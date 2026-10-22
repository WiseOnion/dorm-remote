import CoreBluetooth
import Foundation
import Observation

/// Daybetter RGB strips over Bluetooth LE, copied from grimsteel/daybetter-led-strip, which was written for this
/// exact controller (service E031, write A031, notify F031).
/// Frame: A0 <cmd> <payloadLen+3> <payload…> <CRC-16/MODBUS, low byte first>; replies start with A1.
enum Daybetter {
  static let status: UInt8 = 0x10
  static let power: UInt8 = 0x11
  static let effect: UInt8 = 0x12
  static let brightness: UInt8 = 0x13
  static let color: UInt8 = 0x15

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

  /// DayBetter names its strips by model code, e.g. P031_3712.
  static func looksLikeStrip(_ name: String) -> Bool {
    let upper = name.uppercased()
    return upper.wholeMatch(of: #/P0[0-9A-F]{2}_.*/#) != nil
      || ["SMART LIGHT", "MAGIC LIGHT", "DAYBETTER", "CCHIP"].contains { upper.contains($0) }
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
}

@Observable
final class StripController: NSObject {
  enum State: Equatable { case off, idle, scanning, connecting, unlocking, connected, failed(String) }

  var state: State = .off
  var devices: [FoundDevice] = []
  var log: [String] = []
  var connectedName: String?

  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?
  private var notifyChar: CBCharacteristic?
  private var inFlight = false
  // ponytail: one queued command per command type, newest wins, so dragging a slider never floods
  // the strip and a tap on "On" isn't dropped by a color change right after it.
  private var pending: [Data] = []
  /// Per-channel balance so the strip's colors match the other lights. Saved; set from "Match colors".
  var balance: [Double] = UserDefaults.standard.array(forKey: "stripBalance") as? [Double] ?? Daybetter.defaultBalance {
    didSet { UserDefaults.standard.set(balance, forKey: "stripBalance") }
  }
  /// Called on the main queue whenever the strip reports its state.
  var onStatus: ((StripStatus) -> Void)?
  private var connectTimer: Timer?
  /// The user tapped Disconnect; don't reconnect on our own.
  private var userDisconnected = false

  private static let savedKey = "stripPeripheralID"

  /// A strip was picked before, so the app should find it on its own.
  var hasSaved: Bool { UserDefaults.standard.string(forKey: Self.savedKey) != nil }

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func scan() {
    guard central.state == .poweredOn else { return }
    if let peripheral, state != .connected { central.cancelPeripheralConnection(peripheral) }
    devices = []
    state = .scanning
    // The strip may not advertise its service, so scan everything and let the user pick.
    central.scanForPeripherals(withServices: nil)
  }

  func connect(_ device: FoundDevice) {
    central.stopScan()
    userDisconnected = false
    attach(device.peripheral)
  }

  func disconnect() {
    userDisconnected = true
    UserDefaults.standard.removeObject(forKey: Self.savedKey)
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
  }

  /// Stops a connection attempt that is taking too long and goes back to the device list.
  func cancelConnecting() {
    connectTimer?.invalidate()
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
    scan()
  }

  func setPower(_ on: Bool) { send(Daybetter.frame(Daybetter.power, [on ? 1 : 0])) }
  func setBrightness(_ percent: Int) { send(Daybetter.frame(Daybetter.brightness, [UInt8(max(1, min(100, percent)))])) }

  /// 3-byte RGB, gamma- and channel-corrected (grimsteel set_color).
  func setColor(r: UInt8, g: UInt8, b: UInt8) {
    send(Daybetter.frame(Daybetter.color, Daybetter.corrected(r, g, b, balance: balance)))
  }

  /// Built-in effects take one byte (grimsteel set_effect) and run on the strip after the app closes.
  func setPattern(_ id: UInt8) {
    send(Daybetter.frame(Daybetter.effect, [id]))
  }

  private func attach(_ p: CBPeripheral) {
    peripheral = p
    p.delegate = self
    state = .connecting
    note("connecting to \(p.name ?? p.identifier.uuidString)")
    central.connect(p)
    // CoreBluetooth waits forever for a strip that's out of range or unplugged.
    connectTimer?.invalidate()
    connectTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
      guard let self, self.state == .connecting else { return }
      self.note("connection timed out")
      self.cancelConnecting()
    }
  }

  private func fail(_ message: String) {
    connectTimer?.invalidate()
    state = .failed(message)
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
  }

  private func send(_ data: Data) {
    guard state == .connected, let peripheral, let writeChar else { return }
    let canWrite = writeChar.properties.contains(.write) ? !inFlight : peripheral.canSendWriteWithoutResponse
    guard canWrite else {
      pending.removeAll { $0[1] == data[1] }
      pending.append(data)
      return
    }
    if writeChar.properties.contains(.write) {
      inFlight = true
      peripheral.writeValue(data, for: writeChar, type: .withResponse)
    } else {
      peripheral.writeValue(data, for: writeChar, type: .withoutResponse)
    }
    note("→ " + hex(data))
  }

  private func flushPending() {
    guard !pending.isEmpty else { return }
    send(pending.removeFirst())
  }

  private func ready() {
    connectTimer?.invalidate()
    state = .connected
    connectedName = peripheral?.name
    if let peripheral { UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedKey) }
    // Ask for the current state so the app matches whatever the remote or DayBetter app set.
    send(Daybetter.frame(Daybetter.status, [0x00]))
  }

