import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Redlight

// Offscreen snapshot and timing harness for the popover. Nothing here runs in a plain
// `swift test`; each mode is switched on by an environment variable:
//
//   REDLIGHT_SNAPSHOT_DIR=/some/dir swift test --filter PopoverSnapshot
//       writes <state>-<light|dark>.png, <state>-<light|dark>-late.png and report.txt
//   REDLIGHT_SNAPSHOT_STATES=auto,paused   only those states (optional)
//   REDLIGHT_SNAPSHOT_CLOCK=wall           the manager follows the wall clock (optional)
//   REDLIGHT_POPOVER_TIMING=1 swift test --filter PopoverSnapshot
//       prints a POPOVER-TIMING block
//
// The popover is hosted exactly as `MenuBarViewTests` does: the real
// `StatusItemController.makePopover` content in a borderless window that is never ordered
// in, drawn with `cacheDisplay`. No window is shown and no display is touched.

// MARK: - States

/// One popover state. Add a state by adding one line to `PopoverState.all`.
@MainActor
struct PopoverState {
    enum Location {
        /// An authorized automatic fix (Chicago).
        case fix
        /// No coordinate at all, with this authorization.
        case none(LocationAuthorization)
        /// A coordinate the user typed in; shows the latitude and longitude fields.
        case manual
        /// An authorized automatic fix somewhere else.
        case at(latitude: Double, longitude: Double)
    }

    enum Clock {
        /// `PopoverState.fixedNow`, so solar values do not depend on when the test runs.
        case fixed
        /// The real clock. Needed where the view compares against wall time (a pause).
        case wall
    }

    var name: String
    /// Display names; IDs are 1, 2, 3… in this order.
    var displays: [String]
    /// IDs left unchecked. Every other display is tinted.
    var off: Set<CGDirectDisplayID>
    var inverted: Set<CGDirectDisplayID>
    /// Written to the emptied defaults before `DisplayManager` loads them.
    var defaults: [String: Any]
    var location: Location
    var clock: Clock
    /// Replaces `PopoverFixture.menuBarView()`, for states that need other view inputs.
    var view: (@MainActor (PopoverFixture) -> AnyView)?
    /// Runs after the manager exists, through its real API.
    var configure: @MainActor (PopoverFixture) throws -> Void
    /// Runs on the hosted popover's document before it is drawn, for a state that only
    /// using a control can reach.
    var interact: (@MainActor (NSView) throws -> Void)?

    init(
        _ name: String,
        displays: [String] = PopoverState.twoDisplays,
        off: Set<CGDirectDisplayID> = [],
        inverted: Set<CGDirectDisplayID> = [],
        defaults: [String: Any] = [:],
        location: Location = .fix,
        clock: Clock = .fixed,
        _ configure: @escaping @MainActor (PopoverFixture) throws -> Void = { _ in }
    ) {
        self.name = name
        self.displays = displays
        self.off = off
        self.inverted = inverted
        self.defaults = defaults
        self.location = location
        self.clock = clock
        self.configure = configure
    }

    /// The same state showing another view, e.g.
    /// `PopoverState("about").showing { AnyView(MenuBarView(manager: $0.manager, …, initialPage: .about)) }`.
    func showing(_ view: @escaping @MainActor (PopoverFixture) -> AnyView) -> PopoverState {
        var state = self
        state.view = view
        return state
    }

    /// The same state after something is done to the hosted popover, e.g. a time typed
    /// into its bedtime field.
    func interacting(_ interact: @escaping @MainActor (NSView) throws -> Void) -> PopoverState {
        var state = self
        state.interact = interact
        return state
    }

    static let twoDisplays = ["Built-in Retina Display", "Studio Display"]
    /// 61 characters.
    static let longName = "LG UltraFine 5K Thunderbolt Display in Conference Room 4 West"

    /// 18:40 in Chicago on the March equinox: the sun is a few degrees above the horizon,
    /// so Adaptive sits mid-band and both sunset and the bedtime ramp are still ahead.
    static let fixedNow = Date(timeIntervalSince1970: 1_774_050_000)
    static let fixedNowText = "2026-03-20T23:40:00Z"
    static let chicago = (latitude: 41.88, longitude: -87.63)

    /// Adaptive on, as the app would load it from a saved session.
    static func adaptive(_ extra: [String: Any] = [:]) -> [String: Any] {
        extra.merging(["redlight.adaptiveEnabled": true]) { saved, _ in saved }
    }

