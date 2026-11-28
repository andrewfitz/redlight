import AppKit
import SwiftUI
import Testing
@testable import Redlight

/// The popover as an assistive app reads it: every element SwiftUI exposes, in order, with
/// what VoiceOver would say for it. SwiftUI builds these elements only once a client has
/// asked for them, so `enable()` comes first and the tree is read a turn later.
@MainActor
struct AccessibilityTree {
    struct Node {
        let object: NSObject
        let role: String
        let subrole: String
        /// What VoiceOver says the element is: "toggle button", "tab group".
        let roleDescription: String
        /// The label, or for plain text the words themselves.
        let name: String
        /// The spoken value: "Auto", "Collapsed", "1".
        let value: String
        let help: String
        let isSelected: Bool
        let isEnabled: Bool
    }

    let nodes: [Node]

    /// What VoiceOver does to an app when it starts. It stays on for the test process.
    /// The attribute has no typed setter, so it goes through the informal one, by selector
    /// because Swift marks that deprecated.
    static func enable() {
        _ = NSApplication.shared.perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"),
            with: NSNumber(value: true), with: "AXEnhancedUserInterface" as NSString)
    }

    /// The elements are not `NSAccessibilityProtocol` to the compiler, so ask by selector.
    private static func object(_ node: NSObject, _ name: String) -> Any? {
        let selector = Selector(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }

    private static func flag(_ node: NSObject, _ name: String) -> Bool {
        let selector = Selector(name)
        guard node.responds(to: selector) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: selector), to: Function.self)(node, selector)
    }

    init(_ root: NSView) {
        var nodes: [Node] = []
        func visit(_ element: Any) {
            guard let object = element as? NSObject else { return }
            let role = Self.object(object, "accessibilityRole") as? String ?? ""
            let label = Self.object(object, "accessibilityLabel") as? String ?? ""
            let raw = Self.object(object, "accessibilityValue")
            let text = (raw as? String) ?? (raw as? NSNumber)?.stringValue ?? ""
            let described = Self.object(object, "accessibilityValueDescription") as? String ?? ""
            let isText = role == NSAccessibility.Role.staticText.rawValue
            nodes.append(Node(
                object: object, role: role,
                subrole: Self.object(object, "accessibilitySubrole") as? String ?? "",
                roleDescription: Self.object(object, "accessibilityRoleDescription") as? String ?? "",
                name: label.isEmpty && isText ? text : label,
                value: described.isEmpty ? text : described,
                help: Self.object(object, "accessibilityHelp") as? String ?? "",
                isSelected: Self.flag(object, "isAccessibilitySelected"),
                isEnabled: Self.flag(object, "isAccessibilityEnabled")))
            for child in Self.object(object, "accessibilityChildren") as? [Any] ?? [] { visit(child) }
        }
        visit(root)
        self.nodes = nodes
    }

    func named(_ name: String) -> [Node] { nodes.filter { $0.name == name } }
    func first(_ name: String) -> Node? { nodes.first { $0.name == name } }
    func index(_ name: String) -> Int? { nodes.firstIndex { $0.name == name } }
    var names: [String] { nodes.map(\.name) }

    /// Activates the element as VoiceOver's "press" does.
    @discardableResult
    static func press(_ node: Node) -> Bool { flag(node.object, "accessibilityPerformPress") }

    /// Steps a slider up or down, as VoiceOver's increment and decrement do.
    @discardableResult
    static func increment(_ node: Node) -> Bool { flag(node.object, "accessibilityPerformIncrement") }
    @discardableResult
    static func decrement(_ node: Node) -> Bool { flag(node.object, "accessibilityPerformDecrement") }
}

