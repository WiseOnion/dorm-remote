import AVFoundation
import Foundation
import Observation
import SwiftUI

/// One list of lights, whatever the brand, so the UI never has to know which app a light came from.
struct RGB: Equatable, Codable {
  var r: Int, g: Int, b: Int

  static let white = RGB(r: 255, g: 255, b: 255)

  /// Color temperature to RGB (Tanner Helland's curve fit), for lights without a real white channel.
  static func kelvin(_ k: Int) -> RGB {
    let t = Double(k) / 100
    let clamp = { (v: Double) in Int(max(0, min(255, v)).rounded()) }
    let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
    return RGB(r: clamp(r), g: clamp(g), b: clamp(b))
  }

  static func hue(_ h: Double, saturation: Double = 1) -> RGB {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    let wrapped = h - floor(h)
    UIColor(hue: wrapped, saturation: saturation, brightness: 1, alpha: 1).getRed(&r, green: &g, blue: &b, alpha: &a)
    return RGB(r: Int((r * 255).rounded()), g: Int((g * 255).rounded()), b: Int((b * 255).rounded()))
  }

  /// Hue and saturation, 0–1, for placing the color wheel's knob.
  var hueSaturation: (Double, Double) {
    var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
    UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
    return (Double(h), Double(s))
  }

  var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

  /// Hue palettes are pastel for bulbs; on an RGB strip pastels wash toward white, so push the saturation.
  var vivid: RGB {
    let (h, s) = hueSaturation
    return s < 0.05 ? self : .hue(h, saturation: min(1, s * 1.5 + 0.15))
  }
}

struct LightItem: Identifiable {
  /// Which driver a device comes from. Screens use `caps`, not this.
  enum Kind { case strip, bulb, bleBulb, remote }
  /// What a device can do; the app builds its controls from these.
  enum Capability { case power, brightness, color, white, effects, remote }
  enum Status: Equatable { case ready, setup, busy(String), offline(String) }

  let id: String
  var name: String
  let kind: Kind
  var status: Status
  var on = false
  var brightness = 100
  var color = RGB.white
  /// Set while the light is in white mode.
  var kelvin: Int?
  /// Bulb only: the running built-in effect and its speed (-10…10). The strip's effect lives on Room.
  var effect: String?
  var speed = 0

  var glow: RGB { kelvin.map(RGB.kelvin) ?? color }

  var caps: Set<Capability> {
    switch kind {
    case .strip, .bulb: [.power, .brightness, .color, .white, .effects]
    case .bleBulb: [.power, .brightness, .color, .white]
    case .remote: [.remote]
    }
  }
}

/// Room-wide presets, applied to every light at once.
struct Mood: Identifiable, Codable {
  /// One light's part of a saved scene.
  struct Snap: Codable, Equatable { var color: RGB; var kelvin: Int?; var brightness: Int; var on: Bool }
  /// `palette` spreads its colors over the room's lights, one each, like a Hue scene.
  /// `snapshot` puts each light back exactly as it was saved, keyed by light id.
  enum Look: Codable { case color(RGB), white(Int), party, palette([RGB]), snapshot([String: Snap]) }
  enum Group: String, CaseIterable, Codable {
    case mine = "Yours", everyday = "Everyday", colorful = "Colorful", night = "Night", seasonal = "Seasonal"
  }

  let id: String
  let group: Group
  let look: Look
  let brightness: Int

  init(_ id: String, _ group: Group, _ look: Look, _ brightness: Int) {
    self.id = id
    self.group = group
    self.look = look
    self.brightness = brightness
  }

  private static func hex(_ values: UInt32...) -> Look {
    .palette(values.map { RGB(r: Int($0 >> 16 & 0xFF), g: Int($0 >> 8 & 0xFF), b: Int($0 & 0xFF)) })
  }

  // Palettes and brightness come from the Philips Hue scene gallery (RGB values captured in
  // gist.github.com/labmonkey/a641f6b339ed9a71bdced64b9af91ee8), dimmest scenes raised a little for strips.
  static let all: [Mood] = [
    Mood("Relax", .everyday, .white(2700), 60),
    Mood("Read", .everyday, .white(3500), 100),
    Mood("Focus", .everyday, .white(5000), 100),
    Mood("Energize", .everyday, .white(6500), 100),
    Mood("Sunrise", .everyday, .color(RGB(r: 255, g: 120, b: 40)), 45),

    Mood("Party", .colorful, .party, 100),
    Mood("Tropical twilight", .colorful, hex(0xCD7DFF, 0xFFB782, 0xFFBBED), 70),
    Mood("Savanna sunset", .colorful, hex(0xFF5E24, 0xFFCD5A, 0xFF8244, 0xFFA75A), 60),
    Mood("Arctic aurora", .colorful, hex(0x6EFFB9, 0x4188FF, 0x6DFAFF, 0x3F53FF), 50),
    Mood("Spring blossom", .colorful, hex(0xFF7FC0, 0xFF917D, 0xFFB3E7, 0xFFCCEB), 60),
    Mood("Golden pond", .colorful, hex(0xFF9C23, 0xFFD349, 0xFFA32A, 0xFFCA41), 65),
    Mood("Honolulu", .colorful, hex(0xFF404E, 0xFF874C, 0xFFCD5F, 0xFF9A36), 70),
    Mood("Blue lagoon", .colorful, hex(0x3EF4FF, 0xFFB68D, 0xAAFFF6, 0xD7FFD8), 50),
    Mood("Miami", .colorful, hex(0xFF5F8B, 0x7AAEFF, 0xFF9359, 0xFFA059), 75),
    Mood("Tokyo", .colorful, hex(0xFF2B78, 0x5C08FF, 0x3D90FF, 0xFFA125, 0xA919FF), 60),
    Mood("Vapor wave", .colorful, hex(0x5F6DFF, 0xFF58E9, 0xFFB029, 0x8D1BFF), 78),
    Mood("Soho", .colorful, hex(0xFF719B, 0x5500FF, 0xFFA171, 0x871BFF, 0x67FFDB), 62),
    Mood("Disturbia", .colorful, hex(0x32FFEA, 0xFF5FF6, 0xFF2B42, 0x8EECFF), 63),

    Mood("Movie", .night, .color(RGB(r: 40, g: 40, b: 255)), 15),
    Mood("Nebula", .night, hex(0x6C15FF, 0xB37FFF, 0xFFB5E6, 0x97A2FF), 25),
    Mood("Galaxy", .night, hex(0xEF7DFF, 0xFF6FA9, 0xFF8674), 25),
    Mood("Blood moon", .night, hex(0x483CFF, 0xFFAE93, 0x6173FF, 0xFFB9D2), 20),
    Mood("Moonlight", .night, hex(0x3E68FF, 0x5887FF, 0x83A4FF), 20),
    Mood("Night", .night, .color(RGB(r: 255, g: 20, b: 0)), 5),

    Mood("Halloween", .seasonal, hex(0xFF5A00, 0x7A00FF, 0x39FF14, 0xFF8C00), 70),
    Mood("Aggie Pride", .seasonal, hex(0x004684, 0xFDB927), 85),
    Mood("Christmas", .seasonal, hex(0xFF0000, 0x00C040, 0xFFD27A), 75),
    Mood("Valentine's", .seasonal, hex(0xFF0040, 0xFF4FA0, 0xC0007A), 60),
  ]

