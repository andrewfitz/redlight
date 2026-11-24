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
        let size = CGSize(width: EmberFlagFace.hitWidth, height: EmberFlagFace.rowHeight - 6)
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

    // MARK: Slider press and drag

    private static let whiteRange = 0.25...1.0

    private func openAuto(_ extra: [String: Any] = ["redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8])
        throws -> (LivePopoverFixture, LivePopover, [LiveSlider]) {
        let fixture = LivePopoverFixture.auto(extra)
        let live = try LivePopover(fixture.view())
        let sliders = try live.sliders()
        try #require(sliders.count == 2, "found \(sliders.count) sliders")
        return (fixture, live, sliders)
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
            // (Reset itself answers only on its drawn chip), and the chip still works.
            let underReset = color.pill.width - 60
            try live.drag(from: color.point(x: underReset, dy: -(EmberMetrics.sliderHeight / 2 + 2.5)), dx: 0)
            note("slider auto, pressed over the pill under Reset: \(fixture.settings[3])")
            #expect(abs(manager.intensity - 0.3) < 0.005, "the slop under Reset took the press")
            try live.drag(from: color.point(x: underReset, dy: -27), dx: 0)
            note("slider auto, pressed on Reset: \(fixture.settings[3])")
            #expect(manager.adaptiveMin == 0 && manager.adaptiveMax == 1, "Reset did not take the press on its chip")

            // The drag follows the pointer.
            try live.drag(from: color.point(x: color.x(for: 0.6, range: Self.colorRange)), dx: -40)
            #expect(abs(manager.intensity - (0.6 - 40.0 / 254)) < 0.01, "the value did not follow the drag")
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
            #expect(abs(manager.intensity - (0.6 - 40.0 / 254)) < 0.01, "the value did not follow the drag")
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
            #expect(abs(manager.intensity - (preset - 30.0 / 254)) < 0.01, "the value did not follow the drag")
            #expect(manager.activePresetIndex == nil)

            try live.drag(from: slider.point(x: slider.x(for: 0.9, range: Self.colorRange)), dx: 0)
            #expect(abs(manager.intensity - 0.9) < 0.005, "a press on the track did not take the value there")
        }
    }

    // MARK: Auto's limit flags

    /// The centre of a flag's keyboard stop, which is the centre of its chip's row.
    private func centre(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

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
                #expect(abs(manager.adaptiveMin - (0.2 + 40.0 / 254)) < 0.01, "the drag did not move the minimum")
                #expect(manager.adaptiveMax == 0.8, "the drag moved the maximum")
                #expect(shown.map { abs(Double($0) - manager.adaptiveMin) < 1e-6 } == true,
                        "the displays do not show the minimum being dragged")
                if let directory = LivePopoverEnvironment.shotDirectory {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try live.raster().writePNG(to: directory.appendingPathComponent("flag-drag.png"))
                }
            }
            let shown = fixture.gamma.applyCalls.last?.intensity
            note("flags: released, \(fixture.settings[3]), displays at \(String(describing: shown))")
            #expect(abs(manager.intensity - 0.8) < 1e-9, "the value moved")
            #expect(shown.map { abs(Double($0) - manager.intensity) < 1e-6 } == true,
                    "the release did not go back to the real value")
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
            try live.drag(from: centre(flags[0]), dx: CGFloat(target - 0.2) * 254, steps: 8)
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
            try live.key(.home)
            #expect(abs(manager.adaptiveMax - 0.15) < 1e-9, "the maximum came closer than 5 %: \(manager.adaptiveMax)")
            #expect(manager.intensity == manager.adaptiveMax, "Auto did not land in the new range at once")
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
            let rest = 14.5...17.0

            let loop = live.keyViewLoop()
            note("focus on open: first responder \(live.focusDescription); keyboard navigation "
                 + "\(NSApp.isFullKeyboardAccessEnabled ? "on" : "off"); app active \(NSApp.isActive), "
                 + "window key \(live.window.isKeyWindow)")
            note("focus: Tab stops \(loop)")

            // The keyboard starts with the popover's own root view: no control has it.
            let startsOnRoot = live.window.firstResponder === live.scroll
            try #require(startsOnRoot, "the first responder is \(live.focusDescription)")
            let atOpen = (try colorGrabber(), try whiteGrabber())
            note("focus on open: grabbers drawn \(atOpen.0) and \(atOpen.1) pt tall (rest 16, focused 22)")
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
            try #require(loop.count >= 7)
            try live.key(.tab)
            #expect(live.focusFrame == color.pill, "the first Tab went to \(live.focusDescription)")
            let focused = try colorGrabber()
            note("focus: after Tab the colour temp grabber is drawn \(focused) pt tall")
            #expect(focused > 20, "the grabber does not show the focus Tab gave it")
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

            // Tab goes round every stop once and comes back: both sliders with their flags, and
            // the bedtime field. (With keyboard navigation on, the buttons as well.)
            // The keys above moved the flags: the stops as they are now.
            let loopNow = live.keyViewLoop()
            let stops = try tabRound(live) { stop in
                guard stop == white.pill else { return }
                #expect(try whiteGrabber() > 20, "the white point grabber does not show the focus Tab gave it")
                #expect(rest.contains(try colorGrabber()), "the colour temp grabber still shows focus")
                let whitepoint = manager.whitepoint
                try live.key(.left)
                #expect(abs(manager.whitepoint - (whitepoint - 0.01)) < 1e-9,
                        "Left on the white point did not lower it by 1 %")
                try live.key(.right)
            }
            note("focus: a round of Tab visited \(stops)")
            #expect(Set(stops.map { "\($0)" }) == Set(loopNow.map { "\($0)" }), "Tab did not visit every stop")
            #expect(stops.count == loopNow.count, "Tab visited a stop twice in one round")
            #expect(stops.filter { $0 == color.pill }.count == 1 && stops.filter { $0 == white.pill }.count == 1)
            let picker = try #require(live.views().compactMap { $0 as? NSDatePicker }.first)
            #expect(stops.contains(live.frame(of: picker)))
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
            try #require(loop.count >= 7)
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

    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func escapeClosesFromTheBedtimeField() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto()
            defer { fixture.retire() }
            let live = try LivePopover(fixture.view())
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
