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
            gamma: MockGammaController(), getDisplayIDs: { ids },
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
    case tab, space, escape, enter, left, right
    case character(Character)

    var code: UInt16 {
        switch self {
        case .tab: 48
        case .space: 49
        case .escape: 53
        case .enter: 36
        case .left: 123
        case .right: 124
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
        case .character(let character): String(character)
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .left, .right: [.numericPad, .function]
        default: []
        }
    }
}

/// One slider's pill in the document, found from the grabber SwiftUI lays out.
struct LiveSlider {
    /// In the document's coordinates.
    let pill: CGRect
    let grabber: CGRect

    /// A point `x` along the pill and `dy` below its centre line, as `BandSliderFace` counts.
    func point(x: CGFloat, dy: CGFloat = 0) -> CGPoint {
        CGPoint(x: pill.minX + x, y: pill.midY + dy)
    }

    func face(value: Double, lower: Double, upper: Double, range: ClosedRange<Double>, showBand: Bool)
        -> BandSliderFace {
        BandSliderFace(value: value, lower: lower, upper: upper, range: range,
                       showBand: showBand, width: pill.width)
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

    func key(_ key: LiveKey, settle: TimeInterval = 0.25) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: key.modifiers,
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
    func drag(from start: CGPoint, dx: CGFloat, steps: Int = 5) throws {
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

    /// The sliders, top to bottom: each has one focusable view the size of a grabber at rest.
    func sliders() throws -> [LiveSlider] {
        let grabbers = views()
            .filter { $0.acceptsFirstResponder && $0.bounds.size == BandSliderFace.grabSize }
            .map(frame(of:))
            .sorted { $0.minY < $1.minY }
        try #require(!grabbers.isEmpty, "no slider grabber among the focusable views")
        return grabbers.map { grabber in
            LiveSlider(
                pill: CGRect(x: EmberMetrics.padding, y: grabber.midY - EmberMetrics.sliderHeight / 2,
                             width: EmberMetrics.width - 2 * EmberMetrics.padding,
                             height: EmberMetrics.sliderHeight),
                grabber: grabber)
        }
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

    /// Auto in the afternoon: the value rests on its upper limit. The grabber moves the
    /// value and leaves the limit; the tick above or below it moves the limit.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func grabberOnItsUpperLimitMovesTheValueAndItsTicksMoveTheLimit() async throws {
        try inRunLoopTurn {
            @MainActor func open() throws -> (LivePopoverFixture, LivePopover, LiveSlider) {
                let fixture = LivePopoverFixture.auto(["redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8])
                let live = try LivePopover(fixture.view())
                let slider = try #require(try live.sliders().first)
                return (fixture, live, slider)
            }
            @MainActor func face(_ fixture: LivePopoverFixture, _ slider: LiveSlider) -> BandSliderFace {
                slider.face(value: fixture.manager.intensity, lower: fixture.manager.adaptiveMin,
                            upper: fixture.manager.adaptiveMax, range: Self.colorRange, showBand: true)
            }

            do {
                let (fixture, live, slider) = try open()
                defer { live.close(); fixture.retire() }
                let manager = fixture.manager
                try #require(abs(manager.intensity - 0.8) < 1e-9, "the value is not on its upper limit: \(manager.intensity)")
                let start = face(fixture, slider)
                // The locator and the face agree on where the grabber is.
                #expect(abs(slider.point(x: start.valueX).x - slider.grabber.midX) < 0.6)
                #expect(start.upperTickOpacity == 1, "the upper notch is not under the grabber")

                try live.drag(from: slider.point(x: start.valueX), dx: -40)
                note("slider auto, grabber dragged left 40: value \(manager.intensity), "
                     + "limits \(manager.adaptiveMin)...\(manager.adaptiveMax)")
                #expect(abs(manager.intensity - (0.8 - 40.0 / 254)) < 0.01, "the value did not follow the drag")
                #expect(manager.adaptiveMax == 0.8, "the grabber moved the upper limit")
                #expect(manager.adaptiveMin == 0.2)
            }

            do {
                let (fixture, live, slider) = try open()
                defer { live.close(); fixture.retire() }
                let manager = fixture.manager
                let start = face(fixture, slider)
                // The tick shows above and below the grabber, a point inside the pill.
                try live.drag(from: slider.point(x: start.upperNotchX, dy: -11.5), dx: -40)
                note("slider auto, tick above dragged left 40: value \(manager.intensity), "
                     + "limits \(manager.adaptiveMin)...\(manager.adaptiveMax)")
                #expect(abs(manager.adaptiveMax - (0.8 - 40.0 / 254)) < 0.01, "the tick above did not move the limit")
                #expect(manager.adaptiveMin == 0.2)

                let lowered = manager.adaptiveMax
                let next = face(fixture, slider)
                try live.drag(from: slider.point(x: next.upperNotchX, dy: 11.5), dx: 30)
                note("slider auto, tick below dragged right 30: value \(manager.intensity), "
                     + "limits \(manager.adaptiveMin)...\(manager.adaptiveMax)")
                #expect(abs(manager.adaptiveMax - (lowered + 30.0 / 254)) < 0.01, "the tick below did not move the limit")
                #expect(manager.adaptiveMin == 0.2)
            }
        }
    }

    /// A pinned band is one fixed value. The grabber moves it, and the band stays pinned;
    /// a tick takes one limit away from the other and leaves that one where it was.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func grabberOnAPinnedBandMovesThePinAndItsTicksWidenTheBand() async throws {
        try inRunLoopTurn {
            @MainActor func open() throws -> (LivePopoverFixture, LivePopover, LiveSlider) {
                let fixture = LivePopoverFixture.auto(["redlight.adaptiveMin": 0.6, "redlight.adaptiveMax": 0.6])
                let live = try LivePopover(fixture.view())
                let slider = try #require(try live.sliders().first)
                return (fixture, live, slider)
            }
            @MainActor func face(_ fixture: LivePopoverFixture, _ slider: LiveSlider) -> BandSliderFace {
                slider.face(value: fixture.manager.intensity, lower: fixture.manager.adaptiveMin,
                            upper: fixture.manager.adaptiveMax, range: Self.colorRange, showBand: true)
            }

            do {
                let (fixture, live, slider) = try open()
                defer { live.close(); fixture.retire() }
                let manager = fixture.manager
                try #require(abs(manager.intensity - 0.6) < 1e-9, "the value is not on the pin: \(manager.intensity)")
                let start = face(fixture, slider)
                #expect(start.isPinned)
                try live.drag(from: slider.point(x: start.valueX), dx: -40)
                note("slider pinned, grabber dragged left 40: value \(manager.intensity), "
                     + "limits \(manager.adaptiveMin)...\(manager.adaptiveMax)")
                #expect(abs(manager.intensity - (0.6 - 40.0 / 254)) < 0.01, "the value did not follow the drag")
                // The limits went with the value: had the press taken a limit, the other would
                // have stayed at 0.6 and the band would have opened.
                #expect(manager.adaptiveMin == manager.intensity && manager.adaptiveMax == manager.intensity,
                        "the band is no longer pinned on the value")
            }

            do {
                let (fixture, live, slider) = try open()
                defer { live.close(); fixture.retire() }
                let manager = fixture.manager
                let start = face(fixture, slider)
                try live.drag(from: slider.point(x: start.valueX, dy: -11.5), dx: -40)
                note("slider pinned, tick above dragged left 40: value \(manager.intensity), "
                     + "limits \(manager.adaptiveMin)...\(manager.adaptiveMax)")
                #expect(abs(manager.adaptiveMin - (0.6 - 40.0 / 254)) < 0.01, "the tick did not move the lower limit")
                #expect(manager.adaptiveMax == 0.6, "the upper limit moved with it")
            }

            do {
                let (fixture, live, slider) = try open()
                defer { live.close(); fixture.retire() }
                let manager = fixture.manager
                let start = face(fixture, slider)
                try live.drag(from: slider.point(x: start.valueX, dy: 11.5), dx: 40)
                note("slider pinned, tick below dragged right 40: value \(manager.intensity), "
                     + "limits \(manager.adaptiveMin)...\(manager.adaptiveMax)")
                #expect(abs(manager.adaptiveMax - (0.6 + 40.0 / 254)) < 0.01, "the tick did not move the upper limit")
                #expect(manager.adaptiveMin == 0.6, "the lower limit moved with it")
            }
        }
    }

    /// Manual at a preset: a click on the grabber that does not move changes nothing. The
    /// same press followed by a drag does, so the click did land on the grabber.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func clickOnTheGrabberKeepsThePreset() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture()
            defer { fixture.retire() }
            let manager = fixture.manager
            manager.applyPreset(3)
            let preset = manager.presets[3].intensity
            let live = try LivePopover(fixture.view())
            defer { live.close() }
            let slider = try #require(try live.sliders().first)
            let face = slider.face(value: preset, lower: 0, upper: 1, range: Self.colorRange, showBand: false)
            #expect(abs(slider.point(x: face.valueX).x - slider.grabber.midX) < 0.6)
            try #require(manager.activePresetIndex == 3 && manager.intensity == preset)

            try live.drag(from: slider.point(x: face.valueX), dx: 0)
            note("slider manual, grabber clicked: value \(manager.intensity), "
                 + "preset \(String(describing: manager.activePresetIndex))")
            #expect(manager.intensity == preset, "a click on the grabber changed the value")
            #expect(manager.activePresetIndex == 3, "a click on the grabber deselected the preset")

            // A point beside the centre of the grabber, still on it: the same.
            try live.drag(from: slider.point(x: face.valueX + 1.5, dy: 5), dx: 0)
            #expect(manager.intensity == preset && manager.activePresetIndex == 3)

            try live.drag(from: slider.point(x: face.valueX), dx: -30)
            note("slider manual, grabber dragged left 30: value \(manager.intensity), "
                 + "preset \(String(describing: manager.activePresetIndex))")
            #expect(abs(manager.intensity - (preset - 30.0 / 254)) < 0.01, "the value did not follow the drag")
            #expect(manager.activePresetIndex == nil)
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

    /// What has the keyboard when the popover opens, and where Tab and the arrows take it.
    /// The values rest on their upper limits, as they do by day: the stops that lie on top
    /// of each other.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func opensWithNoControlFocusedAndTabReachesEveryHandle() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto(["redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8])
            defer { fixture.retire() }
            let manager = fixture.manager
            let live = try LivePopover(fixture.view())
            defer { live.close() }
            let sliders = try live.sliders()
            try #require(sliders.count == 2)
            let color = sliders[0], white = sliders[1]
            try #require(abs(manager.intensity - 0.8) < 1e-9 && manager.whitepoint == manager.adaptiveWpMax,
                         "the values are not on their upper limits")
            @MainActor func colorFace() -> BandSliderFace {
                color.face(value: manager.intensity, lower: manager.adaptiveMin, upper: manager.adaptiveMax,
                           range: Self.colorRange, showBand: true)
            }
            @MainActor func whiteFace() -> BandSliderFace {
                white.face(value: manager.whitepoint, lower: manager.adaptiveWpMin, upper: manager.adaptiveWpMax,
                           range: 0.25...1.0, showBand: true)
            }
            // A column a point left of the grabber's centre is the grabber alone, clear of
            // the tick of the limit it rests on.
            @MainActor func grabberHeight(_ slider: LiveSlider, _ face: BandSliderFace) throws -> CGFloat {
                try live.markHeight(in: slider, x: face.valueX - 1)
            }
            @MainActor func lowerNotchHeight() throws -> CGFloat {
                try live.markHeight(in: color, x: colorFace().lowerNotchX, clear: 12)
            }
            let rest = 14.5...17.0, notchRest = 7.0...9.0

            let loop = live.keyViewLoop()
            note("focus on open: first responder \(live.focusDescription); keyboard navigation "
                 + "\(NSApp.isFullKeyboardAccessEnabled ? "on" : "off"); app active \(NSApp.isActive), "
                 + "window key \(live.window.isKeyWindow)")
            note("focus: Tab stops \(loop)")

            // The keyboard starts with the popover's own root view: no control has it. (The
            // keys below go nowhere else: a window that is its own first responder answers
            // a key it has no use for with the alert sound.)
            let startsOnRoot = live.window.firstResponder === live.scroll
            try #require(startsOnRoot, "the first responder is \(live.focusDescription)")
            // No handle is drawn focused before a key is pressed.
            let atOpen = (try grabberHeight(color, colorFace()), try grabberHeight(white, whiteFace()),
                          try lowerNotchHeight())
            note("focus on open: grabbers drawn \(atOpen.0) and \(atOpen.1) pt tall (rest 16, focused 22), "
                 + "lower limit \(atOpen.2) pt (rest 8, focused 22)")
            #expect(rest.contains(atOpen.0) && rest.contains(atOpen.1), "a grabber is not at rest")
            #expect(notchRest.contains(atOpen.2), "the lower limit is not at rest")

            // Space and the arrows change nothing there, and nothing shows focus after them.
            let before = fixture.settings
            for key in [LiveKey.space, .left, .right] {
                try live.key(key)
                #expect(fixture.settings == before, "\(key) changed \(zip(before, fixture.settings).filter { $0 != $1 })")
                #expect(live.popover.isShown)
            }
            #expect(rest.contains(try grabberHeight(color, colorFace())))
            #expect(notchRest.contains(try lowerNotchHeight()))

            // The first Tab goes to the first handle, the colour temp's lower limit, which
            // now shows its focus. An arrow moves it by 1 % and nothing else.
            try #require(loop.count >= 7)
            try live.key(.tab)
            #expect(live.focusFrame == loop[0], "the first Tab went to \(live.focusDescription)")
            let notchFocused = try lowerNotchHeight()
            note("focus: after Tab the lower limit is drawn \(notchFocused) pt tall")
            #expect(notchFocused > 20, "the lower limit does not show the focus Tab gave it")
            try live.key(.left)
            #expect(abs(manager.adaptiveMin - 0.19) < 1e-9 && manager.adaptiveMax == 0.8
                    && abs(manager.intensity - 0.8) < 1e-9, "Left on the lower limit: \(fixture.settings[3])")
            try live.key(.right)
            #expect(abs(manager.adaptiveMin - 0.2) < 1e-9)