  var swatch: [Color] {
    switch look {
    case .color(let c): return [c.color, c.color.opacity(0.5)]
    case .white(let k): return [RGB.kelvin(k).color, RGB.kelvin(k + 1500).color]
    case .party: return [.pink, .purple, .blue, .cyan]
    case .palette(let colors): return colors.map { $0.vivid.color }
    case .snapshot(let snaps):
      // Sorted by light id so the swatch doesn't reshuffle between redraws.
      let lit = snaps.keys.sorted().compactMap { snaps[$0] }.filter(\.on).map { ($0.kelvin.map(RGB.kelvin) ?? $0.color).color }
      return lit.isEmpty ? [.gray, .black] : lit
    }
  }

  /// The photo shrunk to 48×48, as pixels. Small is plenty for picking colors and keeps it instant.
  static func pixels(ofImage data: Data) -> [RGB] {
    guard let image = UIImage(data: data)?.cgImage else { return [] }
    let side = 48
    var buffer = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
      guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return [] }
    var pixels: [RGB] = []
    pixels.reserveCapacity(side * side)
    for i in stride(from: 0, to: buffer.count, by: 4) {
      let r = Int(buffer[i]), g = Int(buffer[i + 1]), b = Int(buffer[i + 2])
      pixels.append(RGB(r: r, g: g, b: b))
    }
    return pixels
  }

  /// Picks a few colors that stand out in a photo: drops dark and gray pixels, groups the rest by hue,
  /// and averages the biggest groups. Returned brightest-group first.
  static func palette(from pixels: [RGB], count: Int = 4) -> [RGB] {
    var bins = [(n: Int, r: Int, g: Int, b: Int)](repeating: (0, 0, 0, 0), count: 18)
    for p in pixels {
      let (h, s) = p.hueSaturation
      guard s > 0.3, max(p.r, p.g, p.b) > 60 else { continue }
      let i = min(17, Int(h * 18))
      bins[i] = (bins[i].n + 1, bins[i].r + p.r, bins[i].g + p.g, bins[i].b + p.b)
    }
    // Ignore groups too small to be a real part of the picture.
    let floor = max(1, pixels.count / 50)
    return bins.filter { $0.n >= floor }
      .sorted { $0.n > $1.n }
      .prefix(count)
      .map { RGB(r: $0.r / $0.n, g: $0.g / $0.n, b: $0.b / $0.n) }
  }
}

/// Strip effects. Built-in effects run on the controller; phone-mic music, the synced rainbow, and the flames run in the app.
enum Effect: Hashable {
  case pattern(UInt8), phoneMic, synced, candle, fire

  struct Pattern: Identifiable {
    let name: String
    let id: UInt8
    let colors: [RGB]
  }

  static let rainbow = [RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 160, b: 0), RGB(r: 255, g: 255, b: 0), RGB(r: 0, g: 255, b: 0),
                        RGB(r: 0, g: 200, b: 255), RGB(r: 0, g: 0, b: 255), RGB(r: 160, g: 0, b: 255)]
  static let three = [RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 255, b: 0), RGB(r: 0, g: 0, b: 255)]

  // Effect bytes copied from grimsteel/daybetter-led-strip const.py (Effect enum), same order and names.
  static let singles: [(String, RGB)] = [
    ("Red", RGB(r: 255, g: 0, b: 0)), ("Green", RGB(r: 0, g: 255, b: 0)), ("Blue", RGB(r: 0, g: 0, b: 255)),
    ("Yellow", RGB(r: 255, g: 255, b: 0)), ("Teal", RGB(r: 0, g: 255, b: 255)), ("Purple", RGB(r: 160, g: 0, b: 255)),
    ("White", RGB(r: 255, g: 255, b: 255)),
  ]
  static let patternGroups: [(String, [Pattern])] = {
    let off = RGB(r: 0, g: 0, b: 0)
    let switching: [Pattern] = [Pattern(name: "Switch RGB", id: 0x09, colors: three),
                                Pattern(name: "Switch all colors", id: 0x0A, colors: rainbow)]
    let fade: [Pattern] = [
      Pattern(name: "Fade quick", id: 0x0B, colors: rainbow), Pattern(name: "Fade slow", id: 0x0C, colors: rainbow),
      Pattern(name: "Fade red & green", id: 0x14, colors: [three[0], three[1]]),
      Pattern(name: "Fade red & blue", id: 0x15, colors: [three[0], three[2]]),
      Pattern(name: "Fade green & blue", id: 0x16, colors: [three[1], three[2]]),
    ]
    var blink: [Pattern] = []
    var flash: [Pattern] = [Pattern(name: "Flash all colors", id: 0x17, colors: rainbow)]
    for (i, single) in singles.enumerated() {
      blink.append(Pattern(name: "Blink " + single.0.lowercased(), id: UInt8(0x0D + i), colors: [single.1, off]))
      flash.append(Pattern(name: "Flash " + single.0.lowercased(), id: UInt8(0x18 + i), colors: [single.1, off]))
    }
    let strobe: [Pattern] = [Pattern(name: "Strobe RGB", id: 0x1F, colors: three),
                             Pattern(name: "Strobe all colors", id: 0x20, colors: rainbow)]
    return [("Switch", switching), ("Fade", fade), ("Blink", blink), ("Flash", flash), ("Strobe", strobe)]
  }()
  static let patterns = patternGroups.flatMap(\.1)

  var name: String {
    switch self {
    case .pattern(let id): Self.patterns.first { $0.id == id }?.name ?? "Effect"
    case .phoneMic: "Phone mic"
    case .synced: "Rainbow in sync"
    case .candle: "Candlelight"
    case .fire: "Fireplace"
    }
  }

  /// One flame frame: a warm color whose level wanders. `level` is the strip's last level (0–1); the result keeps it
  /// moving smoothly for a candle and in jumps for a fire. Kept here, without randomness of its own, so it can be tested.
  static func flame(fire: Bool, level: Double, roll: Double, hueRoll: Double) -> (RGB, Double) {
    let next: Double
    if fire {
      // Mostly mid to bright with sudden flares and dips.
      next = max(0.35, min(1, level + (roll - 0.5) * 0.6))
    } else {
      // A candle sways gently around 70 % and rarely gutters.
      let target = roll < 0.04 ? 0.35 : 0.7
      next = max(0.4, min(0.95, level + (target - level) * 0.25 + (roll - 0.5) * 0.12))
    }
    let green = fire ? 40 + hueRoll * 90 : 110 + hueRoll * 30
    let base = RGB(r: 255, g: Int(green), b: fire ? 0 : Int(hueRoll * 12))
    return (RGB(r: Int(Double(base.r) * next), g: Int(Double(base.g) * next), b: Int(Double(base.b) * next)), next)
  }
}