@MainActor @Suite struct MenuBarViewTests {
    @Test func hostedPopoverRendersAndScrollsWhenAdaptiveExpands() async throws {
        _ = NSApplication.shared
        let defaultsRegistry = TestDefaultsRegistry()
        let defaults = defaultsRegistry.makeDefaults()
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [1, 2] },
            getDisplayName: { "Display \($0)" }, getDisplayPersistenceKey: { String($0) },
            getMainDisplayID: { 1 }, defaults: defaults, location: location,
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0)
        let view = MenuBarView(manager: manager, defaults: defaults)
        let ordinary = StatusItemController.makePopover(content: view)
        let originalSize = ordinary.contentSize
        #expect(originalSize.width == 300)
        #expect(originalSize.height > 200)

        // Auto adds the sun arc and the flags under the sliders: more than this.
        let maximumHeight = originalSize.height + 20
        let expanded = StatusItemController.makePopover(
            maximumHeight: maximumHeight, content: view.environment(\.emberAnimationsEnabled, false))
        let controller = try #require(expanded.contentViewController)
        let scroll = try #require(controller.view as? NSScrollView)
        let document = try #require(scroll.documentView)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: originalSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        document.layoutSubtreeIfNeeded()
        #expect(!scroll.hasVerticalScroller)

        manager.adaptiveEnabled = true
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            document.layoutSubtreeIfNeeded()
        }
        #expect(expanded.contentSize == CGSize(width: 300, height: maximumHeight))
        #expect(scroll.hasVerticalScroller)
        #expect(document.frame.height > maximumHeight)
        let bitmap = try #require(document.bitmapImageRepForCachingDisplay(in: document.bounds))
        document.cacheDisplay(in: document.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 300)
        #expect(bitmap.pixelsHigh > Int(maximumHeight))
        let bytes = try #require(bitmap.bitmapData)
        #expect(UnsafeBufferPointer(start: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            .contains { $0 != 0 })
    }

    private func makeManager(defaults: UserDefaults, location: FakeLocationProvider,
                             displays: [CGDirectDisplayID] = [1, 2],
                             now: @escaping () -> Date = { Date() },
                             calendar: Calendar = .autoupdatingCurrent) -> DisplayManager {
        DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { displays },
            getDisplayName: { "Display \($0)" }, getDisplayPersistenceKey: { String($0) },
            getMainDisplayID: { 1 }, defaults: defaults, location: location,
            now: now, calendar: calendar,
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0)
    }

    /// A real handler over services that do nothing, so a pressed control reaches the manager.
    private func makeHandler(_ manager: DisplayManager) -> CommandHandler {
        CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "Test" }))
    }

    private func settle(_ document: NSView, turns: Int = 4) async {
        for _ in 0..<turns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            document.layoutSubtreeIfNeeded()
        }
    }

    /// The hosted popover's elements, after SwiftUI has had a turn to build them.
    private func accessibility(of document: NSView) async -> AccessibilityTree {
        AccessibilityTree.enable()
        _ = document.accessibilityChildren()
        await settle(document)
        return AccessibilityTree(document)
    }

    /// Presses the element with this name, as VoiceOver would, and reads the tree again.
    private func press(_ name: String, in document: NSView) async throws -> AccessibilityTree {
        let node = try #require(await accessibility(of: document).first(name), "no element named \(name)")
        #expect(AccessibilityTree.press(node), "\(name) did not take the press")
        return await accessibility(of: document)
    }

    /// 18:40 in Chicago on the March equinox, as the snapshot states use.
    private static let evening = Date(timeIntervalSince1970: 1_774_050_000)
    private static var chicagoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private func textFields(in document: NSView) -> (latitude: String?, longitude: String?) {
        let fields = allViews(document).compactMap { $0 as? NSTextField }
        return (fields.first { $0.placeholderString == "Latitude" }?.stringValue,
                fields.first { $0.placeholderString == "Longitude" }?.stringValue)
    }

    /// Hosts the popover's content offscreen, as the existing render test does.
    private func host<Content: View>(_ view: Content) async throws -> (popover: NSPopover, document: NSView, window: NSWindow) {
        _ = NSApplication.shared
        // Offscreen nothing carries an animation to its end; see `OffscreenPopover`.
        let popover = StatusItemController.makePopover(content: view.environment(\.emberAnimationsEnabled, false))
        let controller = try #require(popover.contentViewController)
        let scroll = try #require(controller.view as? NSScrollView)
        let document = try #require(scroll.documentView)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: popover.contentSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            document.layoutSubtreeIfNeeded()
        }
        return (popover, document, window)
    }

    private func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { allViews($0) }
    }

    @Test func everyPageRendersAtThePopoverWidthInBothAppearances() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location)
        for page in [MenuBarPage.controls, .settings, .about] {
            var brightness: [ColorScheme: CGFloat] = [:]
            for scheme in [ColorScheme.dark, .light] {
                let view = MenuBarView(manager: manager, defaults: defaults, initialPage: page)
                    .environment(\.colorScheme, scheme)
                let hosted = try await host(view)
                defer { hosted.window.close() }
                #expect(hosted.popover.contentSize.width == 300)
                #expect(hosted.popover.contentSize.height > 100)
                let bitmap = try #require(hosted.document.bitmapImageRepForCachingDisplay(in: hosted.document.bounds))
                hosted.document.cacheDisplay(in: hosted.document.bounds, to: bitmap)
                let corner = try #require(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
                #expect(corner.alphaComponent == 1)
                brightness[scheme] = (corner.redComponent + corner.greenComponent + corner.blueComponent) / 3
            }
            // The panel paints its own background, and takes its scheme from the environment
            // rather than the system: dark is the dark Ember surface, light the pale one.
            // The bitmap is in the display's colour space, so compare the two, not exact values.
            let dark = try #require(brightness[.dark]), light = try #require(brightness[.light])
            #expect(dark < 0.3)
            #expect(light > 0.8)
        }
    }

    @Test func settingsPageShowsTheSavedCoordinateInItsFields() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let location = FakeLocationProvider()
        location.setManualCoordinate((41.88, -87.63))
        let manager = makeManager(defaults: defaults, location: location)
        manager.adaptiveEnabled = true
        #expect(manager.manualLocation != nil)
        let view = MenuBarView(manager: manager, defaults: defaults, initialPage: .settings)
        let hosted = try await host(view)
        defer { hosted.window.close() }
        let fields = allViews(hosted.document).compactMap { $0 as? NSTextField }
        let latitude = try #require(fields.first { $0.placeholderString == "Latitude" })
        let longitude = try #require(fields.first { $0.placeholderString == "Longitude" })
        #expect(latitude.stringValue == "41.88")
        #expect(longitude.stringValue == "-87.63")
    }

    @Test func modeControlFollowsTheModelAndTheControlsPageHasNoCoordinateFields() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let location = FakeLocationProvider()
        location.setManualCoordinate((41.88, -87.63))
        let manager = makeManager(defaults: defaults, location: location)
        let view = MenuBarView(manager: manager, defaults: defaults)
        let hosted = try await host(view)
        defer { hosted.window.close() }
        let manualHeight = hosted.document.frame.height
        // Flipped from outside the view, as the CLI does while the popover is open.
        manager.adaptiveEnabled = true
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            hosted.document.layoutSubtreeIfNeeded()
        }
        #expect(hosted.document.frame.height > manualHeight + 20)
        #expect(hosted.popover.contentSize.height == hosted.document.frame.height)
        let fields = allViews(hosted.document).compactMap { $0 as? NSTextField }
        #expect(!fields.contains { $0.placeholderString == "Latitude" })
    }

    @Test func popoverSurfaceInstallsOnceBeneathTheContent() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        let view = MenuBarView(manager: manager, defaults: defaults)
        // No window yet: nothing to install into, and no crash.
        #expect(!StatusItemController.installSurface(in: StatusItemController.makePopover(content: view)))

        let hosted = try await host(view)
        defer { hosted.window.close() }
        let contentView = try #require(hosted.window.contentView)
        let frameView = try #require(contentView.superview)
        #expect(StatusItemController.installSurface(in: hosted.popover))
        #expect(StatusItemController.installSurface(in: hosted.popover))
        let surfaces = frameView.subviews.filter { $0 is PopoverSurfaceView }
        #expect(surfaces.count == 1)
        let surface = try #require(surfaces.first)
        let surfaceIndex = try #require(frameView.subviews.firstIndex(of: surface))
        let contentIndex = try #require(frameView.subviews.firstIndex(of: contentView))
        #expect(surfaceIndex < contentIndex)
        #expect(surface.frame == frameView.bounds)
        #expect(surface.hitTest(CGPoint(x: 10, y: 10)) == nil)
        for (name, scheme) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            var resolved: NSColor?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                resolved = PopoverSurfaceView.color.usingColorSpace(.sRGB)
            }
            let color = try #require(resolved)
            #expect(abs(color.redComponent * 255 - EmberPalette.for(scheme).background.r) < 1)

            // The colour is the layer's own background, with nothing drawn, and it is the
            // appearance's colour once the view has been displayed in that appearance.
            #expect(surface.wantsUpdateLayer)
            surface.appearance = NSAppearance(named: name)
            surface.displayIfNeeded()
            let background = try #require(surface.layer?.backgroundColor)
            let shown = try #require(NSColor(cgColor: background)?.usingColorSpace(.sRGB))
            let wanted = EmberPalette.for(scheme).background
            #expect(abs(shown.redComponent * 255 - wanted.r) < 1)
            #expect(abs(shown.greenComponent * 255 - wanted.g) < 1)
            #expect(abs(shown.blueComponent * 255 - wanted.b) < 1)
            #expect(shown.alphaComponent == 1)
            #expect(surface.layer?.contents == nil)
        }
    }

    /// "Built-in Retina Display" is the name of every MacBook's own screen, and its row shows
    /// it in full. A name too long for the row still ends short of the Invert chip.
    @Test func theBuiltInDisplaysNameIsShownInFull() async throws {
        let builtIn = "Built-in Retina Display"
        let long = "LG UltraFine 5K Thunderbolt Display in Conference Room 4 West"
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [1, 2] },
            getDisplayName: { $0 == 1 ? builtIn : long }, getDisplayPersistenceKey: { String($0) },
            getMainDisplayID: { 1 }, defaults: defaults, location: FakeLocationProvider(),
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0)
        let view = MenuBarView(manager: manager, defaults: defaults)
            .environment(\.colorScheme, .light)
            .preferredColorScheme(.light)
        let popover = try OffscreenPopover(content: AnyView(view), appearance: NSAppearance(named: .aqua))
        defer { popover.close() }
        await popover.settle()
        #expect(popover.popover.contentSize.width == EmberMetrics.width)
        let tree = await accessibility(of: popover.document)
        let bitmap = try popover.makeBitmap()
        popover.draw(into: bitmap)
        let raster = try Raster(bitmap)
        let scale = CGFloat(raster.width) / popover.document.bounds.width

        /// The width the name takes when nothing holds it back, in the row's own type.
        func idealWidth(_ name: String) -> CGFloat {
            NSHostingView(rootView: Text(name).font(.ember(13)).fontDesign(.rounded).lineLimit(1).fixedSize())
                .fittingSize.width
        }
        func channels(x: Int, y: Int) -> [Int] {
            let index = (y * raster.width + x) * 4
            return (0..<3).map { Int(raster.pixels[index + $0]) }
        }

        for (name, fits) in [(builtIn, true), (long, false)] {
            // The name's column: from the glyph to the Invert chip, where the row really put it.
            let chip = try #require(tree.first("Invert colors on \(name)"), "no Invert chip for \(name)")
            let onScreen = try #require((chip.object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
            let chipFrame = popover.document.convert(popover.window.convertFromScreen(onScreen), from: nil)
            let start = EmberMetrics.padding + EmberMetrics.cardInset
                + DisplayRowMetrics.glyphWidth + DisplayRowMetrics.spacing
            let end = chipFrame.minX - DisplayRowMetrics.spacing
            let needed = idealWidth(name)

            // Where the drawn name ends: the last column of the row, short of the chip, with
            // anything on it but the card.
            let card = channels(x: Int((EmberMetrics.padding + 3) * scale), y: Int(chipFrame.midY * scale))
            var inkEnd: CGFloat = 0
            for x in Int(start * scale)..<Int((chipFrame.minX - 1) * scale) {
                for y in Int((chipFrame.midY - 8) * scale)...Int((chipFrame.midY + 8) * scale) {
                    let pixel = channels(x: x, y: y)
                    if zip(pixel, card).map({ abs($0 - $1) }).reduce(0, +) > 90 { inkEnd = CGFloat(x + 1) / scale }
                }
            }
            if fits {
                #expect(needed + 1.5 <= end - start,
                        "\(name) needs \(needed) pt and its column is \(end - start) pt wide")
                // The whole name is there: its ink ends where the full text ends.
                #expect(abs(inkEnd - (start + needed)) <= 1.5,
                        "\(name) is drawn to \(inkEnd) pt, and in full it would end at \(start + needed) pt")
            } else {
                #expect(needed > end - start)
                // Cut short with an ellipsis that ends inside the column.
                #expect(inkEnd <= end + 0.5 && inkEnd > end - 8,
                        "\(name) is drawn to \(inkEnd) pt, and its column ends at \(end) pt")
            }
        }
    }

    /// A popover that has just opened has no control focused. Left to itself the window
    /// starts on the first Tab stop, which is the colour temp slider: an arrow
    /// key would move it. The root view takes the keyboard instead, closes on Escape, and
    /// lets every other key end there without the alert sound.
    @Test func popoverOpensWithTheKeyboardOnItsRootView() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location, now: { Self.evening })
        manager.adaptiveEnabled = true
        let view = MenuBarView(manager: manager, defaults: defaults)
        // No window yet: nothing to focus, and no crash.
        #expect(!StatusItemController.restFocus(in: StatusItemController.makePopover(content: view)))

        let hosted = try await host(view)
        defer { hosted.window.close() }
        let root = try #require(hosted.popover.contentViewController?.view as? PopoverScrollView)
        // What the window would choose: a slider handle.
        let firstStop = try #require(allViews(hosted.document).first { $0.canBecomeKeyView },
                                     "the popover has no Tab stop")
        #expect(hosted.window.makeFirstResponder(firstStop))
        #expect(hosted.window.firstResponder === firstStop)

        StatusItemController.prepareShown(hosted.popover)
        #expect(hosted.window.firstResponder === root)
        // It is no Tab stop itself, and Tab still starts at the first control.
        #expect(!root.canBecomeKeyView)
        #expect(!allViews(hosted.document).filter { $0.canBecomeKeyView }.isEmpty)

        var cancels = 0
        root.onCancel = { cancels += 1 }
        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        root.keyDown(with: try key("\u{1b}", 53))
        #expect(cancels == 1)
        root.cancelOperation(nil)
        #expect(cancels == 2)
        // Space, an arrow and a letter do nothing.
        let before = (manager.intensity, manager.adaptiveMin, manager.adaptiveMax, manager.isOn)
        for (characters, code) in [(" ", UInt16(49)), ("\u{F702}", 123), ("a", 0)] {
            root.keyDown(with: try key(characters, code))
        }
        #expect(cancels == 2)
        #expect(before == (manager.intensity, manager.adaptiveMin, manager.adaptiveMax, manager.isOn))
    }

    /// Each popover slider is one element named by its header, with its value in percent,
    /// that VoiceOver can step. In Auto a step past a limit takes the limit along.
    @Test func eachSliderIsOneAccessibleSliderThatSteps() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        for (key, value) in ["redlight.adaptiveEnabled": true, "redlight.adaptiveMin": 0.2,
                             "redlight.adaptiveMax": 0.8] as [String: Any] {
            defaults.set(value, forKey: key)
        }
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location, now: { Self.evening })
        let hosted = try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager)))
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)
        for name in ["Color temp", "White point"] {
            let nodes = tree.named(name)
            #expect(nodes.count == 1, "\(name) is named \(nodes.count) times: \(nodes.map(\.role))")
            #expect(nodes.first?.role == NSAccessibility.Role.slider.rawValue)
        }
        let color = try #require(tree.first("Color temp"))
        #expect(color.value == SliderCore.spokenPercent(manager.intensity))

        let before = manager.intensity
        #expect(AccessibilityTree.increment(color))
        tree = await accessibility(of: hosted.document)
        #expect(manager.intensity > before, "increment did not raise the colour temp")
        manager.setIntensityPushingBand(0.8)
        for _ in 0..<40 {
            guard manager.intensity < 1, let node = tree.first("Color temp") else { break }
            AccessibilityTree.increment(node)
            tree = await accessibility(of: hosted.document)
        }
        #expect(manager.intensity == 1, "stepping up stopped at \(manager.intensity)")
        #expect(manager.adaptiveMax == 1, "the upper limit did not come along")
        #expect(AccessibilityTree.decrement(try #require(tree.first("Color temp"))))
        #expect(manager.intensity < 1)

        // The white point is spoken in percent of its own scale, as a status reports it:
        // its floor, 0.25 on the displays, is 0 percent.
        let handler = makeHandler(manager)
        for output in [0.25, 0.45, 0.625, 1.0] {
            manager.setWhitepointPushingBand(output)
            tree = await accessibility(of: hosted.document)
            let status = handler.snapshot().whitepoint.set
            #expect(tree.first("White point")?.value == "\(status) percent", "at \(output)")
        }
        manager.setWhitepointPushingBand(0.25)
        tree = await accessibility(of: hosted.document)
        #expect(tree.first("White point")?.value == "0 percent")
    }

    /// In Auto each slider also has its minimum and maximum, each a slider of its own that
    /// VoiceOver can step; a pinned band says it is fixed. Manual has neither, and Settings
    /// no range card.
    @Test func autoSlidersHaveTheirLimitsAsSlidersOfTheirOwn() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        for (key, value) in ["redlight.adaptiveEnabled": true, "redlight.adaptiveMin": 0.2,
                             "redlight.adaptiveMax": 0.8, "redlight.adaptiveWpMin": 1.0,
                             "redlight.adaptiveWpMax": 1.0] as [String: Any] {
            defaults.set(value, forKey: key)
        }
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location, now: { Self.evening })
        let hosted = try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager)))
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)
        let names = ["Color temp", "Color temp minimum", "Color temp maximum",
                     "White point", "White point minimum", "White point maximum"]
        for name in names {
            let nodes = tree.named(name)
            #expect(nodes.count == 1, "\(name) is named \(nodes.count) times")
            #expect(nodes.first?.role == NSAccessibility.Role.slider.rawValue)
        }
        let order = names.compactMap { tree.index($0) }
        #expect(order == order.sorted(), "the elements are not value, minimum, maximum in order")
        #expect(tree.first("Color temp minimum")?.value == "20 percent")
        #expect(tree.first("Color temp maximum")?.value == "80 percent")
        #expect(tree.first("White point minimum")?.value == "Fixed at 100 percent")

        #expect(AccessibilityTree.increment(try #require(tree.first("Color temp minimum"))))
        tree = await accessibility(of: hosted.document)
        #expect(manager.adaptiveMin > 0.2, "increment did not raise the minimum")
        #expect(AccessibilityTree.decrement(try #require(tree.first("Color temp maximum"))))
        tree = await accessibility(of: hosted.document)
        #expect(manager.adaptiveMax < 0.8, "decrement did not lower the maximum")
        #expect(manager.intensity <= manager.adaptiveMax + 1e-12, "the value is outside the band")

        manager.adaptiveEnabled = false
        tree = await accessibility(of: hosted.document)
        #expect(!tree.names.contains { $0.hasSuffix("minimum") || $0.hasSuffix("maximum") })

        let settings = try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                                                  initialState: MenuBarInitialState(updateAvailable: false),
                                                  initialPage: .settings))
        defer { settings.window.close() }
        let settingsTree = await accessibility(of: settings.document)
        #expect(settingsTree.index("Auto range") == nil)
        #expect(!settingsTree.names.contains { $0.hasSuffix("minimum") })
    }
    @Test func sunArcAccessibilityReportsCurrentElevationWithoutPhaseJargon() {
        let summary = SunArcView.accessibilitySummary(currentElevation: 0.8)
        #expect(summary.contains("Solar elevation +1°"))
        #expect(!summary.lowercased().contains("marker"))
        #expect(!summary.lowercased().contains("civil"))
        #expect(!summary.lowercased().contains("nautical"))
        #expect(!summary.lowercased().contains("astronomical"))
    }

    @Test func inlinePauseLengthsAreLabelledAndDispatchTheirLength() {
        #expect(PauseLengthRow.options.map(\.title) == ["30 m", "1 h", "2 h", "Until sunrise"])
        #expect(PauseLengthRow.options.map(\.accessibility) == [
            "Pause for 30 minutes", "Pause for 1 hour", "Pause for 2 hours", "Pause until sunrise",
        ])
        #expect(PauseLengthRow.options.map(\.length) == [
            .minutes(30), .minutes(60), .minutes(120), .untilSunrise,
        ])
    }

    @Test func bedtimeRowRoundTripsThroughItsTimeField() {
        #expect(BedtimeRow.suggested == Bedtime(hour: 22, minute: 30))
        for zone in ["UTC", "America/New_York", "Australia/Lord_Howe", "Asia/Kathmandu"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            for minute in stride(from: 0, to: 1440, by: 7) {
                let bedtime = Bedtime(minuteOfDay: minute)!
                #expect(BedtimeRow.bedtime(from: BedtimeRow.date(for: bedtime, calendar: calendar),
                                           calendar: calendar) == bedtime)
            }
        }
    }

    // MARK: - What VoiceOver is told

    @Test func theNextSolarEventIsSpokenInWholeWords() {
        #expect(SunArcView.spokenDuration("Sunset in 1 h 12 m") == "Sunset in 1 hour 12 minutes")
        #expect(SunArcView.spokenDuration("Sunrise in 2 h") == "Sunrise in 2 hours")
        #expect(SunArcView.spokenDuration("First light in 1 h 1 m") == "First light in 1 hour 1 minute")
        #expect(SunArcView.spokenDuration("Sunset in 45 m") == "Sunset in 45 minutes")
        // Nothing to expand: the text is spoken as it is shown.
        for text in ["Sunset in under a minute", "Following the sun", "Locating…", "Auto needs your location"] {
            #expect(SunArcView.spokenDuration(text) == text)
        }
        // Every form the manager can produce, so the two cannot drift apart.
        for minutes in [0, 1, 59, 60, 61, 72, 120, 1439] {
            let shown = DisplayManager.describeNextSolarEvent("sunset", in: TimeInterval(minutes * 60))
            let spoken = SunArcView.spokenDuration(shown)
            #expect(!spoken.hasSuffix(" h") && !spoken.hasSuffix(" m") && !spoken.contains(" h "))
            #expect(spoken.hasPrefix("Sunset in "))
        }
    }

    @Test func autoPageNamesEachControlOnceAndSaysTheNextEventInWords() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(22 * 60 + 30, forKey: "redlight.adaptiveBedtime")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        let tree = await accessibility(of: hosted.document)

        // No headline is drawn: the arc shows what comes next, and says it in words, once.
        let shown = try #require(manager.nextSolarEventText)
        #expect(shown.contains(" h ") || shown.hasSuffix(" m"))
        let spoken = SunArcView.spokenDuration(shown)
        #expect(tree.names.filter { $0.hasPrefix("\(spoken). Solar elevation ") }.count == 1)
        #expect(tree.named(shown).isEmpty && !tree.names.contains { $0.hasPrefix("\(shown).") || $0.hasPrefix("\(shown) ·") })
        #expect(!tree.names.contains { $0.hasPrefix("Following the sun") || $0.hasPrefix("Deepest red by") })

        // The mode is one named picker that says which mode is chosen. Its name is not also
        // read as text beside it.
        #expect(tree.named("Mode").count == 1)
        let mode = try #require(tree.first("Mode"))
        #expect(mode.role == NSAccessibility.Role.tabGroup.rawValue)
        #expect(mode.value == "Auto")
        #expect(tree.first("Auto")?.isSelected == true)
        #expect(tree.first("Manual")?.isSelected == false)
        // The explanation is help on the options. On the picker it would be read in place
        // of what the picker is.
        #expect(!mode.roleDescription.lowercased().contains("solar"))
        #expect(mode.help.isEmpty)
        for option in ["Auto", "Manual"] {
            #expect(tree.first(option)?.help.hasPrefix("Auto follows real solar elevation") == true)
            #expect(tree.first(option)?.roleDescription.lowercased().contains("solar") == false)
        }
        // "Deepest by" is on the Settings page.
        #expect(tree.named(BedtimeRow.title).isEmpty)
    }

    @Test func clearByIsTheSecondRowOfAutoAndSetsTheWakeTime() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                               initialPage: .settings)
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)

        let title = BedtimeRow.Kind.wake.title
        let clear = tree.named(title)
        #expect(clear.count == 1)
        #expect(clear.first?.role == NSAccessibility.Role.checkBox.rawValue)
        #expect(clear.first?.value == "0")
        #expect(clear.first?.help == BedtimeRow.Kind.wake.explanation)
        let deepestIndex = try #require(tree.index(BedtimeRow.title))
        let clearIndex = try #require(tree.index(title))
        let locationIndex = try #require(tree.index("Location"))
        #expect(deepestIndex < clearIndex && clearIndex < locationIndex)
        #expect(tree.named("Wake time").count == 1)                    // its own time field

        // The switch applies the field's time, 07:00 until one is typed, and remembers it.
        tree = try await press(title, in: hosted.document)
        #expect(manager.wakeTime == Bedtime(hour: 7, minute: 0))
        #expect(manager.bedtime == nil)
        #expect(tree.first(title)?.value == "1")
        tree = try await press(title, in: hosted.document)
        #expect(manager.wakeTime == nil)
        #expect(BedtimeDraft(defaults: defaults, kind: .wake).bedtime == Bedtime(hour: 7, minute: 0))
        #expect(BedtimeDraft.wakeKey == "redlight.adaptiveWakeTimeDraft")
    }

    @Test func learnMyAdjustmentsIsTheThirdRowOfAutoAndSaysWhatItLearned() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        // Switched off before, to be switched on here.
        defaults.set(false, forKey: "redlight.learningEnabled")
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(true, forKey: "redlight.display.1.enabled")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                               initialPage: .settings)
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)

        let title = LearningRows.title
        #expect(tree.named(title).count == 1)
        #expect(tree.first(title)?.role == NSAccessibility.Role.checkBox.rawValue)
        #expect(tree.first(title)?.value == "0")
        let clearIndex = try #require(tree.index(BedtimeRow.Kind.wake.title))
        let learnIndex = try #require(tree.index(title))
        let locationIndex = try #require(tree.index("Location"))
        #expect(clearIndex < learnIndex && learnIndex < locationIndex)
        // Off, it says nothing and offers nothing to reset.
        #expect(!tree.names.contains(LearningRows.nothingYet))
        #expect(tree.named(LearningRows.resetTitle).isEmpty)

        tree = try await press(title, in: hosted.document)
        #expect(manager.learningEnabled)
        #expect(tree.first(title)?.value == "1")
        #expect(tree.names.contains(LearningRows.nothingYet))
        #expect(tree.named(LearningRows.resetTitle).isEmpty)

        // A nudge is something learned: the hint goes, the row says what, and the reset appears.
        manager.setIntensityPushingBand(max(0, manager.intensity - 0.2))
        #expect(manager.learnedAnchorCount > 0)
        let said = try #require(manager.learningSummary.first)
        #expect(said.hasPrefix("Color temp is about 20% redder "), "\(said)")
        await settle(hosted.document)
        tree = await accessibility(of: hosted.document)
        #expect(!tree.names.contains(LearningRows.nothingYet))
        // The learned day is drawn; VoiceOver reads it in words.
        let chart = try #require(tree.first("Color temp through the day"))
        #expect(chart.value == said)
        #expect(tree.named(LearningRows.resetTitle).count == 1)
        // Reset asks first. Cancel leaves everything as it was.
        tree = try await press(LearningRows.resetTitle, in: hosted.document)
        #expect(manager.learnedAnchorCount > 0)
        #expect(tree.names.contains(LearningRows.confirmText))
        #expect(tree.named(LearningRows.resetTitle).isEmpty)
        tree = try await press(LearningRows.cancelTitle, in: hosted.document)
        #expect(manager.learnedAnchorCount > 0 && manager.learningBackupCount == 0)
        #expect(!tree.names.contains(LearningRows.confirmText))
        // Confirmed, both sliders are reset and what they had is kept for a restore.
        tree = try await press(LearningRows.resetTitle, in: hosted.document)
        tree = try await press(LearningRows.confirmTitle, in: hosted.document)
        #expect(manager.learnedAnchorCount == 0 && manager.learningEnabled)
        #expect(manager.learningBackupCount == 1)
        #expect(tree.names.contains(LearningRows.nothingYet))

        tree = try await press(title, in: hosted.document)
        #expect(!manager.learningEnabled)
    }

    @Test func keepNightShiftOffIsShownOnlyWhereThereIsANightShift() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        // The tests never connect the system's Night Shift, so the guard has no switch.
        #expect(!NightShiftGuard.shared.isAvailable)
        for (stand, value) in [(Bool?.none, String?.none), (true, "1"), (false, "0")] {
            let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                                   initialState: MenuBarInitialState(keepsNightShiftOff: stand),
                                   initialPage: .settings)
            let hosted = try await host(view)
            defer { hosted.window.close() }
            let tree = await accessibility(of: hosted.document)
            #expect(tree.named("Keep Night Shift off").count == (stand == nil ? 0 : 1))
            #expect(tree.first("Keep Night Shift off")?.value == value)
        }
    }

    @Test func deepestByIsAtTheTopOfSettingsAndNamedOnce() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(22 * 60 + 30, forKey: "redlight.adaptiveBedtime")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                               initialPage: .settings)
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)

        // "Deepest by" is said once, by the switch, which also carries the explanation.
        let deepest = tree.named(BedtimeRow.title)
        #expect(deepest.count == 1)
        #expect(deepest.first?.role == NSAccessibility.Role.checkBox.rawValue)
        #expect(deepest.first?.value == "1")
        #expect(deepest.first?.help == BedtimeRow.explanation)
        #expect(tree.named("Reach the deepest setting by a bedtime").isEmpty)
        // Above the location, which was the top of the page before.
        let toggleIndex = try #require(tree.index(BedtimeRow.title))
        let locationIndex = try #require(tree.index("Location"))
        #expect(toggleIndex < locationIndex)

        // A changed time puts Set after the field it applies and before the switch.
        #expect(!tree.names.contains { $0.hasPrefix("Set bedtime") })
        // Typed into the field: the popover no longer watches the defaults for its draft.
        try enterBedtime(Bedtime(hour: 23, minute: 0)!, in: hosted.document)
        tree = await accessibility(of: hosted.document)
        let field = try #require(tree.index("Bedtime"))
        let set = try #require(tree.index("Set bedtime to 23:00"))
        let toggle = try #require(tree.index(BedtimeRow.title))
        #expect(field < set && set < toggle)
        tree = try await press("Set bedtime to 23:00", in: hosted.document)
        #expect(manager.bedtime == Bedtime(hour: 23, minute: 0))
        #expect(!tree.names.contains { $0.hasPrefix("Set bedtime") })
    }

    /// Settings is reached from Manual too, where "Deepest by" was never shown before. The
    /// bedtime is set and kept there; it only takes effect in Auto.
    @Test func deepestByCanBeSetInManualAndWaitsForAuto() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        manager.applyPreset(3)
        #expect(!manager.adaptiveEnabled && manager.bedtime == nil)
        let before = manager.intensity
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                               initialPage: .settings)
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = try await press(BedtimeRow.title, in: hosted.document)
        #expect(manager.bedtime == BedtimeRow.suggested)
        #expect(tree.first(BedtimeRow.title)?.value == "1")
        #expect(!tree.names.contains { $0.hasPrefix("Command failed") })
        // Manual holds its setting: nothing on screen changes.
        #expect(manager.intensity == before && manager.activePresetIndex == 3)
        try enterBedtime(Bedtime(hour: 23, minute: 15)!, in: hosted.document)
        tree = try await press("Set bedtime to 23:15", in: hosted.document)
        #expect(manager.bedtime == Bedtime(hour: 23, minute: 15))
        #expect(!tree.names.contains { $0.hasPrefix("Command failed") })
        // Auto picks it up.
        manager.adaptiveEnabled = true
        #expect(manager.bedtime == Bedtime(hour: 23, minute: 15))
        #expect(manager.effectiveBedtime == Bedtime(hour: 23, minute: 15))
    }

    /// The time the hosted popover's bedtime field shows, as minutes into the day.
    private func bedtimeFieldMinute(in document: NSView) throws -> Int {
        let picker = try #require(allViews(document).compactMap { $0 as? NSDatePicker }.first)
        return BedtimeRow.bedtime(from: picker.dateValue).minuteOfDay
    }

    @Test func theBedtimeDraftOutlastsThePopoverAndFollowsTheBedtime() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        #expect(manager.bedtime == nil)
        let key = BedtimeDraft.key
        #expect(key == "redlight.adaptiveBedtimeDraft")
        func open() async throws -> (popover: NSPopover, document: NSView, window: NSWindow) {
            try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                                       initialPage: .settings))
        }

        // Nothing saved: the suggested time. A typed time is saved at once, with no bedtime set.
        var hosted = try await open()
        #expect(try bedtimeFieldMinute(in: hosted.document) == BedtimeRow.suggested.minuteOfDay)
        #expect(defaults.object(forKey: key) == nil)
        try enterBedtime(Bedtime(hour: 21, minute: 15)!, in: hosted.document)
        await settle(hosted.document)
        #expect(defaults.integer(forKey: key) == 21 * 60 + 15)
        #expect(manager.bedtime == nil)

        // It is still there after the controls and back, and in a popover opened afresh.
        _ = try await press("Back", in: hosted.document)
        _ = try await press("Settings", in: hosted.document)
        #expect(try bedtimeFieldMinute(in: hosted.document) == 21 * 60 + 15)
        hosted.window.close()
        hosted = try await open()
        #expect(try bedtimeFieldMinute(in: hosted.document) == 21 * 60 + 15)

        // The switch applies the draft. A bedtime set elsewhere (the CLI) moves the field
        // and what is saved, and switching off keeps the time for next time.
        var tree = try await press(BedtimeRow.title, in: hosted.document)
        #expect(manager.bedtime == Bedtime(hour: 21, minute: 15))
        manager.setBedtime(Bedtime(hour: 23, minute: 40))
        await settle(hosted.document)
        #expect(try bedtimeFieldMinute(in: hosted.document) == 23 * 60 + 40)
        #expect(defaults.integer(forKey: key) == 23 * 60 + 40)
        tree = await accessibility(of: hosted.document)
        #expect(!tree.names.contains { $0.hasPrefix("Set bedtime") })
        tree = try await press(BedtimeRow.title, in: hosted.document)
        #expect(manager.bedtime == nil)
        #expect(tree.first(BedtimeRow.title)?.value == "0")
        hosted.window.close()
        hosted = try await open()
        defer { hosted.window.close() }
        #expect(try bedtimeFieldMinute(in: hosted.document) == 23 * 60 + 40)

        // A slider tick saves the manager's state. The row does not take that for a change
        // to its draft: an unapplied time stays in the field.
        manager.setBedtime(Bedtime(hour: 22, minute: 0))
        await settle(hosted.document)
        try enterBedtime(Bedtime(hour: 22, minute: 45)!, in: hosted.document)
        manager.intensity = 0.4
        manager.whitepoint = 0.6
        await settle(hosted.document)
        #expect(try bedtimeFieldMinute(in: hosted.document) == 22 * 60 + 45)
        tree = await accessibility(of: hosted.document)
        #expect(tree.names.contains { $0.hasPrefix("Set bedtime to ") })
        #expect(manager.bedtime == Bedtime(hour: 22, minute: 0))
    }

    @Test func buttonsDrawnByAStyleCarryTheirOwnNames() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        let location = FakeLocationProvider()
        location.authorization = .denied
        let manager = makeManager(defaults: defaults, location: location)
        let view = MenuBarView(manager: manager, defaults: defaults, launchAtLogin: LaunchAtLogin(), handler: makeHandler(manager),
                               initialState: MenuBarInitialState(loginRequiresApproval: true))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)
        #expect(tree.first("Enter coordinates")?.role == NSAccessibility.Role.button.rawValue)
        #expect(tree.first("Open Location Services settings") != nil)

        // Manual: the link that opens the save targets, and the one that closes them.
        manager.adaptiveEnabled = false
        tree = await accessibility(of: hosted.document)
        #expect(tree.first("Mode")?.value == "Manual")
        #expect(tree.first("Save to a preset") != nil)
        tree = try await press("Save to a preset", in: hosted.document)
        #expect(tree.first("Cancel saving to a preset") != nil)
        #expect(tree.first("Overwrite Late preset") != nil)
        tree = try await press("Cancel saving to a preset", in: hosted.document)
        #expect(tree.first("Save to a preset") != nil)

        // Settings: one "Launch at login", the approval row, and the picker's value.
        tree = try await press("Settings", in: hosted.document)
        #expect(tree.named("Launch at login").count == 1)
        #expect(tree.first("Launch at login")?.role == NSAccessibility.Role.checkBox.rawValue)
        #expect(tree.first("Launch at login")?.value == (LaunchAtLogin().isEnabled ? "1" : "0"))
        #expect(tree.first("Approval needed, open Login Items")?.role == NSAccessibility.Role.button.rawValue)
        // The card's caption and the picker share the name; nothing else does.
        #expect(tree.named("Location for Auto").map(\.role).sorted()
            == ["AXHeading", NSAccessibility.Role.tabGroup.rawValue])
        let source = try #require(tree.first("Location for Auto", role: .tabGroup))
        #expect(source.value == "Automatic")
        #expect(source.help.isEmpty && !source.roleDescription.lowercased().contains("coordinates"))
        #expect(tree.first("Coordinates")?.help.hasPrefix("Use coordinates you enter") == true)
        // Back is named by the word on it, on both pushed pages.
        #expect(tree.first("Back")?.role == NSAccessibility.Role.button.rawValue)

        tree = try await press("About Redlight", in: hosted.document)
        let link = try #require(tree.first(AboutInfo.repositoryDisplay))
        #expect(link.role == NSAccessibility.Role.link.rawValue)
        #expect(tree.named("Back").count == 1)
        #expect(tree.first("Back")?.role == NSAccessibility.Role.button.rawValue)
        #expect(tree.first("Close About") == nil)
    }

    @Test func everySwitchIsOneToggleWithItsNameAValueAndAPress() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        manager.setEnabled(true, for: 1)
        let view = MenuBarView(manager: manager, defaults: defaults, launchAtLogin: LaunchAtLogin(), handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)

        // One element each, a toggle, named by its caller, saying whether it is on.
        func toggle(_ name: String, in tree: AccessibilityTree) throws -> AccessibilityTree.Node {
            #expect(tree.named(name).count == 1, "\(name) is read \(tree.named(name).count) times")
            let node = try #require(tree.first(name), "no element named \(name)")
            #expect(node.role == NSAccessibility.Role.checkBox.rawValue, "\(name) is a \(node.role)")
            #expect(node.isEnabled)
            return node
        }
        #expect(try toggle("Enable Redlight", in: tree).value == "1")
        #expect(try toggle("Display 1", in: tree).value == "1")
        #expect(try toggle("Display 2", in: tree).value == "0")
        // A switch is told apart from the Invert checkbox beside it.
        #expect(try toggle("Display 1", in: tree).subrole == NSAccessibility.Subrole.toggle.rawValue)
        // The chip draws "Invert"; its caller's name is the one that is read.
        #expect(try toggle("Invert colors on Display 1", in: tree).value == "0")
        #expect(try toggle("Invert colors on Display 2", in: tree).value == "0")
        #expect(tree.named("Invert").isEmpty)

        #expect(tree.first("Saturation")?.value == "0 percent")
        #expect(try toggle("Saturation filter", in: tree).value == "0")
        tree = try await press("Saturation filter", in: hosted.document)
        #expect(manager.saturationEnabled)
        #expect(try toggle("Saturation filter", in: tree).value == "1")

        // A press reaches the model, and the value follows it.
        tree = try await press("Display 2", in: hosted.document)
        #expect(manager.displays.first { $0.id == 2 }?.isEnabled == true)
        #expect(try toggle("Display 2", in: tree).value == "1")
        tree = try await press("Invert colors on Display 1", in: hosted.document)
        #expect(manager.displays.first { $0.id == 1 }?.isInverted == true)
        #expect(try toggle("Invert colors on Display 1", in: tree).value == "1")
        tree = try await press("Enable Redlight", in: hosted.document)
        #expect(!manager.isOn)
        #expect(try toggle("Enable Redlight", in: tree).value == "0")

        // The mode picker's options can be chosen.
        #expect(tree.first("Mode")?.value == "Manual")
        tree = try await press("Auto", in: hosted.document)
        #expect(manager.adaptiveEnabled)
        #expect(tree.first("Mode")?.value == "Auto")
        #expect(tree.first("Auto")?.isSelected == true)

        #expect(try toggle("Saturation filter", in: tree).value == "1")
        tree = try await press("Saturation filter", in: hosted.document)
        #expect(!manager.saturationEnabled)
        #expect(tree.first("Saturation")?.value == "0 percent")

        tree = try await press("Settings", in: hosted.document)
        #expect(try toggle("Launch at login", in: tree).value == (LaunchAtLogin().isEnabled ? "1" : "0"))
    }

    @Test func pauseAndResumeAreOneControlThatKeepsItsPlace() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        manager.setEnabled(true, for: 1)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)
        let pause = try #require(tree.first("Pause Redlight for 30 minutes"))
        #expect(pause.isEnabled)
        #expect(tree.first("Pause lengths") != nil)

        tree = try await press("Pause Redlight for 30 minutes", in: hosted.document)
        #expect(manager.isPaused)
        let resume = try #require(tree.first("Resume Redlight"))
        // The same element with a new name: focus has nothing to fall off.
        #expect(resume.object === pause.object)
        #expect(resume.isEnabled)
        #expect(tree.first("Pause Redlight for 30 minutes") == nil)
        // The time left takes the chevron's place: there is no other length to choose, and
        // the button says how long is left.
        #expect(tree.first("Pause lengths") == nil)
        #expect(resume.value == "Paused, 30 minutes left")
        #expect(!tree.names.contains { $0.hasPrefix("Paused") }, "the countdown is also read as text")

        tree = try await press("Resume Redlight", in: hosted.document)
        #expect(!manager.isPaused)
        #expect(tree.first("Pause Redlight for 30 minutes")?.object === pause.object)
        #expect(tree.first("Pause lengths") != nil)

        // A length chosen from the row pauses too, and the row goes.
        tree = try await press("Pause lengths", in: hosted.document)
        #expect(tree.first("Pause lengths")?.value == "Expanded")
        // Each chip is read by its caller's name, not by the letters drawn on it.
        for option in PauseLengthRow.options {
            #expect(tree.named(option.accessibility).count == 1)
            #expect(tree.first(option.accessibility)?.role == NSAccessibility.Role.button.rawValue)
            #expect(tree.named(option.title).isEmpty, "\(option.title) is read as drawn")
        }
        tree = try await press("Pause for 1 hour", in: hosted.document)
        #expect(manager.isPaused)
        #expect(tree.first("Resume Redlight")?.object === pause.object)
        #expect(tree.first("Pause for 1 hour") == nil)

        // Nothing to pause: Pause is disabled, and Resume never is.
        tree = try await press("Resume Redlight", in: hosted.document)
        manager.setEnabled(false, for: 1)
        tree = await accessibility(of: hosted.document)
        #expect(tree.first("Pause Redlight for 30 minutes")?.isEnabled == false)
    }

    // MARK: - The accent

    /// Offsets of the pixels drawn in exactly this colour: the solid inside of a fill, not
    /// its antialiased edge.
    private func pixels(of color: EmberRGB, in raster: Raster) -> [Int] {
        let wanted = [Int(color.r.rounded()), Int(color.g.rounded()), Int(color.b.rounded())]
        return stride(from: 0, to: raster.pixels.count, by: 4).filter { index in
            (0..<3).allSatisfy { abs(Int(raster.pixels[index + $0]) - wanted[$0]) <= 2 }
        }
    }

    /// The same, outside `excluded`, in bitmap pixels.
    private func pixels(of color: EmberRGB, in raster: Raster, outside excluded: CGRect) -> [Int] {
        pixels(of: color, in: raster).filter { index in
            let pixel = index / 4
            return !excluded.contains(CGPoint(x: pixel % raster.width, y: pixel / raster.width))
        }
    }

    /// The sun arc's canvas in bitmap pixels, top-left origin, and its sun dot's centre.
    /// The arc is drawn in the tint of each time of day, at the white point of each, so
    /// somewhere on it is almost any colour the accent can take, the old one included: a
    /// check for a stale colour leaves its rectangle out. Its accessibility element spans
    /// the row; the canvas reaches `SunArcView.bleed` past it on either side.
    private func sunArc(
        in popover: OffscreenPopover, latitude: Double, longitude: Double, scale: CGFloat = 2
    ) async throws -> (rect: CGRect, sun: CGPoint) {
        AccessibilityTree.enable()
        _ = popover.document.accessibilityChildren()
        await popover.settle()
        let tree = AccessibilityTree(popover.document)
        let node = try #require(tree.nodes.first { $0.name.contains("Solar elevation") }, "no sun arc")
        let selector = Selector(("accessibilityFrame"))
        try #require(node.object.responds(to: selector))
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        let screen = unsafeBitCast(node.object.method(for: selector), to: Frame.self)(node.object, selector)
        let document = popover.document
        var row = document.convert(popover.window.convertFromScreen(screen), from: nil)
        if !document.isFlipped { row.origin.y = document.bounds.height - row.maxY }
        let bleed = SunArcView.bleed
        let canvas = row.insetBy(dx: -bleed, dy: 0)
        // The arc follows the wall clock, on the calendar of the view's environment.
        let cycle = SunCycle(now: Date(), latitude: latitude, longitude: longitude, calendar: .autoupdatingCurrent)
        let centre = SunArcView.sunCentre(for: cycle, rowWidth: row.width)
        return (CGRect(x: canvas.minX * scale, y: canvas.minY * scale,
                       width: canvas.width * scale, height: canvas.height * scale).integral,
                CGPoint(x: ((canvas.minX + centre.x) * scale).rounded(.down),
                        y: ((canvas.minY + centre.y) * scale).rounded(.down)))
    }

    private func colour(at point: CGPoint, in raster: Raster) -> EmberRGB {
        let index = (Int(point.y) * raster.width + Int(point.x)) * 4
        return EmberRGB(Double(raster.pixels[index]), Double(raster.pixels[index + 1]), Double(raster.pixels[index + 2]))
    }

    private func isClose(_ a: EmberRGB, _ b: EmberRGB) -> Bool {
        abs(a.r - b.r.rounded()) <= 2 && abs(a.g - b.g.rounded()) <= 2 && abs(a.b - b.b.rounded()) <= 2
    }

    /// Draws one dark popover at a low and then a higher colour temp and checks every colour
    /// made from the accent: the accent itself, the committed-action fill and the white point
    /// slider's fill.
    /// Dark, because there all three are made of the accent.
    /// `arc` is where the sun arc is drawn for, when the popover has one.
    private func expectTheAccentToFollow(
        _ manager: DisplayManager, defaults: UserDefaults,
        initialState: MenuBarInitialState = MenuBarInitialState(), minimumBands: Int,
        arc: (latitude: Double, longitude: Double)? = nil
    ) async throws {
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager), initialState: initialState)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
        let popover = try OffscreenPopover(content: AnyView(view), appearance: NSAppearance(named: .darkAqua))
        defer { popover.close() }
        await popover.settle()
        let palette = EmberPalette.dark
        var sunArc: (rect: CGRect, sun: CGPoint)?
        if let arc { sunArc = try await self.sunArc(in: popover, latitude: arc.latitude, longitude: arc.longitude) }
        let excluded = sunArc?.rect ?? .null
        func capture(_ intensity: Double) async throws -> (accent: EmberRGB, raster: Raster) {
            manager.intensity = intensity
            await popover.settle()
            let bitmap = try popover.makeBitmap()
            popover.draw(into: bitmap)
            // Auto holds the value inside its band, so take the accent from what it kept.
            return (EmberTint.rgb(intensity: manager.intensity, scheme: .dark), try Raster(bitmap))
        }
        // Upward, so the colour-temp fill only grows and every pixel it had is still fill.
        // Neither value is a preset's, whose swatch would be mistaken for the accent.
        let low = try await capture(0.2)
        let high = try await capture(0.85)
        #expect(low.accent != high.accent)

        let derived: [(name: String, color: (EmberRGB) -> EmberRGB)] = [
            ("accent", { $0 }),
            ("action", { palette.actionRGB(accent: $0).background }),
            ("white point fill", {
                palette.sliderFillRGB(.level(SliderRow.level(whitepoint: manager.whitepoint)), accent: $0)
            }),
        ]
        let newColors = derived.map { $0.color(high.accent) }
        for (name, color) in derived {
            let old = color(low.accent), new = color(high.accent)
            let painted = pixels(of: old, in: low.raster, outside: excluded)
            #expect(painted.count > 400, "\(name) was drawn on only \(painted.count) pixels")
            #expect(pixels(of: new, in: high.raster).count > 400, "\(name) is not drawn in its new colour")
            // Nothing is left behind in the old colour.
            if !newColors.contains(old) {
                let stale = pixels(of: old, in: high.raster, outside: excluded)
                #expect(stale.isEmpty, "\(name) is still drawn in its old colour on \(stale.count) pixels")
            }
            // And each pixel that had it has the new one.
            let wanted = [Int(new.r.rounded()), Int(new.g.rounded()), Int(new.b.rounded())]
            let followed = painted.filter { index in
                (0..<3).allSatisfy { abs(Int(high.raster.pixels[index + $0]) - wanted[$0]) <= 2 }
            }
            #expect(Double(followed.count) >= 0.99 * Double(painted.count),
                    "\(name): \(followed.count) of \(painted.count) pixels followed the colour temp")
        }
        // The accent is in as many separate bands of rows as there are things drawn in it.
        let rows = Set(pixels(of: high.accent, in: high.raster).map { $0 / 4 / high.raster.width }).sorted()
        var bands = 0
        var last = -10
        for row in rows {
            if row - last > 4 { bands += 1 }
            last = row
        }
        #expect(bands >= minimumBands, "the accent is drawn in \(bands) places")
        // The sun dot is the live accent itself, whatever the arc's tint and dimming.
        if let sunArc {
            let dot = colour(at: sunArc.sun, in: high.raster)
            #expect(isClose(dot, high.accent), "the sun dot is \(dot), not the accent \(high.accent)")
        }
    }

    @Test func theAccentFollowsTheColourTempLiveWhereverItIsPainted() async throws {
        let registry = TestDefaultsRegistry()

        // Auto: the switches that are on (header, display, bedtime), the Invert chip that is
        // on, both slider fills, and the arc's line and dot.
        var defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(22 * 60 + 30, forKey: "redlight.adaptiveBedtime")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        var manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        manager.setEnabled(true, for: 1)
        manager.setInverted(true, for: 1)
        // The header's switch, the display's, the arc and the colour temp slider.
        try await expectTheAccentToFollow(manager, defaults: defaults, minimumBands: 4, arc: (41.88, -87.63))

        // Manual and paused: Resume is the action fill, and the Settings button has its dot.
        defaults = registry.makeDefaults()
        manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        manager.setEnabled(true, for: 1)
        #expect(manager.pause())
        try await expectTheAccentToFollow(
            manager, defaults: defaults,
            initialState: MenuBarInitialState(updateAvailable: true, loginRequiresApproval: false),
            minimumBands: 4)
    }

    @Test func aDraggedFlagRecoloursThePopoverBeforeTheDragPausesOrEnds() async throws {
        // A flag's limit reaches the value only when the drag pauses or ends. Until then the
        // displays show the limit, and so must everything painted with the accent.
        let defaults = TestDefaultsRegistry().makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(0.2, forKey: "redlight.adaptiveMin")
        defaults.set(0.45, forKey: "redlight.adaptiveWpMin")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        manager.setEnabled(true, for: 1)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
        let popover = try OffscreenPopover(content: AnyView(view), appearance: NSAppearance(named: .darkAqua))
        defer { popover.close() }
        await popover.settle()
        let palette = EmberPalette.dark
        // No run loop turn between a write and the drawing: only what the write itself
        // invalidated is drawn anew.
        func draw() throws -> Raster {
            popover.document.layoutSubtreeIfNeeded()
            let bitmap = try popover.makeBitmap()
            popover.draw(into: bitmap)
            return try Raster(bitmap)
        }
        func fill(intensity: Double, whitepoint: Double) -> EmberRGB {
            palette.sliderFillRGB(.level(SliderRow.level(whitepoint: whitepoint)),
                                  accent: EmberTint.rgb(intensity: intensity, scheme: .dark))
        }
        // A white point below its top, so its fill is not the accent itself.
        manager.whitepoint = 0.7
        let value = manager.intensity, white = manager.whitepoint
        #expect(value > 0.3 && white == 0.7)
        let resting = EmberTint.rgb(intensity: value, scheme: .dark)
        #expect(pixels(of: resting, in: try draw()).count > 400)
        // Found once: the arc's place does not change while the flags move.
        let arc = try await sunArc(in: popover, latitude: 41.88, longitude: -87.63)

        // The minimum flag dragged to 10 %, the value untouched.
        manager.adaptiveMin = 0.1
        manager.previewIntensity(0.1)
        #expect(manager.intensity == value)
        var raster = try draw()
        let previewed = EmberTint.rgb(intensity: 0.1, scheme: .dark)
        #expect(pixels(of: previewed, in: raster).count > 400)
        #expect(pixels(of: resting, in: raster, outside: arc.rect).isEmpty)
        #expect(isClose(colour(at: arc.sun, in: raster), previewed), "the sun dot shows the limit")
        // The white point slider keeps the colour temp's hue at its own brightness.
        #expect(pixels(of: fill(intensity: 0.1, whitepoint: white), in: raster).count > 400)

        // The white point's minimum flag: its fill dims to the limit shown on the displays.
        manager.adaptiveWpMin = 0.25
        manager.previewWhitepoint(0.25)
        #expect(manager.whitepoint == white)
        raster = try draw()
        #expect(pixels(of: fill(intensity: 0.1, whitepoint: 0.25), in: raster).count > 400)
        #expect(pixels(of: fill(intensity: 0.1, whitepoint: white), in: raster, outside: arc.rect).isEmpty)

        // Released: back to the value's own colours, wherever the wider bands put it.
        manager.endPreview()
        raster = try draw()
        #expect(manager.intensity > 0.3)
        let released = EmberTint.rgb(intensity: manager.intensity, scheme: .dark)
        #expect(pixels(of: released, in: raster).count > 400)
        #expect(pixels(of: previewed, in: raster, outside: arc.rect).isEmpty)
        #expect(isClose(colour(at: arc.sun, in: raster), released), "the sun dot is back on the value")
        #expect(pixels(of: fill(intensity: manager.intensity, whitepoint: manager.whitepoint),
                       in: raster).count > 400)
    }

    @Test func theSunArcDimsAtOnceWhenWhitePointChanges() async throws {
        for learning in [false, true] {
            let defaults = TestDefaultsRegistry().makeDefaults()
            defaults.set(true, forKey: "redlight.adaptiveEnabled")
            defaults.set(learning, forKey: "redlight.learningEnabled")
            let location = FakeLocationProvider()
            location.coordinate = (41.88, -87.63)
            let manager = makeManager(defaults: defaults, location: location,
                                      now: { Self.evening }, calendar: Self.chicagoCalendar)
            manager.setEnabled(true, for: 1)
            let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
            let popover = try OffscreenPopover(content: AnyView(view), appearance: NSAppearance(named: .darkAqua))
            defer { popover.close() }
            await popover.settle()
            let arc = try await sunArc(in: popover, latitude: 41.88, longitude: -87.63)
            func arcPixels() throws -> [UInt8] {
                let bitmap = try popover.makeBitmap()
                popover.draw(into: bitmap)
                let raster = try Raster(bitmap)
                var pixels: [UInt8] = []
                for y in Int(arc.rect.minY)..<Int(arc.rect.maxY) {
                    let start = (y * raster.width + Int(arc.rect.minX)) * 4
                    pixels += raster.pixels[start..<(start + Int(arc.rect.width) * 4)]
                }
                return pixels
            }
            let before = try arcPixels()
            // Down to the white point's floor: Auto's own offset, or a nudge it learns.
            manager.whitepoint = 0.25
            #expect(manager.whitepoint == manager.whitepointBand.lowerBound)
            await popover.settle()
            #expect(try arcPixels() != before, "learning \(learning): the arc still shows the old white point")
        }
    }

    @Test func aLiveAccentGivesTheSameColoursAsTheAccentItself() {
        // The palette's shortcuts for a live accent skip reading it where the result does
        // not depend on it. They must agree with the plain functions everywhere.
        for palette in [EmberPalette.dark, .light, .darkIncreased, .lightIncreased] {
            for intensity in [0.0, 0.1, 0.34, 0.5, 0.7, 1.0] {
                let live = EmberAccent(intensity: { intensity })
                let rgb = EmberTint.rgb(intensity: intensity, scheme: palette.isDark ? .dark : .light)
                #expect(live.rgb(for: palette) == rgb)
                #expect(palette.action(accent: live).background == palette.action(accent: rgb).background)
                #expect(palette.action(accent: live).foreground == palette.action(accent: rgb).foreground)
                #expect(palette.arcDot(accent: live) == palette.arcDot(accent: rgb))
            }
        }
    }

    // MARK: - Location

    @Test func aRoundTripThroughAboutKeepsTheLocationChoiceAndTheTyping() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        let location = FakeLocationProvider()
        location.authorization = .denied
        let manager = makeManager(defaults: defaults, location: location)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }

        // "Enter coordinates" opens Settings on the fields.
        var tree = try await press("Enter coordinates", in: hosted.document)
        #expect(tree.first("Location for Auto", role: .tabGroup)?.value == "Coordinates")
        #expect(textFields(in: hosted.document).latitude == "")

        // Typing that was not submitted is still there after About.
        let fields = allViews(hosted.document).compactMap { $0 as? NSTextField }
        let latitude = try #require(fields.first { $0.placeholderString == "Latitude" })
        try type("48.85", into: latitude)
        await settle(hosted.document)
        tree = try await press("About Redlight", in: hosted.document)
        #expect(tree.first("Back") != nil)
        tree = try await press("Back", in: hosted.document)
        #expect(tree.first("Location for Auto", role: .tabGroup)?.value == "Coordinates")
        #expect(textFields(in: hosted.document).latitude == "48.85")

        // Automatic, then About and back: Settings does not return to the empty fields.
        tree = try await press("Automatic", in: hosted.document)
        #expect(tree.first("Location for Auto", role: .tabGroup)?.value == "Automatic")
        tree = try await press("About Redlight", in: hosted.document)
        tree = try await press("Back", in: hosted.document)
        #expect(tree.first("Location for Auto", role: .tabGroup)?.value == "Automatic")
        #expect(textFields(in: hosted.document).latitude == nil)

        // Opening Settings from the controls starts clean, without the old typing.
        tree = try await press("Back", in: hosted.document)
        tree = try await press("Settings", in: hosted.document)
        #expect(tree.first("Location for Auto", role: .tabGroup)?.value == "Automatic")
        tree = try await press("Coordinates", in: hosted.document)
        #expect(textFields(in: hosted.document).latitude == "")
        #expect(manager.manualLocation == nil)
    }

    /// A page or a mode pane is kept once built, out of sight: it is not in what VoiceOver
    /// reads, and none of its controls take the keyboard.
    @Test func aPageOutOfSightIsNotReadAndTakesNoKeyboard() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        _ = try await press("Settings", in: hosted.document)
        var tree = try await press("Back", in: hosted.document)
        // Settings is still built: its time pickers are in the window, refusing the keyboard.
        let pickers = allViews(hosted.document).compactMap { $0 as? NSDatePicker }
        #expect(!pickers.isEmpty, "Settings was not kept")
        let refusing = pickers.filter(\.refusesFirstResponder).count
        #expect(refusing == pickers.count)
        #expect(!tree.names.contains("Location for Auto"), "a page out of sight is read")
        #expect(tree.named("Settings").count == 1)
        // Both modes built, one read.
        manager.adaptiveEnabled.toggle()
        await settle(hosted.document)
        manager.adaptiveEnabled.toggle()
        await settle(hosted.document)
        tree = await accessibility(of: hosted.document)
        #expect(tree.named("Color temp").count == 1, "\(tree.named("Color temp").count) Color temp sliders are read")
    }

    @Test func editingASavedCoordinateSurvivesAboutButNotLeavingSettings() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let location = FakeLocationProvider()
        location.setManualCoordinate((41.88, -87.63))
        let manager = makeManager(defaults: defaults, location: location)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        _ = try await press("Settings", in: hosted.document)
        #expect(textFields(in: hosted.document).latitude == "41.88")

        let fields = allViews(hosted.document).compactMap { $0 as? NSTextField }
        try type("10", into: try #require(fields.first { $0.placeholderString == "Latitude" }))
        await settle(hosted.document)
        _ = try await press("About Redlight", in: hosted.document)
        _ = try await press("Back", in: hosted.document)
        #expect(textFields(in: hosted.document).latitude == "10")
        #expect(manager.manualLocation?.latitude == 41.88)   // typed, not submitted

        // Reopening Settings shows the saved coordinate, not the stale typing.
        _ = try await press("Back", in: hosted.document)
        _ = try await press("Settings", in: hosted.document)
        #expect(textFields(in: hosted.document).latitude == "41.88")
        #expect(textFields(in: hosted.document).longitude == "-87.63")
    }

    @Test func coordinateFieldsStartFromTheProvidersLocationInManualMode() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location)
        // Adaptive has resolved one place and stopped; the provider has since moved.
        manager.adaptiveEnabled = true
        manager.adaptiveEnabled = false
        location.coordinate = (51.5, -0.13)
        #expect(manager.coordinate?.latitude == 41.88)

        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        _ = try await press("Settings", in: hosted.document)
        _ = try await press("Coordinates", in: hosted.document)
        #expect(textFields(in: hosted.document).latitude == "51.5")
        #expect(textFields(in: hosted.document).longitude == "-0.13")
    }

    @Test func locationRowSaysWhereTheLocationReallyComesFrom() async throws {
        #expect(LocationRow.text(for: .automatic).title == "Automatic")
        #expect(LocationRow.text(for: .timeZone).title == "Time zone")
        #expect(LocationRow.text(for: .lastKnown).title == "Last known")
        #expect(LocationRow.text(for: .manual).title == "Manual")

        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(22 * 60 + 30, forKey: "redlight.adaptiveBedtime")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        // The controls page has no status line: the source is said on the Settings page,
        // under Location for Auto.
        let controls = try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager)))
        let controlsTree = await accessibility(of: controls.document)
        controls.window.close()
        #expect(controlsTree.first("Location") == nil)

        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                               initialPage: .settings)
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)
        #expect(tree.first("Location")?.value == "Automatic")

        // Location Services refused and never a fix: the row changes while it is open.
        location.automaticIsApproximate = true
        location.authorization = .denied
        location.onChange?()
        tree = await accessibility(of: hosted.document)
        #expect(tree.first("Location")?.value == "Time zone")

        location.automaticIsApproximate = false
        location.onChange?()
        tree = await accessibility(of: hosted.document)
        #expect(tree.first("Location")?.value == "Last known")

        manager.setManualLocation((47.61, -122.33))
        tree = await accessibility(of: hosted.document)
        #expect(tree.first("Location")?.value == "Manual")
    }

    @Test func aBedtimeTheCurveIgnoresIsNotShownAsActive() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(3 * 60, forKey: "redlight.adaptiveBedtime")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = makeManager(defaults: defaults, location: location,
                                  now: { Self.evening }, calendar: Self.chicagoCalendar)
        #expect(manager.bedtime == Bedtime(hour: 3, minute: 0))
        #expect(manager.effectiveBedtime == nil)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)
        // 03:00 is after solar midnight: no bedtime on the arc.
        #expect(tree.names.contains { $0.contains("Solar elevation ") })
        #expect(!tree.names.contains { $0.contains("Bedtime ") })

        let effective = Bedtime(hour: 22, minute: 30)!
        manager.setBedtime(effective)
        tree = await accessibility(of: hosted.document)
        #expect(tree.names.contains { $0.contains("Bedtime \(SunArcView.bedtimeText(effective, locale: .current)).") })

        // On the Settings page the switch shows that a bedtime is set, taken up or not.
        manager.setBedtime(Bedtime(hour: 3, minute: 0))
        let settings = try await host(MenuBarView(manager: manager, defaults: defaults,
                                                  handler: makeHandler(manager), initialPage: .settings))
        defer { settings.window.close() }
        #expect(await accessibility(of: settings.document).first(BedtimeRow.title)?.value == "1")
    }

    // MARK: - Reset, the Settings dot and the Settings bar

    @Test func resetInManualIsHiddenBehindAPresetOnlyWhenAutoHasNothingToReset() async throws {
        // Default: never. Auto, or Manual without a preset: whenever something is set.
        for auto in [false, true] {
            for preset in [false, true] {
                for hidden in [false, true] {
                    #expect(!SliderHeader.showsReset(isDefault: true, isAuto: auto, hasPreset: preset,
                                                     autoSettingsAreDefault: hidden))
                }
            }
        }
        #expect(SliderHeader.showsReset(isDefault: false, isAuto: true, hasPreset: false, autoSettingsAreDefault: true))
        #expect(SliderHeader.showsReset(isDefault: false, isAuto: false, hasPreset: false, autoSettingsAreDefault: true))
        // Manual with a preset: only for limits or an adjustment that Manual does not show.
        #expect(!SliderHeader.showsReset(isDefault: false, isAuto: false, hasPreset: true, autoSettingsAreDefault: true))
        #expect(SliderHeader.showsReset(isDefault: false, isAuto: false, hasPreset: true, autoSettingsAreDefault: false))

        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        manager.applyPreset(3)
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager))
        let hosted = try await host(view)
        defer { hosted.window.close() }
        let color = "Reset color temp and its limits to default"
        let white = "Reset white point and its limits to default"
        var tree = await accessibility(of: hosted.document)
        #expect(tree.first(color) == nil && tree.first(white) == nil)

        // A colour-temp limit set in Auto is invisible here, and Reset is the way to clear it.
        manager.adaptiveMin = 0.2
        manager.applyPreset(3)
        tree = await accessibility(of: hosted.document)
        #expect(manager.activePresetIndex == 3)
        #expect(tree.first(color) != nil)
        #expect(tree.first(white) == nil)

        tree = try await press(color, in: hosted.document)
        #expect(manager.adaptiveMin == DisplayManager.Defaults.intensityMin)
        #expect(manager.intensityIsDefault)
        #expect(tree.first(color) == nil)
    }

    @Test func settingsDotSaysWhatItStandsFor() async throws {
        let none = SettingsNotice(hasUpdate: false, loginRequiresApproval: false)
        #expect(none.isEmpty && none.help == "Settings" && none.accessibilityValue == "")
        let update = SettingsNotice(hasUpdate: true, loginRequiresApproval: false)
        #expect(!update.isEmpty && update.help == "Settings, update available")
        #expect(update.accessibilityValue == "Update available")
        let approval = SettingsNotice(hasUpdate: false, loginRequiresApproval: true)
        #expect(!approval.isEmpty && approval.help == "Settings, login item needs approval")
        #expect(approval.accessibilityValue == "Login item needs approval")
        let both = SettingsNotice(hasUpdate: true, loginRequiresApproval: true)
        #expect(both.help == "Settings, update available, login item needs approval")
        #expect(both.accessibilityValue == "Update available, login item needs approval")

        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        for (state, value) in [
            (MenuBarInitialState(updateAvailable: false, loginRequiresApproval: false), ""),
            (MenuBarInitialState(updateAvailable: false, loginRequiresApproval: true), "Login item needs approval"),
            (MenuBarInitialState(updateAvailable: true, loginRequiresApproval: true),
             "Update available, login item needs approval"),
        ] {
            let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager), initialState: state)
            let hosted = try await host(view)
            defer { hosted.window.close() }
            let tree = await accessibility(of: hosted.document)
            #expect(tree.first("Settings")?.value == value)
            // The words drawn on the row belong to the row: nothing else is named by them.
            #expect(tree.named("Update available").isEmpty)
        }
    }

    @Test func anUpdateIsWrittenOnTheSettingsRowAndALoginItemIsADot() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        // Not a preset's colour temp, and a white point under its top: no swatch and no
        // slider is the accent's own colour.
        manager.intensity = 0.62
        manager.whitepoint = 0.6
        // The label is the fill of a committed action; the dot is far too small to be it.
        let fill = EmberPalette.dark.actionRGB(accent: EmberTint.rgb(intensity: 0.62, scheme: .dark)).background
        var painted: [Int] = []
        for state in [MenuBarInitialState(updateAvailable: false, loginRequiresApproval: false),
                      MenuBarInitialState(updateAvailable: false, loginRequiresApproval: true),
                      MenuBarInitialState(updateAvailable: true, loginRequiresApproval: false),
                      MenuBarInitialState(updateAvailable: true, loginRequiresApproval: true)] {
            let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager), initialState: state)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
            let popover = try OffscreenPopover(content: AnyView(view), appearance: NSAppearance(named: .darkAqua))
            defer { popover.close() }
            await popover.settle()
            let bitmap = try popover.makeBitmap()
            popover.draw(into: bitmap)
            let raster = try Raster(bitmap)
            // The bottom of the popover, where the Settings row is.
            let rows = raster.height * 6 / 7..<raster.height
            painted.append(pixels(of: fill, in: raster).filter { rows.contains($0 / 4 / raster.width) }.count)
        }
        #expect(painted[0] == 0)
        #expect(painted[1] > 20 && painted[1] < 400, "the dot: \(painted[1]) pixels")
        #expect(painted[2] > 2000, "the label: \(painted[2]) pixels")
        #expect(painted[3] == painted[2], "an update and an approval show the label alone")
    }

    @Test func theAutomaticUpdatesSwitchIsThereOnlyWithAnUpdater() async throws {
        // A test run has no feed, so no updater: the setting is off and cannot be set.
        #expect(!Updater.shared.isAvailable)
        Updater.shared.setUpdatesAutomatically(true)
        #expect(!Updater.shared.updatesAutomatically && !Updater.shared.canUpdateAutomatically)

        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        for (stand, expected) in [(nil, nil), (true, "1"), (false, "0")] as [(Bool?, String?)] {
            let view = MenuBarView(
                manager: manager, defaults: defaults, launchAtLogin: LaunchAtLogin(), handler: makeHandler(manager),
                initialState: MenuBarInitialState(updateAvailable: false, updatesAutomatically: stand),
                initialPage: .settings)
            let hosted = try await host(view)
            defer { hosted.window.close() }
            let tree = await accessibility(of: hosted.document)
            let switches = tree.named("Update automatically")
            #expect(switches.count == (expected == nil ? 0 : 1), "\(String(describing: stand)): \(switches.map(\.role))")
            #expect(switches.first?.value == expected)
            // Launch at login is still the first row either way.
            #expect(tree.named("Launch at login").count == 1)
        }
    }

    @Test func settingsBarFitsThePopoverInEveryState() throws {
        _ = NSApplication.shared
        let contentWidth = EmberMetrics.width - 2 * EmberMetrics.padding
        let registry = TestDefaultsRegistry()
        var widths: [String: CGFloat] = [:]
        for quitting in [false, true] {
            for update in [nil, false, true] as [Bool?] {
                let manager = makeManager(defaults: registry.makeDefaults(), location: FakeLocationProvider())
                if quitting { manager.beginTerminationFade {} }
                #expect(manager.isTerminating == quitting)
                let bar = SettingsBar(manager: manager,
                                      dispatch: PopoverDispatch(handler: nil, session: PopoverSession()),
                                      updateAvailable: update, showAbout: {})
                let width = NSHostingView(rootView: bar.fixedSize()).fittingSize.width
                let name = "quitting=\(quitting) update=\(update.map(String.init) ?? "none")"
                widths[name] = width
                #expect(width <= contentWidth, "\(name) is \(width) pt wide")
            }
        }
        // The measure is of real buttons: three of them when not quitting, and "Quitting…"
        // takes more room than "Quit".
        let full = try #require(widths["quitting=false update=true"])
        let plain = try #require(widths["quitting=false update=none"])
        let quittingWidth = try #require(widths["quitting=true update=true"])
        #expect(full > plain + 80)
        #expect(quittingWidth > plain)
        #expect(quittingWidth == widths["quitting=true update=none"])
    }

    @Test func aMissingPresetIsNamedAsTheCLINamesIt() {
        let registry = TestDefaultsRegistry()
        let manager = makeManager(defaults: registry.makeDefaults(), location: FakeLocationProvider())
        manager.presets = Array(manager.presets.prefix(4))
        let dispatch = PopoverCommandDispatch(handler: makeHandler(manager))
        #expect(dispatch.execute(.preset(.late)) == "The late preset is unavailable.")
        #expect(dispatch.execute(.savePreset(.late)) == "The late preset is unavailable.")
        #expect(dispatch.execute(.preset(.night)) == nil)
    }

    /// Types into a hosted field through its editor, as the keyboard would.
    private func type(_ text: String, into field: NSTextField) throws {
        let window = try #require(field.window)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }
}

