import ARKit
import Foundation
import Observation
import simd

/// Finds where each light is without a manual layout. The lights blink one at a time while you turn slowly
/// with the phone up. ARKit tracks which way the phone points, so every camera sample is filed by the world
/// direction it looks at; turning doesn't blur anything. The direction that brightens only while a light is on
/// is that light (its own glow, or the patch of wall or floor it lights). The same samples time how long each
/// light takes to react, so sweeps can send slow lights (cloud bulbs) early.
/// Method: blink-pattern identification (Philips patent US 9,313,863) plus visible-light positioning ideas.
@MainActor
@Observable
final class LightScanner: NSObject {
  enum Phase: Equatable { case ready, preparing, scanning, done, unsupported }

  struct Result {
    /// Radians clockwise from the direction the phone faced when the scan started.
    let yaw: Double
    /// Seconds from command to visible change.
    let latency: Double
  }

  private(set) var phase: Phase = ARWorldTrackingConfiguration.isSupported ? .ready : .unsupported
  /// Share of the circle seen with every light both on and off; the scan is good past about 0.7.
  private(set) var coverage = 0.0
  private(set) var results: [String: Result] = [:]
  private(set) var names: [String: String] = [:]
  let session = ARSession()

  private struct Target {
    let id: String
    /// Cloud bulbs need ~1.5 s to react plus a ~2 s fade.
    let slow: Bool
    var commands: [(t: Double, on: Bool)] = []
    var settle: Double { slow ? 3.8 : 0.4 }
  }

  private enum LightState { case on, off, changing }

  static let yawBins = 36
  static let pitchBins = 6
  static let binCount = yawBins * pitchBins

  private var targets: [Target] = []
  private weak var room: Room?
  private var schedule: Task<Void, Never>?
  private var lastT = 0.0
  private var onSum: [[Double]] = []
  private var onN: [[Int]] = []
  private var offSum = [Double](repeating: 0, count: binCount)
  private var offN = [Int](repeating: 0, count: binCount)
  private var samples: [(t: Double, bins: [UInt16], lumas: [UInt8])] = []

  func start(room: Room) {
    guard phase == .ready || phase == .done else { return }
    self.room = room
    let lights = room.scanTargets()
    targets = lights.map { Target(id: $0.id, slow: $0.kind == .bulb) }
    names = Dictionary(uniqueKeysWithValues: lights.map { ($0.id, $0.name) })
    guard !targets.isEmpty else { return }
    onSum = Array(repeating: Array(repeating: 0, count: Self.binCount), count: targets.count)
    onN = Array(repeating: Array(repeating: 0, count: Self.binCount), count: targets.count)
    offSum = Array(repeating: 0, count: Self.binCount)
    offN = Array(repeating: 0, count: Self.binCount)
    samples = []
    results = [:]
    coverage = 0
    phase = .preparing
    session.delegate = self
    session.run(ARWorldTrackingConfiguration(), options: [.resetTracking])

    schedule = Task { [weak self] in
      // Bright white makes the biggest change to look for; then everything off.
      room.scanPrepare()
      try? await Task.sleep(for: .seconds(1.5))
      guard let self, !Task.isCancelled else { return }
      for i in self.targets.indices { self.command(i, on: false) }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      self.phase = .scanning
      // One light at a time, round and round, until you tap Finish.
      while !Task.isCancelled {
        for i in self.targets.indices {
          let slow = self.targets[i].slow
          self.command(i, on: true)
          try? await Task.sleep(for: .seconds(slow ? 5.5 : 1.5))
          guard !Task.isCancelled else { return }
          self.command(i, on: false)
          try? await Task.sleep(for: .seconds(slow ? 4.2 : 1.0))
          guard !Task.isCancelled else { return }
        }
      }
    }
  }

  /// Ends the scan and keeps what was found; lights not seen are left for the room map.
  func finish() {
    guard phase == .scanning || phase == .preparing else { return }
    schedule?.cancel()
    session.pause()
    var found: [String: Result] = [:]
    for i in targets.indices {
      var best = -1
      var bestContrast = 0.0
      for b in 0..<Self.binCount where onN[i][b] >= 3 && offN[b] >= 3 {
        let contrast = onSum[i][b] / Double(onN[i][b]) - offSum[b] / Double(offN[b])
        if contrast > bestContrast { bestContrast = contrast; best = b }
      }
      // ponytail: 6 levels out of 255 separates a light from camera noise in a dim room; a bright room may need more.
      guard best >= 0, bestContrast >= 6 else { continue }
      let yawBin = best % Self.yawBins
      let yaw = (Double(yawBin) + 0.5) / Double(Self.yawBins) * 2 * .pi - .pi
      found[targets[i].id] = Result(yaw: yaw, latency: latency(of: i, bin: best, contrast: bestContrast))
    }
    results = found
    phase = .done
    room?.scanFinished(found)
  }

  func cancel() {
    let wasRunning = phase == .scanning || phase == .preparing
    schedule?.cancel()
    session.pause()
    if wasRunning { room?.scanRestore() }
    phase = ARWorldTrackingConfiguration.isSupported ? .ready : .unsupported
  }

