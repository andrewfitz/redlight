import AppKit
import Observation

/// What an app does to the tint while it is in front. Amounts are slider percent, 0 to 100
/// of each slider's own scale, as `redlight color` and `redlight whitepoint` count them.
enum AppRule: Codable, Sendable, Equatable {
    /// No tint, as a pause. Invert stays on.
    case pause
    /// Both sliders at these values, whatever Auto or Manual shows: 0…100 each.
    case hold(color: Int, whitepoint: Int, saturation: Int? = nil)
    /// This much added to what Auto or Manual shows: −100…100 each.
    case shift(color: Int, whitepoint: Int, saturation: Int? = nil)

    enum Kind: String, Codable, Sendable, CaseIterable {
        case pause, hold, shift

        /// "Pause", as Settings and the popover show it.
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    static let holdRange: ClosedRange<Double> = 0...100
    static let shiftRange: ClosedRange<Double> = -100...100

    /// The wire and older preferences can contain fractional percentages.
    private enum Input: Decodable {
        case pause
        case hold(color: Double, whitepoint: Double, saturation: Double?)
        case shift(color: Double, whitepoint: Double, saturation: Double?)
    }

    init(from decoder: Decoder) throws {
        switch try Input(from: decoder) {
        case .pause: self = .pause
        case .hold(let c, let w, let s): try self.init(kind: .hold, color: c, whitepoint: w, saturation: s)
        case .shift(let c, let w, let s): try self.init(kind: .shift, color: c, whitepoint: w, saturation: s)
        }
    }

    init(kind: Kind, color: Double, whitepoint: Double, saturation: Double?) throws {
        let range = kind == .shift ? Self.shiftRange : Self.holdRange
        guard [color, whitepoint, saturation].compactMap({ $0 }).allSatisfy(range.contains) else {
            throw CommandError.invalidInput("A \(kind.rawValue) takes percentages from \(Int(range.lowerBound)) to 100.")
        }
        let c = Int(color.rounded()), w = Int(whitepoint.rounded()), s = saturation.map { Int($0.rounded()) }
        switch kind {
        case .pause: self = .pause
        case .hold: self = .hold(color: c, whitepoint: w, saturation: s == 100 ? nil : s)
        case .shift: self = .shift(color: c, whitepoint: w, saturation: s)
        }
    }

    var kind: Kind {
        switch self {
        case .pause: .pause
        case .hold: .hold
        case .shift: .shift
        }
    }

    /// True for a rule that changes the colour rather than hiding it.
    var shapesOutput: Bool { self != .pause }

    /// Nil follows the global saturation switch and level.
    var saturation: Int? {
        switch self {
        case .pause: nil
        case .hold(_, _, let value), .shift(_, _, let value): value
        }
    }

    func withSaturation(_ amount: Int?) -> AppRule {
        switch self {
        case .pause: self
        case .hold(let color, let whitepoint, _):
            .hold(color: color, whitepoint: whitepoint, saturation: amount.flatMap { $0 >= 100 ? nil : max(0, $0) })
        case .shift(let color, let whitepoint, _):
            .shift(color: color, whitepoint: whitepoint, saturation: amount.map { min(100, max(-100, $0)) })
        }
    }

    func amount(_ channel: CommandChannel) -> Int? {
        switch self {
        case .pause: nil
        case .hold(let color, let whitepoint, _), .shift(let color, let whitepoint, _):
            channel == .color ? color : whitepoint
        }
    }

    /// The same rule with one channel's amount replaced, clamped to the rule's range.
    func with(_ channel: CommandChannel, _ amount: Int) -> AppRule {
        switch self {
        case .pause:
            return self
        case .hold(let color, let whitepoint, _):
            let value = min(100, max(0, amount))
            return channel == .color ? .hold(color: value, whitepoint: whitepoint, saturation: saturation) : .hold(color: color, whitepoint: value, saturation: saturation)
        case .shift(let color, let whitepoint, _):
            let value = min(100, max(-100, amount))
            return channel == .color ? .shift(color: value, whitepoint: whitepoint, saturation: saturation) : .shift(color: color, whitepoint: value, saturation: saturation)
        }
    }

