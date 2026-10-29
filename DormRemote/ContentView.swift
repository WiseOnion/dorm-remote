import ARKit
import PhotosUI
import SwiftUI
import UIKit

// Design system. One quiet surface ladder (canvas, surface, raised), one line, three text levels, and no accent of its
// own: the room's lights supply the only color. Every gray has a light and a dark value and an Increase Contrast
// variant (Apple HIG: Color, Dark Mode). Content sits on solid surfaces; glass is left to the system's bars.
private enum Ink {
  static let bg = Color(dark: 0x09090B, light: 0xF2F2F7)
  static let card = Color(dark: 0x111114, light: 0xFFFFFF)
  static let raised = Color(dark: 0x18181D, light: 0xE8E8ED, darkContrast: 0x2A2A33, lightContrast: 0xD1D1D8)
  static let line = Color(UIColor { t in
    let a: CGFloat = t.accessibilityContrast == .high ? 0.24 : 0.09
    return t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: a) : UIColor(white: 0, alpha: a)
  })
  static let text = Color(dark: 0xF5F5F7, light: 0x111114)
  /// Secondary text: 7.3:1 on dark surfaces, 6.3:1 on white (WCAG AA needs 4.5).
  static let dim = Color(dark: 0xA1A1AA, light: 0x5E5E66, darkContrast: 0xD4D4D8, lightContrast: 0x3A3A40)
  /// Text and symbols on a filled `text`-colored control.
  static let inverse = Color(dark: 0x09090B, light: 0xFFFFFF)
  static let bad = Color(dark: 0xFF6B5E, light: 0xD93025, darkContrast: 0xFF8A80, lightContrast: 0xB3261E)
}

/// Corner radii: three sizes, used everywhere.
private enum Radius {
  static let control: CGFloat = 12
  static let card: CGFloat = 18
  static let feature: CGFloat = 24
}

/// One set of timings for the whole app, so every screen moves the same way.
private enum Motion {
  /// Taps and selections: quick, settles without bounce.
  static let tap = Animation.spring(response: 0.3, dampingFraction: 0.86)
  /// Something showing, hiding or changing state.
  static let state = Animation.easeOut(duration: 0.22)
  /// Effect frames arrive ten times a second; a short blend keeps them smooth without lagging the light.
  static let frame = Animation.linear(duration: 0.12)
  /// The room's glow: the mood, not a control, so it drifts.
  static let mood = Animation.easeInOut(duration: 0.6)
}

/// The room's light behind every tab: the average of what's on, washed faintly from the top. Shared, so switching
/// tabs keeps the same room around you. Nothing on, no wash.
private struct RoomGlow: View {
  var room: Room

  var body: some View {
    ZStack {
      Ink.bg
      if let ambient = room.ambient {
        RadialGradient(colors: [ambient.opacity(0.16), ambient.opacity(0.04), .clear], center: .top, startRadius: 0, endRadius: 520)
      }
    }
    .ignoresSafeArea()
    .animation(Motion.mood, value: room.ambient)
  }
}

extension View {
  /// Every sheet looks the same: the surface color with a grabber; the system draws the corners.
  fileprivate func panel() -> some View {
    presentationDragIndicator(.visible)
      .presentationBackground(Ink.card)
  }
}

/// A surface for a group of things. No border: the surface step from the canvas separates it. `tint` adds a hairline
/// in that color, for the rare panel that needs to call attention (a warning).
private struct Card: ViewModifier {
  var tint: Color?
  var radius: CGFloat = Radius.card

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content.background(
      shape.fill(Ink.card)
        .overlay { if let tint { shape.strokeBorder(tint.opacity(0.5), lineWidth: 1) } }
    )
  }
}

extension View {
  fileprivate func card(tint: Color? = nil, radius: CGFloat = Radius.card) -> some View { modifier(Card(tint: tint, radius: radius)) }
}

/// Pressed state for every custom button: a slight shrink and dim on a spring, so taps feel answered
/// within a frame. Off when Reduce Motion is on (only the dim stays).
private struct Press: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      // Quick in, settle out: the press answers at once, the release eases back.
      .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
  }
}

private enum Sheet: Identifiable {
  case light(String), stripSetup, hubSetup, lampSetup, remote(String), addRemote, add, log, makeScene, match
  var id: String {
    switch self {
    case .light(let id): "light-" + id
    case .stripSetup: "strip"
    case .hubSetup: "hub"
    case .remote(let id): "remote-" + id
    case .addRemote: "addRemote"
    case .lampSetup: "lamps"
    case .add: "add"
    case .log: "log"
    case .makeScene: "makeScene"
    case .match: "match"
    }
  }
}

struct ContentView: View {
  var room: Room
  @State private var sheet: Sheet?
  @State private var roomEdit: RoomEdit?
  @State private var removing: LightItem?
  @State private var deletingRoom: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var roomName = ""
  @State private var savingScene = false
  @State private var sceneName = ""
  @State private var photo: PhotosPickerItem?
  @State private var photoError = false
  /// A scene waiting for "Delete" to be confirmed.
  @State private var deletingScene: String?
  /// The scene group on show; nil opens on the first one (Favorites if you have some).
  @SceneStorage("sceneGroup") private var sceneGroup: String?
  /// Which tab is open. Starts from the "tab" default, which screenshots set with -tab.
  @State private var tab = UserDefaults.standard.string(forKey: "tab") ?? "room"
  @State private var photoPicking = false

  private enum RoomEdit: Equatable { case add, rename(String) }

  /// Four tabs, after Hue's (Home, Automations, …, Settings): your room first, then its layout, what runs by itself,
  /// and setup you do once. The tab bar and navigation bars are the system's, so they take on iOS's own glass.
  var body: some View {
    presenting(TabView(selection: $tab) {
      NavigationStack {
        roomTab
          .navigationTitle(room.currentRoom)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar { roomToolbar }
      }
      .tabItem { Label("Room", systemImage: "house.fill") }
      .tag("room")
      MapScreen(room: room) { sheet = .light($0) }
        .tabItem { Label("Map", systemImage: "map.fill") }
        .tag("map")
      AutomationsTab(room: room)
        .tabItem { Label("Automations", systemImage: "clock.fill") }
        .tag("automations")
      settingsTab
        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        .tag("settings")
    }
    .tint(Ink.text)
    .toggleStyle(SwitchToggleStyle(tint: .green)))
  }

  @ToolbarContentBuilder
  private var roomToolbar: some ToolbarContent {
    ToolbarItem(placement: .principal) { roomMenu }
    ToolbarItemGroup(placement: .topBarTrailing) {
      Menu {
        Section("Fade out and turn off in") {
          ForEach([15, 30, 60], id: \.self) { m in
            Button("\(m) minutes") { room.sleep(in: m) }
          }
        }
      } label: {
        Image(systemName: "moon")
      }
      .disabled(!room.anyOn)
      .accessibilityLabel("Sleep timer")
      Button { sheet = .light(Room.all) } label: {
        Image(systemName: "slider.horizontal.3")
      }
      .disabled(room.roomReady.filter { $0.kind != .remote }.isEmpty)
      .accessibilityLabel("Room controls")
    }
  }

  /// The room switcher, like Apple Home's title menu: the room's name, and its rooms underneath.
  private var roomMenu: some View {
    Menu {
      Picker("Room", selection: Binding(get: { room.currentRoom }, set: { name in
        withAnimation(reduceMotion ? Motion.state : Motion.tap) { room.selectedRoom = name }
      })) {
        ForEach(room.rooms, id: \.self) { Text($0).tag($0) }
      }
      Divider()
      Button("New room", systemImage: "plus") {
        roomName = ""
        roomEdit = .add
      }
      Button("Rename \(room.currentRoom)", systemImage: "pencil") {
        roomName = room.currentRoom
        roomEdit = .rename(room.currentRoom)
      }
      if room.rooms.count > 1 {
        Button("Delete \(room.currentRoom)", systemImage: "trash", role: .destructive) { deletingRoom = room.currentRoom }
      }
    } label: {
      RoomTitle(name: room.currentRoom)
    }
    .accessibilityLabel("Room")
    .accessibilityValue(room.currentRoom)
  }

  /// The Room tab reads top to bottom as: the room (its state and its power), its lights, then the looks you can give
  /// it (scenes) and the ones that keep moving (effects). Hardware names stay out of it; they're in Settings.
  private var roomTab: some View {
    ScrollViewReader { proxy in
    List {
      Section {
        hero
        // Nielsen's first heuristic: say what's wrong where you'd look, not as "not reachable" on every light.
        if let problem = room.strip.bluetoothProblem, !room.strip.strips.isEmpty {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(tint: Ink.bad)
        }
        nowPlaying
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

      Section {
        ForEach(room.inRoom) { item in row(item) }
        if room.inRoom.isEmpty { emptyRoom }
      } header: {
        HStack {
          SectionTitle("Lights")
          Spacer()
          Button { sheet = .add } label: {
            Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
          }
          .accessibilityLabel("Add a light")
        }
      }
      .listRowBackground(Ink.card)
      .listRowSeparatorTint(Ink.line)

      Section {
        scenes.id("scenes")
      } header: {
        scenesHeader
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

      Section {
        effects
      } header: {
        SectionTitle("Effects")
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0))
    }
    .listStyle(.insetGrouped)
    .listSectionSpacing(24)
    .onAppear {
      guard UserDefaults.standard.string(forKey: "scroll") == "scenes" else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo("scenes", anchor: .top) }
    }
    }
    .animation(Motion.state, value: room.effect)
    // Pull down to reconnect anything that dropped and re-read the bulbs.
    .refreshable { await room.reconnect() }
    .onChange(of: scenePhase, initial: true) { _, phase in
      if phase == .active { room.walkIn.appOpenedAt = Date() }
    }
    .scrollContentBackground(.hidden)
    .scrollIndicators(.hidden)
    .background(RoomGlow(room: room))
    .foregroundStyle(Ink.text)
    .tint(Ink.text)
    .sensoryFeedback(.selection, trigger: room.currentRoom)
    // A light coming online is a small success; one dropping is an error you can feel.
    .sensoryFeedback(trigger: room.roomReady.count) { old, new in new > old ? .success : new < old ? .error : nil }
  }

