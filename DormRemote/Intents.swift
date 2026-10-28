import AppIntents
import Foundation

// Shortcuts actions, so schedules work without the app open:
// Shortcuts → Automation → Time of Day → Run Immediately → a Dorm Remote action.
// iOS launches the app in the background to run them; the lights are reached over Bluetooth as usual.
// They also work from Siri, the Action Button, and Control Center (iOS 18: Add a Control → Shortcuts),
// with no widget extension to sign, which a free Apple ID can't do reliably.

enum SceneChoice: String, AppEnum {
  // Raw values are what saved automations store, so the original seven never change.
  // "Sunset" and "Ocean" now play their Hue versions (see `mood`).
  case relax = "Relax", focus = "Focus", sunset = "Sunset", ocean = "Ocean", movie = "Movie", night = "Night", party = "Party"
  case read = "Read", energize = "Energize", sunrise = "Sunrise"
  case tropicalTwilight = "Tropical twilight", arcticAurora = "Arctic aurora", springBlossom = "Spring blossom"
  case goldenPond = "Golden pond", honolulu = "Honolulu", miami = "Miami", tokyo = "Tokyo", vaporWave = "Vapor wave"
  case soho = "Soho", disturbia = "Disturbia", nebula = "Nebula", galaxy = "Galaxy", bloodMoon = "Blood moon", moonlight = "Moonlight"

  // App Intents reads these at build time, so they have to be literals.
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
  static let caseDisplayRepresentations: [SceneChoice: DisplayRepresentation] = [
    .relax: "Relax", .read: "Read", .focus: "Focus", .energize: "Energize", .sunrise: "Sunrise", .party: "Party",
    .tropicalTwilight: "Tropical twilight", .sunset: "Savanna sunset", .arcticAurora: "Arctic aurora",
    .springBlossom: "Spring blossom", .goldenPond: "Golden pond", .honolulu: "Honolulu", .ocean: "Blue lagoon",
    .miami: "Miami", .tokyo: "Tokyo", .vaporWave: "Vapor wave", .soho: "Soho", .disturbia: "Disturbia",
    .movie: "Movie", .nebula: "Nebula", .galaxy: "Galaxy", .bloodMoon: "Blood moon", .moonlight: "Moonlight", .night: "Night",
  ]

  var mood: Mood? {
    let name = switch self {
    case .sunset: "Savanna sunset"
    case .ocean: "Blue lagoon"
    default: rawValue
    }
    return Mood.all.first { $0.id == name }
  }
}

/// One light, for "Turn a light on or off" and "Set brightness".
struct LightEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light"
  static let defaultQuery = LightQuery()

  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(stringLiteral: name) }
}

struct LightQuery: EntityQuery {
  @MainActor
  private func all() -> [LightEntity] {
    Room.shared.items.filter { $0.caps.contains(.power) }.map { LightEntity(id: $0.id, name: $0.name) }
  }

  func entities(for identifiers: [String]) async throws -> [LightEntity] {
    await all().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [LightEntity] { await all() }
}

/// Waits briefly for lights to reconnect after a background launch.
@MainActor
private func waitForLights() async {
  for _ in 0..<40 where Room.shared.roomReady.isEmpty || Room.shared.strip.strips.contains(where: { $0.state != .connected }) {
    try? await Task.sleep(for: .milliseconds(250))
  }
}

struct LightsOnIntent: AppIntent {
  static let title: LocalizedStringResource = "Turn lights on"

  @MainActor
  func perform() async throws -> some IntentResult {
    await waitForLights()
    Room.shared.setPower(Room.all, true)
    return .result()
  }
}

struct LightsOffIntent: AppIntent {
  static let title: LocalizedStringResource = "Turn lights off"

  @MainActor
  func perform() async throws -> some IntentResult {
    await waitForLights()
    Room.shared.setPower(Room.all, false)
    return .result()
  }
}

/// One button for the Action Button or Control Center: off if anything's on, otherwise on.
struct ToggleLightsIntent: AppIntent {
  static let title: LocalizedStringResource = "Toggle lights"

  @MainActor
  func perform() async throws -> some IntentResult {
    await waitForLights()
    Room.shared.setPower(Room.all, !Room.shared.anyOn)
    return .result()
  }
}

struct SetSceneIntent: AppIntent {
  static let title: LocalizedStringResource = "Set scene"

  @Parameter(title: "Scene") var scene: SceneChoice

  @MainActor
  func perform() async throws -> some IntentResult {
    await waitForLights()
    if let mood = scene.mood { Room.shared.apply(mood) }
    return .result()
  }
}

struct SetLightPowerIntent: AppIntent {
  static let title: LocalizedStringResource = "Turn a light on or off"

  @Parameter(title: "Light") var light: LightEntity
  @Parameter(title: "On", default: true) var on: Bool

  static var parameterSummary: some ParameterSummary {
    Summary("Turn \(\.$light) \(\.$on)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    await waitForLights()
    Room.shared.setPower(light.id, on)
    return .result()
  }
}

struct SetBrightnessIntent: AppIntent {
  static let title: LocalizedStringResource = "Set brightness"

  @Parameter(title: "Brightness", inclusiveRange: (1, 100)) var brightness: Int
  @Parameter(title: "Light", description: "Leave empty for the whole room.") var light: LightEntity?

  @MainActor
  func perform() async throws -> some IntentResult {
    await waitForLights()
    Room.shared.setBrightness(light?.id ?? Room.all, brightness)
    return .result()
  }
}

/// Bedtime: dims the room over about 20 seconds, then turns it off. Short enough to finish in the
/// background time iOS gives an automation (e.g. "When Sleep Focus turns on").
struct FadeOutIntent: AppIntent {
  static let title: LocalizedStringResource = "Fade lights out"

  @MainActor
  func perform() async throws -> some IntentResult {
    await waitForLights()
    let start = Room.shared.roomReady.filter(\.on).map(\.brightness).max() ?? 0
    if start > 1 {
      for step in stride(from: 9, through: 1, by: -1) {
        Room.shared.setBrightness(Room.all, max(1, start * step / 10))
        try? await Task.sleep(for: .seconds(2))
      }
    }
    Room.shared.setPower(Room.all, false)
    return .result()
  }
}

struct DormShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: ToggleLightsIntent(), phrases: ["Toggle \(.applicationName)", "Toggle the lights in \(.applicationName)"],
                shortTitle: "Toggle lights", systemImageName: "power")
    AppShortcut(intent: LightsOnIntent(), phrases: ["Turn on \(.applicationName)"], shortTitle: "Lights on", systemImageName: "lightbulb.fill")
    AppShortcut(intent: LightsOffIntent(), phrases: ["Turn off \(.applicationName)"], shortTitle: "Lights off", systemImageName: "lightbulb.slash")
    AppShortcut(intent: SetSceneIntent(), phrases: ["Set \(.applicationName) scene"], shortTitle: "Set scene", systemImageName: "sparkles")
    AppShortcut(intent: FadeOutIntent(), phrases: ["Fade out \(.applicationName)", "Goodnight \(.applicationName)"],
                shortTitle: "Fade out", systemImageName: "moon.zzz")
  }
}
