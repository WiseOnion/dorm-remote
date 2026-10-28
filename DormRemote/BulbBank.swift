import CoreBluetooth
import Foundation
import Observation

/// Cheap Bluetooth bulbs with published protocols: fully local, no cloud, no Wi-Fi.
/// ELK-BLEDOM ("Lotus Lamp" app): dave-code-ruiz/elkbledom models.json, FergusInLondon/ELK-BLEDOM.
/// Triones ("Happy Lighting" app): madhead/saberlight protocols/Triones/protocol.md.
enum BulbProtocol: String, Codable {
  case elk, triones

  static func detect(_ name: String) -> BulbProtocol? {
    let upper = name.uppercased()
    if upper.hasPrefix("ELK-") { return .elk }
    if upper.hasPrefix("TRIONES") { return .triones }
    return nil
  }

  var service: CBUUID { CBUUID(string: self == .elk ? "FFF0" : "FFD5") }
  var write: CBUUID { CBUUID(string: self == .elk ? "FFF3" : "FFD9") }

  func power(_ on: Bool) -> [Data] {
    switch self {
    case .elk: [Data(on ? [0x7E, 0x00, 0x04, 0xF0, 0x00, 0x01, 0xFF, 0x00, 0xEF] : [0x7E, 0x00, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF])]
    case .triones: [Data([0xCC, on ? 0x23 : 0x24, 0x33])]
    }
  }

  /// Triones has no brightness command, so its color is scaled instead.
  func color(_ c: RGB, brightness: Int) -> [Data] {
    switch self {
    case .elk:
      return [Data([0x7E, 0x00, 0x05, 0x03, UInt8(c.r), UInt8(c.g), UInt8(c.b), 0x0A, 0xEF]), level(brightness)]
    case .triones:
      let s = { (v: Int) in UInt8(min(255, v * max(1, brightness) / 100)) }
      return [Data([0x56, s(c.r), s(c.g), s(c.b), 0x00, 0xF0, 0xAA])]
    }
  }

  func white(_ kelvin: Int, brightness: Int) -> [Data] {
    switch self {
    case .elk:
      let cold = max(0, min(100, (kelvin - 2700) * 100 / 3800))
      return [Data([0x7E, 0x00, 0x05, 0x02, UInt8(100 - cold), UInt8(cold), 0x00, 0x00, 0xEF]), level(brightness)]
    case .triones:
      // The white channel is a single warm-white LED; cooler temperatures mix RGB instead.
      if kelvin <= 3200 { return [Data([0x56, 0x00, 0x00, 0x00, UInt8(max(1, brightness) * 255 / 100), 0x0F, 0xAA])] }
      return color(RGB.kelvin(kelvin), brightness: brightness)
    }
  }

  private func level(_ brightness: Int) -> Data {
    Data([0x7E, 0x00, 0x01, UInt8(max(1, min(100, brightness))), 0x00, 0x00, 0x00, 0x00, 0xEF])
  }
}

struct SavedBulb: Codable, Identifiable {
  let id: UUID
  var name: String
  let kind: BulbProtocol
  var on = true
  var brightness = 100
  var color = RGB.white
  var kelvin: Int?
}

@Observable
final class BulbBank: NSObject {
  private(set) var bulbs: [SavedBulb] = {
    guard let data = UserDefaults.standard.data(forKey: "bleBulbs") else { return [] }
    return (try? JSONDecoder().decode([SavedBulb].self, from: data)) ?? []
  }()
  private(set) var connected: Set<UUID> = []
  private(set) var nearby: [FoundDevice] = []
  private(set) var scanning = false
  var log: [String] = []
  /// Called on the main queue when a saved bulb is ready. Walk in uses it to light bulbs that connect late.
  var onConnect: (() -> Void)?

  private var central: CBCentralManager!
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var writers: [UUID: CBCharacteristic] = [:]

