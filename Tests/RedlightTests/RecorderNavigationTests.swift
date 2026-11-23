import AppKit
import Carbon.HIToolbox
import Testing
@testable import Redlight

@MainActor @Suite struct RecorderNavigationTests {
    @Test func tabInEitherDirectionEndsRecording() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = RecorderField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        window.contentView?.addSubview(field)
        var transitions: [Bool] = []
        field.onRecordingChange = { transitions.append($0) }

        for flags in [NSEvent.ModifierFlags(), .shift] {
            #expect(field.accessibilityPerformPress())
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: UInt16(kVK_Tab)))
            field.keyDown(with: event)
        }
        #expect(transitions == [true, false, true, false])
    }
}
