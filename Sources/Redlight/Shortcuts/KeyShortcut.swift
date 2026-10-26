import AppKit
import Carbon.HIToolbox

/// A global shortcut as a physical key plus Carbon modifier flags, the form
/// `RegisterEventHotKey` takes. The key's label follows the current keyboard layout.
struct KeyShortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    enum Problem: Equatable {
        /// Global shortcuts with a single modifier would steal ordinary app and text keys.
        case needsModifiers
        case reservedBySystem
    }

    /// Extra keys (often mapped by Stream Deck and similar devices) that apps never use.
    static let standaloneKeys: Set<UInt32> = Set([
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ].map(UInt32.init))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.supportedModifiers
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt32(keyCode), modifiers: Self.carbonModifiers(flags))
    }

    static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// F13–F19 may stand alone. Anything else needs ⌘ or ⌃ plus a second modifier, which
    /// also excludes the ⌥/⌥⇧-only combinations macOS no longer delivers as hotkeys.
    func problem(reserved: Set<KeyShortcut>) -> Problem? {
        if reserved.contains(self) { return .reservedBySystem }
        if Self.standaloneKeys.contains(keyCode) { return nil }
        let count = modifiers.nonzeroBitCount
        let hasPrimary = modifiers & UInt32(cmdKey | controlKey) != 0
        return count >= 2 && hasPrimary ? nil : .needsModifiers
    }

    // MARK: - Labels

    /// Apple's modifier order (⌃⌥⇧⌘), then the key as printed on the current layout.
    func label(keyName: (UInt32) -> String = Self.keyName) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        if let name = specialKeyNames[Int(keyCode)] { return name }
        return layoutCharacter(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "Help",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    /// The unmodified character for a key on the active layout (Dvorak, AZERTY, …).
    private static func layoutCharacter(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: - System shortcuts

    /// Enabled shortcuts from System Settings → Keyboard Shortcuts (Spotlight, Mission
    /// Control, screenshots, …). These can register successfully yet never arrive.
    static func systemReserved() -> Set<KeyShortcut> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return Set(entries.compactMap { entry -> KeyShortcut? in
            guard (entry[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value
            else { return nil }
            return KeyShortcut(keyCode: code, modifiers: modifiers)
        })
    }
}
