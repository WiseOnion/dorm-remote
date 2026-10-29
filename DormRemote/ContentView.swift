import ARKit
import PhotosUI
import SwiftUI
import UIKit

// Design, "night room": a near-black canvas, gray cards with a hairline edge, and white for anything you press.
// The lights are the only color: their dots, sliders and a soft glow behind every tab.
// Layout follows the Hubspace light screen (mode circles, brightness bar, presets, wheel)
// with DayBetter's patterns and music on top.
// Each gray has an Increase Contrast variant, as Apple's HIG (Color) asks of custom colors: edges, fills and secondary
// text get clearly brighter when that setting is on.
private enum Ink {
  static let bg = Color(hex: 0x07070B)
  static let card = Color(hex: 0x121218)
  static let raised = Color(hex: 0x1F1F27, contrast: 0x2E2E3A)
  /// Card edge: light enough to separate a card from the canvas, quiet enough to disappear.
  static let line = Color(UIColor { $0.accessibilityContrast == .high ? UIColor(white: 1, alpha: 0.24) : UIColor(white: 1, alpha: 0.07) })
  static let text = Color(hex: 0xF5F5F7)
  /// Secondary text: 7.3:1 on cards, 6.4:1 on raised fills (WCAG AA needs 4.5).
  static let dim = Color(hex: 0xA1A1AA, contrast: 0xD4D4D8)
  static let bad = Color(hex: 0xFF6B5E, contrast: 0xFF8A80)
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
/// tabs keeps the same room around you.
private struct RoomGlow: View {
  var room: Room

  var body: some View {
    ZStack {
      Ink.bg
      if let ambient = room.ambient {
        RadialGradient(colors: [ambient.opacity(0.22), ambient.opacity(0.05), .clear], center: .top, startRadius: 0, endRadius: 560)
      }
    }
    .ignoresSafeArea()
    .animation(Motion.mood, value: room.ambient)
  }
}

extension View {
  /// Every sheet looks the same: dark card, rounded, with a grabber.
  fileprivate func panel() -> some View {
    presentationDragIndicator(.visible)
      .presentationBackground(Ink.card)
      .presentationCornerRadius(32)
      .preferredColorScheme(.dark)
  }
}

/// A card: the base surface for rows and panels. `tint` washes it with a light's color while it's on.
private struct Card: ViewModifier {
  var tint: Color?
  var radius: CGFloat = 24

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content.background(
      shape.fill(Ink.card)
        .overlay(shape.strokeBorder(tint.map { $0.opacity(0.28) } ?? Ink.line, lineWidth: 1))
    )
  }
}

extension View {
  fileprivate func card(tint: Color? = nil, radius: CGFloat = 24) -> some View { modifier(Card(tint: tint, radius: radius)) }
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
  /// The scene group on show; nil opens on the first one (Favorites if you have some).
  @SceneStorage("sceneGroup") private var sceneGroup: String?
  @Namespace private var tabs

  private enum RoomEdit: Equatable { case add, rename(String) }

  /// Four tabs, after Hue's (Home, Automations, …, Settings): what you use every day first, then the room's layout,
  /// what runs by itself, and setup you do once. Each tab has a native large title that shrinks as you scroll
  /// (Apple's HIG suggests it for the top level of a tabbed app) and keeps its actions in the toolbar.
  var body: some View {
    presenting(TabView {
      NavigationStack {
        roomTab
          .navigationTitle(room.currentRoom)
          .toolbar { roomToolbar }
      }
      .tabItem { Label("Room", systemImage: "lightbulb.2.fill") }
      MapScreen(room: room)
        .tabItem { Label("Map", systemImage: "map.fill") }
      AutomationsTab(room: room)
        .tabItem { Label("Automations", systemImage: "clock.arrow.2.circlepath") }
      settingsTab
        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
    }
    .tint(Ink.text)
    .preferredColorScheme(.dark))
  }

