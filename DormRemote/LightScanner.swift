import ARKit
import AVFoundation
import Foundation
import Observation
import simd

/// "Find my lights", done the way Hue's SpatialAware does it (Philips Hue support article 000017, 2026): one light
/// blinks at a time, you aim the circle at it, and the app pins it down. ARKit tracks where the phone is and where it
/// points, so an aim is a ray through the room. On an iPhone with LiDAR the ray meets the room's mesh at the light; on
/// others, a second aim from a big step to the side crosses the first one at the light.
///
/// The app also watches the middle of the camera: when the blink shows up in the circle it locks on by itself, so
/// you rarely need the button. Exposure is locked first (ARKit 6 exposes the camera for that), so a light switching
/// on can't make the camera darken everything else. The same samples time how long each light takes to react, so
/// sweeps can send slow lights (the cloud bulb) early.
@MainActor
@Observable
final class LightScanner: NSObject {
  enum Phase: Equatable { case ready, preparing, aiming, secondAim, done, unsupported }

  struct Result {
    /// Meters from where you started: x right, y toward the back of the room (the way you first faced is up).
    let x: Double
    let y: Double
    /// Seconds from command to visible change.
    let latency: Double
  }

  private(set) var phase: Phase = ARWorldTrackingConfiguration.isSupported ? .ready : .unsupported
  private(set) var order: [String] = []
  private(set) var names: [String: String] = [:]
  private(set) var index = 0
  /// 0–1: how clearly the blink shows in the circle right now.
  private(set) var lock = 0.0
  private(set) var results: [String: Result] = [:]
  /// A tip when an aim didn't work out.
  private(set) var hint: String?
  /// Second aim: how far you've stepped from the first one, in meters.
  var stepAside: Double {
    guard phase == .secondAim, let a = firstAim?.origin, let b = pose?.origin else { return 0 }
    return Double(simd_distance(a, b))
  }
  /// LiDAR: one aim per light is enough.
  let oneAim = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
  let session = ARSession()

  var current: String? { order.indices.contains(index) ? order[index] : nil }
  var currentName: String { current.flatMap { names[$0] } ?? "" }

  private struct Sample {
    let t: Double
    let level: Double
    let forward: simd_float3
  }

  private typealias Ray = (origin: simd_float3, direction: simd_float3)

  /// Lights you skipped this round.
  private var passed: Set<String> = []
  private var samples: [Sample] = []
  private var pose: Ray?
  private var lastT = 0.0
  private var commands: [(t: Double, on: Bool)] = []
  private var slow: Set<String> = []
  private var firstAim: Ray?
  private var firstLatency: Double?
  private var contrast = 0.0
  private var baseline = 0.0
  private weak var room: Room?
  private var blinker: Task<Void, Never>?
  private var exposureLocked = false

  /// Luma levels (of 255) between the light on and off in the circle that count as seeing it.
  /// ponytail: 18 is plenty for a bulb or strip in view with exposure locked; a light that only washes a far wall in a
  /// bright room may stay under it, which is what the "It's here" button is for.
  private static let lockContrast = 18.0

  /// Finds the lights in the order you picked; lights you didn't pick come after, in list order.
  func start(room: Room, order picked: [String] = []) {
    guard phase == .ready || phase == .done else { return }
    let lights = room.scanTargets()
    guard !lights.isEmpty else { return }
    self.room = room
    let ids = lights.map(\.id)
    order = picked.filter(ids.contains) + ids.filter { !picked.contains($0) }
    names = Dictionary(uniqueKeysWithValues: lights.map { ($0.id, $0.name) })
    slow = Set(lights.filter { $0.kind == .bulb }.map(\.id))
    results = [:]
    passed = []
    index = 0
    hint = nil
    firstAim = nil
    phase = .preparing
    session.delegate = self
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    if oneAim { config.sceneReconstruction = .mesh }
    session.run(config, options: [.resetTracking, .removeExistingAnchors])

    blinker = Task { [weak self] in
      // Bright white everywhere: the exposure is set for lit lights, so a blink stands out instead of blowing out.
      room.scanPrepare()
      try? await Task.sleep(for: .seconds(2))
      guard let self, !Task.isCancelled else { return }
      self.lockExposure()
      for id in self.order { room.scanPower(id, false) }
      try? await Task.sleep(for: .seconds(self.slow.isEmpty ? 1 : 3))
      guard !Task.isCancelled else { return }
      self.phase = .aiming
      self.blink()
    }
  }

  /// Pins the current light where the circle points. "It's here" calls this; so does a clear lock.
  func capture() {
    guard let id = current, let aim = pose else { return }
    switch phase {
    case .aiming:
      let latency = measuredLatency()
      if oneAim, let hit = surface(aim) {
        record(id, hit, latency)
        return next()
      }
      firstAim = aim
      firstLatency = latency
      hint = nil
      phase = .secondAim
      resetLock()
    case .secondAim:
      guard let first = firstAim else { return }
      guard let point = Self.crossing(first, aim) ?? (oneAim ? surface(aim) : nil) else {
        hint = "Those two aims are too close together. Take a bigger step to the side, then aim again."
        resetLock()
        return
      }
      record(id, point, firstLatency ?? measuredLatency())
      next()
    default: break
    }
  }

