import AVFoundation
import Foundation
import Observation
import SwiftUI

/// One list of lights, whatever the brand, so the UI never has to know which app a light came from.
struct RGB: Equatable, Codable {
  var r: Int, g: Int, b: Int

  static let white = RGB(r: 255, g: 255, b: 255)
  static let black = RGB(r: 0, g: 0, b: 0)

  static func hex(_ v: UInt32) -> RGB { RGB(r: Int(v >> 16 & 0xFF), g: Int(v >> 8 & 0xFF), b: Int(v & 0xFF)) }

  /// The same color at a lower level (0–1), for showing a dimmed frame.
  func scaled(_ level: Double) -> RGB {
    RGB(r: Int(Double(r) * level), g: Int(Double(g) * level), b: Int(Double(b) * level))
  }

  /// Smoothly around a list of colors, one color per unit of `x`.
  static func blend(_ colors: [RGB], _ x: Double) -> RGB {
    guard !colors.isEmpty else { return .white }
    let n = colors.count
    let whole = floor(max(0, x))
    let f = max(0, x) - whole
    let a = colors[Int(whole) % n], b = colors[(Int(whole) + 1) % n]
    let mix = { (p: Int, q: Int) in Int(Double(p) + Double(q - p) * f) }
    return RGB(r: mix(a.r, b.r), g: mix(a.g, b.g), b: mix(a.b, b.b))
  }

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

  /// A plain name for the color ("Orange", "Soft pink"), for tiles and VoiceOver, so nobody has to judge a swatch.
  var name: String {
    let (h, s) = hueSaturation
    if s < 0.12 { return "White" }
    let bands: [(Double, String)] = [
      (0.03, "Red"), (0.09, "Orange"), (0.14, "Amber"), (0.19, "Yellow"), (0.27, "Lime"), (0.42, "Green"), (0.5, "Teal"),
      (0.55, "Cyan"), (0.62, "Sky blue"), (0.7, "Blue"), (0.78, "Violet"), (0.86, "Purple"), (0.96, "Pink"), (1.01, "Red"),
    ]
    let base = bands.first { h < $0.0 }?.1 ?? "Red"
    return s < 0.45 ? "Soft " + base.lowercased() : base
  }

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

  /// Which group a built-in pattern is in ("Fade", "Blink"…), which decides how it moves.
  static func group(of id: UInt8) -> String {
    patternGroups.first { $0.1.contains { $0.id == id } }?.0 ?? "Switch"
  }

  /// Roughly what a built-in pattern shows `t` seconds in, so the app's tiles move along with the strip.
  /// The controller runs the real thing on its own clock; this only has to look like it.
  static func preview(_ id: UInt8, at t: Double, speed: Int) -> RGB {
    guard let p = patterns.first(where: { $0.id == id }), !p.colors.isEmpty else { return .white }
    // ponytail: step lengths are eyeballed (2 s per color at speed 1, 0.2 s at 100); the controller's real timing
    // isn't published. Watch a strip next to the app and adjust if they look far apart.
    let step = 2.0 - 1.8 * Double(max(1, min(100, speed)) - 1) / 99
    let colors = p.colors
    switch group(of: id) {
    case "Fade": return RGB.blend(colors, t / (step * 2))
    case "Flash": return colors[Int(t / (step / 2)) % colors.count]
    case "Strobe": return colors[Int(t / (step / 3)) % colors.count]
    default: return colors[Int(t / step) % colors.count]
    }
  }

  /// The Hubspace bulb's closest built-in effect, so a cloud bulb can join a strip pattern. Nil: hold the first color.
  static func hubEffect(for id: UInt8) -> String? {
    guard let p = patterns.first(where: { $0.id == id }) else { return nil }
    let many = p.colors.count > 3
    switch group(of: id) {
    case "Fade": return many ? "fade-7" : "fade-3"
    case "Switch", "Strobe": return many ? "jump-7" : "jump-3"
    default: return many ? "jump-7" : nil
    }
  }