  override init() {
    super.init()
    // Restore identifier: iOS keeps pending connects and relaunches the app for them (Apple TN3115).
    central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "bulbs"])
  }

  func scan() {
    guard central.state == .poweredOn else { return }
    nearby = []
    scanning = true
    central.scanForPeripherals(withServices: nil)
  }

  func stopScan() {
    scanning = false
    central.stopScan()
  }

  func add(_ device: FoundDevice) {
    guard let kind = BulbProtocol.detect(device.name), !bulbs.contains(where: { $0.id == device.id }) else { return }
    bulbs.append(SavedBulb(id: device.id, name: device.name, kind: kind))
    save()
    attach(device.peripheral)
  }

  func remove(_ id: UUID) {
    if let p = peripherals[id] { central.cancelPeripheralConnection(p) }
    bulbs.removeAll { $0.id == id }
    peripherals[id] = nil
    writers[id] = nil
    connected.remove(id)
    save()
  }

  func setPower(_ id: UUID, _ on: Bool) {
    update(id) { $0.on = on }
    send(id) { $0.kind.power(on) }
  }

  func setBrightness(_ id: UUID, _ value: Int) {
    update(id) { $0.brightness = value; $0.on = true }
    send(id) { b in b.kelvin.map { b.kind.white($0, brightness: value) } ?? b.kind.color(b.color, brightness: value) }
  }

  func setColor(_ id: UUID, _ c: RGB) {
    update(id) { $0.color = c; $0.kelvin = nil; $0.on = true }
    send(id) { $0.kind.color(c, brightness: $0.brightness) }
  }

  func setWhite(_ id: UUID, _ kelvin: Int) {
    update(id) { $0.kelvin = kelvin; $0.on = true }
    send(id) { $0.kind.white(kelvin, brightness: $0.brightness) }
  }

  /// One frame of an effect: just the color, nothing saved, no power command. The look from before stays saved.
  func stream(_ id: UUID, _ c: RGB) {
    guard let bulb = bulbs.first(where: { $0.id == id }), let p = peripherals[id], let w = writers[id] else { return }
    let frames = bulb.kind == .elk ? [Data([0x7E, 0x00, 0x05, 0x03, UInt8(c.r), UInt8(c.g), UInt8(c.b), 0x0A, 0xEF])] : bulb.kind.color(c, brightness: 100)
    for frame in frames { p.writeValue(frame, for: w, type: w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse) }
  }

  private func update(_ id: UUID, _ change: (inout SavedBulb) -> Void) {
    guard let i = bulbs.firstIndex(where: { $0.id == id }) else { return }
    change(&bulbs[i])
    save()
  }

  private func send(_ id: UUID, _ frames: (SavedBulb) -> [Data]) {
    guard let bulb = bulbs.first(where: { $0.id == id }), let p = peripherals[id], let w = writers[id] else { return }
    // Changing a look on a light that's off turns it on, like the other lights.
    let all = (bulb.on ? bulb.kind.power(true) : []) + frames(bulb)
    let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    for frame in all { p.writeValue(frame, for: w, type: type) }
  }

  private func attach(_ p: CBPeripheral) {
    peripherals[p.identifier] = p
    p.delegate = self
    // A link iOS kept while the app was away only needs its characteristic found again.
    if p.state == .connected, let kind = bulbs.first(where: { $0.id == p.identifier })?.kind {
      p.discoverServices([kind.service])
    } else {
      central.connect(p)
    }
  }

  private func save() {
    UserDefaults.standard.set(try? JSONEncoder().encode(bulbs), forKey: "bleBulbs")
  }

  private func note(_ line: String) {
    log.append("bulbs: " + line)
    if log.count > 100 { log.removeFirst(log.count - 100) }
  }
}

extension BulbBank: CBCentralManagerDelegate {
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    for p in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] where bulbs.contains(where: { $0.id == p.identifier }) {
      peripherals[p.identifier] = p
      p.delegate = self
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state == .poweredOn else {
      // Bluetooth off drops every link without a disconnect callback.
      connected = []
      writers = [:]
      return
    }
    // A pending connect waits until the bulb is in range and powered, then completes on its own.
    for p in central.retrievePeripherals(withIdentifiers: bulbs.map(\.id)) { attach(p) }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
    guard let name, BulbProtocol.detect(name) != nil, !bulbs.contains(where: { $0.id == peripheral.identifier }) else { return }
    if let i = nearby.firstIndex(where: { $0.id == peripheral.identifier }) {
      nearby[i].rssi = RSSI.intValue
    } else {
      nearby.append(FoundDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, peripheral: peripheral))
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let kind = bulbs.first(where: { $0.id == peripheral.identifier })?.kind else { return }
    peripheral.discoverServices([kind.service])
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    connected.remove(peripheral.identifier)
    writers[peripheral.identifier] = nil
    // Keep trying: the bulb may just be switched off at the wall.
    if bulbs.contains(where: { $0.id == peripheral.identifier }) { central.connect(peripheral) }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    if bulbs.contains(where: { $0.id == peripheral.identifier }) { central.connect(peripheral) }
  }
}

extension BulbBank: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let kind = bulbs.first(where: { $0.id == peripheral.identifier })?.kind,
          let w = service.characteristics?.first(where: { $0.uuid == kind.write }) else { return }
    writers[peripheral.identifier] = w
    connected.insert(peripheral.identifier)
    note("connected \(peripheral.name ?? "bulb")")
    onConnect?()
  }
}
