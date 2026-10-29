import CoreLocation
import Foundation
import Observation
import UIKit

/// Walk in: the room lights up when you get back, with your strips' Bluetooth as the sensor.
///
/// GPS can't tell your door from the building: iOS geofences are good to about 200 m and only report a crossing
/// after you've moved past it and stayed 20 s. Bluetooth reaches about your hallway. The app already keeps a
/// pending connect to every strip, and iOS wakes it when one comes back in range (Apple TN3115), so:
/// away long enough, then a strip reconnects → lights on. "Set my spot" records the strip's signal at your door,
/// and arrival waits for at least that signal. If iOS won't read the signal in the background, the lights come on
/// at reconnect instead of leaving you in the dark.
///
/// The room beacon: the IR bridge also advertises as an iBeacon (firmware/src/main.cpp). iOS watches for it even
/// when the app was swiped away and relaunches the app as you come into range, then again about 30 s after you
/// leave it. That's the one signal that knows your room rather than your building, so it's the main sensor when the
/// bridge is plugged in: in range → coming in, out of range → leaving. While you walk in, the app ranges the beacon
/// once a second (iOS allows that in the background while location updates run, which they do only for those few
/// minutes) and waits for the signal you recorded at your door.
///
/// Two gaps in the strip-only version, and their fixes:
/// - Swiping the app away stops iOS from relaunching it for Bluetooth (Apple QA1962). Region monitoring is the one
///   wake-up that survives a swipe (Apple DTS on the developer forums), so the optional location backup watches a
///   circle around home: crossing it relaunches the app, which re-arms the Bluetooth connects before you're in range.
///   Leaving the circle also counts as being away, for when your strips never quite dropped.
/// - Lights connect at different moments (the bulb loads from the cloud, a second strip is a wall further), so for
///   a minute and a half after the welcome, any light in the room that turns up late gets it too.
///
/// There's no walk out for the strips: once you're out of range the app can't reach them. The cloud bulb can still be
/// turned off from anywhere, so that's an option.
@MainActor
@Observable
final class WalkIn: NSObject {
  static let awayChoices = [5, 10, 20, 30]
  /// How long arrival waits for you to reach your spot before giving up (walking past, not in).
  static let spotWait: TimeInterval = 3 * 60
  /// Lights that connect this long after the welcome still get it.
  static let lateWindow: TimeInterval = 90
  /// The location backup's circle. iOS wants at least about 100 m to be reliable; 150 m covers a dorm building.
  static let homeRadius: CLLocationDistance = 150
  private static let regionID = "walkInHome"
  /// The bridge's iBeacon (same UUID as the firmware).
  static let beaconUUID = UUID(uuidString: "D0A1E7B2-6F2C-4C8B-9E31-5B7A0C1D2E3F")!
  private static let beaconID = "walkInRoom"
  private static var beacon: CLBeaconIdentityConstraint { CLBeaconIdentityConstraint(uuid: beaconUUID) }

