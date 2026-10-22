import Combine
import Foundation
import Observation
import Sparkle

/// Automatic updates with Sparkle 2 (https://sparkle-project.org/documentation/programmatic-setup/).
///
/// The updater runs only in a Release build whose Info.plist names a feed (`SUFeedURL`) and the
/// public update key (`SUPublicEDKey`); Debug builds from `scripts/test/all.sh` never check or
/// install anything. Sparkle checks the feed once a day by default (`SUEnableAutomaticChecks`),
/// asks before it installs (`SUAutomaticallyUpdate` is false) and installs an update by quitting
/// the app, which goes through `AppDelegate.applicationShouldTerminate`: running VMs are offered
/// Suspend All or Shut Down All first, and Cancel keeps the app and the update for later.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?

    /// Whether a check can start now (false while one runs, and without an updater).
    private(set) var canCheckForUpdates = false

    /// Why there is no updater; nil when there is one.
    let unavailableReason: String?

    /// Whether Sparkle checks the feed on its own schedule.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var isAvailable: Bool { controller != nil }

    private init() {
        #if DEBUG
        controller = nil
        unavailableReason = "Automatic updates are off in Debug builds."
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        guard !feed.isEmpty, !key.isEmpty else {
            controller = nil
            unavailableReason = "This build has no update feed."
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        unavailableReason = nil
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
        #endif
    }

    /// Creates the updater; call once at launch.
    func start() { _ = controller }

    /// Checks the feed now and shows the result, also when there is no update.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
