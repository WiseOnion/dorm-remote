import SwiftUI
import UIKit

// Design: black canvas, one soft glow in the color of whatever is on, flat tiles, no borders.
private enum Ink {
  static let bg = Color.black
  static let tile = Color(hex: 0x141416)
  static let raised = Color(hex: 0x1F1F23)
  static let text = Color(hex: 0xF5F5F7)
  static let dim = Color(hex: 0x8E8E93)
}

private enum Sheet: Identifiable {
  case control(String), stripSetup, hubSetup, projector, log
  var id: String {
    switch self {
    case .control(let id): "control-" + id
    case .stripSetup: "strip"
    case .hubSetup: "hub"
    case .projector: "projector"
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
        if !room.ready.isEmpty { roomBrightness }
        moods
        lights
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 40)
    }
    .scrollIndicators(.hidden)
    .background(glow)
    .foregroundStyle(Ink.text)
    .sheet(item: $sheet) { sheet in
      Group {
        switch sheet {
        case .control(let id): ControlSheet(room: room, id: id)
        case .stripSetup: StripSetup(strip: room.strip)
        case .hubSetup: HubSetup(hubspace: room.hubspace)
        case .projector: ProjectorInfo()
        case .log: LogView(lines: room.strip.log + room.hubspace.log)
        }
      }
      .presentationDragIndicator(.visible)
      .presentationBackground(Ink.tile)
      .preferredColorScheme(.dark)
    }
  }

  private var glow: some View {
    ZStack {
      Ink.bg
      if let ambient = room.ambient {
        RadialGradient(colors: [ambient.opacity(0.45), .clear], center: .top, startRadius: 0, endRadius: 520)
      }
    }
    .ignoresSafeArea()
    .animation(.easeInOut(duration: 0.6), value: room.ambient)
  }

  private var header: some View {
    HStack(alignment: .center) {
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
    return on == 0 ? "All off" : on == ready.count ? "All on" : "\(on) of \(ready.count) on"
  }

  private var roomBrightness: some View {
    PillSlider(
      value: Binding(
        get: { Double(room.look(Room.all)?.brightness ?? 100) / 100 },
        set: { room.setBrightness(Room.all, Int(($0 * 100).rounded())) }
      ),
      fill: AnyShapeStyle(room.ambient ?? .white),
      icon: "sun.max.fill",
      label: "Brightness"
    )
    .frame(height: 56)
  }

  private var moods: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Moods")
      ScrollView(.horizontal) {
        HStack(spacing: 16) {
          ForEach(Mood.all) { mood in
            Button { room.apply(mood) } label: {
              VStack(spacing: 8) {
                Circle()
                  .fill(AngularGradient(colors: mood.swatch + [mood.swatch[0]], center: .center))
                  .frame(width: 56, height: 56)
                  .overlay(Circle().strokeBorder(.white, lineWidth: room.mood == mood.id ? 2 : 0))
                  .padding(3)
                Text(mood.id)
                  .font(.caption)
                  .foregroundStyle(room.mood == mood.id ? Ink.text : Ink.dim)
              }
            }
            .buttonStyle(.plain)
            .disabled(room.ready.isEmpty)
            .opacity(room.ready.isEmpty ? 0.4 : 1)
          }
        }
      }
      .scrollIndicators(.hidden)
      .sensoryFeedback(.selection, trigger: room.mood)
    }
  }

  private var lights: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTitle("Lights")
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
        ForEach(room.items) { item in
          LightTile(item: item, effect: item.kind == .strip ? room.effect : nil) {
            room.setPower(item.id, !item.on)
          } open: {
            open(item)
          }
        }
      }
    }
  }

  private func open(_ item: LightItem) {
    switch (item.kind, item.status) {
    case (.projector, _): sheet = .projector
    case (_, .ready): sheet = .control(item.id)
    case (.strip, _): sheet = .stripSetup
    case (.bulb, _): sheet = .hubSetup
    }
  }
}

// MARK: - Pieces

private struct SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text.uppercased())
      .font(.caption.weight(.semibold))
      .tracking(1.2)
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

private struct LightTile: View {
  let item: LightItem
  let effect: Room.Effect?
  let toggle: () -> Void
  let open: () -> Void

