import ARKit
import SwiftUI
import UIKit

// Design: black canvas, flat cards, and each light's own color as the only accent.
// Layout follows the Hubspace light screen (mode circles, brightness bar, presets, wheel)
// with DayBetter's patterns and music on top.
private enum Ink {
  static let bg = Color.black
  static let card = Color(hex: 0x141416)
  static let raised = Color(hex: 0x232328)
  static let text = Color(hex: 0xF5F5F7)
  static let dim = Color(hex: 0x8E8E93)
  static let bad = Color(hex: 0xFF6B5E)
}

/// Pressed state for every custom button: a slight shrink and dim on a spring, so taps feel answered
/// within a frame. Off when Reduce Motion is on (only the dim stays).
private struct Press: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.8 : 1)
      .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

private enum Sheet: Identifiable {
  case light(String), stripSetup, hubSetup, lampSetup, remote(String), addRemote, add, scan, map, log
  var id: String {
    switch self {
    case .light(let id): "light-" + id
    case .stripSetup: "strip"
    case .hubSetup: "hub"
    case .remote(let id): "remote-" + id
    case .addRemote: "addRemote"
    case .scan: "scan"
    case .map: "map"
    case .lampSetup: "lamps"
    case .add: "add"
    case .log: "log"
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
  @State private var roomName = ""

  private enum RoomEdit: Equatable { case add, rename(String) }

  var body: some View {
    // A List, so rows get the standard iOS swipe-left-to-delete.
    List {
      Group {
        header.padding(.top, 16)
        roomTabs
        scenes.padding(.top, 8)
        HStack {
          SectionTitle("Lights")
          Spacer()
          Button { sheet = .add } label: {
            Label("Add", systemImage: "plus").font(.subheadline.weight(.semibold))
          }
          .buttonStyle(Press())
          .frame(minHeight: 44)
        }
        .padding(.top, 16)
        ForEach(room.inRoom) { item in row(item) }
        if room.inRoom.isEmpty {
          Text("Nothing in \(room.currentRoom) yet. Tap Add, or move a device here from its settings.")
            .font(.subheadline)
            .foregroundStyle(Ink.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Text("Swipe left on a device to remove it.")
          .font(.footnote)
          .foregroundStyle(Ink.dim)
          .frame(maxWidth: .infinity)
          .padding(.bottom, 24)
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .scrollIndicators(.hidden)
    .background(glow)
    .foregroundStyle(Ink.text)
    .tint(Ink.text)
    .sheet(item: $sheet) { sheet in
      Group {
        switch sheet {
        case .light(let id): LightSheet(room: room, id: id)
        case .stripSetup: StripSetup(strip: room.strip)
        case .hubSetup: HubSetup(hubspace: room.hubspace)
        case .remote(let id): RemoteSheet(room: room, id: id)
        case .addRemote: AddRemoteSheet(room: room)
        case .scan: ScanSheet(room: room) { self.sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.sheet = .map } }
        case .map: RoomMapSheet(room: room)
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
        }
      }
      .presentationDragIndicator(.visible)
      .presentationBackground(Ink.card)
      .preferredColorScheme(.dark)
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
          Button { room.selectedRoom = name } label: {
            Text(name)
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 16)
              .frame(minHeight: 44)
              .foregroundStyle(selected ? .black : Ink.text)
              .background(Capsule().fill(selected ? Ink.text : Ink.raised))
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

  private var glow: some View {
    ZStack {
      Ink.bg
      if let ambient = room.ambient {
        RadialGradient(colors: [ambient.opacity(0.4), .clear], center: .top, startRadius: 0, endRadius: 480)
      }
    }
    .ignoresSafeArea()
    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: room.ambient)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text(room.currentRoom)
          .font(.system(.largeTitle, design: .rounded, weight: .bold))
        Text(summary)
          .font(.subheadline)
          .foregroundStyle(Ink.dim)
      }
      Spacer()
      Menu {
        Button("Find my lights", systemImage: "viewfinder") { sheet = .scan }
        Button("Room map", systemImage: "map") { sheet = .map }
        Button("Turn everything off", systemImage: "power") { room.setPower(Room.everything, false) }
        if room.hubspace.state == .ready {
          Button("Sign out of Hubspace", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { room.hubspace.signOut() }
        }
        Button("Show log", systemImage: "doc.text") { sheet = .log }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 44, height: 44)
          .foregroundStyle(Ink.dim)
      }
      .accessibilityLabel("More")
      PowerButton(on: room.anyOn, tint: room.ambient ?? .white) {
        room.setPower(Room.all, !room.anyOn)
      }
      .disabled(room.roomReady.isEmpty)
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
      SectionTitle("Scenes")
      ScrollView(.horizontal) {
        HStack(spacing: 16) {
          ForEach(Mood.all) { mood in
            Button { room.apply(mood) } label: {
              VStack(spacing: 8) {
                Circle()
                  .fill(AngularGradient(colors: mood.swatch + [mood.swatch[0]], center: .center))
                  .frame(width: 60, height: 60)
                  .padding(4)
                  .overlay(Circle().strokeBorder(Ink.text, lineWidth: room.mood == mood.id ? 2 : 0))
                Text(mood.id)
                  .font(.caption.weight(.medium))
                  .foregroundStyle(room.mood == mood.id ? Ink.text : Ink.dim)
              }
            }
            .buttonStyle(Press())
          }
        }
      }
      .scrollIndicators(.hidden)
      .disabled(room.roomReady.isEmpty)
      .opacity(room.roomReady.isEmpty ? 0.4 : 1)
      .sensoryFeedback(.selection, trigger: room.mood)
    }
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
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "power")
        .font(.system(size: 20, weight: .semibold))
        .frame(width: 52, height: 52)
        .foregroundStyle(on ? .black : Ink.text)
        .background(Circle().fill(on ? tint : Ink.raised))
        .shadow(color: on ? tint.opacity(0.6) : .clear, radius: 16)
    }
    .buttonStyle(Press())
    .sensoryFeedback(.impact(weight: .medium), trigger: on)
    .accessibilityLabel(on ? "Turn everything off" : "Turn everything on")
  }
}

/// Glowing circle in the light's color, like the bulb icon in Hubspace's list.
private struct Orb: View {
  let item: LightItem
  var size: CGFloat = 52

  var body: some View {
    let lit = item.status == .ready && item.on
    Image(systemName: icon)
      .font(.system(size: size * 0.4, weight: .medium))
      .frame(width: size, height: size)
      .foregroundStyle(lit ? .black.opacity(0.75) : Ink.dim)
      .background(Circle().fill(lit ? item.glow.color : Ink.raised))
      .shadow(color: lit ? item.glow.color.opacity(0.8) : .clear, radius: 14)
      .animation(.easeOut(duration: 0.2), value: lit)
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

  var body: some View {
    VStack(spacing: 16) {
      HStack(spacing: 16) {
        Orb(item: item)
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
            .tint(item.glow.color)
        } else {
          Image(systemName: "chevron.right").foregroundStyle(Ink.dim)
        }
      }
      if item.status == .ready, item.on {
        PillSlider(
          value: Binding(get: { Double(item.brightness) / 100 }, set: { room.setBrightness(item.id, Int(($0 * 100).rounded())) }),
          fill: AnyShapeStyle(item.glow.color),
          label: "Brightness"
        )
        .frame(height: 44)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Ink.card))
    .opacity(item.kind == .remote && item.status != .ready ? 0.55 : 1)
    .contentShape(RoundedRectangle(cornerRadius: 24))
    .onTapGesture(perform: open)
    .sensoryFeedback(.impact(weight: .light), trigger: item.on)
    .animation(.easeOut(duration: 0.2), value: item.on)
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Open \(item.name)", open)
  }

  private var status: String {
    switch item.status {
    case .ready:
      if item.caps.contains(.remote) { return "Tap for the remote" }
      guard item.on else { return "Off" }
      if item.kind == .strip, let effect = room.effect { return effect.name }
      if let effect = item.effect { return HubspaceClient.effectName(effect) }
      return item.kelvin.map { "\($0)K white" } ?? "Color"
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
  @State private var mode = Mode.color
  @State private var renaming = false
  @State private var matching = false
  @State private var confirmRemove = false
  @State private var newName = ""
  @Environment(\.dismiss) private var dismiss

  private static let swatches: [RGB] = [
    RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 0, b: 200), RGB(r: 130, g: 0, b: 255), RGB(r: 0, g: 40, b: 255),
    RGB(r: 0, g: 230, b: 255), RGB(r: 60, g: 255, b: 60), RGB(r: 255, g: 240, b: 0), RGB(r: 255, g: 100, b: 20),
  ]
  private static let swatchNames = ["Red", "Pink", "Purple", "Blue", "Cyan", "Green", "Yellow", "Orange"]
  private static let temperatures = [2200, 2700, 4000, 5000, 6500]

  var body: some View {
    if let item = room.item(id) {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          HStack(spacing: 16) {
            Orb(item: item, size: 44)
            Text(item.name)
              .font(.system(.title, design: .rounded, weight: .bold))
              .lineLimit(1)
            Spacer()
            Toggle(item.name, isOn: Binding(get: { item.on }, set: { room.setPower(id, $0) }))
              .labelsHidden()
              .tint(item.glow.color)
          }

          modePicker(item)

          VStack(alignment: .leading, spacing: 12) {
            Label("Brightness", systemImage: "sun.max")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Ink.dim)
            PillSlider(
              value: Binding(get: { Double(item.brightness) / 100 }, set: { room.setBrightness(id, Int(($0 * 100).rounded())) }),
              fill: AnyShapeStyle(item.glow.color),
              label: "Brightness"
            )
            .frame(height: 48)
          }

          switch mode {
          case .white: whiteControls(item)
          case .color: colorControls(item)
          case .effects:
            if item.kind == .strip { stripEffects } else { bulbEffects(item) }
          }

          if item.kind == .bulb {
            Text("The bulb takes commands through Hubspace's cloud, so it has to be on Wi-Fi. Changes can take a second.")
              .font(.footnote)
              .foregroundStyle(Ink.dim)
          }

          footer(item)
        }
        .padding(24)
        .padding(.top, 8)
      }
      .onAppear {
        let inEffect = item.kind == .strip ? room.effect != nil : item.effect != nil
        mode = inEffect ? .effects : item.kelvin != nil ? .white : .color
      }
      .sheet(isPresented: $matching) {
        MatchSheet(room: room)
          .presentationDragIndicator(.visible)
          .presentationBackground(Ink.card)
          .preferredColorScheme(.dark)
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
      ForEach(Mode.allCases.filter { item.caps.contains($0.capability) }, id: \.self) { m in
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
    .animation(.easeOut(duration: 0.15), value: mode)
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
        .fill(LinearGradient(colors: [Color(hex: 0xFFD54A), Color(hex: 0xFF9F1C)], startPoint: .top, endPoint: .bottom))
        .overlay(Image(systemName: "play.fill").font(.title2).foregroundStyle(.white))
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
      ColorWheel(selected: item.kelvin == nil ? item.color : nil) { room.setColor(id, $0) }
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
      ForEach(Effect.patternGroups, id: \.0) { group in
        heading(group.0, "sparkles")
        LazyVGrid(columns: Self.twoColumns, spacing: 12) {
          ForEach(group.1) { p in
            effectCard(p.name, colors: p.colors.map(\.color), active: room.effect == .pattern(p.id)) { room.start(.pattern(p.id)) }
          }
        }
      }
      heading("Music", "waveform")
      effectCard("Pulse to music (phone mic)", colors: [.pink, .purple, .cyan], active: room.effect == .phoneMic) { room.start(.phoneMic) }
      if room.effect == .phoneMic {
        Capsule()
          .fill(Ink.raised)
          .overlay(alignment: .leading) {
            GeometryReader { geo in Capsule().fill(.white).frame(width: geo.size.width * room.level) }
          }
          .frame(height: 6)
          .animation(.linear(duration: 0.05), value: room.level)
      }
      Text("Effects run on the strip itself and keep going when you close the app. Music mode listens through your phone while the app is open.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
      if let error = room.effectError {
        Text(error).font(.footnote).foregroundStyle(Ink.bad)
      }
    }
  }

  private static let bulbSwatches: [String: [Color]] = [
    "rainbow": Effect.rainbow.map(\.color), "fade-3": Effect.three.map(\.color), "jump-3": Effect.three.map(\.color),
    "fade-7": Effect.rainbow.map(\.color), "jump-7": Effect.rainbow.map(\.color), "flash": [.white, .black],
    "christmas": [.red, .green, .white], "july-4th": [.red, .white, .blue], "valentines-day": [.pink, .red, .white],
    "chill": [RGB.kelvin(2700).color, RGB.kelvin(2200).color], "sleep": [RGB.kelvin(2200).color, .black],
    "wake-up": [RGB.kelvin(2200).color, .white], "moonlight": [Color(hex: 0x6E8BFF), Color(hex: 0x1A1F4A)],
    "nightlight": [Color(hex: 0xFF5A1F), .black], "dinner-party": [RGB.kelvin(2700).color, Color(hex: 0xFF9F1C)],
  ]

  private func bulbEffects(_ item: LightItem) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      if item.effect != nil {
        speedSlider(Double(item.speed + 10) / 20) { room.setBulbSpeed(id, Int(($0 * 20).rounded()) - 10) }
      }
      ForEach(HubspaceClient.effectGroups, id: \.0) { group in
        heading(group.0, group.0 == "Holidays" ? "gift" : "sparkles")
        LazyVGrid(columns: Self.twoColumns, spacing: 12) {
          ForEach(group.1, id: \.id) { e in
            effectCard(e.name, colors: Self.bulbSwatches[e.id] ?? [.white, RGB.kelvin(5000).color], active: item.effect == e.id) {
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
      .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(active ? Ink.text.opacity(0.14) : Ink.raised))
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Ink.text.opacity(active ? 0.9 : 0), lineWidth: 1.5))
    }
    .buttonStyle(Press())
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
      Button { matching = true } label: {
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
      .gesture(DragGesture(minimumDistance: 0).onChanged { g in
        let dx = g.location.x - geo.size.width / 2, dy = g.location.y - geo.size.height / 2
        let angle = atan2(dy, dx)
        pick(RGB.hue(angle / (2 * .pi), saturation: min(1, (dx * dx + dy * dy).squareRoot() / r)))
      })
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityLabel("Color wheel")
  }
}

// MARK: - Setup

private struct StripSetup: View {
  var strip: StripController
  @State private var showOthers = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let strips = strip.devices.filter { Daybetter.looksLikeStrip($0.name) }
    let others = strip.devices.filter { !Daybetter.looksLikeStrip($0.name) }
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Add your LED strip").font(.system(.title, design: .rounded, weight: .bold))
          Text("Close the DayBetter app first. The strip only talks to one app at a time.")
            .foregroundStyle(Ink.dim)
        }

        switch strip.state {
        case .connecting, .unlocking:
          HStack(spacing: 12) {
            ProgressView()
            Text("Connecting…").foregroundStyle(Ink.dim)
            Spacer()
            Button("Cancel") { strip.cancelConnecting() }.frame(minHeight: 44)
          }
        case .off:
          Text("Turn on Bluetooth.").foregroundStyle(Ink.dim)
        case .failed(let message):
          Text(message).foregroundStyle(Ink.bad)
          Button("Try again") { strip.scan() }.frame(minHeight: 44)
        default:
          if strips.isEmpty {
            HStack(spacing: 12) {
              ProgressView()
              Text("Looking for DayBetter strips…").foregroundStyle(Ink.dim)
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
                  Text(device.name).font(.footnote).foregroundStyle(Ink.dim)
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
    .onAppear { if strip.state == .idle { strip.scan() } }
    .onChange(of: strip.state) { _, new in if new == .connected { dismiss() } }
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
    .onChange(of: hubspace.state) { _, new in if new == .ready { dismiss() } }
  }

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
        .background(Capsule().fill(.white))
    }
    .buttonStyle(Press())
    .disabled(disabled)
    .opacity(disabled ? 0.4 : 1)
  }
}

/// "Find my lights": the lights blink one at a time while you turn slowly, and the app learns where each one is.
private struct ScanSheet: View {
  var room: Room
  let openMap: () -> Void
  @State private var scanner = LightScanner()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Find my lights").font(.system(.title, design: .rounded, weight: .bold))
        switch scanner.phase {
        case .unsupported:
          Text("This iPhone can't track motion for scanning. Place your lights on the room map instead.")
            .foregroundStyle(Ink.dim)
          wide("Open room map", action: openMap)
        case .ready:
          VStack(alignment: .leading, spacing: 10) {
            step(1, "Dim the room if you can. Stand or sit where you usually are.")
            step(2, "Tap Start and hold the phone up, like taking a panorama.")
            step(3, "Turn slowly all the way around. The lights in \(room.currentRoom) blink one at a time; the ring fills as the app sees each one.")
            step(4, "Tap Finish when the ring is mostly full. Your lights go back to how they were.")
          }
          .foregroundStyle(Ink.dim)
          wide("Start") { scanner.start(room: room) }
            .disabled(room.scanTargets().isEmpty)
          if room.scanTargets().isEmpty {
            Text("No connected lights in \(room.currentRoom).").font(.footnote).foregroundStyle(Ink.bad)
          }
        case .preparing, .scanning:
          ZStack {
            CameraView(session: scanner.session)
              .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Circle()
              .trim(from: 0, to: scanner.coverage)
              .stroke(Ink.text, style: StrokeStyle(lineWidth: 6, lineCap: .round))
              .rotationEffect(.degrees(-90))
              .frame(width: 120, height: 120)
              .animation(.easeOut, value: scanner.coverage)
          }
          .frame(height: 360)
          Text(scanner.phase == .preparing
               ? "Getting the lights ready…"
               : "Keep turning slowly. \(Int(scanner.coverage * 100))% of the room seen.")
            .foregroundStyle(Ink.dim)
          wide("Finish") { scanner.finish() }
            .disabled(scanner.coverage < 0.3)
          Button("Cancel") {
            scanner.cancel()
            dismiss()
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        case .done:
          ForEach(Array(scanner.names.keys.sorted()), id: \.self) { id in
            HStack {
              Text(scanner.names[id] ?? id)
              Spacer()
              if let r = scanner.results[id] {
                Text(String(format: "Found · reacts in %.1f s", r.latency)).foregroundStyle(Ink.dim)
              } else {
                Text("Not seen").foregroundStyle(Ink.bad)
              }
            }
            .font(.subheadline)
            .frame(minHeight: 44)
          }
          Text(scanner.results.count == scanner.names.count
               ? "All found. Scenes now sweep around the room and arrive together."
               : "Place the ones not seen on the room map, or scan again in a darker room.")
            .font(.footnote)
            .foregroundStyle(Ink.dim)
          wide("Check the room map", action: openMap)
          Button("Scan again") { scanner.start(room: room) }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
      }
      .padding(24)
    }
    .onDisappear { scanner.cancel() }
  }

  private func step(_ n: Int, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(n)").font(.subheadline.weight(.bold)).frame(width: 22, height: 22).background(Circle().fill(Ink.raised))
      Text(text).font(.subheadline)
    }
  }