  var enabled = UserDefaults.standard.bool(forKey: "walkIn") {
    didSet {
      UserDefaults.standard.set(enabled, forKey: "walkIn")
      updateGeofence()
      updateWatch()
    }
  }
  /// The scene to play; nil turns the lights on the way they were.
  var sceneID = UserDefaults.standard.string(forKey: "walkInScene") {
    didSet { UserDefaults.standard.set(sceneID, forKey: "walkInScene") }
  }
  /// How long you have to be gone for a return to count as coming home.
  var awayMinutes = UserDefaults.standard.object(forKey: "walkInAwayMinutes") as? Int ?? 10 {
    didSet { UserDefaults.standard.set(awayMinutes, forKey: "walkInAwayMinutes") }
  }
  /// Walk out: when you leave, every light turns off at the same moment.
  var offWhenLeaving = UserDefaults.standard.bool(forKey: "walkInOffWhenLeaving") {
    didSet {
      UserDefaults.standard.set(offWhenLeaving, forKey: "walkInOffWhenLeaving")
      updateWatch()
    }
  }
  /// Your zones from the guided setup: the bridge's signal from your phone in the room, in the doorway, and outside
  /// in the hall (dBm). The bridge's engine turns them into "you left" and "you came in" (firmware/src/main.cpp).
  private(set) var zones: [Int]? = (UserDefaults.standard.array(forKey: "walkInZones") as? [Int]).flatMap { $0.count == 3 ? $0 : nil } {
    didSet {
      UserDefaults.standard.set(zones, forKey: "walkInZones")
      updateWatch()
    }
  }
  /// Setup in progress: each zone's reading as it's measured (room, doorway, hall), and which one is being measured.
  private(set) var zoneReadings: [Int?] = [nil, nil, nil]
  private(set) var measuringZone: Int?
  var zoneError: String?
  /// Coming back with a door spot set: wait for the bridge to see you reach it, until then.
  private var doorWait: Date?
  /// Location: the room beacon and the circle around home. Both need "Always" so iOS can wake the app.
  var useLocation = UserDefaults.standard.bool(forKey: "walkInLocation") {
    didSet {
      UserDefaults.standard.set(useLocation, forKey: "walkInLocation")
      if useLocation, home == nil { setHomeHere() } else { updateGeofence() }
    }
  }
  /// Beacon signal (dBm) at your door. Nil: light up as soon as the beacon is seen.
  private(set) var beaconSpot = UserDefaults.standard.object(forKey: "walkInBeaconSpot") as? Int {
    didSet { UserDefaults.standard.set(beaconSpot, forKey: "walkInBeaconSpot") }
  }
  /// Whether iOS last placed you inside the beacon's range; nil until it has said either way.
  private(set) var nearBeacon: Bool?
  /// The latest beacon reading while ranging, for the screen.
  private(set) var beaconRSSI: Int?
  /// Location is set to Always. With only While Using, iOS can't wake the app for the beacon or the circle.
  private(set) var locationAlways = false
  /// Signal strength (dBm) at your door. Nil: light up as soon as a strip is back.
  private(set) var spot = UserDefaults.standard.object(forKey: "walkInSpot") as? Int {
    didSet { UserDefaults.standard.set(spot, forKey: "walkInSpot") }
  }
  private(set) var lastArrival = UserDefaults.standard.object(forKey: "walkInLast") as? Date {
    didSet { UserDefaults.standard.set(lastArrival, forKey: "walkInLast") }
  }
  private(set) var home: CLLocationCoordinate2D? = {
    let saved = UserDefaults.standard.array(forKey: "walkInHome") as? [Double] ?? []
    return saved.count == 2 ? CLLocationCoordinate2D(latitude: saved[0], longitude: saved[1]) : nil
  }() {
    didSet { UserDefaults.standard.set(home.map { [$0.latitude, $0.longitude] }, forKey: "walkInHome") }
  }
  private(set) var measuring = false
  private(set) var locating = false
  var spotError: String?
  var locationError: String?

  struct Event: Codable, Identifiable, Equatable {
    let time: Date
    let text: String
    var id: Date { time }
  }

  /// What happened lately, newest first, so you can see why it did or didn't light up.
  private(set) var events: [Event] = {
    guard let data = UserDefaults.standard.data(forKey: "walkInEvents") else { return [] }
    return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
  }()

  /// When you left. Saved, since iOS may relaunch the app between leaving and coming back.
  /// Away since leaving, until you're back: "Away" or "You're home" on the Room tab.
  var isAway: Bool { awaySince != nil }
  /// When you left, while you're away.
  var awayDate: Date? { awaySince }

