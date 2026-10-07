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
    /// Reserved by the entry point before recovery or SwiftUI initialization.
    static var commandServer: CommandServer?
    static var prepareForTermination: TerminationCoordinator.Prepare?
    static var publishStoppedState: (() -> Void)?
    /// Set by `RedlightApp.init`; the status item can only be created once AppKit is up.
    static var makeStatusItem: (() -> StatusItemController)?

    private let termination = TerminationCoordinator()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusItem = Self.makeStatusItem?()
        _ = Updater.shared  // starts Sparkle's scheduled background checks
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepare = Self.prepareForTermination else { return .terminateNow }
        return termination.request(prepare: prepare) { [weak sender] in
            sender?.reply(toApplicationShouldTerminate: true)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if !ControlHandoff.shared.handle(url: url) {
                NSLog("Redlight: ignoring an unsupported command URL.")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore immediately on a normal termination. If the process is killed too
        // abruptly for this callback, DisplaySessionRecovery repairs it next launch.
        CGDisplayRestoreColorSyncSettings()
        Self.publishStoppedState?()
        DisplaySessionRecovery.finish()
    }
}

struct RedlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var manager: DisplayManager
    @State private var launchAtLogin: LaunchAtLogin

    init() {
        // Must run before DisplayManager enumerates displays and captures gamma tables.
        DisplaySessionRecovery.begin()
        let manager = DisplayManager(
            locationPromptActivation: {},
            onMasterStateChange: { _ in reloadRedlightControls() }
        )
        _manager = State(initialValue: manager)
        _launchAtLogin = State(initialValue: LaunchAtLogin())
        let launchAtLogin = _launchAtLogin.wrappedValue
        let handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { AppearanceController.shared.isDark },
            setAppearance: { try AppearanceController.shared.setDark($0) },
            login: {
                launchAtLogin.refresh()
                return Status.Login(enabled: launchAtLogin.isEnabled,
                                    requiresApproval: launchAtLogin.requiresApproval)
            },
            setLogin: { launchAtLogin.isEnabled = $0 },
            update: { Updater.shared.checkForUpdates() },
            quit: { NSApplication.shared.terminate(nil) },
            version: { AboutInfo.version() },
            canUpdate: { Updater.shared.isAvailable }
        ))
        do {
            guard let server = AppDelegate.commandServer else {
                throw CommandError.system("The Redlight command port was not reserved before startup.")
            }
            try server.installHandler { try handler.execute($0) }
        } catch {
            // A failed startup must restore gamma and the recovery marker before exiting.
            manager.restoreAllDisplays()
            manager.publishStoppedState()
            DisplaySessionRecovery.finish()
            NSLog("Redlight: command server startup failed: %@", error.localizedDescription)
            exit(2)
        }
        IntentBridge.install(execute: { try handler.execute($0) }, snapshot: { handler.snapshot() })
        let installer = CLIInstaller()
        installer.installSilentlyIfPossible()
        AppDelegate.prepareForTermination = { completion in
            manager.beginTerminationFade(completion: completion)
        }
        AppDelegate.publishStoppedState = { manager.publishStoppedState() }
        AppDelegate.makeStatusItem = {
            StatusItemController(isActive: { manager.isAnyActive }) {
                MenuBarView(manager: manager, launchAtLogin: launchAtLogin, handler: handler)
                    .onAppear { installer.offerPrivilegedInstallOnPopoverOpen() }
            }
        }
    }

    var body: some Scene {
        // The menu bar item and its panel are AppKit (StatusItemController); SwiftUI only
        // needs a scene to exist. LSUIElement keeps this one out of sight.
        Settings { EmptyView() }
    }
}