    static let all: [PopoverState] = [
        PopoverState("manual") { $0.manager.applyPreset(3) },
        PopoverState("auto", defaults: adaptive([
            "redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 1.0,
            "redlight.adaptiveWpMin": 0.45, "redlight.adaptiveWpMax": 1.0,
            "redlight.adaptiveBedtime": 22 * 60 + 30,
        ])),
        PopoverState("auto-no-location", defaults: adaptive(), location: .none(.denied)),
        PopoverState("paused", clock: .wall) {
            $0.manager.applyPreset(3)
            try #require($0.manager.pause())
        },
        PopoverState("one-display", displays: ["Built-in Retina Display"]) { $0.manager.applyPreset(3) },
        PopoverState("three-displays-long-name",
                     displays: ["Built-in Retina Display", longName, "Studio Display"]) {
            $0.manager.applyPreset(3)
        },
        PopoverState("no-displays", displays: []),
        PopoverState("display-off-inverted", off: [1], inverted: [2]) { $0.manager.applyPreset(3) },
        PopoverState("color-zero") { $0.manager.applyPreset(4) },
        PopoverState("color-full") { $0.manager.applyPreset(0) },
        PopoverState("pinned-band", defaults: adaptive([
            "redlight.adaptiveWpMin": 0.6, "redlight.adaptiveWpMax": 0.6,
        ])),
        PopoverState("sliders-nondefault") {
            $0.manager.intensity = 0.62
            $0.manager.whitepoint = 0.8
        },
        // Not in the brief: the only state that shows the AppKit text fields.
        PopoverState("auto-manual-location", defaults: adaptive(), location: .manual),

        // Auto with Location Services refused and never a fix: the Location row names the
        // time zone, because the bedtime line has taken the status line's place.
        PopoverState("auto-time-zone", defaults: adaptive(["redlight.adaptiveBedtime": 22 * 60 + 30])) {
            $0.location.automaticIsApproximate = true
            $0.location.authorization = .denied
            $0.manager.applyAdaptive()
        },
        // 03:00 is after solar midnight all year, so the curve ignores it: the ordinary
        // status line, and no bedtime on the arc.
        PopoverState("auto-inert-bedtime", defaults: adaptive(["redlight.adaptiveBedtime": 3 * 60])),
        // A time typed into the field but not applied yet: Set, after the field.
        PopoverState("auto-bedtime-draft", defaults: adaptive(["redlight.adaptiveBedtime": 22 * 60 + 30]))
            // The row copies the bedtime into its draft when it appears; type the time after.
            .interacting { try enterBedtime(Bedtime(hour: 23, minute: 0)!, in: $0) },
        // A preset chosen in Manual over a colour-temp limit set in Auto: Reset shows.
        PopoverState("manual-preset-hidden-limits", defaults: ["redlight.adaptiveMin": 0.2]) {
            $0.manager.applyPreset(3)
        },
        PopoverState("manual-save-target") { $0.manager.applyPreset(3) }
            .showing { $0.menuBarView(MenuBarInitialState(choosingSaveTarget: true)) },
        PopoverState("pause-lengths") { $0.manager.applyPreset(3) }
            .showing { $0.menuBarView(MenuBarInitialState(choosingPauseLength: true)) },
        PopoverState("command-error") { $0.manager.applyPreset(3) }
            .showing { $0.menuBarView(MenuBarInitialState(commandError: "The late preset is unavailable.")) },
        // The dot on the Settings button: an update, a login item waiting for approval.
        PopoverState("settings-dot") { $0.manager.applyPreset(3) }
            .showing { $0.menuBarView(MenuBarInitialState(updateAvailable: false, loginRequiresApproval: true)) },

        PopoverState("settings") { $0.manager.applyPreset(3) }
            .showing { $0.menuBarView(page: .settings, MenuBarInitialState(updateAvailable: false)) },
        PopoverState("settings-coordinates-error", defaults: adaptive(), location: .none(.denied))
            .showing {
                $0.menuBarView(page: .settings, MenuBarInitialState(
                    editingLocation: true, latitudeText: "91", longitudeText: "-87.63",
                    locationError: "Latitude must be a number from -90 to 90.", updateAvailable: false))
            },
        PopoverState("settings-update-approval") { $0.manager.applyPreset(3) }
            .showing {
                $0.menuBarView(page: .settings,
                               MenuBarInitialState(updateAvailable: true, loginRequiresApproval: true))
            },
        // Pause for apps unfolded: one app chosen, two more running.
        PopoverState("settings-apps") {
            $0.manager.applyPreset(3)
            $0.appSource.names = ["com.apple.Safari": "Safari"]
            $0.appSource.runningApps = [
                RunningApp(bundleID: "com.apple.Safari", name: "Safari", processID: 11),
                RunningApp(bundleID: "com.apple.Preview", name: "Preview", processID: 12),
                RunningApp(bundleID: "com.apple.finder", name: "Finder", processID: 13),
            ]
            try $0.apps.apply(.add("com.apple.Safari"))
        }.showing {
            $0.menuBarView(page: .settings, MenuBarInitialState(choosingApps: true, updateAvailable: false))
        },
        // The widest bar there is: "Quitting…", with an update waiting.
        PopoverState("settings-quitting") {
            $0.manager.applyPreset(3)
            $0.manager.beginTerminationFade {}
        }.showing { $0.menuBarView(page: .settings, MenuBarInitialState(updateAvailable: true)) },
        PopoverState("about") { $0.manager.applyPreset(3) }.showing { $0.menuBarView(page: .about) },
        // The README's picture: Auto a little after sunset. The sun arc follows the wall clock,
        // so the scene is wherever the sun has just set at the moment of the run: Lisbon, on
        // UTC in winter, for a run around noon in Chicago. Run it alone with
        // REDLIGHT_SNAPSHOT_STATES=readme.
        PopoverState("readme", displays: ["Studio Display", "iPad"], defaults: adaptive(),
                     location: .at(latitude: 38.72, longitude: -9.14), clock: .wall)
            .showing {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
                return AnyView($0.menuBarView()
                    .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone))
            },
    ]

    /// States that cannot be reached without changing source files, with the reason.
    static let unreachable: [(name: String, reason: String)] = []
}