    /// Throws unless every amount is finite and in its rule's range.
    func validated() throws -> AppRule {
        switch self {
        case .pause:
            break
        case .hold(let color, let whitepoint, _):
            guard [color, whitepoint, saturation].compactMap({ $0 }).allSatisfy({ (0...100).contains($0) }) else {
                throw CommandError.invalidInput("A hold is color temp, white point and optional saturation, each from 0 to 100.")
            }
            if saturation == 100 { return withSaturation(nil) }
        case .shift(let color, let whitepoint, _):
            guard [color, whitepoint, saturation].compactMap({ $0 }).allSatisfy({ (-100...100).contains($0) }) else {
                throw CommandError.invalidInput("A shift is color temp, white point and optional saturation, each from -100 to 100.")
            }
        }
        return self
    }

    /// "hold color temp 40%, white point 70%", as `redlight apps list` and Shortcuts put it.
    var text: String {
        switch self {
        case .pause: "pause"
        case .hold(let color, let whitepoint, _):
            "hold color temp \(Self.percent(color)), white point \(Self.percent(whitepoint))" + (saturation.map { ", saturation \(Self.percent($0))" } ?? "")
        case .shift(let color, let whitepoint, _):
            "shift color temp \(Self.signed(color)), white point \(Self.signed(whitepoint))" + (saturation.map { ", saturation \(Self.signed($0))" } ?? "")
        }
    }

    static func percent(_ value: Int) -> String { "\(value)%" }

    static func signed(_ value: Int) -> String {
        value == 0 ? "0%" : (value > 0 ? "+" : "−") + "\(value.magnitude)%"
    }

}

/// One chosen app and its rule.
struct AppRuleEntry: Codable, Sendable, Equatable {
    var bundleID: String
    var rule: AppRule
}

/// The chosen app in front, with its rule. The name is for display only: the bundle ID and
/// the process say which app it is.
struct ActiveApp: Equatable, Sendable {
    var bundleID: String
    var processID: pid_t
    var name: String
    var rule: AppRule
}

/// A running application as the app rules see it.
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

/// Loose bundle identifier check shared by the CLI, the handler and the saved rules: an app
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

/// Owns the apps with a rule, and decides which of them, if any, is in front. It does not
/// touch the display itself: `onChange` hands every decision to `DisplayManager.setActiveApp`.
@MainActor
@Observable
final class AppRulesController {
    static let defaultsKey = "redlight.appRules"
    /// The saved form's version. A form this build cannot read starts an empty list.
    static let storageVersion = 1

    /// In the order chosen; bundle IDs are compared without regard to case.
    private(set) var rules: [AppRuleEntry]
    /// The app being judged: the last app in front other than Redlight. Opening the popover
    /// or the Shortcuts window activates Redlight; judging this app instead keeps the
    /// decision, and lets the popover edit the rule of the app it was opened over.
    private(set) var recentApp: RunningApp?
    /// The chosen app in front, or nil. Decided once before the display model exists, so
    /// launch starts with its rule, and again on each activation, wake and rule change.
    @ObservationIgnored private(set) var activeApp: ActiveApp?
    @ObservationIgnored var onChange: ((ActiveApp?) -> Void)?

    @ObservationIgnored private let source: AppActivationSource
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ownBundleID: String?
    @ObservationIgnored private let ownProcessID: pid_t
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
        rules = Self.decode(defaults.data(forKey: Self.defaultsKey))
        source.start(
            onActivate: { [weak self] in self?.evaluate($0) },
            onTerminate: { [weak self] in self?.appDidTerminate($0) },
            onWake: { [weak self] in self.map { $0.evaluate($0.source.frontmostApp) } })
        evaluate(source.frontmostApp)
    }