  private var lit: Bool { item.status == .ready && item.on }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: item.status == .ready ? toggle : open) {
        Image(systemName: icon)
          .font(.system(size: 20, weight: .medium))
          .frame(width: 44, height: 44)
          .foregroundStyle(lit ? .black : Ink.dim)
          .background(Circle().fill(lit ? item.glow.color : Ink.raised))
          .shadow(color: lit ? item.glow.color.opacity(0.7) : .clear, radius: 12)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(lit ? "Turn \(item.name) off" : "Turn \(item.name) on")
      .sensoryFeedback(.impact(weight: .light), trigger: item.on)

      Spacer(minLength: 20)

      Button(action: open) {
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name)
            .font(.body.weight(.semibold))
            .lineLimit(1)
          Text(status)
            .font(.footnote)
            .foregroundStyle(statusColor)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(Ink.tile)
        .overlay(
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(LinearGradient(colors: [item.glow.color.opacity(lit ? 0.22 : 0), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    )
    .opacity(item.kind == .projector ? 0.6 : 1)
    .contentShape(RoundedRectangle(cornerRadius: 24))
    .onTapGesture(perform: open)
    .animation(.easeInOut(duration: 0.25), value: lit)
  }

  private var icon: String {
    switch item.kind {
    case .strip: "light.strip.2"
    case .bulb: lit ? "lightbulb.fill" : "lightbulb"
    case .projector: "moon.stars"
    }
  }

  private var status: String {
    switch item.status {
    case .ready: item.on ? effect.map { "\($0.rawValue) · on" } ?? "\(item.brightness)%" : "Off"
    case .setup: item.kind == .projector ? "Needs IR bridge" : "Tap to set up"
    case .busy(let s): s + "…"
    case .offline(let s): s
    }
  }

  private var statusColor: Color {
    if case .offline = item.status { return Color(hex: 0xFF6B5E) }
    return Ink.dim
  }
}

/// Big Control Center-style slider. With a fill it grows from the left; without one it shows a thumb over the track.
private struct PillSlider: View {
  @Binding var value: Double
  var fill: AnyShapeStyle?
  var track = AnyShapeStyle(Ink.raised)
  var icon: String?
  var label: String

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      ZStack(alignment: .leading) {
        Capsule().fill(track)
        if let fill {
          Capsule().fill(fill).frame(width: max(h, w * value))
        } else {
          Circle()
            .fill(.white)
            .frame(width: h - 12, height: h - 12)
            .shadow(radius: 4)
            .offset(x: 6 + (w - h) * value)
        }
        HStack(spacing: 8) {
          if let icon { Image(systemName: icon) }
          Text(label)
          Spacer()
          if fill != nil { Text("\(Int((value * 100).rounded()))%").monospacedDigit() }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 20)
        .foregroundStyle(fill != nil && value > 0.5 ? .black : Ink.text)
        .blendMode(fill != nil ? .normal : .difference)
        .allowsHitTesting(false)
      }
      .clipShape(Capsule())
      .contentShape(Capsule())
      .gesture(DragGesture(minimumDistance: 0).onChanged { g in
        value = max(0.01, min(1, g.location.x / w))
      })
    }
    .accessibilityElement()
    .accessibilityLabel(label)
    .accessibilityValue("\(Int(value * 100)) percent")
    .accessibilityAdjustableAction { dir in
      value = max(0.01, min(1, value + (dir == .increment ? 0.1 : -0.1)))
    }
  }
}

// MARK: - Control sheet

private struct ControlSheet: View {
  var room: Room
  let id: String
  @State private var white = false
  @State private var custom = Color.white
  @State private var renaming = false
  @State private var newName = ""
  @Environment(\.dismiss) private var dismiss

