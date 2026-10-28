import Foundation
import Observation

/// Walk in: the room lights up when you get back, with your strips' Bluetooth as the sensor.
///
/// GPS can't tell your door from the building: iOS geofences are good to about 200 m and only report a crossing
/// after you've moved past it and stayed 20 s. Bluetooth reaches about your hallway. The app already keeps a
/// pending connect to every strip, and iOS wakes it when one comes back in range (Apple TN3115), so:
/// away 10+ minutes, then a strip reconnects → lights on. "Set my spot" records the strip's signal at your door,
/// and arrival waits for at least that signal. If iOS won't read the signal in the background, the lights come on
/// at reconnect instead of leaving you in the dark.
///
/// There's no walk out: once you're out of range the app can't reach the strips to turn them off.
@MainActor
@Observable
final class WalkIn {
  /// How long every strip has to be out of range before a return counts as coming home.
  static let away: TimeInterval = 10 * 60
  /// How long arrival waits for you to reach your spot before giving up (walking past, not in).
  static let spotWait: TimeInterval = 3 * 60

  var enabled = UserDefaults.standard.bool(forKey: "walkIn") {
    didSet { UserDefaults.standard.set(enabled, forKey: "walkIn") }
  }
  /// The scene to play; nil turns the lights on the way they were.
  var sceneID = UserDefaults.standard.string(forKey: "walkInScene") {
    didSet { UserDefaults.standard.set(sceneID, forKey: "walkInScene") }
  }
  /// Signal strength (dBm) at your door. Nil: light up as soon as a strip is back.
  private(set) var spot = UserDefaults.standard.object(forKey: "walkInSpot") as? Int {
    didSet { UserDefaults.standard.set(spot, forKey: "walkInSpot") }
  }
  private(set) var lastArrival = UserDefaults.standard.object(forKey: "walkInLast") as? Date {
    didSet { UserDefaults.standard.set(lastArrival, forKey: "walkInLast") }
  }
  private(set) var measuring = false
  var spotError: String?

  /// When the last strip went out of range. Saved, since iOS may relaunch the app between leaving and coming back.
  private var awaySince = UserDefaults.standard.object(forKey: "walkInAway") as? Date {
    didSet { UserDefaults.standard.set(awaySince, forKey: "walkInAway") }
  }

  weak var room: Room?

  private var connected: [Strip] { room?.strip.strips.filter { $0.state == .connected } ?? [] }

  func stripDropped() {
    guard connected.isEmpty, awaySince == nil else { return }
    awaySince = Date()
  }

  func stripConnected(_ id: UUID) {
    guard let since = awaySince else { return }
    awaySince = nil
    // A blip (strip unplugged a moment, or you stepped out briefly) isn't coming home.
    guard enabled, Date().timeIntervalSince(since) >= Self.away else { return }
    if let spot { waitForSpot(id, spot, until: Date().addingTimeInterval(Self.spotWait)) } else { arrive(id) }
  }

  private func waitForSpot(_ id: UUID, _ spot: Int, until deadline: Date) {
    room?.strip.readRSSI(id) { [weak self] rssi in
      guard let self else { return }
      MainActor.assumeIsolated {
        guard let rssi else {
          // No reading: the strip dropped again (walked past), or iOS won't read in the background.
          if self.room?.strip.strips.first(where: { $0.id == id })?.state == .connected { self.arrive(id) }
          return
        }
        if rssi >= spot {
          self.arrive(id)
        } else if Date() < deadline {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.waitForSpot(id, spot, until: deadline) } }
        }
      }
    }
  }

  private func arrive(_ id: UUID) {
    guard let room else { return }
    // Light the room this strip is in.
    if let item = room.item(Room.stripItemID(id)) { room.selectedRoom = room.roomOf(item) }
    if let sceneID, let mood = room.moods.first(where: { $0.id == sceneID }) {
      room.apply(mood)
    } else {
      room.setPower(Room.all, true)
    }
    lastArrival = Date()
  }

  /// Stand at your door and call this: averages a few readings from the nearest connected strip.
  func setSpot() {
    guard let room, let strip = connected.first(where: { s in
      room.item(Room.stripItemID(s.id)).map { room.roomOf($0) == room.currentRoom } ?? false
    }) ?? connected.first else {
      spotError = "No strip is connected right now. Step a little closer and try again."
      return
    }
    spotError = nil
    measuring = true
    var readings: [Int] = []
    func next(_ left: Int) {
      room.strip.readRSSI(strip.id) { [weak self] rssi in
        MainActor.assumeIsolated {
          guard let self else { return }
          if let rssi { readings.append(rssi) }
          if left > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { next(left - 1) } }
            return
          }
          self.measuring = false
          guard !readings.isEmpty else {
            self.spotError = "Couldn't read the strip's signal. Try again."
            return
          }
          // A little slack, so standing a step further back still counts.
          self.spot = readings.reduce(0, +) / readings.count - 4
        }
      }
    }
    next(6)
  }

  func clearSpot() { spot = nil }
}
