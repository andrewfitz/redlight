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
    @MainActor
    fileprivate final class CallbackContext {
        weak var owner: CarbonHotkeys?
    }

    var onEvent: ((UInt32, Bool) -> Void)?
    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let context = CallbackContext()
    private nonisolated static let signature: OSType = 0x5244_4C54 // 'RDLT'

    init() {
        context.owner = self
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetEventDispatcherTarget(), hotkeyCallback, types.count, &types,
            Unmanaged.passUnretained(context).toOpaque(), &handler)
        return status == noErr && handler != nil
    }

    func register(_ shortcut: KeyShortcut, id: UInt32) -> Bool {
        guard registered[id] == nil, installHandler() else { return false }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { return false }
        registered[id] = reference
        return true
    }

    func unregisterAll() {
        for reference in registered.values { UnregisterEventHotKey(reference) }
        registered.removeAll()
    }

    func isKeyDown(_ shortcut: KeyShortcut) -> Bool {
        guard let code = CGKeyCode(exactly: shortcut.keyCode) else { return false }
        return CGEventSource.keyState(.combinedSessionState, key: code)
    }

    fileprivate func receive(id: UInt32, pressed: Bool) -> Bool {
        guard registered[id] != nil else { return false }
        onEvent?(id, pressed)
        return true
    }

    isolated deinit {
        if let handler { RemoveEventHandler(handler) }
        unregisterAll()
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
    let context = Unmanaged<CarbonHotkeys.CallbackContext>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        let handled = context.owner?.receive(id: hotkey.id, pressed: hotkey.pressed) == true
        return handled ? noErr : OSStatus(eventNotHandledErr)
    }
}
