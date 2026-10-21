import SwiftUI

@main
struct DormRemoteApp: App {
  @State private var strip = StripController()
  @State private var hubspace = HubspaceClient()

  var body: some Scene {
    WindowGroup {
      ContentView(strip: strip, hubspace: hubspace)
    }
  }
}
