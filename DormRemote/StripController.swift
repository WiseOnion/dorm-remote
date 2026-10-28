import CoreBluetooth
import Foundation
import Observation

/// Daybetter RGB strips over Bluetooth LE, copied from grimsteel/daybetter-led-strip, which was written for this
/// exact controller (service E031, write A031, notify F031).
/// Frame: A0 <cmd> <payloadLen+3> <payload…> <CRC-16/MODBUS, low byte first>; replies start with A1.
enum Daybetter {
  static let challenge: UInt8 = 0x00
  static let response: UInt8 = 0x01
  static let status: UInt8 = 0x10
  static let power: UInt8 = 0x11
  static let effect: UInt8 = 0x12
  static let brightness: UInt8 = 0x13
  static let color: UInt8 = 0x15
  /// Effect speed 1–100 (DoudGeorges PROTOCOL.md; not in grimsteel, so older controllers may ignore it).
  static let speed: UInt8 = 0x16

  // grimsteel util.py: FastLED-derived gamma table plus per-channel calibration. The strip's green and blue
  // LEDs are far brighter than its red, so uncorrected colors like orange come out nearly white.
  static let gamma: [UInt8] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 3,
    3, 3, 3, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6,
    7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 11, 11, 11, 12,
    12, 12, 13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18, 19, 19,
    20, 20, 21, 21, 22, 23, 23, 24, 24, 25, 26, 26, 27, 28, 28, 29,
    30, 30, 31, 32, 33, 33, 34, 35, 36, 36, 37, 38, 39, 40, 40, 41,
    42, 43, 44, 45, 46, 47, 48, 48, 49, 50, 51, 52, 53, 54, 55, 56,
    57, 58, 60, 61, 62, 63, 64, 65, 66, 67, 68, 70, 71, 72, 73, 74,
    76, 77, 78, 79, 81, 82, 83, 85, 86, 87, 89, 90, 91, 93, 94, 96,
    97, 99, 100, 102, 103, 105, 106, 108, 109, 111, 112, 114, 115, 117, 119, 120,
    122, 124, 125, 127, 129, 130, 132, 134, 136, 137, 139, 141, 143, 145, 146, 148,
    150, 152, 154, 156, 158, 160, 162, 164, 166, 168, 170, 172, 174, 176, 178, 180,
    182, 184, 187, 189, 191, 193, 195, 197, 200, 202, 204, 207, 209, 211, 213, 216,
    218, 221, 223, 225, 228, 230, 233, 235, 238, 240, 243, 245, 248, 250, 253, 255,
  ]

  /// grimsteel's hand-tuned channel balance (255, 100, 140 out of 255). "Match colors" changes it per strip.
  static let defaultBalance: [Double] = [1, 100.0 / 255, 140.0 / 255]

  static func corrected(_ r: UInt8, _ g: UInt8, _ b: UInt8, balance: [Double] = defaultBalance) -> [UInt8] {
    zip([r, g, b], balance).map { v, k in UInt8(Int(Double(gamma[Int(v)]) * k)) }
  }

  /// DayBetter names its strips by model code, e.g. P031_3712, or by family (DoudGeorges PROTOCOL.md).
  static func looksLikeStrip(_ name: String) -> Bool {
    let upper = name.uppercased()
    return upper.wholeMatch(of: #/P0[0-9A-F]{2}_.*/#) != nil
      || ["SMART LIGHT", "MAGIC LIGHT", "DAYBETTER", "CCHIP", "WI-FI LIGHT", "BLE BULB"].contains { upper.contains($0) }
  }

  /// Controllers advertise a scan service C0xx (AF30 on the P00B), even when they send no name.
  static func advertisesStrip(_ services: [CBUUID]) -> Bool {
    services.contains { s in
      let id = s.uuidString.uppercased()
      return id == "AF30" || (id.count == 4 && id.hasPrefix("C0"))
    }
  }

  /// Controller revisions use different GATT IDs. Most follow E0xx service → A0xx write / F0xx notify.
  static func characteristics(for service: CBUUID) -> (write: CBUUID, notify: CBUUID)? {
    let id = service.uuidString.uppercased()
    if id == "FF10" { return (CBUUID(string: "FF12"), CBUUID(string: "FF11")) }
    if id == "AE30" { return (CBUUID(string: "AE01"), CBUUID(string: "AE02")) }
    if id.count == 4, id.hasPrefix("E0") {
      let suffix = id.suffix(2)
      return (CBUUID(string: "A0" + suffix), CBUUID(string: "F0" + suffix))
    }
    return nil
  }

  /// "Magic Light" controllers drive addressable segments with a different command set (DoudGeorges PROTOCOL.md, HC family).
  static func isSegmentController(_ service: CBUUID) -> Bool {
    ["AE30", "E010", "E019", "E01A", "E020", "E028", "E02A", "E036", "E044"].contains(service.uuidString.uppercased())
  }

  static let cchip: [UInt8] = Array("CCHIP".utf8)

  /// CCHIP unlock (DoudGeorges PROTOCOL.md): the strip answers the request with A1 00 0A "CCHIP" c1 c2 <crc>,
  /// and expects "CCHIP" c1^36 c2^76 back.
  static func unlockAnswer(to reply: [UInt8]) -> Data? {
    guard reply.count >= 10, reply[0] == 0xA1, reply[1] == challenge, Array(reply[3..<8]) == cchip else { return nil }
    return frame(response, cchip + [reply[8] ^ 36, reply[9] ^ 76])
  }

  /// The strip's verdict on the unlock: A1 01 09 "CCHIP" <0 = unlocked>. Nil when this isn't that reply.
  static func unlockResult(_ reply: [UInt8]) -> Bool? {
    guard reply.count >= 9, reply[0] == 0xA1, reply[1] == response else { return nil }
    return reply[8] == 0
  }

  static func crc16modbus(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for b in bytes {
      crc ^= UInt16(b)
      for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
    }
    return crc
  }

  static func frame(_ cmd: UInt8, _ payload: [UInt8]) -> Data {
    let body: [UInt8] = [0xA0, cmd, UInt8(payload.count + 3)] + payload
    let crc = crc16modbus(body)
    return Data(body + [UInt8(crc & 0xFF), UInt8(crc >> 8)])
  }
}

