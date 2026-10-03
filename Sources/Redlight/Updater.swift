import AppKit
import Sparkle

/// Sparkle auto-updates. The feed (`SUFeedURL`) and EdDSA public key (`SUPublicEDKey`) live
/// in the Info.plist written by `build.sh`; the appcast is attached to each GitHub release.
/// Unbundled runs (`swift run`) have neither key, so the updater stays off there.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    private init() {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = bundled
            ? SPUStandardUpdaterController(startingUpdater: true,
                                           updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        // Accessory app: bring Sparkle's window to the front instead of behind other apps.
        NSApplication.shared.activate()
        controller?.checkForUpdates(nil)
    }
}
