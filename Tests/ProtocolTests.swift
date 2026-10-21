import CoreBluetooth
import XCTest
@testable import DormRemote

/// Frames captured from real strips (homebridge-daybetter, grimsteel/daybetter-led-strip, DoudGeorges PROTOCOL.md).
final class DaybetterTests: XCTestCase {
  private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }

  func testCapturedFrames() {
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.power, [1])), "A0 11 04 01 B1 21")
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.power, [0])), "A0 11 04 00 70 E1")
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.color, [0xFF, 0, 0])), "A0 15 06 FF 00 00 25 C0")
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.color, [0, 0xFF, 0])), "A0 15 06 00 FF 00 54 00")
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.brightness, [100])), "A0 13 04 64 D0 CA")
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.brightness, [1])), "A0 13 04 01 10 E1")
  }

  func testUnlockRequest() {
    XCTAssertEqual(hex(Daybetter.frame(0x00, Daybetter.cchip)), "A0 00 08 43 43 48 49 50 AC CA")
  }

  func testRGBWColorFrame() {
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.color, [0xFF, 0, 0, 0])), "A0 15 07 FF 00 00 00 3C 1B")
  }

  func testCharacteristicsPerRevision() {
    let e026 = Daybetter.characteristics(for: CBUUID(string: "E026"))
    XCTAssertEqual(e026?.write, CBUUID(string: "A026"))
    XCTAssertEqual(e026?.notify, CBUUID(string: "F026"))
    let e031 = Daybetter.characteristics(for: CBUUID(string: "E031"))
    XCTAssertEqual(e031?.write, CBUUID(string: "A031"))
    let ff10 = Daybetter.characteristics(for: CBUUID(string: "FF10"))
    XCTAssertEqual(ff10?.write, CBUUID(string: "FF12"))
    XCTAssertEqual(ff10?.notify, CBUUID(string: "FF11"))
    XCTAssertNil(Daybetter.characteristics(for: CBUUID(string: "180A")))
    XCTAssertNil(Daybetter.characteristics(for: CBUUID(string: "0000E026-0000-1000-8000-00805F9B34FA")))
  }
}

@MainActor
final class HubspaceTests: XCTestCase {
  func testLoginFormAction() throws {
    let html = """
      <html><form id="other" action="https://x/y"></form>
      <form id="kc-form-login" onsubmit="login.disabled = true; return true;" action="https://accounts.hubspaceconnect.com/auth/realms/thd/login-actions/authenticate?session_code=S&amp;execution=E&amp;client_id=hubspace_android&amp;tab_id=T" method="post">
      </form></html>
      """
    let url = try HubspaceClient.formAction(html, id: "kc-form-login")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    XCTAssertEqual(items.first { $0.name == "session_code" }?.value, "S")
    XCTAssertEqual(items.first { $0.name == "execution" }?.value, "E")
    XCTAssertEqual(items.first { $0.name == "tab_id" }?.value, "T")
    XCTAssertThrowsError(try HubspaceClient.formAction(html, id: "kc-otp-login-form"))
  }

  func testAuthCodeFromRedirect() {
    let resp = HTTPURLResponse(url: URL(string: "https://a")!, statusCode: 302, httpVersion: nil,
                               headerFields: ["Location": "hubspace-app://loginredirect?state=x&session_state=y&code=abc.def"])!
    XCTAssertEqual(HubspaceClient.authCode(resp), "abc.def")
    let page = HTTPURLResponse(url: URL(string: "https://a")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    XCTAssertNil(HubspaceClient.authCode(page))
  }

  func testFormBodyEncoding() {
    let body = String(decoding: HubspaceClient.formBody(["password": "a+b é&=", "username": "me@x.com"]), as: UTF8.self)
    XCTAssertEqual(body, "password=a%2Bb%20%C3%A9%26%3D&username=me%40x.com")
  }

  func testAccountID() {
    let me: [String: Any] = ["accountAccess": [["account": ["accountId": "acct-1"]]]]
    XCTAssertEqual(HubspaceClient.accountID(from: me), "acct-1")
    XCTAssertNil(HubspaceClient.accountID(from: [:]))
  }

  private func device(_ json: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }

  func testParseLight() throws {
    let dev = try device("""
      {"id": "meta-1", "typeId": "metadevice.device", "friendlyName": "Desk Lamp",
       "description": {"device": {"deviceClass": "light"}},
       "state": {"values": [
         {"functionClass": "power", "functionInstance": null, "value": "on"},
         {"functionClass": "brightness", "functionInstance": null, "value": 42},
         {"functionClass": "color-rgb", "functionInstance": null, "value": {"color-rgb": {"r": 10, "g": 20, "b": 30}}},
         {"functionClass": "color-mode", "functionInstance": "primary", "value": "color"}
       ]}}
      """)
    let light = try XCTUnwrap(HubspaceClient.parseLight(dev))
    XCTAssertEqual(light.name, "Desk Lamp")
    XCTAssertTrue(light.on)
    XCTAssertEqual(light.brightness, 42)
    XCTAssertEqual([light.r, light.g, light.b], [10, 20, 30])
    XCTAssertEqual(light.instances["color-mode"], .some("primary"))
    XCTAssertEqual(light.instances["power"], .some(nil))
  }

  func testParseLightSkipsNonLights() throws {
    let fan = try device(#"{"id": "f", "typeId": "metadevice.device", "description": {"device": {"deviceClass": "fan"}}}"#)
    XCTAssertNil(HubspaceClient.parseLight(fan))
    let child = try device(#"{"id": "c", "typeId": "metadevice.homeDevice", "description": {"device": {"deviceClass": "light"}}}"#)
    XCTAssertNil(HubspaceClient.parseLight(child))
  }

  func testStateBody() throws {
    let light = HubLight(id: "meta-1", name: "L", on: true, brightness: 50, r: 0, g: 0, b: 0,
                         instances: ["power": nil, "color-mode": "primary"])
    let body = HubspaceClient.stateBody(light, [("power", "on"), ("color-mode", "color")], now: 123)
    let data = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    XCTAssertEqual(String(decoding: data, as: UTF8.self),
                   #"{"metadeviceId":"meta-1","values":[{"functionClass":"power","functionInstance":null,"lastUpdateTime":123,"value":"on"},{"functionClass":"color-mode","functionInstance":"primary","lastUpdateTime":123,"value":"color"}]}"#)
  }
}
