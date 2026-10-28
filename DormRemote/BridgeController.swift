import CoreBluetooth
import Foundation
import Observation

/// One button on an IR remote. `command` is a known NEC code (Flipper IRDB); nil means it has to be learned.
struct IRButton: Identifiable {
  let id: String
  let name: String
  let icon: String
  var command: UInt8? = nil
}

/// Talks to the DormBridge board (firmware/), which turns Bluetooth commands into infrared.
@Observable
final class BridgeController: NSObject {
  enum State: Equatable { case off, searching, connecting, ready }

  static let service = CBUUID(string: "DB00")
  static let commandChar = CBUUID(string: "DB01")
  static let replyChar = CBUUID(string: "DB02")
  static let address: [UInt8] = [0x07, 0xFD]

  /// Starting button layouts. Only the projector ships with codes (Flipper IRDB, HLKZine astronaut projector,
  /// NEC-extended address 07 FD); every other device learns its buttons from its own remote.
  static let templates: [(name: String, buttons: [IRButton])] = [
    ("Galaxy projector", [
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
    ]),
    ("TV or streaming box", [
      IRButton(id: "power", name: "Power", icon: "power"), IRButton(id: "input", name: "Input", icon: "rectangle.on.rectangle"),
      IRButton(id: "volUp", name: "Vol +", icon: "speaker.wave.3"), IRButton(id: "volDown", name: "Vol −", icon: "speaker.wave.1"),
      IRButton(id: "mute", name: "Mute", icon: "speaker.slash"), IRButton(id: "home", name: "Home", icon: "house"),
      IRButton(id: "up", name: "Up", icon: "chevron.up"), IRButton(id: "ok", name: "OK", icon: "circle"),
      IRButton(id: "down", name: "Down", icon: "chevron.down"), IRButton(id: "left", name: "Left", icon: "chevron.left"),
      IRButton(id: "back", name: "Back", icon: "arrow.uturn.backward"), IRButton(id: "right", name: "Right", icon: "chevron.right"),
    ]),
    ("Fan, heater, or AC", [
      IRButton(id: "power", name: "Power", icon: "power"), IRButton(id: "mode", name: "Mode", icon: "dial.medium"),
      IRButton(id: "timer", name: "Timer", icon: "timer"), IRButton(id: "speedUp", name: "Speed +", icon: "wind"),
      IRButton(id: "speedDown", name: "Speed −", icon: "wind"), IRButton(id: "swing", name: "Swing", icon: "arrow.left.and.right"),
      IRButton(id: "tempUp", name: "Temp +", icon: "thermometer.sun"), IRButton(id: "tempDown", name: "Temp −", icon: "thermometer.snowflake"),
      IRButton(id: "sleep", name: "Sleep", icon: "moon"),
    ]),
    ("Anything else", [
      IRButton(id: "power", name: "Power", icon: "power"), IRButton(id: "on", name: "On", icon: "circle.fill"),
      IRButton(id: "off", name: "Off", icon: "circle"), IRButton(id: "up", name: "Up / +", icon: "plus"),
      IRButton(id: "down", name: "Down / −", icon: "minus"), IRButton(id: "mode", name: "Mode", icon: "dial.medium"),
      IRButton(id: "b1", name: "Button 1", icon: "1.circle"), IRButton(id: "b2", name: "Button 2", icon: "2.circle"),
      IRButton(id: "b3", name: "Button 3", icon: "3.circle"),
    ]),
  ]

  static func buttons(for template: String) -> [IRButton] {
    templates.first { $0.name == template }?.buttons ?? templates.last!.buttons
  }

  private(set) var state = State.off
  /// "<device id>.<button id>" waiting for a code from the real remote.
  private(set) var learning: String?
  private(set) var learned: [String: Data] = UserDefaults.standard.dictionary(forKey: "irLearned") as? [String: Data] ?? [:]
  var log: [String] = []

  private var central: CBCentralManager!
  private var peripheral: CBPeripheral?
  private var writeChar: CBCharacteristic?
  private var connectTimer: Timer?

  override init() {
    super.init()
    // Restore identifier: iOS keeps pending connects and relaunches the app for them (Apple TN3115).
    central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "bridge"])
  }

  static func key(_ device: UUID, _ button: IRButton) -> String { device.uuidString + "." + button.id }

  /// Learned codes win; otherwise the template's known code. Returns false if the button has neither yet.
  @discardableResult
  func press(_ button: IRButton, device: UUID) -> Bool {
    if let code = learned[Self.key(device, button)] {
      write([0x02] + code)
    } else if let command = button.command {
      write([0x01] + Self.address + [command])
    } else {
      return false
    }
    return true
  }

  func isLearned(_ button: IRButton, device: UUID) -> Bool { learned[Self.key(device, button)] != nil }

  /// The next code the bridge's IR receiver sees gets saved for this button.
  func learn(_ button: IRButton, device: UUID) {
    guard state == .ready else { return }
    learning = Self.key(device, button)
    write([0x10])
  }

  func cancelLearning() { learning = nil }

  func forgetLearned(device: UUID) {
    learned = learned.filter { !$0.key.hasPrefix(device.uuidString) }
    UserDefaults.standard.set(learned, forKey: "irLearned")
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
  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    guard let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
    peripheral = p
    p.delegate = self
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central.state == .poweredOn else {
      state = .off
      writeChar = nil
      return
    }
    // A link iOS kept while the app was away: a connected bridge doesn't advertise, so scanning wouldn't find it.
    if let peripheral, peripheral.state == .connected {
      state = .connecting
      peripheral.discoverServices([Self.service])
    } else {
      scan()
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    central.stopScan()
    self.peripheral = peripheral
    peripheral.delegate = self
    state = .connecting
    central.connect(peripheral)
    // CoreBluetooth waits forever on a board that went out of range mid-connect.
    connectTimer?.invalidate()
    connectTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
      guard let self, self.state == .connecting else { return }
      central.cancelPeripheralConnection(peripheral)
      self.scan()
    }
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
      connectTimer?.invalidate()
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