extension AccessibilityTree {
    /// For a name that a heading and a control share.
    func first(_ name: String, role: NSAccessibility.Role) -> Node? {
        nodes.first { $0.name == name && $0.role == role.rawValue }
    }
}

/// Words the popover makes from the model's, where a wrong one is easy to miss on screen.
@MainActor @Suite struct PopoverWordingTests {
    /// The pause pill ticks on the pause's own minutes, and counts from its own last tick: a
    /// tick left over from before the pause, or from an earlier one, is not counted from.
    @Test func thePauseCountdownCountsFromItsOwnPausesTicks() {
        let until = Date(timeIntervalSinceReferenceDate: 100_000)
        // Thirty minutes: the first boundary is the start.
        #expect(PauseCountdown.start(until: until, length: 1800) == until.addingTimeInterval(-1800))
        // A sunrise pause of 7 h 12 m 20 s: rounded back to a whole minute before it began.
        let odd: TimeInterval = 7 * 3600 + 12 * 60 + 20
        let start = PauseCountdown.start(until: until, length: odd)
        #expect(start == until.addingTimeInterval(-(7 * 3600 + 13 * 60)))
        #expect(until.timeIntervalSince(start).truncatingRemainder(dividingBy: 60) == 0)

        let now = until.addingTimeInterval(-1795)
        // No tick yet, one from before this pause, one from after its end: now.
        #expect(PauseCountdown.moment(tick: nil, until: until, length: 1800, now: now) == now)
        #expect(PauseCountdown.moment(tick: until.addingTimeInterval(-1830), until: until, length: 1800, now: now) == now)
        #expect(PauseCountdown.moment(tick: until.addingTimeInterval(5), until: until, length: 1800, now: now) == now)
        // Its own tick, the first included: the tick.
        let first = until.addingTimeInterval(-1800), later = until.addingTimeInterval(-600)
        #expect(PauseCountdown.moment(tick: first, until: until, length: 1800, now: now) == first)
        #expect(PauseCountdown.moment(tick: later, until: until, length: 1800, now: now) == later)
        // So a pause opens on its own length, not a minute more: counted from an idle tick
        // 40 s before it began it would read 31.
        let stale = first.addingTimeInterval(-40)
        #expect(DisplayManager.pauseMinutesLeft(until: until, now: stale) == 31)
        let counted = PauseCountdown.moment(tick: stale, until: until, length: 1800, now: first.addingTimeInterval(0.2))
        #expect(PauseCountdown.text(minutes: DisplayManager.pauseMinutesLeft(until: until, now: counted)) == "30m")
        // A pause with no end in sight does not trap.
        #expect(PauseCountdown.text(minutes: Int.max).hasSuffix("h"))
    }