/// A remote-controlled (infrared) device reached through the DormBridge.
struct IRDevice: Codable, Identifiable {
  let id: UUID
  var name: String
  var template: String
}

@MainActor
@Observable
final class Room {

  /// The selected room's lights.
  static let all = "all"
  /// Every light in every room.
  static let everything = "everything"
  /// One room for the app and its Shortcuts actions.
  static let shared = Room(strip: StripController(), hubspace: HubspaceClient(), bridge: BridgeController(), lamps: BulbBank())
  static let stripID = "strip"

  let strip: StripController
  let hubspace: HubspaceClient
  let bridge: BridgeController
  let lamps: BulbBank

  private(set) var effect: Effect?
  /// The strips the running effect plays on.
  private var effectStrips: Set<UUID> = []
  private(set) var mood: String?
  /// Music level 0–1 for the meter.
  private(set) var level: Double = 0
  var effectError: String?

  // Strips only report power and brightness, so remember what we last sent to each.
  private var stripLooks: [UUID: SavedLook]
  private var names: [String: String]
  /// Per-light choice: true = shared with roommates (kept out of scenes, All on/off, and schedules).
  private var sharedChoice = UserDefaults.standard.dictionary(forKey: "sharedLights") as? [String: Bool] ?? [:]
  private(set) var irDevices: [IRDevice] = {
    guard let data = UserDefaults.standard.data(forKey: "irDevices") else { return [] }
    return (try? JSONDecoder().decode([IRDevice].self, from: data)) ?? []
  }()
  /// Devices swiped away ("strip", "hub" for the whole Hubspace account, or one "hub:<id>" bulb); "Add" brings them back.
  private var hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenLights") ?? [])
  private var engine: AVAudioEngine?
  private var hue = 0.0
  private var lastBeat = Date.distantPast
  private var average: Double = 0

  init(strip: StripController, hubspace: HubspaceClient, bridge: BridgeController, lamps: BulbBank) {
    self.strip = strip
    self.hubspace = hubspace
    self.bridge = bridge
    self.lamps = lamps
    names = UserDefaults.standard.dictionary(forKey: "names") as? [String: String] ?? [:]
    if let data = UserDefaults.standard.data(forKey: "stripLooks"),
       let saved = try? JSONDecoder().decode([String: SavedLook].self, from: data) {
      stripLooks = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    } else if let first = StripController.firstID, let data = UserDefaults.standard.data(forKey: "stripLook"),
              let saved = try? JSONDecoder().decode(SavedLook.self, from: data) {
      // Saved before the app handled more than one strip.
      stripLooks = [first: saved]
    } else {
      stripLooks = [:]
    }
    strip.onStatus = { [weak self] id, status in
      MainActor.assumeIsolated { self?.apply(status, to: id) }
    }
  }

  /// The strip's own report wins over what we remember, so IR remote changes show up here.
  private func apply(_ status: StripStatus, to id: UUID) {
    updateLook(id) {
      $0.on = status.on
      $0.brightness = status.brightness
    }
  }

  /// The first strip keeps the id "strip" from when there was only one; the rest are "strip:<uuid>".
  static func stripItemID(_ id: UUID) -> String {
    id == StripController.firstID ? stripID : "strip:" + id.uuidString
  }

  private func stripUUID(_ light: LightItem) -> UUID? {
    strip.strips.first { Self.stripItemID($0.id) == light.id }?.id
  }

  // MARK: Lights

