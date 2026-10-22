import CoreBluetooth
import Foundation
import Observation

/// Daybetter "QC" (whole-strip RGB) controllers over Bluetooth LE.
/// Frame: A0 <cmd> <payloadLen+3> <payload…> <CRC-16/MODBUS, low byte first>; replies start with A1.
/// Protocol: DoudGeorges/daybetter-leds PROTOCOL.md, grimsteel/daybetter-led-strip, homebridge-daybetter.
enum Daybetter {
  static let power: UInt8 = 0x11
  static let mode: UInt8 = 0x12
  static let brightness: UInt8 = 0x13
  static let color: UInt8 = 0x15
  static let status: UInt8 = 0x10
  static let speed: UInt8 = 0x16
  static let sensitivity: UInt8 = 0x17
  static let rhythm: UInt8 = 0x21
  /// Mode id for the controller's own microphone; the sub-mode picks the style (0 Classic … 3 Disco).
  static let micMode: UInt8 = 160

  /// DayBetter names its strips by model code, e.g. P031_3712.
  static func looksLikeStrip(_ name: String) -> Bool {
    let upper = name.uppercased()
    return upper.wholeMatch(of: #/P0[0-9A-F]{2}_.*/#) != nil
      || ["SMART LIGHT", "MAGIC LIGHT", "DAYBETTER", "CCHIP"].contains { upper.contains($0) }
  }
  static let cchip: [UInt8] = Array("CCHIP".utf8)

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

/// What the strip reports about itself (also after IR remote presses).
struct StripStatus: Equatable {
  var on: Bool
  var mode: UInt8
  var subMode: UInt8
  var brightness: Int
  /// The color as commanded, undoing the strip's brightness scaling.
  var r: Int, g: Int, b: Int

  /// Status reply: A1 10 <len> power mode subMode brightness speed sensitivity R G B W …
  /// The strip reports R,G,B already scaled by brightness (PsychedelicPalimpsest gateway, verified on a P065).
  init?(_ bytes: [UInt8]) {
    guard bytes.count >= 14, bytes[0] == 0xA1, bytes[1] == Daybetter.status else { return nil }
    on = bytes[3] != 0
    mode = bytes[4]
    subMode = bytes[5]
    brightness = max(1, min(100, Int(bytes[6])))
    let unscale = { (v: UInt8) in min(255, Int((Double(v) * 100 / Double(max(1, Int(bytes[6])))).rounded())) }
    r = unscale(bytes[9]); g = unscale(bytes[10]); b = unscale(bytes[11])
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
  private var rhythmOn = false
  /// Called on the main queue whenever the strip reports its state.
  var onStatus: ((StripStatus) -> Void)?
  private var handshakeTimer: Timer?
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

  /// Same sequence as the DayBetter app: solid-color mode, then R G B with the 4th byte FF.
  /// A 3-byte color makes some controllers read the checksum as the 4th byte, so only some colors come out right.
  func setColor(r: UInt8, g: UInt8, b: UInt8) {
    stopRhythm()
    send(Daybetter.frame(Daybetter.mode, [0x01, 0x00]))
    send(Daybetter.frame(Daybetter.color, [r, g, b, 0xFF]))
  }

  /// Built-in patterns run on the strip itself, so they keep going after the app closes.
  func setPattern(_ id: UInt8) {
    stopRhythm()
    send(Daybetter.frame(Daybetter.mode, [id, 0xFF]))
  }

  func setSpeed(_ percent: Int) { send(Daybetter.frame(Daybetter.speed, [UInt8(max(1, min(100, percent)))])) }
  func setSensitivity(_ value: Int) { send(Daybetter.frame(Daybetter.sensitivity, [UInt8(max(0, min(255, value)))])) }

  /// Music from the microphone in the strip's controller.
  func setMicMusic(style: UInt8) {
    send(Daybetter.frame(Daybetter.mode, [Daybetter.micMode, style]))
    send(Daybetter.frame(Daybetter.rhythm, [0x01]))
    rhythmOn = true
  }

  private func stopRhythm() {
    guard rhythmOn else { return }
    send(Daybetter.frame(Daybetter.rhythm, [0x00]))
    rhythmOn = false
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
      guard let self, self.state == .connecting || self.state == .unlocking else { return }
      self.note("connection timed out")
      self.cancelConnecting()
    }
  }

  private func fail(_ message: String) {
    connectTimer?.invalidate()
    handshakeTimer?.invalidate()
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

  /// Handshake writes skip the queue; nothing else is sent until the strip is unlocked.
  private func rawWrite(_ data: Data) {
    guard let peripheral, let writeChar else { return }
    let type: CBCharacteristicWriteType = writeChar.properties.contains(.write) ? .withResponse : .withoutResponse
    peripheral.writeValue(data, for: writeChar, type: type)
    note("→ " + hex(data))
  }

  private func flushPending() {
    guard !pending.isEmpty else { return }
    send(pending.removeFirst())
  }

  private func ready() {
    handshakeTimer?.invalidate()
    connectTimer?.invalidate()
    state = .connected
    connectedName = peripheral?.name
    if let peripheral { UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedKey) }
    // Ask for the current state so the app matches whatever the remote or DayBetter app set.
    send(Daybetter.frame(Daybetter.status, [0x01]))
  }

  private func startHandshake() {
    state = .unlocking
    rawWrite(Daybetter.frame(0x00, Daybetter.cchip))
    // Older firmware never answers the challenge and needs no unlock.
    handshakeTimer?.invalidate()
    handshakeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
      guard let self, self.state == .unlocking else { return }
      self.note("no CCHIP reply, continuing without unlock")
      self.ready()
    }
  }

  private func handle(_ bytes: [UInt8]) {
    guard bytes.count >= 4, bytes[0] == 0xA1 else { return }
    switch bytes[1] {
    case 0x00 where state == .unlocking && bytes.count >= 10:
      let response = Daybetter.cchip + [bytes[8] ^ 36, bytes[9] ^ 76]
      rawWrite(Daybetter.frame(0x01, response))
      // This strip does use the unlock, so a missing confirmation is a failure, not old firmware.
      handshakeTimer?.invalidate()
      handshakeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
        guard let self, self.state == .unlocking else { return }
        self.fail("The strip didn't confirm the unlock. Open the log and share it.")
      }
    case 0x01 where state == .unlocking && bytes.count >= 9:
      if bytes[8] == 0 {
        note("unlocked")
        ready()
      } else {
        fail("The strip rejected the unlock. Open the log and share it.")
      }
    case Daybetter.status:
      if let status = StripStatus(bytes) { onStatus?(status) }
    default:
      break
    }
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
    handshakeTimer?.invalidate()
    writeChar = nil
    notifyChar = nil
    connectedName = nil
    inFlight = false
    pending = []
    rhythmOn = false
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
    guard state == .connecting else { return }
    startHandshake()
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