    /// The pause pill counts minutes up to 99, then the hours still to run.
    @Test func thePauseCountdownStaysThreeCharactersWide() {
        #expect(PauseCountdown.text(minutes: 30) == "30m")
        #expect(PauseCountdown.text(minutes: 1) == "1m")
        #expect(PauseCountdown.text(minutes: 0) == "1m")
        #expect(PauseCountdown.text(minutes: 99) == "99m")
        #expect(PauseCountdown.text(minutes: 100) == "2h")
        #expect(PauseCountdown.text(minutes: 120) == "2h")
        #expect(PauseCountdown.text(minutes: 121) == "3h")
        #expect(PauseCountdown.text(minutes: 24 * 60) == "24h")
        for minutes in 0...(25 * 60) { #expect(PauseCountdown.text(minutes: minutes).count <= 3) }
    }

    /// The row shows the apps with a rule; VoiceOver is told them and their rules too, not
    /// only that it is folded.
    @Test func appsSaysWhichAppsHaveWhichRule() {
        #expect(AppsControl.accessibilityValue(chosen: [], isExpanded: false) == "None, collapsed")
        #expect(AppsControl.accessibilityValue(
            chosen: [("Safari", .pause), ("Preview", .hold(color: 40, whitepoint: 70))], isExpanded: true)
                == "Safari: Pause, Preview: Hold, expanded")
    }
}

