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

private enum Sheet: Identifiable {
  case light(String), stripSetup, hubSetup, lampSetup, projector, log
  var id: String {
    switch self {
    case .light(let id): "light-" + id
    case .stripSetup: "strip"
    case .hubSetup: "hub"
    case .projector: "projector"
    case .lampSetup: "lamps"
    case .log: "log"
    }
  }
}

struct ContentView: View {
  var room: Room
  @State private var sheet: Sheet?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 32) {
        header
        scenes
        VStack(alignment: .leading, spacing: 12) {
          SectionTitle("Lights")
          ForEach(room.items) { item in
            LightRow(room: room, item: item) { open(item) }
          }
          Button { sheet = .lampSetup } label: {
            Label("Add a Bluetooth bulb", systemImage: "plus")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Ink.dim)
              .frame(maxWidth: .infinity, minHeight: 52)
              .background(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Ink.raised, style: StrokeStyle(lineWidth: 1.5, dash: [6])))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 40)
    }
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
        case .projector: ProjectorSheet(bridge: room.bridge)
        case .lampSetup: LampSetup(lamps: room.lamps)
        case .log: LogView(lines: room.strip.log + room.hubspace.log + room.bridge.log + room.lamps.log)
        }
      }
      .presentationDragIndicator(.visible)
      .presentationBackground(Ink.card)
      .preferredColorScheme(.dark)
    }
  }

  private var glow: some View {
    ZStack {
      Ink.bg
      if let ambient = room.ambient {
        RadialGradient(colors: [ambient.opacity(0.4), .clear], center: .top, startRadius: 0, endRadius: 480)
      }
    }
    .ignoresSafeArea()
    .animation(.easeInOut(duration: 0.6), value: room.ambient)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text("My Room")
          .font(.system(size: 34, weight: .bold, design: .rounded))
        Text(summary)
          .font(.subheadline)
          .foregroundStyle(Ink.dim)
      }
      Spacer()
      Menu {
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
      .disabled(room.ready.isEmpty)
    }
  }

  private var summary: String {
    let ready = room.ready
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
            .buttonStyle(.plain)
          }
        }
      }
      .scrollIndicators(.hidden)
      .disabled(room.ready.isEmpty)
      .opacity(room.ready.isEmpty ? 0.4 : 1)
      .sensoryFeedback(.selection, trigger: room.mood)
    }
  }

  private func open(_ item: LightItem) {
    switch (item.kind, item.status) {
    case (.projector, _): sheet = .projector
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
    .buttonStyle(.plain)
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
      .animation(.easeInOut(duration: 0.3), value: lit)
  }

  private var icon: String {
    switch item.kind {
    case .strip: "light.strip.2"
    case .bulb, .bleBulb: "lightbulb.fill"
    case .projector: "moon.stars.fill"
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
        if item.kind == .projector, item.status == .ready {
          Button {
            BridgeController.buttons.first.map(room.bridge.press)
          } label: {
            Image(systemName: "power")
              .font(.body.weight(.semibold))
              .frame(width: 44, height: 44)
              .background(Circle().fill(Ink.raised))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Projector power")
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
        .frame(height: 36)
      }
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Ink.card))
    .opacity(item.kind == .projector ? 0.55 : 1)
    .contentShape(RoundedRectangle(cornerRadius: 24))
    .onTapGesture(perform: open)
    .sensoryFeedback(.impact(weight: .light), trigger: item.on)
    .animation(.easeInOut(duration: 0.25), value: item.on)
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "Open \(item.name)", open)
  }

  private var status: String {
    switch item.status {
    case .ready:
      if item.kind == .projector { return "Tap for the remote" }
      guard item.on else { return "Off" }
      if item.kind == .strip, let effect = room.effect { return effect.name }
      if let effect = item.effect { return HubspaceClient.effectName(effect) }
      return item.kelvin.map { "\($0)K white" } ?? "Color"
    case .setup: return item.kind == .projector ? "Needs an IR bridge" : "Tap to set up"
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
  enum Mode: String, CaseIterable { case white = "White", color = "Color", effects = "Effects" }

  var room: Room
  let id: String
  @State private var mode = Mode.color
  @State private var renaming = false
  @State private var newName = ""
  @Environment(\.dismiss) private var dismiss

  private static let swatches: [RGB] = [
    RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 0, b: 200), RGB(r: 130, g: 0, b: 255), RGB(r: 0, g: 40, b: 255),
    RGB(r: 0, g: 230, b: 255), RGB(r: 60, g: 255, b: 60), RGB(r: 255, g: 240, b: 0), RGB(r: 255, g: 100, b: 20),
  ]
  private static let temperatures = [2200, 2700, 4000, 5000, 6500]

  var body: some View {
    if let item = room.item(id) {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          HStack(spacing: 16) {
            Orb(item: item, size: 44)
            Text(item.name)
              .font(.system(size: 26, weight: .bold, design: .rounded))
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
      ForEach(item.kind == .bleBulb ? [Mode.white, .color] : Mode.allCases, id: \.self) { m in
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
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == m ? .isSelected : [])
      }
    }
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
          .buttonStyle(.plain)
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
          .buttonStyle(.plain)
          .accessibilityLabel("Preset color \(i + 1)")
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
      if case .pattern = room.effect {
        speedSlider(Double(room.speed) / 100) { room.setSpeed(Int(($0 * 100).rounded())) }
      }
      ForEach(Effect.patternGroups, id: \.0) { group in
        heading(group.0, "sparkles")
        LazyVGrid(columns: Self.twoColumns, spacing: 12) {
          ForEach(group.1) { p in
            effectCard(p.name, colors: p.colors.map(\.color), active: room.effect == .pattern(p.id)) { room.start(.pattern(p.id)) }
          }
        }
      }

      heading("Music", "waveform")
      LazyVGrid(columns: Self.twoColumns, spacing: 12) {
        ForEach(Effect.micStyles.indices, id: \.self) { i in
          effectCard(Effect.micStyles[i], colors: [.pink, .purple, .cyan], active: room.effect == .stripMic(UInt8(i))) {
            room.start(.stripMic(UInt8(i)))
          }
        }
      }
      if case .stripMic = room.effect {
        VStack(alignment: .leading, spacing: 12) {
          heading("Mic sensitivity", "mic")
          PillSlider(value: Binding(get: { Double(room.sensitivity) / 255 }, set: { room.setSensitivity(Int(($0 * 255).rounded())) }),
                     fill: AnyShapeStyle(Ink.text), label: "Mic sensitivity")
            .frame(height: 40)
        }
      }
      effectCard("Use phone mic", colors: [.white, Ink.dim], active: room.effect == .phoneMic) { room.start(.phoneMic) }
      if room.effect == .phoneMic {
        Capsule()
          .fill(Ink.raised)
          .overlay(alignment: .leading) {
            GeometryReader { geo in Capsule().fill(.white).frame(width: geo.size.width * room.level) }
          }
          .frame(height: 6)
          .animation(.linear(duration: 0.05), value: room.level)
      }
      Text("Patterns and music styles run on the strip itself and use its built-in mic, so they keep going when you close the app. If the strip has no mic, use your phone's mic instead (only while the app is open).")
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
    .buttonStyle(.plain)
    .accessibilityAddTraits(active ? .isSelected : [])
  }

  private func footer(_ item: LightItem) -> some View {
    HStack {
      Button("Rename") {
        newName = item.name
        renaming = true
      }
      Spacer()
      Button(item.kind == .strip ? "Forget strip" : item.kind == .bleBulb ? "Remove bulb" : "Sign out of Hubspace", role: .destructive) {
        switch item.kind {
        case .strip:
          room.stopEffect()
          room.strip.disconnect()
        case .bleBulb:
          UUID(uuidString: String(item.id.dropFirst(4))).map(room.lamps.remove)
        default:
          room.hubspace.signOut()
        }
        dismiss()
      }
    }
    .font(.subheadline)
    .frame(minHeight: 44)
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
          Text("Add your LED strip").font(.system(size: 28, weight: .bold, design: .rounded))
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
            .buttonStyle(.plain)
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
                .buttonStyle(.plain)
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

private struct LampSetup: View {
  var lamps: BulbBank
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Add a Bluetooth bulb").font(.system(size: 28, weight: .bold, design: .rounded))
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
          .buttonStyle(.plain)
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
          Text("Add your smart bulb").font(.system(size: 28, weight: .bold, design: .rounded))
          Text("Sign in with your Hubspace account. The bulb has to be on Wi-Fi: Hubspace locks its Bluetooth, so this app reaches it through Hubspace's cloud.")
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
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.4 : 1)
  }
}

