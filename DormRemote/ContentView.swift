import SwiftUI
import UIKit

struct ContentView: View {
  @Bindable var strip: StripController
  @State private var color = Color(red: 0.49, green: 0.36, blue: 1)
  @State private var brightness = 100.0
  @State private var showLog = false

  private let presets: [Color] = [
    .init(hex: 0xFF0000), .init(hex: 0xFF7A00), .init(hex: 0xFFE600), .init(hex: 0x00FF3C),
    .init(hex: 0x00C8FF), .init(hex: 0x0030FF), .init(hex: 0x8A00FF), .init(hex: 0xFF00B4),
    .init(hex: 0xFF3060), .init(hex: 0x00FFA2), .init(hex: 0xFFFFFF), .init(hex: 0xFFB070),
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Dorm\nRemote")
            .font(.system(size: 44, weight: .heavy, design: .rounded))
            .foregroundStyle(LinearGradient(colors: [.white, color], startPoint: .topLeading, endPoint: .bottomTrailing))

          stripCard
        }
        .padding(16)
      }
      .background(Color(hex: 0x0B0B0F).ignoresSafeArea())
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Log") { showLog = true }
        }
      }
      .sheet(isPresented: $showLog) { LogView(lines: strip.log) }
    }
  }

  private var stripCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Daybetter strip").font(.title3.bold())
        Spacer()
        statusPill
      }

      switch strip.state {
      case .connected:
        controls
        Button("Disconnect", role: .destructive) { strip.disconnect() }
          .font(.subheadline)
      case .off:
        Text("Turn on Bluetooth to find your strip.").foregroundStyle(.secondary)
      case .connecting:
        ProgressView("Connecting…")
      case .failed(let message):
        Text(message).foregroundStyle(.red)
        Button("Scan again") { strip.scan() }.buttonStyle(.bordered)
      case .idle, .scanning:
        picker
      }
    }
    .padding(24)
    .background(Color(hex: 0x16161D), in: RoundedRectangle(cornerRadius: 24))
    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(hex: 0x2A2A35)))
  }

  private var statusPill: some View {
    let (text, tint): (String, Color) = switch strip.state {
    case .connected: (strip.connectedName ?? "Connected", .green)
    case .connecting: ("Connecting", .orange)
    case .scanning: ("Scanning", .orange)
    case .failed: ("Error", .red)
    case .off: ("Bluetooth off", .gray)
    case .idle: ("Not connected", .gray)
    }
    return Label(text, systemImage: "circle.fill")
      .font(.caption)
      .labelStyle(PillLabel(tint: tint))
  }

  private var picker: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Close the DayBetter app first. The strip takes one Bluetooth connection at a time. Tap your strip below; the closest devices are at the top.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if strip.devices.isEmpty {
        ProgressView().frame(maxWidth: .infinity)
      }
      ForEach(strip.devices) { device in
        Button {
          strip.connect(device)
        } label: {
          HStack {
            Text(device.name)
            Spacer()
            Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
          }
          .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        Divider()
      }
      if strip.state == .idle {
        Button("Scan") { strip.scan() }.buttonStyle(.bordered)
      }
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        Button { strip.setPower(true) } label: { Text("On").frame(maxWidth: .infinity, minHeight: 44) }
          .buttonStyle(.borderedProminent)
          .tint(color)
        Button { strip.setPower(false) } label: { Text("Off").frame(maxWidth: .infinity, minHeight: 44) }
          .buttonStyle(.bordered)
      }

      ColorPicker("Color", selection: $color, supportsOpacity: false)
        .onChange(of: color) { _, new in send(new) }

      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
        ForEach(presets.indices, id: \.self) { i in
          Button {
            color = presets[i]
          } label: {
            RoundedRectangle(cornerRadius: 12).fill(presets[i]).frame(height: 44)
          }
          .accessibilityLabel("Preset color \(i + 1)")
        }
      }

      VStack(alignment: .leading) {
        Text("Brightness \(Int(brightness))%").font(.subheadline).foregroundStyle(.secondary)
        Slider(value: $brightness, in: 1...100, step: 1)
          .tint(color)
          .onChange(of: brightness) { _, new in strip.setBrightness(Int(new)) }
      }
    }
  }

  private func send(_ c: Color) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
    let byte = { (v: CGFloat) in UInt8((max(0, min(1, v)) * 255).rounded()) }
    strip.setColor(r: byte(r), g: byte(g), b: byte(b))
  }
}

private struct PillLabel: LabelStyle {
  let tint: Color
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.font(.system(size: 6)).foregroundStyle(tint)
      configuration.title.foregroundStyle(.secondary)
    }
  }
}

private struct LogView: View {
  let lines: [String]
  @Environment(\.dismiss) private var dismiss

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
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          ShareLink(item: lines.joined(separator: "\n"))
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
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
