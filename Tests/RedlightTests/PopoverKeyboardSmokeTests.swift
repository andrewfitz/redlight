import AppKit
import SwiftUI
import Testing
@testable import Redlight

// The real-popover tier: a real `NSPopover`, built as `StatusItemController` builds it and
// shown from an anchor window, driven with real `NSEvent`s through `NSApp.sendEvent`. The
// regular suite renders offscreen and never shows a window, so this tier is off unless
// asked for:
//
//   backstage start        (the hidden display; nothing is shown without it)
//   REDLIGHT_TEST_POPOVER_KEYBOARD=1 swift test --filter PopoverKeyboardSmoke
//
// Nothing here appears on the user's screens or takes their keyboard:
// - Every window is placed on the hidden display (a screen whose name contains
//   "Backstage", or REDLIGHT_TEST_POPOVER_SCREEN). Without that screen each test fails
//   before it shows anything.
// - The test process is never activated. It keeps the activation policy it starts with,
//   under which macOS does not let it come to the front, and the tests require that.
//   Only an active app has a key window, so the popover's window is made to report that it
//   is key (`SimulatedKeyState`). The window, its responder chain, SwiftUI's focus and
//   AppKit's event dispatch are the real ones; what is not exercised is `NSApp.activate()`
//   and the window server handing the popover the keyboard.
// - No key is sent that nothing handles: a window answers such a key with the alert sound.
//
// REDLIGHT_TEST_POPOVER_ACTIVATE=1 activates the app for real instead, as the controller
// does. Only for a run under `backstage launch`, which keeps the keyboard with the user
// (it needs Accessibility granted to the terminal that starts it):
//
//   backstage launch <toolchain>/usr/libexec/swift/pm/swiftpm-testing-helper \
//     --env REDLIGHT_TEST_POPOVER_KEYBOARD=1 --env REDLIGHT_TEST_POPOVER_ACTIVATE=1 -- \
//     --test-bundle-path <bundle>/Contents/MacOS/RedlightTests --filter PopoverKeyboardSmoke \
//     <bundle>/Contents/MacOS/RedlightTests --testing-library swift-testing
//
// REDLIGHT_TEST_POPOVER_SHOTS=/some/dir also writes pictures of the shown popover, taken
// from the window server, in light and dark.

enum LivePopoverEnvironment {
    private static let values = ProcessInfo.processInfo.environment
    static let enabled = values["REDLIGHT_TEST_POPOVER_KEYBOARD"] == "1"
    static let activates = values["REDLIGHT_TEST_POPOVER_ACTIVATE"] == "1"
    static let screenName = values["REDLIGHT_TEST_POPOVER_SCREEN"] ?? "Backstage"
    static let shotDirectory: URL? = values["REDLIGHT_TEST_POPOVER_SHOTS"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
    }
}

// MARK: - Key state without activation

/// Makes one window report that it is key, and the app that it is active with that key
/// window, for as long as the popover is up. AppKit moves the focus on Tab only in the
/// app's key window, and SwiftUI gives the keyboard to a focused view only there. The three
/// getters are replaced in place and put back; nothing outside this process is told anything.
@MainActor
private enum SimulatedKeyState {
    nonisolated(unsafe) static weak var window: NSWindow?
    private static var replaced: [(method: Method, original: IMP, stand: IMP)] = []

    static func begin(_ window: NSWindow) {
        self.window = window
        typealias Flag = @convention(c) (AnyObject, Selector) -> Bool
        let isKey = #selector(getter: NSWindow.isKeyWindow)
        replace(isKey, in: object_getClass(window)) { original in
            let before = unsafeBitCast(original, to: Flag.self)
            let block: @convention(block) (AnyObject) -> Bool = { object in
                object === SimulatedKeyState.window || before(object, isKey)
            }
            return imp_implementationWithBlock(block)
        }
        replace(#selector(getter: NSApplication.isActive), in: object_getClass(NSApplication.shared)) { _ in
            let block: @convention(block) (AnyObject) -> Bool = { _ in true }
            return imp_implementationWithBlock(block)
        }
        replace(#selector(getter: NSApplication.keyWindow), in: object_getClass(NSApplication.shared)) { _ in
            let block: @convention(block) (AnyObject) -> NSWindow? = { _ in SimulatedKeyState.window }
            return imp_implementationWithBlock(block)
        }
        window.becomeKey()
    }

    static func end() {
        window?.resignKey()
        for entry in replaced.reversed() {
            method_setImplementation(entry.method, entry.original)
            imp_removeBlock(entry.stand)
        }
        replaced = []
        window = nil
    }

    private static func replace(_ selector: Selector, in type: AnyClass?, with make: (IMP) -> IMP) {
        guard let type, let method = class_getInstanceMethod(type, selector) else { return }
        let original = method_getImplementation(method)
        let stand = make(original)
        method_setImplementation(method, stand)
        replaced.append((method, original, stand))
    }
}

// MARK: - Run loop

/// Runs `body` inside a run-loop turn of its own.
///
/// An app handles its events inside `NSApplication.run`. A test process has only the plain
/// run loop that the Swift runtime started, and ends as soon as that one is stopped. AppKit
/// stops the current run loop now and then while it handles an event (a limit drag does),
/// which an app's own loop takes in its stride. Inside a turn of its own, that stop ends
/// the turn and nothing else.
@MainActor
func inRunLoopTurn(_ body: @MainActor () throws -> Void) throws {
    final class Outcome: @unchecked Sendable {
        var result: Result<Void, Error>?
    }
    let outcome = Outcome()
    try withoutActuallyEscaping(body) { body in
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { outcome.result = Result { try body() } }
        }
        while outcome.result == nil { CFRunLoopRunInMode(.defaultMode, 0.05, false) }
        try outcome.result?.get()
    }
}

// MARK: - Fixture

/// A manager over a mock gamma controller and fake services, at a fixed moment: the early
/// afternoon in Chicago on the March equinox, when Auto rests on the top of its bands.
@MainActor
final class LivePopoverFixture {
    static let afternoon = Date(timeIntervalSince1970: 1_774_030_000)

    private let registry = TestDefaultsRegistry()
    let defaults: UserDefaults
    let location = FakeLocationProvider()
    let gamma = MockGammaController()
    let manager: DisplayManager
    let handler: CommandHandler

    init(defaults values: [String: Any] = [:], manualLocation: Bool = false,
         displays: [String] = ["Built-in Retina Display"],
         coordinate: (latitude: Double, longitude: Double) = (41.88, -87.63),
         now: @escaping () -> Date = { LivePopoverFixture.afternoon }) {
        let defaults = registry.makeDefaults()
        self.defaults = defaults
        // These check Auto's own behaviour: Learn my adjustments, on by default, is off here
        // unless a test asks for it.
        defaults.set(false, forKey: "redlight.learningEnabled")
        for (key, value) in values { defaults.set(value, forKey: key) }
        location.coordinate = coordinate
        if manualLocation { location.setManualCoordinate(coordinate) }
        let ids = displays.indices.map { CGDirectDisplayID($0 + 1) }
        manager = DisplayManager(
            gamma: gamma, getDisplayIDs: { ids },
            getDisplayName: { displays[Int($0) - 1] }, getDisplayPersistenceKey: { "live-display-\($0)" },
            getMainDisplayID: { 1 }, defaults: defaults, location: location,
            now: now,
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0, peekTransitionDuration: 0,
            locationPromptActivation: {})
        handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "Test" }))
        for id in ids { manager.setEnabled(true, for: id) }
    }

    static func auto(_ extra: [String: Any] = [:]) -> LivePopoverFixture {
        LivePopoverFixture(defaults: extra.merging(["redlight.adaptiveEnabled": true]) { saved, _ in saved })
    }

    func view(page: MenuBarPage = .controls,
              _ initialState: MenuBarInitialState = MenuBarInitialState()) -> MenuBarView {
        MenuBarView(manager: manager, defaults: defaults, handler: handler,
                    initialState: initialState, initialPage: page)
    }

    /// Everything a stray key press could change.
    var settings: [String] {
        ["on \(manager.isOn)", "auto \(manager.adaptiveEnabled)", "paused \(manager.isPaused)",
         "color \(manager.intensity) in \(manager.adaptiveMin)...\(manager.adaptiveMax)",
         "white \(manager.whitepoint) in \(manager.adaptiveWpMin)...\(manager.adaptiveWpMax)",
         "preset \(String(describing: manager.activePresetIndex))",
         "bedtime \(String(describing: manager.bedtime))",
         "displays \(manager.displays.map { "\($0.isEnabled)/\($0.isInverted)" })"]
    }

    func retire() {
        manager.restoreAllDisplays()
    }
}

// MARK: - The shown popover

enum LiveKey {
    case tab, space, escape, enter, left, right, home, end
    case character(Character)

    var code: UInt16 {
        switch self {
        case .tab: 48
        case .space: 49
        case .escape: 53
        case .enter: 36
        case .left: 123
        case .right: 124
        case .home: 115
        case .end: 119
        case .character(let character):
            ["-": 27, "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28,
             "9": 25, ".": 47][character] ?? 0
        }
    }

    var characters: String {
        switch self {
        case .tab: "\t"
        case .space: " "
        case .escape: "\u{1b}"
        case .enter: "\r"
        case .left: "\u{F702}"
        case .right: "\u{F703}"
        case .home: "\u{F729}"
        case .end: "\u{F72B}"
        case .character(let character): String(character)
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .left, .right: [.numericPad, .function]
        case .home, .end: [.function]
        default: []
        }
    }
}

/// One slider's pill in the document, found from its keyboard stop, which covers the pill.
struct LiveSlider {
    /// In the document's coordinates.
    let pill: CGRect

    /// The size of a popover slider's keyboard stop: the pill.
    static let size = CGSize(width: EmberMetrics.width - 2 * EmberMetrics.padding, height: EmberMetrics.sliderHeight)
    /// The length of track the whole range is drawn along.
    static let usableWidth = Double(size.width - 2 * EmberSliderFace.inset)

    /// A point `x` along the pill and `dy` below its centre line.
    func point(x: CGFloat, dy: CGFloat = 0) -> CGPoint {
        CGPoint(x: pill.minX + x, y: pill.midY + dy)
    }

    /// Where the grabber is drawn for `value`, along the pill.
    func x(for value: Double, range: ClosedRange<Double>) -> CGFloat {
        EmberSliderFace.x(for: value, width: pill.width, range: range)
    }
}

/// Set from a notification's block, which is `@Sendable`. Only ever touched on the main thread.
private final class LiveFlag: @unchecked Sendable {
    var isSet = false
}

@MainActor
final class LivePopover {
    let popover: NSPopover
    let window: NSWindow
    let scroll: NSScrollView
    let document: NSView
    private let anchor: NSWindow
    private var isClosed = false
    /// True when the popover posted that it had shown before the harness went on.
    private(set) var sawDidShow = false

    enum LiveError: Error {
        /// A window came up on another screen than the hidden one. It was closed at once.
        case wrongScreen(String)
        case notShownAndKey
    }