  private static let swatches: [RGB] = [
    RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 90, b: 30), RGB(r: 255, g: 190, b: 0), RGB(r: 0, g: 255, b: 80),
    RGB(r: 0, g: 210, b: 255), RGB(r: 0, g: 60, b: 255), RGB(r: 140, g: 0, b: 255), RGB(r: 255, g: 0, b: 180),
    RGB(r: 255, g: 50, b: 100), RGB(r: 0, g: 255, b: 170), RGB(r: 255, g: 255, b: 255),
  ]

  var body: some View {
    let look = room.look(id)
    let isAll = id == Room.all
    let hasStrip = isAll ? room.ready.contains(where: { $0.kind == .strip }) : look?.kind == .strip

    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(isAll ? "All lights" : look?.name ?? "Light")
              .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(look?.on == true ? "On" : "Off").foregroundStyle(Ink.dim)
          }
          Spacer()
          PowerButton(on: look?.on ?? false, tint: look?.glow.color ?? .white) {
            room.setPower(id, !(look?.on ?? false))
          }
        }

        PillSlider(
          value: Binding(
            get: { Double(look?.brightness ?? 100) / 100 },
            set: { room.setBrightness(id, Int(($0 * 100).rounded())) }
          ),
          fill: AnyShapeStyle(look?.glow.color ?? .white),
          icon: "sun.max.fill",
          label: "Brightness"
        )
        .frame(height: 64)

        Picker("Mode", selection: $white) {
          Text("Color").tag(false)
          Text("White").tag(true)
        }
        .pickerStyle(.segmented)

        if white {
          PillSlider(
            value: Binding(
              get: { (Double(look?.kelvin ?? 4000) - 2200) / 4300 },
              set: { room.setWhite(id, Int(2200 + $0 * 4300)) }
            ),
            track: AnyShapeStyle(LinearGradient(colors: [RGB.kelvin(2200).color, RGB.kelvin(4000).color, RGB.kelvin(6500).color],
                                                startPoint: .leading, endPoint: .trailing)),
            label: "\(look?.kelvin ?? 4000)K"
          )
          .frame(height: 56)
        } else {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
            ForEach(Self.swatches.indices, id: \.self) { i in
              let c = Self.swatches[i]
              Button { room.setColor(id, c) } label: {
                Circle()
                  .fill(c.color)
                  .frame(height: 44)
                  .overlay(Circle().strokeBorder(.white, lineWidth: look?.kelvin == nil && look?.color == c ? 2 : 0).padding(-4))
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Color \(i + 1)")
            }
            ColorPicker("Custom color", selection: $custom, supportsOpacity: false)
              .labelsHidden()
              .frame(height: 44)
              .onChange(of: custom) { _, new in
                let (r, g, b) = new.rgb
                room.setColor(id, RGB(r: r, g: g, b: b))
              }
          }
        }

        if hasStrip {
          VStack(alignment: .leading, spacing: 12) {
            SectionTitle(isAll ? "Strip effects" : "Effects")
            HStack(spacing: 12) {
              ForEach(Room.Effect.allCases, id: \.self) { e in
                Button { room.toggle(e) } label: {
                  HStack {
                    Image(systemName: e == .music ? "waveform" : "rainbow")
                    Text(e.rawValue)
                  }
                  .font(.subheadline.weight(.semibold))
                  .frame(maxWidth: .infinity, minHeight: 52)
                  .foregroundStyle(room.effect == e ? .black : Ink.text)
                  .background(Capsule().fill(room.effect == e ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.raised)))
                }
                .buttonStyle(.plain)
              }
            }
            if room.effect == .music {
              Capsule()
                .fill(Ink.raised)
                .overlay(alignment: .leading) {
                  GeometryReader { geo in
                    Capsule().fill(.white).frame(width: geo.size.width * room.level)
                  }
                }
                .frame(height: 6)
                .animation(.linear(duration: 0.05), value: room.level)
              Text("Listening through the mic. Play music near your phone.")
                .font(.footnote).foregroundStyle(Ink.dim)
            }
            if let error = room.effectError {
              Text(error).font(.footnote).foregroundStyle(Color(hex: 0xFF6B5E))
            }
          }
        }

        if !isAll, let look {
          footer(look)
        }
      }
      .padding(24)
    }
    .onAppear { white = look?.kelvin != nil }
    .alert("Rename", isPresented: $renaming) {
      TextField("Name", text: $newName)
      Button("Save") { room.rename(id, to: newName) }
      Button("Cancel", role: .cancel) {}
    }
  }

  private func footer(_ look: LightItem) -> some View {
    HStack {
      Button("Rename") {
        newName = look.name
        renaming = true
      }
      Spacer()
      Button(look.kind == .strip ? "Forget strip" : "Sign out", role: .destructive) {
        if look.kind == .strip {
          room.stopEffect()
          room.strip.disconnect()
        } else {
          room.hubspace.signOut()
        }
        dismiss()
      }
    }
    .font(.subheadline)
    .frame(minHeight: 44)
  }
}

