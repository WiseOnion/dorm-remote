import AppIntents
import Foundation

// Shortcuts actions, so schedules work without the app open:
// Shortcuts → Automation → Time of Day → Run Immediately → a Dorm Remote action.
// iOS launches the app in the background to run them; the lights are reached over Bluetooth as usual.

enum SceneChoice: String, AppEnum {
  case relax = "Relax", focus = "Focus", sunset = "Sunset", ocean = "Ocean", movie = "Movie", night = "Night", party = "Party"

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
  static let caseDisplayRepresentations: [SceneChoice: DisplayRepresentation] = [
    .relax: "Relax", .focus: "Focus", .sunset: "Sunset", .ocean: "Ocean", .movie: "Movie", .night: "Night", .party: "Party",
  ]
}

/// Waits briefly for lights to reconnect after a background launch.
@MainActor
private func waitForLights() async {
  for _ in 0..<40 where Room.shared.roomReady.isEmpty || Room.shared.strip.hasSaved && Room.shared.strip.state != .connected {
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

struct SetSceneIntent: AppIntent {
  static let title: LocalizedStringResource = "Set scene"

  @Parameter(title: "Scene") var scene: SceneChoice

  @MainActor
  func perform() async throws -> some IntentResult {
    await waitForLights()
    if let mood = Mood.all.first(where: { $0.id == scene.rawValue }) { Room.shared.apply(mood) }
    return .result()
  }
}

struct DormShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: LightsOnIntent(), phrases: ["Turn on \(.applicationName)"], shortTitle: "Lights on", systemImageName: "lightbulb.fill")
    AppShortcut(intent: LightsOffIntent(), phrases: ["Turn off \(.applicationName)"], shortTitle: "Lights off", systemImageName: "lightbulb.slash")
    AppShortcut(intent: SetSceneIntent(), phrases: ["Set \(.applicationName) scene"], shortTitle: "Set scene", systemImageName: "sparkles")
  }
}