    /// Shows the popover the way `StatusItemController.togglePopover` and `popoverDidShow` do.
    init<Content: View>(_ content: Content, appearance: NSAppearance? = nil, animated: Bool = false) throws {
        let app = NSApplication.shared
        LivePopover.armWatchdog()
        let name = LivePopoverEnvironment.screenName
        let screen = try #require(
            NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(name) },
            "no screen named \(name): start the hidden display first (`backstage start`)")
        if LivePopoverEnvironment.activates {
            app.setActivationPolicy(.accessory)
        } else {
            // A prohibited app cannot come to the front, whatever a mouse-down would ask for.
            try #require(app.activationPolicy() == .prohibited,
                         "this process can be activated: run the tier on its own, with --filter PopoverKeyboardSmoke")
        }
        let maximumHeight = screen.visibleFrame.height - 30
        let popover = StatusItemController.makePopover(maximumHeight: maximumHeight, content: content)
        // The app's popover animates in. Most tests have no use for the wait.
        if !animated { popover.animates = false }
        if let appearance { popover.appearance = appearance }
        let didShow = LiveFlag()
        let observer = NotificationCenter.default.addObserver(
            forName: NSPopover.didShowNotification, object: popover, queue: nil) { _ in didShow.isSet = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        let scroll = try #require(popover.contentViewController?.view as? NSScrollView)
        let document = try #require(scroll.documentView)
        // Where a status item would be: the top of the screen, the popover hanging below.
        let origin = CGPoint(x: screen.frame.midX - 12, y: screen.visibleFrame.maxY - 30)
        let anchor = NSWindow(contentRect: NSRect(origin: origin, size: CGSize(width: 25, height: 25)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        let anchorView = try #require(anchor.contentView)
        anchor.orderFront(nil)
        guard anchor.screen === screen else {
            anchor.close()
            throw LiveError.wrongScreen(anchor.screen?.localizedName ?? "none")
        }
        // A handle that takes the focus shows it only when a key press brought the focus,
        // which it tells from the event being handled. The app opens on a click, so no key
        // press from an earlier test may be the last event when this popover opens.
        if let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: anchor.windowNumber,
            context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
            while let next = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05),
                                             inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
            }
        }
        if LivePopoverEnvironment.activates { app.activate() }
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        StatusItemController.prepareShown(popover)
        guard let window = popover.contentViewController?.view.window, window.screen === screen else {
            let found = popover.contentViewController?.view.window?.screen?.localizedName ?? "none"
            popover.close()
            anchor.close()
            throw LiveError.wrongScreen(found)
        }
        self.popover = popover
        self.scroll = scroll
        self.document = document
        self.anchor = anchor
        self.window = window
        if let appearance { window.appearance = appearance }
        // `popoverDidShow`, when the popover says it has shown: after its animation, if any.
        let shownBy = Date().addingTimeInterval(3)
        while !didShow.isSet, Date() < shownBy { pump(0.02) }
        sawDidShow = didShow.isSet
        StatusItemController.installSurface(in: popover)
        if LivePopoverEnvironment.activates {
            let deadline = Date().addingTimeInterval(3)
            while !app.isActive, Date() < deadline { pump(0.05) }
            window.makeKey()
        } else {
            SimulatedKeyState.begin(window)
            // The first window of a process takes the key state only the second time it is
            // told: until then SwiftUI starts no gesture in it. Later windows do not care.
            pump(0.1)
            window.resignKey()
            window.becomeKey()
        }
        pump(0.3)
        guard popover.isShown, window.isKeyWindow else {
            close()
            throw LiveError.notShownAndKey
        }
    }

    /// A press that waits for a release that never comes would hang the run with a window
    /// up, so the process ends itself instead.
    private static var watchdogArmed = false
    private static func armWatchdog() {
        guard !watchdogArmed else { return }
        watchdogArmed = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("live popover tier: no end after 180 s, exiting\n".utf8))
            exit(3)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if !LivePopoverEnvironment.activates { SimulatedKeyState.end() }
        popover.close()
        anchor.close()
        // Whatever the windows still have to do, they do inside this test's turn.
        pump(0.5)
    }

    // MARK: Events

    /// Takes events off the queue and dispatches them as `NSApplication.run` does, so the
    /// event being handled is `NSApp.currentEvent`, and gives SwiftUI its turns.
    func pump(_ seconds: TimeInterval = 0.1) {
        let deadline = Date().addingTimeInterval(seconds)
        while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        document.layoutSubtreeIfNeeded()
    }

    func key(_ key: LiveKey, shift: Bool = false, settle: TimeInterval = 0.25) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.modifiers.union(shift ? .shift : []),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
            isARepeat: false, keyCode: key.code))
        NSApp.postEvent(event, atStart: false)
        pump(settle)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: document.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// A press and a release at one point of the document. Both are queued before either is
    /// handled: an AppKit control follows the mouse in a loop of its own from the press on.
    func click(at point: CGPoint) throws {
        NSApp.postEvent(try mouse(.leftMouseDown, at: point), atStart: false)
        NSApp.postEvent(try mouse(.leftMouseUp, at: point), atStart: false)
        pump(0.25)
    }

    /// A press at `start`, a drag by `dx` in steps, and a release, each handled on its own
    /// turn. With `dx` 0 the pointer does not move between the press and the release.
    /// `beforeRelease` runs with the button still down, after the last step.
    func drag(from start: CGPoint, dx: CGFloat, steps: Int = 5,
              beforeRelease: @MainActor () throws -> Void = {}) throws {
        NSApp.postEvent(try mouse(.leftMouseDown, at: start), atStart: false)
        pump(0.1)
        var end = start
        if dx != 0 {
            for step in 1...steps {
                end = CGPoint(x: start.x + dx * CGFloat(step) / CGFloat(steps), y: start.y)
                NSApp.postEvent(try mouse(.leftMouseDragged, at: end), atStart: false)
                pump(0.05)
            }
        }
        try beforeRelease()
        NSApp.postEvent(try mouse(.leftMouseUp, at: end), atStart: false)
        pump(0.3)
    }

    // MARK: What is there

    func views() -> [NSView] {
        func walk(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(walk) }
        return walk(document)
    }

    func frame(of view: NSView) -> CGRect {
        view.convert(view.bounds, to: document)
    }

    /// The first responder's frame in the document. Nil when it is the window or no view.
    var focusFrame: CGRect? {
        guard let view = window.firstResponder as? NSView, view.isDescendant(of: document) else { return nil }
        return frame(of: view)
    }

    var focusDescription: String {
        guard let responder = window.firstResponder else { return "nothing" }
        guard let view = responder as? NSView else { return "\(type(of: responder))" }
        return "\(type(of: view)) \(frame(of: view))"
    }

    /// The views the Tab key stops at, in the order AppKit visits them from the first.
    func keyViewLoop(limit: Int = 40) -> [CGRect] {
        guard let first = views().first(where: { $0.canBecomeKeyView }) else { return [] }
        var frames = [frame(of: first)]
        var cursor = first.nextValidKeyView
        while let view = cursor, view !== first, frames.count < limit {
            frames.append(frame(of: view))
            cursor = view.nextValidKeyView
        }
        return frames
    }

    /// The popover's sliders, top to bottom: each has one focusable view, the size of its pill.
    func sliders() throws -> [LiveSlider] {
        let pills = views()
            .filter { $0.acceptsFirstResponder && $0.bounds.size == LiveSlider.size }
            .map(frame(of:))
            .sorted { $0.minY < $1.minY }
        try #require(!pills.isEmpty, "no slider pill among the focusable views")
        return pills.map(LiveSlider.init(pill:))
    }

    /// The Auto limit flags' keyboard stops, row by row and left to right: minimum then
    /// maximum under each slider (one spot for both under a pinned band).
    func flagStops() throws -> [CGRect] {
        let size = CGSize(width: EmberFlagFace.hitWidth, height: EmberFlagFace.chipHeight)
        let thumbs = views()
            .filter { $0.acceptsFirstResponder && $0.bounds.size == size }
            .map(frame(of:))
            .sorted { (a: CGRect, b: CGRect) -> Bool in
                let sameRow = abs(a.midY - b.midY) <= 1
                return sameRow ? a.midX < b.midX : a.midY < b.midY
            }
        try #require(!thumbs.isEmpty, "no flag among the focusable views")
        return thumbs
    }

    // MARK: Pixels

    /// The document as it is drawn now, at `scale` pixels per point.
    func raster(scale: CGFloat = 2) throws -> Raster {
        let size = document.bounds.size
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
        bitmap.size = size
        let document = document
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            document.cacheDisplay(in: document.bounds, to: bitmap)
        }
        return try Raster(bitmap)
    }

    /// The height in points of the mark drawn in the column `x` of a slider's pill: the run
    /// of pixels around the centre line that are not the colour found `clear` points to the
    /// side, which must be bare fill.
    func markHeight(in slider: LiveSlider, x: CGFloat, clear: CGFloat = -14, scale: CGFloat = 2) throws -> CGFloat {
        let raster = try raster(scale: scale)
        let column = Int(((slider.pill.minX + x) * scale).rounded(.down))
        let reference = Int(((slider.pill.minX + x + clear) * scale).rounded(.down))
        let middle = Int((slider.pill.midY * scale).rounded(.down))
        func differs(_ row: Int) -> Bool {
            let a = raster.pixel(x: column, y: row), b = raster.pixel(x: reference, y: row)
            return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 60
        }
        guard differs(middle) else { return 0 }
        var top = middle, bottom = middle
        let limit = Int(slider.pill.height * scale)
        while middle - top < limit, differs(top - 1) { top -= 1 }
        while bottom - middle < limit, differs(bottom + 1) { bottom += 1 }
        return CGFloat(bottom - top + 1) / scale
    }

    /// The popover's window as the window server composites it, without its shadow. A
    /// process may always capture its own windows. Nil when the call is not available.
    func windowImage() -> CGImage? {
        typealias Function = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // Swift no longer declares it; the window server still serves it.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let function = unsafeBitCast(symbol, to: Function.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return function(.null, includingWindow, UInt32(window.windowNumber),
                        boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }
}

extension Raster {
    /// Straight (not premultiplied) RGBA of an image, row 0 at the top.
    init(image: CGImage) throws {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, Int(bytes[index + channel]) * 255 / alpha))
            }
        }
        self.width = width
        self.height = height
        self.pixels = bytes
    }

    func pixel(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let index = (y * width + x) * 4
        return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]), Int(pixels[index + 3]))
    }

    /// The first and last opaque pixel of a row, or nil for a row with none.
    func opaqueRun(row: Int) -> ClosedRange<Int>? {
        let opaque = (0..<width).filter { pixel(x: $0, y: row).a > 128 }
        guard let first = opaque.first, let last = opaque.last else { return nil }
        return first...last
    }

    /// Straight pixels on a flat colour, so that what is transparent shows.
    func shown(on color: (r: Int, g: Int, b: Int)) -> Raster {
        var result = self
        let back = [color.r, color.g, color.b]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            for channel in 0..<3 {
                result.pixels[index + channel] =
                    UInt8((Int(pixels[index + channel]) * alpha + back[channel] * (255 - alpha)) / 255)
            }
            result.pixels[index + 3] = 255
        }
        return result
    }

    /// A part of this raster, each pixel repeated `zoom` times.
    func cropped(x originX: Int, y originY: Int, width cropWidth: Int, height cropHeight: Int, zoom: Int) -> Raster {
        var result = self
        result.width = cropWidth * zoom
        result.height = cropHeight * zoom
        result.pixels = [UInt8](repeating: 0, count: result.width * result.height * 4)
        for y in 0..<result.height {
            for x in 0..<result.width {
                let source = pixel(x: originX + x / zoom, y: originY + y / zoom)
                let index = (y * result.width + x) * 4
                result.pixels[index] = UInt8(source.r)
                result.pixels[index + 1] = UInt8(source.g)
                result.pixels[index + 2] = UInt8(source.b)
                result.pixels[index + 3] = UInt8(source.a)
            }
        }
        return result
    }
}

