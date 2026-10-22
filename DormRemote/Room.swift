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
}

struct LightItem: Identifiable {
  enum Kind { case strip, bulb, bleBulb, projector }
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
}

/// Room-wide presets, applied to every light at once.
struct Mood: Identifiable {
  enum Look { case color(RGB), white(Int), party }
  let id: String
  let look: Look
  let brightness: Int

  static let all: [Mood] = [
    Mood(id: "Relax", look: .white(2700), brightness: 60),
    Mood(id: "Focus", look: .white(5000), brightness: 100),
    Mood(id: "Sunset", look: .color(RGB(r: 255, g: 90, b: 30)), brightness: 70),
    Mood(id: "Ocean", look: .color(RGB(r: 0, g: 140, b: 255)), brightness: 70),
    Mood(id: "Movie", look: .color(RGB(r: 40, g: 40, b: 255)), brightness: 15),
    Mood(id: "Night", look: .color(RGB(r: 255, g: 20, b: 0)), brightness: 5),
    Mood(id: "Party", look: .party, brightness: 100),
  ]

  var swatch: [Color] {
    switch look {
    case .color(let c): [c.color, c.color.opacity(0.5)]
    case .white(let k): [RGB.kelvin(k).color, RGB.kelvin(k + 1500).color]
    case .party: [.pink, .purple, .blue, .cyan]
    }
  }
}

/// Strip effects. Patterns and strip-mic music run on the controller; phone-mic music runs in the app.
enum Effect: Hashable {
  case pattern(UInt8), stripMic(UInt8), phoneMic

  struct Pattern: Identifiable {
    let name: String
    let id: UInt8
    let colors: [RGB]
  }

  static let rainbow = [RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 160, b: 0), RGB(r: 255, g: 255, b: 0), RGB(r: 0, g: 255, b: 0),
                        RGB(r: 0, g: 200, b: 255), RGB(r: 0, g: 0, b: 255), RGB(r: 160, g: 0, b: 255)]
  static let three = [RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 255, b: 0), RGB(r: 0, g: 0, b: 255)]

  // Mode ids from the PsychedelicPalimpsest DayBetter gateway (checked live on a QC strip), in IR-remote order:
  // 9–10 jump, 11–12 fade, 13–19 blink one color, 20–22 two-color fade, 23 flash all, 24–30 flash one color, 31–32 strobe.
  static let singles: [(String, RGB)] = [
    ("Red", RGB(r: 255, g: 0, b: 0)), ("Green", RGB(r: 0, g: 255, b: 0)), ("Blue", RGB(r: 0, g: 0, b: 255)),
    ("Yellow", RGB(r: 255, g: 255, b: 0)), ("Teal", RGB(r: 0, g: 255, b: 255)), ("Purple", RGB(r: 160, g: 0, b: 255)),
    ("White", RGB(r: 255, g: 255, b: 255)),
  ]
  static let patternGroups: [(String, [Pattern])] = {
    let off = RGB(r: 0, g: 0, b: 0)
    let jump: [Pattern] = [Pattern(name: "Jump 3", id: 9, colors: three), Pattern(name: "Jump 7", id: 10, colors: rainbow)]
    let fade: [Pattern] = [
      Pattern(name: "Fast fade", id: 11, colors: rainbow), Pattern(name: "Slow fade", id: 12, colors: rainbow),
      Pattern(name: "Red & green", id: 20, colors: [three[0], three[1]]),
      Pattern(name: "Red & blue", id: 21, colors: [three[0], three[2]]),
      Pattern(name: "Green & blue", id: 22, colors: [three[1], three[2]]),
    ]
    var blink: [Pattern] = []
    var flash: [Pattern] = [Pattern(name: "Flash all", id: 23, colors: rainbow)]
    for (i, single) in singles.enumerated() {
      blink.append(Pattern(name: single.0 + " blink", id: UInt8(13 + i), colors: [single.1, off]))
      flash.append(Pattern(name: single.0 + " flash", id: UInt8(24 + i), colors: [single.1, off]))
    }
    let strobe: [Pattern] = [Pattern(name: "Strobe", id: 31, colors: [.white, off]), Pattern(name: "Strobe 2", id: 32, colors: rainbow)]
    return [("Jump", jump), ("Fade", fade), ("Blink", blink), ("Flash", flash), ("Strobe", strobe)]
  }()
  static let patterns = patternGroups.flatMap(\.1)

  static let micStyles = ["Classic", "Soft", "Dynamic", "Disco"]

  var name: String {
    switch self {
    case .pattern(let id): Self.patterns.first { $0.id == id }?.name ?? "Pattern"
    case .stripMic(let style): Self.micStyles[Int(style)]
    case .phoneMic: "Phone mic"
    }
  }
}

@MainActor
@Observable
final class Room {

  static let all = "all"
  static let stripID = "strip"

  let strip: StripController
  let hubspace: HubspaceClient
  let bridge: BridgeController
  let lamps: BulbBank

