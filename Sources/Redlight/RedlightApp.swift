import SwiftUI
import ServiceManagement
import CoreGraphics

/// A small crash/sudden-termination guard around gamma-table ownership. A process that did
/// not mark its previous session clean may have left Redlight's LUT installed; restore
/// ColorSync before `DisplayManager` gets a chance to snapshot that stale LUT as "original."
enum DisplaySessionRecovery {
    static let cleanExitKey = "redlight.previousSessionExitedCleanly"

    static func begin(
        defaults: UserDefaults = .standard,
        restore: () -> Void = { CGDisplayRestoreColorSyncSettings() }
    ) {
        if defaults.object(forKey: cleanExitKey) != nil,
           !defaults.bool(forKey: cleanExitKey) {
            restore()
        }
        defaults.set(false, forKey: cleanExitKey)
        defaults.synchronize()
    }

    static func finish(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: cleanExitKey)
        defaults.synchronize()
    }
}

/// Launch-at-login state, backed by `SMAppService.mainApp`. Registration only ever happens
/// from the user's explicit toggle — never automatically at launch.
@MainActor
@Observable
final class LaunchAtLogin {
    var isEnabled: Bool {
        didSet {
            guard !isSyncing else { return }
            let registered = Self.isRegistered(service.status)
            guard isEnabled != registered else {
                requiresApproval = service.status == .requiresApproval
                return
            }
            do {
                if isEnabled { try service.register() }
                else { try service.unregister() }
            } catch {
                // Typical when running unbundled (`swift run`) or from outside /Applications.
                // The toggle snaps back via refresh(); leave a trace of why.
                NSLog("Redlight: login item %@ failed: %@",
                      isEnabled ? "register" : "unregister", String(describing: error))
            }
            refresh()  // reflect the actual system state, including registration failures
        }
    }
    private(set) var requiresApproval: Bool
    @ObservationIgnored private let service: SMAppService
    @ObservationIgnored private var isSyncing = false

    init(service: SMAppService = .mainApp) {
        self.service = service
        let status = service.status
        isEnabled = Self.isRegistered(status)
        requiresApproval = status == .requiresApproval
    }

    /// Re-sync with the system (login items can also change in System Settings).
    func refresh() {
        isSyncing = true
        defer { isSyncing = false }
        let status = service.status
        isEnabled = Self.isRegistered(status)
        requiresApproval = status == .requiresApproval
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func isRegistered(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound: false
        @unknown default: false
        }
    }
}

@MainActor
final class TerminationCoordinator {
    typealias Prepare = (@escaping () -> Void) -> Void

    private var isWaiting = false
    private var isApproved = false

    func request(
        prepare: Prepare,
        reply: @escaping () -> Void
    ) -> NSApplication.TerminateReply {
        if isApproved { return .terminateNow }
        if isWaiting { return .terminateLater }

        isWaiting = true
        var isPreparing = true
        var completedSynchronously = false
        prepare { [weak self] in
            guard let self, !self.isApproved else { return }
            if isPreparing {
                completedSynchronously = true
            } else {
                self.isApproved = true
                reply()
            }
        }
        isPreparing = false
        if completedSynchronously {
            isApproved = true
            return .terminateNow
        }
        return .terminateLater
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var prepareForTermination: TerminationCoordinator.Prepare?

    private let termination = TerminationCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepare = Self.prepareForTermination else { return .terminateNow }
        return termination.request(prepare: prepare) { [weak sender] in
            sender?.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore immediately on a normal termination. If the process is killed too
        // abruptly for this callback, DisplaySessionRecovery repairs it next launch.
        CGDisplayRestoreColorSyncSettings()
        DisplaySessionRecovery.finish()
    }
}

@main
struct RedlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var manager: DisplayManager
    @State private var launchAtLogin: LaunchAtLogin

    init() {
        // Must run before DisplayManager enumerates displays and captures gamma tables.
        DisplaySessionRecovery.begin()
        let manager = DisplayManager()
        _manager = State(initialValue: manager)
        _launchAtLogin = State(initialValue: LaunchAtLogin())
        AppDelegate.prepareForTermination = { completion in
            manager.beginTerminationFade(completion: completion)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager, launchAtLogin: launchAtLogin)
        } label: {
            // Simplified app icon: sun setting behind a monitor. Filled sun = active,
            // outline arc = inactive. A template image, so macOS tints it to contrast the
            // menu bar (dark on light, light on dark) — .template preserves that.
            Image(nsImage: manager.isAnyActive
                  ? MenuBarIcon.activeImage()
                  : MenuBarIcon.inactiveImage())
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)
    }
}
