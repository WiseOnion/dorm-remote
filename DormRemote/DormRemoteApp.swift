import SwiftUI

@main
struct DormRemoteApp: App {
  @State private var strip = StripController()

  var body: some Scene {
    WindowGroup {
      ContentView(strip: strip)
    }
  }
}