  /// The room at a glance: its power, what it's doing, how many lights, and whether you're home.
  private var hero: some View {
    let power = room.inRoom.filter { $0.caps.contains(.power) }
    let lit = room.roomReady.filter { $0.on && $0.caps.contains(.power) }
    return VStack(spacing: 16) {
      RoomPower(on: room.anyOn, colors: lit.map { room.shown($0).color }) { room.setPower(Room.all, !room.anyOn) }
        .disabled(room.roomReady.isEmpty)
        .contextMenu {
          Button("Turn off every room", systemImage: "power") { room.setPower(Room.everything, false) }
        }
      VStack(spacing: 4) {
        Text(roomState)
          .font(.title3.weight(.semibold))
          .contentTransition(.opacity)
        HStack(spacing: 8) {
          Text(power.count == 1 ? "1 light" : "\(power.count) lights")
          if room.walkIn.enabled {
            Text("·")
            Text("\(Image(systemName: room.walkIn.isAway ? "figure.walk.departure" : "house")) \(room.walkIn.isAway ? "Away" : "You're home")")
          }
        }
        .font(.subheadline)
        .foregroundStyle(Ink.dim)
      }
      .multilineTextAlignment(.center)
      .accessibilityElement(children: .combine)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
    .animation(Motion.state, value: roomState)
  }

  /// One line that says what the room is doing.
  private var roomState: String {
    let ready = room.roomReady.filter { $0.caps.contains(.power) }
    if room.inRoom.isEmpty { return "No lights yet" }
    if ready.isEmpty { return "Connecting" }
    let on = ready.filter(\.on).count
    if on == 0 { return "Everything is off" }
    if let effect = room.effectPlaying(on: Room.all) { return "\(effect.name) is playing" }
    if let mood = room.mood { return "\(mood) is on" }
    return on == ready.count ? "All lights on" : on == 1 ? "1 light on" : "\(on) lights on"
  }

  private var emptyRoom: some View {
    VStack(spacing: 12) {
      Text("Nothing in \(room.currentRoom) yet").font(.headline)
      Text("Add a light, or move one here from Settings.")
        .font(.subheadline)
        .foregroundStyle(Ink.dim)
      Button("Add a light") { sheet = .add }
        .font(.body.weight(.semibold))
        .frame(minHeight: 44)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
  }

  private func presenting(_ content: some View) -> some View {
    content
    .fullScreenCover(isPresented: Binding(get: { room.sleepAt != nil }, set: { if !$0 { room.cancelSleep() } })) {
      SleepScreen(room: room)
    }
    .sheet(item: $sheet) { sheet in
      Group {
        switch sheet {
        case .light(let id): LightSheet(room: room, id: id) { self.sheet = .match }
        case .stripSetup: StripSetup(strip: room.strip)
        case .hubSetup: HubSetup(hubspace: room.hubspace)
        case .remote(let id): RemoteSheet(room: room, id: id)
        case .addRemote: AddRemoteSheet(room: room)
        case .lampSetup: LampSetup(lamps: room.lamps)
        case .add: AddSheet { kind in
          room.restore(kind)
          // Open the new device's setup once this sheet is gone.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            switch kind {
            case .strip: self.sheet = .stripSetup
            case .hubspace: self.sheet = room.hubspace.state == .ready ? nil : .hubSetup
            case .bluetooth: self.sheet = .lampSetup
            case .remote: self.sheet = .addRemote
            }
          }
        }
        case .log: LogView(lines: room.strip.log + room.hubspace.log + room.bridge.log + room.lamps.log)
        case .makeScene: SceneMaker(room: room)
        case .match: MatchSheet(room: room)
        }
      }
      .panel()
    }
    .confirmationDialog("Remove \(removing?.name ?? "this device")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
      Button("Remove", role: .destructive) {
        if let item = removing { room.remove(item) }
        removing = nil
      }
    } message: {
      Text("You can add it back from Add.")
    }
    .confirmationDialog("Delete \(deletingScene ?? "scene")?", isPresented: Binding(get: { deletingScene != nil }, set: { if !$0 { deletingScene = nil } }), titleVisibility: .visible) {
      Button("Delete scene", role: .destructive) {
        if let id = deletingScene { room.deleteScene(id) }
        deletingScene = nil
      }
    } message: {
      Text("This can't be undone.")
    }
    .confirmationDialog("Delete \(deletingRoom ?? "room")?", isPresented: Binding(get: { deletingRoom != nil }, set: { if !$0 { deletingRoom = nil } }), titleVisibility: .visible) {
      Button("Delete room", role: .destructive) {
        if let name = deletingRoom { room.deleteRoom(name) }
        deletingRoom = nil
      }
    } message: {
      Text("Its devices move to \(room.rooms.first { $0 != deletingRoom } ?? "another room").")
    }
    .alert(roomEdit == .add ? "New room" : "Rename room", isPresented: Binding(get: { roomEdit != nil }, set: { if !$0 { roomEdit = nil } })) {
      TextField("Room name", text: $roomName)
      Button("Save") {
        switch roomEdit {
        case .add: room.addRoom(roomName)
        case .rename(let old): room.renameRoom(old, to: roomName)
        case nil: break
        }
        roomEdit = nil
      }
      Button("Cancel", role: .cancel) { roomEdit = nil }
    }
  }

  /// The effect playing in this room, live: each light's current color, the speed, and Stop.
  @ViewBuilder
  private var nowPlaying: some View {
    if let effect = room.effectPlaying(on: Room.all) {
      let lights = room.roomReady.filter { room.effectLights.contains($0.id) }
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          HStack(spacing: -8) {
            ForEach(lights.prefix(4)) { light in
              Circle()
                .fill(room.shown(light).color)
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Ink.card, lineWidth: 2))
                .animation(Motion.frame, value: room.shown(light))
            }
          }
          .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("Now playing").font(.footnote).foregroundStyle(Ink.dim)
            Text(effect.name).font(.body.weight(.semibold)).lineLimit(1)
          }
          Spacer()
          Button { room.endEffect() } label: {
            Image(systemName: "stop.fill")
              .font(.subheadline)
              .frame(width: 36, height: 36)
              .foregroundStyle(Ink.inverse)
              .background(Circle().fill(Ink.text))
              .frame(width: 44, height: 44)
          }
          .buttonStyle(Press())
          .accessibilityLabel("Stop \(effect.name)")
        }
        if effect.hasSpeed {
          HStack(spacing: 12) {
            Image(systemName: "tortoise").foregroundStyle(Ink.dim)
            PillSlider(value: Binding(get: { Double(room.speed - 1) / 99 }, set: { room.setSpeed(1 + Int(($0 * 99).rounded())) }),
                       fill: AnyShapeStyle(Ink.text.opacity(0.85)),
                       label: "Speed", showsPercent: false)
              .frame(height: 28)
            Image(systemName: "hare").foregroundStyle(Ink.dim)
          }
        }
        if effect == .phoneMic {
          Capsule()
            .fill(Ink.raised)
            .overlay(alignment: .leading) {
              GeometryReader { geo in Capsule().fill(Ink.text).frame(width: geo.size.width * room.level) }
            }
            .frame(height: 6)
            .animation(.linear(duration: 0.05), value: room.level)
        }
      }
      .padding(16)
      .card()
      .transition(.opacity)
      .accessibilityElement(children: .contain)
    }
  }

  private var scenesHeader: some View {
    HStack {
      SectionTitle("Scenes")
      Spacer()
      Menu {
        Button("Pick colors", systemImage: "paintpalette") { sheet = .makeScene }
        Button("Save the room as it is", systemImage: "square.and.arrow.down") {
          sceneName = ""
          savingScene = true
        }
        Button("From a photo", systemImage: "photo") { photoPicking = true }
      } label: {
        Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
      }
      .accessibilityLabel("New scene")
    }
  }

  /// Scenes say "make my room look like this": one group at a time, picked by name, each scene a small window into a
  /// dark room lit its way.
  private var scenes: some View {
    let groups = sceneGroups
    let shown = groups.contains(sceneGroup ?? "") ? sceneGroup! : groups[0]
    let list = moods(in: shown)
    return VStack(alignment: .leading, spacing: 8) {
      ScrollView(.horizontal) {
        HStack(spacing: 20) {
          ForEach(groups, id: \.self) { g in
            Button {
              withAnimation(Motion.state) { sceneGroup = g }
            } label: {
              Text(g)
                .font(.subheadline.weight(shown == g ? .semibold : .regular))
                .foregroundStyle(shown == g ? Ink.text : Ink.dim)
                .frame(minHeight: 44)
            }
            .buttonStyle(Press())
            .accessibilityAddTraits(shown == g ? .isSelected : [])
          }
        }
        .padding(.horizontal, 4)
      }
      .scrollIndicators(.hidden)
      .sensoryFeedback(.selection, trigger: shown)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
          ForEach(list) { sceneTile($0) }
          if list.isEmpty {
            Text(shown == Mood.Group.mine.rawValue ? "Make your own with +." : "Press and hold a scene to add it here.")
              .font(.subheadline)
              .foregroundStyle(Ink.dim)
              .frame(height: 80)
          }
        }
        .padding(.horizontal, 4)
      }
      .scrollIndicators(.hidden)
      .id(shown)
      .transition(.opacity)
    }
    .disabled(room.roomReady.isEmpty)
    .opacity(room.roomReady.isEmpty ? 0.4 : 1)
    .sensoryFeedback(.impact(weight: .light), trigger: room.mood)
    .alert("Save scene", isPresented: $savingScene) {
      TextField("Name", text: $sceneName)
      Button("Save") { room.saveScene(named: sceneName) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Saves every light in \(room.currentRoom) the way it is now.")
    }
    // The system photo picker needs no photo-library permission: the app only gets the one picture you choose.
    .photosPicker(isPresented: $photoPicking, selection: $photo, matching: .images)
    .onChange(of: photo) { _, item in
      guard let item else { return }
      Task {
        let data = try? await item.loadTransferable(type: Data.self)
        photo = nil
        let colors = data.map { Mood.palette(from: Mood.pixels(ofImage: $0)) } ?? []
        if colors.isEmpty {
          photoError = true
        } else {
          room.savePalette(colors, named: "Photo")
        }
      }
    }
    .alert("No strong colors", isPresented: $photoError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("That photo is mostly gray or dark. Try one with bolder colors.")
    }
  }

  private static let favoritesGroup = "Favorites"

  /// Favorites (when there are any), Yours, then the built-in groups.
  private var sceneGroups: [String] {
    let favorites = room.favorites.isEmpty ? [] : [Self.favoritesGroup]
    return favorites + Mood.Group.allCases.map(\.rawValue)
  }

  private func moods(in group: String) -> [Mood] {
    if group == Self.favoritesGroup { return room.moods.filter { room.favorites.contains($0.id) } }
    if group == Mood.Group.mine.rawValue { return room.customScenes }
    return Mood.all.filter { $0.group.rawValue == group }
  }

  private func sceneTile(_ mood: Mood) -> some View {
    let selected = room.mood == mood.id
    let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    return Button { room.apply(mood) } label: {
      VStack(alignment: .leading, spacing: 8) {
        ScenePreview(mood: mood)
          .frame(width: 112, height: 80)
          .clipShape(shape)
          .overlay(shape.strokeBorder(selected ? Ink.text : Ink.line, lineWidth: selected ? 2 : 1))
          .overlay(alignment: .topTrailing) {
            if room.favorites.contains(mood.id) {
              Image(systemName: "star.fill").font(.caption2).foregroundStyle(.white.opacity(0.9)).padding(8)
            }
          }
        Text(mood.id)
          .font(.footnote.weight(selected ? .semibold : .regular))
          .foregroundStyle(selected ? Ink.text : Ink.dim)
          .lineLimit(1)
          .frame(width: 112, alignment: .leading)
      }
    }
    .buttonStyle(Press())
    .animation(Motion.tap, value: selected)
    .accessibilityLabel("\(mood.id) scene")
    .accessibilityHint("Tap again to shuffle its colors. Press and hold to favorite.")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .contextMenu {
      let favorite = room.favorites.contains(mood.id)
      Button(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "star.slash" : "star") {
        room.toggleFavorite(mood.id)
      }
      if mood.group == .mine {
        Button("Delete scene", systemImage: "trash", role: .destructive) { deletingScene = mood.id }
      }
    }
  }

  /// Effects say "keep changing the room". Drift moves a color scene between lights; the rest run on the room's
  /// strips and Bluetooth bulbs (and the cloud bulb, room-wide). Tap a running one to stop it.
  private var effects: some View {
    let canPlay = room.roomReady.contains { $0.kind == .strip || $0.kind == .bleBulb }
    let playing = room.effectPlaying(on: Room.all)
    return ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: 16) {
        effectTile("Drift", "wind", on: room.living) { room.living.toggle() }
          .accessibilityHint("Color scenes move slowly from light to light")
        Group {
          effectTile("Color cycle", "rainbow", on: playing == .synced) { toggle(.synced) }
          effectTile("Candle", "flame", on: playing == .candle) { toggle(.candle) }
          effectTile("Fireplace", "fireplace", on: playing == .fire) { toggle(.fire) }
          effectTile("Music", "waveform", on: playing == .phoneMic) { toggle(.phoneMic) }
        }
        .disabled(!canPlay)
        .opacity(canPlay ? 1 : 0.4)
      }
      .padding(.horizontal, 4)
    }
    .scrollIndicators(.hidden)
    .sensoryFeedback(.impact(weight: .light), trigger: playing)
  }

  private func toggle(_ e: Effect) {
    if room.effectPlaying(on: Room.all) == e { room.endEffect() } else { room.start(e, on: Room.all) }
  }

  private func effectTile(_ name: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 8) {
        Image(systemName: icon)
          .font(.title3)
          .frame(width: 56, height: 56)
          .foregroundStyle(on ? Ink.inverse : Ink.text)
          .background(Circle().fill(on ? Ink.text : Ink.raised))
        Text(name)
          .font(.footnote.weight(on ? .semibold : .regular))
          .foregroundStyle(on ? Ink.text : Ink.dim)
          .lineLimit(1)
      }
      .frame(minWidth: 64)
    }
    .buttonStyle(Press())
    .animation(Motion.tap, value: on)
    .accessibilityLabel(name)
    .accessibilityValue(on ? "On" : "Off")
  }

  private func row(_ item: LightItem) -> some View {
    LightRow(room: room, item: item) { open(item) }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        Button(role: .destructive) { removing = item } label: { Label("Remove", systemImage: "trash") }
      }
  }

  private func open(_ item: LightItem) {
    switch (item.kind, item.status) {
    case (.remote, _): sheet = .remote(item.id)
    case (_, .ready): sheet = .light(item.id)
    case (.strip, _): sheet = .stripSetup
    case (.bulb, _): sheet = .hubSetup
    case (.bleBulb, _): sheet = .lampSetup
    }
  }
}

// MARK: - Sleep and scene maker

/// The sleep timer's screen: black, so it doesn't light the room, and awake, because iOS pauses the app once the
/// phone locks. Leave the phone on the charger; the lights fade, turn off, and the screen goes back to normal.
private struct SleepScreen: View {
  var room: Room

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let left = max(0, Int((room.sleepAt ?? .now).timeIntervalSince(context.date)))
      VStack(spacing: 16) {
        Spacer()
        Image(systemName: "moon.zzz").font(.title2)
        Text(left >= 60 ? "\(left / 60 + 1) min" : "\(left) s")
          .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
          .contentTransition(.numericText(countsDown: true))
        Text("Lights fade, then turn off. Keep Dorm Remote open; the screen stays dark until then.")
          .font(.footnote)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 280)
        Spacer()
        Button("Stop timer") { room.cancelSleep() }
          .font(.body.weight(.semibold))
          .frame(minHeight: 44)
      }
      // Dim on purpose: this is the only light left in the room.
      .foregroundStyle(Color.white.opacity(0.28))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.ignoresSafeArea())
    }
    .statusBarHidden()
    .persistentSystemOverlays(.hidden)
    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }
}

/// Pick up to five colors and save them as a scene. The lights share them out, and Drift moves between them.
private struct SceneMaker: View {
  var room: Room
  @Environment(\.dismiss) private var dismiss
  @State private var colors: [RGB] = []
  @State private var current = RGB(r: 163, g: 91, b: 255)
  @State private var name = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        // Apple HIG (Sheets): a way out on the leading edge that doesn't save.
        Button("Cancel") { dismiss() }
          .frame(minHeight: 44)
        VStack(alignment: .leading, spacing: 8) {
          Text("Pick colors").font(.system(.title, design: .rounded, weight: .bold))
          Text("Choose up to five. Your lights share them out, and Drift moves slowly between them.")
            .foregroundStyle(Ink.dim)
        }
        HStack(spacing: 12) {
          ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
            Button { colors.remove(at: i) } label: {
              Circle().fill(c.color).frame(width: 44, height: 44)
                .overlay(Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.black.opacity(0.6)))
            }
            .accessibilityLabel("Remove \(c.name)")
          }
          if colors.count < 5 {
            Circle().strokeBorder(Ink.dim, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])).frame(width: 44, height: 44)
              .accessibilityHidden(true)
          }
        }
        .animation(Motion.tap, value: colors)
        ColorWheel(selected: current, pick: { current = $0 })
          .frame(height: 260)
          .frame(maxWidth: .infinity)
        if !room.recentColors.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 12) {
              ForEach(Array(room.recentColors.enumerated()), id: \.offset) { _, c in
                Button { current = c } label: { Circle().fill(c.color).frame(width: 36, height: 36) }
                  .accessibilityLabel(c.name)
              }
            }
          }
          .scrollIndicators(.hidden)
        }
        Button { colors.append(current) } label: {
          Label("Add this color", systemImage: "plus")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(Ink.raised))
        }
        .buttonStyle(Press())
        .disabled(colors.count >= 5)
        TextField("Name (optional)", text: $name)
          .padding(.horizontal, 16)
          .frame(minHeight: 52)
          .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.raised))
        Button {
          room.savePalette(colors, named: name.trimmingCharacters(in: .whitespaces).isEmpty ? "My colors" : name)
          dismiss()
        } label: {
          Text("Save and play")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(Ink.inverse)
            .background(Capsule().fill(Ink.text))
        }
        .buttonStyle(Press())
        .disabled(colors.isEmpty)
        .opacity(colors.isEmpty ? 0.4 : 1)
      }
      .padding(24)
    }
    .scrollIndicators(.hidden)
    .sensoryFeedback(.selection, trigger: colors.count)
  }
}