// MARK: - Defaults

/// The one preferences domain a run uses. Every fixture starts from it emptied, and the
/// run removes it when it ends.
///
/// The domain is named by a path, so its file is `defaults.plist` in a directory of the
/// run's own under the temporary directory and nothing is added to ~/Library/Preferences.
/// The directory is named by process so that two runs at once cannot share state.
@MainActor
final class PopoverDefaultsStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PopoverSnapshotTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    let name: String
    private let defaults: UserDefaults

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        name = directory.appendingPathComponent("defaults").path
        defaults = try #require(UserDefaults(suiteName: name))
    }

    func emptied() -> UserDefaults {
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// False when the preferences daemon refused the write: a machine problem, not a
    /// harness one. Rendering does not depend on it.
    func synchronizes() -> Bool {
        defaults.synchronize()
    }

    /// Empties the domain and deletes its directory. The daemon can write the emptied file
    /// a moment after it is asked to, so keep deleting until the directory has stayed away
    /// for a second (three seconds at most).
    func remove() {
        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()
        var quietChecks = 0
        for _ in 0..<60 where quietChecks < 20 {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
                quietChecks = 0
            } else {
                quietChecks += 1
            }
            usleep(50_000)
        }
    }
}

// MARK: - Fixture

/// A manager in one state with live controls: a real `CommandHandler` over fake services,
/// a mock gamma controller, and the run's own defaults domain, emptied first.
@MainActor
final class PopoverFixture {
    let state: PopoverState
    let defaults: UserDefaults
    let gamma = MockGammaController()
    let location = FakeLocationProvider()
    let manager: DisplayManager
    let handler: CommandHandler
    let apps: AppSuspensionController
    /// What `apps` takes for the running apps; empty unless a state fills it.
    let appSource = FakeAppSource()
    /// Only reads `SMAppService.mainApp.status`; its setter is reached through `handler`,
    /// whose login service here is a no-op.
    let launchAtLogin = LaunchAtLogin()

