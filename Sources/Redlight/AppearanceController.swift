import AppKit
import Darwin
import Observation

/// Reads and toggles the macOS *system* light/dark appearance.
///
/// Toggling dark mode "officially" means scripting System Events, which throws
/// an Automation consent prompt at the user on first use. The private SkyLight
/// call `SLSSetAppearanceThemeLegacy` flips the same global setting instantly
/// with no prompt, so it's the primary path; the symbols are resolved via
/// `dlsym` and guarded for nil so a future macOS removing them degrades to the
/// AppleScript fallback instead of crashing.
///
/// `isDark` mirrors the system setting (not this app's appearance) and stays
/// live by observing the distributed theme-change notification.
@MainActor
@Observable
final class AppearanceController {
    static let shared = AppearanceController()

    private(set) var isDark: Bool

    // MARK: - SkyLight (private) symbols

    private typealias GetThemeFn = @convention(c) () -> Bool
    private typealias SetThemeFn = @convention(c) (Bool) -> Void

    @ObservationIgnored private let getTheme: GetThemeFn?
    @ObservationIgnored private let setTheme: SetThemeFn?

    /// Retained for the app's lifetime; this is a singleton, so it's never
    /// removed (deinit is nonisolated under Swift 6 and can't touch it anyway).
    @ObservationIgnored private var themeObserver: NSObjectProtocol?

    private init() {
        // Resolve the private symbols once up front; nil just means "use the
        // AppleScript fallback". The handle is deliberately never dlclose'd.
        if let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
        ) {
            getTheme = dlsym(handle, "SLSGetAppearanceThemeLegacy")
                .map { unsafeBitCast($0, to: GetThemeFn.self) }
            setTheme = dlsym(handle, "SLSSetAppearanceThemeLegacy")
                .map { unsafeBitCast($0, to: SetThemeFn.self) }
        } else {
            getTheme = nil
            setTheme = nil
        }

        isDark = Self.readSystemIsDark()

        // Posted to the distributed center whenever the system theme changes,
        // from any source (Settings, other apps, our own toggle).
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    /// Flips the system appearance. SkyLight first (silent), AppleScript via
    /// System Events as fallback. Never crashes or retries if both fail; the
    /// notification observer reconciles `isDark` with whatever actually stuck.
    func toggle() {
        // Trust SkyLight's own read of the current theme when available; it
        // can't be stale the way a cached UserDefaults snapshot can.
        let current = getTheme?() ?? isDark
        let target = !current

        if let setTheme {
            setTheme(target)
            isDark = target
            return
        }

        if toggleViaAppleScript() {
            isDark = target
        }
    }

    private func refresh() {
        isDark = Self.readSystemIsDark()
    }

    /// "Dark" is stored in NSGlobalDomain as `AppleInterfaceStyle = Dark`; the
    /// key is absent entirely in light mode, so fall back to the app's
    /// effective appearance (which tracks the system for this agent app).
    private static func readSystemIsDark() -> Bool {
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
            return style == "Dark"
        }
        return NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Requires `NSAppleEventsUsageDescription` (Info.plist) and the user's
    /// one-time Automation consent. If consent is missing or denied (-1743)
    /// this logs and returns false — no crash, no retry loop.
    private func toggleViaAppleScript() -> Bool {
        let source = """
            tell application "System Events" to tell appearance preferences \
            to set dark mode to not dark mode
            """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            NSLog("Redlight: AppleScript appearance toggle failed: %@", error)
            return false
        }
        return true
    }
}
