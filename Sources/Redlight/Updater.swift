import AppKit
import Sparkle

/// Sparkle auto-updates. The feed (`SUFeedURL`) and EdDSA public key (`SUPublicEDKey`) live
/// in the Info.plist written by `build.sh`; the appcast is attached to each GitHub release.
/// Unbundled runs (`swift run`) have neither key, so the updater stays off there.
///
/// Redlight is an accessory app, so a scheduled check's alert opens behind whatever app is
/// in front. Gentle reminders: Sparkle still shows that alert, and `hasPendingUpdate` lets
/// the popover flag the Updates button until the user looks at it.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private(set) var hasPendingUpdate = false
    private(set) var canCheckForUpdates = false
    /// Sparkle's own setting, kept by Sparkle in the app's defaults: new versions are
    /// downloaded in the background and installed when the app next quits, without asking.
    private(set) var updatesAutomatically = false
    /// False where that setting cannot be turned on: automatic checks are off.
    private(set) var canUpdateAutomatically = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticObservations: [NSKeyValueObservation] = []

    private override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        automaticObservations = [
            controller.updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                MainActor.assumeIsolated { self?.updatesAutomatically = updater.automaticallyDownloadsUpdates }
            },
            controller.updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canUpdateAutomatically = updater.allowsAutomaticUpdates }
            },
        ]
    }

    /// Only ever called for the user's own choice: Sparkle remembers it.
    func setUpdatesAutomatically(_ on: Bool) {
        guard let updater = controller?.updater, updater.automaticallyDownloadsUpdates != on else { return }
        updater.automaticallyDownloadsUpdates = on
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        // Accessory app: bring Sparkle's window to the front instead of behind other apps.
        NSApplication.shared.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let scheduled = !state.userInitiated
        MainActor.assumeIsolated { if scheduled { hasPendingUpdate = true } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { hasPendingUpdate = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { hasPendingUpdate = false }
    }
}