  @ToolbarContentBuilder
  private var roomToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      Menu {
        Section("Fade out and turn off in") {
          ForEach([15, 30, 60], id: \.self) { m in
            Button("\(m) minutes") { room.sleep(in: m) }
          }
        }
      } label: {
        Image(systemName: "moon.zzz").font(.body.weight(.semibold))
      }
      .disabled(!room.anyOn)
      .accessibilityLabel("Sleep timer")
      Button { sheet = .light(Room.all) } label: {
        Image(systemName: "slider.horizontal.3").font(.body.weight(.semibold))
      }
      .disabled(room.roomReady.filter { $0.kind != .remote }.isEmpty)
      .accessibilityLabel("Room controls")
      PowerButton(on: room.anyOn) { room.setPower(Room.all, !room.anyOn) }
        .disabled(room.roomReady.isEmpty)
        .contextMenu {
          Button("Turn off every room", systemImage: "power") { room.setPower(Room.everything, false) }
        }
    }
  }

  private var roomTab: some View {
    // A List, so rows get the standard iOS swipe-left-to-delete.
    List {
      Group {
        Text(summary)
          .font(.subheadline)
          .foregroundStyle(Ink.dim)
          .contentTransition(.numericText())
        roomTabs
        nowPlaying
        HStack {
          SectionTitle("Lights")
          Spacer()
          Button { sheet = .add } label: {
            Label("Add", systemImage: "plus").font(.subheadline.weight(.semibold))
          }
          .buttonStyle(Press())
          .frame(minHeight: 44)
        }
        .padding(.top, 8)
        ForEach(room.inRoom) { item in row(item) }
        if room.inRoom.isEmpty {
          VStack(spacing: 16) {
            Image(systemName: "light.strip.2")
              .font(.system(size: 28, weight: .medium))
              .foregroundStyle(Ink.dim)
            VStack(spacing: 4) {
              Text("Nothing in \(room.currentRoom) yet").font(.headline)
              Text("Add a light, or move one here from its settings.")
                .font(.subheadline)
                .foregroundStyle(Ink.dim)
                .multilineTextAlignment(.center)
            }
            Button { sheet = .add } label: {
              Text("Add a light")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 24)
                .frame(minHeight: 48)
                .foregroundStyle(.black)
                .background(Capsule().fill(Ink.text))
            }
            .buttonStyle(Press())
          }
          .frame(maxWidth: .infinity)
          .padding(24)
          .card()
        }
        scenes.padding(.top, 16)
        Color.clear.frame(height: 16)
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
    }
    .listStyle(.plain)
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

  /// Room tabs, like Apple Home. Press and hold a room to rename or delete it.
  private var roomTabs: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(room.rooms, id: \.self) { name in
          let selected = room.currentRoom == name
          Button {
            withAnimation(reduceMotion ? Motion.state : Motion.tap) { room.selectedRoom = name }
          } label: {
            Text(name)
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 16)
              .frame(minHeight: 44)
              .foregroundStyle(selected ? .black : Ink.text)
              .background {
                // The selected pill slides between rooms instead of jumping.
                if selected {
                  Capsule().fill(Ink.text).matchedGeometryEffect(id: "roomTab", in: tabs)
                } else {
                  Capsule().fill(Ink.raised)
                }
              }
          }
          .buttonStyle(Press())
          .accessibilityAddTraits(selected ? .isSelected : [])
          .contextMenu {
            Button("Rename", systemImage: "pencil") {
              roomName = name
              roomEdit = .rename(name)
            }
            if room.rooms.count > 1 {
              Button("Delete room", systemImage: "trash", role: .destructive) { deletingRoom = name }
            }
          }
        }
        Button {
          roomName = ""
          roomEdit = .add
        } label: {
          Image(systemName: "plus")
            .frame(width: 44, height: 44)
            .background(Circle().fill(Ink.raised))
        }
        .buttonStyle(Press())
        .accessibilityLabel("Add room")
      }
    }
    .scrollIndicators(.hidden)
    .sensoryFeedback(.selection, trigger: room.currentRoom)
  }

  /// The effect playing in this room, live: each light's current color, the speed, and Stop. Effects start in a light's
  /// sheet, and without this the home screen didn't show one was running.
  @ViewBuilder
  private var nowPlaying: some View {
    if let effect = room.effectPlaying(on: Room.all) {
      let lights = room.roomReady.filter { room.effectLights.contains($0.id) }
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          ZStack {
            ForEach(Array(lights.prefix(4).enumerated()), id: \.element.id) { i, light in
              Circle()
                .fill(room.shown(light).color)
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Ink.card, lineWidth: 2))
                .offset(x: CGFloat(i) * 14)
                .animation(Motion.frame, value: room.shown(light))
            }
          }
          .frame(width: 28 + CGFloat(max(0, min(4, lights.count) - 1)) * 14, height: 28, alignment: .leading)
          VStack(alignment: .leading, spacing: 2) {
            Text("NOW PLAYING").font(.caption2.weight(.heavy)).tracking(2).foregroundStyle(Ink.dim)
            Text(effect.name).font(.body.weight(.semibold)).lineLimit(1)
          }
          Spacer()
          Button { sheet = .light(Room.all) } label: {
            Image(systemName: "slider.horizontal.3")
              .frame(width: 44, height: 44)
              .background(Circle().fill(Ink.raised))
          }
          .buttonStyle(Press())
          .accessibilityLabel("Change effect")
          Button { room.endEffect() } label: {
            Image(systemName: "stop.fill")
              .frame(width: 44, height: 44)
              .foregroundStyle(.black)
              .background(Circle().fill(Ink.text))
          }
          .buttonStyle(Press())
          .accessibilityLabel("Stop \(effect.name)")
        }
        if effect.hasSpeed {
          HStack(spacing: 12) {
            Image(systemName: "tortoise").foregroundStyle(Ink.dim)
            PillSlider(value: Binding(get: { Double(room.speed - 1) / 99 }, set: { room.setSpeed(1 + Int(($0 * 99).rounded())) }),
                       fill: AnyShapeStyle(LinearGradient(colors: effect.colors.map(\.color), startPoint: .leading, endPoint: .trailing)),
                       label: "Speed", showsPercent: false)
              .frame(height: 32)
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
      .card(tint: lights.first.map { room.shown($0).color })
      .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
      .accessibilityElement(children: .contain)
    }
  }

  private var summary: String {
    let ready = room.roomReady.filter { $0.caps.contains(.power) }
    if ready.isEmpty { return "Tap a light to set it up" }
    let on = ready.filter(\.on).count
    return on == 0 ? "Everything's off" : on == ready.count ? "Everything's on" : "\(on) of \(ready.count) on"
  }

  private var scenes: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        SectionTitle("Scenes")
        Spacer()
        Button { room.living.toggle() } label: {
          Label("Drift", systemImage: room.living ? "wind" : "pause.circle")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .foregroundStyle(room.living ? .black : Ink.text)
            .background(Capsule().fill(room.living ? Ink.text : Ink.raised))
        }
        .buttonStyle(Press())
        .accessibilityLabel("Drift")
        .accessibilityValue(room.living ? "On" : "Off")
        .accessibilityHint("Color scenes drift slowly from light to light")
      }
      // One row at a time, picked with chips: six stacked rows read as clutter (the "feature overload" reviewers
      // hold against Govee's app). Opens on Favorites when there are some.
      let groups = sceneGroups
      let shown = groups.contains(sceneGroup ?? "") ? sceneGroup! : groups[0]
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(groups, id: \.self) { g in
            Button {
              withAnimation(Motion.state) { sceneGroup = g }
            } label: {
              Text(g)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(shown == g ? Ink.text : Ink.dim)
                .background(Capsule().fill(shown == g ? Ink.raised : .clear))
                .overlay(Capsule().strokeBorder(shown == g ? Ink.line : .clear))
            }
            .buttonStyle(Press())
            .accessibilityAddTraits(shown == g ? .isSelected : [])
          }
        }
      }
      .scrollIndicators(.hidden)
      .sensoryFeedback(.selection, trigger: shown)
      sceneRow(moods(in: shown), leading: shown == Mood.Group.mine.rawValue ? AnyView(HStack(alignment: .top, spacing: 16) { makeTile; saveTile; photoTile }) : nil)
        .id(shown)
        .transition(.opacity)
    }
    .disabled(room.roomReady.isEmpty)
    .opacity(room.roomReady.isEmpty ? 0.4 : 1)
    .sensoryFeedback(.selection, trigger: room.mood)
    .alert("Save scene", isPresented: $savingScene) {
      TextField("Name", text: $sceneName)
      Button("Save") { room.saveScene(named: sceneName) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Saves every light in \(room.currentRoom) the way it is now.")
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

  private func sceneRow(_ moods: [Mood], leading: AnyView? = nil) -> some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: 16) {
        if let leading { leading }
        ForEach(moods) { sceneTile($0) }
      }
    }
    .scrollIndicators(.hidden)
  }

  private func sceneTile(_ mood: Mood) -> some View {
    Button { room.apply(mood) } label: {
      VStack(spacing: 8) {
        Circle()
          .fill(AngularGradient(colors: mood.swatch + [mood.swatch[0]], center: .center))
          .frame(width: 60, height: 60)
          .padding(4)
          .overlay(Circle().strokeBorder(Ink.text, lineWidth: room.mood == mood.id ? 2 : 0))
          .animation(Motion.tap, value: room.mood)
          .overlay(alignment: .topTrailing) {
            if room.favorites.contains(mood.id) {
              Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Ink.text)
                .padding(4).background(Circle().fill(Ink.bg))
            }
          }
        Text(mood.id)
          .font(.caption.weight(.medium))
          .foregroundStyle(room.mood == mood.id ? Ink.text : Ink.dim)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .frame(width: 72)
      }
    }
    .buttonStyle(Press())
    .accessibilityLabel("\(mood.id) scene")
    .accessibilityHint("Tap again to shuffle its colors. Press and hold to favorite.")
    .accessibilityAddTraits(room.mood == mood.id ? .isSelected : [])
    .contextMenu {
      let favorite = room.favorites.contains(mood.id)
      Button(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "star.slash" : "star") {
        room.toggleFavorite(mood.id)
      }
      if mood.group == .mine {
        Button("Delete scene", systemImage: "trash", role: .destructive) { room.deleteScene(mood.id) }
      }
    }
  }

  /// The system photo picker needs no photo-library permission: the app only gets the one picture you choose.
  private var photoTile: some View {
    PhotosPicker(selection: $photo, matching: .images) {
      VStack(spacing: 8) {
        Image(systemName: "photo.on.rectangle.angled")
          .font(.title3.weight(.semibold))
          .frame(width: 60, height: 60)
          .background(Circle().strokeBorder(Ink.dim, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
          .padding(4)
        Text("From photo").font(.caption.weight(.medium)).foregroundStyle(Ink.dim).frame(width: 72)
      }
    }
    .buttonStyle(Press())
    .accessibilityLabel("Make a scene from a photo")
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

  /// Your own color combo: purple and orange for Halloween, blues and magentas for every night. The most common
  /// wish in Lotus Lamp and DayBetter reviews.
  private var makeTile: some View {
    Button { sheet = .makeScene } label: {
      VStack(spacing: 8) {
        Image(systemName: "paintpalette")
          .font(.title3.weight(.semibold))
          .frame(width: 60, height: 60)
          .background(Circle().strokeBorder(Ink.dim, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
          .padding(4)
        Text("Pick colors").font(.caption.weight(.medium)).foregroundStyle(Ink.dim).frame(width: 72)
      }
    }
    .buttonStyle(Press())
    .accessibilityLabel("Make a scene from colors you pick")
  }

  private var saveTile: some View {
    Button {
      sceneName = ""
      savingScene = true
    } label: {
      VStack(spacing: 8) {
        Image(systemName: "plus")
          .font(.title3.weight(.semibold))
          .frame(width: 60, height: 60)
          .background(Circle().strokeBorder(Ink.dim, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
          .padding(4)
        Text("Save current").font(.caption.weight(.medium)).foregroundStyle(Ink.dim).frame(width: 72)
      }
    }
    .buttonStyle(Press())
    .accessibilityLabel("Save the room as a scene")
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
          .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.raised))
        Button {
          room.savePalette(colors, named: name.trimmingCharacters(in: .whitespaces).isEmpty ? "My colors" : name)
          dismiss()
        } label: {
          Text("Save and play")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.black)
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
  /// Settings, like Hue's last tab: devices, rooms and accounts. Set up once, then out of the way of the Room tab.
  var settingsTab: some View {
    NavigationStack {
      List {
        Section("Devices") {
          ForEach(room.items) { item in
            Button { open(item) } label: {
              HStack(spacing: 12) {
                Orb(item: item, color: room.live[item.id], size: 36)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.name).foregroundStyle(Ink.text)
                  if case .offline(let why) = item.status {
                    Text(why).font(.footnote).foregroundStyle(Ink.bad)
                  } else {
                    Text(room.roomOf(item)).font(.footnote).foregroundStyle(Ink.dim)
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
                Button { room.identify(item.id) } label: { Label("Blink", systemImage: "light.max") }.tint(Ink.raised)
              }
            }
          }
          Button { sheet = .add } label: { Label("Add a device", systemImage: "plus") }
        }
        .listRowBackground(Ink.card)
        Section("Rooms") {
          ForEach(room.rooms, id: \.self) { name in
            Button {
              roomName = name
              roomEdit = .rename(name)
            } label: {
              LabeledContent(name) {
                Text("\(room.items.filter { room.roomOf($0) == name }.count)").foregroundStyle(Ink.dim)
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
        }
        .listRowBackground(Ink.card)
        Section("Hubspace") {
          if room.hubspace.state == .ready {
            Button("Sign out", role: .destructive) { room.hubspace.signOut() }
          } else {
            Button("Sign in") { sheet = .hubSetup }
          }
        }
        .listRowBackground(Ink.card)
        Section {
          Toggle("Reduce flashing", isOn: Binding(get: { room.reduceFlashing }, set: { room.reduceFlashing = $0 }))
        } footer: {
          Text("Hides blink, flash and strobe effects and calms music mode.")
        }
        .listRowBackground(Ink.card)
        Section("Help") {
          Button { sheet = .log } label: { Label("Activity log", systemImage: "doc.text") }
          Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          } label: { Label("Bluetooth and location access", systemImage: "hand.raised") }
          LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        }
        .listRowBackground(Ink.card)
      }
      .scrollContentBackground(.hidden)
      .background(RoomGlow(room: room))
      .foregroundStyle(Ink.text)
      .navigationTitle("Settings")
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

private struct PowerButton: View {
  let on: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "power")
        .contentShape(Rectangle())
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 34, height: 34)
        .foregroundStyle(on ? .black : Ink.text)
        .background(Circle().fill(on ? Ink.text : Ink.raised))
        .frame(width: 44, height: 44)
        .animation(Motion.state, value: on)
    }
    .buttonStyle(Press())
    .sensoryFeedback(.impact(weight: .medium), trigger: on)
    .accessibilityLabel(on ? "Turn everything off" : "Turn everything on")
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

private struct LightRow: View {
  var room: Room
  let item: LightItem
  let open: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let glow = room.shown(item).color
    VStack(spacing: 16) {
      HStack(spacing: 16) {
        Orb(item: item, color: room.live[item.id])
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name).font(.body.weight(.semibold)).lineLimit(1)
          Text(status).font(.footnote).foregroundStyle(statusColor).lineLimit(1)
        }
        Spacer()
        if item.caps.contains(.remote), item.status == .ready {
          Button {
            room.pressRemotePower(item)
          } label: {
            Image(systemName: "power")
              .font(.body.weight(.semibold))
              .frame(width: 44, height: 44)
              .background(Circle().fill(Ink.raised))
          }
          .buttonStyle(Press())
          .accessibilityLabel("\(item.name) power")
        } else if item.status == .ready {
          Toggle(item.name, isOn: Binding(get: { item.on }, set: { room.setPower(item.id, $0) }))
            .labelsHidden()
            .tint(glow)
        } else {
          Image(systemName: "chevron.right").foregroundStyle(Ink.dim)
        }
      }
      if item.status == .ready, item.on {
        PillSlider(
          value: Binding(get: { Double(item.brightness) / 100 }, set: { room.setBrightness(item.id, Int(($0 * 100).rounded())) }),
          fill: AnyShapeStyle(glow),
          label: "Brightness"
        )
        .frame(height: 44)
        // Reduce Motion: fade only, no slide.
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(16)
    .card(tint: item.status == .ready && item.on && !item.caps.contains(.remote) ? glow : nil)
    .opacity(item.kind == .remote && item.status != .ready ? 0.55 : 1)
    .contentShape(RoundedRectangle(cornerRadius: 24))
    .onTapGesture(perform: open)
    .sensoryFeedback(.impact(weight: .light), trigger: item.on)
    .animation(Motion.state, value: item.on)
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Open \(item.name)", open)
    .contextMenu {
      if item.status == .ready, item.caps.contains(.power) {
        Button("Blink", systemImage: "light.max") { room.identify(item.id) }
      }
    }
  }

  private var status: String {
    switch item.status {
    case .ready:
      if item.caps.contains(.remote) { return "Tap for the remote" }
      guard item.on else { return "Off" }
      if let effect = room.effectPlaying(on: item.id) { return effect.name }
      if let effect = item.effect { return HubspaceClient.effectName(effect) }
      // "Purple · 60%": the color in words (no judging swatches) and the level at a glance.
      let look = item.kelvin.map { $0 <= 3300 ? "Warm white" : $0 >= 5000 ? "Cool white" : "White" } ?? item.color.name
      return "\(look) · \(item.brightness)%"
    case .setup: return item.kind == .remote ? "Needs the IR bridge" : "Tap to set up"
    case .busy(let s): return s + "…"
    case .offline(let s): return s
    }
  }

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
            .foregroundStyle(value > 0.85 ? .black : Ink.text)
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
              .foregroundStyle(.black)
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
      .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.raised))
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(active ? Ink.text : Ink.line, lineWidth: active ? 1.5 : 1))
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
              .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.raised.opacity(0.6)))
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
              .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.raised.opacity(0.6)))
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
          .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.raised.opacity(0.6)))
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
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.raised.opacity(0.6)))
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
        .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }

  private func primary(_ title: String, disabled: Bool, _ action: @escaping () async -> Void) -> some View {
    Button { Task { await action() } } label: {
      Text(title)
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(.black)
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
              Text("Turn off the smart bulb when I leave").font(.body.weight(.semibold))
              Text("It's on Wi-Fi, so it can still be reached once you're gone. The strips can't: they're out of Bluetooth range by then.")
                .font(.footnote)
                .foregroundStyle(Ink.dim)
            }
          }
          .frame(minHeight: 44)

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
            if walkIn.measuring { ProgressView().tint(.black) }
            Text(walkIn.measuring ? "Measuring…" : walkIn.spot == nil ? "Set my spot" : "Set it again")
          }
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 52)
          .foregroundStyle(.black)
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

  private static let recipes: [(icon: String, title: String, how: String)] = [
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
            .foregroundStyle(.black)
            .background(Capsule().fill(Ink.text))
        }
        .buttonStyle(Press())
      }
  }
}