  private var awaySince = UserDefaults.standard.object(forKey: "walkInAway") as? Date {
    didSet { UserDefaults.standard.set(awaySince, forKey: "walkInAway") }
  }
  private var arrivedAt: Date?
  /// While walking in with a beacon spot set: the signal to reach and when to give up.
  private var rangeTarget: (spot: Int, until: Date)?
  /// When ranging for arrival started, whether the beacon has been heard since, and the strip that brought you in.
  /// A bridge that's unplugged or out of power is never heard, and Walk in then falls back to the strips.
  private var rangeStarted = Date.distantPast
  private var rangeHeard = false
  private var rangeStrip: UUID?
  /// The last ranging callback. iOS 18 can stop ranging while the screen is off (Apple developer forums); the app
  /// keeps running then (location updates), so a watchdog notices the silence.
  private var lastRanged = Date.distantPast
  /// Readings collected by Set my spot.
  private var spotReadings: [Int]?
  /// Lights already welcomed this time, so a late one is lit once and a light you switch off stays off.
  private var welcomed: Set<String> = []
  private var background: UIBackgroundTaskIdentifier = .invalid
  private let location = CLLocationManager()

  weak var room: Room? {
    didSet {
      room?.bridge.onPresence = { [weak self] arrived, rssi, margin in
        MainActor.assumeIsolated { self?.bridgeSaw(arrived: arrived, rssi: rssi, margin: margin) }
      }
      room?.bridge.onLink = { [weak self] up in
        MainActor.assumeIsolated { if !up { self?.bridgeDropped() } }
      }
      updateWatch()
    }
  }

  /// When you last opened the app. Opening it reconnects the strips too, and that isn't walking in: without this,
  /// opening the app hours after getting home (if iOS didn't wake it on the way in) would turn the lights on.
  var appOpenedAt: Date?

  override init() {
    super.init()
    // Set up early in launch: a region crossing that relaunched the app is delivered to this delegate (Apple DTS).
    location.delegate = self
    locationAlways = location.authorizationStatus == .authorizedAlways
  }

  private var connected: [Strip] { room?.strip.strips.filter { $0.state == .connected } ?? [] }

  private func note(_ text: String) {
    events.insert(Event(time: Date(), text: text), at: 0)
    events = Array(events.prefix(15))
    UserDefaults.standard.set(try? JSONEncoder().encode(events), forKey: "walkInEvents")
  }

  // MARK: Leaving

  func stripDropped() {
    guard connected.isEmpty, awaySince == nil else { return }
    // The beacon still hears you: a strip blipped, you didn't leave. Its exit comes about 30 s after you do.
    if useLocation, nearBeacon == true { return }
    left("Your strips went out of Bluetooth range.")
  }

  private func left(_ why: String) {
    awaySince = Date()
    arrivedAt = nil
    updateWatch()
    guard enabled else { return }
    note("Left. " + why)
    guard offWhenLeaving, let room else { return }
    beginBackground()
    // After a relaunch the strips are still reconnecting; they get turned off as they come back, if still in range.
    room.strip.reconnectNow()
    let off = room.leaveOff()
    note(off == 0 ? "Nothing was on." : off == 1 ? "Turned off 1 light." : "Turned off \(off) lights together.")
    Task { [weak self] in
      for wait in [3.0, 3, 4] {
        try? await Task.sleep(for: .seconds(wait))
        guard let self, self.awaySince != nil else { return }
        let more = room.leaveOff()
        if more > 0 { self.note(more == 1 ? "1 more light turned off." : "\(more) more lights turned off.") }
      }
      self?.endBackground()
    }
  }

  // MARK: Your doorway (the bridge's zones)