  var items: [LightItem] {
    let strips: [LightItem] = strip.strips.enumerated().map { i, s in
      let id = Self.stripItemID(s.id)
      let look = stripLooks[s.id] ?? SavedLook()
      return LightItem(id: id, name: names[id] ?? (i == 0 ? "LED strip" : "LED strip \(i + 1)"), kind: .strip,
                       status: stripStatus(s), on: look.on, brightness: look.brightness, color: look.color, kelvin: look.kelvin)
    }

    var list: [LightItem] = []
    let placeholder = { (status: LightItem.Status) in
      LightItem(id: "hub", name: "Smart bulb", kind: .bulb, status: status)
    }
    switch hubspace.state {
    case .ready:
      list += hubspace.lights.map { l in
        LightItem(id: "hub:" + l.id, name: names["hub:" + l.id] ?? l.name, kind: .bulb,
                  status: hubspace.offline.contains(l.id) ? .offline("Not on Wi-Fi. Tap for help") : .ready,
                  on: l.on, brightness: l.brightness, color: RGB(r: l.r, g: l.g, b: l.b), kelvin: l.kelvin,
                  effect: l.effect, speed: l.speed)
      }
    case .signedOut, .loginFailed, .needsCode: list.append(placeholder(.setup))
    case .signingIn, .loading: list.append(placeholder(.busy("Loading")))
    case .unavailable: list.append(placeholder(.offline("Can't reach Hubspace")))
    }
    list += lamps.bulbs.map { b in
      LightItem(id: "ble:" + b.id.uuidString, name: names["ble:" + b.id.uuidString] ?? "Bulb", kind: .bleBulb,
                status: lamps.connected.contains(b.id) ? .ready : .busy("Looking"),
                on: b.on, brightness: b.brightness, color: b.color, kelvin: b.kelvin)
    }
    list += strips
    // No strip yet: a row that opens setup.
    if strips.isEmpty {
      list.append(LightItem(id: Self.stripID, name: names[Self.stripID] ?? "LED strip", kind: .strip,
                            status: strip.bluetoothOn ? .setup : .offline("Bluetooth is off")))
    }
    let remoteStatus: LightItem.Status = switch bridge.state {
    case .ready: .ready
    case .connecting: .busy("Connecting to bridge")
    case .off, .searching: .setup
    }
    list += irDevices.map { d in
      let id = "ir:" + d.id.uuidString
      return LightItem(id: id, name: names[id] ?? d.name, kind: .remote, status: remoteStatus)
    }
    return list.filter { !hidden.contains($0.id) && !($0.kind == .bulb && hidden.contains("hub")) }
  }

  private func stripStatus(_ s: Strip) -> LightItem.Status {
    guard strip.bluetoothOn else { return .offline("Bluetooth is off") }
    switch s.state {
    case .connected: return .ready
    case .connecting: return .busy("Connecting")
    case .idle: return .busy("Looking")
    case .failed(let m): return .offline(m)
    }
  }

  enum AddKind: String, CaseIterable, Identifiable {
    case strip = "DayBetter LED strip", hubspace = "Hubspace bulb", bluetooth = "Bluetooth bulb", remote = "Remote-controlled device (IR)"
    var id: String { rawValue }
  }

  /// Swipe to delete: forgets the device and removes its row.
  func remove(_ item: LightItem) {
    switch item.kind {
    case .strip:
      if let id = stripUUID(item) {
        stopEffect(on: [item])
        strip.remove(id)
        stripLooks[id] = nil
        saveStrips()
      } else {
        // The setup row: hide it until "Add".
        hidden.insert(Self.stripID)
      }
    case .bulb:
      // Just this bulb; the other bulbs on the account (a roommate's, say) stay. Signing out is in the menu.
      hidden.insert(item.id)
    case .bleBulb:
      lamp(item).map(lamps.remove)
    case .remote:
      irDevices.removeAll { "ir:" + $0.id.uuidString == item.id }
      saveIR()
    }
    saveHidden()
  }

  /// Brings a removed row back; the home screen then opens its setup.
  func restore(_ kind: AddKind) {
    switch kind {
    case .strip: hidden.remove(Self.stripID)
    case .hubspace: hidden = hidden.filter { $0 != "hub" && !$0.hasPrefix("hub:") }
    case .bluetooth, .remote: break
    }
    saveHidden()
  }

  private func saveHidden() { UserDefaults.standard.set(Array(hidden), forKey: "hiddenLights") }

  // MARK: Remote-controlled devices

  func addIRDevice(name: String, template: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let device = IRDevice(id: UUID(), name: trimmed.isEmpty ? template : trimmed, template: template)
    irDevices.append(device)
    setRoom("ir:" + device.id.uuidString, currentRoom)
    saveIR()
  }

  func irDevice(_ itemID: String) -> IRDevice? { irDevices.first { "ir:" + $0.id.uuidString == itemID } }

  /// The tile's power button: the device's "power" button, if it has a code yet.
  func pressRemotePower(_ item: LightItem) {
    guard let device = irDevice(item.id),
          let power = BridgeController.buttons(for: device.template).first(where: { $0.id == "power" }) else { return }
    bridge.press(power, device: device.id)
  }

  private func saveIR() { UserDefaults.standard.set(try? JSONEncoder().encode(irDevices), forKey: "irDevices") }

  var ready: [LightItem] { items.filter { $0.status == .ready } }

  // MARK: Rooms

  private(set) var rooms: [String] = UserDefaults.standard.stringArray(forKey: "rooms") ?? ["Bedroom", "Living room"]
  private var roomAssignment = UserDefaults.standard.dictionary(forKey: "roomOf") as? [String: String] ?? [:]
  var selectedRoom = UserDefaults.standard.string(forKey: "selectedRoom") ?? "Bedroom" {
    didSet { UserDefaults.standard.set(selectedRoom, forKey: "selectedRoom") }
  }

  /// The selected room, or the first one if it was deleted.
  var currentRoom: String { rooms.contains(selectedRoom) ? selectedRoom : rooms.first ?? "" }

  /// New devices land in the first room. Lights earlier marked "shared", or named for the living room,
  /// start in a living room so roommates' lights stay out of your room's scenes.
  func roomOf(_ item: LightItem) -> String {
    if let r = roomAssignment[item.id], rooms.contains(r) { return r }
    let shared = sharedChoice[item.id] ?? item.name.lowercased().contains("living")
    if shared, let living = rooms.first(where: { $0.lowercased().contains("living") }) { return living }
    return rooms.first ?? ""
  }

  func setRoom(_ id: String, _ room: String) {
    roomAssignment[id] = room
    saveRooms()
  }

  func addRoom(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !rooms.contains(trimmed) else { return }
    rooms.append(trimmed)
    selectedRoom = trimmed
    saveRooms()
  }

  func renameRoom(_ old: String, to new: String) {
    let trimmed = new.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !rooms.contains(trimmed), let i = rooms.firstIndex(of: old) else { return }
    // Pin every light that was in the old room (including ones placed by default) before renaming it.
    for item in items where roomOf(item) == old { roomAssignment[item.id] = trimmed }
    rooms[i] = trimmed
    if selectedRoom == old { selectedRoom = trimmed }
    saveRooms()
  }