// MARK: - Settings

extension ContentView {
  /// Settings, the backstage: rooms, devices, accounts and diagnostics. Small rows and system symbols; this is the
  /// one place the hardware (strips, the cloud bulb, the IR bridge) is named.
  var settingsTab: some View {
    NavigationStack {
      List {
      Group {
        Section {
          ForEach(room.rooms, id: \.self) { name in
            Button {
              roomName = name
              roomEdit = .rename(name)
            } label: {
              LabeledContent(name) {
                let n = room.items.filter { room.roomOf($0) == name }.count
                Text(n == 1 ? "1 device" : "\(n) devices").foregroundStyle(Ink.dim)
              }
              .foregroundStyle(Ink.text)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              if room.rooms.count > 1 {
                Button(role: .destructive) { deletingRoom = name } label: { Label("Delete", systemImage: "trash") }
              }
            }
          }
          Button {
            roomName = ""
            roomEdit = .add
          } label: { Label("Add a room", systemImage: "plus") }
        } header: { SectionTitle("Rooms") }

        Section {
          ForEach(room.items) { item in
            Button { open(item) } label: {
              HStack(spacing: 12) {
                Image(systemName: deviceSymbol(item))
                  .font(.body)
                  .foregroundStyle(Ink.dim)
                  .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.name).foregroundStyle(Ink.text)
                  if case .offline(let why) = item.status {
                    Text(why).font(.footnote).foregroundStyle(Ink.bad)
                  } else {
                    Text("\(deviceKind(item)) · \(room.roomOf(item))").font(.footnote).foregroundStyle(Ink.dim)
                  }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.dim)
              }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) { removing = item } label: { Label("Remove", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
              if item.status == .ready, item.caps.contains(.power) {
                Button { room.identify(item.id) } label: { Label("Blink", systemImage: "light.max") }.tint(.gray)
              }
            }
          }
          LabeledContent {
            Text(bridgeState).foregroundStyle(Ink.dim)
          } label: {
            Label("IR bridge", systemImage: "sensor.tag.radiowaves.forward")
          }
          Button { sheet = .add } label: { Label("Add a device", systemImage: "plus") }
        } header: { SectionTitle("Devices") } footer: {
          Text("Swipe right on a light to blink it.")
        }

        Section {
          if room.hubspace.state == .ready {
            Button("Sign out of Hubspace", role: .destructive) { room.hubspace.signOut() }
          } else {
            Button("Sign in to Hubspace") { sheet = .hubSetup }
          }
        } header: { SectionTitle("Accounts") }

        Section {
          Toggle("Reduce flashing", isOn: Binding(get: { room.reduceFlashing }, set: { room.reduceFlashing = $0 }))
        } header: { SectionTitle("Comfort") } footer: {
          Text("Hides blink, flash and strobe effects and calms music mode.")
        }

        Section {
          Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          } label: { Label("Bluetooth and location access", systemImage: "hand.raised") }
          Button { sheet = .log } label: { Label("Activity log", systemImage: "doc.text") }
        } header: { SectionTitle("System") }

        Section {
          LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        } header: { SectionTitle("About") }
      }
      .listRowBackground(Ink.card)
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(RoomGlow(room: room))
      .foregroundStyle(Ink.text)
      .tint(Ink.text)
      .navigationTitle("Settings")
    }
  }

  private func deviceSymbol(_ item: LightItem) -> String {
    switch item.kind {
    case .strip: "light.strip.2"
    case .bulb, .bleBulb: "lightbulb"
    case .remote: "av.remote"
    }
  }

  private func deviceKind(_ item: LightItem) -> String {
    switch item.kind {
    case .strip: "LED strip"
    case .bulb: "Hubspace bulb"
    case .bleBulb: "Bluetooth bulb"
    case .remote: "Infrared"
    }
  }

  private var bridgeState: String {
    switch room.bridge.state {
    case .ready: "Connected"
    case .connecting: "Connecting"
    case .searching: "Looking for it"
    case .off: "Not set up"
    }
  }
}

// MARK: - Home pieces

private struct SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text.uppercased())
      .font(.caption.weight(.semibold))
      .tracking(2)
      .foregroundStyle(Ink.dim)
  }
}

/// The room's power, Dorm Remote's signature control. Off: a dark disc with a quiet ring. On: the ring takes on the
/// room's live colors and lights its center a little, so every light reads as one room (the app keeps them in step
/// underneath). State is in the words too, not only the color.
private struct RoomPower: View {
  let on: Bool
  let colors: [Color]
  let action: () -> Void

  var body: some View {
    let lit = on && !colors.isEmpty
    Button(action: action) {
      ZStack {
        Circle().fill(Ink.card)
        if lit {
          Circle()
            .fill(RadialGradient(colors: [colors[0].opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 64))
          Circle()
            .strokeBorder(AngularGradient(colors: colors + [colors[0]], center: .center), lineWidth: 4)
            .shadow(color: colors[0].opacity(0.4), radius: 14)
        } else {
          Circle().strokeBorder(Ink.line, lineWidth: 2)
        }
        VStack(spacing: 6) {
          Image(systemName: "power").font(.system(size: 30, weight: .semibold))
          Text(on ? "On" : "Off").font(.footnote.weight(.semibold)).foregroundStyle(Ink.dim)
        }
        .foregroundStyle(Ink.text)
      }
      .frame(width: 128, height: 128)
      .animation(Motion.mood, value: lit)
      .animation(Motion.frame, value: colors)
    }
    .buttonStyle(Press())
    .sensoryFeedback(.impact(weight: .medium), trigger: on)
    .accessibilityLabel("Room power")
    .accessibilityValue(on ? "On" : "Off")
    .accessibilityHint(on ? "Turns every light in the room off" : "Turns every light in the room on")
  }
}

/// A scene as a small window into a dark room, lit the scene's way: still for whites, a slow breath for a single
/// color, drifting pools for a palette, a turning hue for Party. The motion is a few percent and slow; with Reduce
/// Motion it stops.
private struct ScenePreview: View {
  let mood: Mood
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private enum Kind { case still, breathe, drift, cycle }

  private var kind: Kind {
    switch mood.look {
    case .white, .snapshot: .still
    case .color: .breathe
    case .palette: .drift
    case .party: .cycle
    }
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion || kind == .still)) { context in
      let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
      Canvas { ctx, size in
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x0C0C10)))
        let colors = mood.swatch
        let n = max(1, min(colors.count, 4))
        let level = 0.4 + 0.6 * Double(mood.brightness) / 100
        for i in 0..<n {
          let phase = Double(i) * 2.1
          var x = (Double(i) + 0.5) / Double(n)
          var y = 1.0
          var alpha = level
          var color = colors[i % colors.count]
          switch kind {
          case .still: break
          case .breathe: alpha *= 0.88 + 0.12 * sin(t / 2.4)
          case .drift:
            x += 0.07 * sin(t / 5 + phase)
            y += 0.05 * cos(t / 6 + phase)
          case .cycle:
            color = Color(hue: (Double(i) / Double(n) + t / 40).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 1)
          }
          let center = CGPoint(x: x * size.width, y: y * size.height)
          let r = size.width * (n == 1 ? 0.95 : 0.62)
          ctx.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                   with: .radialGradient(Gradient(colors: [color.opacity(alpha), color.opacity(0)]),
                                         center: center, startRadius: 0, endRadius: r))
        }
      }
    }
    .accessibilityHidden(true)
  }
}

/// Glowing circle in the light's color, like the bulb icon in Hubspace's list.
private struct Orb: View {
  let item: LightItem
  /// What the light shows right now (an effect's current frame); its saved look otherwise.
  var color: RGB?
  var size: CGFloat = 52

  var body: some View {
    let lit = item.status == .ready && item.on
    let glow = (color ?? item.glow).color
    Image(systemName: icon)
      .font(.system(size: size * 0.4, weight: .medium))
      .frame(width: size, height: size)
      .foregroundStyle(lit ? .black.opacity(0.75) : Ink.dim)
      .background(Circle().fill(lit ? glow : Ink.raised))
      .shadow(color: lit ? glow.opacity(0.45) : .clear, radius: 12)
      .animation(Motion.state, value: lit)
      .animation(Motion.frame, value: color)
  }

  private var icon: String {
    switch item.kind {
    case .strip: "light.strip.2"
    case .bulb, .bleBulb: "lightbulb.fill"
    case .remote: "dot.radiowaves.left.and.right"
    }
  }
}

/// What a light is doing, in plain words: "Violet · 72%", "Candlelight", "Off", "Not reachable". No hardware words.
@MainActor
private func plainState(_ item: LightItem, in room: Room) -> String {
  switch item.status {
  case .ready:
    if item.caps.contains(.remote) { return "Remote" }
    guard item.on else { return "Off" }
    if let effect = room.effectPlaying(on: item.id) { return effect.name }
    if let effect = item.effect { return HubspaceClient.effectName(effect) }
    let look = item.kelvin.map { $0 <= 3300 ? "Warm white" : $0 >= 5000 ? "Cool white" : "White" } ?? item.color.name
    return "\(look) · \(item.brightness)%"
  case .setup: return "Not set up"
  case .busy: return "Connecting"
  case .offline: return "Not reachable"
  }
}

/// The room's name with a chevron: the title of the Room and Map tabs, and the button that switches rooms.
private struct RoomTitle: View {
  let name: String
  var body: some View {
    HStack(spacing: 4) {
      Text(name).font(.headline)
      Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(Ink.dim)
    }
    .foregroundStyle(Ink.text)
    .frame(minHeight: 44)
  }
}

/// A light in the room: a dot in its live color, its name, what it's doing in plain words, and a power button.
/// Tap the row for its controls. No hardware words here (Bluetooth, Hubspace, bridge); Settings has those.
private struct LightRow: View {
  var room: Room
  let item: LightItem
  let open: () -> Void

  var body: some View {
    let ready = item.status == .ready
    let remote = item.caps.contains(.remote)
    let lit = ready && item.on && !remote
    let glow = room.shown(item).color
    HStack(spacing: 12) {
      Circle()
        .fill(lit ? glow : Ink.raised)
        .frame(width: 12, height: 12)
        .shadow(color: lit ? glow.opacity(0.6) : .clear, radius: 6)
        .animation(Motion.frame, value: room.shown(item))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.name).font(.body.weight(.medium)).foregroundStyle(ready ? Ink.text : Ink.dim).lineLimit(1)
        Text(status).font(.subheadline).foregroundStyle(statusColor).lineLimit(1)
      }
      Spacer(minLength: 8)
      if ready {
        Button {
          if remote { room.pressRemotePower(item) } else { room.setPower(item.id, !item.on) }
        } label: {
          Image(systemName: "power")
            .font(.subheadline.weight(.semibold))
            .frame(width: 34, height: 34)
            .foregroundStyle(lit ? Color.black.opacity(0.75) : Ink.text)
            .background(Circle().fill(lit ? glow : Ink.raised))
            .frame(width: 44, height: 44)
        }
        .buttonStyle(Press())
        .accessibilityLabel(remote ? "\(item.name) power" : item.on ? "Turn off \(item.name)" : "Turn on \(item.name)")
      } else {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.dim)
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .sensoryFeedback(.impact(weight: .light), trigger: item.on)
    .animation(Motion.state, value: item.on)
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Open \(item.name)", open)
    .contextMenu {
      if ready, item.caps.contains(.power) {
        Button("Blink", systemImage: "light.max") { room.identify(item.id) }
      }
    }
  }

  private var status: String { plainState(item, in: room) }

  private var statusColor: Color {
    if case .offline = item.status { return Ink.bad }
    return Ink.dim
  }
}

/// Wide pill slider that fills from the left, like Control Center.
private struct PillSlider: View {
  @Binding var value: Double
  var fill: AnyShapeStyle
  var range: ClosedRange<Double> = 0.01...1
  var label: String
  var showsPercent = true

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      ZStack(alignment: .leading) {
        Capsule().fill(Ink.raised)
        Capsule().fill(fill).frame(width: max(h, w * value))
        if showsPercent {
          Text("\(Int((value * 100).rounded()))%")
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(value > 0.85 ? Ink.inverse : Ink.text)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 14)
            .allowsHitTesting(false)
        }
      }
      .clipShape(Capsule())
      .contentShape(Capsule())
      .gesture(DragGesture(minimumDistance: 0).onChanged { g in
        value = min(range.upperBound, max(range.lowerBound, g.location.x / w))
      })
    }
    // A light tick every 10 %, so you can feel the level without looking.
    .sensoryFeedback(.selection, trigger: Int((value * 10).rounded()))
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue("\(Int(value * 100)) percent")
    .accessibilityAdjustableAction { dir in
      value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? 0.1 : -0.1)))
    }
  }
}

/// Track with a draggable knob, for white temperature.
private struct KnobSlider: View {
  @Binding var value: Double
  let track: AnyShapeStyle
  let label: String

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      ZStack(alignment: .leading) {
        Capsule().fill(track)
        Capsule()
          .fill(.white)
          .frame(width: h * 1.6, height: h - 8)
          .shadow(color: .black.opacity(0.3), radius: 4)
          .offset(x: 4 + (w - h * 1.6 - 8) * value)
      }
      .contentShape(Capsule())
      .gesture(DragGesture(minimumDistance: 0).onChanged { g in
        value = min(1, max(0, g.location.x / w))
      })
    }
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityAdjustableAction { dir in
      value = min(1, max(0, value + (dir == .increment ? 0.1 : -0.1)))
    }
  }
}

