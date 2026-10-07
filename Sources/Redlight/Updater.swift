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
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
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
