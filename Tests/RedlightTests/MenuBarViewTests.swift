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

        let maximumHeight = originalSize.height + 40
        let expanded = StatusItemController.makePopover(maximumHeight: maximumHeight, content: view)
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
        let popover = StatusItemController.makePopover(content: view)
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
        #expect(hosted.document.frame.height > manualHeight + 40)
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
    /// starts on the first Tab stop, which in Auto is the colour temp's lower limit: an arrow
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

    @Test func autoHeadlineIsSpokenInWholeWords() {
        #expect(AutoHeadline.spokenText("Sunset in 1 h 12 m") == "Sunset in 1 hour 12 minutes")
        #expect(AutoHeadline.spokenText("Sunrise in 2 h") == "Sunrise in 2 hours")
        #expect(AutoHeadline.spokenText("First light in 1 h 1 m") == "First light in 1 hour 1 minute")
        #expect(AutoHeadline.spokenText("Sunset in 45 m") == "Sunset in 45 minutes")
        // Nothing to expand: the text is spoken as it is shown.
        for text in ["Sunset in under a minute", "Following the sun", "Locating…", "Auto needs your location"] {
            #expect(AutoHeadline.spokenText(text) == text)
        }
        // Every form the manager can produce, so the two cannot drift apart.
        for minutes in [0, 1, 59, 60, 61, 72, 120, 1439] {
            let shown = DisplayManager.describeNextSolarEvent("sunset", in: TimeInterval(minutes * 60))
            let spoken = AutoHeadline.spokenText(shown)
            #expect(!spoken.hasSuffix(" h") && !spoken.hasSuffix(" m") && !spoken.contains(" h "))
            #expect(spoken.hasPrefix("Sunset in "))
        }
    }

    @Test func autoPageNamesEachControlOnceAndSaysTheHeadlineInWords() async throws {
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
        var tree = await accessibility(of: hosted.document)

        // The headline has letters for units on screen and words for VoiceOver.
        let shown = try #require(manager.nextSolarEventText)
        #expect(shown.contains(" h ") || shown.hasSuffix(" m"))
        #expect(tree.named(AutoHeadline.spokenText(shown)).count == 1)
        #expect(tree.named(shown).isEmpty)

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

        // "Deepest by" is said once, by the switch, which also carries the explanation.
        let deepest = tree.named(BedtimeRow.title)
        #expect(deepest.count == 1)
        #expect(deepest.first?.role == NSAccessibility.Role.checkBox.rawValue)
        #expect(deepest.first?.value == "1")
        #expect(deepest.first?.help == BedtimeRow.explanation)
        #expect(tree.named("Reach the deepest setting by a bedtime").isEmpty)

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
            try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager)))
        }

        // Nothing saved: the suggested time. A typed time is saved at once, with no bedtime set.
        var hosted = try await open()
        #expect(try bedtimeFieldMinute(in: hosted.document) == BedtimeRow.suggested.minuteOfDay)
        #expect(defaults.object(forKey: key) == nil)
        try enterBedtime(Bedtime(hour: 21, minute: 15)!, in: hosted.document)
        await settle(hosted.document)
        #expect(defaults.integer(forKey: key) == 21 * 60 + 15)
        #expect(manager.bedtime == nil)

        // It is still there after Manual and back, after Settings and back, and in a popover
        // opened afresh.
        manager.adaptiveEnabled = false
        await settle(hosted.document)
        manager.adaptiveEnabled = true
        await settle(hosted.document)
        #expect(try bedtimeFieldMinute(in: hosted.document) == 21 * 60 + 15)
        _ = try await press("Settings", in: hosted.document)
        _ = try await press("Back", in: hosted.document)
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
        // The chevron stays, so the pill keeps its shape, but there is no length to choose.
        #expect(tree.first("Pause lengths")?.isEnabled == false)

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

    /// Draws one dark popover at a low and then a higher colour temp and checks every colour
    /// made from the accent: the accent itself, the committed-action fill and the soft fill.
    /// Dark, because there all three are made of the accent.
    private func expectTheAccentToFollow(
        _ manager: DisplayManager, defaults: UserDefaults,
        initialState: MenuBarInitialState = MenuBarInitialState(), minimumBands: Int
    ) async throws {
        let view = MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager), initialState: initialState)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
        let popover = try OffscreenPopover(content: AnyView(view), appearance: NSAppearance(named: .darkAqua))
        defer { popover.close() }
        await popover.settle()
        let palette = EmberPalette.dark
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
            ("soft fill", { palette.sliderFillRGB(.soft, accent: $0) }),
        ]
        let newColors = derived.map { $0.color(high.accent) }
        for (name, color) in derived {
            let old = color(low.accent), new = color(high.accent)
            let painted = pixels(of: old, in: low.raster)
            #expect(painted.count > 400, "\(name) was drawn on only \(painted.count) pixels")
            #expect(pixels(of: new, in: high.raster).count > 400, "\(name) is not drawn in its new colour")
            // Nothing is left behind in the old colour.
            if !newColors.contains(old) {
                #expect(pixels(of: old, in: high.raster).isEmpty, "\(name) is still drawn in its old colour")
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
        try await expectTheAccentToFollow(manager, defaults: defaults, minimumBands: 5)

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
        // The bedtime line takes the status line's place on the controls page, so the
        // source is said on the Settings page, under Location for Auto.
        let controls = try await host(MenuBarView(manager: manager, defaults: defaults, handler: makeHandler(manager)))
        let controlsTree = await accessibility(of: controls.document)
        controls.window.close()
        #expect(controlsTree.names.contains { $0.hasPrefix("Deepest red by ") })
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
        // 03:00 is after solar midnight: the ordinary status line, and no bedtime on the arc.
        #expect(!tree.names.contains { $0.hasPrefix("Deepest red by ") })
        #expect(tree.named(manager.adaptiveStatusText).count == 1)
        #expect(manager.adaptiveStatusText.hasPrefix("Following the sun"))
        // The switch still shows that a bedtime is set.
        #expect(tree.first(BedtimeRow.title)?.value == "1")

        let effective = Bedtime(hour: 22, minute: 30)!
        manager.setBedtime(effective)
        tree = await accessibility(of: hosted.document)
        #expect(tree.named("Deepest red by \(BedtimeRow.clockText(effective))").count == 1)
        #expect(tree.named(manager.adaptiveStatusText).isEmpty)
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
