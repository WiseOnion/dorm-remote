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
  /// Set while the bulb is in white mode.
  var kelvin: Int? = nil
  /// Set while the bulb runs one of its built-in effects (color-mode "sequence").
  var effect: String? = nil
  /// Effect speed, -10 (slow) to 10 (fast); 0 is normal.
  var speed = 0
}

@MainActor
@Observable
final class HubspaceClient: NSObject {
  enum State: Equatable {
    case signedOut, signingIn, needsCode, loading, ready
    /// Login failed; the sign-in form shows the reason.
    case loginFailed(String)
    /// Signed in, but the lights couldn't be loaded (offline, Hubspace down).
    case unavailable(String)
  }

  var state: State = .signedOut
  var lights: [HubLight] = []
  /// Last failed command, shown under the lights. Commands failing never sign you out.
  var commandError: String?
  var log: [String] = []
  /// Relays commands over Bluetooth to bulbs that aren't on Wi-Fi.
  let hub = BulbHub()

  enum K {
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
  /// One refresh at a time: Keycloak may rotate the refresh token, so parallel refreshes could sign you out.
  private var refreshing: Task<String, Error>?
  private var accountID: String?
  private var verifier = ""
  private var otpAction: URL?
  private var loginSession: URLSession?
  private var pendingSends: [String: Task<Void, Never>] = [:]

  override init() {
    super.init()
    hub.log = { [weak self] in self?.note($0) }
    if refreshToken != nil { Task { await load() } }
  }

  /// Start the Bluetooth hub once signed in; the app stops it in the background.
  func startHub() {
    guard let accountID else { return }
    hub.start(accountID: accountID) { [weak self] associationId in
      await self?.associateHub(associationId) ?? false
    }
  }

  /// The softhub joins the account as a device, like the Hubspace app's hub does.
  private func associateHub(_ associationId: String) async -> Bool {
    guard let accountID else { return false }
    do {
      _ = try await api("POST", K.apiHost + "/v1/accounts/\(accountID)/devices", json: ["associationId": associationId])
      note("bulb hub joined the account")
      return true
    } catch {
      note("bulb hub couldn't join: \(error.localizedDescription)")
      return false
    }
  }

  // MARK: Login

  func signIn(email: String, password: String) async {
    state = .signingIn
    endLoginSession()
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
      note("login page \(Self.status(pageResp))")
      let code: String
      if let redirect = Self.authCode(pageResp) {
        code = redirect
      } else {
        let action = try Self.formAction(String(decoding: page, as: UTF8.self), id: "kc-form-login")
        let (body, resp) = try await post(session, action, ["username": email, "password": password, "credentialId": ""])
        note("login submit \(Self.status(resp))")
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
      endLoginSession()
      state = .loginFailed(error.localizedDescription)
    }
  }

  /// Hubspace sometimes emails a one-time code after the password.
  func submitCode(_ otp: String) async {
    guard let session = loginSession, let action = otpAction else {
      state = .loginFailed("Sign in again")
      return
    }
    state = .signingIn
    do {
      let (body, resp) = try await post(session, action, ["action": "submit", "flowName": "doLogIn", "emailCode": otp])
      note("code submit \(Self.status(resp))")
      guard let code = Self.authCode(resp) else {
        // A wrong code returns the form again with a new action URL.
        if let retry = try? Self.formAction(body, id: "kc-otp-login-form") {
          otpAction = retry
          state = .needsCode
          commandError = "That code didn't work. Try again."
          return
        }
        throw Failure("That code didn't work")
      }
      commandError = nil
      try await exchange(code: code)
    } catch {
      endLoginSession()
      state = .loginFailed(error.localizedDescription)
    }
  }

  func signOut() {
    hub.stop()
    Keychain.delete(K.refreshKey)
    refreshToken = nil
    idToken = nil
    accountID = nil
    lights = []
    commandError = nil
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
    endLoginSession()
    await load()
  }

  /// The session retains its delegate (self) until invalidated.
  private func endLoginSession() {
    loginSession?.invalidateAndCancel()
    loginSession = nil
  }