// MARK: - Light sheet

private struct LightSheet: View {
  enum Mode: String, CaseIterable {
    case white = "White", color = "Color", effects = "Effects"
    var capability: LightItem.Capability {
      switch self {
      case .white: .white
      case .color: .color
      case .effects: .effects
      }
    }
  }

  var room: Room
  let id: String
  /// Opens color matching in place of this sheet (Apple HIG: one sheet at a time).
  var openMatch: () -> Void = {}
  @State private var mode = Mode.color
  @State private var renaming = false
  @State private var confirmRemove = false
  @State private var newName = ""
  @Environment(\.dismiss) private var dismiss

  /// Room controls: the same sheet, acting on every light in the room.
  private var isRoom: Bool { id == Room.all }

  /// For the room, Effects means strip effects, so it shows only when the room has a strip.
  private func modeAvailable(_ m: Mode, _ item: LightItem) -> Bool {
    guard isRoom else { return item.caps.contains(m.capability) }
    return m != .effects || room.roomReady.contains { $0.kind == .strip }
  }

  // Fully saturated, one hue step apart, so each reads as its own color on an LED instead of drifting to white.
  private static let swatches: [RGB] = [
    RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 90, b: 0), RGB(r: 255, g: 160, b: 0), RGB(r: 255, g: 230, b: 0),
    RGB(r: 157, g: 255, b: 0), RGB(r: 0, g: 255, b: 64), RGB(r: 0, g: 255, b: 192), RGB(r: 0, g: 217, b: 255),
    RGB(r: 0, g: 40, b: 255), RGB(r: 122, g: 0, b: 255), RGB(r: 255, g: 0, b: 225), RGB(r: 255, g: 45, b: 120),
  ]
  private static let swatchNames = ["Red", "Orange", "Amber", "Yellow", "Lime", "Green", "Teal", "Cyan", "Blue", "Violet", "Magenta", "Pink"]
  private static let temperatures = [2200, 2700, 4000, 5000, 6500]

  var body: some View {
    if let item = isRoom ? room.look(id) : room.item(id) {
      // What the light shows right now, so the switch and slider move with a running effect like the Room tab does.
      let glow = (isRoom ? room.ambient : room.shown(item).color) ?? item.glow.color
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          HStack(spacing: 16) {
            Orb(item: item, color: isRoom ? nil : room.live[item.id], size: 44)
            Text(isRoom ? room.currentRoom : item.name)
              .font(.system(.title, design: .rounded, weight: .bold))
              .lineLimit(1)
            Spacer()
            Toggle(item.name, isOn: Binding(get: { item.on }, set: { room.setPower(id, $0) }))
              .labelsHidden()
              .tint(glow)
          }

          modePicker(item)

          VStack(alignment: .leading, spacing: 12) {
            Label("Brightness", systemImage: "sun.max")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Ink.dim)
            PillSlider(
              value: Binding(get: { Double(item.brightness) / 100 }, set: { room.setBrightness(id, Int(($0 * 100).rounded())) }),
              fill: AnyShapeStyle(glow),
              label: "Brightness"
            )
            .frame(height: 48)
          }

          switch mode {
          case .white: whiteControls(item)
          case .color: colorControls(item)
          case .effects:
            if isRoom || item.kind == .strip { stripEffects } else { bulbEffects(item) }
          }

          if !isRoom, item.kind == .bulb {
            Text("The bulb takes commands through Hubspace's cloud, so it has to be on Wi-Fi. Changes can take a second.")
              .font(.footnote)
              .foregroundStyle(Ink.dim)
          }

          if isRoom {
            Text("Changes here go to every light in \(room.currentRoom).").font(.footnote).foregroundStyle(Ink.dim)
          } else {
            footer(item)
          }
        }
        .padding(24)
        .padding(.top, 8)
      }
      .onAppear {
        let inEffect = room.effectPlaying(on: id) != nil || (!isRoom && item.effect != nil)
        mode = inEffect ? .effects : item.kelvin != nil ? .white : .color
      }
      .alert("This effect flashes", isPresented: Binding(get: { room.flashWarning }, set: { room.flashWarning = $0 })) {
        Button("Turn on Reduce flashing") {
          room.reduceFlashing = true
          room.endEffect()
        }
        Button("Keep it", role: .cancel) {}
      } message: {
        Text("Blink, flash and strobe effects can bother anyone sensitive to flashing light. Reduce flashing hides them; it's also in Settings.")
      }
      .alert("Rename", isPresented: $renaming) {
        TextField("Name", text: $newName)
        Button("Save") { room.rename(id, to: newName) }
        Button("Cancel", role: .cancel) {}
      }
    } else {
      // The light went away (strip forgotten, signed out).
      Color.clear.onAppear { dismiss() }
    }
  }

  private func modePicker(_ item: LightItem) -> some View {
    return HStack(spacing: 0) {
      ForEach(Mode.allCases.filter { modeAvailable($0, item) }, id: \.self) { m in
        Button { mode = m } label: {
          VStack(spacing: 8) {
            modeCircle(m)
              .frame(width: 60, height: 60)
              .padding(5)
              .overlay(Circle().strokeBorder(Ink.text.opacity(mode == m ? 0.9 : 0), lineWidth: 2))
            Text(m.rawValue)
              .font(.caption.weight(.medium))
              .foregroundStyle(mode == m ? Ink.text : Ink.dim)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(Press())
        .accessibilityAddTraits(mode == m ? .isSelected : [])
      }
    }
    .animation(Motion.state, value: mode)
    .sensoryFeedback(.selection, trigger: mode)
  }

  @ViewBuilder
  private func modeCircle(_ m: Mode) -> some View {
    switch m {
    case .white:
      Circle().fill(AngularGradient(colors: [RGB.kelvin(2200).color, .white, RGB.kelvin(6500).color, Color(hex: 0x9FC9F0), RGB.kelvin(2200).color], center: .center))
    case .color:
      Circle().fill(AngularGradient(colors: (0...12).map { RGB.hue(Double($0) / 12).color }, center: .center))
    case .effects:
      Circle()
        .fill(Ink.raised)
        .overlay(Image(systemName: "play.fill").font(.title2).foregroundStyle(Ink.text))
    }
  }

  private func whiteControls(_ item: LightItem) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("White temperature  \(item.kelvin ?? 4000)K", systemImage: "thermometer.medium")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Ink.dim)
      KnobSlider(
        value: Binding(get: { (Double(item.kelvin ?? 4000) - 2200) / 4300 },
                       set: { room.setWhite(id, Int((2200 + $0 * 4300) / 50) * 50) }),
        track: AnyShapeStyle(LinearGradient(colors: [RGB.kelvin(2200).color, .white, Color(hex: 0x9FC9F0)], startPoint: .leading, endPoint: .trailing)),
        label: "White temperature"
      )
      .frame(height: 48)
      HStack {
        ForEach(Self.temperatures, id: \.self) { k in
          Button { room.setWhite(id, k) } label: {
            Circle()
              .fill(RGB.kelvin(k).color)
              .frame(width: 48, height: 48)
              .padding(4)
              .overlay(Circle().strokeBorder(Ink.text, lineWidth: item.kelvin == k ? 2 : 0))
          }
          .buttonStyle(Press())
          .frame(maxWidth: .infinity)
          .accessibilityLabel("\(k) kelvin")
        }
      }
    }
  }

  private func colorControls(_ item: LightItem) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Presets", systemImage: "paintpalette")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Ink.dim)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 16) {
        ForEach(Self.swatches.indices, id: \.self) { i in
          let c = Self.swatches[i]
          Button { room.setColor(id, c) } label: {
            Circle()
              .fill(c.color)
              .frame(width: 52, height: 52)
              .padding(4)
              .overlay(Circle().strokeBorder(Ink.text, lineWidth: item.kelvin == nil && item.color == c ? 2 : 0))
          }
          .buttonStyle(Press())
          .accessibilityLabel(Self.swatchNames[i])
        }
      }
      if !room.recentColors.isEmpty {
        Label("Recent", systemImage: "clock")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Ink.dim)
        ScrollView(.horizontal) {
          HStack(spacing: 12) {
            ForEach(Array(room.recentColors.enumerated()), id: \.offset) { _, c in
              Button { room.setColor(id, c) } label: {
                Circle()
                  .fill(c.color)
                  .frame(width: 44, height: 44)
                  .padding(4)
                  .overlay(Circle().strokeBorder(Ink.text, lineWidth: item.kelvin == nil && item.color == c ? 2 : 0))
              }
              .buttonStyle(Press())
              .accessibilityLabel("Recent color")
            }
          }
        }
        .scrollIndicators(.hidden)
      }
      ColorWheel(selected: item.kelvin == nil ? item.color : nil, pick: { room.setColor(id, $0) }, done: { room.remember($0) })
        .padding(.horizontal, 24)
    }
  }

  private static let twoColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

  private func heading(_ title: String, _ icon: String) -> some View {
    Label(title, systemImage: icon)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Ink.dim)
  }

  private func speedSlider(_ value: Double, _ set: @escaping (Double) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      heading("Speed", "gauge.with.dots.needle.50percent")
      PillSlider(value: Binding(get: { value }, set: set), fill: AnyShapeStyle(Ink.text), label: "Speed")
        .frame(height: 40)
    }
  }

  private var stripEffects: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let playing = room.effectPlaying(on: id) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Playing").font(.footnote).foregroundStyle(Ink.dim)
            Text(playing.name).font(.headline)
          }
          Spacer()
          Button { room.endEffect() } label: {
            Label("Stop", systemImage: "stop.fill")
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 16)
              .frame(minHeight: 44)
              .foregroundStyle(Ink.inverse)
              .background(Capsule().fill(Ink.text))
          }
          .buttonStyle(Press())
        }
        if playing.hasSpeed {
          speedSlider(Double(room.speed - 1) / 99) { room.setSpeed(1 + Int(($0 * 99).rounded())) }
        }
      }
      heading("Cozy", "flame")
      LazyVGrid(columns: Self.twoColumns, spacing: 12) {
        effectCard("Candlelight", colors: [Color(hex: 0xFF8C1A), Color(hex: 0xFFB347), Color(hex: 0x7A3A00)],
                   active: room.effectPlaying(on: id) == .candle) { room.start(.candle, on: id) }
        effectCard("Fireplace", colors: [Color(hex: 0xFF3B00), Color(hex: 0xFF8A00), Color(hex: 0x5A1400)],
                   active: room.effectPlaying(on: id) == .fire) { room.start(.fire, on: id) }
      }
      heading("In sync", "link")
      effectCard("Rainbow in sync", colors: Effect.rainbow.map(\.color), active: room.effectPlaying(on: id) == .synced) { room.start(.synced, on: id) }
      ForEach(Effect.patternGroups.filter { !room.reduceFlashing || !Room.flashingGroups.contains($0.0) }, id: \.0) { group in
        heading(group.0, "sparkles")
        LazyVGrid(columns: Self.twoColumns, spacing: 12) {
          ForEach(group.1) { p in
            effectCard(p.name, colors: p.colors.map(\.color), active: room.effectPlaying(on: id) == .pattern(p.id)) { room.start(.pattern(p.id), on: id) }
          }
        }
      }
      heading("Music", "waveform")
      effectCard("Pulse to music (phone mic)", colors: [.pink, .purple, .cyan], active: room.effectPlaying(on: id) == .phoneMic) { room.start(.phoneMic, on: id) }
      if room.effectPlaying(on: id) == .phoneMic {
        Capsule()
          .fill(Ink.raised)
          .overlay(alignment: .leading) {
            GeometryReader { geo in Capsule().fill(Ink.text).frame(width: geo.size.width * room.level) }
          }
          .frame(height: 6)
          .animation(.linear(duration: 0.05), value: room.level)
      }
      Text(isRoom
           ? "Built-in effects run on each strip and keep going when you close the app, but two strips drift apart over time. \"Rainbow in sync\", the flames and music run from your phone, so they stay together while the app is open. The smart bulb joins in too: its own matching effect, or a color every few seconds sent ahead by its cloud delay."
           : "Built-in effects run on the strip and keep going when you close the app. \"Rainbow in sync\", the flames and music run from your phone while the app is open. Start an effect from Room controls to bring the other lights along.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
      if let error = room.effectError {
        Text(error).font(.footnote).foregroundStyle(Ink.bad)
      }
      Toggle(isOn: Binding(get: { room.reduceFlashing }, set: { room.reduceFlashing = $0 })) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Reduce flashing").font(.subheadline.weight(.semibold))
          Text("Hides blink, flash and strobe effects, and keeps music mode and Party smooth.")
            .font(.footnote)
            .foregroundStyle(Ink.dim)
        }
      }
      .frame(minHeight: 44)
    }
  }

  private func bulbEffects(_ item: LightItem) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      if item.effect != nil {
        speedSlider(Double(item.speed + 10) / 20) { room.setBulbSpeed(id, Int(($0 * 20).rounded()) - 10) }
      }
      ForEach(HubspaceClient.effectGroups, id: \.0) { group in
        heading(group.0, group.0 == "Holidays" ? "gift" : "sparkles")
        LazyVGrid(columns: Self.twoColumns, spacing: 12) {
          ForEach(group.1, id: \.id) { e in
            effectCard(e.name, colors: HubspaceClient.colors(ofEffect: e.id).map(\.color), active: item.effect == e.id) {
              room.setBulbEffect(id, e.id)
            }
          }
        }
      }
      Text("These run on the bulb itself, so they keep going after you close the app.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
    }
  }

  private func effectCard(_ name: String, colors: [Color], active: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Circle()
          .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
          .frame(width: 28, height: 28)
        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 56)
      // The running effect lights up in its own colors.
      .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.raised))
      .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(active ? Ink.text : Ink.line, lineWidth: active ? 1.5 : 1))
      .animation(Motion.state, value: active)
    }
    .buttonStyle(Press())
    .sensoryFeedback(.selection, trigger: active)
    .accessibilityAddTraits(active ? .isSelected : [])
  }

  private func footer(_ item: LightItem) -> some View {
    VStack(alignment: .leading, spacing: 12) {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Room")
        Text("Scenes and the power button act on one room at a time.").font(.footnote).foregroundStyle(Ink.dim)
      }
      Spacer()
      Picker("Room", selection: Binding(get: { room.roomOf(item) }, set: { room.setRoom(id, $0) })) {
        ForEach(room.rooms, id: \.self) { Text($0).tag($0) }
      }
      .pickerStyle(.menu)
    }
    if item.kind == .strip {
      Button(action: openMatch) {
        Label("Match colors with the lamp", systemImage: "eyedropper.halffull")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 48)
          .background(Capsule().fill(Ink.raised))
      }
      .buttonStyle(Press())
    }
    HStack {
      Button("Rename") {
        newName = item.name
        renaming = true
      }
      Spacer()
      Button(item.kind == .strip ? "Forget strip" : "Remove", role: .destructive) { confirmRemove = true }
        .confirmationDialog("Remove \(item.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
          Button("Remove", role: .destructive) {
            room.remove(item)
            dismiss()
          }
        } message: {
          Text("You can add it back from Add.")
        }
    }
    .font(.subheadline)
    .frame(minHeight: 44)
    }
  }
}