  /// Leaves this light for later (or for the room map).
  func skip() {
    if let id = current { passed.insert(id) }
    next()
  }

  /// Finds this light now instead, out of order. Also redoes one that's already found.
  func pick(_ id: String) {
    guard phase == .aiming || phase == .secondAim || phase == .done, let i = order.firstIndex(of: id) else { return }
    blinker?.cancel()
    if let old = current, old != id { room?.scanPower(old, false) }
    if phase == .done {
      // Back from the results: the lights are restored, so set them up for scanning again.
      room?.scanPrepare()
      for other in order where other != id { room?.scanPower(other, false) }
      session.run(session.configuration ?? ARWorldTrackingConfiguration())
      lockExposure()
    }
    passed.remove(id)
    index = i
    firstAim = nil
    firstLatency = nil
    hint = nil
    phase = .aiming
    blink()
  }

  /// Ends the scan and keeps what was found; lights not found are left for the room map.
  func finish() {
    guard phase != .done, phase != .ready, phase != .unsupported else { return }
    blinker?.cancel()
    if let id = current { room?.scanPower(id, false) }
    session.pause()
    unlockExposure()
    phase = .done
    room?.scanFinished(results)
  }

  func cancel() {
    let wasRunning = phase == .aiming || phase == .secondAim || phase == .preparing
    blinker?.cancel()
    session.pause()
    unlockExposure()
    if wasRunning { room?.scanRestore() }
    phase = ARWorldTrackingConfiguration.isSupported ? .ready : .unsupported
  }

  // MARK: Steps

  /// The current light blinks until it's found: quick for Bluetooth lights, slow for the cloud bulb (it takes about
  /// a second and a half to react, then fades).
  private func blink() {
    blinker?.cancel()
    guard let id = current else { return finish() }
    resetLock()
    commands = []
    let period = slow.contains(id) ? 3.5 : 0.8
    blinker = Task { [weak self] in
      var on = true
      while !Task.isCancelled {
        guard let self else { return }
        self.commands.append((ProcessInfo.processInfo.systemUptime, on))
        self.room?.scanPower(id, on)
        try? await Task.sleep(for: .seconds(period))
        on.toggle()
      }
    }
  }

  /// On to the next light in your order that isn't found or skipped yet; done when there's none.
  private func next() {
    blinker?.cancel()
    if let id = current { room?.scanPower(id, false) }
    firstAim = nil
    firstLatency = nil
    hint = nil
    let open = { (i: Int) in self.results[self.order[i]] == nil && !self.passed.contains(self.order[i]) }
    guard let i = (order.indices.filter { $0 > index } + order.indices.filter { $0 <= index }).first(where: open) else {
      index = order.count
      return finish()
    }
    index = i
    phase = .aiming
    blink()
  }

  private func record(_ id: String, _ p: simd_float3, _ latency: Double?) {
    // ARKit's world: -z is the way the phone first faced, which is up on the map; +z is toward the back.
    results[id] = Result(x: Double(p.x), y: Double(p.z), latency: latency ?? (slow.contains(id) ? 1.5 : 0.15))
  }

  private func resetLock() {
    samples = []
    lock = 0
    contrast = 0
  }

  // MARK: Seeing the blink

  fileprivate func add(_ t: Double, _ center: Double, _ whole: Double, _ forward: simd_float3, _ origin: simd_float3) {
    pose = (origin, forward)
    guard phase == .aiming || phase == .secondAim, let id = current, t - lastT > 0.03 else { return }
    lastT = t
    // Without the exposure lock, the frame's own brightness stands in for it.
    let level = exposureLocked ? center : center - whole * 0.6
    samples.append(Sample(t: t, level: level, forward: forward))
    let window = slow.contains(id) ? 16.0 : 5.0
    samples.removeAll { $0.t < t - window }
    updateLock(slowLight: slow.contains(id), forward: forward)
  }

  /// On or off at time `t`, once the light has had time to react; nil while it's changing.
  private func state(at t: Double, settle: Double) -> Bool? {
    guard let last = commands.last(where: { $0.t <= t - settle }) else { return nil }
    if commands.contains(where: { $0.t > t - settle && $0.t <= t }) { return nil }
    return last.on
  }

  private func updateLock(slowLight: Bool, forward: simd_float3) {
    // Only samples aimed where you're aiming now (within about 8°) count.
    let aimed = samples.filter { simd_dot($0.forward, forward) > 0.99 }
    let settle = slowLight ? (room?.hubspace.expectedDelay ?? 1.5) + 0.6 : 0.25
    var on: [Double] = [], off: [Double] = []
    for s in aimed {
      switch state(at: s.t, settle: settle) {
      case true?: on.append(s.level)
      case false?: off.append(s.level)
      case nil: break
      }
    }
    guard on.count >= 3, off.count >= 3, let first = aimed.first?.t, let last = aimed.last?.t else {
      lock = max(0, lock - 0.05)
      return
    }
    baseline = off.reduce(0, +) / Double(off.count)
    contrast = on.reduce(0, +) / Double(on.count) - baseline
    // Seen switching on at least twice (once for the slow bulb) while aimed here, so a passing glare isn't a light.
    let cycles = commands.filter { $0.on && $0.t >= first && $0.t <= last }.count
    let needed = slowLight ? 1 : 2
    lock = min(1, max(0, contrast / Self.lockContrast)) * (cycles >= needed ? 1 : 0.8)
    // The second aim waits until you've actually stepped aside (40 cm), or it would cross the first one at no angle.
    let stepped = phase != .secondAim || simd_distance(pose?.origin ?? .zero, firstAim?.origin ?? .zero) > 0.4
    if contrast >= Self.lockContrast, cycles >= needed, stepped { capture() }
  }