            // The second goes to the value, which rests on its upper limit. It shows its
            // focus, the limit behind it is at rest again, and an arrow moves the value by
            // 1 % and leaves the limit.
            try live.key(.tab)
            #expect(live.focusFrame == color.grabber, "the second Tab went to \(live.focusDescription)")
            let focused = try grabberHeight(color, colorFace())
            note("focus: after the second Tab the grabber is drawn \(focused) pt tall")
            #expect(focused > 20, "the grabber does not show the focus Tab gave it")
            #expect(notchRest.contains(try lowerNotchHeight()), "the lower limit still shows focus")
            try live.key(.left)
            note("focus: Left on the value: \(fixture.settings[3])")
            #expect(abs(manager.intensity - 0.79) < 1e-9, "Left did not lower the value by 1 %")
            #expect(abs(manager.adaptiveMin - 0.2) < 1e-9 && manager.adaptiveMax == 0.8, "Left moved a limit")
            try live.key(.right)
            #expect(abs(manager.intensity - 0.8) < 1e-9)

            // Tab goes round every stop and comes back: both sliders' three handles and the
            // bedtime field. (With keyboard navigation on, the buttons as well.)
            let stops = try tabRound(live) { stop in
                if stop == loop[2] {
                    // The upper limit, under the grabber: focused, it is drawn in line with
                    // the grabber and over it, as one taller bar.
                    #expect(try grabberHeight(color, colorFace()) > 20,
                            "the upper limit does not show its focus over the grabber")
                }
                guard stop == white.grabber else { return }
                #expect(try grabberHeight(white, whiteFace()) > 20,
                        "the white point grabber does not show the focus Tab gave it")
                // The colour temp's grabber is at rest again now that the focus has moved on.
                #expect(rest.contains(try grabberHeight(color, colorFace())),
                        "the colour temp grabber still shows focus")
                try live.key(.left)
                #expect(abs(manager.whitepoint - (manager.adaptiveWpMax - 0.01)) < 1e-9,
                        "Left on the white point's value did not lower it by 1 %")
                try live.key(.right)
            }
            note("focus: a round of Tab visited \(stops)")
            #expect(Set(stops.map { "\($0)" }) == Set(loop.map { "\($0)" }), "Tab did not visit every stop")
            #expect(stops.count == loop.count, "Tab visited a stop twice in one round")
            let picker = try #require(live.views().compactMap { $0 as? NSDatePicker }.first)
            #expect(stops.contains(white.grabber) && stops.contains(live.frame(of: picker)))
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

    /// A pinned band has its three handles on one spot. Tab still goes through all of them
    /// and on to the next slider.
    @Test(.enabled(if: LivePopoverEnvironment.enabled))
    func tabGoesThroughAPinnedBand() async throws {
        try inRunLoopTurn {
            let fixture = LivePopoverFixture.auto(["redlight.adaptiveMin": 0.6, "redlight.adaptiveMax": 0.6])
            defer { fixture.retire() }
            let live = try LivePopover(fixture.view())
            defer { live.close() }
            let loop = live.keyViewLoop()
            let stops = try tabRound(live)
            note("focus pinned: Tab stops \(loop), a round visited \(stops)")
            try #require(loop.count >= 7)
            #expect(Set(stops.map { "\($0)" }) == Set(loop.map { "\($0)" }), "Tab did not visit every stop")
            #expect(stops.count == loop.count, "Tab visited a stop twice in one round")
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