  private func handle(_ bytes: [UInt8]) {
    if let status = StripStatus(bytes) { onStatus?(status) }
  }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: " ") }

  private func note(_ line: String) {
    log.append(line)
    if log.count > 300 { log.removeFirst(log.count - 300) }
  }
}

extension StripController: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state == .poweredOn else {
      state = .off
      note("bluetooth state \(central.state.rawValue)")
      return
    }
    state = .idle
    // Reconnect to the strip picked last time.
    if let saved = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init),
       let p = central.retrievePeripherals(withIdentifiers: [saved]).first {
      attach(p)
    } else {
      scan()
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
    // The saved strip came back into range or finished booting.
    if state == .scanning, peripheral.identifier.uuidString == UserDefaults.standard.string(forKey: Self.savedKey) {
      central.stopScan()
      attach(peripheral)
      return
    }
    guard let name, !name.isEmpty else { return }
    if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
      devices[i].rssi = RSSI.intValue
    } else {
      devices.append(FoundDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral))
    }
    devices.sort { $0.rssi > $1.rssi }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    note("connected, discovering services")
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    note("connect failed: \(error?.localizedDescription ?? "unknown")")
    fail(error?.localizedDescription ?? "Couldn't connect")
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    writeChar = nil
    notifyChar = nil
    connectedName = nil
    inFlight = false
    pending = []
    note("disconnected \(error?.localizedDescription ?? "")")
    // Keep an error on screen, and don't fight a scan the user started.
    if case .failed = state { return }
    if state == .scanning { return }
    let wasConnected = state == .connected
    state = .idle
    // The strip dropped (unplugged, out of range): try again until it's back or the user picks another.
    if wasConnected, !userDisconnected { attach(peripheral) }
  }
}

extension StripController: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let services = peripheral.services ?? []
    note("services: " + services.map(\.uuid.uuidString).joined(separator: ", "))
    guard let service = services.first(where: { Daybetter.characteristics(for: $0.uuid) != nil }) else {
      fail("No Daybetter service found. Open the log and share it.")
      return
    }
    note("using service \(service.uuid.uuidString)")
    peripheral.discoverCharacteristics(nil, for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let chars = service.characteristics ?? []
    for c in chars { note("char \(c.uuid.uuidString) props \(c.properties.rawValue)") }
    let expected = Daybetter.characteristics(for: service.uuid)
    let writable = { (c: CBCharacteristic) in c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) }
    writeChar = chars.first { $0.uuid == expected?.write && writable($0) } ?? chars.first(where: writable)
    notifyChar = chars.first { $0.uuid == expected?.notify } ?? chars.first { $0.properties.contains(.notify) }
    guard writeChar != nil else {
      fail("No writable characteristic. Open the log and share it.")
      return
    }
    if let notifyChar {
      peripheral.setNotifyValue(true, for: notifyChar)
    } else {
      ready()
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    if let error { note("notify error: \(error.localizedDescription)") }
    // grimsteel needs no unlock step: enable notifications and start sending.
    guard state == .connecting else { return }
    ready()
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let value = characteristic.value else { return }
    note("← " + hex(value))
    handle([UInt8](value))
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error { note("write error: \(error.localizedDescription)") }
    inFlight = false
    flushPending()
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    flushPending()
  }
}
