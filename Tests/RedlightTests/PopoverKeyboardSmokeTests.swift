import AppKit
import SwiftUI
import Testing
@testable import Redlight

@MainActor @Suite struct PopoverKeyboardSmokeTests {
    // This interaction test needs a macOS GUI session. The regular suite renders offscreen.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REDLIGHT_TEST_POPOVER_KEYBOARD"] == "1"))
    func entersManualCoordinatesThroughNativePopover() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        let location = FakeLocationProvider()
        location.setManualCoordinate((41.88, -87.63))
        let manager = DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [1] },
            getDisplayName: { "Display \($0)" }, getDisplayPersistenceKey: { String($0) },
            getMainDisplayID: { 1 }, defaults: defaults, location: location,
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0)
        let services = CommandServices(appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "Test" })
        let handler = CommandHandler(manager: manager, services: services)
        let view = MenuBarView(manager: manager, handler: handler).defaultAppStorage(defaults)
        let popover = StatusItemController.makePopover(content: view)
        popover.animates = false
        let anchor = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 25, height: 25),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.alphaValue = 0.01
        defer { popover.close(); anchor.close() }
        let anchorView = try #require(anchor.contentView)
        anchor.orderBack(nil)
        app.activate()
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        let popupWindow = try #require(popover.contentViewController?.view.window)
        popupWindow.alphaValue = 0.01
        popupWindow.makeKey()
        #expect(popover.isShown)
        await layout(popover)

        let scroll = try #require(popover.contentViewController?.view as? NSScrollView)
        let document = try #require(scroll.documentView)
        let fields = allViews(document).compactMap { $0 as? NSTextField }
        let latitude = try #require(fields.first { $0.placeholderString == "Latitude" })
        let longitude = try #require(fields.first { $0.placeholderString == "Longitude" })
        try enter("42", in: latitude, window: popupWindow)
        try enter("-88", in: longitude, window: popupWindow)
        try sendKey("\r", code: 36, to: popupWindow)
        await layout(popover)

        #expect(manager.manualLocation?.latitude == 42)
        #expect(manager.manualLocation?.longitude == -88)
    }

    private func layout(_ popover: NSPopover) async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            popover.contentViewController?.view.layoutSubtreeIfNeeded()
        }
    }

    private func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { allViews($0) }
    }

    private func enter(_ text: String, in field: NSTextField, window: NSWindow) throws {
        let location = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        let keyCodes: [Character: UInt16] = ["-": 27, "2": 19, "4": 21, "8": 28]
        for character in text {
            try sendKey(String(character), code: try #require(keyCodes[character]), to: window)
        }
    }

    private func sendKey(_ character: String, code: UInt16, to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }
}