  /// Median time from an "on" command until the circle got halfway to its lit level.
  private func measuredLatency() -> Double? {
    guard contrast >= Self.lockContrast / 2 else { return nil }
    var delays: [Double] = []
    for c in commands where c.on {
      if let hit = samples.first(where: { $0.t >= c.t && $0.t < c.t + 6 && $0.level >= baseline + contrast / 2 }) {
        delays.append(hit.t - c.t)
      }
    }
    guard !delays.isEmpty else { return nil }
    return delays.sorted()[delays.count / 2]
  }

  // MARK: Where the aim lands

  /// Where the ray meets the room's surfaces, if ARKit has mapped them there. Nil past 8 m or closer than 30 cm.
  private func surface(_ aim: Ray) -> simd_float3? {
    let query = ARRaycastQuery(origin: aim.origin, direction: aim.direction, allowing: .estimatedPlane, alignment: .any)
    guard let hit = session.raycast(query).first else { return nil }
    let p = simd_make_float3(hit.worldTransform.columns.3)
    let d = simd_distance(p, aim.origin)
    return d > 0.3 && d < 8 ? p : nil
  }

  /// Where two aims at the same light cross: the midpoint of their closest approach. Nil when they're nearly parallel
  /// (under about 3° apart, too small a step to tell distance) or meet behind you.
  static func crossing(_ a: (origin: simd_float3, direction: simd_float3), _ b: (origin: simd_float3, direction: simd_float3)) -> simd_float3? {
    let d1 = simd_normalize(a.direction), d2 = simd_normalize(b.direction)
    let w = a.origin - b.origin
    let aa = simd_dot(d1, d1), bb = simd_dot(d1, d2), cc = simd_dot(d2, d2)
    let dd = simd_dot(d1, w), ee = simd_dot(d2, w)
    let denom = aa * cc - bb * bb
    guard denom > 0.0025 else { return nil }
    let s = (bb * ee - cc * dd) / denom
    let t = (aa * ee - bb * dd) / denom
    guard s > 0.3, t > 0.3, s < 10, t < 10 else { return nil }
    return ((a.origin + d1 * s) + (b.origin + d2 * t)) / 2
  }

  // MARK: Camera

  private func lockExposure() {
    guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
          device.isExposureModeSupported(.locked), (try? device.lockForConfiguration()) != nil else { return }
    device.exposureMode = .locked
    device.unlockForConfiguration()
    exposureLocked = true
  }

  private func unlockExposure() {
    guard exposureLocked else { return }
    exposureLocked = false
    guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
          device.isExposureModeSupported(.continuousAutoExposure), (try? device.lockForConfiguration()) != nil else { return }
    device.exposureMode = .continuousAutoExposure
    device.unlockForConfiguration()
  }

  /// The average brightness in the middle of the picture (the circle on screen) and across the whole picture,
  /// plus where the camera is and points.
  nonisolated fileprivate static func measure(_ frame: ARFrame) -> (Double, Double, Double, simd_float3, simd_float3)? {
    guard case .normal = frame.camera.trackingState else { return nil }
    let buffer = frame.capturedImage
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    var whole = 0
    for gy in 0..<24 {
      for gx in 0..<32 { whole += Int(pixels[((gy * 2 + 1) * h / 48) * row + (gx * 2 + 1) * w / 64]) }
    }
    // The circle: a tenth of the short side around the middle, which is a fifth of the screen's width.
    let r = min(w, h) / 10
    let step = max(1, r / 8)
    var center = 0, n = 0
    for dy in stride(from: -r, through: r, by: step) {
      for dx in stride(from: -r, through: r, by: step) where dx * dx + dy * dy <= r * r {
        center += Int(pixels[(h / 2 + dy) * row + w / 2 + dx])
        n += 1
      }
    }
    let m = frame.camera.transform
    let forward = -simd_normalize(simd_make_float3(m.columns.2))
    let origin = simd_make_float3(m.columns.3)
    return (frame.timestamp, Double(center) / Double(max(1, n)), Double(whole) / 768, forward, origin)
  }
}

extension LightScanner: ARSessionDelegate {
  nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard let (t, center, whole, forward, origin) = Self.measure(frame) else { return }
    // The session calls its delegate on the main queue (no delegateQueue is set).
    MainActor.assumeIsolated { self.add(t, center, whole, forward, origin) }
  }
}