    var recentBundleID: String? { recentApp?.bundleID }

    func rule(for bundleID: String) -> AppRule? {
        rules.first { AppBundleID.matches($0.bundleID, bundleID) }?.rule
    }

    /// Gives an app a rule, or a new one. A chosen app keeps its place and spelling.
    func set(_ bundleID: String, _ rule: AppRule) throws {
        let id = try AppBundleID.validate(bundleID)
        let rule = try rule.validated()
        if let index = rules.firstIndex(where: { AppBundleID.matches($0.bundleID, id) }) {
            guard rules[index].rule != rule else { return }
            rules[index].rule = rule
        } else {
            rules.append(AppRuleEntry(bundleID: id, rule: rule))
        }
        rulesDidChange()
    }

    func remove(_ bundleID: String) throws {
        guard let index = rules.firstIndex(where: { AppBundleID.matches($0.bundleID, bundleID) }) else {
            throw CommandError.invalidInput("\(bundleID) has no rule; use redlight apps list.")
        }
        names.removeValue(forKey: rules.remove(at: index).bundleID)
        rulesDidChange()
    }

    func clear() {
        guard !rules.isEmpty else { return }
        rules.removeAll()
        names.removeAll()
        rulesDidChange()
    }

    func apply(_ change: CommandApps) throws {
        switch change {
        case .set(let id, let rule): try set(id, rule)
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

    /// The rules as commands report them, each with its app's name.
    var statusRules: [Status.App] {
        rules.map { Status.App(bundleID: $0.bundleID, name: name(for: $0.bundleID), rule: $0.rule) }
    }

    /// Regular apps running now, other than Redlight.
    func runningApps() -> [RunningApp] {
        source.runningApps.filter { !isOwn($0) }
    }

    /// The saved rules, with unreadable entries and case-insensitive repeats dropped.
    static func decode(_ data: Data?) -> [AppRuleEntry] {
        guard let data, let stored = try? JSONDecoder().decode(Stored<Lenient>.self, from: data),
              stored.version == storageVersion else { return [] }
        var seen = Set<String>()
        return stored.rules.compactMap { lenient in
            guard let entry = lenient.entry,
                  (try? AppBundleID.validate(entry.bundleID)) != nil, let rule = try? entry.rule.validated(),
                  seen.insert(entry.bundleID.folding(options: .caseInsensitive, locale: nil)).inserted
            else { return nil }
            return AppRuleEntry(bundleID: entry.bundleID, rule: rule)
        }
    }

    private struct Stored<Entry: Codable>: Codable {
        var version: Int
        var rules: [Entry]
    }

    /// One unreadable entry costs only itself.
    private struct Lenient: Codable {
        var entry: AppRuleEntry?
        init(from decoder: Decoder) throws { entry = try? AppRuleEntry(from: decoder) }
        func encode(to encoder: Encoder) throws { try entry.encode(to: encoder) }
    }

    private func isOwn(_ app: RunningApp) -> Bool {
        if app.processID == ownProcessID { return true }
        guard let bundleID = app.bundleID, let ownBundleID else { return false }
        return AppBundleID.matches(bundleID, ownBundleID)
    }

    private func rulesDidChange() {
        if rules.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(Stored(version: Self.storageVersion, rules: rules)) {
            // Small: written on every step of a drag that edits a rule.
            defaults.set(data, forKey: Self.defaultsKey)
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

    /// Redlight keeps the previous app. An empty frontmost snapshot clears it. An app without
    /// a bundle ID can have no rule.
    private func evaluate(_ app: RunningApp?) {
        if app.map(isOwn) != true, recentApp != app { recentApp = app }
        let active = recentApp.flatMap { app -> ActiveApp? in
            guard let id = app.bundleID, let rule = rule(for: id) else { return nil }
            return ActiveApp(bundleID: id, processID: app.processID, name: app.name, rule: rule)
        }
        guard active != activeApp else { return }
        activeApp = active
        onChange?(active)
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
