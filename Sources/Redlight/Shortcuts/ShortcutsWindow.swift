import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A plain AppKit window: SwiftUI's Settings scene would appear whenever Sparkle activates
/// the app, and a recorder cannot live in the menu, which keeps the keyboard while open.
@MainActor
final class ShortcutsWindowController: NSObject, NSWindowDelegate {
    private let store: ShortcutStore
    private var window: NSWindow?

    init(store: ShortcutStore) {
        self.store = store
    }

    /// Hotkeys stay unregistered while a recorder listens. Leaving the window (closing it,
    /// switching apps) must end recording, or every shortcut would stay off.
    func windowDidResignKey(_ notification: Notification) { stopRecording() }
    func windowWillClose(_ notification: Notification) { stopRecording() }

    private func stopRecording() {
        guard store.isRecording else { return }
        window?.makeFirstResponder(nil)
        store.isRecording = false
    }

    func show() {
        // The window is kept between openings. System Settings may have gained or lost
        // shortcuts meanwhile, so re-read them rather than validate against a stale set.
        store.refreshSystemShortcuts()
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: ShortcutsView(store: store, stopRecording: { [weak self] in
            self?.stopRecording()
        }))
        let pointer = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame
        let availableHeight = max(1, (visible?.height ?? 600) - 50)
        window.setContentSize(CGSize(width: 460, height: min(550, availableHeight)))
        if let visible {
            window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        } else {
            window.center()
        }
        return window
    }
}

struct ShortcutsView: View {
    @Bindable var store: ShortcutStore
    let stopRecording: () -> Void
    @State private var notes: [ShortcutAction: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcuts work in any app. Tap Pause to pause for 30 minutes, or hold it to see true colors until you let go.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(ShortcutAction.allCases, id: \.self) { action in
                        GridRow {
                            Text(action.title)
                                .gridColumnAlignment(.trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    ShortcutRecorder(
                                        title: action.title,
                                        shortcut: store.shortcut(for: action),
                                        layoutGeneration: store.layoutGeneration,
                                        reserved: store.systemReserved,
                                        isRecording: $store.isRecording,
                                        onRecord: { record($0, for: action) },
                                        onClear: { clear(action) },
                                        onRejected: { notes[action] = $0 }
                                    )
                                    .frame(width: 150, height: 24)
                                    Button {
                                        clear(action)
                                        stopRecording()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .opacity(store.shortcut(for: action) == nil ? 0 : 1)
                                    .disabled(store.shortcut(for: action) == nil)
                                    .accessibilityLabel("Clear \(action.title) shortcut")
                                }
                                if let note = note(for: action) {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack {
                Button("Use Suggested Shortcuts") {
                    notes.removeAll()
                    store.useSuggested(reserved: store.systemReserved)
                    stopRecording()
                    for action in ShortcutAction.allCases {
                        if let suggested = action.suggested, store.systemReserved.contains(suggested) {
                            notes[action] = "macOS already uses \(suggested.label())."
                        }
                    }
                }
                Spacer()
                Button("Clear All") {
                    notes.removeAll()
                    store.clearAll()
                    stopRecording()
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func note(for action: ShortcutAction) -> String? {
        if let shortcut = store.shortcut(for: action), store.systemReserved.contains(shortcut) {
            return "macOS already uses \(shortcut.label())."
        }
        if store.unavailable.contains(action) { return "Another app is using this shortcut." }
        return notes[action]
    }

    private func clear(_ action: ShortcutAction) {
        notes[action] = nil
        store.set(nil, for: action)
    }

    private func record(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        notes[action] = nil
        if let previous = store.set(shortcut, for: action) {
            notes[previous] = nil
            notes[action] = "Moved from \(previous.title)."
        }
    }
}

/// Click to record, then press a combination. Esc cancels; Delete clears.
private struct ShortcutRecorder: NSViewRepresentable {
    let title: String
    let shortcut: KeyShortcut?
    let layoutGeneration: Int
    let reserved: Set<KeyShortcut>
    @Binding var isRecording: Bool
    let onRecord: (KeyShortcut) -> Void
    let onClear: () -> Void
    let onRejected: (String) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.setAccessibilityElement(true)
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.updateShortcut(shortcut, layoutGeneration: layoutGeneration)
        field.reserved = reserved
        field.onRecord = onRecord
        field.onClear = onClear
        field.onRejected = onRejected
        field.onRecordingChange = { recording in
            if isRecording != recording { isRecording = recording }
        }
        field.setAccessibilityLabel("\(title) shortcut")
    }
}

final class RecorderField: NSView {
    var reserved: Set<KeyShortcut> = []
    var onRecord: ((KeyShortcut) -> Void)?
    var onClear: (() -> Void)?
    var onRejected: ((String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var shortcut: KeyShortcut?
    private var layoutGeneration = 0
    private var shortcutLabel = "Record Shortcut"
    private var liveModifiers: NSEvent.ModifierFlags = []
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            liveModifiers = []
            onRecordingChange?(isRecording)
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityValue() -> Any? { label }
    override func accessibilityPerformPress() -> Bool { startRecording() }

    override func mouseDown(with event: NSEvent) { _ = startRecording() }

    func updateShortcut(_ shortcut: KeyShortcut?, layoutGeneration: Int) {
        guard self.shortcut != shortcut || self.layoutGeneration != layoutGeneration else { return }
        self.shortcut = shortcut
        self.layoutGeneration = layoutGeneration
        shortcutLabel = shortcut?.label() ?? "Record Shortcut"
        needsDisplay = true
    }

    private func startRecording() -> Bool {
        guard let window, window.makeFirstResponder(self) else { return false }
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        needsDisplay = true
    }

    /// ⌘ combinations arrive as key equivalents before keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let code = Int(event.keyCode)
        guard isRecording else {
            if modifiers.isEmpty, code == kVK_Space || code == kVK_Return {
                if !event.isARepeat { _ = startRecording() }
            } else {
                super.keyDown(with: event)
            }
            return
        }
        guard !event.isARepeat else { return }
        if modifiers.isEmpty, code == kVK_Escape {
            isRecording = false
            return
        }
        if modifiers.isEmpty, code == kVK_Delete || code == kVK_ForwardDelete {
            if shortcut != nil { onClear?() }
            isRecording = false
            return
        }
        let candidate = KeyShortcut(keyCode: event.keyCode, flags: modifiers)
        switch candidate.problem(reserved: reserved) {
        case .needsModifiers:
            onRejected?("Use ⌘ or ⌃ with another modifier. F13–F19 work on their own.")
            NSSound.beep()
        case .reservedBySystem:
            onRejected?("macOS already uses \(candidate.label()).")
            NSSound.beep()
        case .invalidKey:
            onRejected?("This key cannot be used as a shortcut.")
            NSSound.beep()
        case nil:
            onRecord?(candidate)
            isRecording = false
        }
    }

    private var label: String {
        if isRecording {
            return liveModifiers.isEmpty ? "Type Shortcut…"
                : KeyShortcut(keyCode: 0, flags: liveModifiers).label { _ in "" }
        }
        return shortcutLabel
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let color: NSColor = shortcut == nil && !isRecording ? .secondaryLabelColor : .labelColor
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: color,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
