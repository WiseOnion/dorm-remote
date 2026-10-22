import SwiftUI

@main
struct DormRemoteApp: App {
  @State private var room = Room.shared

  var body: some Scene {
    WindowGroup {
      ContentView(room: room)
        .preferredColorScheme(.dark)
    }
  }
}