/// What the strip reports about itself: A1 10 11 <power> … (also sent after IR remote presses).
/// grimsteel documents only the power byte; the brightness byte matched what we sent in this strip's logs.
struct StripStatus: Equatable {
  var on: Bool
  var brightness: Int

  init?(_ bytes: [UInt8]) {
    guard bytes.count >= 7, bytes[0] == 0xA1, bytes[1] == Daybetter.status, bytes[2] == 0x11 else { return nil }
    on = bytes[3] == 0x01
    brightness = max(1, min(100, Int(bytes[6])))
  }
}

struct FoundDevice: Identifiable {
  let id: UUID
  let name: String
  var rssi: Int
  let peripheral: CBPeripheral
  /// Advertises a DayBetter scan service, so it's a strip whatever its name.
  var daybetter = false
}

/// One saved strip and its Bluetooth link.
@Observable
final class Strip: Identifiable {
  enum State: Equatable { case idle, connecting, connected, failed(String) }

  let id: UUID
  var state: State = .idle

  @ObservationIgnored fileprivate var peripheral: CBPeripheral?
  @ObservationIgnored fileprivate var writeChar: CBCharacteristic?
  @ObservationIgnored fileprivate var notifyChar: CBCharacteristic?
  @ObservationIgnored fileprivate var inFlight = false
  // ponytail: one queued command per command type, newest wins, so dragging a slider never floods
  // the strip and a tap on "On" isn't dropped by a color change right after it.
  @ObservationIgnored fileprivate var pending: [Data] = []
  /// The color on the strip right now, nil when unknown (just connected, or an effect is running).
  @ObservationIgnored fileprivate var shown: [Double]?
  @ObservationIgnored fileprivate var fadeTimer: Timer?
  /// Gives up on a new pick that never answers.
  @ObservationIgnored fileprivate var connectTimer: Timer?
  /// Waits on the strip's first reply, then on the unlock.
  @ObservationIgnored fileprivate var handshakeTimer: Timer?
  @ObservationIgnored fileprivate var retryTimer: Timer?
  @ObservationIgnored fileprivate var unlocking = false