  /// Its lights move to the first remaining room. The last room can't be deleted.
  func deleteRoom(_ name: String) {
    guard rooms.count > 1 else { return }
    rooms.removeAll { $0 == name }
    roomAssignment = roomAssignment.filter { $0.value != name }
    if selectedRoom == name { selectedRoom = rooms[0] }
    saveRooms()
  }

  private func saveRooms() {
    UserDefaults.standard.set(rooms, forKey: "rooms")
    UserDefaults.standard.set(roomAssignment, forKey: "roomOf")
  }

  var inRoom: [LightItem] { items.filter { roomOf($0) == currentRoom } }
  /// What room-wide controls act on: the selected room's connected devices.
  var roomReady: [LightItem] { ready.filter { roomOf($0) == currentRoom } }

  func item(_ id: String) -> LightItem? { items.first { $0.id == id } }

  /// What a control sheet shows: one light, or the first ready one standing in for the room.
  func look(_ id: String) -> LightItem? {
    let lights = roomReady.filter { $0.kind != .remote }
    return id == Self.all ? (lights.first { $0.on } ?? lights.first) : item(id)
  }

  var anyOn: Bool { roomReady.contains { $0.on } }

  /// The background glow: the color of whatever is on.
  var ambient: Color? {
    let on = roomReady.filter(\.on)
    guard !on.isEmpty else { return nil }
    let n = Double(on.count)
    let sum = on.reduce((0.0, 0.0, 0.0)) { ($0.0 + Double($1.glow.r), $0.1 + Double($1.glow.g), $0.2 + Double($1.glow.b)) }
    return Color(red: sum.0 / n / 255, green: sum.1 / n / 255, blue: sum.2 / n / 255)
  }

  /// Colors picked on the wheel, newest first, so a favorite is one tap away next time.
  private(set) var recentColors: [RGB] = {
    guard let data = UserDefaults.standard.data(forKey: "recentColors") else { return [] }
    return (try? JSONDecoder().decode([RGB].self, from: data)) ?? []
  }()

  func remember(_ c: RGB) {
    // Near-duplicates (a wheel drag ending a pixel away) replace the old entry.
    recentColors.removeAll { abs($0.r - c.r) + abs($0.g - c.g) + abs($0.b - c.b) < 24 }
    recentColors.insert(c, at: 0)
    recentColors = Array(recentColors.prefix(8))
    UserDefaults.standard.set(try? JSONEncoder().encode(recentColors), forKey: "recentColors")
  }

  /// Pull to refresh: reconnect anything that dropped and re-read the bulbs.
  func reconnect() async {
    strip.reconnectNow()
    hubspace.clearOffline()
    switch hubspace.state {
    case .ready: await hubspace.refresh()
    case .unavailable: await hubspace.load()
    default: break
    }
  }

  func rename(_ id: String, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    names[id] = trimmed.isEmpty ? nil : trimmed
    UserDefaults.standard.set(names, forKey: "names")
  }

  // MARK: Control

  func setPower(_ id: String, _ on: Bool) {
    if !on { stopEffect(on: targets(id)) }
    cancelSweep()
    mood = nil
    for light in targets(id) { power(light, on) }
  }

  private func power(_ light: LightItem, _ on: Bool) {
    switch light.kind {
    case .strip:
      guard let s = stripUUID(light) else { break }
      strip.setPower(s, on)
      updateLook(s) { $0.on = on }
    case .bulb: hub(light).map { hubspace.setPower($0, on) }
    case .bleBulb: lamp(light).map { lamps.setPower($0, on) }
    case .remote: break
    }
  }

  func setBrightness(_ id: String, _ value: Int) {
    cancelSweep()
    mood = nil
    for light in targets(id) { brightness(light, value) }
  }

  func setColor(_ id: String, _ color: RGB) {
    cancelSweep()
    mood = nil
    stopEffect(on: targets(id))
    for light in targets(id) { paint(light, color) }
  }

  func setWhite(_ id: String, _ kelvin: Int) {
    cancelSweep()
    mood = nil
    stopEffect(on: targets(id))
    for light in targets(id) { white(light, kelvin) }
  }

  /// Shows one color on the strips and on your bulbs at once, so the strips' balance can be matched by eye.
  func showForMatching(_ c: RGB) {
    stopEffect()
    mood = nil
    // The strips' rooms, whichever tab is open, so the lamps next to them are what they get compared with.
    let stripRooms = Set(items.filter { $0.kind == .strip }.map(roomOf))
    for light in ready where light.kind != .remote && stripRooms.contains(roomOf(light)) { paint(light, c) }
  }