  private(set) var effect: Effect?
  private(set) var mood: String?
  /// Music level 0–1 for the meter.
  private(set) var level: Double = 0
  var effectError: String?

  // The strip never reports its state, so remember what we last sent.
  private var stripLook: LightItem
  private var names: [String: String]
  private var engine: AVAudioEngine?
  private var hue = 0.0
  private var lastBeat = Date.distantPast
  private var average: Double = 0
  /// Effect speed, 1–100.
  private(set) var speed = UserDefaults.standard.object(forKey: "speed") as? Int ?? 50
  /// Strip mic sensitivity, 0–255.
  private(set) var sensitivity = UserDefaults.standard.object(forKey: "sensitivity") as? Int ?? 128

  init(strip: StripController, hubspace: HubspaceClient, bridge: BridgeController, lamps: BulbBank) {
    self.strip = strip
    self.hubspace = hubspace
    self.bridge = bridge
    self.lamps = lamps
    names = UserDefaults.standard.dictionary(forKey: "names") as? [String: String] ?? [:]
    stripLook = LightItem(id: Self.stripID, name: "LED strip", kind: .strip, status: .setup)
    if let data = UserDefaults.standard.data(forKey: "stripLook"),
       let saved = try? JSONDecoder().decode(SavedLook.self, from: data) {
      stripLook.on = saved.on
      stripLook.brightness = saved.brightness
      stripLook.color = saved.color
      stripLook.kelvin = saved.kelvin
    }
    strip.onStatus = { [weak self] status in
      MainActor.assumeIsolated { self?.apply(status) }
    }
  }

  /// The strip's own report wins over what we remember, so IR remote changes show up here.
  private func apply(_ status: StripStatus) {
    stripLook.on = status.on
    stripLook.brightness = status.brightness
    switch status.mode {
    case 0x01:
      stripLook.color = RGB(r: status.r, g: status.g, b: status.b)
      stripLook.kelvin = nil
      if case .pattern = effect { effect = nil }
      if case .stripMic = effect { effect = nil }
    case Daybetter.micMode:
      if effect != .phoneMic { effect = .stripMic(status.subMode) }
    case let mode where Effect.patterns.contains(where: { $0.id == mode }):
      effect = .pattern(mode)
    default:
      break
    }
    saveStrip()
  }

  // MARK: Lights

