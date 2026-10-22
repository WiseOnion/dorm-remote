import CoreBluetooth
import Foundation
import Observation

/// A projector remote button. Default codes come from the Flipper IRDB file
/// LED_Lighting/HLKZine/Astronaut_Star_Projector.ir (NEC-extended, address 07 FD).
struct IRButton: Identifiable {
  let id: String
  let name: String
  let icon: String
  let command: UInt8
}

/// Talks to the DormBridge board (firmware/), which turns Bluetooth commands into infrared.
@Observable
final class BridgeController: NSObject {
  enum State: Equatable { case off, searching, connecting, ready }

  static let service = CBUUID(string: "DB00")
  static let commandChar = CBUUID(string: "DB01")
  static let replyChar = CBUUID(string: "DB02")
  static let address: [UInt8] = [0x07, 0xFD]

  static let buttons: [IRButton] = [
    IRButton(id: "power", name: "Power", icon: "power", command: 0xFF),
    IRButton(id: "nebula", name: "Nebula", icon: "sparkles", command: 0x03),
    IRButton(id: "timer", name: "Timer", icon: "timer", command: 0x0B),
    IRButton(id: "brightUp", name: "Brighter", icon: "sun.max", command: 0x01),
    IRButton(id: "brightDown", name: "Dimmer", icon: "sun.min", command: 0x05),
    IRButton(id: "speedUp", name: "Faster", icon: "hare", command: 0x04),
    IRButton(id: "speedDown", name: "Slower", icon: "tortoise", command: 0x02),
    IRButton(id: "starsPower", name: "Stars", icon: "star", command: 0x0F),
    IRButton(id: "starsMode", name: "Star mode", icon: "star.circle", command: 0x0E),
    IRButton(id: "starsUp", name: "Stars +", icon: "plus.circle", command: 0x0D),
    IRButton(id: "starsDown", name: "Stars −", icon: "minus.circle", command: 0x0C),
    IRButton(id: "reset", name: "Reset", icon: "arrow.counterclockwise", command: 0x1A),
  ]

  private(set) var state = State.off
  /// The button waiting for a code from the real remote.
  private(set) var learning: String?
  private(set) var learned: [String: Data] = UserDefaults.standard.dictionary(forKey: "irLearned") as? [String: Data] ?? [:]
  var log: [String] = []

  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func press(_ button: IRButton) {
    if let code = learned[button.id] {
      write([0x02] + code)
    } else {
      write([0x01] + Self.address + [button.command])
    }
  }

  /// The next code the bridge's IR receiver sees gets saved for this button.
  func learn(_ button: IRButton) {
    learning = button.id
    write([0x10])
  }

  func cancelLearning() { learning = nil }

  func forgetLearned() {
    learned = [:]
    UserDefaults.standard.removeObject(forKey: "irLearned")
  }

  private func write(_ bytes: [UInt8]) {
    guard state == .ready, let peripheral, let writeChar else { return }
    peripheral.writeValue(Data(bytes), for: writeChar, type: .withResponse)
    note("ir → " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
  }

  private func scan() {
    state = .searching
    central.scanForPeripherals(withServices: [Self.service])
  }

  private func note(_ line: String) {
    log.append("bridge: " + line)
    if log.count > 100 { log.removeFirst(log.count - 100) }
  }
}

extension BridgeController: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state == .poweredOn else {
      state = .off
      return
    }
    scan()
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    central.stopScan()
    self.peripheral = peripheral
    peripheral.delegate = self
    state = .connecting
    central.connect(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Self.service])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    scan()
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    writeChar = nil
    learning = nil
    note("disconnected")
    scan()
  }
}

extension BridgeController: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return }
    peripheral.discoverCharacteristics([Self.commandChar, Self.replyChar], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let chars = service.characteristics ?? []
    writeChar = chars.first { $0.uuid == Self.commandChar }
    if let reply = chars.first(where: { $0.uuid == Self.replyChar }) { peripheral.setNotifyValue(true, for: reply) }
    if writeChar != nil {
      state = .ready
      note("connected")
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let value = characteristic.value, value.count >= 11, value[value.startIndex] == 0x10, let id = learning else { return }
    learned[id] = value.dropFirst().prefix(10)
    UserDefaults.standard.set(learned, forKey: "irLearned")
    note("learned \(id)")
    learning = nil
  }
}