// MARK: - Tests

@MainActor @Suite(.serialized) struct PopoverKeyboardSmokeTests {
    private static let colorRange = 0.0...1.0

    private func note(_ line: String) {
        FileHandle.standardError.write(Data("LIVE \(line)\n".utf8))
    }

    // MARK: The surface

    /// The Ember surface beneath the content fills the popover's outline, arrow included,
    /// and nothing outside it.
    @Test(.enabled(if: LivePopoverEnvironment.enabled), arguments: ["light", "dark"])
    func surfaceFillsThePopoverOutline(scheme: String) async throws {
        try inRunLoopTurn {
            let isDark = scheme == "dark"
            let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
            let fixture = LivePopoverFixture.auto()
            defer { fixture.retire() }
            let live = try LivePopover(
                fixture.view().environment(\.colorScheme, isDark ? .dark : .light), appearance: appearance)
            defer { live.close() }
            // Long enough for the window server to have the first frames.
            live.pump(0.6)

            let frameView = try #require(live.window.contentView?.superview)
            let surface = try #require(frameView.subviews.first { $0 is PopoverSurfaceView })
            note("surface \(scheme): frame view \(type(of: frameView)) "
                 + "masksToBounds \(String(describing: frameView.layer?.masksToBounds)) "
                 + "cornerRadius \(String(describing: frameView.layer?.cornerRadius)) "
                 + "mask \(frameView.layer?.mask == nil ? "none" : "set") "
                 + "subviews \(frameView.subviews.map { "\(type(of: $0))" })")
            note("surface \(scheme): shown \(live.popover.isShown) window \(live.window.frame) visible \(live.window.isVisible)")
            let surfaceFrame = surface.frame, frameBounds = frameView.bounds
            #expect(surfaceFrame == frameBounds)
            let surfaceIndex = frameView.subviews.firstIndex(of: surface) ?? .max
            let contentIndex = frameView.subviews.firstIndex { live.scroll.isDescendant(of: $0) } ?? .min
            #expect(surfaceIndex < contentIndex, "the surface is not beneath the content")

            let image = try #require(live.windowImage(), "the window server gave no picture of the popover")
            let raster = try Raster(image: image)
            let scale = CGFloat(image.width) / live.window.frame.width
            if let directory = LivePopoverEnvironment.shotDirectory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // Magenta shows where the window is transparent.
                let shown = raster.shown(on: (255, 0, 255))
                try shown.writePNG(to: directory.appendingPathComponent("popover-\(scheme).png"), scale: scale)
                let corner = Int(34 * scale)
                let crops: [(String, Int, Int, Int, Int)] = [
                    ("arrow", raster.width / 2 - Int(40 * scale), 0, Int(80 * scale), Int(30 * scale)),
                    ("top-left", 0, 0, corner, corner),
                    ("top-right", raster.width - corner, 0, corner, corner),
                    ("bottom-left", 0, raster.height - corner, corner, corner),
                    ("bottom-right", raster.width - corner, raster.height - corner, corner, corner),
                ]
                for (name, x, y, width, height) in crops {
                    try shown.cropped(x: x, y: y, width: width, height: height, zoom: 6).writePNG(
                        to: directory.appendingPathComponent("popover-\(scheme)-\(name).png"), scale: 1)
                }
                note("surface \(scheme): pictures in \(directory.path)")
            }

            // The body is the first row that is opaque nearly from side to side. Above it only
            // the arrow is: a surface that was not clipped would fill those rows.
            let rows = (0..<raster.height).map { raster.opaqueRun(row: $0) }
            let tip = try #require(rows.firstIndex { $0 != nil }, "nothing opaque in the picture")
            let body = try #require(rows.firstIndex { ($0?.count ?? 0) > raster.width * 3 / 4 })
            let arrowHeight = CGFloat(body - tip) / scale
            note("surface \(scheme): arrow \(arrowHeight) pt tall, tip run \(String(describing: rows[tip])), "
                 + "body from row \(body) of \(raster.height), run \(String(describing: rows[body]))")
            #expect(arrowHeight >= 6, "no arrow above the body")
            for row in tip..<max(tip, body - Int(2 * scale)) {
                #expect((rows[row]?.count ?? 0) < raster.width / 3, "row \(row) is opaque beyond the arrow")
            }
            // The four corners of the window lie outside the rounded outline.
            let inset = Int(2 * scale)
            for (x, y) in [(inset, inset), (raster.width - 1 - inset, inset),
                           (inset, raster.height - 1 - inset), (raster.width - 1 - inset, raster.height - 1 - inset)] {
                #expect(raster.pixel(x: x, y: y).a < 16, "the corner at \(x), \(y) is filled")
            }
            // The arrow is the panel's colour: the pixel inside it and the one below it, in the
            // panel's padding, are the Ember background.
            let background = (isDark ? EmberPalette.dark : EmberPalette.light).background
            let tipRun = try #require(rows[tip])
            let column = (tipRun.lowerBound + tipRun.upperBound) / 2
            for (name, row) in [("arrow", body - Int(3 * scale)), ("panel", body + Int(8 * scale))] {
                let pixel = raster.pixel(x: column, y: row)
                note("surface \(scheme): \(name) pixel \(pixel), Ember background \(background)")
                #expect(pixel.a == 255)
                #expect(abs(Double(pixel.r) - background.r) <= 6 && abs(Double(pixel.g) - background.g) <= 6
                        && abs(Double(pixel.b) - background.b) <= 6, "the \(name) is not the Ember background")
            }
        }
    }

    // MARK: The mode switch

    /// Where the selected segment of the mode control is drawn: the rows and columns, in
    /// pixels, holding the raised fill. Nil when there is none.
    private func selectedSegment(
        in raster: Raster, palette: EmberPalette
    ) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        let trough = palette.wash.mixed(palette.troughAlpha, over: palette.background)
        let raised = palette.raisedRGB.mixed(palette.raisedAlpha, over: trough)
        let wanted = [Int(raised.r.rounded()), Int(raised.g.rounded()), Int(raised.b.rounded())]
        var rows: [Int] = [], lefts: [Int] = [], rights: [Int] = []
        for y in 0..<raster.height {
            // The longest unbroken run of the fill in this row: the segment itself, without
            // the edges of a label that pass through its colour.
            var best = 0, bestStart = 0, run = 0
            for x in 0..<raster.width {
                let index = (y * raster.width + x) * 4
                if raster.pixels[index + 3] == 255,
                   (0..<3).allSatisfy({ abs(Int(raster.pixels[index + $0]) - wanted[$0]) <= 3 }) {
                    run += 1
                    if run > best {
                        best = run
                        bestStart = x - run + 1
                    }
                } else {
                    run = 0
                }
            }
            if best >= 60 {
                rows.append(y)
                lefts.append(bestStart)
                rights.append(bestStart + best - 1)
            }
        }
        guard let top = rows.first, let bottom = rows.last, let left = lefts.min(), let right = rights.max()
        else { return nil }
        return (top...bottom, left...right)
    }

    /// The rows and columns holding the Warm preset's swatch: something of the Manual pane,
    /// near its leading edge, that no other part of the popover is the colour of while the
    /// colour temp is at 100 %.
    private func warmSwatch(in raster: Raster) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        let late = EmberTint.rgb(intensity: Preset.defaults[1].intensity, scheme: .dark)
        let wanted = [Int(late.r.rounded()), Int(late.g.rounded()), Int(late.b.rounded())]
        var rows: [Int] = [], lefts: [Int] = [], rights: [Int] = []
        for y in 0..<raster.height {
            var first: Int?, last = 0, count = 0
            for x in 0..<raster.width {
                let index = (y * raster.width + x) * 4
                if (0..<3).allSatisfy({ abs(Int(raster.pixels[index + $0]) - wanted[$0]) <= 3 }) {
                    if first == nil { first = x }
                    last = x
                    count += 1
                }
            }
            // A row through the whole swatch, not one of its rounded ends.
            if let first, count >= 20 {
                rows.append(y)
                lefts.append(first)
                rights.append(last)
            }
        }
        guard let top = rows.first, let bottom = rows.last, let left = lefts.min(), let right = rights.max()
        else { return nil }
        return (top...bottom, left...right)
    }

    /// Pressing the other mode slides the selected segment straight across, and the pane
    /// under it sideways with it: in every frame the window server shows, the segment is on
    /// its own rows and the Manual pane's swatches on theirs, while the popover goes through
    /// the heights between the two panes'. Segment, pane and height arrive together. The
    /// popover animates as the app's does.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func theModeSwitchMovesItsSegmentStraightAcross() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            let dark = try #require(NSAppearance(named: .darkAqua))
            let live = try LivePopover(
                fixture.view().environment(\.colorScheme, .dark).preferredColorScheme(.dark),
                appearance: dark, animated: true)
            defer {
                live.close()
                fixture.retire()
            }
            let palette = EmberPalette.dark
            live.pump(0.4)
            // The control in the document, to press its other half.
            let drawn = try #require(selectedSegment(in: try live.raster(), palette: palette),
                                     "no selected segment drawn")
            // Its text breaks the fill's rows, so take the width from the trough: two halves
            // of the panel's width inside its padding and the control's own.
            let segmentWidth = (EmberMetrics.width - 2 * EmberMetrics.padding - 4) / 2
            let midY = CGFloat(drawn.rows.lowerBound + drawn.rows.upperBound) / 4
            let autoX = EmberMetrics.padding + 2 + segmentWidth / 2

            @MainActor func capture() throws -> Raster {
                let image = try #require(live.windowImage())
                return try Raster(image: image)
            }
            @MainActor func press(_ type: NSEvent.EventType, at point: CGPoint) throws {
                NSApp.postEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: live.document.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: live.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)),
                    atStart: false)
            }
            let resting = try #require(selectedSegment(in: try capture(), palette: palette),
                                       "no selected segment shown")

            for (round, toAuto) in [false, true].enumerated() {
                let before = try #require(selectedSegment(in: try capture(), palette: palette))
                let x = toAuto ? autoX : autoX + segmentWidth
                let point = CGPoint(x: x, y: live.document.isFlipped ? midY : live.document.bounds.height - midY)
                try press(.leftMouseDown, at: point)
                try press(.leftMouseUp, at: point)
                // Every frame the window server has, for longer than any of the animations.
                var frames: [Raster] = []
                var tops: Set<CGFloat> = [live.window.frame.maxY]
                let end = Date().addingTimeInterval(0.9)
                while Date() < end {
                    live.pump(0.004)
                    frames.append(try capture())
                    tops.insert(live.window.frame.maxY)
                }
                #expect(fixture.manager.adaptiveEnabled == toAuto)
                // The popover hangs from the menu bar: as its height goes by, its top stays put.
                #expect(tops.count == 1, "round \(round): the top edge moved, through \(tops.sorted())")
                var lines: [String] = []
                var lastLeft = before.columns.lowerBound
                var moved = 0
                for (index, frame) in frames.enumerated() {
                    guard let segment = selectedSegment(in: frame, palette: palette) else {
                        Issue.record("round \(round) frame \(index): no selected segment")
                        continue
                    }
                    lines.append("\(index): rows \(segment.rows) columns \(segment.columns) height \(frame.height)")
                    #expect(segment.rows == resting.rows,
                            "round \(round) frame \(index): rows \(segment.rows), not \(resting.rows)")
                    // Only ever toward the pressed half.
                    let left = segment.columns.lowerBound
                    if toAuto { #expect(left <= lastLeft + 1) } else { #expect(left >= lastLeft - 1) }
                    if left != lastLeft { moved += 1 }
                    lastLeft = left
                }
                note("mode switch round \(round) to \(toAuto ? "auto" : "manual"): \(frames.count) frames, "
                    + "\(moved) moves\n" + lines.joined(separator: "\n"))
                let settled = try capture()
                let after = try #require(selectedSegment(in: settled, palette: palette))
                #expect(after.rows == resting.rows)
                #expect(abs(after.columns.lowerBound - before.columns.lowerBound) > Int(segmentWidth))

                // The height: through values of its own between the two, never back.
                let heights = frames.map(\.height)
                let from = try #require(heights.first), to = settled.height
                #expect(abs(to - from) > 40, "the two panes are \(abs(to - from)) px apart")
                for (earlier, later) in zip(heights, heights.dropFirst()) {
                    #expect(to > from ? later >= earlier : later <= earlier, "the height went back: \(heights)")
                }
                // Whole points, so 2 px steps: any height but the two ends is on the way.
                let between = Set(heights.filter { min(from, to) < $0 && $0 < max(from, to) })
                // Two at the least, however few frames a busy machine captures; a jump has none.
                #expect(between.count >= 2, "the height jumped: \(heights)")

                // The Manual pane: its swatch only ever moves sideways.
                let manualFrame = toAuto ? frames.first : settled
                let swatchRows = try #require(manualFrame.flatMap { warmSwatch(in: $0) }, "no Warm swatch").rows
                var swatchLefts: [Int] = []
                for (index, frame) in frames.enumerated() {
                    // Also while the popover's edge cuts it: its leading edge is the last to
                    // go and the first to come. Cut down to its rounded end it shows on fewer
                    // rows, evenly above and below: its middle row is what must not move.
                    guard let swatch = warmSwatch(in: frame) else { continue }
                    let middle = swatch.rows.lowerBound + swatch.rows.upperBound
                    #expect(abs(middle - (swatchRows.lowerBound + swatchRows.upperBound)) <= 4
                        && swatch.rows.lowerBound >= swatchRows.lowerBound - 2
                        && swatch.rows.upperBound <= swatchRows.upperBound + 2,
                            "round \(round) frame \(index): swatch rows \(swatch.rows), not \(swatchRows)")
                    swatchLefts.append(swatch.columns.lowerBound)
                }
                // Coming in, it is seen at several places on its way. Going out it is past
                // the edge within a frame or two of these captures, so there it only has to
                // have been seen.
                #expect(Set(swatchLefts).count >= (toAuto ? 1 : 3), "the pane did not slide: \(swatchLefts)")
                for (earlier, later) in zip(swatchLefts, swatchLefts.dropFirst()) {
                    // Manual lives on the right: it leaves to the right and comes from there.
                    #expect(toAuto ? later >= earlier - 1 : later <= earlier + 1, "\(swatchLefts)")
                }

                // Together: the segment and the height are home within a few frames of
                // each other.
                func arrival(_ values: [Int], at target: Int) -> Int {
                    values.firstIndex { abs($0 - target) <= 4 } ?? values.count
                }
                let segmentLefts = frames.map { selectedSegment(in: $0, palette: palette)?.columns.lowerBound ?? -1 }
                let segmentHome = arrival(segmentLefts, at: after.columns.lowerBound)
                let heightHome = arrival(heights, at: to)
                #expect(abs(segmentHome - heightHome) <= 4, "segment home at \(segmentHome), height at \(heightHome)")

                // One pane is left, with one of each slider, and the popover is its size.
                let pills = try live.sliders().map(\.pill)
                #expect(pills.count == 3, "round \(round): slider pills at \(pills)")
                #expect(live.popover.contentSize.height == live.document.frame.height)
                if let directory = LivePopoverEnvironment.shotDirectory {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for (index, frame) in frames.enumerated() {
                        try frame.shown(on: (90, 90, 90)).writePNG(to: directory.appendingPathComponent(
                            String(format: "mode-%d-%03d.png", round, index)))
                    }
                }
            }
        }
    }

    /// Settings slides in from the right as the controls leave by the left, and Back slides
    /// them the other way: the controls' mode segment stays on its own rows in every frame
    /// and only ever moves toward the side it is going to, and the popover's height never
    /// turns back on its way. Each ends with one page, the size of the popover.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func settingsSlidesInFromTheRightAndBackSlidesItAway() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            let dark = try #require(NSAppearance(named: .darkAqua))
            let live = try LivePopover(
                fixture.view().environment(\.colorScheme, .dark).preferredColorScheme(.dark),
                appearance: dark, animated: true)
            defer {
                live.close()
                fixture.retire()
            }
            let palette = EmberPalette.dark
            live.pump(0.4)
            @MainActor func capture() throws -> Raster {
                let image = try #require(live.windowImage())
                return try Raster(image: image)
            }
            @MainActor func press(at point: CGPoint) throws {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.postEvent(try #require(NSEvent.mouseEvent(
                        with: type, location: live.document.convert(point, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: live.window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)),
                        atStart: false)
                }
            }
            // A page out of sight is kept, its views with it: what counts is on screen.
            @MainActor func onScreen(_ view: NSView) -> Bool {
                guard let content = live.window.contentView else { return false }
                return view.convert(view.bounds, to: nil).intersects(content.frame.insetBy(dx: 1, dy: 1))
            }
            @MainActor func isOnSettings() -> Bool {
                live.views().contains { $0 is NSDatePicker && onScreen($0) }
            }
            @MainActor func sliderCount() -> Int {
                live.views().filter { $0.acceptsFirstResponder && $0.bounds.size == LiveSlider.size && onScreen($0) }.count
            }
            let resting = try #require(selectedSegment(in: try capture(), palette: palette), "no mode segment shown")
            let controlsHeight = live.document.frame.height
            #expect(!isOnSettings() && sliderCount() == 2)

            for toSettings in [true, false] {
                // The Settings row is the last card of the controls; Back is the first thing
                // on the Settings page.
                let height = live.document.bounds.height
                let top = toSettings
                    ? CGPoint(x: EmberMetrics.width / 2, y: height - EmberMetrics.padding - 22)
                    : CGPoint(x: EmberMetrics.padding + 18, y: EmberMetrics.padding + 13)
                try press(at: CGPoint(x: top.x, y: live.document.isFlipped ? top.y : height - top.y))
                var frames: [Raster] = []
                var tops: Set<CGFloat> = [live.window.frame.maxY]
                let end = Date().addingTimeInterval(0.9)
                while Date() < end {
                    live.pump(0.004)
                    frames.append(try capture())
                    tops.insert(live.window.frame.maxY)
                }
                let what = toSettings ? "to Settings" : "back"
                // The popover hangs from the menu bar: as its height goes by, its top stays put.
                #expect(tops.count == 1, "\(what): the top edge moved, through \(tops.sorted())")
                #expect(isOnSettings() == toSettings, "\(what): the page did not change")
                // One page is left, and the popover is its size.
                #expect(sliderCount() == (toSettings ? 0 : 2), "\(what)")
                #expect(abs(live.popover.contentSize.height - live.document.frame.height) < 1, "\(what)")
                if !toSettings { #expect(abs(live.document.frame.height - controlsHeight) < 1) }

                // The controls' segment: on its rows, and only ever going its way.
                var lefts: [Int] = []
                for (index, frame) in frames.enumerated() {
                    guard let segment = selectedSegment(in: frame, palette: palette) else { continue }
                    #expect(segment.rows == resting.rows, "\(what) frame \(index): rows \(segment.rows)")
                    lefts.append(segment.columns.lowerBound)
                }
                for (earlier, later) in zip(lefts, lefts.dropFirst()) {
                    #expect(toSettings ? later <= earlier + 1 : later >= earlier - 1, "\(what): \(lefts)")
                }
                if toSettings {
                    #expect(selectedSegment(in: try capture(), palette: palette) == nil, "the controls did not leave")
                } else {
                    // Coming back it is seen at several places on its way, and ends at home.
                    #expect(Set(lefts).count >= 3, "\(what): the page did not slide: \(lefts)")
                    #expect(lefts.last == resting.columns.lowerBound)
                }
                // The height goes one way.
                let heights = frames.map(\.height)
                let rising = (heights.last ?? 0) >= (heights.first ?? 0)
                for (earlier, later) in zip(heights, heights.dropFirst()) {
                    #expect(rising ? later >= earlier : later <= earlier, "\(what): the height went back: \(heights)")
                }
                note("page slide \(what): \(frames.count) frames, segment lefts \(lefts), heights \(Set(heights).sorted())")
                if let directory = LivePopoverEnvironment.shotDirectory {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for (index, frame) in frames.prefix(8).enumerated() {
                        try frame.shown(on: (90, 90, 90)).writePNG(to: directory.appendingPathComponent(
                            String(format: "page-%@-%03d.png", toSettings ? "in" : "back", index)))
                    }
                }
            }
        }
    }

    /// A mode change that something interrupts, or that nobody pressed for, still ends with
    /// one pane at its own height, and lets go of that height afterwards.
    /// The popover is the menu of a menu bar item, so it stands where a menu would: above
    /// every app's windows, floating panels and always-on-top windows included, and over a
    /// full-screen app.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func thePopoverStandsAboveEveryOtherWindowLikeAMenu() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            let live = try LivePopover(fixture.view(), animated: true)
            defer {
                live.close()
                fixture.retire()
            }
            live.pump(0.4)
            #expect(live.window.level == .popUpMenu, "level \(live.window.level.rawValue)")
            #expect(live.window.collectionBehavior.contains(.fullScreenAuxiliary))
            // A floating window of another kind, such as an always-on-top panel, stays under it.
            let panel = NSPanel(contentRect: live.window.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.orderFrontRegardless()
            defer { panel.close() }
            live.pump(0.1)
            let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? Int }
            let popoverIndex = try #require(order.firstIndex(of: live.window.windowNumber))
            let panelIndex = try #require(order.firstIndex(of: panel.windowNumber))
            #expect(popoverIndex < panelIndex, "the popover should be in front of a status-bar-level panel")
        }
    }

    /// The popover follows a sliding height once a frame, on the display's clock, and lets the
    /// display go when the height stops. (Closing in the middle of a slide lets it go as well,
    /// on the popover's close notification, but a popover here never finishes closing.)
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func thePopoverFollowsASlideOnTheDisplayAndLetsGoAfter() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            let live = try LivePopover(fixture.view(), animated: true)
            defer {
                live.close()
                fixture.retire()
            }
            let sizer = try #require((live.scroll as? PopoverScrollView)?.sizer)
            live.pump(0.4)
            #expect(!sizer.isWaitingForDisplay, "waiting on the display at rest")
            fixture.manager.adaptiveEnabled.toggle()
            live.pump(0.08)
            #expect(sizer.isWaitingForDisplay, "not following the slide")
            live.pump(0.8)
            #expect(!sizer.isWaitingForDisplay, "still waiting on the display after the slide")
            #expect(abs(live.popover.contentSize.height - live.document.frame.height) < 1)
        }
    }

    /// A slide is pictures over the popover. Going to a Settings page taller than the controls,
    /// they cover the whole popover as it grows: left at the controls' height, the live page
    /// showed below them, still, cut off by their foot.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aSlideToATallerPageCoversThePopoverAsItGrows() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture(defaults: ["redlight.adaptiveEnabled": true], manualLocation: true)
            defer { fixture.retire() }
            // Every General row: a Settings page well taller than the controls.
            let view = MenuBarView(manager: fixture.manager, defaults: fixture.defaults, launchAtLogin: LaunchAtLogin(),
                                   handler: fixture.handler, openShortcuts: {},
                                   initialState: MenuBarInitialState(updateAvailable: false, updatesAutomatically: true,
                                                                     keepsNightShiftOff: true))
            let live = try LivePopover(view, animated: true)
            defer { live.close() }
            live.pump(0.4)
            let controls = live.popover.contentSize.height
            let height = live.document.bounds.height
            let row = CGPoint(x: EmberMetrics.width / 2, y: height - EmberMetrics.padding - 22)
            let point = CGPoint(x: row.x, y: live.document.isFlipped ? row.y : height - row.y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(try #require(NSEvent.mouseEvent(
                    with: type, location: live.document.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: live.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)),
                    atStart: false)
            }
            // Partway: the popover has grown, and the pictures with it.
            var checked = 0
            let end = Date().addingTimeInterval(0.5)
            while Date() < end {
                live.pump(0.01)
                guard let overlay = live.scroll.subviews.first(where: { $0 is PopoverSlideOverlay }) else { continue }
                #expect(overlay.frame == live.scroll.bounds,
                        "the pictures are \(overlay.frame.height) tall in a popover \(live.scroll.bounds.height) tall")
                checked += 1
            }
            #expect(live.popover.contentSize.height > controls + 60,
                    "Settings is \(live.popover.contentSize.height) tall against the controls' \(controls)")
            #expect(checked >= 3, "only \(checked) frames of the slide were seen")
        }
    }

    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aModeChangeSettlesWhateverInterruptsIt() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            let live = try LivePopover(fixture.view(), animated: true)
            defer {
                live.close()
                fixture.retire()
            }
            let manager = fixture.manager
            live.pump(0.4)
            @MainActor func height() -> CGFloat { live.document.frame.height }
            @MainActor func expectSettled(_ expected: CGFloat, _ what: String) throws {
                // Within a point: a pane with running text has a height that is not whole.
                #expect(abs(height() - expected) < 1, "\(what): \(height()), not \(expected)")
                #expect(abs(live.popover.contentSize.height - height()) < 1, "\(what): the popover is another size")
                let pills = try live.sliders().map(\.pill)
                #expect(pills.count == 3, "\(what): slider pills at \(pills)")
                // And the strip is at that pane, not parked between two or on the other.
                for pill in pills { #expect(pill.minX == EmberMetrics.padding, "\(what): a slider at \(pill)") }
            }
            let autoHeight = height()

            // From outside, as the CLI does: no event, nothing pressed.
            manager.adaptiveEnabled = false
            live.pump(0.8)
            let manualHeight = height()
            #expect(manualHeight < autoHeight - 20)
            try expectSettled(manualHeight, "a flip from outside")

            // Back, and away again before the slide is a third done; then back for good.
            manager.adaptiveEnabled = true
            live.pump(0.08)
            manager.adaptiveEnabled = false
            live.pump(0.8)
            try expectSettled(manualHeight, "a flip turned round midway")
            manager.adaptiveEnabled = true
            live.pump(0.05)
            manager.adaptiveEnabled = false
            live.pump(0.05)
            manager.adaptiveEnabled = true
            live.pump(0.8)
            try expectSettled(autoHeight, "three flips in a row")
            #expect(try live.flagStops().count == 4)

            // The height is let go: when the pane changes by itself, the popover follows at
            // once. Auto loses its location, and the arc gives way to the ask for one.
            fixture.location.coordinate = nil
            fixture.location.authorization = .denied
            manager.applyAdaptive()
            live.pump(0.3)
            let askHeight = height()
            #expect(abs(askHeight - autoHeight) > 4)
            #expect(abs(live.popover.contentSize.height - askHeight) < 1)
            // And with no location the switch still lands on each pane's own height.
            manager.adaptiveEnabled = false
            live.pump(0.8)
            try expectSettled(manualHeight, "to Manual from the ask")
            manager.adaptiveEnabled = true
            live.pump(0.8)
            try expectSettled(askHeight, "back to the ask")
            fixture.location.authorization = .authorized
            fixture.location.coordinate = (41.88, -87.63)
            manager.applyAdaptive()
            live.pump(0.3)
            try expectSettled(autoHeight, "the location back")

            // Tab during a slide never stops in the pane that is leaving. To Manual, that is
            // Auto's, going out by the left: no stop is left of the popover. A stop in the
            // pane coming in from the right is one the user is about to see.
            manager.adaptiveEnabled = false
            live.pump(0.03)
            var during: [CGRect] = []
            for _ in 0..<14 {
                try live.key(.tab, settle: 0.012)
                if let frame = live.focusFrame { during.append(frame) }
            }
            #expect(during.count >= 10)
            for frame in during {
                #expect(frame.minX >= 0, "Tab stopped at \(frame)")
            }
            live.pump(0.8)
            try expectSettled(manualHeight, "Tab pressed all through the slide")
            manager.adaptiveEnabled = true
            live.pump(0.8)
            try expectSettled(autoHeight, "back to Auto")

            // One Tab round afterwards: each stop once, the sliders among them.
            let stops = try tabRound(live)
            #expect(Set(stops.map { "\($0)" }).count == stops.count)
            let pills = try live.sliders().map(\.pill)
            for pill in pills { #expect(stops.filter { $0 == pill }.count == 1) }
        }
    }

    // MARK: Slider press and drag

    private static let whiteRange = 0.25...1.0

    private func openAuto(_ extra: [String: Any] = ["redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8])
        throws -> (LivePopoverFixture, LivePopover, [LiveSlider]) {
        let fixture = LivePopoverFixture.auto(extra)
        let live = try LivePopover(fixture.view())
        let sliders = try live.sliders()
        try #require(sliders.count == 3, "found \(sliders.count) sliders")
        return (fixture, live, sliders)
    }

    @Test(.enabled(if: LivePopoverEnvironment.enabled), arguments: [false, true])
    func saturationPressPreviewsUntilRelease(auto: Bool) async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture(defaults: ["redlight.adaptiveEnabled": auto])
            let manager = fixture.manager
            manager.setEnabled(true, for: 1)
            manager.intensity = 0.7
            let live = try LivePopover(fixture.view())
            defer { live.close(); fixture.retire() }

            let slider = try #require(try live.sliders().last)
            let track = slider.pill
            let handle = slider.point(x: slider.x(for: 0, range: 0...1))
            try live.drag(from: handle, dx: 0) {
                #expect(fixture.gamma.saturationCalls.last?.saturation == 0)
                #expect(!manager.saturationEnabled)
            }
            #expect(fixture.gamma.saturationCalls.last?.saturation == 1)
            try live.drag(from: handle, dx: track.width / 2) {
                #expect((0.4...0.6).contains(manager.saturation))
                #expect(fixture.gamma.saturationCalls.last?.saturation == Float(manager.saturation))
            }
            #expect(fixture.gamma.saturationCalls.last?.saturation == 1)
            AccessibilityTree.enable()
            _ = live.document.accessibilityChildren()
            live.pump(0.1)
            let toggle = try #require(AccessibilityTree(live.document).first("Saturation filter"))
            #expect(AccessibilityTree.press(toggle))
            live.pump(0.1)
            #expect(manager.saturationEnabled)
            try live.drag(from: slider.point(x: track.width / 2), dx: 20)
            #expect(fixture.gamma.saturationCalls.last?.saturation == Float(manager.saturation))
        }
    }

    /// Auto in the afternoon with a 20–80 % colour temp band: the value rests on its upper
    /// limit. A press anywhere on the pill, or just above or below it, takes the value there,
    /// and the limits stay.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aPressAnywhereOnThePillMovesTheValueThere() async throws {
        try inRunLoopTurn {
            let (fixture, live, sliders) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            try #require(abs(manager.intensity - 0.8) < 1e-9, "the value is not on its upper limit: \(manager.intensity)")
            let color = sliders[0]

            try live.drag(from: color.point(x: color.x(for: 0.4, range: Self.colorRange), dy: 9), dx: 0)
            note("slider auto, pressed at 40 %: \(fixture.settings[3])")
            #expect(abs(manager.intensity - 0.4) < 0.005, "the press did not take the value there")
            #expect(manager.adaptiveMin == 0.2 && manager.adaptiveMax == 0.8, "the press moved a limit")

            // Below the pill's edge, in the few points of slop under it.
            try live.drag(from: color.point(x: color.x(for: 0.6, range: Self.colorRange),
                                            dy: EmberMetrics.sliderHeight / 2 + 2.5), dx: 0)
            note("slider auto, pressed under the pill at 60 %: \(fixture.settings[3])")
            #expect(abs(manager.intensity - 0.6) < 0.005, "a press just under the pill did not take the value")

            // Right above a flag the pill still takes the value, and the flag stays.
            try live.drag(from: color.point(x: color.x(for: 0.2, range: Self.colorRange),
                                            dy: EmberMetrics.sliderHeight / 2 + 2), dx: 0)
            note("slider auto, pressed right above the minimum flag: \(fixture.settings[3])")
            #expect(abs(manager.intensity - 0.2) < 0.005, "a press right above the flag did not take the value")
            #expect(manager.adaptiveMin == 0.2 && manager.adaptiveMax == 0.8, "a press on the pill moved a flag")

            // Above the pill's edge, in the slop under the header, away from Reset.
            try live.drag(from: color.point(x: color.x(for: 0.3, range: Self.colorRange),
                                            dy: -(EmberMetrics.sliderHeight / 2 + 2.5)), dx: 0)
            note("slider auto, pressed over the pill at 30 %: \(fixture.settings[3])")
            #expect(abs(manager.intensity - 0.3) < 0.005, "a press just over the pill did not take the value")

            // Under Reset the header lies over the slop: a press there never moves the value
            // (Reset itself answers only on its drawn button), and the button still works. It is
            // the 18 pt circle before the value: the value's "30%", 8 pt, then its middle.
            let underReset = color.pill.width - 42
            try live.drag(from: color.point(x: underReset, dy: -(EmberMetrics.sliderHeight / 2 + 2.5)), dx: 0)
            note("slider auto, pressed over the pill under Reset: \(fixture.settings[3])")
            #expect(abs(manager.intensity - 0.3) < 0.005, "the slop under Reset took the press")
            try live.drag(from: color.point(x: underReset, dy: -27), dx: 0)
            note("slider auto, pressed on Reset: \(fixture.settings[3])")
            #expect(manager.adaptiveMin == 0 && manager.adaptiveMax == 1, "Reset did not take the press on its chip")

            // The drag follows the pointer.
            try live.drag(from: color.point(x: color.x(for: 0.6, range: Self.colorRange)), dx: -40)
            #expect(abs(manager.intensity - (0.6 - 40.0 / LiveSlider.usableWidth)) < 0.01, "the value did not follow the drag")
        }
    }

    /// A drag past either end reaches exactly 100 % and 0 %, in Auto too: the limit in the
    /// way moves with the value, and the next tick of the curve leaves the value there.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aDragReachesBothEndsAndPushesTheLimitInAuto() async throws {
        try inRunLoopTurn {
            let (fixture, live, sliders) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            let color = sliders[0], white = sliders[1]
            // From the grabber to a few points past the end of the pill, still in the popover.
            let startRight = color.x(for: manager.intensity, range: Self.colorRange)
            try live.drag(from: color.point(x: startRight), dx: color.pill.width + 8 - startRight, steps: 8)
            note("slider auto, dragged past the right end: \(fixture.settings[3])")
            #expect(manager.intensity == 1.0, "the drag did not reach 100 %: \(manager.intensity)")
            #expect(manager.adaptiveMax == 1.0, "the upper limit did not move with the value")
            #expect(manager.adaptiveMin == 0.2)
            manager.applyAdaptive()
            #expect(manager.intensity == 1.0, "the next tick moved the value to \(manager.intensity)")

            let startLeft = color.x(for: manager.intensity, range: Self.colorRange)
            try live.drag(from: color.point(x: startLeft), dx: -8 - startLeft, steps: 8)
            note("slider auto, dragged past the left end: \(fixture.settings[3])")
            #expect(manager.intensity == 0.0, "the drag did not reach 0 %: \(manager.intensity)")
            #expect(manager.adaptiveMin == 0.0 && manager.adaptiveMax == 1.0)
            manager.applyAdaptive()
            #expect(manager.intensity == 0.0, "the next tick moved the value to \(manager.intensity)")

            let whiteStart = white.x(for: manager.whitepoint, range: Self.whiteRange)
            try live.drag(from: white.point(x: whiteStart), dx: -8 - whiteStart, steps: 8)
            note("slider auto, white point dragged past the left end: \(fixture.settings[4])")
            #expect(manager.whitepoint == 0.25 && manager.adaptiveWpMin == 0.25)
            try live.drag(from: white.point(x: white.x(for: 0.25, range: Self.whiteRange)),
                          dx: white.pill.width + 8 - white.x(for: 0.25, range: Self.whiteRange), steps: 8)
            #expect(manager.whitepoint == 1.0, "the white point did not reach 100 %: \(manager.whitepoint)")
        }
    }

    /// A pinned band is one fixed value: a drag moves it, and the band stays pinned on it.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aDragMovesAPinnedBandWithTheValue() async throws {
        try inRunLoopTurn {
            let (fixture, live, sliders) = try openAuto(["redlight.adaptiveMin": 0.6, "redlight.adaptiveMax": 0.6])
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            try #require(abs(manager.intensity - 0.6) < 1e-9, "the value is not on the pin: \(manager.intensity)")
            let color = sliders[0]
            try live.drag(from: color.point(x: color.x(for: 0.6, range: Self.colorRange)), dx: -40)
            note("slider pinned, dragged left 40: \(fixture.settings[3])")
            #expect(abs(manager.intensity - (0.6 - 40.0 / LiveSlider.usableWidth)) < 0.01, "the value did not follow the drag")
            #expect(manager.adaptiveMin == manager.intensity && manager.adaptiveMax == manager.intensity,
                    "the band is no longer pinned on the value")
        }
    }

    /// Manual at a preset: a click on the grabber that does not move changes nothing, so the
    /// preset stays chosen. The same press followed by a drag does, and a press elsewhere
    /// takes the value there.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func clickOnTheValueKeepsThePreset() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture()
            defer { fixture.retire() }
            let manager = fixture.manager
            manager.applyPreset(3)
            let preset = manager.presets[3].intensity
            let live = try LivePopover(fixture.view())
            defer { live.close() }
            let slider = try #require(try live.sliders().first)
            let valueX = slider.x(for: preset, range: Self.colorRange)
            try #require(manager.activePresetIndex == 3 && manager.intensity == preset)

            try live.drag(from: slider.point(x: valueX), dx: 0)
            note("slider manual, grabber clicked: value \(manager.intensity), "
                 + "preset \(String(describing: manager.activePresetIndex))")
            #expect(manager.intensity == preset, "a click on the grabber changed the value")
            #expect(manager.activePresetIndex == 3, "a click on the grabber deselected the preset")

            // A point beside the centre of the grabber, still on it: the same.
            try live.drag(from: slider.point(x: valueX + 1.5, dy: 5), dx: 0)
            #expect(manager.intensity == preset && manager.activePresetIndex == 3)

            try live.drag(from: slider.point(x: valueX), dx: -30)
            note("slider manual, grabber dragged left 30: value \(manager.intensity), "
                 + "preset \(String(describing: manager.activePresetIndex))")
            #expect(abs(manager.intensity - (preset - 30.0 / LiveSlider.usableWidth)) < 0.01, "the value did not follow the drag")
            #expect(manager.activePresetIndex == nil)

            try live.drag(from: slider.point(x: slider.x(for: 0.9, range: Self.colorRange)), dx: 0)
            #expect(abs(manager.intensity - 0.9) < 0.005, "a press on the track did not take the value there")
        }
    }

    // MARK: Auto's limit flags

    /// The centre of a flag's keyboard stop, which is the centre of its chip's row.
    private func centre(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// The minimum's flag dragged onto the maximum's: they are one flag, the band is pinned and
    /// the value is on the pin. Short of it by less than the gap the flag is held at the gap.
    /// The merged flag dragged left opens the band again, the minimum leaving.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aFlagDraggedOntoTheOtherMergesWithItAndDraggedOffOpensTheBand() async throws {
        try inRunLoopTurn {
            let (fixture, live, sliders) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            let color = sliders[0]
            @MainActor func place(_ value: Double) -> CGFloat { color.x(for: value, range: Self.colorRange) }
            var flags = try live.flagStops()
            try #require(flags.count == 4, "found \(flags.count) flag stops")

            // To 77 %: closer to the maximum than the gap, not yet halfway across it.
            try live.drag(from: centre(flags[0]), dx: place(0.77) - place(0.2), steps: 10)
            note("merge: minimum dragged to 77 %: \(fixture.settings[3])")
            #expect(abs(manager.adaptiveMin - 0.75) < 1e-9 && manager.adaptiveMax == 0.8, "not held at the gap")

            // On to the maximum's own place, and a little past it.
            flags = try live.flagStops()
            // In one move, so that the merge begins at a known moment: with a directory for
            // pictures, the flags are drawn as they close, a few times on the way.
            try live.drag(from: centre(flags[0]), dx: place(0.81) - place(0.75), steps: 1) {
                guard let directory = LivePopoverEnvironment.shotDirectory else { return }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (index, wait) in [0, 0.05, 0.07, 0.1, 0.3].enumerated() {
                    live.pump(wait)
                    try live.raster().writePNG(to: directory.appendingPathComponent("flags-merging-\(index).png"))
                }
            }
            note("merge: minimum dragged onto the maximum: \(fixture.settings[3])")
            #expect(manager.adaptiveMin == 0.8 && manager.adaptiveMax == 0.8, "the flags did not merge")
            #expect(manager.isIntensityPinned && manager.intensity == 0.8, "the value is not on the pin")
            if let directory = LivePopoverEnvironment.shotDirectory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try live.raster().writePNG(to: directory.appendingPathComponent("flags-merged.png"))
            }

            // A click on the merged flag changes nothing.
            flags = try live.flagStops()
            try live.drag(from: centre(flags[0]), dx: 0)
            #expect(manager.adaptiveMin == 0.8 && manager.adaptiveMax == 0.8, "a click opened the band")

            // Dragged left by 40 pt: the minimum leaves, the maximum stays.
            try live.drag(from: centre(flags[0]), dx: -40, steps: 8)
            note("merge: merged flag dragged left 40: \(fixture.settings[3])")
            #expect(abs(manager.adaptiveMin - (0.8 - 40.0 / LiveSlider.usableWidth)) < 0.01, "the minimum did not leave")
            #expect(manager.adaptiveMax == 0.8, "the maximum moved")
            #expect(!manager.isIntensityPinned)
        }
    }

    /// A flag is taken a little under its chip too, in the gap before the next block, so its
    /// hit area is as tall as any control's. Past that the gap takes nothing.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aFlagIsTakenJustUnderItsChipAndNotBelowThat() async throws {
        try inRunLoopTurn {
            let (fixture, live, _) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            var flags = try live.flagStops()
            try #require(flags.count == 4, "found \(flags.count) flag stops")
            try live.drag(from: CGPoint(x: flags[0].midX, y: flags[0].maxY + EmberFlagFace.hitSlop - 0.5), dx: 40)
            note("flags: minimum dragged from under its chip: \(fixture.settings[3])")
            #expect(abs(manager.adaptiveMin - (0.2 + 40.0 / LiveSlider.usableWidth)) < 0.01,
                    "a press just under the chip did not take the flag")
            let moved = manager.adaptiveMin
            flags = try live.flagStops()
            try live.drag(from: CGPoint(x: flags[0].midX, y: flags[0].maxY + EmberFlagFace.hitSlop + 1.5), dx: 40)
            #expect(manager.adaptiveMin == moved && manager.adaptiveMax == 0.8, "the gap under the flags took a press")
        }
    }

    /// A press and drag on a flag moves that limit alone and shows it on the displays while
    /// the button is down; the release goes back to the real value.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aFlagDragMovesOnlyItsLimitAndPreviewsIt() async throws {
        try inRunLoopTurn {
            let (fixture, live, _) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            let flags = try live.flagStops()
            note("flags: stops \(flags)")
            try #require(flags.count == 4, "found \(flags.count) flag stops")
            try live.drag(from: centre(flags[0]), dx: 40) {
                let shown = fixture.gamma.applyCalls.last?.intensity
                note("flags: while the minimum is dragged, \(fixture.settings[3]), displays at \(String(describing: shown))")
                #expect(abs(manager.adaptiveMin - (0.2 + 40.0 / LiveSlider.usableWidth)) < 0.01, "the drag did not move the minimum")
                #expect(manager.adaptiveMax == 0.8, "the drag moved the maximum")
                #expect(shown.map { abs(Double($0) - manager.adaptiveMin) < 1e-6 } == true,
                        "the displays do not show the minimum being dragged")
                // And so does the popover, with the button still down: what the window
                // server shows is painted in the limit's colour, not the value's.
                let image = try #require(live.windowImage())
                let onScreen = try Raster(image: image)
                let isDark = live.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                @MainActor func painted(_ intensity: Double) -> Int {
                    let color = EmberTint.rgb(intensity: intensity, scheme: isDark ? .dark : .light)
                    let wanted = [Int(color.r.rounded()), Int(color.g.rounded()), Int(color.b.rounded())]
                    return stride(from: 0, to: onScreen.pixels.count, by: 4).count { index in
                        (0..<3).allSatisfy { abs(Int(onScreen.pixels[index + $0]) - wanted[$0]) <= 4 }
                    }
                }
                #expect(manager.intensity == 0.8, "the value moved during the drag")
                #expect(painted(manager.adaptiveMin) > 2000, "the popover is not in the dragged limit's colour")
                #expect(painted(0.8) == 0, "the popover is still in the value's colour")
                if let directory = LivePopoverEnvironment.shotDirectory {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try live.raster().writePNG(to: directory.appendingPathComponent("flag-drag.png"))
                    try onScreen.shown(on: (90, 90, 90)).writePNG(to: directory.appendingPathComponent("flag-drag-window.png"))
                }
            }
            let shown = fixture.gamma.applyCalls.last?.intensity
            note("flags: released, \(fixture.settings[3]), displays at \(String(describing: shown))")
            #expect(abs(manager.intensity - 0.8) < 1e-9, "the value moved")
            #expect(shown.map { abs(Double($0) - manager.intensity) < 1e-6 } == true,
                    "the release did not go back to the real value")
        }
    }

    /// A press on a flag that does not move still shows its limit, on the displays and in the
    /// popover's colours, for as long as the button is down. Nothing is changed by it.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aPressOnAFlagPreviewsItsLimitBeforeItMoves() async throws {
        try inRunLoopTurn {
            let (fixture, live, _) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            let flags = try live.flagStops()
            try #require(flags.count == 4, "found \(flags.count) flag stops")
            let before = fixture.settings
            // Colour temp minimum (20 %), its maximum (80 %, where the value rests), then the
            // white point's minimum.
            for (index, expected) in [(0, manager.adaptiveMin), (1, manager.adaptiveMax)] {
                try live.drag(from: centre(flags[index]), dx: 0) {
                    let shown = fixture.gamma.applyCalls.last?.intensity
                    #expect(shown.map { abs(Double($0) - expected) < 1e-6 } == true,
                            "flag \(index) held still: the displays show \(String(describing: shown)), not \(expected)")
                    #expect(manager.shownIntensity == expected)
                }
                #expect(manager.shownIntensity == manager.intensity, "the release did not end the preview")
                let shown = fixture.gamma.applyCalls.last?.intensity
                #expect(shown.map { abs(Double($0) - manager.intensity) < 1e-6 } == true)
            }
            try live.drag(from: centre(flags[2]), dx: 0) {
                let shown = fixture.gamma.applyCalls.last?.whitepoint
                #expect(shown.map { abs(Double($0) - manager.adaptiveWpMin) < 1e-6 } == true,
                        "the white point's minimum held still shows \(String(describing: shown))")
                #expect(manager.shownWhitepoint == manager.adaptiveWpMin)
            }
            #expect(manager.shownWhitepoint == manager.whitepoint)
            #expect(fixture.settings == before, "a press that did not move changed a setting")
        }
    }

    /// Partway down the evening's curve: the minimum dragged past the value carries the
    /// value, and the slider and the displays agree once the button is up.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aMinimumDraggedPastTheValueCarriesIt() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture(
                defaults: ["redlight.adaptiveEnabled": true, "redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8],
                now: { Date(timeIntervalSince1970: 1_774_050_000) })
            defer { fixture.retire() }
            let manager = fixture.manager
            let live = try LivePopover(fixture.view())
            defer { live.close() }
            let start = manager.intensity
            try #require(start > 0.25 && start < 0.7, "the evening is not partway down the band: \(start)")
            let flags = try live.flagStops()
            let target = start + 0.1
            try live.drag(from: centre(flags[0]), dx: CGFloat(target - 0.2) * CGFloat(LiveSlider.usableWidth), steps: 8)
            note("flags: minimum dragged past the value \(start): \(fixture.settings[3])")
            #expect(manager.adaptiveMin > start, "the minimum did not pass the value")
            #expect(manager.intensity >= manager.adaptiveMin - 1e-9, "the value did not follow the minimum")
            let shown = fixture.gamma.applyCalls.last?.intensity
            #expect(shown.map { abs(Double($0) - manager.intensity) < 1e-6 } == true,
                    "the displays show \(String(describing: shown)), the slider \(manager.intensity)")
        }
    }

    /// The value dragged to 100 % pushes the maximum flag along to the end.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aValueDraggedToTheEndPushesTheMaximumFlag() async throws {
        try inRunLoopTurn {
            let (fixture, live, sliders) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            let color = sliders[0]
            let before = try live.flagStops()
            let x = color.x(for: manager.intensity, range: Self.colorRange)
            try live.drag(from: color.point(x: x), dx: color.pill.width + 8 - x, steps: 8)
            let after = try live.flagStops()
            note("flags: value dragged to the end, \(fixture.settings[3]), maximum flag \(before[1].midX) → \(after[1].midX)")
            #expect(manager.intensity == 1 && manager.adaptiveMax == 1)
            #expect(after[1].midX > before[1].midX, "the maximum flag did not move")
            #expect(after[0] == before[0], "the minimum flag moved")
        }
    }

    /// A pinned band shows one chip; a drag splits it in its own direction.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func aPinnedChipSplitsInTheDragsDirection() async throws {
        try inRunLoopTurn {
            for dx: CGFloat in [-30, 30] {
                let (fixture, live, _) = try openAuto(["redlight.adaptiveMin": 0.6, "redlight.adaptiveMax": 0.6])
                defer { live.close(); fixture.retire() }
                let manager = fixture.manager
                let flags = try live.flagStops()
                try #require(flags.count == 4)
                #expect(flags[0] == flags[1], "the pinned band's two stops are not on one chip")
                try live.drag(from: centre(flags[0]), dx: dx)
                note("flags pinned, dragged \(dx): \(fixture.settings[3])")
                if dx < 0 {
                    #expect(manager.adaptiveMin < 0.6 - 0.05 + 1e-9 && manager.adaptiveMax == 0.6)
                } else {
                    #expect(manager.adaptiveMax > 0.6 + 0.05 - 1e-9 && manager.adaptiveMin == 0.6)
                }
            }
        }
    }

    /// Tab goes value, minimum, maximum for each slider; the keys move a focused flag.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func tabGoesValueMinimumMaximumAndTheKeysMoveAFlag() async throws {
        try inRunLoopTurn {
            let (fixture, live, sliders) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            let flags = try live.flagStops()
            try #require(flags.count == 4)
            var order: [CGRect] = []
            for _ in 0..<6 {
                try live.key(.tab)
                order.append(try #require(live.focusFrame, "Tab left the document: \(live.focusDescription)"))
            }
            note("flags: the first six Tab stops \(order)")
            #expect(order == [sliders[0].pill, flags[0], flags[1], sliders[1].pill, flags[2], flags[3]],
                    "Tab did not go value, minimum, maximum")
            // Back to the colour temp's minimum: Shift-Tab is not sent, so go round.
            for _ in 0..<12 where live.focusFrame != flags[0] { try live.key(.tab) }
            try #require(live.focusFrame == flags[0], "Tab never came back to the minimum")
            try live.key(.left)
            #expect(abs(manager.adaptiveMin - 0.19) < 1e-9, "Left did not lower the minimum by 1 %: \(manager.adaptiveMin)")
            try live.key(.home)
            #expect(manager.adaptiveMin == 0, "Home did not take the minimum to 0 %")
            try live.key(.right, shift: true)
            #expect(abs(manager.adaptiveMin - 0.1) < 1e-9, "Shift-Right did not raise the minimum by 10 %")
            try live.key(.tab)
            try live.key(.end)
            #expect(manager.adaptiveMax == 1, "End did not take the maximum to 100 %")
            // Home takes the maximum as far down as it goes: onto the minimum, one fixed value.
            try live.key(.home)
            #expect(manager.adaptiveMax == manager.adaptiveMin && abs(manager.adaptiveMax - 0.1) < 1e-9,
                    "Home did not merge the maximum with the minimum: \(manager.adaptiveMax)")
            #expect(manager.intensity == manager.adaptiveMax, "Auto did not land in the new range at once")
            // One step back up opens the band by the gap, never by less; the next is 1 %.
            try live.key(.right)
            #expect(abs(manager.adaptiveMax - 0.15) < 1e-9 && abs(manager.adaptiveMin - 0.1) < 1e-9,
                    "Right did not open the band by the gap: \(manager.adaptiveMin)…\(manager.adaptiveMax)")
            try live.key(.right)
            #expect(abs(manager.adaptiveMax - 0.16) < 1e-9, "Right did not raise the maximum by 1 %")
            // And back down: 1 %, then across the gap onto the minimum again.
            try live.key(.left)
            try live.key(.left)
            #expect(manager.adaptiveMax == manager.adaptiveMin, "Left at the gap did not merge the limits")
        }
    }

    // MARK: Focus

    /// Presses Tab until the focus is back where the first Tab put it, and returns the
    /// stops in order. A stop that takes several presses, as the time field does for its
    /// hour and minute, counts once.
    private func tabRound(_ live: LivePopover, limit: Int = 30,
                          at stop: @MainActor (CGRect) throws -> Void = { _ in }) throws -> [CGRect] {
        var stops: [CGRect] = []
        for _ in 0..<limit {
            try live.key(.tab)
            let frame = try #require(live.focusFrame, "Tab left the document: \(live.focusDescription)")
            if frame == stops.last { continue }
            if frame == stops.first { break }
            stops.append(frame)
            try stop(frame)
        }
        return stops
    }

    /// What has the keyboard when the popover opens, and where Tab and the keys take it. Auto
    /// in the afternoon with a 20–80 % band: the values rest on their upper limits.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func opensWithNoControlFocusedAndTabVisitsEachSliderOnce() async throws {
        try inRunLoopTurn {
            let (fixture, live, sliders) = try openAuto()
            defer { live.close(); fixture.retire() }
            let manager = fixture.manager
            let color = sliders[0], white = sliders[1]
            try #require(abs(manager.intensity - 0.8) < 1e-9 && manager.whitepoint == manager.adaptiveWpMax,
                         "the values are not on their upper limits")
            // A column a point left of the grabber's centre, with bare fill 14 pt left of it.
            @MainActor func grabberHeight(_ slider: LiveSlider, _ value: Double, _ range: ClosedRange<Double>) throws -> CGFloat {
                try live.markHeight(in: slider, x: slider.x(for: value, range: range) - 1)
            }
            @MainActor func colorGrabber() throws -> CGFloat { try grabberHeight(color, manager.intensity, Self.colorRange) }
            @MainActor func whiteGrabber() throws -> CGFloat { try grabberHeight(white, manager.whitepoint, Self.whiteRange) }
            // Drawn a fraction taller or shorter than its size, by the antialiasing at its ends.
            let restHeight = EmberSlider.grabberSize(.rest).height
            let rest = (restHeight - 1.5)...(restHeight + 1)
            let focusedFloor = EmberSlider.grabberSize(.focused).height - 2

            let loop = live.keyViewLoop()
            note("focus on open: first responder \(live.focusDescription); keyboard navigation "
                 + "\(NSApp.isFullKeyboardAccessEnabled ? "on" : "off"); app active \(NSApp.isActive), "
                 + "window key \(live.window.isKeyWindow)")
            note("focus: Tab stops \(loop)")

            // The keyboard starts with the popover's own root view: no control has it.
            let startsOnRoot = live.window.firstResponder === live.scroll
            try #require(startsOnRoot, "the first responder is \(live.focusDescription)")
            let atOpen = (try colorGrabber(), try whiteGrabber())
            note("focus on open: grabbers drawn \(atOpen.0) and \(atOpen.1) pt tall (rest \(restHeight), focused \(EmberSlider.grabberSize(.focused).height))")
            #expect(rest.contains(atOpen.0) && rest.contains(atOpen.1), "a grabber is not at rest")

            // Space and the arrows change nothing there, and nothing shows focus after them.
            let before = fixture.settings
            for key in [LiveKey.space, .left, .right] {
                try live.key(key)
                #expect(fixture.settings == before, "\(key) changed \(zip(before, fixture.settings).filter { $0 != $1 })")
                #expect(live.popover.isShown)
            }
            #expect(rest.contains(try colorGrabber()))

            // The first Tab goes to the colour temp slider, which shows its focus. The arrows
            // move it by 1 % and leave the limits; End and Home take it to the ends, moving
            // the limit in the way.
            try #require(loop.count >= 6)
            try live.key(.tab)
            #expect(live.focusFrame == color.pill, "the first Tab went to \(live.focusDescription)")
            let focused = try colorGrabber()
            note("focus: after Tab the colour temp grabber is drawn \(focused) pt tall")
            #expect(focused > focusedFloor, "the grabber does not show the focus Tab gave it")
            try live.key(.left)
            note("focus: Left on the colour temp: \(fixture.settings[3])")
            #expect(abs(manager.intensity - 0.79) < 1e-9, "Left did not lower the value by 1 %")
            #expect(manager.adaptiveMin == 0.2 && manager.adaptiveMax == 0.8, "Left moved a limit")
            try live.key(.right)
            #expect(abs(manager.intensity - 0.8) < 1e-9)
            try live.key(.left, shift: true)
            #expect(abs(manager.intensity - 0.7) < 1e-9, "Shift-Left did not lower the value by 10 %")
            try live.key(.end)
            note("focus: End on the colour temp: \(fixture.settings[3])")
            #expect(manager.intensity == 1.0 && manager.adaptiveMax == 1.0, "End did not reach 100 %")
            try live.key(.home)
            note("focus: Home on the colour temp: \(fixture.settings[3])")
            #expect(manager.intensity == 0.0 && manager.adaptiveMin == 0.0, "Home did not reach 0 %")
            try live.key(.end)

            // Tab goes round every stop once and comes back: both sliders with their flags.
            // (With keyboard navigation on, the buttons as well.)
            // The keys above moved the flags: the stops as they are now.
            let loopNow = live.keyViewLoop()
            let stops = try tabRound(live) { stop in
                guard stop == white.pill else { return }
                #expect(try whiteGrabber() > focusedFloor, "the white point grabber does not show the focus Tab gave it")
                #expect(rest.contains(try colorGrabber()), "the colour temp grabber still shows focus")
                let whitepoint = manager.whitepoint
                try live.key(.left)
                // One percent of the white point's own scale, 0.25 to 1.
                #expect(abs(manager.whitepoint - (whitepoint - 0.0075)) < 1e-9,
                        "Left on the white point did not lower it by 1 %")
                try live.key(.right)
            }
            note("focus: a round of Tab visited \(stops)")
            #expect(Set(stops.map { "\($0)" }) == Set(loopNow.map { "\($0)" }), "Tab did not visit every stop")
            #expect(stops.count == loopNow.count, "Tab visited a stop twice in one round")
            #expect(stops.filter { $0 == color.pill }.count == 1 && stops.filter { $0 == white.pill }.count == 1)
            // The bedtime field is on the Settings page now: none of these stops is it.
            #expect(live.views().compactMap { $0 as? NSDatePicker }.isEmpty)
        }
    }

    /// The app's popover animates in, and the controller hands the keyboard to the root view
    /// as soon as `show` returns, before the animation. It must still be there, with the
    /// surface, once the popover has shown, in Auto and on a page with no Tab stop.
    @Test(.enabled(if: LivePopoverEnvironment.enabled), arguments: [MenuBarPage.controls, .settings])
    func anAnimatedOpeningLeavesTheKeyboardOnTheRootView(page: MenuBarPage) async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto(["redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8])
            defer { fixture.retire() }
            let live = try LivePopover(
                fixture.view(page: page, MenuBarInitialState(updateAvailable: false)), animated: true)
            defer { live.close() }
            live.pump(0.6)
            note("animated \(page): did show \(live.sawDidShow), first responder \(live.focusDescription)")
            #expect(live.popover.animates)
            #expect(live.sawDidShow, "the popover never said it had shown")
            let startsOnRoot = live.window.firstResponder === live.scroll
            #expect(startsOnRoot, "the first responder is \(live.focusDescription)")
            let surfaces = live.window.contentView?.superview?.subviews.filter { $0 is PopoverSurfaceView } ?? []
            #expect(surfaces.count == 1, "the popover has \(surfaces.count) surfaces")
            // And the first Tab still goes to the first control, where there is one.
            if page == .controls, startsOnRoot {
                let loop = live.keyViewLoop()
                try live.key(.tab)
                #expect(live.focusFrame == loop.first, "the first Tab went to \(live.focusDescription)")
            }
        }
    }

    /// A pinned band keeps the Tab order: its one chip holds the minimum's and the maximum's stops.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func tabGoesThroughAPinnedBand() async throws {
        try inRunLoopTurn {
            let (fixture, live, _) = try openAuto(["redlight.adaptiveMin": 0.6, "redlight.adaptiveMax": 0.6])
            defer { live.close(); fixture.retire() }
            let loop = live.keyViewLoop()
            let stops = try tabRound(live)
            note("focus pinned: Tab stops \(loop), a round visited \(stops)")
            try #require(loop.count >= 6)
            #expect(Set(stops.map { "\($0)" }) == Set(loop.map { "\($0)" }), "Tab did not visit every stop")
            #expect(stops.count == Set(loop.map { "\($0)" }).count, "Tab visited a stop twice in one round")
        }
    }

    // MARK: Escape

    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func escapeClosesFromTheControlsPage() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            defer { fixture.retire() }
            let live = try LivePopover(fixture.view())
            defer { live.close() }
            note("escape, controls: first responder \(live.focusDescription)")
            try #require(live.popover.isShown)
            try live.key(.escape)
            #expect(!live.popover.isShown, "Escape did not close the popover from the controls")
        }
    }

    /// With the keyboard on a slider handle, where SwiftUI hears Escape itself.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func escapeClosesFromASliderHandle() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            defer { fixture.retire() }
            let live = try LivePopover(fixture.view())
            defer { live.close() }
            try live.key(.tab)
            note("escape, slider handle: first responder \(live.focusDescription)")
            try #require(live.focusFrame != nil && live.window.firstResponder !== live.scroll)
            try #require(live.popover.isShown)
            try live.key(.escape)
            #expect(!live.popover.isShown, "Escape did not close the popover from a slider handle")
        }
    }

    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func escapeClosesFromSettings() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            defer { fixture.retire() }
            let live = try LivePopover(fixture.view(page: .settings, MenuBarInitialState(updateAvailable: false)))
            defer { live.close() }
            note("escape, settings: first responder \(live.focusDescription)")
            try #require(live.popover.isShown)
            try live.key(.escape)
            #expect(!live.popover.isShown, "Escape did not close the popover from Settings")
        }
    }

    /// A click on the page's title, which is no control, must not leave the popover deaf.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func escapeClosesAfterAClickOnNothing() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            defer { fixture.retire() }
            let live = try LivePopover(fixture.view(page: .settings, MenuBarInitialState(updateAvailable: false)))
            defer { live.close() }
            try live.click(at: CGPoint(x: EmberMetrics.width / 2, y: EmberMetrics.padding + 10))
            note("escape, after a click on the title: first responder \(live.focusDescription)")
            try #require(live.popover.isShown)
            try live.key(.escape)
            #expect(!live.popover.isShown, "Escape did not close the popover after a click on nothing")
        }
    }

    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func escapeClosesFromACoordinateField() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture(defaults: ["redlight.adaptiveEnabled": true], manualLocation: true)
            defer { fixture.retire() }
            let live = try LivePopover(fixture.view(page: .settings, MenuBarInitialState(updateAvailable: false)))
            defer { live.close() }
            let latitude = try #require(live.views().compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "Latitude" })
            let frame = live.frame(of: latitude)
            try live.click(at: CGPoint(x: frame.midX, y: frame.midY))
            note("escape, coordinate field: first responder \(live.focusDescription)")
            try #require(live.window.firstResponder is NSTextView, "the click did not start editing the field")
            try live.key(.character("4"))
            try #require(live.popover.isShown)
            try live.key(.escape)
            #expect(!live.popover.isShown, "Escape did not close the popover from a coordinate field")
            #expect(fixture.manager.manualLocation?.latitude == 41.88, "Escape applied the half-typed latitude")
        }
    }

    /// Settings is kept out of sight after Back, its fields with it: a field that was being
    /// typed in gives the keyboard back, and Tab on the controls never reaches the page.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func backTakesTheKeyboardFromASettingsFieldAndTabStaysOnTheControls() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture(defaults: ["redlight.adaptiveEnabled": true], manualLocation: true)
            defer { fixture.retire() }
            let live = try LivePopover(fixture.view(page: .settings, MenuBarInitialState(updateAvailable: false)),
                                       animated: true)
            defer { live.close() }
            let latitude = try #require(live.views().compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "Latitude" })
            let frame = live.frame(of: latitude)
            try live.click(at: CGPoint(x: frame.midX, y: frame.midY))
            try #require(live.window.firstResponder is NSTextView, "the click did not start editing the field")
            try live.key(.character("4"))
            let typed = latitude.stringValue
            // Back, at the top left of the page.
            let height = live.document.bounds.height
            let back = CGPoint(x: EmberMetrics.padding + 18, y: EmberMetrics.padding + 13)
            try live.click(at: CGPoint(x: back.x, y: live.document.isFlipped ? back.y : height - back.y))
            live.pump(0.6)
            #expect(!(live.window.firstResponder is NSTextView), "the field out of sight still has the keyboard")
            try live.key(.character("5"))
            #expect(latitude.stringValue == typed, "typing reached the field out of sight: \(latitude.stringValue)")
            #expect(fixture.manager.manualLocation?.latitude == 41.88)
            // Round the controls with Tab: never into a view of the page out of sight.
            guard let content = live.window.contentView else { return }
            for press in 0..<14 {
                try live.key(.tab)
                guard let view = live.window.firstResponder as? NSView else { continue }
                let onScreen = view.convert(view.bounds, to: nil).intersects(content.frame)
                #expect(onScreen && !(view is NSTextView) && !(view is NSDatePicker),
                        "Tab \(press) reached \(type(of: view)) out of sight")
            }
        }
    }

    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func escapeClosesFromTheBedtimeField() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            defer { fixture.retire() }
            // "Deepest by" is at the top of the Settings page.
            let live = try LivePopover(fixture.view(page: .settings))
            defer { live.close() }
            let picker = try #require(live.views().compactMap { $0 as? NSDatePicker }.first)
            let frame = live.frame(of: picker)
            // On the hour, at the leading end of the field.
            try live.click(at: CGPoint(x: frame.minX + 12, y: frame.midY))
            note("escape, bedtime field: first responder \(live.focusDescription)")
            try #require(live.window.firstResponder === picker, "the click did not put the keyboard in the bedtime field")
            try #require(live.popover.isShown)
            try live.key(.escape)
            #expect(!live.popover.isShown, "Escape did not close the popover from the bedtime field")
        }
    }

    // MARK: Return

    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func entersManualCoordinatesThroughNativePopover() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture(defaults: ["redlight.adaptiveEnabled": true], manualLocation: true)
            defer { fixture.retire() }
            // The coordinate fields live on the Settings page.
            let live = try LivePopover(fixture.view(page: .settings, MenuBarInitialState(updateAvailable: false)))
            defer { live.close() }
            let fields = live.views().compactMap { $0 as? NSTextField }
            let latitude = try #require(fields.first { $0.placeholderString == "Latitude" })
            let longitude = try #require(fields.first { $0.placeholderString == "Longitude" })
            try enter("42", in: latitude, live)
            try enter("-88", in: longitude, live)
            try live.key(.enter)
            note("return: manual location \(String(describing: fixture.manager.manualLocation))")
            #expect(fixture.manager.manualLocation?.latitude == 42)
            #expect(fixture.manager.manualLocation?.longitude == -88)
            #expect(live.popover.isShown, "Return closed the popover")
        }
    }

    private func enter(_ text: String, in field: NSTextField, _ live: LivePopover) throws {
        let frame = live.frame(of: field)
        try live.click(at: CGPoint(x: frame.midX, y: frame.midY))
        let editor = try #require(live.window.firstResponder as? NSTextView, "the click did not start editing")
        editor.selectAll(nil)
        for character in text { try live.key(.character(character), settle: 0.05) }
    }
}