  // What the last connection learned, so the next one is quicker: discover only this service, and go straight to
  // the unlock for a strip that needs it instead of waiting out the silent status request.
  @ObservationIgnored fileprivate var service: CBUUID?
  @ObservationIgnored fileprivate var needsUnlock = false

  init(id: UUID) {
    self.id = id
    let hint = UserDefaults.standard.dictionary(forKey: Self.hintsKey)?[id.uuidString] as? [String: String] ?? [:]
    service = hint["service"].map(CBUUID.init(string:))
    needsUnlock = hint["unlock"] == "1"
  }

  fileprivate static let hintsKey = "stripHints"

  fileprivate func saveHint() {
    var all = UserDefaults.standard.dictionary(forKey: Self.hintsKey) ?? [:]
    var hint: [String: String] = ["unlock": needsUnlock ? "1" : "0"]
    if let service { hint["service"] = service.uuidString }
    all[id.uuidString] = hint
    UserDefaults.standard.set(all, forKey: Self.hintsKey)
  }
}

/// Every DayBetter strip you've added. Saved strips reconnect on their own; scanning only fills the setup list.
@Observable
final class StripController: NSObject {
  private(set) var strips: [Strip] = []
  /// Nearby devices that aren't saved strips, for the setup list.
  private(set) var devices: [FoundDevice] = []
  private(set) var bluetoothOn = false
  /// The strip just picked in setup. It joins `strips` once it connects, so a wrong pick is never saved.
  private(set) var adding: Strip?
  var log: [String] = []

  /// Per-channel balance so the strips' colors match the other lights. Saved; set from "Match colors".
  var balance: [Double] = UserDefaults.standard.array(forKey: "stripBalance") as? [Double] ?? Daybetter.defaultBalance {
    didSet { UserDefaults.standard.set(balance, forKey: "stripBalance") }
  }
  /// Called on the main queue whenever a strip reports its state.
  var onStatus: ((UUID, StripStatus) -> Void)?

  private var central: CBCentralManager!
  /// The setup sheet is open and wants the nearby list.
  private var listing = false

  private static let savedKey = "strips"
  /// The strip saved before the app handled more than one. It keeps its old light id, so its name, room,
  /// and spot on the map carry over.
  static let firstID = UserDefaults.standard.string(forKey: "stripPeripheralID").flatMap(UUID.init)