  /// Guided setup, step `i` (0 room, 1 doorway, 2 hall): the bridge measures where you stand for about 4 s.
  func measureZone(_ i: Int) {
    guard let room, room.bridge.state == .ready else {
      zoneError = "Your IR bridge isn't connected. Plug it in and open this page in your room."
      return
    }
    zoneError = nil
    measuringZone = i
    // The bridge numbers zones from the outside in: 0 hall, 1 doorway, 2 room.
    room.bridge.measureZone(2 - i) { [weak self] rssi in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.measuringZone = nil
        guard let rssi else {
          self.zoneError = i == 2
            ? "Your IR bridge can't hear your phone out there. Step back toward your door, just outside it, and try again."
            : "Couldn't get a reading. Try again."
          return
        }
        self.zoneReadings[i] = rssi
        self.finishZones()
      }
    }
  }

  /// Three readings in: they have to step down from room to doorway to hall, or the doorway can't be told apart.
  private func finishZones() {
    guard let r = zoneReadings[0], let d = zoneReadings[1], let h = zoneReadings[2] else { return }
    guard r - d >= 3, d - h >= 3 else {
      zoneError = r - d < 3
        ? "Your room and doorway read almost the same. Measure the room from farther in, or move the bridge away from the door."
        : "Your doorway and the hall read almost the same. Step a little farther out for the hall."
      zoneReadings = [nil, nil, nil]
      return
    }
    zones = [r, d, h]
    note("Doorway set up: room \(r), doorway \(d), hall \(h) dBm.")
  }

  func redoZones() {
    zoneReadings = [nil, nil, nil]
    zones = nil
    zoneError = nil
  }

  /// Keeps the bridge's zones in step with the settings.
  private func updateWatch() {
    room?.bridge.setZones(enabled ? zones : nil)
  }

  private func bridgeSaw(arrived: Bool, rssi: Int, margin: Int) {
    guard enabled else { return }
    if arrived {
      guard let since = awaySince else { return }
      doorWait = nil
      comeBack(since: since, via: "You came through your door", strip: nil, atDoor: true)
    } else if awaySince == nil {
      left("You went out your door (\(margin) dB past it).")
    }
  }

  /// The bridge lost your phone: you're past its range, unless the beacon still hears you (a blip).
  private func bridgeDropped() {
    guard enabled, awaySince == nil else { return }
    if useLocation, nearBeacon == true { return }
    left("Your IR bridge lost your phone.")
  }

  /// Location updates keep the app running in the background, for ranging while you walk in or watching while you're
  /// home. Lowest accuracy: it's the running that matters, not the fix.
  private func updateLocationUpdates() {
    if rangeTarget != nil {
      location.allowsBackgroundLocationUpdates = true
      location.pausesLocationUpdatesAutomatically = false
      location.showsBackgroundLocationIndicator = false
      location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
      location.startUpdatingLocation()
    } else {
      location.stopUpdatingLocation()
      location.allowsBackgroundLocationUpdates = false
    }
  }

  // MARK: Coming back

  func stripConnected(_ id: UUID) {
    lightReady()
    guard let since = awaySince else { return }
    comeBack(since: since, via: "Back in range of your strips", strip: id)
  }

  /// The room beacon came into range: iOS relaunches the app for this even after a swipe-away.
  private func beaconEntered() {
    nearBeacon = true
    guard enabled else { return }
    // After a swipe-away nothing else re-arms the strips' connects.
    room?.strip.reconnectNow()
    guard let since = awaySince else { return }
    beginBackground()
    comeBack(since: since, via: "Your room's beacon is in range", strip: nil)
  }

  private func comeBack(since: Date, via: String, strip id: UUID?, atDoor: Bool = false) {
    // Already waiting for the bridge to see you at the door: a strip or the beacon coming back adds nothing.
    if !atDoor, doorWait != nil { return }
    // With a door spot on the bridge, wait for the bridge to say you're there, unless it never connects.
    if !atDoor, zones != nil, let room, Date().timeIntervalSince(since) >= Double(awayMinutes) * 60 {
      doorWait = Date().addingTimeInterval(Self.spotWait)
      note("\(via). Waiting for you to reach your door.")
      beginBackground()
      Task { [weak self] in await self?.room?.reconnect() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        MainActor.assumeIsolated {
          guard self.doorWait != nil, self.awaySince != nil, room.bridge.state != .ready else { return }
          self.doorWait = nil
          self.note("The IR bridge didn't connect. Using the strips and beacon instead.")
          self.comeBack(since: since, via: "Back", strip: id, atDoor: false, skipBridge: true)
        }
      }
      return
    }
    comeBack(since: since, via: via, strip: id, atDoor: atDoor, skipBridge: true)
  }

  private func comeBack(since: Date, via: String, strip id: UUID?, atDoor: Bool, skipBridge: Bool) {
    awaySince = nil
    doorWait = nil
    guard enabled else { return }
    let minutes = Int(Date().timeIntervalSince(since) / 60)
    if let opened = appOpenedAt, Date().timeIntervalSince(opened) < 30 {
      note("Back, but you'd just opened the app, so no welcome.")
      return
    }
    // A blip (strip unplugged a moment, or you stepped out briefly) isn't coming home.
    guard Date().timeIntervalSince(since) >= Double(awayMinutes) * 60 else {
      note("Back after \(minutes) min. Too short to count (the setting is \(awayMinutes) min).")
      return
    }
    beginBackground()
    // The cloud bulb needs a few seconds to load after a relaunch: start now, while you're still walking in.
    Task { [weak self] in await self?.room?.reconnect() }
    let deadline = Date().addingTimeInterval(Self.spotWait)
    // The bridge already saw you at your door.
    if atDoor {
      note("\(via) after \(minutes) min.")
      arrive(id)
    // The beacon sits in your room, so its signal places you better than a strip's.
    } else if let beaconSpot, useLocation {
      note("\(via) after \(minutes) min. Waiting for you to reach your door.")
      rangeStarted = Date()
      rangeHeard = false
      rangeStrip = id
      lastRanged = Date()
      startRanging(until: deadline, spot: beaconSpot)
      watchRanging()
    } else if let id, let spot {
      note("\(via) after \(minutes) min. Waiting for you to reach your spot.")
      waitForSpot(id, spot, until: deadline)
    } else {
      note("\(via) after \(minutes) min.")
      arrive(id)
    }
  }

  private func waitForSpot(_ id: UUID, _ spot: Int, until deadline: Date) {
    room?.strip.readRSSI(id) { [weak self] rssi in
      guard let self else { return }
      MainActor.assumeIsolated {
        guard let rssi else {
          // No reading: the strip dropped again (walked past), or iOS won't read in the background.
          if self.room?.strip.strips.first(where: { $0.id == id })?.state == .connected {
            self.arrive(id)
          } else {
            self.note("The strip dropped again before you reached your spot. Walking past?")
            self.awaySince = Date()
            self.endBackground()
          }
          return
        }
        if rssi >= spot {
          self.arrive(id)
        } else if Date() < deadline {
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.waitForSpot(id, spot, until: deadline) } }
        } else {
          self.note("You didn't reach your spot within 3 minutes, so no welcome.")
          self.endBackground()
        }
      }
    }
  }

  private func arrive(_ id: UUID?) {
    guard let room else { return }
    // Light the room this strip is in.
    if let id, let item = room.item(Room.stripItemID(id)) { room.selectedRoom = room.roomOf(item) }
    welcomed = Set(room.welcome(scene: sceneID))
    lastArrival = Date()
    arrivedAt = Date()
    updateWatch()
    note(welcomed.isEmpty ? "Home, but no light in \(room.currentRoom) was ready yet." : "Welcome home: \(sceneID ?? "lights on") (\(welcomed.count) lights).")
    beginBackground()
    // The cloud bulb loads a few seconds after a background relaunch, and other lights connect when they connect.
    Task { [weak self] in
      for wait in [3.0, 5, 7, 10, 15, 20] {
        try? await Task.sleep(for: .seconds(wait))
        self?.lightReady()
      }
      self?.endBackground()
    }
  }

  /// A light connected: if you just walked in, it gets the welcome too.
  func lightReady() {
    guard let arrivedAt, Date().timeIntervalSince(arrivedAt) < Self.lateWindow, let room else { return }
    let late = room.welcome(scene: sceneID, except: welcomed, late: true)
    guard !late.isEmpty else { return }
    welcomed.formUnion(late)
    note(late.count == 1 ? "One more light caught up." : "\(late.count) more lights caught up.")
  }

  // MARK: Ranging the beacon

  private func startRanging(until deadline: Date? = nil, spot: Int? = nil) {
    if let deadline, let spot { rangeTarget = (spot, deadline) }
    // Ranging only runs in the background while location updates do; they stop as soon as you're in.
    if rangeTarget != nil { updateLocationUpdates() }
    location.startRangingBeacons(satisfying: Self.beacon)
  }

  private func stopRanging() {
    location.stopRangingBeacons(satisfying: Self.beacon)
    rangeTarget = nil
    updateLocationUpdates()
  }

  /// Every 5 s while walking in: if ranging went quiet, stop waiting for a reading that won't come.
  private func watchRanging() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      MainActor.assumeIsolated {
        guard self.rangeTarget != nil else { return }
        if Date().timeIntervalSince(self.lastRanged) > 12 {
          self.stopRanging()
          self.note("iOS paused beacon readings (screen off?). Lighting up, since you're in range.")
          self.arrive(self.rangeStrip)
        } else {
          self.watchRanging()
        }
      }
    }
  }

  private func ranged(_ rssi: Int?) {
    lastRanged = Date()
    beaconRSSI = rssi
    if rssi != nil { nearBeacon = true }
    if spotReadings != nil, let rssi { spotReadings?.append(rssi) }
    guard let target = rangeTarget else { return }
    if rssi != nil { rangeHeard = true }
    // 15 s without a single beacon reading: the bridge isn't there. Use the strips instead of waiting in the dark.
    if !rangeHeard, Date().timeIntervalSince(rangeStarted) > 15 {
      stopRanging()
      if let id = rangeStrip, let spot {
        note("No beacon heard (is the bridge plugged in?). Using your strips instead.")
        waitForSpot(id, spot, until: target.until)
      } else {
        note("No beacon heard (is the bridge plugged in?). Lighting up anyway.")
        arrive(rangeStrip)
      }
      return
    }
    if let rssi, rssi >= target.spot {
      stopRanging()
      arrive(nil)
    } else if Date() > target.until {
      stopRanging()
      note("You didn't reach your door within 3 minutes, so no welcome. Walking past?")
      endBackground()
    }
  }

  /// "Try it now": runs the welcome as if you'd just walked in.
  func tryNow() {
    note("Test run.")
    arrive(nil)
  }

  // MARK: Your spot

  /// Stand at your door and call this: averages a few readings from the nearest connected strip.
  func setSpot() {
    measureBeacon()
    guard let room, let strip = connected.first(where: { s in
      room.item(Room.stripItemID(s.id)).map { room.roomOf($0) == room.currentRoom } ?? false
    }) ?? connected.first else {
      spotError = useLocation
        ? "No strip is connected, so only the beacon was measured. That's enough if the bridge is plugged in."
        : "No strip is connected right now. Step a little closer and try again."
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
          self.note("Spot set at \(self.spot!) dBm.")
        }
      }
    }
    next(6)
  }

  func clearSpot() {
    spot = nil
    beaconSpot = nil
  }

  /// Three seconds of beacon readings where you stand. Skipped quietly when location is off or no bridge is near.
  private func measureBeacon() {
    guard useLocation, location.authorizationStatus == .authorizedAlways || location.authorizationStatus == .authorizedWhenInUse else { return }
    spotReadings = []
    startRanging()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      MainActor.assumeIsolated {
        let readings = self.spotReadings ?? []
        self.spotReadings = nil
        if self.rangeTarget == nil { self.location.stopRangingBeacons(satisfying: Self.beacon) }
        guard !readings.isEmpty else { return }
        self.beaconSpot = readings.reduce(0, +) / readings.count - 4
        self.note("Beacon spot set at \(self.beaconSpot!) dBm.")
      }
    }
  }

  // MARK: Location backup

  /// Saves where you are now as home and starts watching it. Needs "Always" location so iOS can wake the app.
  func setHomeHere() {
    locationError = nil
    switch location.authorizationStatus {
    case .denied, .restricted:
      locationError = "Location is off for Dorm Remote. Turn it on in Settings → Dorm Remote → Location → Always."
      return
    case .notDetermined:
      locating = true
      location.requestAlwaysAuthorization()
      return
    default:
      if location.authorizationStatus == .authorizedWhenInUse { location.requestAlwaysAuthorization() }
      locating = true
      location.desiredAccuracy = kCLLocationAccuracyBest
      location.requestLocation()
    }
  }

  private func updateGeofence() {
    for region in location.monitoredRegions where region.identifier == Self.regionID || region.identifier == Self.beaconID {
      location.stopMonitoring(for: region)
    }
    if enabled, useLocation, CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) {
      let beacon = CLBeaconRegion(uuid: Self.beaconUUID, identifier: Self.beaconID)
      beacon.notifyOnEntry = true
      beacon.notifyOnExit = true
      // Waking the screen asks iOS where you are, so pulling out your phone at the door counts too.
      beacon.notifyEntryStateOnDisplay = true
      location.startMonitoring(for: beacon)
    }
    guard enabled, useLocation, let home, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
    let region = CLCircularRegion(center: home, radius: Self.homeRadius, identifier: Self.regionID)
    region.notifyOnEntry = true
    region.notifyOnExit = true
    location.startMonitoring(for: region)
  }

  /// Crossing into the circle around home. Usually you're still a minute from your door, so this re-arms the
  /// strips' connects (after a swipe-away nothing else would) and the strips decide when you're actually there.
  private func nearHome() {
    guard enabled else { return }
    note("Near home (location).")
    beginBackground()
    room?.strip.reconnectNow()
    // Never really left Bluetooth range: you're home now.
    if awaySince != nil, let strip = connected.first {
      stripConnected(strip.id)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MainActor.assumeIsolated { if self.arrivedAt == nil { self.endBackground() } } }
    }
  }

  private func leftHome() {
    guard awaySince == nil else { return }
    left("You left the area around home (location).")
  }

  private func beginBackground() {
    guard background == .invalid else { return }
    background = UIApplication.shared.beginBackgroundTask(withName: "Walk in") { [weak self] in
      MainActor.assumeIsolated { self?.endBackground() }
    }
  }

  private func endBackground() {
    guard background != .invalid else { return }
    UIApplication.shared.endBackgroundTask(background)
    background = .invalid
  }
}

