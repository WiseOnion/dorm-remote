import SwiftUI

@main
struct DormRemoteApp: App {
  @State private var room = Room(strip: StripController(), hubspace: HubspaceClient())

  var body: some Scene {
    WindowGroup {
      ContentView(room: room)
        .preferredColorScheme(.dark)
    }
  }
}
