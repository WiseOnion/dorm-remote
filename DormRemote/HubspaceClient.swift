import CryptoKit
import Foundation
import Observation

/// Hubspace (Afero cloud) lights. Login and API calls follow the aioafero library:
/// Keycloak login with PKCE at accounts.hubspaceconnect.com, then the metadevices API.
/// The bulb only takes commands from Home Depot's cloud, so this needs internet, not the same Wi-Fi.
struct HubLight: Identifiable {
  let id: String
  var name: String
  var on: Bool
  var brightness: Int
  var r: Int, g: Int, b: Int
  /// functionInstance per functionClass, as the device reports it (often null).
  var instances: [String: String?]
}

@MainActor
@Observable
final class HubspaceClient: NSObject {
  enum State: Equatable { case signedOut, signingIn, needsCode, loading, ready, failed(String) }

  var state: State = .signedOut
  var lights: [HubLight] = []

  private enum K {
    static let authHost = "https://accounts.hubspaceconnect.com/auth/realms/thd"
    static let apiHost = "https://api2.afero.net"
    static let dataHost = "https://semantics2.afero.net"
    static let clientID = "hubspace_android"
    static let redirect = "hubspace-app://loginredirect"
    static let userAgent = "Mozilla/5.0 (Linux; Android 15; DormRemote Build/test; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/138.0.7204.63 Mobile Safari/537.36"
    static let refreshKey = "hubspaceRefreshToken"
  }

  private var refreshToken: String? = Keychain.read(K.refreshKey)
  private var idToken: String?
  private var tokenExpiry = Date.distantPast
  private var accountID: String?
  private var verifier = ""
  private var otpAction: URL?
  private var loginSession: URLSession?
  private var colorTask: Task<Void, Never>?

  override init() {
    super.init()
    if refreshToken != nil { Task { await load() } }
  }

  // MARK: Login

