import AferoSofthub
import Foundation
import Observation

/// Makes the phone a Bluetooth hub for Hubspace bulbs, the same way the Hubspace app does.
/// Bulbs that never finished Wi-Fi setup only reach Hubspace's cloud through a hub like this;
/// without one the cloud answers commands with 424. Uses Afero's published Softhub framework
/// (aferodeveloper/AferoIOSSofthub), started per the AferoSwiftSDK docs.
@MainActor
@Observable
final class BulbHub {
  private(set) var running = false
  var log: (String) -> Void = { _ in }

  // ponytail: the docs name the cloud only as "prod"; if the softhub rejects a name, the next one is tried.
  private static let services = ["prod", "PROD", "production"]
  private var serviceIndex = 0
  private var accountID: String?
  private var associate: ((String) async -> Bool)?
  private var stateObservation: NSKeyValueObservation?

  func start(accountID: String, associate: @escaping (String) async -> Bool) {
    self.accountID = accountID
    self.associate = associate
    guard AferoSofthub.sharedInstance().state == .stopped else { return }
    if stateObservation == nil {
      stateObservation = AferoSofthub.sharedInstance().observe(\.state) { [weak self] hub, _ in
        let state = hub.state
        Task { @MainActor in
          self?.running = state == .started
          self?.log("bulb hub state \(state.rawValue)")
        }
      }
    }
    launch()
  }

  /// Afero asks apps to stop the softhub in the background.
  func stop() {
    guard AferoSofthub.sharedInstance().state != .stopped else { return }
    AferoSofthub.stop()
  }

  private func launch() {
    guard let accountID else { return }
    let service = Self.services[serviceIndex]
    log("starting bulb hub (\(service))")
    AferoSofthub.start(
      withAccountId: accountID,
      service: service,
      logLevelName: AferoSofthubLogLevel(rawValue: "WARNING"),
      hardwareIdentifier: "DormRemote",
      associationHandler: { [weak self] associationId in
        Task { @MainActor in
          guard let self, let associate = self.associate else { return }
          self.log("bulb hub asks to join the account")
          let ok = await associate(associationId)
          AferoSofthub.notifyAssociationCompleted(with: ok ? .success : .transientFailure)
        }
      },
      setupModeDeviceDetectedHandler: { _, _, _ in },
      setupModeDeviceGoneHandler: { _ in },
      completionHandler: { [weak self] reason in
        Task { @MainActor in
          guard let self else { return }
          self.log("bulb hub stopped, reason \(reason.rawValue)")
          if reason == .unhandledService, self.serviceIndex + 1 < Self.services.count {
            self.serviceIndex += 1
            self.launch()
          }
        }
      }
    )
  }
}