extension WalkIn: CLLocationManagerDelegate {
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    MainActor.assumeIsolated {
      locationAlways = status == .authorizedAlways
      updateWatch()
      guard locating else { return }
      switch status {
      case .authorizedAlways, .authorizedWhenInUse:
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestLocation()
      case .denied, .restricted:
        locating = false
        locationError = "Location is off for Dorm Remote. Turn it on in Settings → Dorm Remote → Location → Always."
      default: break
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let fix = locations.last else { return }
    let coordinate = fix.coordinate, accuracy = fix.horizontalAccuracy
    let always = manager.authorizationStatus == .authorizedAlways
    MainActor.assumeIsolated {
      guard locating else { return }
      locating = false
      home = coordinate
      note("Home set (to within \(Int(accuracy)) m).")
      if !always {
        locationError = "Home is set, but iOS can only wake the app if location is set to Always: Settings → Dorm Remote → Location → Always."
      }
      updateGeofence()
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    MainActor.assumeIsolated {
      guard locating else { return }
      locating = false
      locationError = "Couldn't get your location. Try again near a window."
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    let id = region.identifier
    MainActor.assumeIsolated {
      if id == Self.regionID { nearHome() }
      if id == Self.beaconID { beaconEntered() }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    let id = region.identifier
    MainActor.assumeIsolated {
      if id == Self.regionID { leftHome() }
      if id == Self.beaconID {
        nearBeacon = false
        if awaySince == nil { left("You left your room's beacon range.") }
      }
    }
  }

  /// Also called when you wake the screen (notifyEntryStateOnDisplay): inside after being away is coming in.
  nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
    guard region.identifier == Self.beaconID else { return }
    MainActor.assumeIsolated {
      switch state {
      case .inside: if nearBeacon != true || awaySince != nil { beaconEntered() }
      case .outside: nearBeacon = false
      default: break
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying constraint: CLBeaconIdentityConstraint) {
    // 0 means iOS heard it but couldn't measure this second.
    let rssi = beacons.map(\.rssi).filter { $0 != 0 }.max()
    MainActor.assumeIsolated { ranged(rssi) }
  }
}