/// The app rules in the hosted popover, with `MenuBarViewTests`' helpers.
extension MenuBarViewTests {
    /// The main menu's per-app settings: each app with its rule, a picker, its amounts as
    /// adjustable values, a remove button, then the running apps to add.
    @Test func appsRowsNameEachRuleAndStepItsAmounts() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        let source = FakeAppSource(frontmost: .safari)
        source.names = ["com.apple.Safari": "Safari", "com.apple.Preview": "Preview"]
        source.runningApps = [.safari, .preview, .script]
        let apps = AppRulesController(source: source, defaults: defaults,
                                      ownBundleID: "com.redlight.app", ownProcessID: 999)
        apps.onChange = { manager.setActiveApp($0) }
        try apps.set("com.apple.Safari", .hold(color: 40, whitepoint: 70))
        let handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "Test" },
            appRules: { apps.statusRules }, changeApps: { try apps.apply($0) }))
        let hosted = try await host(MenuBarView(manager: manager, defaults: defaults, handler: handler, apps: apps,
                                                initialState: MenuBarInitialState(updateAvailable: false),
                                                initialPage: .controls))
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)
        #expect(tree.first(AppsControl.title)?.value == "Safari: Hold, collapsed")
        #expect(tree.first("Rule for Safari") == nil, "folded")

        tree = try await press(AppsControl.title, in: hosted.document)
        #expect(tree.first(AppsControl.title)?.value == "Safari: Hold, expanded")
        #expect(tree.first("Rule for Safari")?.value == "Hold")
        let color = try #require(tree.first("Safari color temp hold"))
        #expect(color.value == "40%")
        #expect(tree.first("Safari white point hold")?.value == "70%")
        #expect(AccessibilityTree.increment(color))
        #expect(apps.rule(for: "com.apple.Safari") == .hold(color: 45, whitepoint: 70))
        tree = await accessibility(of: hosted.document)
        #expect(tree.first("Safari color temp hold")?.value == "45%")
        #expect(AccessibilityTree.decrement(try #require(tree.first("Safari white point hold"))))
        #expect(apps.rule(for: "com.apple.Safari") == .hold(color: 45, whitepoint: 65))

        // The running app without a rule is offered; the one without a bundle ID is not.
        #expect(tree.first("Add Safari, paused") == nil)
        #expect(tree.first("Add Script, paused") == nil)
        tree = try await press("Add Preview, paused", in: hosted.document)
        #expect(apps.rule(for: "com.apple.Preview") == .pause)
        #expect(tree.first("Rule for Preview")?.value == "Pause")
        #expect(tree.first("Preview color temp pause") == nil, "a Pause has no amounts")

        tree = try await press("Remove the rule for Safari", in: hosted.document)
        #expect(apps.rule(for: "com.apple.Safari") == nil)
        #expect(tree.first(AppsControl.title)?.value == "Preview: Pause, expanded")
    }

    /// Opened over an app with a Hold, the sliders set that Hold and say so, until "Edit
    /// Auto instead"; the model is left alone.
    @Test func thePopoverOpenedOverAnAppWithAHoldEditsItsRule() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(0.6, forKey: "redlight.intensity")
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        let source = FakeAppSource(frontmost: .photoshop)
        let apps = AppRulesController(source: source, defaults: defaults,
                                      ownBundleID: "com.redlight.app", ownProcessID: 999)
        apps.onChange = { manager.setActiveApp($0) }
        try apps.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        source.activate(.redlight)
        let hosted = try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                                                apps: apps))
        defer { hosted.window.close() }
        var tree = await accessibility(of: hosted.document)
        #expect(tree.first("The sliders set the Hold for Photoshop") != nil)
        let color = try #require(tree.first("Color temp for Photoshop"))
        #expect(color.role == NSAccessibility.Role.slider.rawValue)
        #expect(color.value == SliderCore.spokenPercent(0.4))
        #expect(AccessibilityTree.increment(color))
        let held = try #require(apps.rule(for: "com.adobe.Photoshop")?.amount(.color))
        #expect(held > 40)
        #expect(manager.intensity == 0.6, "the Hold, not the model")

        tree = try await press("Edit Manual instead", in: hosted.document)
        #expect(tree.first("Color temp for Photoshop") == nil)
        let global = try #require(tree.first("Color temp"))
        #expect(global.value == SliderCore.spokenPercent(0.6))
        #expect(tree.first("Photoshop has a Hold; the sliders set Manual") != nil)
        // Each step takes its own target as it begins: Manual here, the rule untouched.
        let rule = apps.rule(for: "com.adobe.Photoshop")
        #expect(AccessibilityTree.increment(global))
        #expect(manager.intensity > 0.6)
        #expect(apps.rule(for: "com.adobe.Photoshop") == rule)
        tree = try await press("Edit Photoshop", in: hosted.document)
        #expect(tree.first("Color temp for Photoshop") != nil)

        // The app quitting takes the line away; the sliders are Manual's again.
        source.terminate(.photoshop)
        tree = await accessibility(of: hosted.document)
        #expect(tree.first("Color temp for Photoshop") == nil)
        #expect(tree.first("Color temp") != nil)
        #expect(tree.first("Edit Manual instead") == nil)
        let before = manager.intensity
        #expect(AccessibilityTree.increment(try #require(tree.first("Color temp"))))
        #expect(manager.intensity > before, "a step after the rule went sets Manual")
    }

    /// Editing a rule hides Save to a preset, and with it the only Cancel, so choosing a
    /// preset to overwrite ends there rather than staying on behind the rule.
    @Test func editingARuleEndsChoosingAPresetToSaveTo() async throws {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let manager = makeManager(defaults: defaults, location: FakeLocationProvider())
        let source = FakeAppSource(frontmost: .photoshop)
        let apps = AppRulesController(source: source, defaults: defaults,
                                      ownBundleID: "com.redlight.app", ownProcessID: 999)
        apps.onChange = { manager.setActiveApp($0) }
        try apps.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        source.activate(.redlight)
        let hosted = try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager),
                                                apps: apps))
        defer { hosted.window.close() }
        func overwriting(_ tree: AccessibilityTree) -> Bool {
            tree.names.contains { $0.hasPrefix("Overwrite ") && $0.hasSuffix(" preset") }
        }

        _ = try await press("Edit Manual instead", in: hosted.document)
        var tree = try await press("Save to a preset", in: hosted.document)
        #expect(overwriting(tree))
        #expect(tree.first("Cancel saving to a preset") != nil)

        tree = try await press("Edit Photoshop", in: hosted.document)
        #expect(tree.first("Cancel saving to a preset") == nil)
        #expect(!overwriting(tree), "a swatch applies its preset again")

        tree = try await press("Edit Manual instead", in: hosted.document)
        #expect(tree.first("Save to a preset") != nil)
        #expect(tree.first("Cancel saving to a preset") == nil)
        #expect(!overwriting(tree))
    }
}