  private func wide(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(.black)
        .background(Capsule().fill(.white))
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

/// Top-down room map, the fallback for lights the scan didn't see. You're in the middle; drag each light to where it is.
private struct RoomMapSheet: View {
  var room: Room

  var body: some View {
    let lights = room.inRoom.filter { $0.caps.contains(.color) }
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("\(room.currentRoom) map").font(.system(.title, design: .rounded, weight: .bold))
          Text("You're the dot in the middle. Lights found by scanning are already placed; drag any light to fix it. Dashed ones aren't placed yet.")
            .foregroundStyle(Ink.dim)
        }
        GeometryReader { geo in
          let side = geo.size.width
          ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Ink.raised.opacity(0.5))
            Circle().fill(Ink.text).frame(width: 14, height: 14)
            Text("You").font(.caption2).foregroundStyle(Ink.dim).offset(y: 16)
            ForEach(Array(lights.enumerated()), id: \.element.id) { index, light in
              let placed = room.placements[light.id]
              let fallback = Double(index) / Double(max(1, lights.count)) * 2 * .pi
              let x = placed?.x ?? sin(fallback) * 0.9
              let y = placed?.y ?? -cos(fallback) * 0.9
              VStack(spacing: 4) {
                Circle()
                  .fill(light.glow.color)
                  .frame(width: 34, height: 34)
                  .overlay(Circle().strokeBorder(Ink.text, style: StrokeStyle(lineWidth: 2, dash: placed == nil ? [4] : [])))
                Text(light.name).font(.caption2).lineLimit(1).fixedSize()
              }
              .position(x: (x + 1) / 2 * side, y: (y + 1) / 2 * side)
              .gesture(DragGesture().onChanged { g in
                room.setPlacement(light.id, x: g.location.x / side * 2 - 1, y: g.location.y / side * 2 - 1)
              })
              .accessibilityLabel(light.name)
            }
          }
          .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        Button {
          room.testSweep()
        } label: {
          Label("Test the sweep", systemImage: "wave.3.right")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.black)
            .background(Capsule().fill(.white))
        }
        .buttonStyle(Press())
        Text("Each tap rolls a new color around the room, in order, timed so every light lands together.")
          .font(.footnote)
          .foregroundStyle(Ink.dim)
      }
      .padding(24)
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
              Image(systemName: button.icon).font(.title3)
              Text(button.name).font(.caption.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
              .fill(button.id == "power" ? Color(hex: 0xFF453A).opacity(0.25) : Ink.raised))
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
            .background(Capsule().fill(.white))
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
}
