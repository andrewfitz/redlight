import AppKit
import Observation

/// A running application as the app suspension sees it.
struct RunningApp: Equatable, Sendable {
    var bundleID: String?
    var name: String
    var processID: pid_t
}

extension RunningApp {
    init(_ app: NSRunningApplication) {
        self.init(bundleID: app.bundleIdentifier,
                  name: app.localizedName ?? app.bundleIdentifier ?? "Unnamed app",
                  processID: app.processIdentifier)
    }
}

/// Activations, wakes and app names. `NSWorkspace` in the app; a fake in tests.
@MainActor
protocol AppActivationSource: AnyObject {
    var frontmostApp: RunningApp? { get }
    /// Regular (Dock) apps currently running.
    var runningApps: [RunningApp] { get }
    /// The installed app's name, or nil when no app has this bundle ID.
    func displayName(forBundleID bundleID: String) -> String?
    /// Called once; the callbacks run on the main actor.
    func start(
        onActivate: @escaping @MainActor (RunningApp) -> Void,
        onTerminate: @escaping @MainActor (RunningApp) -> Void,
        onWake: @escaping @MainActor () -> Void
    )
}

/// Loose bundle identifier check shared by the CLI, the handler and the saved list: an app
/// that is not installed is still a valid choice, so only the shape is checked.
enum AppBundleID {
    static let maxLength = 255

    static func validate(_ text: String) throws -> String {
        guard !text.isEmpty, text.count <= maxLength,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) })
        else {
            throw CommandError.invalidInput(
                "A bundle ID is 1 to \(maxLength) characters with no spaces, such as com.apple.Photos.")
        }
        return text
    }

    static func matches(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }
}

/// Owns the apps that suspend the tint while in front, and decides whether the app in front
/// is one of them. It does not touch the display itself: `onChange` hands every decision to
/// `DisplayManager.setSuspendedForApp`, which ignores repeats.
@MainActor
@Observable
final class AppSuspensionController {
    static let defaultsKey = "redlight.pauseForApps"

    /// In the order chosen; compared without regard to case.
    private(set) var bundleIDs: [String]
    /// The name of the chosen app in front, or nil. Decided once before the model exists,
    /// so launch can start hidden, and again on each activation, wake and list change.
    @ObservationIgnored private(set) var suspendedFor: String?
    @ObservationIgnored var onChange: ((String?) -> Void)?

    @ObservationIgnored private let source: AppActivationSource
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ownBundleID: String?
    @ObservationIgnored private let ownProcessID: pid_t
    /// The last app in front other than Redlight. Opening the Shortcuts window activates
    /// Redlight; judging this app instead keeps the decision and still follows list changes.
    private var recentApp: RunningApp?
    @ObservationIgnored private var names: [String: String] = [:]

    init(
        source: AppActivationSource = WorkspaceAppSource(),
        defaults: UserDefaults = .standard,
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.source = source
        self.defaults = defaults
        self.ownBundleID = ownBundleID
        self.ownProcessID = ownProcessID
        bundleIDs = Self.sanitized(defaults.array(forKey: Self.defaultsKey))
        source.start(
            onActivate: { [weak self] in self?.evaluate($0) },
            onTerminate: { [weak self] in self?.appDidTerminate($0) },
            onWake: { [weak self] in self.map { $0.evaluate($0.source.frontmostApp) } })
        evaluate(source.frontmostApp)
    }

    var recentBundleID: String? { recentApp?.bundleID }

    func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains { AppBundleID.matches($0, bundleID) }
    }

    /// Choosing an app already chosen does nothing.
    func add(_ bundleID: String) throws {
        let id = try AppBundleID.validate(bundleID)
        guard !contains(id) else { return }
        bundleIDs.append(id)
        listDidChange()
    }

    func remove(_ bundleID: String) throws {
        guard let index = bundleIDs.firstIndex(where: { AppBundleID.matches($0, bundleID) }) else {
            throw CommandError.invalidInput("\(bundleID) is not in the list; use redlight apps list.")
        }
        names.removeValue(forKey: bundleIDs.remove(at: index))
        listDidChange()
    }

    func clear() {
        guard !bundleIDs.isEmpty else { return }
        bundleIDs.removeAll()
        names.removeAll()
        listDidChange()
    }

    func apply(_ change: CommandApps) throws {
        switch change {
        case .add(let id): try add(id)
        case .remove(let id): try remove(id)
        case .clear: clear()
        }
    }

    /// The installed app's name, falling back to the bundle ID. Cached: the lookup asks
    /// Launch Services, and the popover reads it on every redraw.
    func name(for bundleID: String) -> String {
        if let name = names[bundleID] { return name }
        let name = source.displayName(forBundleID: bundleID) ?? bundleID
        names[bundleID] = name
        return name
    }

    /// Regular apps running now, other than Redlight.
    func runningApps() -> [RunningApp] {
        source.runningApps.filter { !isOwn($0) }
    }

    /// A string array with invalid entries and case-insensitive repeats dropped.
    static func sanitized(_ raw: [Any]?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for case let id as String in raw ?? [] where (try? AppBundleID.validate(id)) != nil {
            guard seen.insert(id.folding(options: .caseInsensitive, locale: nil)).inserted else { continue }
            result.append(id)
        }
        return result
    }

    private func isOwn(_ app: RunningApp) -> Bool {
        if app.processID == ownProcessID { return true }
        guard let bundleID = app.bundleID, let ownBundleID else { return false }
        return AppBundleID.matches(bundleID, ownBundleID)
    }

    private func listDidChange() {
        if bundleIDs.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(bundleIDs, forKey: Self.defaultsKey)
        }
        evaluate(recentApp)
    }

    /// The app being judged quit. Usually the next app's activation follows, but not when
    /// Redlight's own window takes over (its activation keeps `recentApp`) or nothing does,
    /// so stop judging an app that is gone. The system may still name it as frontmost.
    private func appDidTerminate(_ app: RunningApp) {
        guard let recentApp, recentApp.processID == app.processID else { return }
        self.recentApp = nil
        let front = source.frontmostApp
        evaluate(front?.processID == app.processID ? nil : front)
    }

    /// Redlight keeps the previous app. An empty frontmost snapshot clears it.
    private func evaluate(_ app: RunningApp?) {
        if app.map(isOwn) != true { recentApp = app }
        let match = recentApp.flatMap { app in app.bundleID.map(contains) == true ? app : nil }
        guard suspendedFor != match?.name else { return }
        suspendedFor = match?.name
        onChange?(suspendedFor)
    }
}

@MainActor
final class WorkspaceAppSource: AppActivationSource {
    // nonisolated(unsafe): written on the main actor; read in deinit for cleanup.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var frontmostApp: RunningApp? { NSWorkspace.shared.frontmostApplication.map(RunningApp.init) }

    var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map(RunningApp.init)
    }

    func displayName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    func start(
        onActivate: @escaping @MainActor (RunningApp) -> Void,
        onTerminate: @escaping @MainActor (RunningApp) -> Void,
        onWake: @escaping @MainActor () -> Void
    ) {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                .map(RunningApp.init)
            MainActor.assumeIsolated { if let app { onActivate(app) } }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                .map(RunningApp.init)
            MainActor.assumeIsolated { if let app { onTerminate(app) } }
        })
        // Activations are not delivered during sleep, and the screen may wake on another app.
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWake() }
        })
        // Activations in another login session are not delivered to this one.
        observers.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWake() }
        })
    }
}