    init(_ state: PopoverState, store: PopoverDefaultsStore) throws {
        self.state = state
        let defaults = store.emptied()
        self.defaults = defaults
        for (key, value) in state.defaults { defaults.set(value, forKey: key) }

        switch state.location {
        case .fix:
            location.coordinate = PopoverState.chicago
        case .none(let authorization):
            location.authorization = authorization
        case .manual:
            location.coordinate = PopoverState.chicago
            location.setManualCoordinate((latitude: 47.61, longitude: -122.33))
        case .at(let latitude, let longitude):
            location.coordinate = (latitude, longitude)
        }

        let names = state.displays
        let ids = names.indices.map { CGDirectDisplayID($0 + 1) }
        let wallClock = state.clock == .wall || PopoverEnvironment.usesWallClock
        manager = DisplayManager(
            gamma: gamma, getDisplayIDs: { ids },
            getDisplayName: { names[Int($0) - 1] },
            getDisplayPersistenceKey: { "snapshot-display-\($0)" },
            getMainDisplayID: { 1 }, defaults: defaults, location: location,
            now: wallClock ? { Date() } : { PopoverState.fixedNow },
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0, peekTransitionDuration: 0,
            locationPromptActivation: {})

        let apps = AppSuspensionController(
            source: appSource, defaults: defaults,
            ownBundleID: "com.redlight.snapshot", ownProcessID: 1)
        self.apps = apps
        handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "Snapshot" },
            apps: { apps.bundleIDs }, changeApps: { try apps.apply($0) }))

        for id in ids where !state.off.contains(id) { manager.setEnabled(true, for: id) }
        for id in ids where state.inverted.contains(id) { manager.setInverted(true, for: id) }
        try state.configure(self)
    }

    /// Stops the manager's timers and observers, as the app does on quit (gamma is a
    /// mock). The next fixture reuses the defaults domain, so a manager that SwiftUI
    /// keeps alive a little longer must not write to it.
    func retire() {
        manager.restoreAllDisplays()
    }

    /// The popover as the app builds it. This is the one call to `MenuBarView`'s
    /// initialiser, so a new trailing argument (`initialPage:`) is added here, or per
    /// state with `PopoverState.showing`.
    func menuBarView(page: MenuBarPage = .controls,
                     _ initialState: MenuBarInitialState = MenuBarInitialState()) -> AnyView {
        AnyView(MenuBarView(manager: manager, defaults: defaults, launchAtLogin: launchAtLogin, handler: handler,
                            openShortcuts: {}, apps: apps, initialState: initialState, initialPage: page))
    }

    /// The state's view and, for snapshots, a forced appearance. `menuBarView` hands the
    /// popover this run's defaults, so what it remembers never reaches the standard ones.
    func content(scheme: ColorScheme? = nil) -> AnyView {
        let view = state.view?(self) ?? menuBarView()
        guard let scheme else { return view }
        // The shown popover is the key window. This one never is, so say so here or the
        // controls SwiftUI draws itself (checkboxes) take their inactive, grey look.
        return AnyView(view
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
            .environment(\.controlActiveState, .key))
    }
}

extension PopoverState.Clock: Equatable {}

/// Enters a time in a hosted popover's bedtime field as its own editor does: the field
/// takes the value, then sends its action.
@MainActor
func enterBedtime(_ bedtime: Bedtime, in root: NSView) throws {
    func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
    let picker = try #require(walk(root).compactMap { $0 as? NSDatePicker }.first, "no bedtime field")
    picker.dateValue = BedtimeRow.date(for: bedtime)
    #expect(picker.sendAction(picker.action, to: picker.target), "the bedtime field has no action")
}

// MARK: - Offscreen host

/// The real popover content in a window that is never ordered in.
@MainActor
final class OffscreenPopover {
    let popover: NSPopover
    let window: NSWindow
    let scroll: NSScrollView
    let document: NSView
    let appearance: NSAppearance?

    init(content: AnyView, appearance: NSAppearance? = nil) throws {
        _ = NSApplication.shared
        self.appearance = appearance
        // No maximum height: the document takes its natural size.
        popover = StatusItemController.makePopover(content: content)
        let controller = try #require(popover.contentViewController)
        scroll = try #require(controller.view as? NSScrollView)
        document = try #require(scroll.documentView)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: popover.contentSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // AppKit-backed controls take their colours from the view's appearance, not from
        // SwiftUI's colour scheme.
        if let appearance {
            window.appearance = appearance
            popover.appearance = appearance
            scroll.appearance = appearance
            document.appearance = appearance
        }
        window.contentViewController = controller
        document.layoutSubtreeIfNeeded()
    }

