import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys. Carbon's `RegisterEventHotKey` needs no Accessibility or Input
/// Monitoring permission and only ever sees the registered combinations.
@MainActor
protocol HotkeyRegistering: AnyObject {
    /// False when macOS refuses the combination, usually because another app owns it.
    func register(_ shortcut: KeyShortcut, id: UInt32) -> Bool
    func unregisterAll()
    /// Called with the registration id and whether the key went down or up.
    var onEvent: ((UInt32, Bool) -> Void)? { get set }
    /// Whether the shortcut's key is still physically down, to stop a repeat or peek if
    /// the key-up never arrives.
    func isKeyDown(_ shortcut: KeyShortcut) -> Bool
}

@MainActor
final class CarbonHotkeys: HotkeyRegistering {
    var onEvent: ((UInt32, Bool) -> Void)?
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private nonisolated static let signature: OSType = 0x5244_4C54 // 'RDLT'

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(), hotkeyCallback, types.count, &types,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: KeyShortcut, id: UInt32) -> Bool {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        registered[id] = reference
        return true
    }

    func unregisterAll() {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        registered.removeAll()
    }

    func isKeyDown(_ shortcut: KeyShortcut) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.keyCode))
    }

    fileprivate func receive(id: UInt32, pressed: Bool) {
        onEvent?(id, pressed)
    }

    /// Decoded off the actor so only plain values cross into it.
    fileprivate nonisolated static func decode(_ event: EventRef) -> (id: UInt32, pressed: Bool)? {
        var hotkey = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
        guard status == noErr, hotkey.signature == signature else { return nil }
        return (hotkey.id, GetEventKind(event) == UInt32(kEventHotKeyPressed))
    }
}

/// Carbon delivers hotkey events on the main thread's event dispatcher.
private let hotkeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData, let hotkey = CarbonHotkeys.decode(event) else {
        return OSStatus(eventNotHandledErr)
    }
    let owner = Unmanaged<CarbonHotkeys>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { owner.receive(id: hotkey.id, pressed: hotkey.pressed) }
    return noErr
}