// MARK: - Setup

private struct StripSetup: View {
  var strip: StripController
  @State private var showFar = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let near = strip.devices.filter { showFar || $0.rssi > -80 }
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Add your LED strip").font(.system(size: 28, weight: .bold, design: .rounded))
        Text("Close the DayBetter app first. Your strip is usually the top one, since it's closest.")
          .foregroundStyle(Ink.dim)
      }

      switch strip.state {
      case .connecting, .unlocking:
        HStack {
          ProgressView()
          Text("Connecting…").foregroundStyle(Ink.dim)
          Spacer()
          Button("Cancel") { strip.cancelConnecting() }.frame(minHeight: 44)
        }
      case .off:
        Text("Turn on Bluetooth.").foregroundStyle(Ink.dim)
      case .failed(let message):
        Text(message).foregroundStyle(Color(hex: 0xFF6B5E))
        Button("Try again") { strip.scan() }
      default:
        if near.isEmpty {
          HStack(spacing: 12) {
            ProgressView()
            Text("Looking for lights nearby…").foregroundStyle(Ink.dim)
          }
        }
        ScrollView {
          VStack(spacing: 0) {
            ForEach(near) { device in
              Button { strip.connect(device) } label: {
                HStack {
                  Text(device.name)
                  Spacer()
                  SignalBars(rssi: device.rssi)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              Divider().overlay(Ink.raised)
            }
          }
        }
        Toggle("Show far-away devices", isOn: $showFar)
          .font(.subheadline)
          .foregroundStyle(Ink.dim)
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .onAppear { if strip.state == .idle { strip.scan() } }
    .onChange(of: strip.state) { _, new in if new == .connected { dismiss() } }
  }
}

private struct SignalBars: View {
  let rssi: Int
  var body: some View {
    let bars = rssi > -60 ? 3 : rssi > -75 ? 2 : 1
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

private struct HubSetup: View {
  var hubspace: HubspaceClient
  @State private var email = ""
  @State private var password = ""
  @State private var code = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Add your smart bulb").font(.system(size: 28, weight: .bold, design: .rounded))
        Text("Sign in with your Hubspace account once. Your bulb then works from anywhere.")
          .foregroundStyle(Ink.dim)
      }

      switch hubspace.state {
      case .needsCode:
        Text("Hubspace emailed you a code.").foregroundStyle(Ink.dim)
        if let error = hubspace.commandError {
          Text(error).foregroundStyle(Color(hex: 0xFF6B5E)).font(.subheadline)
        }
        field("Code") {
          TextField("", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
        }
        primary("Continue", disabled: code.isEmpty) { await hubspace.submitCode(code) }
      case .signingIn, .loading:
        ProgressView().frame(maxWidth: .infinity, minHeight: 52)
      case .unavailable(let message):
        Text("Couldn't reach Hubspace: \(message)").foregroundStyle(Color(hex: 0xFF6B5E))
        primary("Try again", disabled: false) { await hubspace.load() }
      default:
        if case .loginFailed(let message) = hubspace.state {
          Text(message).foregroundStyle(Color(hex: 0xFF6B5E)).font(.subheadline)
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
      Spacer(minLength: 0)
    }
    .padding(24)
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

private struct ProjectorInfo: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "moon.stars")
        .font(.system(size: 36))
        .foregroundStyle(Ink.dim)
      Text("Galaxy projector").font(.system(size: 28, weight: .bold, design: .rounded))
      Text("The projector only listens to infrared, and iPhones don't have an IR blaster. A small ESP32 board with an IR LED (about $8) can act as a bridge: the app talks to it over Bluetooth, and it beams the remote's signals to the projector.")
        .foregroundStyle(Ink.dim)
      Text("Once the bridge is plugged in, this tile turns on.")
        .foregroundStyle(Ink.dim)
      Spacer(minLength: 0)
    }
    .padding(24)
    .presentationDetents([.medium])
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

  /// 0–255 components.
  var rgb: (Int, Int, Int) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
    let byte = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
    return (byte(r), byte(g), byte(b))
  }
}
