import SwiftUI

@main
struct DormRemoteApp: App {
  @State private var room = Room.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView(room: room)
        .preferredColorScheme(.dark)
    }
    .onChange(of: scenePhase) { _, phase in
      // Afero asks apps to run the bulb hub only in the foreground.
      switch phase {
      case .active: if room.hubspace.state == .ready { room.hubspace.startHub() }
      case .background: room.hubspace.hub.stop()
      default: break
      }
    }
  }
}