/// Puts the same color on the strip and the lamp; sliders scale the strip's red, green, and blue until they match.
private struct MatchSheet: View {
  var room: Room
  @State private var balance: [Double] = []
  @State private var test = 0
  @Environment(\.dismiss) private var dismiss

  private static let tests: [(String, RGB)] = [
    ("White", RGB(r: 255, g: 255, b: 255)), ("Orange", RGB(r: 255, g: 100, b: 20)),
    ("Purple", RGB(r: 140, g: 0, b: 255)), ("Teal", RGB(r: 0, g: 210, b: 200)),
  ]
  private static let channels: [(String, Color)] = [("Red", .red), ("Green", .green), ("Blue", .blue)]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Match colors").font(.system(.title, design: .rounded, weight: .bold))
          Text("Your lamp and strip now show the same color. Slide the strip's channels until it looks like the lamp. Start with White, then check the others.")
            .foregroundStyle(Ink.dim)
        }
        HStack(spacing: 8) {
          ForEach(Self.tests.indices, id: \.self) { i in
            Button {
              test = i
              room.showForMatching(Self.tests[i].1)
            } label: {
              VStack(spacing: 6) {
                Circle().fill(Self.tests[i].1.color).frame(width: 44, height: 44)
                  .overlay(Circle().strokeBorder(Ink.text, lineWidth: test == i ? 2 : 0).padding(-4))
                Text(Self.tests[i].0).font(.caption).foregroundStyle(test == i ? Ink.text : Ink.dim)
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(Press())
          }
        }
        if balance.count == 3 {
          ForEach(0..<3, id: \.self) { i in
            VStack(alignment: .leading, spacing: 8) {
              Text("Strip \(Self.channels[i].0.lowercased())").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.dim)
              PillSlider(
                value: Binding(get: { balance[i] }, set: { v in
                  balance[i] = v
                  room.setStripBalance(balance, resend: Self.tests[test].1)
                }),
                fill: AnyShapeStyle(Self.channels[i].1.opacity(0.8)),
                range: 0.05...1,
                label: "Strip \(Self.channels[i].0)"
              )
              .frame(height: 44)
            }
          }
        }
        HStack {
          Button("Reset") {
            balance = Daybetter.defaultBalance
            room.setStripBalance(balance, resend: Self.tests[test].1)
          }
          Spacer()
          Button("Done") { dismiss() }.font(.body.weight(.semibold))
        }
        .frame(minHeight: 44)
      }
      .padding(24)
    }
    .onAppear {
      balance = room.strip.balance
      room.showForMatching(Self.tests[test].1)
    }
  }
}

/// Hue around the edge, saturation toward the middle.
private struct ColorWheel: View {
  let selected: RGB?
  let pick: (RGB) -> Void
  /// The color where the finger lifted, for the Recent row.
  var done: (RGB) -> Void = { _ in }

  var body: some View {
    GeometryReader { geo in
      let r = min(geo.size.width, geo.size.height) / 2
      ZStack {
        Circle().fill(AngularGradient(colors: (0...12).map { RGB.hue(Double($0) / 12).color }, center: .center))
        Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
        if let selected {
          let (h, s) = selected.hueSaturation
          Circle()
            .fill(selected.color)
            .frame(width: 32, height: 32)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.4), radius: 4)
            .offset(x: cos(h * 2 * .pi) * s * r, y: sin(h * 2 * .pi) * s * r)
        }
      }
      .frame(width: r * 2, height: r * 2)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Circle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in pick(color(at: g.location, in: geo.size, r: r)) }
        .onEnded { g in done(color(at: g.location, in: geo.size, r: r)) })
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityLabel("Color wheel")
    .accessibilityValue(selected?.name ?? "No color picked")
  }

  private func color(at p: CGPoint, in size: CGSize, r: CGFloat) -> RGB {
    let dx = p.x - size.width / 2, dy = p.y - size.height / 2
    return RGB.hue(atan2(dy, dx) / (2 * .pi), saturation: min(1, (dx * dx + dy * dy).squareRoot() / r))
  }
}

// MARK: - Setup

private struct StripSetup: View {
  var strip: StripController
  @State private var showOthers = false
  /// Nothing turned up after a few seconds: show the fixes.
  @State private var slowSearch = false
  @Environment(\.dismiss) private var dismiss

  // DayBetter FAQ (daybetter.net) and what the app itself needs.
  private static let tips = [
    "Swipe the DayBetter app away in the app switcher. A strip talks to one app at a time.",
    "Unplug the strip's power for 10 seconds, then plug it back in.",
    "Turn Bluetooth off and on in Control Center.",
    "Move closer. The controller box is the part with the antenna.",
    "Strips you've already added stay connected and don't show up here. Check the Lights list.",
    "Some controllers use other names: open \"Show all Bluetooth devices\" below.",
  ]

  var body: some View {
    let isStrip = { (d: FoundDevice) in d.daybetter || Daybetter.looksLikeStrip(d.name) }
    // In a dorm, the neighbors' strips show up too: closest first, and say which one that is.
    let strips = strip.devices.filter(isStrip).sorted { $0.rssi > $1.rssi }
    let others = strip.devices.filter { !isStrip($0) }
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text(strip.strips.isEmpty ? "Add your LED strip" : "Add another LED strip").font(.system(.title, design: .rounded, weight: .bold))
          Text("Close the DayBetter app first. The strip only talks to one app at a time. Strips you've already added stay connected and aren't listed.")
            .foregroundStyle(Ink.dim)
        }

        if !strip.bluetoothOn {
          Text("Turn on Bluetooth.").foregroundStyle(Ink.dim)
        } else if case .failed(let message) = strip.adding?.state {
          Text(message).foregroundStyle(Ink.bad)
          Button("Try again") {
            strip.cancelAdding()
            strip.scan()
          }
          .frame(minHeight: 44)
        } else if strip.adding != nil {
          HStack(spacing: 12) {
            ProgressView()
            Text("Connecting…").foregroundStyle(Ink.dim)
            Spacer()
            Button("Cancel") { strip.cancelAdding() }.frame(minHeight: 44)
          }
        } else {
          if strips.isEmpty {
            HStack(spacing: 12) {
              ProgressView()
              Text("Looking for DayBetter strips…").foregroundStyle(Ink.dim)
            }
            if slowSearch {
              VStack(alignment: .leading, spacing: 12) {
                Text("Not showing up? Try these").font(.subheadline.weight(.semibold))
                ForEach(Self.tips, id: \.self) { tip in
                  Label(tip, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .padding(16)
              .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.raised.opacity(0.6)))
              .transition(.opacity)
            }
          }
          ForEach(strips) { device in
            Button { strip.connect(device) } label: {
              HStack(spacing: 16) {
                Image(systemName: "light.strip.2")
                  .frame(width: 44, height: 44)
                  .background(Circle().fill(Ink.raised))
                VStack(alignment: .leading, spacing: 2) {
                  Text("DayBetter strip").font(.body.weight(.semibold))
                  Text(strips.count > 1 && device.id == strips.first?.id ? "\(device.name) · closest to you" : device.name)
                    .font(.footnote).foregroundStyle(Ink.dim)
                }
                Spacer()
                SignalBars(rssi: device.rssi)
              }
              .padding(16)
              .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.raised.opacity(0.6)))
            }
            .buttonStyle(Press())
          }

          DisclosureGroup("Not listed? Show all Bluetooth devices", isExpanded: $showOthers) {
            VStack(spacing: 0) {
              ForEach(others) { device in
                Button { strip.connect(device) } label: {
                  HStack {
                    Text(device.name)
                    Spacer()
                    SignalBars(rssi: device.rssi)
                  }
                  .frame(minHeight: 48)
                  .contentShape(Rectangle())
                }
                .buttonStyle(Press())
              }
            }
          }
          .font(.subheadline)
          .foregroundStyle(Ink.dim)
        }
      }
      .padding(24)
    }
    .onAppear {
      if case .failed = strip.adding?.state { strip.cancelAdding() }
      strip.scan()
    }
    .onDisappear { strip.stopScan() }
    .task {
      try? await Task.sleep(for: .seconds(8))
      withAnimation(Motion.state) { slowSearch = true }
    }
    // The picked strip connected and joined the list.
    .onChange(of: strip.strips.count) { old, new in if new > old { dismiss() } }
  }
}

private struct SignalBars: View {
  let rssi: Int
  var body: some View {
    let bars = rssi > -65 ? 3 : rssi > -85 ? 2 : 1
    HStack(alignment: .bottom, spacing: 2) {
      ForEach(1...3, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1)
          .fill(i <= bars ? Ink.text : Ink.raised)
          .frame(width: 4, height: CGFloat(4 + i * 4))
      }
    }
    .accessibilityLabel("Signal \(bars) of 3")
  }
}

private struct AddSheet: View {
  let pick: (Room.AddKind) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a light").font(.system(.title, design: .rounded, weight: .bold)).padding(.bottom, 8)
      ForEach(Room.AddKind.allCases) { kind in
        Button {
          dismiss()
          pick(kind)
        } label: {
          HStack(spacing: 16) {
            Image(systemName: icon(kind))
              .frame(width: 44, height: 44)
              .background(Circle().fill(Ink.raised))
            VStack(alignment: .leading, spacing: 2) {
              Text(kind.rawValue).font(.body.weight(.semibold))
              Text(detail(kind)).font(.footnote).foregroundStyle(Ink.dim)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Ink.dim)
          }
          .padding(16)
          .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.raised.opacity(0.6)))
        }
        .buttonStyle(Press())
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .presentationDetents([.medium, .large])
  }

  private func icon(_ kind: Room.AddKind) -> String {
    switch kind {
    case .strip: "light.strip.2"
    case .hubspace, .bluetooth: "lightbulb.fill"
    case .remote: "dot.radiowaves.left.and.right"
    }
  }

  private func detail(_ kind: Room.AddKind) -> String {
    switch kind {
    case .strip: "Bluetooth, works offline"
    case .hubspace: "Needs the bulb on Wi-Fi"
    case .bluetooth: "Happy Lighting or Lotus Lamp bulbs, offline"
    case .remote: "Projector, fan, TV, AC… through the IR bridge"
    }
  }
}

private struct LampSetup: View {
  var lamps: BulbBank
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Add a Bluetooth bulb").font(.system(.title, design: .rounded, weight: .bold))
          Text("Works fully offline with bulbs made for the Happy Lighting app (they show up as Triones) or the Lotus Lamp app (ELK-BLEDOM). Close that app first.")
            .foregroundStyle(Ink.dim)
        }
        if lamps.nearby.isEmpty {
          HStack(spacing: 12) {
            ProgressView()
            Text("Looking for bulbs…").foregroundStyle(Ink.dim)
          }
        }
        ForEach(lamps.nearby) { device in
          Button {
            lamps.add(device)
            dismiss()
          } label: {
            HStack(spacing: 16) {
              Image(systemName: "lightbulb.fill")
                .frame(width: 44, height: 44)
                .background(Circle().fill(Ink.raised))
              Text(device.name).font(.body.weight(.semibold))
              Spacer()
              SignalBars(rssi: device.rssi)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Ink.raised.opacity(0.6)))
          }
          .buttonStyle(Press())
        }
      }
      .padding(24)
    }
    .onAppear { lamps.scan() }
    .onDisappear { lamps.stopScan() }
  }
}