  override init() {
    super.init()
    let saved = UserDefaults.standard.stringArray(forKey: Self.savedKey).map { $0.compactMap(UUID.init) }
    strips = (saved ?? Self.firstID.map { [$0] } ?? []).map(Strip.init)
    // The restore identifier lets iOS keep pending connects alive and relaunch the app when a strip comes back
    // (Apple TN3115; not after a force-quit).
    central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "strips"])
  }

  func scan() {
    devices = []
    listing = true
    updateScan()
  }

  func stopScan() {
    listing = false
    updateScan()
  }

  /// Scans while setup is open, or while a saved strip hasn't been seen since launch.
  private func updateScan() {
    guard central.state == .poweredOn else { return }
    // The strip may not advertise its service, so scan everything.
    if listing || strips.contains(where: { $0.peripheral == nil }) {
      if !central.isScanning { central.scanForPeripherals(withServices: nil) }
    } else if central.isScanning {
      central.stopScan()
    }
  }

  func connect(_ device: FoundDevice) {
    cancelAdding()
    let strip = Strip(id: device.id)
    adding = strip
    devices.removeAll { $0.id == device.id }
    attach(strip, device.peripheral)
    // A saved strip waits forever for its strip to come back; a new pick that never answers should fail.
    strip.connectTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self, weak strip] _ in
      guard let self, let strip, self.adding === strip, strip.state != .connected else { return }
      if case .failed = strip.state { return }
      self.note("connection timed out")
      self.fail(strip, "Couldn't connect. Is the strip plugged in and close by? Close the DayBetter app if it's open.")
    }
  }

  /// Drops the strip being added, if any.
  func cancelAdding() {
    guard let strip = adding else { return }
    adding = nil
    stopTimers(strip)
    if let p = strip.peripheral { central.cancelPeripheralConnection(p) }
  }

  /// Pull to refresh: try every strip that isn't connected right now instead of waiting for its retry.
  func reconnectNow() {
    guard central.state == .poweredOn else { return }
    for strip in strips where strip.state != .connected {
      if case .connecting = strip.state { continue }
      strip.retryTimer?.invalidate()
      if let p = strip.peripheral { attach(strip, p) }
    }
    updateScan()
  }

  /// Forgets a strip.
  func remove(_ id: UUID) {
    guard let i = strips.firstIndex(where: { $0.id == id }) else { return }
    let strip = strips.remove(at: i)
    stopTimers(strip)
    if let p = strip.peripheral { central.cancelPeripheralConnection(p) }
    save()
    updateScan()
  }

  func setPower(_ id: UUID, _ on: Bool) { send(id, Daybetter.frame(Daybetter.power, [on ? 1 : 0])) }
  func setBrightness(_ id: UUID, _ percent: Int) { send(id, Daybetter.frame(Daybetter.brightness, [UInt8(max(1, min(100, percent)))])) }
  func setSpeed(_ id: UUID, _ percent: Int) { send(id, Daybetter.frame(Daybetter.speed, [UInt8(max(1, min(100, percent)))])) }

  /// How long a color change takes, to match the Hubspace bulbs' built-in fade (about 2 s).
  static let fadeTime = 2.0

  /// 3-byte RGB, gamma- and channel-corrected (grimsteel set_color). Fades from the current color like the bulbs do;
  /// the strip has no fade of its own, so the app sends steps. Queued steps coalesce, so a slow link just skips frames.
  func setColor(_ id: UUID, r: UInt8, g: UInt8, b: UInt8, fade: Bool = true) {
    guard let strip = lookup(id) else { return }
    strip.fadeTimer?.invalidate()
    let target = [Double(r), Double(g), Double(b)]
    guard fade, let from = strip.shown, from != target else {
      show(strip, target)
      return
    }
    let start = Date()
    strip.fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self, weak strip] timer in
      guard let self, let strip else { return timer.invalidate() }
      let p = min(1, Date().timeIntervalSince(start) / Self.fadeTime)
      let eased = p * p * (3 - 2 * p)
      self.show(strip, zip(from, target).map { $0 + ($1 - $0) * eased })
      if p >= 1 { timer.invalidate() }
    }
  }

  /// Built-in effects take one byte (grimsteel set_effect) and run on the strip after the app closes.
  func setPattern(_ id: UUID, _ pattern: UInt8) {
    guard let strip = lookup(id) else { return }
    strip.fadeTimer?.invalidate()
    strip.shown = nil
    send(id, Daybetter.frame(Daybetter.effect, [pattern]))
  }

  private func show(_ strip: Strip, _ c: [Double]) {
    strip.shown = c
    let byte = { (v: Double) in UInt8(max(0, min(255, v.rounded()))) }
    send(strip.id, Daybetter.frame(Daybetter.color, Daybetter.corrected(byte(c[0]), byte(c[1]), byte(c[2]), balance: balance)))
  }

  private func lookup(_ id: UUID) -> Strip? {
    adding?.id == id ? adding : strips.first { $0.id == id }
  }

  /// Connects, or picks up a link iOS kept alive while the app was away.
  private func attach(_ strip: Strip, _ p: CBPeripheral) {
    strip.peripheral = p
    p.delegate = self
    if p.state == .connected {
      strip.state = .connecting
      p.discoverServices(nil)
    } else {
      strip.state = .idle
      note("looking for \(p.name ?? p.identifier.uuidString)")
      // Waits until the strip is in range and powered, then completes on its own.
      central.connect(p)
    }
  }

  /// Shows the error. A saved strip tries again by itself; a new pick waits for "Try again".
  private func fail(_ strip: Strip, _ message: String) {
    stopTimers(strip)
    strip.state = .failed(message)
    guard let p = strip.peripheral else { return }
    central.cancelPeripheralConnection(p)
    guard adding !== strip else { return }
    retry(strip, p, after: 15)
  }

  private func retry(_ strip: Strip, _ p: CBPeripheral, after seconds: Double) {
    strip.retryTimer?.invalidate()
    strip.retryTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self, weak strip] _ in
      guard let self, let strip, self.strips.contains(where: { $0 === strip }), self.central.state == .poweredOn else { return }
      self.attach(strip, p)
    }
  }

  private func stopTimers(_ strip: Strip) {
    [strip.connectTimer, strip.handshakeTimer, strip.retryTimer, strip.fadeTimer].forEach { $0?.invalidate() }
    strip.unlocking = false
  }

  private func send(_ id: UUID, _ data: Data) {
    guard let strip = lookup(id), strip.state == .connected, let peripheral = strip.peripheral, let writeChar = strip.writeChar else { return }
    let canWrite = writeChar.properties.contains(.write) ? !strip.inFlight : peripheral.canSendWriteWithoutResponse
    guard canWrite else {
      strip.pending.removeAll { $0[1] == data[1] }
      strip.pending.append(data)
      return
    }
    if writeChar.properties.contains(.write) {
      strip.inFlight = true
      peripheral.writeValue(data, for: writeChar, type: .withResponse)
    } else {
      peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
    }
    note("→ " + hex(data))
  }

  /// Handshake writes skip the queue: nothing else goes out until the strip is ready.
  private func rawWrite(_ strip: Strip, _ data: Data) {
    guard let p = strip.peripheral, let w = strip.writeChar else { return }
    p.writeValue(data, for: w, type: w.properties.contains(.write) ? .withResponse : .withoutResponse)
    note("→ " + hex(data))
  }

  private func flushPending(_ strip: Strip) {
    guard !strip.pending.isEmpty else { return }
    send(strip.id, strip.pending.removeFirst())
  }

  /// Asks for the strip's status. A strip that answers is ready; one that stays silent may be a newer controller
  /// waiting for the CCHIP unlock, so try that next. Some controllers answer neither and still take commands.
  private func handshake(_ strip: Strip) {
    strip.handshakeTimer?.invalidate()
    if strip.needsUnlock {
      unlock(strip)
      return
    }
    rawWrite(strip, Daybetter.frame(Daybetter.status, [0x00]))
    strip.handshakeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self, weak strip] _ in
      guard let self, let strip, strip.state == .connecting else { return }
      self.note("no reply, trying the CCHIP unlock")
      self.unlock(strip)
    }
  }

  private func unlock(_ strip: Strip) {
    strip.unlocking = true
    rawWrite(strip, Daybetter.frame(Daybetter.challenge, Daybetter.cchip))
    strip.handshakeTimer?.invalidate()
    strip.handshakeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self, weak strip] _ in
      guard let self, let strip, strip.state == .connecting else { return }
      self.note("no unlock reply, sending commands anyway")
      strip.needsUnlock = false
      strip.saveHint()
      self.ready(strip)
    }
  }

  private func handle(_ strip: Strip, _ bytes: [UInt8]) {
    if strip.state == .connecting {
      if strip.unlocking, let answer = Daybetter.unlockAnswer(to: bytes) {
        rawWrite(strip, answer)
        // This strip does use the unlock, so a missing verdict is a failure, not old firmware.
        strip.handshakeTimer?.invalidate()
        strip.handshakeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self, weak strip] _ in
          guard let self, let strip, strip.state == .connecting else { return }
          self.fail(strip, "The strip didn't confirm the unlock. Open the log and share it.")
        }
        return
      }
      if strip.unlocking, let unlocked = Daybetter.unlockResult(bytes) {
        if unlocked {
          note("unlocked")
          strip.needsUnlock = true
          strip.saveHint()
          ready(strip)
        } else {
          fail(strip, "The strip refused the unlock. Unplug it for a few seconds, then try again.")
        }
        return
      }
      // Any reply means it takes commands without the unlock.
      if bytes.first == 0xA1, !strip.unlocking {
        strip.saveHint()
        ready(strip)
      }
    }
    if let status = StripStatus(bytes) { onStatus?(strip.id, status) }
  }

  private func ready(_ strip: Strip) {
    stopTimers(strip)
    strip.shown = nil
    strip.state = .connected
    if adding === strip {
      adding = nil
      strips.append(strip)
      save()
    }
    // Ask for the current state so the app matches whatever the remote or DayBetter app set.
    send(strip.id, Daybetter.frame(Daybetter.status, [0x00]))
  }

  private func save() {
    UserDefaults.standard.set(strips.map(\.id.uuidString), forKey: Self.savedKey)
  }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }

  private func note(_ line: String) {
    log.append(line)
    if log.count > 300 { log.removeFirst(log.count - 300) }
  }
}