private struct ProjectorSheet: View {
  var bridge: BridgeController
  @State private var learnMode = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 16) {
          Image(systemName: "moon.stars.fill")
            .font(.title2)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Ink.raised))
          Text("Galaxy projector").font(.system(size: 26, weight: .bold, design: .rounded))
        }
        if bridge.state == .ready {
          remote
        } else {
          setup
        }
      }
      .padding(24)
    }
  }

  private var remote: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let id = bridge.learning, let button = BridgeController.buttons.first(where: { $0.id == id }) {
        HStack {
          ProgressView()
          Text("Point the projector's remote at the bridge and press \(button.name).")
            .font(.subheadline)
          Spacer()
          Button("Cancel") { bridge.cancelLearning() }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.raised))
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
        ForEach(BridgeController.buttons) { button in
          Button {
            learnMode ? bridge.learn(button) : bridge.press(button)
          } label: {
            VStack(spacing: 8) {
              Image(systemName: button.icon).font(.title3)
              Text(button.name).font(.caption.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
              .fill(button.id == "power" ? Color(hex: 0xFF453A).opacity(0.25) : Ink.raised))
            .overlay(alignment: .topTrailing) {
              if bridge.learned[button.id] != nil {
                Circle().fill(Ink.text).frame(width: 6, height: 6).padding(8)
              }
            }
          }
          .buttonStyle(.plain)
          .sensoryFeedback(.impact(weight: .light), trigger: bridge.log.count)
        }
      }
      Toggle("Learn buttons from the real remote", isOn: $learnMode)
        .font(.subheadline)
      Text(learnMode
           ? "Tap a button here, then press the same button on the projector's remote. Needs the IR Unit on the bridge. A dot marks learned buttons."
           : "Buttons use common astronaut-projector codes. If one does nothing, turn on learning and teach it from the real remote.")
        .font(.footnote)
        .foregroundStyle(Ink.dim)
      if !bridge.learned.isEmpty {
        Button("Forget learned buttons", role: .destructive) { bridge.forgetLearned() }
          .font(.subheadline)
      }
    }
  }

  private var setup: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("The projector only takes infrared, and iPhones have no IR blaster. Plug in a DormBridge and this turns into the projector's remote.")
        .foregroundStyle(Ink.dim)
      Text("What you need: an M5Stack ATOM Lite (about $8, has an IR LED built in) flashed with the DormBridge firmware, on any USB charger, pointed at the projector. Optional: the M5Stack IR Unit (about $4) to learn codes from the real remote.")
        .foregroundStyle(Ink.dim)
      HStack(spacing: 12) {
        ProgressView()
        Text(bridge.state == .off ? "Turn on Bluetooth." : "Looking for a DormBridge…").foregroundStyle(Ink.dim)
      }
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