private struct HubSetup: View {
  var hubspace: HubspaceClient
  @State private var email = ""
  @State private var password = ""
  @State private var code = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Add your smart bulb").font(.system(.title, design: .rounded, weight: .bold))
          Text("Sign in with your Hubspace account. The bulb has to be on Wi-Fi first: Hubspace encrypts its Bluetooth, so only its own app can use that. On campus Wi-Fi, register the bulb's Wi-Fi MAC address (Hubspace app → bulb → Settings) on your school's device network, then finish Wi-Fi setup in the Hubspace app.")
            .foregroundStyle(Ink.dim)
        }

        switch hubspace.state {
        case .needsCode:
          Text("Hubspace emailed you a code.").foregroundStyle(Ink.dim)
          if let error = hubspace.commandError {
            Text(error).foregroundStyle(Ink.bad).font(.subheadline)
          }
          field("Code") {
            TextField("", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
          }
          primary("Continue", disabled: code.isEmpty) { await hubspace.submitCode(code) }
        case .signingIn, .loading:
          ProgressView().frame(maxWidth: .infinity, minHeight: 52)
        case .unavailable(let message):
          Text("Couldn't reach Hubspace: \(message)").foregroundStyle(Ink.bad)
          primary("Try again", disabled: false) { await hubspace.load() }
        case .ready:
          // Signed in; a bulb tile sent you here because Hubspace can't reach that bulb.
          VStack(alignment: .leading, spacing: 12) {
            Text("Get the bulb on Wi-Fi").font(.headline)
            ForEach(Array(Self.wifiSteps.enumerated()), id: \.offset) { i, step in
              HStack(alignment: .top, spacing: 12) {
                Text("\(i + 1)").font(.subheadline.weight(.bold)).frame(width: 24, height: 24).background(Circle().fill(Ink.raised))
                Text(step).font(.subheadline).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          primary("Check again", disabled: false) {
            hubspace.clearOffline()
            await hubspace.refresh()
            dismiss()
          }
        default:
          if case .loginFailed(let message) = hubspace.state {
            Text(message).foregroundStyle(Ink.bad).font(.subheadline)
          }
          field("Email") {
            TextField("", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never)
          }
          field("Password") {
            SecureField("", text: $password).textContentType(.password)
          }
          primary("Sign in", disabled: email.isEmpty || password.isEmpty) {
            await hubspace.signIn(email: email, password: password)
          }
        }
      }
      .padding(24)
    }
    // Signing in finishes setup; the Wi-Fi help (opened while signed in) closes itself from "Check again".
    .onChange(of: hubspace.state) { _, new in if new == .ready, hubspace.offline.isEmpty { dismiss() } }
  }

  // docs/ARCHITECTURE.md, Hubspace bulbs: campus networks only admit registered devices, and the bulb needs 2.4 GHz.
  private static let wifiSteps = [
    "In the Hubspace app, open the bulb's settings and copy its Wi-Fi MAC address.",
    "Register that address on your school's device network (at NC A&T: Aggie_Guest self-registration, signed in with AggiePride). Wait for \"Approved\".",
    "Run Wi-Fi setup for the bulb in the Hubspace app and pick that network. It has to be 2.4 GHz.",
    "No campus network? A spare phone's Personal Hotspot with Maximize Compatibility on works too.",
    "Come back and tap Check again, or pull down on the home screen.",
  ]

  private func field(_ label: String, @ViewBuilder _ input: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label).font(.subheadline).foregroundStyle(Ink.dim)
      input()
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
  }

  private func primary(_ title: String, disabled: Bool, _ action: @escaping () async -> Void) -> some View {
    Button { Task { await action() } } label: {
      Text(title)
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(Ink.inverse)
        .background(Capsule().fill(Ink.text))
    }
    .buttonStyle(Press())
    .disabled(disabled)
    .opacity(disabled ? 0.4 : 1)
  }
}

/// Walk in settings: light up when you get home (WalkIn.swift). Lives on the Automations tab.
private struct WalkInSection: View {
  var room: Room

  var body: some View {
    let walkIn = room.walkIn
    VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Your room lights up when you get back and knows when you've left. Your IR bridge's beacon tells it you're at your room; your strips and a circle around your building back it up.")
            .foregroundStyle(Ink.dim)
        }
        sensors(walkIn)

        Toggle(isOn: Binding(get: { walkIn.enabled }, set: { walkIn.enabled = $0 })) {
          Text("Light up when I get home").font(.body.weight(.semibold))
        }
        .frame(minHeight: 44)

        Group {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("What comes on")
              Spacer()
              Picker("What comes on", selection: Binding(get: { walkIn.sceneID }, set: { walkIn.sceneID = $0 })) {
                Text("Lights as they were").tag(String?.none)
                ForEach(room.moods) { Text($0.id).tag(Optional($0.id)) }
              }
              .pickerStyle(.menu)
            }
            .frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 8) {
              Text("Counts as coming home after being gone")
              Picker("Away for at least", selection: Binding(get: { walkIn.awayMinutes }, set: { walkIn.awayMinutes = $0 })) {
                ForEach(WalkIn.awayChoices, id: \.self) { Text("\($0) min").tag($0) }
              }
              .pickerStyle(.segmented)
              Text("Shorter catches quick trips; longer ignores stepping out to the bathroom.")
                .font(.footnote)
                .foregroundStyle(Ink.dim)
            }
          }

          spotSection(walkIn)
          locationSection(walkIn)

          Toggle(isOn: Binding(get: { walkIn.offWhenLeaving }, set: { walkIn.offWhenLeaving = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Turn everything off when I leave").font(.body.weight(.semibold))
              Text("Strips and bulb go off together.")
                .font(.footnote)
                .foregroundStyle(Ink.dim)
            }
          }
          .frame(minHeight: 44)
          if walkIn.offWhenLeaving { leaveSection(walkIn) }

          Button { walkIn.tryNow() } label: {
            Label("Try it now", systemImage: "play.fill")
              .font(.body.weight(.semibold))
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(Capsule().fill(Ink.raised))
          }
          .buttonStyle(Press())
        }
        .disabled(!walkIn.enabled)
        .opacity(walkIn.enabled ? 1 : 0.5)

        if !walkIn.events.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            Text("Recent activity").font(.headline)
            ForEach(walkIn.events) { event in
              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(event.time, format: .dateTime.weekday(.abbreviated).hour().minute())
                  .font(.footnote.monospacedDigit())
                  .foregroundStyle(Ink.dim)
                  .frame(width: 92, alignment: .leading)
                Text(event.text).font(.footnote).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }

        Text("It follows your phone, so a roommate coming in won't trigger it. Keep Bluetooth on. Swiping Dorm Remote away stops iOS from waking it for Bluetooth; the location backup is the way around that.")
          .font(.footnote)
          .foregroundStyle(Ink.dim)
    }
    .sensoryFeedback(.success, trigger: walkIn.spot)
  }

  /// What each sensor sees right now, so you can tell why it did or didn't light up.
  private func sensors(_ walkIn: WalkIn) -> some View {
    let strips = room.strip.strips
    let connected = strips.filter { $0.state == .connected }.count
    return VStack(alignment: .leading, spacing: 12) {
      sensor("light.strip.2", "Strips",
             strips.isEmpty ? "None added" : connected == 0 ? "Out of range" : "\(connected) of \(strips.count) in range",
             good: connected > 0)
      sensor("sensor.tag.radiowaves.forward", "Room beacon",
             !walkIn.useLocation ? "Turn on Use location"
               : !walkIn.locationAlways ? "Needs location set to Always"
               : walkIn.nearBeacon == true ? (walkIn.beaconRSSI.map { "In range (\($0) dBm)" } ?? "In range")
               : walkIn.nearBeacon == false ? "Out of range" : "Not seen yet. Plug in the IR bridge (firmware from Oct 29 or later)",
             good: walkIn.nearBeacon == true)
      sensor("av.remote", "IR bridge",
             room.bridge.state == .ready ? (walkIn.doorSpot != nil || walkIn.leaveSpot != nil ? "Watching your spots" : "Connected") : "Not connected",
             good: room.bridge.state == .ready)
      sensor("mappin.circle", "Area around home",
             !walkIn.useLocation ? "Off" : !walkIn.locationAlways ? "Needs location set to Always" : walkIn.home == nil ? "Not set" : "Set (150 m)",
             good: walkIn.useLocation && walkIn.locationAlways && walkIn.home != nil)
      if walkIn.useLocation, !walkIn.locationAlways {
        Button {
          if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } label: {
          Text("Open Settings → Location → Always")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(Ink.raised))
        }
        .buttonStyle(Press())
      }
    }
    .padding(16)
    .card()
  }

  private func sensor(_ icon: String, _ name: String, _ state: String, good: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).frame(width: 28).foregroundStyle(good ? Ink.text : Ink.dim)
      Text(name).font(.subheadline.weight(.semibold))
      Spacer()
      Text(state).font(.footnote).foregroundStyle(Ink.dim).multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }

  /// Walk out's spot: where on the way out everything turns off.
  private func leaveSection(_ walkIn: WalkIn) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Leaving spot").font(.headline)
      Text(walkIn.leaveSpot == nil
           ? "Not set: the lights go off when iOS notices you've left your room, about 30 s later, and the strips only if they're still in range then. Walk out to where you want them off (outside your door, or down the hall while your IR bridge still reaches you) and tap Set leaving spot."
           : "Set (\(walkIn.leaveSpot!) dBm). Your IR bridge watches your phone's signal; when you pass this spot it wakes Dorm Remote and everything goes off together.")
        .font(.subheadline)
        .foregroundStyle(Ink.dim)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        Button { walkIn.setLeaveSpot() } label: {
          HStack(spacing: 8) {
            if walkIn.measuringLeave { ProgressView() }
            Text(walkIn.measuringLeave ? "Measuring…" : walkIn.leaveSpot == nil ? "Set leaving spot" : "Set it again")
          }
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 52)
          .background(Capsule().fill(Ink.raised))
        }
        .buttonStyle(Press())
        .disabled(walkIn.measuringLeave)
        if walkIn.leaveSpot != nil {
          Button("Clear") { walkIn.clearLeaveSpot() }
            .frame(minWidth: 64, minHeight: 52)
        }
      }
      if let error = walkIn.leaveError {
        Text(error).font(.footnote).foregroundStyle(Ink.bad).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func spotSection(_ walkIn: WalkIn) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Your spot").font(.headline)
      Text(walkIn.spot == nil
           ? "Not set: the lights come on as soon as you're back in range, which is about your hallway. Stand right outside your door and tap Set my spot to make them wait until you're there."
           : walkIn.beaconSpot != nil
             ? "Set with the beacon (\(walkIn.beaconSpot!) dBm): the lights wait until you're about as close to your room as where you stood."
             : "Set with your strips: the lights wait until you're about as close as where you stood. Turn on Use location first to set it with the beacon, which is more exact.")
        .font(.subheadline)
        .foregroundStyle(Ink.dim)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 12) {
        Button { walkIn.setSpot() } label: {
          HStack(spacing: 8) {
            if walkIn.measuring { ProgressView().tint(Ink.inverse) }
            Text(walkIn.measuring ? "Measuring…" : walkIn.spot == nil ? "Set my spot" : "Set it again")
          }
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 52)
          .foregroundStyle(Ink.inverse)
          .background(Capsule().fill(Ink.text))
        }
        .buttonStyle(Press())
        .disabled(walkIn.measuring)
        if walkIn.spot != nil {
          Button("Clear") { walkIn.clearSpot() }
            .frame(minWidth: 64, minHeight: 52)
        }
      }
      if let error = walkIn.spotError {
        Text(error).font(.footnote).foregroundStyle(Ink.bad)
      }
    }
  }

  private func locationSection(_ walkIn: WalkIn) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(isOn: Binding(get: { walkIn.useLocation }, set: { walkIn.useLocation = $0 })) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Use location (recommended)").font(.body.weight(.semibold))
          Text("Lets iOS wake Dorm Remote as you come in, even if you swiped it away: from your IR bridge's beacon right at your room, and from a circle around your building. Needs location set to Always.")
            .font(.footnote)
            .foregroundStyle(Ink.dim)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(minHeight: 44)
      if walkIn.useLocation {
        HStack(spacing: 12) {
          Label(walkIn.home == nil ? "Home not set" : "Home is set", systemImage: walkIn.home == nil ? "mappin.slash" : "mappin.circle.fill")
            .font(.subheadline)
            .foregroundStyle(walkIn.home == nil ? Ink.bad : Ink.text)
          Spacer()
          Button {
            walkIn.setHomeHere()
          } label: {
            HStack(spacing: 8) {
              if walkIn.locating { ProgressView() }
              Text(walkIn.home == nil ? "Set home here" : "Set again here")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Capsule().fill(Ink.raised))
          }
          .buttonStyle(Press())
          .disabled(walkIn.locating)
        }
        Text("Do this in your room. It watches a 150 m circle around it, which catches you on the way in before the beacon does.")
          .font(.footnote)
          .foregroundStyle(Ink.dim)
        if let error = walkIn.locationError {
          Text(error).font(.footnote).foregroundStyle(Ink.bad).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

/// Recipes for the Shortcuts actions in Intents.swift. iOS runs automations even with the app closed, which is
/// how schedules work here: an app can't keep its own timers running in the background.
private struct ScheduleSection: View {
  @Environment(\.openURL) private var openURL

  static let recipes: [(icon: String, title: String, how: String)] = [
    ("sunrise", "Wake up to light", "Automation → Alarm → Is Stopped → Run Immediately → Dorm Remote: Set scene → Sunrise."),
    ("moon.zzz", "Fade out at bedtime", "Automation → Sleep (Focus) → Turns On → Run Immediately → Dorm Remote: Fade lights out."),
    ("clock", "Lights on at a set time", "Automation → Time of Day → pick a time → Run Immediately → Dorm Remote: Set scene."),
    ("button.horizontal.top.press", "Action Button", "Settings → Action Button → Shortcut → Dorm Remote: Toggle lights."),
    ("switch.2", "Control Center", "Open Control Center → + → Add a Control → Shortcuts → Dorm Remote: Toggle lights."),
    ("mic", "Siri", "Say \"Toggle Dorm Remote\", \"Goodnight Dorm Remote\", or \"Set Dorm Remote scene\"."),
  ]

  var body: some View {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Set these up once in the Shortcuts app. They run on their own, even when Dorm Remote is closed.")
            .foregroundStyle(Ink.dim)
        }
        ForEach(Self.recipes, id: \.title) { r in
          HStack(alignment: .top, spacing: 16) {
            Image(systemName: r.icon)
              .frame(width: 44, height: 44)
              .background(Circle().fill(Ink.raised))
            VStack(alignment: .leading, spacing: 4) {
              Text(r.title).font(.body.weight(.semibold))
              Text(r.how).font(.footnote).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        Button {
          if let url = URL(string: "shortcuts://") { openURL(url) }
        } label: {
          Text("Open Shortcuts")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(Ink.inverse)
            .background(Capsule().fill(Ink.text))
        }
        .buttonStyle(Press())
      }
  }
}

/// The Automations tab: whether you're home, what happens when you arrive, and what runs on a schedule. Each one is a
/// compact row; the details are one tap deeper.
private struct AutomationsTab: View {
  var room: Room

  var body: some View {
    let walkIn = room.walkIn
    NavigationStack {
      List {
      Group {
        if walkIn.enabled {
          Section {
            HStack(spacing: 16) {
              Image(systemName: walkIn.isAway ? "figure.walk.departure" : "house.fill")
                .font(.title2)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Ink.raised))
              VStack(alignment: .leading, spacing: 2) {
                Text(walkIn.isAway ? "Away" : "You're home").font(.title3.weight(.semibold))
                Text(presenceDetail(walkIn)).font(.subheadline).foregroundStyle(Ink.dim)
              }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
          }
        }

        Section {
          Toggle(isOn: Binding(get: { walkIn.enabled }, set: { walkIn.enabled = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Walk in")
              Text("Lights up when you come back").font(.footnote).foregroundStyle(Ink.dim)
            }
          }
          if walkIn.enabled {
            NavigationLink {
              page("Walk in") { WalkInSection(room: room) }
            } label: {
              LabeledContent("Turns on") {
                Text("\(walkIn.sceneID ?? "Lights as they were") · \(walkIn.awayMinutes) min away")
              }
            }
          }
        } header: { SectionTitle("When you arrive") }

        Section {
          ForEach(ScheduleSection.recipes, id: \.title) { r in
            NavigationLink {
              page(r.title) { RecipePage(icon: r.icon, title: r.title, how: r.how) }
            } label: {
              Label(r.title, systemImage: r.icon)
            }
          }
        } header: { SectionTitle("Schedules") } footer: {
          Text("Set up once in the Shortcuts app. They run on their own, even when Dorm Remote is closed.")
        }
      }
      .listRowBackground(Ink.card)
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(RoomGlow(room: room))
      .foregroundStyle(Ink.text)
      .tint(Ink.text)
      .navigationTitle("Automations")
      .animation(Motion.state, value: walkIn.enabled)
    }
  }

  private func presenceDetail(_ walkIn: WalkIn) -> String {
    if walkIn.isAway, let since = walkIn.awayDate { return "Since \(since.formatted(date: .omitted, time: .shortened))" }
    if let back = walkIn.lastArrival { return "Back since \(back.formatted(date: .omitted, time: .shortened))" }
    return "Walk in is watching for you"
  }

  private func page<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    ScrollView {
      content()
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    .scrollIndicators(.hidden)
    .background(RoomGlow(room: room))
    .foregroundStyle(Ink.text)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// One Shortcuts recipe: what it does and the steps to set it up.
private struct RecipePage: View {
  let icon: String
  let title: String
  let how: String
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      Image(systemName: icon)
        .font(.title)
        .frame(width: 64, height: 64)
        .background(Circle().fill(Ink.raised))
      VStack(alignment: .leading, spacing: 8) {
        SectionTitle("How to set it up")
        Text(how).fixedSize(horizontal: false, vertical: true)
      }
      Button {
        if let url = URL(string: "shortcuts://") { openURL(url) }
      } label: {
        Text("Open Shortcuts")
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 52)
          .foregroundStyle(Ink.inverse)
          .background(Capsule().fill(Ink.text))
      }
      .buttonStyle(Press())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// "Find my lights": you pick the order, each light blinks in turn, you aim the circle at it, and it lands on the map.
private struct ScanSheet: View {
  var room: Room
  @State private var scanner = LightScanner()
  /// The order you tapped the lights in.
  @State private var picked: [String] = []
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Find my lights").font(.system(.title, design: .rounded, weight: .bold))
        switch scanner.phase {
        case .unsupported:
          Text("This iPhone can't track motion for scanning. Drag your lights into place on the map instead.")
            .foregroundStyle(Ink.dim)
        case .ready:
          intro
        case .preparing, .aiming, .secondAim:
          aiming
        case .done:
          results
        }
      }
      .padding(24)
    }
    .onDisappear { scanner.cancel() }
    .sensoryFeedback(.success, trigger: scanner.results.count)
    .sensoryFeedback(.impact(weight: .medium), trigger: scanner.phase)
  }

  private var intro: some View {
    let lights = room.scanTargets()
    return VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 10) {
        step(1, "Stand or sit where you usually are. That spot becomes the middle of the map.")
        step(2, "Each light blinks in turn. Aim the circle at it, or at the glow it throws on the wall.")
        step(3, scanner.oneAim
             ? "It locks on by itself when it sees the blink. If it doesn't, tap It's here."
             : "It locks on by itself, then asks you to take a big step sideways and aim again. Two aims tell it how far away the light is.")
      }
      .foregroundStyle(Ink.dim)
      if lights.isEmpty {
        Text("No connected lights in \(room.currentRoom).").font(.footnote).foregroundStyle(Ink.bad)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Order").font(.headline)
          Text("Tap the lights in the order you want to find them. Lights you don't tap go last.")
            .font(.footnote)
            .foregroundStyle(Ink.dim)
          ForEach(lights) { light in
            let n = picked.firstIndex(of: light.id).map { $0 + 1 }
            Button {
              if let i = picked.firstIndex(of: light.id) { picked.remove(at: i) } else { picked.append(light.id) }
            } label: {
              HStack(spacing: 12) {
                Text(n.map(String.init) ?? "")
                  .font(.subheadline.weight(.bold).monospacedDigit())
                  .frame(width: 28, height: 28)
                  .foregroundStyle(n == nil ? Ink.dim : Ink.inverse)
                  .background(Circle().fill(n == nil ? Ink.raised : Ink.text))
                Orb(item: light, color: room.live[light.id], size: 32)
                Text(light.name).font(.body.weight(.semibold))
                Spacer()
                if room.placements[light.id]?.found == true {
                  Text("On the map").font(.footnote).foregroundStyle(Ink.dim)
                }
              }
              .padding(.horizontal, 12)
              .frame(minHeight: 52)
              .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.raised.opacity(0.6)))
            }
            .buttonStyle(Press())
            .accessibilityLabel(n.map { "\(light.name), number \($0)" } ?? light.name)
          }
        }
        .sensoryFeedback(.selection, trigger: picked)
      }
      wide("Start") { scanner.start(room: room, order: picked) }
        .disabled(lights.isEmpty)
    }
  }

  private var aiming: some View {
    VStack(alignment: .leading, spacing: 16) {
      ZStack {
        CameraView(session: scanner.session)
          .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        // The circle the app watches: a fifth of the width, same as LightScanner.measure.
        GeometryReader { geo in
          let d = geo.size.width / 5
          ZStack {
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 2)
            Circle()
              .trim(from: 0, to: scanner.lock)
              .stroke(Ink.text, style: StrokeStyle(lineWidth: 5, lineCap: .round))
              .rotationEffect(.degrees(-90))
              .animation(Motion.state, value: scanner.lock)
          }
          .frame(width: d, height: d)
          .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
      }
      .frame(height: 380)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text(headline).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        if let hint = scanner.hint {
          Text(hint).font(.footnote).foregroundStyle(Ink.bad)
        }
      }

      if scanner.phase != .preparing {
        HStack(spacing: 12) {
          wide("It's here") { scanner.capture() }
          Button("Skip") { scanner.skip() }
            .font(.body.weight(.semibold))
            .frame(minWidth: 72, minHeight: 52)
        }
        // Jump to any light, in any order.
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(scanner.order, id: \.self) { id in
              let done = scanner.results[id] != nil
              Button { scanner.pick(id) } label: {
                HStack(spacing: 6) {
                  if done { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                  Text(scanner.names[id] ?? "Light").font(.footnote.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(scanner.current == id ? Ink.inverse : Ink.text)
                .background(Capsule().fill(scanner.current == id ? Ink.text : Ink.raised))
              }
              .buttonStyle(Press())
            }
          }
        }
        .scrollIndicators(.hidden)
      }
      HStack {
        Button("Cancel") {
          scanner.cancel()
          dismiss()
        }
        Spacer()
        if !scanner.results.isEmpty {
          Button("Done") { scanner.finish() }.font(.body.weight(.semibold))
        }
      }
      .frame(minHeight: 44)
    }
  }

  private var headline: String {
    switch scanner.phase {
    case .preparing: "Getting the lights ready…"
    case .secondAim: "Now step aside"
    default: "Aim at \(scanner.currentName)"
    }
  }

  private var detail: String {
    switch scanner.phase {
    case .preparing:
      return "They flash white, then go dark. Hold the phone up like you're taking a photo."
    case .secondAim:
      let moved = scanner.stepAside
      return moved < 0.4
        ? "Take a big step to the side (about half a meter), then aim at \(scanner.currentName) again."
        : "Good. Aim at \(scanner.currentName) again until the ring fills."
    default:
      return "It's blinking. Put it in the circle, or the patch of wall it lights, and hold still until the ring fills."
    }
  }

  private var results: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(scanner.order, id: \.self) { id in
        HStack {
          Text(scanner.names[id] ?? id)
          Spacer()
          if let r = scanner.results[id] {
            Text(String(format: "%.1f m away", hypot(r.x, r.y))).foregroundStyle(Ink.dim)
          } else {
            Button("Find it") { scanner.pick(id) }
          }
        }
        .font(.subheadline)
        .frame(minHeight: 44)
      }
      Text(scanner.results.count == scanner.order.count
           ? "All found. They're on the map, and scenes now roll across the room in order."
           : "The ones not found can be dragged into place on the map.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
      wide("See the map") { dismiss() }
    }
  }

  private func step(_ n: Int, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(n)").font(.subheadline.weight(.bold)).frame(width: 22, height: 22).background(Circle().fill(Ink.raised))
      Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func wide(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(Ink.inverse)
        .background(Capsule().fill(Ink.text))
    }
    .buttonStyle(Press())
  }
}