/// The Automations tab, like Hue's and Google Home's: one card per automation with its switch and what it will do;
/// the settings are one tap deeper, so the tab reads at a glance.
private struct AutomationsTab: View {
  var room: Room
  @State private var walkInOpen = false
  @State private var schedulesOpen = false

  var body: some View {
    let walkIn = room.walkIn
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          SectionTitle("Automatic")
          card(icon: "figure.walk.arrival", title: "Walk in", detail: walkInSummary(walkIn),
               on: Binding(get: { walkIn.enabled }, set: { walkIn.enabled = $0 })) { walkInOpen = true }
          SectionTitle("With Shortcuts").padding(.top, 20)
          card(icon: "clock", title: "Schedules", detail: "Wake up, bedtime, a set time, Siri and the Action Button", on: nil) { schedulesOpen = true }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }
      .scrollIndicators(.hidden)
      .background(RoomGlow(room: room))
      .foregroundStyle(Ink.text)
      .navigationTitle("Automations")
      .navigationDestination(isPresented: $walkInOpen) { page("Walk in") { WalkInSection(room: room) } }
      .navigationDestination(isPresented: $schedulesOpen) { page("Schedules") { ScheduleSection() } }
    }
  }

  private func walkInSummary(_ walkIn: WalkIn) -> String {
    guard walkIn.enabled else { return "Off" }
    let what = walkIn.sceneID ?? "Lights as they were"
    if let last = walkIn.events.first {
      return "\(what) · last: \(last.time.formatted(date: .omitted, time: .shortened))"
    }
    return "\(what) after \(walkIn.awayMinutes) min away"
  }

  private func card(icon: String, title: String, detail: String, on: Binding<Bool>?, open: @escaping () -> Void) -> some View {
    HStack(spacing: 14) {
      Button(action: open) {
        HStack(spacing: 14) {
          Image(systemName: icon)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .foregroundStyle(on?.wrappedValue == true ? .black : Ink.text)
            .background(Circle().fill(on?.wrappedValue == true ? Ink.text : Ink.raised))
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(Ink.dim).lineLimit(2)
          }
          Spacer(minLength: 0)
          if on == nil { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.dim) }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(Press())
      if let on {
        Toggle(title, isOn: on).labelsHidden()
      }
    }
    .padding(16)
    .card()
    .animation(Motion.state, value: on?.wrappedValue)
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
                  .foregroundStyle(n == nil ? Ink.dim : .black)
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
              .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.raised.opacity(0.6)))
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
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                .foregroundStyle(scanner.current == id ? .black : Ink.text)
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
        .foregroundStyle(.black)
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
private struct MapScreen: View {
  var room: Room
  @State private var scanning = false
  /// The map's frame stays put while you drag, so the scale doesn't shift under your finger.
  @State private var frozen: MapFrame?
  /// Bumped to ripple a light's dot (a sweep reaching it, or a tap).
  @State private var pulse: [String: Int] = [:]
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
        VStack(alignment: .leading, spacing: 28) {
          header
          if lights.isEmpty {
            Text("No lights in \(room.currentRoom) yet. Add one on the Room tab.")
              .foregroundStyle(Ink.dim)
          } else {
            map(placed)
            if !unplaced.isEmpty { tray(unplaced) }
            sweepSection(lights)
            syncSection(lights)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
      }
      .scrollIndicators(.hidden)
      .background(RoomGlow(room: room))
      .foregroundStyle(Ink.text)
      .navigationTitle("Map")
      .toolbar {
        if room.rooms.count > 1 {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Picker("Room", selection: Binding(get: { room.currentRoom }, set: { room.selectedRoom = $0 })) {
                ForEach(room.rooms, id: \.self) { Text($0).tag($0) }
              }
            } label: {
              Label(room.currentRoom, systemImage: "chevron.up.chevron.down").labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
            }
          }
        }
      }
      .sheet(isPresented: $scanning) { ScanSheet(room: room).panel() }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 16) {
      let placed = room.inRoom.contains { room.placements[$0.id] != nil }
      Text(placed ? "Tap a light to blink it. Drag lights, and the white dot, to where they really are."
                  : "Your phone's camera finds each light while it blinks, then puts it on the map.")
        .font(.subheadline)
        .foregroundStyle(Ink.dim)
      Button { scanning = true } label: {
        Label(placed ? "Scan again" : "Find my lights with the camera", systemImage: "viewfinder")
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 52)
          .foregroundStyle(placed ? Ink.text : .black)
          .background(Capsule().fill(placed ? Ink.raised : Ink.text))
      }
      .buttonStyle(Press())
      .disabled(room.scanTargets().isEmpty)
    }
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
    return GeometryReader { geo in
      let side = geo.size.width
      let scale = side / f.span
      let toView = { (x: Double, y: Double) in CGPoint(x: (x - f.minX) * scale, y: (y - f.minY) * scale) }
      let toMap = { (p: CGPoint) -> (Double, Double) in
        (min(f.minX + f.span, max(f.minX, Double(p.x) / scale + f.minX)), min(f.minY + f.span, max(f.minY, Double(p.y) / scale + f.minY)))
      }
      ZStack {
        RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Ink.card)
        // A 1 m grid, so distances read at a glance.
        Path { path in
          var v = ceil(f.minX)
          while v < f.minX + f.span {
            let x = (v - f.minX) * scale
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: side))
            v += 1
          }
          v = ceil(f.minY)
          while v < f.minY + f.span {
            let y = (v - f.minY) * scale
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: side, y: y))
            v += 1
          }
        }
        .stroke(Ink.line, lineWidth: 1)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        Text("1 m squares · up is the way you faced when scanning")
          .font(.caption2)
          .foregroundStyle(Ink.dim)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          .padding(.bottom, 10)

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
            dot(light, found: p.found)
              .position(toView(p.x, p.y))
              .onTapGesture {
                room.identify(light.id)
                pulse[light.id, default: 0] += 1
              }
              .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("map"))
                .onChanged { g in
                  if frozen == nil { frozen = f }
                  let m = toMap(g.location)
                  room.setPlacement(light.id, x: m.0, y: m.1)
                }
                .onEnded { _ in frozen = nil })
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(light.name)
              .accessibilityHint("Drag to where it sits in your room")
              .accessibilityAction(named: "Blink") { room.identify(light.id) }
          }
        }
      }
      .coordinateSpace(name: "map")
      .frame(width: side, height: side)
    }
    .aspectRatio(1, contentMode: .fit)
    .sensoryFeedback(.selection, trigger: frozen == nil)
  }

  private var you: some View {
    VStack(spacing: 4) {
      Circle()
        .fill(Ink.text)
        .frame(width: 16, height: 16)
        .overlay(Circle().strokeBorder(Ink.bg, lineWidth: 3))
        .padding(14)
        .background(Circle().fill(Ink.text.opacity(0.08)))
      Text("You").font(.caption2.weight(.semibold)).foregroundStyle(Ink.dim)
    }
    .contentShape(Rectangle())
    .accessibilityLabel("You")
    .accessibilityHint("Drag to where you usually sit")
  }

  private func dot(_ light: LightItem, found: Bool) -> some View {
    let lit = light.status == .ready && light.on
    let c = room.shown(light).color
    return VStack(spacing: 4) {
      ZStack {
        // A ripple when a sweep reaches it or you tap it.
        Circle()
          .stroke(lit ? c : Ink.text, lineWidth: 3)
          .frame(width: 34, height: 34)
          .keyframeAnimator(initialValue: 0.0, trigger: pulse[light.id] ?? 0) { view, t in
            view.scaleEffect(1 + t * 1.4).opacity(t == 0 || t == 1 ? 0 : 1 - t)
          } keyframes: { _ in
            LinearKeyframe(1.0, duration: reduceMotion ? 0.01 : 0.8)
          }
        Circle()
          .fill(lit ? c : Ink.raised)
          .frame(width: 34, height: 34)
          .shadow(color: lit ? c.opacity(0.45) : .clear, radius: 12)
          .overlay(Image(systemName: light.kind == .strip ? "light.strip.2" : "lightbulb.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(lit ? .black.opacity(0.7) : Ink.dim))
          .animation(Motion.frame, value: room.shown(light))
      }
      Text(light.name).font(.caption2.weight(.medium)).lineLimit(1).fixedSize()
      if !found {
        Text("placed by hand").font(.caption2).foregroundStyle(Ink.dim)
      }
    }
    .padding(5)
    .contentShape(Rectangle())
  }

  /// Lights not on the map yet: tap to drop one next to you, then drag it into place.
  private func tray(_ unplaced: [LightItem]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Not on the map yet").font(.headline)
      Text("Tap one to put it next to you, then drag it where it belongs. Or find it with the camera.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(Array(unplaced.enumerated()), id: \.element.id) { i, light in
            Button {
              room.setPlacement(light.id, x: Double(room.you.x) + Double(i % 3 - 1), y: Double(room.you.y) - 1)
            } label: {
              Label(light.name, systemImage: "plus")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Capsule().fill(Ink.raised))
            }
            .buttonStyle(Press())
          }
        }
      }
      .scrollIndicators(.hidden)
    }
  }

  private func sweepSection(_ lights: [LightItem]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("How scenes travel").font(.headline)
      Text("A new scene rolls across the room this way, and each light shows it on its turn, the slow bulb included.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(Room.SweepStyle.allCases, id: \.self) { style in
            let on = room.sweepStyle == style
            Button { withAnimation(Motion.tap) { room.sweepStyle = style } } label: {
              Text(style.rawValue)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(on ? .black : Ink.text)
                .background(Capsule().fill(on ? Ink.text : Ink.raised))
            }
            .buttonStyle(Press())
            .accessibilityAddTraits(on ? .isSelected : [])
          }
        }
      }
      .scrollIndicators(.hidden)
      .sensoryFeedback(.selection, trigger: room.sweepStyle)
      Button {
        let schedule = room.testSweep()
        for light in lights {
          DispatchQueue.main.asyncAfter(deadline: .now() + (schedule[light.id] ?? 0)) { pulse[light.id, default: 0] += 1 }
        }
      } label: {
        Label("Try it", systemImage: "wave.3.right")
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 52)
          .background(Capsule().fill(Ink.raised))
      }
      .buttonStyle(Press())
    }
  }

  /// Folded away: most people set it once, if ever.
  private func syncSection(_ lights: [LightItem]) -> some View {
    DisclosureGroup {
      syncTools(lights).padding(.top, 12)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("Keep lights in sync").font(.headline).foregroundStyle(Ink.text)
        Text("If one light changes late").font(.footnote).foregroundStyle(Ink.dim)
      }
    }
    .tint(Ink.dim)
  }

  private func syncTools(_ lights: [LightItem]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Flash them and watch: everything should come back at the same moment. If a light comes back late, slide it right so it's sent earlier; early, slide it left.")
          .font(.footnote)
          .foregroundStyle(Ink.dim)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button { room.flashTogether() } label: {
        Label("Flash all together", systemImage: "bolt.fill")
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: 52)
          .background(Capsule().fill(Ink.raised))
      }
      .buttonStyle(Press())
      ForEach(lights) { light in
        let nudge = room.syncNudge[light.id] ?? 0
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(light.name).font(.subheadline.weight(.semibold))
            Spacer()
            Text(nudge == 0 ? "auto" : String(format: "%+.1f s", nudge))
              .font(.footnote.monospacedDigit())
              .foregroundStyle(Ink.dim)
          }
          // -1 s to +2 s, and a double tap goes back to auto.
          PillSlider(value: Binding(get: { (nudge + 1) / 3 }, set: { room.setNudge(light.id, (($0 * 3 - 1) * 10).rounded() / 10) }),
                     fill: AnyShapeStyle(room.shown(light).color), range: 0...1, label: "\(light.name) timing", showsPercent: false)
            .frame(height: 32)
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
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.raised))
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
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            .background(Ink.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
              .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(template == t.name ? Ink.raised : Ink.raised.opacity(0.4)))
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
            .foregroundStyle(.black)
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

  /// A color that switches to `contrast` when Increase Contrast is on.
  init(hex: UInt32, contrast: UInt32) {
    self.init(UIColor { UIColor(Color(hex: $0.accessibilityContrast == .high ? contrast : hex)) })
  }
}
