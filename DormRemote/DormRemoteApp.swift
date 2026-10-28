import SwiftUI
import UIKit

@main
struct DormRemoteApp: App {
  @State private var room = Room.shared

  init() {
    // Navigation titles in the same rounded face as the rest of the app.
    let rounded = { (style: UIFont.TextStyle, weight: UIFont.Weight) -> UIFont in
      let size = UIFont.preferredFont(forTextStyle: style).pointSize
      let font = UIFont.systemFont(ofSize: size, weight: weight)
      return font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? font
    }
    let bar = UINavigationBar.appearance()
    bar.largeTitleTextAttributes = [.font: rounded(.largeTitle, .bold)]
    bar.titleTextAttributes = [.font: rounded(.headline, .semibold)]
  }

  var body: some Scene {
    WindowGroup {
      ContentView(room: room)
        .preferredColorScheme(.dark)
    }
  }
}