/// Live camera for the scan, drawn from the scanner's own ARKit session.
private struct CameraView: UIViewRepresentable {
  let session: ARSession

  func makeUIView(context: Context) -> ARSCNView {
    let view = ARSCNView()
    view.session = session
    view.automaticallyUpdatesLighting = false
    return view
  }

  func updateUIView(_ view: ARSCNView, context: Context) {}
}

/// The Map tab: where your lights are (found by scanning or dragged into place), how changes travel across the room,
/// and keeping the slow bulb in step. One screen, because all three are the same room layout.
/// The room in miniature: each light a point of its own light, you a small white dot, the floor a faint grid. Tap a
/// light to see what it's doing, tap it again for its controls, drag it to where it really is.
private struct MapScreen: View {
  var room: Room
  /// Opens a light's controls (the Room tab's sheet).
  var open: (String) -> Void = { _ in }
  @State private var scanning = false
  /// The map's frame stays put while you drag, so the scale doesn't shift under your finger.
  @State private var frozen: MapFrame?
  /// Bumped to ripple a light's dot (a sweep reaching it).
  @State private var pulse: [String: Int] = [:]
  @State private var selected: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  struct MapFrame: Equatable {
    var minX: Double
    var minY: Double
    var span: Double
  }

  var body: some View {
    let lights = room.inRoom.filter { $0.caps.contains(.power) }
    let placed = lights.filter { room.placements[$0.id] != nil }
    let unplaced = lights.filter { room.placements[$0.id] == nil }
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 32) {
          if lights.isEmpty {
            ContentUnavailableView("No lights in \(room.currentRoom)", systemImage: "map",
                                   description: Text("Add a light on the Room tab, then place it here."))
          } else if placed.isEmpty {
            emptyMap
            if !unplaced.isEmpty { tray(unplaced) }
          } else {
            VStack(alignment: .leading, spacing: 12) {
              map(placed)
              Text(selected == nil ? "Tap a light to see it. Drag to move it." : "Tap it again for its controls.")
                .font(.footnote)
                .foregroundStyle(Ink.dim)
                .padding(.horizontal, 4)
                .contentTransition(.opacity)
            }
            if !unplaced.isEmpty { tray(unplaced) }
            sweepSection(lights)
            syncSection(lights)
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .animation(Motion.state, value: selected)
      }
      .scrollIndicators(.hidden)
      .background(RoomGlow(room: room))
      .foregroundStyle(Ink.text)
      .navigationTitle(room.currentRoom)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Menu {
            Picker("Room", selection: Binding(get: { room.currentRoom }, set: { room.selectedRoom = $0; selected = nil })) {
              ForEach(room.rooms, id: \.self) { Text($0).tag($0) }
            }
          } label: {
            RoomTitle(name: room.currentRoom)
          }
          .accessibilityLabel("Room")
          .accessibilityValue(room.currentRoom)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button { scanning = true } label: { Image(systemName: "viewfinder") }
            .disabled(room.scanTargets().isEmpty)
            .accessibilityLabel("Find lights with the camera")
        }
      }
      .sheet(isPresented: $scanning) { ScanSheet(room: room).panel() }
    }
  }

  private var emptyMap: some View {
    VStack(spacing: 12) {
      Image(systemName: "viewfinder").font(.largeTitle).foregroundStyle(Ink.dim)
      Text("Put your lights on the map").font(.headline)
      Text("Your camera finds each light while it blinks. Then scenes can roll across the room in order.")
        .font(.subheadline)
        .foregroundStyle(Ink.dim)
        .multilineTextAlignment(.center)
      Button { scanning = true } label: {
        Text("Find my lights")
          .font(.body.weight(.semibold))
          .padding(.horizontal, 24)
          .frame(minHeight: 48)
          .foregroundStyle(Ink.inverse)
          .background(Capsule().fill(Ink.text))
      }
      .buttonStyle(Press())
      .disabled(room.scanTargets().isEmpty)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(32)
    .card(radius: Radius.feature)
  }

  /// Fits every placed light and you, with at least 3 m across and a margin, centered.
  private func frame(_ placed: [LightItem]) -> MapFrame {
    let points = placed.compactMap { room.placements[$0.id] }.map { (x: $0.x, y: $0.y) } + [(x: Double(room.you.x), y: Double(room.you.y))]
    let xs = points.map(\.x), ys = points.map(\.y)
    let loX = xs.min() ?? 0, hiX = xs.max() ?? 0, loY = ys.min() ?? 0, hiY = ys.max() ?? 0
    let span = max(3, hiX - loX, hiY - loY) + 1.5
    return MapFrame(minX: (loX + hiX) / 2 - span / 2, minY: (loY + hiY) / 2 - span / 2, span: span)
  }

  private func map(_ placed: [LightItem]) -> some View {
    let f = frozen ?? frame(placed)
    let shape = RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
    return GeometryReader { geo in
      let side = geo.size.width
      let scale = side / f.span
      let toView = { (x: Double, y: Double) in CGPoint(x: (x - f.minX) * scale, y: (y - f.minY) * scale) }
      let toMap = { (p: CGPoint) -> (Double, Double) in
        (min(f.minX + f.span, max(f.minX, Double(p.x) / scale + f.minX)), min(f.minY + f.span, max(f.minY, Double(p.y) / scale + f.minY)))
      }
      ZStack {
        shape.fill(Ink.card)
          .contentShape(shape)
          .onTapGesture { selected = nil }
        // The floor: a dot every metre, barely there.
        Canvas { ctx, size in
          var x = ceil(f.minX)
          while x < f.minX + f.span {
            var y = ceil(f.minY)
            while y < f.minY + f.span {
              let p = CGPoint(x: (x - f.minX) * scale, y: (y - f.minY) * scale)
              ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(Ink.line))
              y += 1
            }
            x += 1
          }
        }
        .allowsHitTesting(false)

        you
          .position(toView(Double(room.you.x), Double(room.you.y)))
          .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("map"))
            .onChanged { g in
              if frozen == nil { frozen = f }
              let m = toMap(g.location)
              room.setYou(x: m.0, y: m.1)
            }
            .onEnded { _ in frozen = nil })

        ForEach(placed) { light in
          if let p = room.placements[light.id] {
            node(light)
              .position(toView(p.x, p.y))
              .onTapGesture {
                if selected == light.id { open(light.id) } else { selected = light.id }
              }
              .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("map"))
                .onChanged { g in
                  if frozen == nil { frozen = f }
                  selected = light.id
                  let m = toMap(g.location)
                  room.setPlacement(light.id, x: m.0, y: m.1)
                }
                .onEnded { _ in frozen = nil })
              .contextMenu {
                Button("Controls", systemImage: "slider.horizontal.3") { open(light.id) }
                Button("Blink", systemImage: "light.max") { room.identify(light.id) }
              }
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(light.name)
              .accessibilityValue(plainState(light, in: room))
              .accessibilityHint("Double tap for its controls. Drag to where it sits in your room.")
              .accessibilityAction { open(light.id) }
              .accessibilityAction(named: "Blink") { room.identify(light.id) }
          }
        }
      }
      .clipShape(shape)
      .coordinateSpace(name: "map")
      .frame(width: side, height: side)
    }
    .aspectRatio(1, contentMode: .fit)
    .sensoryFeedback(.selection, trigger: frozen == nil)
    .sensoryFeedback(.selection, trigger: selected)
  }

  private var you: some View {
    VStack(spacing: 6) {
      Circle()
        .fill(Ink.text)
        .frame(width: 10, height: 10)
        .padding(9)
        .background(Circle().fill(Ink.text.opacity(0.1)))
      Text("You").font(.caption2).foregroundStyle(Ink.dim)
    }
    .padding(8)
    .contentShape(Rectangle())
    .accessibilityLabel("You")
    .accessibilityHint("Drag to where you usually sit")
  }

  /// A light as a point of its own light: a soft halo in its color when it's on, a quiet ring when it's off. The
  /// selected one grows a little and shows its name and state.
  private func node(_ light: LightItem) -> some View {
    let lit = light.status == .ready && light.on
    let c = room.shown(light).color
    let isSelected = selected == light.id
    return VStack(spacing: 6) {
      ZStack {
        if lit {
          Circle()
            .fill(RadialGradient(colors: [c.opacity(0.45), c.opacity(0)], center: .center, startRadius: 0, endRadius: 34))
            .frame(width: 68, height: 68)
        }
        // A ripple when a sweep reaches it.
        Circle()
          .stroke(lit ? c : Ink.text, lineWidth: 2)
          .frame(width: 22, height: 22)
          .keyframeAnimator(initialValue: 0.0, trigger: pulse[light.id] ?? 0) { view, t in
            view.scaleEffect(1 + t * 2).opacity(t == 0 || t == 1 ? 0 : 1 - t)
          } keyframes: { _ in
            LinearKeyframe(1.0, duration: reduceMotion ? 0.01 : 0.8)
          }
        Circle()
          .fill(lit ? c : Ink.raised)
          .overlay(Circle().strokeBorder(lit ? Color.white.opacity(0.5) : Ink.line, lineWidth: isSelected ? 2 : 1))
          .frame(width: isSelected ? 20 : 14, height: isSelected ? 20 : 14)
          .animation(Motion.frame, value: room.shown(light))
      }
      .frame(width: 68, height: 68)
      VStack(spacing: 2) {
        Text(light.name)
          .font(.caption.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? Ink.text : Ink.dim)
        if isSelected {
          Text(plainState(light, in: room)).font(.caption2).foregroundStyle(Ink.dim)
        }
      }
      .lineLimit(1)
      .fixedSize()
      .offset(y: -18)
    }
    .animation(Motion.tap, value: isSelected)
    .contentShape(Rectangle())
  }

  /// Lights not on the map yet: tap to drop one next to you, then drag it into place.
  private func tray(_ unplaced: [LightItem]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle("Not on the map")
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(Array(unplaced.enumerated()), id: \.element.id) { i, light in
            Button {
              room.setPlacement(light.id, x: Double(room.you.x) + Double(i % 3 - 1), y: Double(room.you.y) - 1)
            } label: {
              Label(light.name, systemImage: "plus")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.raised))
            }
            .buttonStyle(Press())
            .accessibilityHint("Puts it next to you; then drag it into place")
          }
        }
      }
      .scrollIndicators(.hidden)
    }
  }

  private func sweepSection(_ lights: [LightItem]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionTitle("How scenes travel")
        Spacer()
        Button {
          let schedule = room.testSweep()
          for light in lights {
            DispatchQueue.main.asyncAfter(deadline: .now() + (schedule[light.id] ?? 0)) { pulse[light.id, default: 0] += 1 }
          }
        } label: {
          Label("Try it", systemImage: "play.fill").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
        .buttonStyle(Press())
      }
      ScrollView(.horizontal) {
        HStack(spacing: 20) {
          ForEach(Room.SweepStyle.allCases, id: \.self) { style in
            let on = room.sweepStyle == style
            Button { withAnimation(Motion.tap) { room.sweepStyle = style } } label: {
              Text(style.rawValue)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Ink.text : Ink.dim)
                .frame(minHeight: 44)
            }
            .buttonStyle(Press())
            .accessibilityAddTraits(on ? .isSelected : [])
          }
        }
      }
      .scrollIndicators(.hidden)
      .sensoryFeedback(.selection, trigger: room.sweepStyle)
      Text("A new scene rolls across the room this way, each light on its turn.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
    }
  }

  /// Folded away: most people set it once, if ever.
  private func syncSection(_ lights: [LightItem]) -> some View {
    DisclosureGroup {
      syncTools(lights).padding(.top, 12)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("Keep lights in sync").font(.body.weight(.medium)).foregroundStyle(Ink.text)
        Text("If one light changes late").font(.footnote).foregroundStyle(Ink.dim)
      }
    }
    .tint(Ink.dim)
  }

  private func syncTools(_ lights: [LightItem]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Flash them and watch: everything should come back at the same moment. If a light comes back late, slide it right so it's sent earlier; early, slide it left.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
        .fixedSize(horizontal: false, vertical: true)
      Button { room.flashTogether() } label: {
        Label("Flash all together", systemImage: "bolt.fill").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
      }
      .buttonStyle(Press())
      ForEach(lights) { light in
        let nudge = room.syncNudge[light.id] ?? 0
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(light.name).font(.subheadline.weight(.medium))
            Spacer()
            Text(nudge == 0 ? "Auto" : String(format: "%+.1f s", nudge))
              .font(.footnote.monospacedDigit())
              .foregroundStyle(Ink.dim)
          }
          // -1 s to +2 s, and a double tap goes back to auto.
          PillSlider(value: Binding(get: { (nudge + 1) / 3 }, set: { room.setNudge(light.id, (($0 * 3 - 1) * 10).rounded() / 10) }),
                     fill: AnyShapeStyle(room.shown(light).color), range: 0...1, label: "\(light.name) timing", showsPercent: false)
            .frame(height: 28)
            .onTapGesture(count: 2) { room.setNudge(light.id, 0) }
        }
      }
    }
  }
}