  func setStripBalance(_ balance: [Double], resend c: RGB) {
    strip.balance = balance
    // Instant, so slider moves show right away.
    for s in ready.compactMap(stripUUID) { strip.setColor(s, r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b), fade: false) }
  }

  func setBulbEffect(_ id: String, _ effect: String) {
    mood = nil
    item(id).flatMap(hub).map { hubspace.setEffect($0, effect) }
  }

  func setBulbSpeed(_ id: String, _ speed: Int) {
    item(id).flatMap(hub).map { hubspace.setEffectSpeed($0, speed) }
  }

  func apply(_ m: Mood) {
    // Tapping the scene that's already on reshuffles which light gets which color (Hue does the same).
    shuffle = mood == m.id ? shuffle + 1 : 0
    stopEffect(on: roomReady)
    let lights = roomReady.filter { $0.kind != .remote }
    let order = mapOrder(lights)
    let shift = shuffle
    sweep(lights) { [weak self] light in
      guard let self else { return }
      if case .snapshot(let snaps) = m.look {
        // Lights added after the scene was saved stay as they are.
        guard let snap = snaps[light.id] else { return }
        guard snap.on else { return self.power(light, false) }
        self.brightness(light, snap.brightness)
        if let k = snap.kelvin { self.white(light, k) } else { self.paint(light, snap.color) }
        return
      }
      self.brightness(light, m.brightness)
      switch m.look {
      case .color(let c): self.paint(light, c)
      case .white(let k): self.white(light, k)
      case .party: self.paint(light, RGB(r: 255, g: 0, b: 180))
      case .palette(let colors): self.paintPalette(light, colors, order, shift)
      case .snapshot: break
      }
    }
    // Party switches colors on the strip; with Reduce flashing it rolls a smooth rainbow instead.
    if case .party = m.look { start(reduceFlashing ? .synced : .pattern(10), on: Self.all) }
    mood = m.id
    startLiving(m)
  }

  private var shuffle = 0

  /// Palette colors go around the room in map order, so neighbors differ. Unplaced lights keep list order.
  private func mapOrder(_ lights: [LightItem]) -> [String: Int] {
    let angle = { (l: LightItem) in self.placements[l.id].map { atan2($0.y, $0.x) } ?? .infinity }
    return Dictionary(uniqueKeysWithValues: lights.sorted { angle($0) < angle($1) }.enumerated().map { ($1.id, $0) })
  }

  private func paintPalette(_ light: LightItem, _ colors: [RGB], _ order: [String: Int], _ shift: Int) {
    let c = colors[((order[light.id] ?? 0) + shift) % colors.count]
    paint(light, light.kind == .strip ? c.vivid : c)
  }

  // MARK: Living scenes

  /// Color scenes keep moving: every few seconds each light hands its color to the next, and strips fade
  /// between them. Runs while the app is open; any manual change stops it.
  var living = UserDefaults.standard.bool(forKey: "livingScenes") {
    didSet {
      UserDefaults.standard.set(living, forKey: "livingScenes")
      if let id = mood, let m = moods.first(where: { $0.id == id }) { startLiving(m) } else { livingTimer?.invalidate() }
    }
  }
  private var livingTimer: Timer?
  static let livingStep = 12.0

  private func startLiving(_ m: Mood) {
    livingTimer?.invalidate()
    guard living, case .palette(let colors) = m.look, colors.count > 1 else { return }
    livingTimer = Timer.scheduledTimer(withTimeInterval: Self.livingStep, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self, self.mood == m.id, self.living else { return timer.invalidate() }
        self.shuffle += 1
        // Same order as when the scene was applied, so every light steps to its neighbor's color.
        let lights = self.roomReady.filter { $0.kind != .remote }
        let order = self.mapOrder(lights)
        for light in lights where light.on { self.paintPalette(light, colors, order, self.shuffle) }
      }
    }
  }

  // MARK: Your scenes

  private(set) var customScenes: [Mood] = {
    guard let data = UserDefaults.standard.data(forKey: "customScenes") else { return [] }
    return (try? JSONDecoder().decode([Mood].self, from: data)) ?? []
  }()
  private(set) var favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteScenes") ?? [])

  /// Yours first, then the built-in ones.
  var moods: [Mood] { customScenes + Mood.all }

  /// Saves every light in the room as it is right now.
  func saveScene(named name: String) {
    let lights = roomReady.filter { $0.kind != .remote }
    guard !lights.isEmpty else { return }
    let snaps = Dictionary(uniqueKeysWithValues: lights.map {
      ($0.id, Mood.Snap(color: $0.color, kelvin: $0.kelvin, brightness: $0.brightness, on: $0.on))
    })
    let level = lights.filter(\.on).map(\.brightness).max() ?? 0
    addScene(Mood(uniqueName(name), .mine, .snapshot(snaps), level))
  }

  /// Saves a palette (from a photo) as one of your scenes and plays it.
  func savePalette(_ colors: [RGB], named name: String) {
    guard !colors.isEmpty else { return }
    let m = Mood(uniqueName(name), .mine, .palette(colors), 70)
    addScene(m)
    apply(m)
  }

  func deleteScene(_ id: String) {
    customScenes.removeAll { $0.id == id }
    favorites.remove(id)
    saveScenes()
  }

  func toggleFavorite(_ id: String) {
    if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
    saveScenes()
  }

  private func addScene(_ m: Mood) {
    customScenes.insert(m, at: 0)
    saveScenes()
  }

  /// "Movie" → "Movie 2" when the name is taken, so ids stay unique.
  private func uniqueName(_ name: String) -> String {
    let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? "My scene" : name.trimmingCharacters(in: .whitespaces)
    let taken = Set(moods.map(\.id))
    var candidate = base
    var n = 2
    while taken.contains(candidate) {
      candidate = "\(base) \(n)"
      n += 1
    }
    return candidate
  }

  private func saveScenes() {
    UserDefaults.standard.set(try? JSONEncoder().encode(customScenes), forKey: "customScenes")
    UserDefaults.standard.set(Array(favorites), forKey: "favoriteScenes")
  }

  // MARK: Placement and sweeps

  /// Where a light is, as seen from where you usually sit: x right, y toward you (-1…1), plus how long it
  /// takes to react. Filled in by "Find my lights"; the room map is the fallback for anything not seen.
  struct Placement: Codable {
    var x: Double
    var y: Double
    var latency: Double
    var found: Bool
  }

  private(set) var placements: [String: Placement] = {
    guard let data = UserDefaults.standard.data(forKey: "placements") else { return [:] }
    return (try? JSONDecoder().decode([String: Placement].self, from: data)) ?? [:]
  }()
  private var sweepTasks: [Task<Void, Never>] = []
  private var sweepColor = 0
  private var scanSaved: [LightItem] = []

  /// Total time for a change to travel across the room.
  static let sweepTime = 1.2

  func setPlacement(_ id: String, x: Double, y: Double) {
    let latency = placements[id]?.latency ?? defaultLatency(item(id))
    placements[id] = Placement(x: max(-1, min(1, x)), y: max(-1, min(1, y)), latency: latency, found: false)
    savePlacements()
  }

  func clearPlacement(_ id: String) {
    placements[id] = nil
    savePlacements()
  }

  private func defaultLatency(_ item: LightItem?) -> Double { item?.kind == .bulb ? 1.5 : 0.15 }

  private func savePlacements() { UserDefaults.standard.set(try? JSONEncoder().encode(placements), forKey: "placements") }

  private func cancelSweep() {
    sweepTasks.forEach { $0.cancel() }
    sweepTasks = []
  }

  /// Runs `action` on each light so the change rolls around the room in order, and lands together: slow lights
  /// (cloud bulbs, measured during the scan) are sent early by their extra delay. Unplaced lights go first.
  private func sweep(_ lights: [LightItem], _ action: @escaping @MainActor (LightItem) -> Void) {
    cancelSweep()
    let latency = { (l: LightItem) in self.placements[l.id]?.latency ?? self.defaultLatency(l) }
    let slowest = lights.map(latency).max() ?? 0
    let angles = lights.compactMap { l in placements[l.id].map { (l.id, atan2($0.y, $0.x)) } }
    var progress: [String: Double] = [:]
    if angles.count >= 2 {
      // Start right after the widest empty stretch of the circle, so the sweep never jumps across the room.
      let sorted = angles.sorted { $0.1 < $1.1 }
      var gapEnd = 0
      var widest = -1.0
      for i in sorted.indices {
        let next = sorted[(i + 1) % sorted.count].1
        let gap = (next - sorted[i].1 + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        if gap > widest { widest = gap; gapEnd = (i + 1) % sorted.count }
      }
      let start = sorted[gapEnd].1
      let span = max(0.001, 2 * .pi - widest)
      for (id, a) in angles {
        progress[id] = min(1, ((a - start + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)) / span)
      }
    }
    for light in lights {
      let delay = (progress[light.id] ?? 0) * Self.sweepTime * (angles.count >= 2 ? 1 : 0) + (slowest - latency(light))
      if delay < 0.02 {
        action(light)
      } else {
        sweepTasks.append(Task { @MainActor in
          try? await Task.sleep(for: .seconds(delay))
          guard !Task.isCancelled else { return }
          action(light)
        })
      }
    }
  }

  /// Rolls the next color around the room so the order and timing can be checked.
  func testSweep() {
    let colors = [RGB(r: 255, g: 90, b: 30), RGB(r: 0, g: 140, b: 255), RGB(r: 140, g: 0, b: 255), RGB(r: 0, g: 220, b: 120)]
    let c = colors[sweepColor % colors.count]
    sweepColor += 1
    stopEffect()
    mood = nil
    sweep(roomReady.filter { $0.caps.contains(.color) }) { [weak self] in self?.paint($0, c) }
  }

  // MARK: Scanning (driven by LightScanner)

  func scanTargets() -> [LightItem] { roomReady.filter { $0.caps.contains(.power) } }

  /// Remembers each light's look, then sets them all to bright white, the easiest change for the camera to see.
  func scanPrepare() {
    stopEffect()
    cancelSweep()
    scanSaved = scanTargets()
    for light in scanSaved {
      brightness(light, 100)
      white(light, 5000)
    }
  }

  /// Power only, so the scan doesn't overwrite the saved look.
  func scanPower(_ id: String, _ on: Bool) {
    guard let light = item(id) else { return }
    switch light.kind {
    case .strip: stripUUID(light).map { strip.setPower($0, on) }
    case .bulb: hub(light).map { hubspace.setPower($0, on) }
    case .bleBulb: lamp(light).map { lamps.setPower($0, on) }
    case .remote: break
    }
  }

  func scanFinished(_ found: [String: LightScanner.Result]) {
    for (id, r) in found {
      // yaw 0 = the way the phone faced at the start, clockwise; that direction is "up" on the map.
      placements[id] = Placement(x: sin(r.yaw) * 0.8, y: -cos(r.yaw) * 0.8, latency: r.latency, found: true)
    }
    savePlacements()
    scanRestore()
  }

  /// Puts every scanned light back how it was.
  func scanRestore() {
    for light in scanSaved {
      if light.on {
        brightness(light, light.brightness)
        if let k = light.kelvin { white(light, k) } else { paint(light, light.color) }
      } else {
        scanPower(light.id, false)
        stripUUID(light).map { s in updateLook(s) { $0.on = false } }
      }
    }
    scanSaved = []
  }

  private func targets(_ id: String) -> [LightItem] {
    let lights = switch id {
    case Self.all: roomReady
    case Self.everything: ready
    default: ready.filter { $0.id == id }
    }
    return lights.filter { $0.kind != .remote }
  }

  private func lamp(_ light: LightItem) -> UUID? {
    light.id.hasPrefix("ble:") ? UUID(uuidString: String(light.id.dropFirst(4))) : nil
  }

  private func hub(_ light: LightItem) -> HubLight? {
    hubspace.lights.first { "hub:" + $0.id == light.id }
  }

  private func brightness(_ light: LightItem, _ value: Int) {
    switch light.kind {
    case .strip:
      guard let s = stripUUID(light) else { break }
      wakeStrip(s)
      strip.setBrightness(s, value)
      updateLook(s) { $0.brightness = value }
    case .bulb: hub(light).map { hubspace.setBrightness($0, value) }
    case .bleBulb: lamp(light).map { lamps.setBrightness($0, value) }
    case .remote: break
    }
  }

  private func paint(_ light: LightItem, _ c: RGB) {
    switch light.kind {
    case .strip:
      guard let s = stripUUID(light) else { break }
      wakeStrip(s)
      strip.setColor(s, r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b))
      updateLook(s) {
        $0.color = c
        $0.kelvin = nil
      }
    case .bulb: hub(light).map { hubspace.setColor($0, r: c.r, g: c.g, b: c.b) }
    case .bleBulb: lamp(light).map { lamps.setColor($0, c) }
    case .remote: break
    }
  }

  private func white(_ light: LightItem, _ kelvin: Int) {
    switch light.kind {
    case .strip:
      // RGB-only strip: fake the temperature.
      guard let s = stripUUID(light) else { break }
      let c = RGB.kelvin(kelvin)
      wakeStrip(s)
      strip.setColor(s, r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b))
      updateLook(s) { $0.kelvin = kelvin }
    case .bulb: hub(light).map { hubspace.setWhite($0, kelvin: kelvin) }
    case .bleBulb: lamp(light).map { lamps.setWhite($0, kelvin) }
    case .remote: break
    }
  }

  /// Changing a look turns the strip on, like the bulb does on its own.
  private func wakeStrip(_ id: UUID) {
    guard stripLooks[id]?.on != true else { return }
    strip.setPower(id, true)
    updateLook(id) { $0.on = true }
  }

  private struct SavedLook: Codable { var on = false; var brightness = 100; var color = RGB.white; var kelvin: Int? }

  private func updateLook(_ id: UUID, _ change: (inout SavedLook) -> Void) {
    change(&stripLooks[id, default: SavedLook()])
    saveStrips()
  }

  private func saveStrips() {
    let saved = Dictionary(uniqueKeysWithValues: stripLooks.map { ($0.key.uuidString, $0.value) })
    UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "stripLooks")
  }

  // MARK: Effects (strips only: the bulb goes through Home Depot's cloud, too slow to follow a beat)

  /// The effect playing on this light, or on any strip in the room for `Room.all`.
  func effectPlaying(on id: String) -> Effect? {
    let playing = targets(id).contains { light in stripUUID(light).map { effectStrips.contains($0) } ?? false }
    return playing ? effect : nil
  }

  /// Starts an effect on one strip, or on every connected strip in the room for `Room.all`.
  func start(_ e: Effect, on id: String) {
    let strips = targets(id).compactMap(stripUUID)
    stopEffect()
    effectError = nil
    guard !strips.isEmpty else { return }
    for s in strips { wakeStrip(s) }
    mood = nil
    effect = e
    effectStrips = Set(strips)
    switch e {
    case .pattern(let p):
      for s in strips {
        strip.setPattern(s, p)
        strip.setSpeed(s, speed)
      }
    case .synced:
      // Each controller runs built-in effects on its own clock, so two strips drift apart. One clock in the app keeps them together.
      syncTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncStep() }
      }
    case .candle, .fire:
      // Full brightness once; the flicker lives in the color, so each frame is one write per strip.
      for s in strips {
        strip.setBrightness(s, 100)
        updateLook(s) { $0.brightness = 100 }
      }
      flameLevels = [:]
      syncTimer = Timer.scheduledTimer(withTimeInterval: e == .fire ? 0.09 : 0.14, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.flameStep() }
      }
    case .phoneMic:
      Task {
        guard await AVAudioApplication.requestRecordPermission() else {
          effectError = "Allow the microphone in Settings to use your phone's mic."
          effect = nil
          return
        }
        guard effect == .phoneMic else { return }
        do { try listen() } catch {
          effectError = "Couldn't start the microphone."
          stopEffect()
        }
      }
    }
  }

  /// Takes these lights out of the running effect; the effect ends when no strip is left in it.
  private func stopEffect(on lights: [LightItem]) {
    effectStrips.subtract(lights.compactMap(stripUUID))
    if effectStrips.isEmpty { stopEffect() }
  }

  /// Effect speed, 1–100: the built-in effects' speed command, and how fast the synced rainbow turns.
  private(set) var speed = UserDefaults.standard.object(forKey: "stripSpeed") as? Int ?? 50
  private var syncTimer: Timer?

  func setSpeed(_ value: Int) {
    speed = max(1, min(100, value))
    UserDefaults.standard.set(speed, forKey: "stripSpeed")
    if case .pattern = effect { for s in effectStrips { strip.setSpeed(s, speed) } }
  }

  /// One step of the synced rainbow: every strip gets the same color at the same moment. A full turn takes 60 s at
  /// speed 1 and about 3 s at 100.
  private func syncStep() {
    guard effect == .synced else { return }
    hue += 0.1 / (60 - Double(speed - 1) * 57 / 99)
    let c = RGB.hue(hue)
    for s in effectStrips { strip.setColor(s, r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b), fade: false) }
  }

  private var flameLevels: [UUID: Double] = [:]

  /// Each strip flickers on its own, so two strips look like two flames, not one copied.
  private func flameStep() {
    guard effect == .candle || effect == .fire else { return }
    for s in effectStrips {
      let (c, level) = Effect.flame(fire: effect == .fire, level: flameLevels[s] ?? 0.7,
                                    roll: Double.random(in: 0...1), hueRoll: Double.random(in: 0...1))
      flameLevels[s] = level
      strip.setColor(s, r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b), fade: false)
    }
  }

  /// Forgets the running effect. The strip leaves a built-in effect on its next color.
  func stopEffect() {
    syncTimer?.invalidate()
    syncTimer = nil
    effectStrips = []
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    engine = nil
    effect = nil
    level = 0
  }

  private func listen() throws {
    let session = AVAudioSession.sharedInstance()
    // Mix with others so Spotify keeps playing; measurement mode turns off voice processing.
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
    try session.setActive(true)
    let engine = AVAudioEngine()
    let input = engine.inputNode
    input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
      guard let data = buffer.floatChannelData?[0] else { return }
      let n = Int(buffer.frameLength)
      var sum: Float = 0
      for i in 0..<n { sum += data[i] * data[i] }
      let rms = Double((sum / Float(max(n, 1))).squareRoot())
      Task { @MainActor in self?.onSound(rms) }
    }
    try engine.start()
    self.engine = engine
  }

  /// ~20 updates a second. Loudness drives brightness; a jump above the running average is a beat and shifts the color.
  private func onSound(_ rms: Double) {
    guard effect == .phoneMic else { return }
    let db = 20 * log10(max(rms, 1e-6))
    let loud = max(0, min(1, (db + 55) / 45))
    // Reduce flashing: brightness falls slowly and never below 40 %, and colors fade at most every 1.5 s.
    let gentle = reduceFlashing
    level = max(loud, level * (gentle ? 0.96 : 0.8))
    average = average * 0.95 + loud * 0.05
    if loud > average + 0.15, loud > 0.3, Date().timeIntervalSince(lastBeat) > (gentle ? 1.5 : 0.25) {
      lastBeat = Date()
      hue += 0.13
      let c = RGB.hue(hue)
      for s in effectStrips { strip.setColor(s, r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b), fade: gentle) }
    }
    let floor = gentle ? 40.0 : 8.0
    for s in effectStrips { strip.setBrightness(s, Int(floor + level * (100 - floor))) }
  }

  /// Hides blink, flash and strobe effects and calms music mode, for anyone sensitive to flashing light.
  var reduceFlashing = UserDefaults.standard.bool(forKey: "reduceFlashing") {
    didSet { UserDefaults.standard.set(reduceFlashing, forKey: "reduceFlashing") }
  }

  /// Effect groups that flash: blink, flash and strobe.
  static let flashingGroups: Set<String> = ["Blink", "Flash", "Strobe"]
}