  func signIn(email: String, password: String) async {
    state = .signingIn
    do {
      // Fresh cookie jar per login; Keycloak ties the form to its session cookie.
      let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
      loginSession = session
      verifier = Self.randomVerifier()
      let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

      var auth = URLComponents(string: K.authHost + "/protocol/openid-connect/auth")!
      auth.queryItems = [
        .init(name: "response_type", value: "code"),
        .init(name: "client_id", value: K.clientID),
        .init(name: "redirect_uri", value: K.redirect),
        .init(name: "code_challenge", value: challenge),
        .init(name: "code_challenge_method", value: "S256"),
        .init(name: "scope", value: "openid offline_access"),
      ]
      var req = URLRequest(url: auth.url!)
      req.setValue(K.userAgent, forHTTPHeaderField: "User-Agent")
      let (page, pageResp) = try await session.data(for: req)
      let code: String
      if let redirect = Self.authCode(pageResp) {
        code = redirect
      } else {
        let action = try Self.formAction(String(decoding: page, as: UTF8.self), id: "kc-form-login")
        let (body, resp) = try await post(session, action, ["username": email, "password": password, "credentialId": ""])
        if let c = Self.authCode(resp) {
          code = c
        } else if body.contains("kc-otp-login-form") {
          otpAction = try Self.formAction(body, id: "kc-otp-login-form")
          state = .needsCode
          return
        } else {
          throw Failure("Wrong email or password")
        }
      }
      try await exchange(code: code)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// Hubspace sometimes emails a one-time code after the password.
  func submitCode(_ otp: String) async {
    guard let session = loginSession, let action = otpAction else { return }
    state = .signingIn
    do {
      let (_, resp) = try await post(session, action, ["action": "submit", "flowName": "doLogIn", "emailCode": otp])
      guard let code = Self.authCode(resp) else { throw Failure("That code didn't work") }
      try await exchange(code: code)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func signOut() {
    Keychain.delete(K.refreshKey)
    refreshToken = nil
    idToken = nil
    accountID = nil
    lights = []
    state = .signedOut
  }

  private func exchange(code: String) async throws {
    try await tokenRequest([
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": K.redirect,
      "code_verifier": verifier,
      "client_id": K.clientID,
    ])
    loginSession = nil
    await load()
  }

  private func tokenRequest(_ form: [String: String]) async throws {
    var req = URLRequest(url: URL(string: K.authHost + "/protocol/openid-connect/token")!)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue(K.userAgent, forHTTPHeaderField: "User-Agent")
    req.httpBody = Self.formBody(form)
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["id_token"] as? String,
          let refresh = json["refresh_token"] as? String
    else { throw Failure("Hubspace login expired. Sign in again.") }
    // aioafero sends the id_token as the bearer, not the access_token.
    idToken = id
    refreshToken = refresh
    Keychain.save(refresh, account: K.refreshKey)
    tokenExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 120) - 5)
  }

  private func bearer() async throws -> String {
    if let idToken, Date() < tokenExpiry { return idToken }
    guard let refreshToken else { throw Failure("Not signed in") }
    try await tokenRequest([
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "scope": "openid email offline_access profile",
      "client_id": K.clientID,
    ])
    return idToken!
  }

  // MARK: Devices

  func load() async {
    state = .loading
    do {
      if accountID == nil {
        let me = try await api("GET", K.apiHost + "/v1/users/me") as? [String: Any]
        let access = me?["accountAccess"] as? [[String: Any]]
        accountID = (access?.first?["account"] as? [String: Any])?["accountId"] as? String
        guard accountID != nil else { throw Failure("No Hubspace account found") }
      }
      let list = try await api("GET", K.dataHost + "/v1/accounts/\(accountID!)/metadevices?expansions=state,capabilities,semantics") as? [[String: Any]] ?? []
      lights = list.compactMap(Self.parseLight)
      state = .ready
    } catch {
      state = refreshToken == nil ? .signedOut : .failed(error.localizedDescription)
    }
  }

  func setPower(_ light: HubLight, _ on: Bool) {
    update(light.id) { $0.on = on }
    put(light, [("power", on ? "on" : "off")])
  }

  func setBrightness(_ light: HubLight, _ value: Int) {
    update(light.id) { $0.brightness = value }
    debounced { self.put(light, [("power", "on"), ("brightness", value)]) }
  }

  func setColor(_ light: HubLight, r: Int, g: Int, b: Int) {
    update(light.id) { $0.r = r; $0.g = g; $0.b = b }
    debounced {
      self.put(light, [("power", "on"), ("color-mode", "color"), ("color-rgb", ["color-rgb": ["r": r, "g": g, "b": b]])])
    }
  }

  private func update(_ id: String, _ change: (inout HubLight) -> Void) {
    if let i = lights.firstIndex(where: { $0.id == id }) { change(&lights[i]) }
  }

  /// The cloud is slow; drags send only once they pause.
  private func debounced(_ action: @escaping () -> Void) {
    colorTask?.cancel()
    colorTask = Task {
      try? await Task.sleep(for: .milliseconds(250))
      if !Task.isCancelled { action() }
    }
  }

  private func put(_ light: HubLight, _ values: [(String, Any)]) {
    guard let accountID else { return }
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let states: [[String: Any]] = values.map { cls, value in
      let instance: String? = light.instances[cls] ?? nil
      return ["functionClass": cls,
              "functionInstance": instance.map { $0 as Any } ?? NSNull(),
              "value": value,
              "lastUpdateTime": now]
    }
    let body: [String: Any] = ["metadeviceId": light.id, "values": states]
    Task {
      do {
        _ = try await api("PUT", K.dataHost + "/v1/accounts/\(accountID)/metadevices/\(light.id)/state", json: body)
      } catch {
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func api(_ method: String, _ url: String, json: [String: Any]? = nil) async throws -> Any? {
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = method
    req.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
    req.setValue(K.userAgent, forHTTPHeaderField: "User-Agent")
    if let json {
      req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: json)
    }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw Failure("Hubspace returned \(status)") }
    return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
  }

  private static func parseLight(_ dev: [String: Any]) -> HubLight? {
    guard dev["typeId"] as? String == "metadevice.device",
          let id = dev["id"] as? String,
          let description = dev["description"] as? [String: Any],
          (description["device"] as? [String: Any])?["deviceClass"] as? String == "light"
    else { return nil }
    var light = HubLight(id: id, name: dev["friendlyName"] as? String ?? "Light", on: false, brightness: 100, r: 255, g: 255, b: 255, instances: [:])
    for s in (dev["state"] as? [String: Any])?["values"] as? [[String: Any]] ?? [] {
      guard let cls = s["functionClass"] as? String else { continue }
      if light.instances[cls] == nil { light.instances.updateValue(s["functionInstance"] as? String, forKey: cls) }
      switch cls {
      case "power": light.on = s["value"] as? String == "on"
      case "brightness": light.brightness = s["value"] as? Int ?? light.brightness
      case "color-rgb":
        let rgb = (s["value"] as? [String: Any])?["color-rgb"] as? [String: Int] ?? [:]
        light.r = rgb["r"] ?? 255; light.g = rgb["g"] ?? 255; light.b = rgb["b"] ?? 255
      default: break
      }
    }
    return light
  }

  // MARK: Helpers

  private func post(_ session: URLSession, _ url: URL, _ form: [String: String]) async throws -> (String, URLResponse) {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue("io.afero.partner.hubspace", forHTTPHeaderField: "X-Requested-With")
    req.setValue(K.userAgent, forHTTPHeaderField: "User-Agent")
    req.httpBody = Self.formBody(form)
    let (data, resp) = try await session.data(for: req)
    return (String(decoding: data, as: UTF8.self), resp)
  }

  /// The login finishes by redirecting to hubspace-app://loginredirect?code=…, which is never followed.
  private static func authCode(_ resp: URLResponse) -> String? {
    guard let http = resp as? HTTPURLResponse, http.statusCode == 302,
          let location = http.value(forHTTPHeaderField: "Location") else { return nil }
    return URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value
  }

  private static func formAction(_ html: String, id: String) throws -> URL {
    let forms = html.matches(of: #/<form\b[^>]*>/#).map { String($0.output) }
    guard let tag = forms.first(where: { $0.contains("id=\"\(id)\"") }),
          let action = tag.firstMatch(of: #/action="([^"]+)"/#)?.output.1,
          let url = URL(string: String(action).replacingOccurrences(of: "&amp;", with: "&"))
    else { throw Failure("Hubspace changed its login page") }
    return url
  }

  private static func formBody(_ form: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return Data(form.map { k, v in
      "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }.joined(separator: "&").utf8)
  }

  private static func randomVerifier() -> String {
    let bytes = (0..<40).map { _ in UInt8.random(in: 0...255) }
    return Data(bytes).base64URL
  }
}

extension HubspaceClient: URLSessionTaskDelegate {
  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}

struct Failure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

extension Data {
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