/// Remote for any infrared device, laid out from its template. Buttons without a known code are learned
/// from the device's own remote (needs the IR Unit on the bridge).
private struct RemoteSheet: View {
  var room: Room
  let id: String
  @State private var learnMode = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let device = room.irDevice(id) {
          HStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
              .font(.title2)
              .frame(width: 44, height: 44)
              .background(Circle().fill(Ink.raised))
            Text(device.name).font(.system(.title, design: .rounded, weight: .bold)).lineLimit(1)
          }
          if room.bridge.state == .ready {
            remote(device)
          } else {
            setup
          }
        }
      }
      .padding(24)
    }
  }

  private func remote(_ device: IRDevice) -> some View {
    let bridge = room.bridge
    let buttons = BridgeController.buttons(for: device.template)
    let unknown = buttons.filter { $0.command == nil && !bridge.isLearned($0, device: device.id) }
    return VStack(alignment: .leading, spacing: 20) {
      if let key = bridge.learning, let button = buttons.first(where: { BridgeController.key(device.id, $0) == key }) {
        HStack {
          ProgressView()
          Text("Point \(device.name)'s remote at the bridge and press \(button.name).")
            .font(.subheadline)
          Spacer()
          Button("Cancel") { bridge.cancelLearning() }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.raised))
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
        ForEach(buttons) { button in
          let ready = button.command != nil || bridge.isLearned(button, device: device.id)
          Button {
            if learnMode || !ready { bridge.learn(button, device: device.id) } else { bridge.press(button, device: device.id) }
          } label: {
            VStack(spacing: 8) {
              Image(systemName: button.icon).font(.title3).foregroundStyle(button.id == "power" ? Ink.bad : Ink.text)
              Text(button.name).font(.caption.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
              .fill(Ink.raised))
            .opacity(ready || learnMode ? 1 : 0.45)
            .overlay(alignment: .topTrailing) {
              if bridge.isLearned(button, device: device.id) {
                Circle().fill(Ink.text).frame(width: 6, height: 6).padding(8)
              }
            }
          }
          .buttonStyle(Press())
          .accessibilityHint(ready ? "" : "Not learned yet. Tap to learn it from the real remote.")
        }
      }
      Toggle("Re-learn buttons from the real remote", isOn: $learnMode)
        .font(.subheadline)
      Text(unknown.isEmpty
           ? "Tap a dimmed button or turn on re-learning, then press the same button on the real remote. Needs the IR Unit on the bridge. A dot marks learned buttons."
           : "\(unknown.count) buttons aren't learned yet (dimmed). Tap one, then press the same button on the real remote. Needs the IR Unit on the bridge.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
      Button("Forget learned buttons", role: .destructive) { bridge.forgetLearned(device: device.id) }
        .font(.subheadline)
    }
  }

  private var setup: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("iPhones have no IR blaster, so infrared devices go through a DormBridge: an M5Stack ATOM Lite (about $8) or ATOM Echo flashed with the DormBridge firmware, on any USB charger, pointed at the device. Add the M5Stack IR Unit (about $4) to learn buttons from any remote.")
        .foregroundStyle(Ink.dim)
      HStack(spacing: 12) {
        ProgressView()
        Text(room.bridge.state == .off ? "Turn on Bluetooth." : "Looking for a DormBridge…").foregroundStyle(Ink.dim)
      }
    }
  }
}

/// Adds any remote-controlled device. The template only sets the starting buttons.
private struct AddRemoteSheet: View {
  var room: Room
  @State private var name = ""
  @State private var template = BridgeController.templates[0].name
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Add a remote-controlled device").font(.system(.title, design: .rounded, weight: .bold))
          Text("Anything with an infrared remote. It's added to \(room.currentRoom).").foregroundStyle(Ink.dim)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Name").font(.subheadline).foregroundStyle(Ink.dim)
          TextField("", text: $name, prompt: Text("e.g. Galaxy projector, Fan"))
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Ink.raised, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Buttons").font(.subheadline).foregroundStyle(Ink.dim)
          ForEach(BridgeController.templates, id: \.name) { t in
            Button { template = t.name } label: {
              HStack {
                Text(t.name)
                Spacer()
                if template == t.name { Image(systemName: "checkmark") }
              }
              .padding(.horizontal, 16)
              .frame(minHeight: 48)
              .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(template == t.name ? Ink.raised : Ink.raised.opacity(0.4)))
            }
            .buttonStyle(Press())
          }
        }
        Button {
          room.addIRDevice(name: name, template: template)
          dismiss()
        } label: {
          Text("Add")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(Ink.inverse)
            .background(Capsule().fill(Ink.text))
        }
        .buttonStyle(Press())
      }
      .padding(24)
    }
  }
}

private struct LogView: View {
  let lines: [String]

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(lines.joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
      .navigationTitle("Log")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          ShareLink(item: lines.joined(separator: "\n"))
        }
      }
    }
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }

  /// A color with light and dark values, each with an optional Increase Contrast variant.
  init(dark: UInt32, light: UInt32, darkContrast: UInt32? = nil, lightContrast: UInt32? = nil) {
    self.init(UIColor { t in
      let high = t.accessibilityContrast == .high
      let hex = t.userInterfaceStyle == .dark ? (high ? darkContrast ?? dark : dark) : (high ? lightContrast ?? light : light)
      return UIColor(Color(hex: hex))
    })
  }
}