extension StripController: CBCentralManagerDelegate {
  /// iOS relaunched the app for a strip; take back the links it kept.
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    for p in restored {
      guard let strip = strips.first(where: { $0.id == p.identifier }) else { continue }
      strip.peripheral = p
      p.delegate = self
    }
    note("restored \(restored.count) strip link(s)")
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    bluetoothOn = central.state == .poweredOn
    guard bluetoothOn else {
      note("bluetooth state \(central.state.rawValue)")
      // Turning Bluetooth off drops every link without a disconnect callback.
      for strip in strips {
        stopTimers(strip)
        strip.writeChar = nil
        strip.notifyChar = nil
        strip.inFlight = false
        strip.pending = []
        strip.state = .idle
      }
      return
    }
    // Reconnect to every saved strip. Any the system no longer knows turn up in the scan instead.
    let known = central.retrievePeripherals(withIdentifiers: strips.map(\.id))
    for strip in strips {
      if let p = known.first(where: { $0.identifier == strip.id }) ?? strip.peripheral { attach(strip, p) }
    }
    updateScan()
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    // A saved strip the system had forgotten came back into range.
    if let strip = strips.first(where: { $0.id == peripheral.identifier }) {
      if strip.peripheral == nil {
        attach(strip, peripheral)
        updateScan()
      }
      return
    }
    guard listing, adding?.id != peripheral.identifier else { return }
    let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let daybetter = Daybetter.advertisesStrip(services)
    let advertised = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
    guard let name = advertised.flatMap({ $0.isEmpty ? nil : $0 }) ?? (daybetter ? "DayBetter strip" : nil) else { return }
    if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
      devices[i].rssi = RSSI.intValue
      devices[i].daybetter = devices[i].daybetter || daybetter
    } else {
      devices.append(FoundDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral, daybetter: daybetter))
    }
    devices.sort { $0.rssi > $1.rssi }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    let strip = lookup(peripheral.identifier)
    strip?.state = .connecting
    // A known strip only needs its own service looked up, which is faster than listing them all.
    let known = strip?.service.map { [$0] }
    note(known == nil ? "connected, discovering services" : "connected, looking up \(known![0].uuidString)")
    peripheral.discoverServices(known)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    note("connect failed: \(error?.localizedDescription ?? "unknown")")
    guard let strip = lookup(peripheral.identifier) else { return }
    // Apple publishes no connection limit; it depends on the phone and on other apps' Bluetooth devices.
    if (error as? CBError)?.code == .connectionLimitReached {
      fail(strip, "Your phone has too many Bluetooth devices connected. Remove a light or close another Bluetooth app.")
    } else if adding === strip {
      fail(strip, error?.localizedDescription ?? "Couldn't connect")
    } else {
      strip.state = .idle
      retry(strip, peripheral, after: 3)
    }
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    note("disconnected \(error?.localizedDescription ?? "")")
    guard let strip = lookup(peripheral.identifier) else { return }
    strip.writeChar = nil
    strip.notifyChar = nil
    strip.inFlight = false
    strip.pending = []
    strip.fadeTimer?.invalidate()
    strip.handshakeTimer?.invalidate()
    strip.unlocking = false
    // Keep an error on screen; a saved strip's retry is already scheduled.
    if case .failed = strip.state { return }
    if adding === strip {
      fail(strip, "The strip disconnected. Try again.")
      return
    }
    // The strip dropped (unplugged, out of range): wait for it to come back.
    strip.state = .idle
    central.connect(peripheral)
  }
}