    /// Lets SwiftUI's deferred work (appearance callbacks, the popover's own resize) land.
    func settle(turns: Int = 4) async {
        for _ in 0..<turns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            layout()
        }
    }

    func layout() {
        if window.contentLayoutRect.size != popover.contentSize {
            window.setContentSize(popover.contentSize)
        }
        document.layoutSubtreeIfNeeded()
    }

    /// A bitmap of the whole document at `scale` pixels per point, whatever the backing
    /// scale of the (absent) screen is.
    func makeBitmap(scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let size = document.bounds.size
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
        bitmap.size = size
        return bitmap
    }

    func draw(into bitmap: NSBitmapImageRep) {
        let document = document
        let draw = { document.cacheDisplay(in: document.bounds, to: bitmap) }
        if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
    }

    /// AppKit views SwiftUI placed in the document, with their frames in bitmap pixels.
    func hostedControls(scale: CGFloat = 2) -> [HostedControl] {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return walk(document).dropFirst().compactMap { view in
            guard view is NSControl, !view.isHidden, view.bounds.width > 1, view.bounds.height > 1
            else { return nil }
            var frame = view.convert(view.bounds, to: document)
            if !document.isFlipped { frame.origin.y = document.bounds.height - frame.maxY }
            let detail: String
            if let picker = view as? NSDatePicker {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
                detail = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            } else if let field = view as? NSTextField {
                detail = field.stringValue.isEmpty
                    ? "placeholder \(field.placeholderString ?? "")" : field.stringValue
            } else if let button = view as? NSButton {
                detail = button.title
            } else {
                detail = ""
            }
            return HostedControl(
                kind: String(describing: type(of: view)), detail: detail,
                pixels: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                               width: frame.width * scale, height: frame.height * scale).integral)
        }
    }

    func close() {
        window.close()
    }
}

struct HostedControl {
    var kind: String
    var detail: String
    /// Top-left origin, in bitmap pixels.
    var pixels: CGRect
}

// MARK: - Pixels

/// RGBA8 pixels, row 0 at the top.
struct Raster {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    /// A copy of the bitmap's premultiplied RGBA bytes.
    init(_ bitmap: NSBitmapImageRep) throws {
        width = bitmap.pixelsWide
        height = bitmap.pixelsHigh
        let source = try #require(bitmap.bitmapData)
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            pixels.withUnsafeMutableBytes { target in
                target.baseAddress!.advanced(by: row * width * 4)
                    .copyMemory(from: source.advanced(by: row * bitmap.bytesPerRow), byteCount: width * 4)
            }
        }
    }

    /// Premultiplied pixels over an opaque colour.
    func composited(over background: (r: UInt8, g: UInt8, b: UInt8)) -> Raster {
        var result = self
        let under = [Int(background.r), Int(background.g), Int(background.b)]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let clear = 255 - Int(pixels[index + 3])
            for channel in 0..<3 {
                result.pixels[index + channel] = UInt8(min(255,
                    Int(pixels[index + channel]) + (under[channel] * clear + 127) / 255))
            }
            result.pixels[index + 3] = 255
        }
        return result
    }

    /// Each channel pushed through its own 256-entry table. For opaque pixels only.
    func mapped(_ lookup: (r: [UInt8], g: [UInt8], b: [UInt8])) -> Raster {
        var result = self
        for index in stride(from: 0, to: pixels.count, by: 4) {
            result.pixels[index] = lookup.r[Int(pixels[index])]
            result.pixels[index + 1] = lookup.g[Int(pixels[index + 1])]
            result.pixels[index + 2] = lookup.b[Int(pixels[index + 2])]
        }
        return result
    }

    private func forEachPixel(in rect: CGRect?, _ body: (Int) -> Void) -> Int {
        let area = (rect ?? CGRect(x: 0, y: 0, width: width, height: height))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return 0 }
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) { body((y * width + x) * 4) }
        }
        return Int(area.width) * Int(area.height)
    }

    /// Share of pixels in `rect` that anything was drawn on. For a transparent capture.
    func coverage(in rect: CGRect? = nil) -> Double {
        var drawn = 0
        let count = forEachPixel(in: rect) { if pixels[$0 + 3] > 8 { drawn += 1 } }
        return count == 0 ? 0 : Double(drawn) / Double(count)
    }

    /// Share of pixels in `rect` where any channel is more than `tolerance` apart.
    func difference(from other: Raster, in rect: CGRect? = nil, tolerance: Int = 24) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var different = 0
        let count = forEachPixel(in: rect) { index in
            for channel in 0..<4
            where abs(Int(pixels[index + channel]) - Int(other.pixels[index + channel])) > tolerance {
                different += 1
                return
            }
        }
        return count == 0 ? 0 : Double(different) / Double(count)
    }

    func maximum(channel: Int) -> UInt8 {
        var result: UInt8 = 0
        for index in stride(from: channel, to: pixels.count, by: 4) { result = max(result, pixels[index]) }
        return result
    }

    /// Opaque sRGB PNG at 144 dpi, so viewers show a 2x capture at its point size.
    func writePNG(to url: URL, scale: CGFloat = 2) throws {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }
}

