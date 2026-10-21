import CoreBluetooth
import Foundation
import Observation

/// Daybetter strip over Bluetooth LE.
/// Frame: A0 <cmd> <payloadLen+3> <payload…> <CRC-16/MODBUS, low byte first>.
/// Commands come from homebridge-daybetter; the checksum was identified by matching its captured frames.
enum Daybetter {
  static let service = CBUUID(string: "E026")
  static let power: UInt8 = 0x11
  static let brightness: UInt8 = 0x13
  static let color: UInt8 = 0x15

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

struct FoundDevice: Identifiable {
  let id: UUID
  let name: String
  var rssi: Int
  let peripheral: CBPeripheral
}

@Observable
final class StripController: NSObject {
  enum State: Equatable { case off, idle, scanning, connecting, connected, failed(String) }

  var state: State = .off
  var devices: [FoundDevice] = []
  var log: [String] = []
  var connectedName: String?

  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var characteristic: CBCharacteristic?
  // ponytail: only the newest unsent command is kept, so dragging a slider never floods the strip.
  private var inFlight = false
  private var pending: Data?

  private static let savedKey = "stripPeripheralID"

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func scan() {
    guard central.state == .poweredOn else { return }
    devices = []
    state = .scanning
    // The strip may not advertise its service, so scan everything and let the user pick.
    central.scanForPeripherals(withServices: nil)
  }

  func connect(_ device: FoundDevice) {
    central.stopScan()
    attach(device.peripheral)
  }

  func disconnect() {
    if let peripheral { central.cancelPeripheralConnection(peripheral) }
    UserDefaults.standard.removeObject(forKey: Self.savedKey)
  }

  func setPower(_ on: Bool) { send(Daybetter.frame(Daybetter.power, [on ? 1 : 0])) }
  func setBrightness(_ percent: Int) { send(Daybetter.frame(Daybetter.brightness, [UInt8(max(1, min(100, percent)))])) }
  func setColor(r: UInt8, g: UInt8, b: UInt8) { send(Daybetter.frame(Daybetter.color, [r, g, b])) }

  private func attach(_ p: CBPeripheral) {
    peripheral = p
    p.delegate = self
    state = .connecting
    note("connecting to \(p.name ?? p.identifier.uuidString)")
    central.connect(p)
  }

  private func send(_ data: Data) {
    guard let peripheral, let characteristic else { return }
    if characteristic.properties.contains(.write) {
      if inFlight { pending = data; return }
      inFlight = true
      peripheral.writeValue(data, for: characteristic, type: .withResponse)
    } else {
      guard peripheral.canSendWriteWithoutResponse else { pending = data; return }
      peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }
    note("→ " + data.map { String(format: "%02X", $0) }.joined(separator: " "))
  }

  private func flushPending() {
    guard let next = pending else { return }
    pending = nil
    send(next)
  }

  private func note(_ line: String) {
    log.append(line)
    if log.count > 200 { log.removeFirst(log.count - 200) }
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
    guard let name, !name.isEmpty else { return }
    if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
      devices[i].rssi = RSSI.intValue
    } else {
      devices.append(FoundDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral))
    }
    devices.sort { $0.rssi > $1.rssi }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    note("connected, looking for service E026")
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    state = .failed(error?.localizedDescription ?? "Couldn't connect")
    note("connect failed: \(error?.localizedDescription ?? "unknown")")
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    characteristic = nil
    connectedName = nil
    inFlight = false
    pending = nil
    state = .idle
    note("disconnected \(error?.localizedDescription ?? "")")
  }
}

extension StripController: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let services = peripheral.services ?? []
    note("services: " + services.map(\.uuid.uuidString).joined(separator: ", "))
    guard let service = services.first(where: { $0.uuid == Daybetter.service }) else {
      state = .failed("This strip doesn't use service E026. Open the log and screenshot it.")
      return
    }
    peripheral.discoverCharacteristics(nil, for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let chars = service.characteristics ?? []
    for c in chars { note("char \(c.uuid.uuidString) props \(c.properties.rawValue)") }
    guard let writable = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) else {
      state = .failed("No writable characteristic in E026")
      return
    }
    characteristic = writable
    connectedName = peripheral.name
    state = .connected
    UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedKey)
    note("using \(writable.uuid.uuidString)")
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
