import CoreBluetooth
import UIKit
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

  // grimsteel util.py correct_color: gamma, then green * 100/255, blue * 140/255.
  func testColorCorrection() {
    XCTAssertEqual(Daybetter.corrected(255, 0, 0), [255, 0, 0])
    XCTAssertEqual(Daybetter.corrected(255, 255, 255), [255, 100, 140])
    XCTAssertEqual(Daybetter.corrected(255, 146, 39), [255, 23, 0])
    // A custom balance scales each channel after gamma.
    XCTAssertEqual(Daybetter.corrected(255, 255, 255, balance: [0.5, 1, 0.2]), [127, 255, 51])
  }

  func testRGBWColorFrame() {
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.color, [0xFF, 0, 0, 0])), "A0 15 07 FF 00 00 00 3C 1B")
  }

  func testEffectFrame() {
    // grimsteel set_effect: one byte, e.g. fade slow.
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.effect, [0x0C])), "A0 12 04 0C 80 E4")
  }

  func testStatusReply() throws {
    // From this strip's log: A1 10 11 01 01 00 64 …
    let bytes: [UInt8] = [0xA1, 0x10, 0x11, 0x01, 0x01, 0x00, 0x64, 0x32, 0x32, 0xFF, 0x92, 0x27, 0xFF, 0, 0, 0, 0, 0x6E, 0x29]
    let status = try XCTUnwrap(StripStatus(bytes))
    XCTAssertTrue(status.on)
    XCTAssertEqual(status.brightness, 100)
    XCTAssertNil(StripStatus([0xA1, 0x13, 0x04, 0x01, 0x11, 0x1D]))
  }

  // DoudGeorges PROTOCOL.md: request A0 00 08 "CCHIP" AC CA; answer "CCHIP" c1^36 c2^76; verdict byte 8, 0 = unlocked.
  func testUnlock() throws {
    XCTAssertEqual(hex(Daybetter.frame(Daybetter.challenge, Daybetter.cchip)), "A0 00 08 43 43 48 49 50 AC CA")
    let challenge: [UInt8] = [0xA1, 0x00, 0x0A] + Daybetter.cchip + [0x10, 0x20, 0x00, 0x00]
    let answer = try XCTUnwrap(Daybetter.unlockAnswer(to: challenge))
    let body = Array(answer.prefix(10))
    XCTAssertEqual(body, [0xA0, 0x01, 0x0A] + Daybetter.cchip + [0x10 ^ 36, 0x20 ^ 76])
    let crc = Daybetter.crc16modbus(body)
    XCTAssertEqual(Array(answer.suffix(2)), [UInt8(crc & 0xFF), UInt8(crc >> 8)])
    // A status reply isn't a challenge.
    XCTAssertNil(Daybetter.unlockAnswer(to: [0xA1, 0x10, 0x11, 0x01, 0x01, 0x00, 0x64, 0, 0, 0]))
    XCTAssertEqual(Daybetter.unlockResult([0xA1, 0x01, 0x09] + Daybetter.cchip + [0x00]), true)
    XCTAssertEqual(Daybetter.unlockResult([0xA1, 0x01, 0x09] + Daybetter.cchip + [0x01]), false)
    XCTAssertNil(Daybetter.unlockResult([0xA1, 0x15, 0x04, 0x01, 0xF1, 0x1C]))
  }

  func testSpeedFrame() {
    XCTAssertEqual(Array(Daybetter.frame(Daybetter.speed, [50]).prefix(4)), [0xA0, 0x16, 0x04, 50])
  }

  func testControllerFamilies() {
    XCTAssertFalse(Daybetter.isSegmentController(CBUUID(string: "E031")))
    XCTAssertFalse(Daybetter.isSegmentController(CBUUID(string: "FF10")))
    XCTAssertTrue(Daybetter.isSegmentController(CBUUID(string: "E010")))
    XCTAssertTrue(Daybetter.isSegmentController(CBUUID(string: "AE30")))
    XCTAssertTrue(Daybetter.advertisesStrip([CBUUID(string: "C031")]))
    XCTAssertTrue(Daybetter.advertisesStrip([CBUUID(string: "180A"), CBUUID(string: "AF30")]))
    XCTAssertFalse(Daybetter.advertisesStrip([CBUUID(string: "180A")]))
    XCTAssertFalse(Daybetter.advertisesStrip([]))
  }

  func testStripNames() {
    XCTAssertTrue(Daybetter.looksLikeStrip("P031_3712"))
    XCTAssertTrue(Daybetter.looksLikeStrip("Smart Light"))
    XCTAssertTrue(Daybetter.looksLikeStrip("WI-FI LIGHT"))
    XCTAssertTrue(Daybetter.looksLikeStrip("BLE BULB"))
    XCTAssertFalse(Daybetter.looksLikeStrip("Echo Dot-107"))
    XCTAssertFalse(Daybetter.looksLikeStrip("PX31_1"))
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

  func testParseWhiteMode() throws {
    let dev = try device("""
      {"id": "meta-2", "typeId": "metadevice.device", "description": {"device": {"deviceClass": "light"}},
       "state": {"values": [
         {"functionClass": "color-mode", "functionInstance": null, "value": "white"},
         {"functionClass": "color-temperature", "functionInstance": null, "value": 3000}
       ]}}
      """)
    XCTAssertEqual(try XCTUnwrap(HubspaceClient.parseLight(dev)).kelvin, 3000)
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

final class LookTests: XCTestCase {
  func testKelvinToRGB() {
    XCTAssertEqual(RGB.kelvin(2700), RGB(r: 255, g: 167, b: 87))
    XCTAssertEqual(RGB.kelvin(2200), RGB(r: 255, g: 146, b: 39))
    XCTAssertEqual(RGB.kelvin(6500), RGB(r: 255, g: 254, b: 250))
  }

  func testEveryShortcutSceneExists() {
    for choice in SceneChoice.allCases { XCTAssertNotNil(choice.mood, choice.rawValue) }
    XCTAssertEqual(Set(Mood.all.map(\.id)).count, Mood.all.count, "scene names must be unique")
  }

  func testSavedSceneRoundTrips() throws {
    let snap = Mood.Snap(color: RGB(r: 1, g: 2, b: 3), kelvin: nil, brightness: 40, on: true)
    let scene = Mood("Study", .mine, .snapshot(["strip": snap]), 40)
    let back = try JSONDecoder().decode(Mood.self, from: JSONEncoder().encode(scene))
    XCTAssertEqual(back.id, "Study")
    XCTAssertEqual(back.group, .mine)
    guard case .snapshot(let snaps) = back.look else { return XCTFail("wrong look") }
    XCTAssertEqual(snaps["strip"], snap)
  }

  func testPhotoPalette() {
    // Mostly red, some blue, a little green (too little to count), plus gray and black that are skipped.
    let pixels = Array(repeating: RGB(r: 230, g: 20, b: 30), count: 60) + Array(repeating: RGB(r: 20, g: 40, b: 220), count: 30)
      + [RGB(r: 0, g: 200, b: 0)] + Array(repeating: RGB(r: 128, g: 128, b: 128), count: 40) + Array(repeating: RGB(r: 5, g: 5, b: 5), count: 40)
    let palette = Mood.palette(from: pixels)
    XCTAssertEqual(palette, [RGB(r: 230, g: 20, b: 30), RGB(r: 20, g: 40, b: 220)])
    XCTAssertEqual(Mood.palette(from: Array(repeating: RGB(r: 128, g: 128, b: 128), count: 10)), [])
  }

  func testPaletteFromRealImage() throws {
    // Left half orange, right half blue, as a PNG, through the same path a picked photo takes.
    let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { ctx in
      UIColor(red: 1, green: 0.4, blue: 0, alpha: 1).setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
      UIColor(red: 0, green: 0.2, blue: 1, alpha: 1).setFill()
      ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
    }
    let pixels = Mood.pixels(ofImage: try XCTUnwrap(image.pngData()))
    XCTAssertEqual(pixels.count, 48 * 48)
    let palette = Mood.palette(from: pixels)
    // Resampling can blend a column at the seam into a third, small group.
    XCTAssertGreaterThanOrEqual(palette.count, 2)
    XCTAssertTrue(palette.contains { $0.r > 200 && $0.b < 60 }, "orange missing: \(palette)")
    XCTAssertTrue(palette.contains { $0.b > 200 && $0.r < 60 }, "blue missing: \(palette)")
  }

  func testVividKeepsHueAndWhite() {
    // Hue's pastel peach becomes a saturated orange on the strip; white stays white.
    let peach = RGB(r: 255, g: 183, b: 130).vivid
    XCTAssertEqual(peach.r, 255)
    XCTAssertLessThan(peach.b, 40)
    XCTAssertEqual(RGB.white.vivid, .white)
  }
}

final class BulbProtocolTests: XCTestCase {
  private func hex(_ frames: [Data]) -> [String] { frames.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") } }

  func testDetect() {
    XCTAssertEqual(BulbProtocol.detect("ELK-BLEDOM"), .elk)
    XCTAssertEqual(BulbProtocol.detect("Triones:A1B2"), .triones)
    XCTAssertNil(BulbProtocol.detect("P031_3712"))
  }

  // Frames from madhead/saberlight (Triones) and dave-code-ruiz/elkbledom models.json (ELK-BLEDOM).
  func testTrionesFrames() {
    XCTAssertEqual(hex(BulbProtocol.triones.power(true)), ["CC 23 33"])
    XCTAssertEqual(hex(BulbProtocol.triones.power(false)), ["CC 24 33"])
    XCTAssertEqual(hex(BulbProtocol.triones.color(RGB(r: 255, g: 0, b: 0), brightness: 100)), ["56 FF 00 00 00 F0 AA"])
    XCTAssertEqual(hex(BulbProtocol.triones.color(RGB(r: 200, g: 100, b: 0), brightness: 50)), ["56 64 32 00 00 F0 AA"])
    XCTAssertEqual(hex(BulbProtocol.triones.white(2700, brightness: 100)), ["56 00 00 00 FF 0F AA"])
  }

  func testElkFrames() {
    XCTAssertEqual(hex(BulbProtocol.elk.power(true)), ["7E 00 04 F0 00 01 FF 00 EF"])
    XCTAssertEqual(hex(BulbProtocol.elk.color(RGB(r: 0, g: 0, b: 255), brightness: 40)),
                   ["7E 00 05 03 00 00 FF 0A EF", "7E 00 01 28 00 00 00 00 EF"])
  }
}