  var items: [LightItem] {
    var strip = stripLook
    strip.name = names[Self.stripID] ?? "LED strip"
    strip.status = switch self.strip.state {
    case .connected: .ready
    case .connecting, .unlocking: .busy("Connecting")
    case .off: .offline("Bluetooth is off")
    case .failed(let m): .offline(m)
    case .idle, .scanning: self.strip.hasSaved ? .busy("Looking") : .setup
    }

    var list = [strip]
    let placeholder = { (status: LightItem.Status) in
      LightItem(id: "hub", name: "Smart bulb", kind: .bulb, status: status)
    }
    switch hubspace.state {
    case .ready:
      list += hubspace.lights.map { l in
        LightItem(id: "hub:" + l.id, name: names["hub:" + l.id] ?? l.name, kind: .bulb, status: .ready,
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
    let projectorStatus: LightItem.Status = switch bridge.state {
    case .ready: .ready
    case .connecting: .busy("Connecting to bridge")
    case .off, .searching: .setup
    }
    list.append(LightItem(id: "projector", name: names["projector"] ?? "Galaxy projector", kind: .projector, status: projectorStatus))
    return list
  }

  var ready: [LightItem] { items.filter { $0.status == .ready } }

  func item(_ id: String) -> LightItem? { items.first { $0.id == id } }

  /// What a control sheet shows: one light, or the first ready one standing in for the room.
  func look(_ id: String) -> LightItem? {
    id == Self.all ? (ready.first { $0.on } ?? ready.first) : item(id)
  }

  var anyOn: Bool { ready.contains { $0.on } }

  /// The background glow: the color of whatever is on.
  var ambient: Color? {
    let on = ready.filter(\.on)
    guard !on.isEmpty else { return nil }
    let n = Double(on.count)
    let sum = on.reduce((0.0, 0.0, 0.0)) { ($0.0 + Double($1.glow.r), $0.1 + Double($1.glow.g), $0.2 + Double($1.glow.b)) }
    return Color(red: sum.0 / n / 255, green: sum.1 / n / 255, blue: sum.2 / n / 255)
  }

  func rename(_ id: String, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    names[id] = trimmed.isEmpty ? nil : trimmed
    UserDefaults.standard.set(names, forKey: "names")
  }

  // MARK: Control

  func setPower(_ id: String, _ on: Bool) {
    if !on { stopEffect() }
    mood = nil
    for light in targets(id) {
      switch light.kind {
      case .strip:
        strip.setPower(on)
        stripLook.on = on
        saveStrip()
      case .bulb: hub(light).map { hubspace.setPower($0, on) }
      case .bleBulb: lamp(light).map { lamps.setPower($0, on) }
      case .projector: break
      }
    }
  }

  func setBrightness(_ id: String, _ value: Int) {
    mood = nil
    for light in targets(id) { brightness(light, value) }
  }

  func setColor(_ id: String, _ color: RGB) {
    mood = nil
    if targets(id).contains(where: { $0.kind == .strip }) { stopEffect() }
    for light in targets(id) { paint(light, color) }
  }

  func setWhite(_ id: String, _ kelvin: Int) {
    mood = nil
    if targets(id).contains(where: { $0.kind == .strip }) { stopEffect() }
    for light in targets(id) { white(light, kelvin) }
  }

  func setBulbEffect(_ id: String, _ effect: String) {
    mood = nil
    item(id).flatMap(hub).map { hubspace.setEffect($0, effect) }
  }

  func setBulbSpeed(_ id: String, _ speed: Int) {
    item(id).flatMap(hub).map { hubspace.setEffectSpeed($0, speed) }
  }

  func apply(_ m: Mood) {
    stopEffect()
    for light in ready where light.kind != .projector {
      brightness(light, m.brightness)
      switch m.look {
      case .color(let c): paint(light, c)
      case .white(let k): white(light, k)
      case .party: paint(light, RGB(r: 255, g: 0, b: 180))
      }
    }
    if case .party = m.look, ready.contains(where: { $0.kind == .strip }) { start(.pattern(10)) }
    mood = m.id
  }

  private func targets(_ id: String) -> [LightItem] {
    ready.filter { $0.kind != .projector && (id == Self.all || $0.id == id) }
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
      wakeStrip()
      strip.setBrightness(value)
      stripLook.brightness = value
      saveStrip()
    case .bulb: hub(light).map { hubspace.setBrightness($0, value) }
    case .bleBulb: lamp(light).map { lamps.setBrightness($0, value) }
    case .projector: break
    }
  }

  private func paint(_ light: LightItem, _ c: RGB) {
    switch light.kind {
    case .strip:
      wakeStrip()
      strip.setColor(r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b))
      stripLook.color = c
      stripLook.kelvin = nil
      saveStrip()
    case .bulb: hub(light).map { hubspace.setColor($0, r: c.r, g: c.g, b: c.b) }
    case .bleBulb: lamp(light).map { lamps.setColor($0, c) }
    case .projector: break
    }
  }

  private func white(_ light: LightItem, _ kelvin: Int) {
    switch light.kind {
    case .strip:
      // RGB-only strip: fake the temperature.
      let c = RGB.kelvin(kelvin)
      wakeStrip()
      strip.setColor(r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b))
      stripLook.kelvin = kelvin
      saveStrip()
    case .bulb: hub(light).map { hubspace.setWhite($0, kelvin: kelvin) }
    case .bleBulb: lamp(light).map { lamps.setWhite($0, kelvin) }
    case .projector: break
    }
  }

  /// Changing a look turns the strip on, like the bulb does on its own.
  private func wakeStrip() {
    guard !stripLook.on else { return }
    strip.setPower(true)
    stripLook.on = true
  }

  private struct SavedLook: Codable { var on: Bool; var brightness: Int; var color: RGB; var kelvin: Int? }

  private func saveStrip() {
    let saved = SavedLook(on: stripLook.on, brightness: stripLook.brightness, color: stripLook.color, kelvin: stripLook.kelvin)
    UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "stripLook")
  }

  // MARK: Effects (strip only: the bulb goes through Home Depot's cloud, too slow to follow a beat)

  func start(_ e: Effect) {
    stopEffect()
    effectError = nil
    guard strip.state == .connected else { return }
    wakeStrip()
    mood = nil
    effect = e
    switch e {
    case .pattern(let id):
      strip.setPattern(id)
      strip.setSpeed(speed)
    case .stripMic(let style):
      strip.setMicMusic(style: style)
      strip.setSensitivity(sensitivity)
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

  func setSensitivity(_ value: Int) {
    sensitivity = value
    UserDefaults.standard.set(value, forKey: "sensitivity")
    strip.setSensitivity(value)
  }

  func setSpeed(_ value: Int) {
    speed = value
    UserDefaults.standard.set(value, forKey: "speed")
    strip.setSpeed(value)
  }

  /// Forgets the running effect. The strip leaves a built-in effect on its next color.
  func stopEffect() {
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
    level = max(loud, level * 0.8)
    average = average * 0.95 + loud * 0.05
    if loud > average + 0.15, loud > 0.3, Date().timeIntervalSince(lastBeat) > 0.25 {
      lastBeat = Date()
      hue += 0.13
      let c = RGB.hue(hue)
      strip.setColor(r: UInt8(c.r), g: UInt8(c.g), b: UInt8(c.b))
    }
    strip.setBrightness(Int(8 + level * 92))
  }
}