/// The app's transfer curve for the darkest preset (colour temp 0, white point 0.3) as
/// per-channel lookup tables: what `GammaTableComposer` would load into the display.
@MainActor
enum LateFilter {
    static let intensity: Float = 0
    static let whitepoint: Float = 0.3

    static let lookup: (r: [UInt8], g: [UInt8], b: [UInt8]) = {
        let identity = GammaTableComposer.resample(original: nil, tableSize: 256, invert: false)
        var table = GammaTableComposer.makeTable(size: 256)
        GammaTableComposer.render(identity, intensity: intensity, whitepoint: whitepoint, into: &table)
        func bytes(_ channel: [CGGammaValue]) -> [UInt8] {
            channel.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        }
        return (bytes(table.r), bytes(table.g), bytes(table.b))
    }()
}

// MARK: - Environment

enum PopoverEnvironment {
    private static let values = ProcessInfo.processInfo.environment

    static var snapshotDirectory: URL? {
        guard let path = values["REDLIGHT_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Nil means every state.
    static var snapshotStates: Set<String>? {
        guard let list = values["REDLIGHT_SNAPSHOT_STATES"], !list.isEmpty else { return nil }
        return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    static var usesWallClock: Bool { values["REDLIGHT_SNAPSHOT_CLOCK"] == "wall" }
    static var timingEnabled: Bool { values["REDLIGHT_POPOVER_TIMING"] == "1" }
}

// MARK: - Tests

@MainActor @Suite(.serialized) struct PopoverSnapshotTests {
    static let schemes: [(name: String, scheme: ColorScheme, appearance: NSAppearance.Name)] = [
        ("light", .light, .aqua), ("dark", .dark, .darkAqua),
    ]

    private struct Shot {
        var raw: Raster
        var controls: [HostedControl]
    }

    @Test(.enabled(if: PopoverEnvironment.snapshotDirectory != nil))
    func writesSnapshotsOfEveryState() async throws {
        let directory = try #require(PopoverEnvironment.snapshotDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PopoverDefaultsStore()
        defer { store.remove() }
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            print("POPOVER-SNAPSHOT \(line)")
        }
        note("clock manager=\(PopoverEnvironment.usesWallClock ? "wall" : "fixed \(PopoverState.fixedNowText)") "
            + "sun-arc=wall pause-countdown=wall")
        note("late-filter intensity=\(LateFilter.intensity) whitepoint=\(LateFilter.whitepoint) "
            + "white→(\(LateFilter.lookup.r[255]),\(LateFilter.lookup.g[255]),\(LateFilter.lookup.b[255])) "
            + "max-red=\(LateFilter.lookup.r.max() ?? 0)")

        let wanted = PopoverEnvironment.snapshotStates
        for state in PopoverState.all where wanted?.contains(state.name) ?? true {
            var shots: [String: Shot] = [:]
            for (name, scheme, appearanceName) in Self.schemes {
                let appearance = try #require(NSAppearance(named: appearanceName))
                let fixture = try PopoverFixture(state, store: store)
                let host = try OffscreenPopover(content: fixture.content(scheme: scheme), appearance: appearance)
                defer {
                    host.close()
                    fixture.retire()
                }
                await host.settle()
                if let interact = state.interact {
                    try interact(host.document)
                    await host.settle()
                }

                let bitmap = try host.makeBitmap()
                host.draw(into: bitmap)
                let raw = try Raster(bitmap)
                #expect(raw.width == 600, "\(state.name)-\(name) is \(raw.width) px wide")
                #expect(raw.coverage() > 0.01, "\(state.name)-\(name) drew almost nothing")

                // The popover's own surface is a system material that only exists on
                // screen; stand in the window background of the same appearance.
                let composed = raw.composited(over: Self.background(appearance))
                let late = composed.mapped(LateFilter.lookup)
                #expect(late.maximum(channel: 1) == 0 && late.maximum(channel: 2) == 0)
                try composed.writePNG(to: directory.appendingPathComponent("\(state.name)-\(name).png"))
                try late.writePNG(to: directory.appendingPathComponent("\(state.name)-\(name)-late.png"))

                let controls = host.hostedControls()
                shots[name] = Shot(raw: raw, controls: controls)
                note("\(state.name)-\(name) \(raw.width)x\(raw.height)px "
                    + "coverage=\(Self.percent(raw.coverage())) appkit-controls=\(controls.count)")
                for control in controls {
                    let coverage = raw.coverage(in: control.pixels)
                    note("  \(coverage < 0.005 ? "BLANK" : "drawn") \(control.kind) "
                        + "\(Int(control.pixels.width))x\(Int(control.pixels.height))px "
                        + "coverage=\(Self.percent(coverage)) \(control.detail)")
                }
            }

            let light = try #require(shots["light"]), dark = try #require(shots["dark"])
            let difference = light.raw.difference(from: dark.raw)
            #expect(difference > 0.005, "\(state.name): light and dark captures are the same")
            // The same control in both appearances: an AppKit control that ignored the
            // forced appearance would draw identically.
            var unchanged: [String] = []
            if light.controls.map(\.kind) == dark.controls.map(\.kind) {
                for (a, b) in zip(light.controls, dark.controls)
                where a.pixels == b.pixels && light.raw.difference(from: dark.raw, in: a.pixels) < 0.005 {
                    unchanged.append("\(a.kind) \(a.detail)")
                }
            }
            note("\(state.name) light-vs-dark differing=\(Self.percent(difference)) "
                + "appkit-controls-identical-in-both=\(unchanged.isEmpty ? "none" : unchanged.joined(separator: ", "))")
        }

        note("preferences domains=1 (\(store.name), removed with its file when the run ends) "
            + "synchronize=\(store.synchronizes() ? "ok" : "FAILED: the preferences daemon refused the write")")
        for skipped in PopoverState.unreachable { note("SKIPPED \(skipped.name): \(skipped.reason)") }
        try (report.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: PopoverEnvironment.timingEnabled))
    func reportsPopoverTiming() async throws {
        let store = try PopoverDefaultsStore()
        defer { store.remove() }
        var load = [Double](repeating: 0, count: 1)
        getloadavg(&load, 1)
        // A tick is: write the value, `layoutSubtreeIfNeeded` (update), `cacheDisplay` of
        // the whole document into a 2x bitmap (draw). Compare runs at a similar load.
        var lines = ["POPOVER-TIMING begin build=\(Self.buildConfiguration) gamma=mock "
            + "render=cacheDisplay@2x window=offscreen " + String(format: "load-average=%.1f", load[0])]
        for name in ["manual", "auto"] {
            let state = try #require(PopoverState.all.first { $0.name == name })
            lines += try await Self.timing(of: state, store: store)
        }
        lines.append("POPOVER-TIMING end")
        print(lines.joined(separator: "\n"))
    }

    // MARK: Timing

    private static func timing(of state: PopoverState, store: PopoverDefaultsStore) async throws -> [String] {
        let clock = ContinuousClock()
        var lines: [String] = []
        func line(_ label: String, _ samples: [Double], _ extra: String = "") {
            let sorted = samples.sorted()
            let mean = samples.reduce(0, +) / Double(max(1, samples.count))
            func percentile(_ p: Double) -> Double {
                sorted[max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
            }
            // The median and minimum hold up on a busy machine; the mean and maximum do not.
            lines.append(String(
                format: "POPOVER-TIMING %@ %@ n=%d mean=%.3fms p95=%.3fms max=%.3fms median=%.3fms min=%.3fms%@",
                state.name, label, samples.count, mean, percentile(0.95), sorted.last ?? 0,
                percentile(0.5), sorted.first ?? 0, extra.isEmpty ? "" : " " + extra))
        }

        // Construction: content view, hosting controller and first fitting size.
        let fixture = try PopoverFixture(state, store: store)
        var construction: [Double] = []
        for _ in 0..<11 {
            let start = clock.now
            let popover = StatusItemController.makePopover(content: fixture.content())
            construction.append(milliseconds(clock.now - start))
            withExtendedLifetime(popover) {}
        }
        // The first one pays for one-time framework setup; it is reported on its own.
        line("construct", Array(construction.dropFirst()),
             String(format: "first=%.3fms", construction[0]))

        let host = try OffscreenPopover(content: fixture.content())
        defer {
            host.close()
            fixture.retire()
        }
        await host.settle()
        let manager = fixture.manager

        // One slider tick: write the value, lay out, draw the document into a bitmap.
        func ticks(_ label: String, in range: ClosedRange<Double>, set: (Double) -> Void) throws {
            let bitmap = try host.makeBitmap()
            let byteCount = bitmap.bytesPerRow * bitmap.pixelsHigh
            let data = try #require(bitmap.bitmapData)
            var previous = [UInt8](repeating: 0, count: byteCount)
            var total: [Double] = [], model: [Double] = [], layout: [Double] = [], drawing: [Double] = []
            var changed = 0
            let warmUp = 10, count = 200
            for tick in 0..<(warmUp + count) {
                // Up the range and back down, so every tick is a new value.
                let step = tick % 300
                let fraction = Double(step < 150 ? step : 300 - step) / 150
                let value = range.lowerBound + (range.upperBound - range.lowerBound) * fraction
                memset(data, 0, byteCount)
                // The loop never returns to the run loop, so release each tick's
                // temporaries here, outside the timed part.
                let (start, written, laidOut, end) = autoreleasepool {
                    let start = clock.now
                    set(value)
                    let written = clock.now
                    host.document.layoutSubtreeIfNeeded()
                    let laidOut = clock.now
                    host.draw(into: bitmap)
                    return (start, written, laidOut, clock.now)
                }
                let same = previous.withUnsafeBytes { memcmp($0.baseAddress!, data, byteCount) == 0 }
                previous.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: data, byteCount: byteCount) }
                guard tick >= warmUp else { continue }
                if !same { changed += 1 }
                total.append(milliseconds(end - start))
                model.append(milliseconds(written - start))
                layout.append(milliseconds(laidOut - written))
                drawing.append(milliseconds(end - laidOut))
            }
            // Medians of the parts: the manager's own work (mock gamma, saving), SwiftUI's
            // update and layout, and the drawing.
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            line(label, total, String(
                format: "median-parts: model=%.3fms layout=%.3fms draw=%.3fms frames-changed=%d/%d",
                median(model), median(layout), median(drawing), changed, count))
        }
        let intensityRange = manager.adaptiveEnabled ? manager.intensityBand : 0...1
        let whitepointRange = manager.adaptiveEnabled ? manager.whitepointBand : 0.25...1
        try ticks("intensity-tick", in: intensityRange) { manager.intensity = $0 }
        try ticks("whitepoint-tick", in: whitepointRange) { manager.whitepoint = $0 }

        // Mode switch: flip Adaptive, let the popover resize, draw at the new size.
        var bitmaps: [String: NSBitmapImageRep] = [:]
        var switching: [Double] = []
        var heights: Set<Int> = []
        for flip in 0..<22 {
            let start = clock.now
            manager.adaptiveEnabled.toggle()
            await host.settle(turns: 3)
            let key = "\(host.document.bounds.size)"
            if bitmaps[key] == nil { bitmaps[key] = try host.makeBitmap() }
            host.draw(into: try #require(bitmaps[key]))
            heights.insert(Int(host.document.bounds.height))
            // The first pair builds each mode's views and bitmap for the first time.
            if flip >= 2 { switching.append(milliseconds(clock.now - start)) }
        }
        line("mode-switch", switching,
             "heights=\(heights.sorted().map(String.init).joined(separator: "/"))pt settle-turns=3")
        return lines
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    // MARK: Helpers

    private static func background(_ appearance: NSAppearance) -> (r: UInt8, g: UInt8, b: UInt8) {
        var result: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)
        appearance.performAsCurrentDrawingAppearance {
            guard let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) else { return }
            func byte(_ component: CGFloat) -> UInt8 { UInt8((min(1, max(0, component)) * 255).rounded()) }
            result = (byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
        }
        return result
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }
}