extension StripController: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let strip = lookup(peripheral.identifier) else { return }
    let services = peripheral.services ?? []
    note("services: " + services.map(\.uuid.uuidString).joined(separator: ", "))
    let usable = services.filter { Daybetter.characteristics(for: $0.uuid) != nil }
    // The remembered service is gone (controller swapped?): forget it and list everything.
    if strip.service != nil, usable.isEmpty {
      strip.service = nil
      strip.saveHint()
      peripheral.discoverServices(nil)
      return
    }
    guard let service = usable.first(where: { !Daybetter.isSegmentController($0.uuid) }) else {
      fail(strip, usable.isEmpty
        ? "No Daybetter service found. Open the log and share it."
        : "This is a DayBetter \"Magic Light\" segment controller. It uses different commands, so Dorm Remote can't run it yet.")
      return
    }
    note("using service \(service.uuid.uuidString)")
    strip.service = service.uuid
    peripheral.discoverCharacteristics(nil, for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let strip = lookup(peripheral.identifier) else { return }
    let chars = service.characteristics ?? []
    for c in chars { note("char \(c.uuid.uuidString) props \(c.properties.rawValue)") }
    let expected = Daybetter.characteristics(for: service.uuid)
    let writable = { (c: CBCharacteristic) in c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) }
    strip.writeChar = chars.first { $0.uuid == expected?.write && writable($0) } ?? chars.first(where: writable)
    strip.notifyChar = chars.first { $0.uuid == expected?.notify } ?? chars.first { $0.properties.contains(.notify) }
    guard strip.writeChar != nil else {
      fail(strip, "No writable characteristic. Open the log and share it.")
      return
    }
    if let notifyChar = strip.notifyChar {
      peripheral.setNotifyValue(true, for: notifyChar)
    } else {
      // Nothing can come back, so there's nothing to wait for.
      ready(strip)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    if let error { note("notify error: \(error.localizedDescription)") }
    guard let strip = lookup(peripheral.identifier), strip.state == .connecting else { return }
    handshake(strip)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let value = characteristic.value, let strip = lookup(peripheral.identifier) else { return }
    note("← " + hex(value))
    handle(strip, [UInt8](value))
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error { note("write error: \(error.localizedDescription)") }
    guard let strip = lookup(peripheral.identifier) else { return }
    strip.inFlight = false
    flushPending(strip)
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    if let strip = lookup(peripheral.identifier) { flushPending(strip) }
  }
}