  private func tokenRequest(_ form: [String: String]) async throws {
    var req = URLRequest(url: URL(string: K.authHost + "/protocol/openid-connect/token")!)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue(K.userAgent, forHTTPHeaderField: "User-Agent")
    req.httpBody = Self.formBody(form)
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = Self.status(resp)
    note("token \(status)")
    // 400/401 means the refresh token was revoked or expired; anything else may be temporary.
    if status == 400 || status == 401 {
      signOut()
      throw Failure("Hubspace signed you out. Sign in again.")
    }
    guard status == 200,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["id_token"] as? String,
          let refresh = json["refresh_token"] as? String
    else { throw Failure("Hubspace login returned \(status)") }
    // aioafero sends the id_token as the bearer, not the access_token.
    idToken = id
    refreshToken = refresh
    Keychain.save(refresh, account: K.refreshKey)
    tokenExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 120) - 5)
  }

  private func bearer(forceRefresh: Bool = false) async throws -> String {
    if !forceRefresh, let idToken, Date() < tokenExpiry { return idToken }
    if let refreshing { return try await refreshing.value }
    guard let refreshToken else { throw Failure("Not signed in") }
    let task = Task<String, Error> {
      defer { self.refreshing = nil }
      try await self.tokenRequest([
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "scope": "openid email offline_access profile",
        "client_id": K.clientID,
      ])
      guard let token = self.idToken else { throw Failure("Not signed in") }
      return token
    }
    refreshing = task
    return try await task.value
  }

  // MARK: Devices

  func load() async {
    state = .loading
    do {
      if accountID == nil {
        let me = try await api("GET", K.apiHost + "/v1/users/me") as? [String: Any]
        accountID = Self.accountID(from: me)
        guard accountID != nil else { throw Failure("No Hubspace account found") }
      }
      let list = try await api("GET", K.dataHost + "/v1/accounts/\(accountID!)/metadevices?expansions=state,capabilities,semantics") as? [[String: Any]] ?? []
      lights = list.compactMap(Self.parseLight)
      note("found \(lights.count) light(s) in \(list.count) device record(s)")
      commandError = nil
      state = .ready
      startHub()
    } catch {
      note("load failed: \(error.localizedDescription)")
      state = refreshToken == nil ? .signedOut : .unavailable(error.localizedDescription)
    }
  }

  func setPower(_ light: HubLight, _ on: Bool) {
    update(light.id) { $0.on = on }
    send(light, key: "power", [("power", on ? "on" : "off")], delay: 0)
  }

  func setBrightness(_ light: HubLight, _ value: Int) {
    update(light.id) { $0.brightness = value; $0.on = true }
    send(light, key: "brightness", [("power", "on"), ("brightness", value)])
  }

  /// Built-in effects, as the bulb lists them (aioafero sample data for the EcoSmart A19/A21 color bulbs).
  /// Hubspace files the first five under "preset" and the rest under "custom".
  static let presetEffects: Set<String> = ["flash", "fade-3", "fade-7", "jump-3", "jump-7"]
  static let effectGroups: [(String, [(id: String, name: String)])] = [
    ("Fun patterns", [("rainbow", "Rainbow"), ("fade-3", "Fade 3"), ("fade-7", "Fade 7"),
                      ("jump-3", "Jump 3"), ("jump-7", "Jump 7"), ("flash", "Flash")]),
    ("Moods", [("chill", "Chill"), ("clarity", "Clarity"), ("dinner-party", "Dinner Party"), ("focus", "Focus"),
               ("getting-ready", "Getting Ready"), ("moonlight", "Moonlight"), ("nightlight", "Night Light"),
               ("sleep", "Sleep"), ("wake-up", "Wake Up")]),
    ("Holidays", [("christmas", "Christmas"), ("july-4th", "July 4th"), ("valentines-day", "Valentine's Day")]),
  ]

  static func effectName(_ id: String) -> String {
    effectGroups.flatMap(\.1).first { $0.id == id }?.name ?? id.capitalized
  }

  func setEffect(_ light: HubLight, _ effect: String) {
    update(light.id) { $0.effect = effect; $0.kelvin = nil; $0.on = true }
    let preset = Self.presetEffects.contains(effect)
    var values: [(String, String?, Any)] = [
      ("power", inst(light, "power"), "on"),
      ("color-mode", inst(light, "color-mode"), "sequence"),
      ("color-sequence", "preset", preset ? effect : "custom"),
    ]
    if !preset { values.append(("color-sequence", "custom", effect)) }
    send(light, key: "color", entries: values)
  }

  func setEffectSpeed(_ light: HubLight, _ speed: Int) {
    update(light.id) { $0.speed = speed }
    send(light, key: "speed", entries: [("speed", "color-sequence", max(-10, min(10, speed)))])
  }

  private func inst(_ light: HubLight, _ cls: String) -> String? { light.instances[cls] ?? nil }

  func setColor(_ light: HubLight, r: Int, g: Int, b: Int) {
    update(light.id) { $0.r = r; $0.g = g; $0.b = b; $0.on = true; $0.kelvin = nil; $0.effect = nil }
    send(light, key: "color", [("power", "on"), ("color-mode", "color"), ("color-rgb", ["color-rgb": ["r": r, "g": g, "b": b]])])
  }

  /// Tunable white, 2200–6500 K on the EcoSmart RGBW bulbs. Shares the color slot so the last pick wins.
  func setWhite(_ light: HubLight, kelvin: Int) {
    update(light.id) { $0.kelvin = kelvin; $0.on = true; $0.effect = nil }
    send(light, key: "color", [("power", "on"), ("color-mode", "white"), ("color-temperature", kelvin)])
  }

  private func update(_ id: String, _ change: (inout HubLight) -> Void) {
    if let i = lights.firstIndex(where: { $0.id == id }) { change(&lights[i]) }
  }

  /// The cloud is slow, so drags send once they pause. Each kind of change waits separately,
  /// so a color change isn't dropped by a brightness change right after it.
  private func send(_ light: HubLight, key: String, _ values: [(String, Any)], delay: Int = 250) {
    send(light, key: key, entries: values.map { ($0.0, inst(light, $0.0), $0.1) }, delay: delay)
  }

  private func send(_ light: HubLight, key: String, entries: [(String, String?, Any)], delay: Int = 250) {
    let slot = light.id + key
    pendingSends[slot]?.cancel()
    let body = Self.stateBody(light.id, entries, now: Int(Date().timeIntervalSince1970 * 1000))
    pendingSends[slot] = Task {
      if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
      guard !Task.isCancelled, let accountID else { return }
      do {
        _ = try await api("PUT", K.dataHost + "/v1/accounts/\(accountID)/metadevices/\(light.id)/state", json: body)
        commandError = nil
      } catch {
        commandError = "\(light.name): \(error.localizedDescription)"
      }
    }
  }

  private func api(_ method: String, _ url: String, json: [String: Any]? = nil, retried: Bool = false) async throws -> Any? {
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = method
    req.setValue("Bearer \(try await bearer(forceRefresh: retried))", forHTTPHeaderField: "Authorization")
    req.setValue(K.userAgent, forHTTPHeaderField: "User-Agent")
    if let json {
      req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONSerialization.data(withJSONObject: json)
    }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = Self.status(resp)
    note("\(method) \(URL(string: url)?.path ?? "") \(status)")
    // A token can be rejected before its stated expiry; refresh once and retry.
    if status == 401, !retried { return try await api(method, url, json: json, retried: true) }
    // 424: Hubspace has no path to the bulb (not on Wi-Fi and no Bluetooth hub nearby yet).
    if status == 424 { throw Failure("Can't reach the bulb yet. Keep your phone near it for a few seconds.") }
    guard (200..<300).contains(status) else { throw Failure("Hubspace returned \(status)") }
    return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
  }

  private func note(_ line: String) {
    log.append("hubspace: " + line)
    if log.count > 200 { log.removeFirst(log.count - 200) }
  }

  // MARK: Parsing (internal so tests can reach them)

  static func accountID(from me: [String: Any]?) -> String? {
    let access = me?["accountAccess"] as? [[String: Any]]
    return (access?.first?["account"] as? [String: Any])?["accountId"] as? String
  }

  static func parseLight(_ dev: [String: Any]) -> HubLight? {
    guard dev["typeId"] as? String == "metadevice.device",
          let id = dev["id"] as? String,
          let description = dev["description"] as? [String: Any],
          (description["device"] as? [String: Any])?["deviceClass"] as? String == "light"
    else { return nil }
    var light = HubLight(id: id, name: dev["friendlyName"] as? String ?? "Light", on: false, brightness: 100, r: 255, g: 255, b: 255, instances: [:])
    var mode: String?
    var temperature: Int?
    var sequence: [String: String] = [:]
    for s in (dev["state"] as? [String: Any])?["values"] as? [[String: Any]] ?? [] {
      guard let cls = s["functionClass"] as? String else { continue }
      if light.instances[cls] == nil { light.instances.updateValue(s["functionInstance"] as? String, forKey: cls) }
      switch cls {
      case "power": light.on = s["value"] as? String == "on"
      case "brightness": light.brightness = (s["value"] as? NSNumber)?.intValue ?? light.brightness
      case "color-rgb":
        let rgb = (s["value"] as? [String: Any])?["color-rgb"] as? [String: Any] ?? [:]
        light.r = (rgb["r"] as? NSNumber)?.intValue ?? 255
        light.g = (rgb["g"] as? NSNumber)?.intValue ?? 255
        light.b = (rgb["b"] as? NSNumber)?.intValue ?? 255
      case "color-mode": mode = s["value"] as? String
      case "color-temperature": temperature = (s["value"] as? NSNumber)?.intValue
      case "color-sequence":
        if let instance = s["functionInstance"] as? String, let value = s["value"] as? String { sequence[instance] = value }
      case "speed" where s["functionInstance"] as? String == "color-sequence":
        light.speed = (s["value"] as? NSNumber)?.intValue ?? 0
      default: break
      }
    }
    if mode == "white" { light.kelvin = temperature ?? 2700 }
    if mode == "sequence", let preset = sequence["preset"] {
      light.effect = preset == "custom" ? sequence["custom"] : preset
    }
    return light
  }

  static func stateBody(_ light: HubLight, _ values: [(String, Any)], now: Int) -> [String: Any] {
    stateBody(light.id, values.map { ($0.0, light.instances[$0.0] ?? nil, $0.1) }, now: now)
  }

  static func stateBody(_ id: String, _ entries: [(String, String?, Any)], now: Int) -> [String: Any] {
    let states: [[String: Any]] = entries.map { cls, instance, value in
      ["functionClass": cls,
       "functionInstance": instance.map { $0 as Any } ?? NSNull(),
       "value": value,
       "lastUpdateTime": now]
    }
    return ["metadeviceId": id, "values": states]
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

  private static func status(_ resp: URLResponse) -> Int { (resp as? HTTPURLResponse)?.statusCode ?? 0 }

  /// The login finishes by redirecting to hubspace-app://loginredirect?code=…, which is never followed.
  static func authCode(_ resp: URLResponse) -> String? {
    guard let http = resp as? HTTPURLResponse, (300..<400).contains(http.statusCode),
          let location = http.value(forHTTPHeaderField: "Location") else { return nil }
    return URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value
  }

  static func formAction(_ html: String, id: String) throws -> URL {
    let forms = html.matches(of: #/<form\b[^>]*>/#).map { String($0.output) }
    guard let tag = forms.first(where: { $0.contains("id=\"\(id)\"") }),
          let action = tag.firstMatch(of: #/action="([^"]+)"/#)?.output.1,
          let url = URL(string: String(action).replacingOccurrences(of: "&amp;", with: "&"))
    else { throw Failure("Hubspace changed its login page") }
    return url
  }

  /// application/x-www-form-urlencoded with only RFC 3986 unreserved ASCII left as is.
  static func formBody(_ form: [String: String]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return Data(form.sorted { $0.key < $1.key }.map { k, v in
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