  var name: String {
    switch self {
    case .pattern(let id): Self.patterns.first { $0.id == id }?.name ?? "Effect"
    case .phoneMic: "Phone mic"
    case .synced: "Rainbow in sync"
    case .candle: "Candlelight"
    case .fire: "Fireplace"
    }
  }

  /// The colors it's drawn with on cards and the now-playing bar.
  var colors: [RGB] {
    switch self {
    case .pattern(let id): Self.patterns.first { $0.id == id }?.colors.filter { $0 != .black } ?? Self.rainbow
    case .phoneMic: [.hex(0xFF2D78), .hex(0xC56BFF), .hex(0x00D9FF)]
    case .synced: Self.rainbow
    case .candle: [.hex(0xFF8C1A), .hex(0xFFB347), .hex(0x7A3A00)]
    case .fire: [.hex(0xFF3B00), .hex(0xFF8A00), .hex(0x5A1400)]
    }
  }

  /// Built-in patterns have a speed; the flames and music set their own pace.
  var hasSpeed: Bool {
    switch self {
    case .pattern, .synced: true
    case .phoneMic, .candle, .fire: false
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
  /// The lights the running effect plays on, by light id: strips, Bluetooth bulbs, and (for the whole room) the cloud bulb.
  private(set) var effectLights: Set<String> = []
  /// Each light's look from before the effect, so Stop puts it back.
  private var effectRestore: [String: Mood.Snap] = [:]
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
    walkIn.room = self
    strip.onConnect = { [weak self] id in
      MainActor.assumeIsolated { self?.walkIn.stripConnected(id) }
    }
    strip.onDrop = { [weak self] _ in
      MainActor.assumeIsolated { self?.walkIn.stripDropped() }
    }
    lamps.onConnect = { [weak self] in
      MainActor.assumeIsolated { self?.walkIn.lightReady() }
    }
    displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshLive() }
    }
  }

  let walkIn = WalkIn()

  // MARK: What the lights show right now

  /// Each light's color at this moment while something moves on it (an effect, a bulb's own effect), by light id.
  /// The tiles, the power button and the glow read this, so the screen moves with the room.
  private(set) var live: [String: RGB] = [:]
  /// The last frame the app sent to each light in an app-run effect.
  private var sent: [String: RGB] = [:]
  private var displayTimer: Timer?
  private let clockStart = Date()

  /// The color to draw a light with: what it's showing right now.
  func shown(_ item: LightItem) -> RGB { live[item.id] ?? item.glow }

  private func refreshLive() {
    var next: [String: RGB] = [:]
    let t = Date().timeIntervalSince(clockStart)
    if let effect {
      for id in effectLights {
        if case .pattern(let p) = effect { next[id] = Effect.preview(p, at: t, speed: speed) } else if let c = sent[id] { next[id] = c }
      }
    }
    // A Hubspace bulb running its own effect.
    for light in hubspace.lights where light.on {
      guard let e = light.effect, next["hub:" + light.id] == nil else { continue }
      next["hub:" + light.id] = HubspaceClient.preview(e, at: t, speed: light.speed)
    }
    if next != live { live = next }
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
    var r = 0.0, g = 0.0, b = 0.0
    for light in on {
      let c = shown(light)
      r += Double(c.r)
      g += Double(c.g)
      b += Double(c.b)
    }
    return Color(red: r / n / 255, green: g / n / 255, blue: b / n / 255)
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
    let lights = targets(id)
    if !on { stopEffect(on: lights) }
    mood = nil
    guard lights.count > 1 else {
      cancelSweep()
      lights.forEach { power($0, on) }
      return
    }
    // Several lights: they switch together, so the strips wait for the cloud bulb. The switches move right away.
    for light in lights { stripUUID(light).map { s in updateLook(s) { $0.on = on } } }
    together(lights) { [weak self] in self?.power($0, on) }
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
    // The scene stays selected, like Hue: dimming it is still that scene, and Drift (colors only) keeps going.
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
    play(m, on: roomReady.filter { $0.kind != .remote })
    // Party switches colors on the strip; with Reduce flashing it rolls a smooth rainbow instead.
    if case .party = m.look { start(reduceFlashing ? .synced : .pattern(10), on: Self.all) }
    mood = m.id
    startLiving(m)
  }

  /// A scene's look on these lights, rolled across the room.
  private func play(_ m: Mood, on lights: [LightItem]) {
    let order = mapOrder(roomReady.filter { $0.kind != .remote })
    let shift = shuffle
    sweep(lights) { [weak self] light in
      guard let self else { return }
      if case .snapshot(let snaps) = m.look {
        // Lights added after the scene was saved stay as they are.
        guard let snap = snaps[light.id] else { return }
        guard snap.on else { return self.power(light, false) }
        self.setLook(light, brightness: snap.brightness, color: snap.color, kelvin: snap.kelvin)
        return
      }
      switch m.look {
      case .color(let c): self.setLook(light, brightness: m.brightness, color: c)
      case .white(let k): self.setLook(light, brightness: m.brightness, kelvin: k)
      case .party: self.setLook(light, brightness: m.brightness, color: RGB(r: 255, g: 0, b: 180))
      case .palette(let colors): self.setLook(light, brightness: m.brightness, color: self.paletteColor(light, colors, order, shift))
      case .snapshot: break
      }
    }
  }

  /// Walk in: the welcome on the selected room's lights, skipping `except` (lights already welcomed). A late light
  /// only gets lit if it's off, so one you switched on yourself is left alone. Returns the lights it lit.
  @discardableResult
  func welcome(scene id: String?, except: Set<String> = [], late: Bool = false) -> [String] {
    let lights = roomReady.filter { $0.caps.contains(.power) && !except.contains($0.id) && !(late && $0.on) }
    guard !lights.isEmpty else { return [] }
    let m = id.flatMap { id in moods.first { $0.id == id } }
    if let m, !late {
      apply(m)
    } else if let m {
      play(m, on: lights)
    } else {
      mood = nil
      together(lights) { [weak self] in self?.power($0, true) }
      for light in lights { stripUUID(light).map { s in updateLook(s) { $0.on = true } } }
    }
    return lights.map(\.id)
  }

  /// Walk in, leaving: turns off what the app can still reach once you're gone, the cloud bulbs in your strips' rooms.
  /// Returns how many it turned off.
  func leaveOff() -> Int {
    let rooms = Set(items.filter { $0.kind == .strip }.map(roomOf))
    let bulbs = ready.filter { $0.kind == .bulb && $0.on && rooms.contains(roomOf($0)) }
    bulbs.forEach { power($0, false) }
    return bulbs.count
  }

  private var shuffle = 0

  /// Palette colors go around the room in map order (seen from your spot), so neighbors differ. Unplaced lights go last.
  private func mapOrder(_ lights: [LightItem]) -> [String: Int] {
    let angle = { (l: LightItem) in self.placements[l.id].map { atan2($0.y - self.you.y, $0.x - self.you.x) } ?? .infinity }
    return Dictionary(uniqueKeysWithValues: lights.sorted { angle($0) < angle($1) }.enumerated().map { ($1.id, $0) })
  }

  private func paletteColor(_ light: LightItem, _ colors: [RGB], _ order: [String: Int], _ shift: Int) -> RGB {
    let c = colors[((order[light.id] ?? 0) + shift) % colors.count]
    return light.kind == .strip ? c.vivid : c
  }

  /// Brightness and color in one go. The cloud bulb gets them as one command, so it changes in one step, not two.
  private func setLook(_ light: LightItem, brightness level: Int, color: RGB? = nil, kelvin: Int? = nil) {
    if light.kind == .bulb, let h = hub(light) {
      hubspace.setLook(h, brightness: level, color: color, kelvin: kelvin)
      return
    }
    brightness(light, level)
    if let kelvin { white(light, kelvin) } else if let color { paint(light, color) }
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
        let shift = self.shuffle
        // Together, so the cloud bulb hands its color on at the same moment as the strips.
        self.together(lights.filter(\.on)) { [weak self] light in
          guard let self else { return }
          self.paint(light, self.paletteColor(light, colors, order, shift))
        }
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

  /// Where a light is on the room map, in meters from where you stood for "Find my lights": x right, y toward the back
  /// (the top of the map is the way you faced). Plus how long it takes to react, and whether the scan measured that.
  /// Spots saved before the scan used meters were -1…1; the map scales to fit, so they still show in the right order.
  struct Placement: Codable {
    var x: Double
    var y: Double
    var latency: Double
    var found: Bool
  }

  /// How a change travels across the room.
  enum SweepStyle: String, CaseIterable, Codable {
    case around = "Around you", leftRight = "Left to right", frontBack = "Front to back", outward = "Out from you", together = "All at once"
  }

  private(set) var placements: [String: Placement] = {
    guard let data = UserDefaults.standard.data(forKey: "placements") else { return [:] }
    return (try? JSONDecoder().decode([String: Placement].self, from: data)) ?? [:]
  }()
  /// Where you usually are on the map; "Around you" and "Out from you" start here.
  private(set) var you: CGPoint = {
    let saved = UserDefaults.standard.array(forKey: "mapYou") as? [Double] ?? []
    return saved.count == 2 ? CGPoint(x: saved[0], y: saved[1]) : .zero
  }()
  var sweepStyle = SweepStyle(rawValue: UserDefaults.standard.string(forKey: "sweepStyle") ?? "") ?? .around {
    didSet { UserDefaults.standard.set(sweepStyle.rawValue, forKey: "sweepStyle") }
  }
  /// Your nudge per light from "Keep lights in sync", in seconds: positive means it shows changes late, so it's sent earlier.
  private(set) var syncNudge = UserDefaults.standard.dictionary(forKey: "syncNudge") as? [String: Double] ?? [:]
  private var sweepTasks: [Task<Void, Never>] = []
  private var sweepColor = 0
  private var scanSaved: [LightItem] = []

  /// Total time for a change to travel across the room.
  static let sweepTime = 1.2

  func setPlacement(_ id: String, x: Double, y: Double) {
    let old = placements[id]
    placements[id] = Placement(x: x, y: y, latency: old?.latency ?? 0, found: old?.found ?? false)
    savePlacements()
  }

  func clearPlacement(_ id: String) {
    placements[id] = nil
    savePlacements()
  }

  func setYou(x: Double, y: Double) {
    you = CGPoint(x: x, y: y)
    UserDefaults.standard.set([x, y], forKey: "mapYou")
  }

  func setNudge(_ id: String, _ seconds: Double) {
    syncNudge[id] = abs(seconds) < 0.05 ? nil : seconds
    UserDefaults.standard.set(syncNudge, forKey: "syncNudge")
  }

  /// Seconds from sending a command to seeing it: what the scan measured, else a live estimate (the cloud bulb's
  /// round trip to Hubspace), plus your nudge.
  func latency(_ l: LightItem) -> Double {
    let measured = placements[l.id].flatMap { $0.found && $0.latency > 0 ? $0.latency : nil }
    let base = measured ?? (l.kind == .bulb ? hubspace.expectedDelay : l.kind == .bleBulb ? 0.1 : 0.15)
    return max(0, base + (syncNudge[l.id] ?? 0))
  }

  private func savePlacements() { UserDefaults.standard.set(try? JSONEncoder().encode(placements), forKey: "placements") }

  private func cancelSweep() {
    sweepTasks.forEach { $0.cancel() }
    sweepTasks = []
  }

  /// The same change on every light, landing at the same moment: fast lights wait out the slowest one's delay.
  private func together(_ lights: [LightItem], _ action: @escaping @MainActor (LightItem) -> Void) {
    sweep(lights, spread: false, action)
  }

  /// How far along the sweep each placed light is, 0 (first) to 1 (last). Unplaced lights aren't in it and go first.
  private func sweepProgress(_ lights: [LightItem]) -> [String: Double] {
    let placed = lights.compactMap { l in placements[l.id].map { (l.id, $0) } }
    guard placed.count >= 2 else { return [:] }
    let normalize = { (values: [(String, Double)]) -> [String: Double] in
      let lo = values.map(\.1).min() ?? 0, hi = values.map(\.1).max() ?? 0
      return Dictionary(uniqueKeysWithValues: values.map { ($0.0, hi - lo < 0.001 ? 0 : ($0.1 - lo) / (hi - lo)) })
    }
    switch sweepStyle {
    case .together: return [:]
    case .leftRight: return normalize(placed.map { ($0.0, $0.1.x) })
    case .frontBack: return normalize(placed.map { ($0.0, $0.1.y) })
    case .outward: return normalize(placed.map { ($0.0, hypot($0.1.x - you.x, $0.1.y - you.y)) })
    case .around:
      let angles = placed.map { ($0.0, atan2($0.1.y - you.y, $0.1.x - you.x)) }
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
      return Dictionary(uniqueKeysWithValues: angles.map { id, a in
        (id, min(1, ((a - start + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)) / span))
      })
    }
  }

  /// When each light's turn comes in the sweep, in seconds after the first. For the map's animation.
  func sweepSchedule(_ lights: [LightItem]) -> [String: Double] {
    sweepProgress(lights).mapValues { $0 * Self.sweepTime }
  }

  /// Runs `action` on each light so the change rolls across the room in the chosen style, and every light shows it
  /// on its turn: slow lights (the cloud bulb) are sent early by their extra delay.
  private func sweep(_ lights: [LightItem], spread: Bool = true, _ action: @escaping @MainActor (LightItem) -> Void) {
    cancelSweep()
    let slowest = lights.map(latency).max() ?? 0
    let progress = spread ? sweepProgress(lights) : [:]
    for light in lights {
      let delay = (progress[light.id] ?? 0) * Self.sweepTime + (slowest - latency(light))
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

  /// Rolls the next color across the room so the order and timing can be checked. Returns when each light's turn is.
  @discardableResult
  func testSweep() -> [String: Double] {
    let colors = [RGB(r: 255, g: 90, b: 30), RGB(r: 0, g: 140, b: 255), RGB(r: 140, g: 0, b: 255), RGB(r: 0, g: 220, b: 120)]
    let c = colors[sweepColor % colors.count]
    sweepColor += 1
    stopEffect()
    mood = nil
    let lights = roomReady.filter { $0.caps.contains(.color) }
    sweep(lights) { [weak self] in self?.paint($0, c) }
    return sweepSchedule(lights)
  }

  /// "Keep lights in sync": every light in the room goes dark, then comes back at once, timed by each light's delay.
  /// If one shows up late, nudge it on the map screen. Lights that were off end up off again.
  func flashTogether() {
    stopEffect()
    mood = nil
    let lights = roomReady.filter { $0.caps.contains(.power) }
    let wasOn = Set(lights.filter(\.on).map(\.id))
    let wait = (lights.map(latency).max() ?? 0) + 1.5
    cancelSweep()
    lights.forEach { scanPower($0.id, false) }
    sweepTasks.append(Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(wait))
      guard let self, !Task.isCancelled else { return }
      self.together(lights) { self.scanPower($0.id, true) }
      try? await Task.sleep(for: .seconds(wait + 2))
      guard !Task.isCancelled else { return }
      for light in lights where !wasOn.contains(light.id) { self.scanPower(light.id, false) }
    })
  }

  /// Blinks one light twice, so you can tell which dot on the map it is. Ends the way it started.
  func identify(_ id: String) {
    guard let light = item(id), light.status == .ready else { return }
    let gap = max(0.5, latency(light) + 0.4)
    let start = light.on
    Task { @MainActor [weak self] in
      for step in 0..<4 {
        self?.scanPower(id, step % 2 == 0 ? !start : start)
        try? await Task.sleep(for: .seconds(gap))
      }
    }
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

  /// Puts each found light on the map, in meters from where you stood, which becomes your spot.
  func scanFinished(_ found: [String: LightScanner.Result]) {
    for (id, r) in found {
      placements[id] = Placement(x: r.x, y: r.y, latency: r.latency, found: true)
    }
    if !found.isEmpty { setYou(x: 0, y: 0) }
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


  // MARK: Effects

  /// The effect playing on this light, or on any light in the room for `Room.all`.
  func effectPlaying(on id: String) -> Effect? {
    targets(id).contains { effectLights.contains($0.id) } ? effect : nil
  }

  /// The lights in the running effect, as they are now.
  private var effectItems: [LightItem] { ready.filter { effectLights.contains($0.id) } }

  /// Starts an effect on one light, or on every light in the room for `Room.all`. Strips and Bluetooth bulbs take every
  /// frame. The cloud bulb joins room-wide effects as well as it can: its own matching effect, or a color every few
  /// seconds sent ahead by its delay, so it keeps pace instead of trailing.
  func start(_ e: Effect, on id: String) {
    let roomWide = id == Self.all || id == Self.everything
    let lights = targets(id).filter { $0.kind == .strip || $0.kind == .bleBulb || ($0.kind == .bulb && roomWide) }
    stopEffect()
    effectError = nil
    guard !lights.isEmpty else { return }
    if case .pattern(let p) = e, Self.flashingGroups.contains(Effect.group(of: p)), !reduceFlashing, !flashWarned {
      flashWarned = true
      flashWarning = true
    }
    mood = nil
    effect = e
    effectLights = Set(lights.map(\.id))
    effectRestore = Dictionary(uniqueKeysWithValues: lights.map {
      ($0.id, Mood.Snap(color: $0.color, kelvin: $0.kelvin, brightness: $0.brightness, on: $0.on))
    })
    for light in lights {
      if let s = stripUUID(light) { wakeStrip(s) }
      if light.kind == .bleBulb, !light.on, let l = lamp(light) { lamps.setPower(l, true) }
    }
    switch e {
    case .pattern(let p):
      for light in lights {
        if let s = stripUUID(light) {
          strip.setPattern(s, p)
          strip.setSpeed(s, speed)
        } else if light.kind == .bulb, let h = hub(light) {
          if let builtIn = Effect.hubEffect(for: p) {
            hubspace.setEffect(h, builtIn)
            hubspace.setEffectSpeed(h, hubSpeed)
          } else if let first = Effect.patterns.first(where: { $0.id == p })?.colors.first {
            hubspace.setColor(h, r: first.r, g: first.g, b: first.b)
          }
        }
      }
      // Bluetooth bulbs have no built-in patterns, so the app plays the pattern on them.
      if lights.contains(where: { $0.kind == .bleBulb }) { tick(0.1) { $0.patternStep() } }
    case .synced:
      // Each controller runs built-in effects on its own clock, so two strips drift apart. One clock in the app keeps them together.
      tick(0.1) { $0.syncStep() }
    case .candle, .fire:
      // Full brightness once; the flicker lives in the color, so each frame is one write per light.
      for light in lights where light.kind != .bulb { brightness(light, 100) }
      flameLevels = [:]
      tick(e == .fire ? 0.09 : 0.14) { $0.flameStep() }
    case .phoneMic:
      Task {
        guard await AVAudioApplication.requestRecordPermission() else {
          effectError = "Allow the microphone in Settings to use your phone's mic."
          stopEffect()
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

  /// The Stop button: ends the effect and puts each light back the way it was before it started, all at once.
  func endEffect() {
    let restore = effectRestore
    let lights = effectItems
    stopEffect()
    together(lights) { [weak self] light in
      guard let self, let snap = restore[light.id] else { return }
      guard snap.on else { return self.power(light, false) }
      self.setLook(light, brightness: snap.brightness, color: snap.color, kelvin: snap.kelvin)
    }
  }

  /// Takes these lights out of the running effect; the effect ends when no light is left in it.
  private func stopEffect(on lights: [LightItem]) {
    effectLights.subtract(lights.map(\.id))
    if effectLights.isEmpty { stopEffect() }
  }

  /// Effect speed, 1–100: the built-in effects' speed command, and how fast the synced rainbow turns.
  private(set) var speed = UserDefaults.standard.object(forKey: "stripSpeed") as? Int ?? 50
  private var syncTimer: Timer?
  /// The same speed on the Hubspace scale, -10 to 10.
  private var hubSpeed: Int { max(-10, min(10, (speed - 50) / 5)) }

  func setSpeed(_ value: Int) {
    speed = max(1, min(100, value))
    UserDefaults.standard.set(speed, forKey: "stripSpeed")
    guard case .pattern = effect else { return }
    for light in effectItems {
      if let s = stripUUID(light) { strip.setSpeed(s, speed) }
      if light.kind == .bulb, let h = hub(light), h.effect != nil { hubspace.setEffectSpeed(h, hubSpeed) }
    }
  }

  private func tick(_ interval: Double, _ step: @escaping @MainActor (Room) -> Void) {
    syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { if let self { step(self) } }
    }
  }

  /// One frame to a fast light (strip or Bluetooth bulb), straight away.
  private func stream(_ light: LightItem, _ c: RGB, fade: Bool = false) {
    switch light.kind {
    case .strip: stripUUID(light).map { strip.setColor($0, r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b), fade: fade) }
    case .bleBulb: lamp(light).map { lamps.stream($0, c) }
    case .bulb, .remote: return
    }
    sent[light.id] = c
  }

  private var cloudNext: [String: Date] = [:]

  /// One frame to the cloud bulb, at most every `seconds`. `color` is given the bulb's delay, so it can aim that far ahead.
  private func cloudFrame(_ light: LightItem, every seconds: Double, _ color: (Double) -> RGB) {
    guard light.kind == .bulb, Date() >= cloudNext[light.id] ?? .distantPast, let h = hub(light) else { return }
    cloudNext[light.id] = Date().addingTimeInterval(seconds)
    let c = color(latency(light))
    hubspace.setColor(h, r: c.r, g: c.g, b: c.b)
  }

  /// Built-in patterns, played by the app on Bluetooth bulbs (the strips run their own).
  private func patternStep() {
    guard case .pattern(let p) = effect else { return }
    let c = Effect.preview(p, at: Date().timeIntervalSince(clockStart), speed: speed)
    for light in effectItems where light.kind == .bleBulb { stream(light, c) }
  }

  /// One step of the synced rainbow: every light gets the same color at the same moment. A full turn takes 60 s at
  /// speed 1 and about 3 s at 100.
  private func syncStep() {
    guard effect == .synced else { return }
    let turn = 60 - Double(speed - 1) * 57 / 99
    hue += 0.1 / turn
    let c = RGB.hue(hue)
    let now = hue
    for light in effectItems {
      if light.kind == .bulb {
        sent[light.id] = c
        // ponytail: one color every 3 s, aimed ahead by the bulb's delay; its own fade fills the gaps. Faster would
        // risk Hubspace's rate limit, which isn't published (aioafero docs: "the API rate-limits requests").
        cloudFrame(light, every: 3) { ahead in RGB.hue(now + ahead / turn) }
      } else {
        stream(light, c)
      }
    }
  }

  private var flameLevels: [String: Double] = [:]

  /// Each light flickers on its own, so two strips look like two flames, not one copied. The cloud bulb glows and
  /// shifts every few seconds.
  private func flameStep() {
    guard effect == .candle || effect == .fire else { return }
    let fire = effect == .fire
    for light in effectItems {
      let (c, level) = Effect.flame(fire: fire, level: flameLevels[light.id] ?? 0.7,
                                    roll: Double.random(in: 0...1), hueRoll: Double.random(in: 0...1))
      flameLevels[light.id] = level
      if light.kind == .bulb {
        sent[light.id] = c
        cloudFrame(light, every: 4) { _ in c }
      } else {
        stream(light, c)
      }
    }
  }

  /// Forgets the running effect. A strip leaves a built-in effect on its next color.
  func stopEffect() {
    syncTimer?.invalidate()
    syncTimer = nil
    effectLights = []
    effectRestore = [:]
    sent = [:]
    cloudNext = [:]
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
    let beat = loud > average + 0.15 && loud > 0.3 && Date().timeIntervalSince(lastBeat) > (gentle ? 1.5 : 0.25)
    if beat {
      lastBeat = Date()
      hue += 0.13
    }
    let c = RGB.hue(hue)
    let floor = gentle ? 40.0 : 8.0
    let percent = Int(floor + level * (100 - floor))
    for light in effectItems {
      switch light.kind {
      case .strip:
        guard let s = stripUUID(light) else { continue }
        if beat { strip.setColor(s, r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b), fade: gentle) }
        strip.setBrightness(s, percent)
        sent[light.id] = c.scaled(Double(percent) / 100)
      case .bleBulb:
        stream(light, c.scaled(Double(percent) / 100))
      case .bulb:
        sent[light.id] = c
        if beat { cloudFrame(light, every: 2.5) { _ in c } }
      case .remote: break
      }
    }
  }

  /// Hides blink, flash and strobe effects and calms music mode, for anyone sensitive to flashing light.
  var reduceFlashing = UserDefaults.standard.bool(forKey: "reduceFlashing") {
    didSet { UserDefaults.standard.set(reduceFlashing, forKey: "reduceFlashing") }
  }

  /// Set the first time a flashing effect starts, so the app offers Reduce flashing once (Govee does the same;
  /// a DayBetter reviewer with epilepsy bought strips for soft light and got flashing).
  var flashWarning = false
  private var flashWarned = UserDefaults.standard.bool(forKey: "flashWarned") {
    didSet { UserDefaults.standard.set(flashWarned, forKey: "flashWarned") }
  }

  // MARK: Sleep timer

  /// When the lights go out. iOS pauses the app once the phone locks, so the timer keeps the app open on a black
  /// screen until then (SleepScreen). Reviewers of DayBetter's app ask for exactly this: a timer for falling asleep.
  private(set) var sleepAt: Date?
  private var sleepTask: Task<Void, Never>?

  func sleep(in minutes: Int) {
    cancelSleep()
    let start = roomReady.filter(\.on).map(\.brightness).max() ?? 0
    guard start > 0 else { return }
    let total = Double(minutes * 60)
    sleepAt = Date().addingTimeInterval(total)
    sleepTask = Task { @MainActor [weak self] in
      // Holds for the first half, then dims in ten steps, too slow to notice.
      try? await Task.sleep(for: .seconds(total / 2))
      for step in stride(from: 9, through: 1, by: -1) {
        guard !Task.isCancelled, let self else { return }
        self.setBrightness(Self.all, max(1, start * step / 10))
        try? await Task.sleep(for: .seconds(total / 20))
      }
      guard !Task.isCancelled, let self else { return }
      self.setPower(Self.all, false)
      self.cancelSleep()
    }
  }

  func cancelSleep() {
    sleepTask?.cancel()
    sleepTask = nil
    sleepAt = nil
  }

  /// Effect groups that flash: blink, flash and strobe.
  static let flashingGroups: Set<String> = ["Blink", "Flash", "Strobe"]
}