  private func command(_ i: Int, on: Bool) {
    targets[i].commands.append((ProcessInfo.processInfo.systemUptime, on))
    room?.scanPower(targets[i].id, on)
  }

  private func state(_ target: Target, at t: Double) -> LightState {
    guard let last = target.commands.last(where: { $0.t <= t }) else { return .changing }
    if t - last.t < target.settle { return .changing }
    return last.on ? .on : .off
  }

  fileprivate func add(_ t: Double, _ bins: [UInt16], _ lumas: [UInt8]) {
    guard phase == .scanning, t - lastT > 0.08 else { return }
    lastT = t
    samples.append((t, bins, lumas))
    if samples.count > 4000 { samples.removeFirst(samples.count - 4000) }
    let states = targets.map { state($0, at: t) }
    // Only clean moments count: all off (baseline), or exactly one light fully on.
    if states.contains(.changing) { return }
    let lit = states.indices.filter { states[$0] == .on }
    if lit.isEmpty {
      for (b, l) in zip(bins, lumas) { offSum[Int(b)] += Double(l); offN[Int(b)] += 1 }
    } else if lit.count == 1 {
      let i = lit[0]
      for (b, l) in zip(bins, lumas) { onSum[i][Int(b)] += Double(l); onN[i][Int(b)] += 1 }
    }
    updateCoverage()
  }

  private func updateCoverage() {
    var covered = 0
    for y in 0..<Self.yawBins {
      let column = (0..<Self.pitchBins).map { $0 * Self.yawBins + y }
      let baseline = column.contains { offN[$0] >= 3 }
      let everyLight = onN.allSatisfy { counts in column.contains { counts[$0] >= 3 } }
      if baseline && everyLight { covered += 1 }
    }
    coverage = Double(covered) / Double(Self.yawBins)
  }

  /// Median time from an "on" command until the light's direction got halfway to its full brightness.
  private func latency(of i: Int, bin: Int, contrast: Double) -> Double {
    let fallback = targets[i].slow ? 1.5 : 0.15
    var delays: [Double] = []
    for c in targets[i].commands where c.on {
      let window = samples.compactMap { s -> (t: Double, l: Double)? in
        guard s.t > c.t - 1, s.t < c.t + 6, let k = s.bins.firstIndex(of: UInt16(bin)) else { return nil }
        return (s.t, Double(s.lumas[k]))
      }
      let before = window.filter { $0.t < c.t }.map(\.l)
      guard !before.isEmpty else { continue }
      let base = before.reduce(0, +) / Double(before.count)
      if let hit = window.first(where: { $0.t >= c.t && $0.l >= base + contrast / 2 }) { delays.append(hit.t - c.t) }
    }
    guard !delays.isEmpty else { return fallback }
    return delays.sorted()[delays.count / 2]
  }

  /// A 24 x 18 grid of brightness samples from the camera's luma plane, each filed by the world direction it sees.
  nonisolated fileprivate static func sample(_ frame: ARFrame) -> (Double, [UInt16], [UInt8])? {
    guard case .normal = frame.camera.trackingState else { return nil }
    let buffer = frame.capturedImage
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let k = frame.camera.intrinsics
    let fx = k[0][0], fy = k[1][1], cx = k[2][0], cy = k[2][1]
    let transform = frame.camera.transform
    var bins: [UInt16] = []
    var lumas: [UInt8] = []
    bins.reserveCapacity(432)
    lumas.reserveCapacity(432)
    for gy in 0..<18 {
      for gx in 0..<24 {
        let u = min(w - 3, max(2, Int((Double(gx) + 0.5) / 24 * Double(w))))
        let v = min(h - 3, max(2, Int((Double(gy) + 0.5) / 18 * Double(h))))
        var sum = 0
        for dy in -1...1 { for dx in -1...1 { sum += Int(pixels[(v + dy * 2) * row + u + dx * 2]) } }
        // Camera space: x right, y up, looking down -z (image v grows downward).
        let ray = transform * simd_float4((Float(u) - cx) / fx, -(Float(v) - cy) / fy, -1, 0)
        let dir = simd_normalize(simd_float3(ray.x, ray.y, ray.z))
        let pitch = Double(asin(dir.y))
        guard abs(pitch) < .pi / 3 else { continue }
        let yaw = Double(atan2(dir.x, -dir.z))
        let yb = Int((yaw + .pi) / (2 * .pi) * Double(yawBins)) % yawBins
        let pb = min(pitchBins - 1, max(0, Int((pitch + .pi / 3) / (2 * .pi / 3) * Double(pitchBins))))
        bins.append(UInt16(pb * yawBins + yb))
        lumas.append(UInt8(sum / 9))
      }
    }
    return (frame.timestamp, bins, lumas)
  }
}

extension LightScanner: ARSessionDelegate {
  nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard let (t, bins, lumas) = Self.sample(frame) else { return }
    Task { @MainActor in self.add(t, bins, lumas) }
  }
}
