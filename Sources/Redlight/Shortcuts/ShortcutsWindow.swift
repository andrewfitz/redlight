import AppKit
import SwiftUI

/// A plain AppKit window: SwiftUI's Settings scene would appear whenever Sparkle activates
/// the app, and a recorder cannot live in the menu, which keeps the keyboard while open.
@MainActor
final class ShortcutsWindowController {
    private let store: ShortcutStore
    private let reserved: () -> Set<KeyShortcut>
    private var window: NSWindow?

    init(store: ShortcutStore, reserved: @escaping () -> Set<KeyShortcut> = { KeyShortcut.systemReserved() }) {
        self.store = store
        self.reserved = reserved
    }

    func show() {
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
        window.contentView = NSHostingView(rootView: ShortcutsView(store: store, reserved: reserved()))
        window.setContentSize(window.contentView?.fittingSize ?? CGSize(width: 440, height: 480))
        window.center()
        return window
    }
}

struct ShortcutsView: View {
    @Bindable var store: ShortcutStore
    let reserved: Set<KeyShortcut>
    @State private var notes: [ShortcutAction: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shortcuts work in any app. Tap Pause to pause for 30 minutes, or hold it to see true colors until you let go.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    GridRow {
                        Text(action.title)
                            .gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                ShortcutRecorder(
                                    shortcut: store.shortcut(for: action),
                                    layoutGeneration: store.layoutGeneration,
                                    reserved: reserved,
                                    isRecording: $store.isRecording,
                                    onRecord: { record($0, for: action) },
                                    onClear: { clear(action) },
                                    onRejected: { notes[action] = $0 }
                                )
                                .frame(width: 150, height: 24)
                                .accessibilityLabel("\(action.title) shortcut")
                                Button {
                                    clear(action)
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

            HStack {
                Button("Use Suggested Shortcuts") {
                    notes.removeAll()
                    store.useSuggested()
                }
                Spacer()
                Button("Clear All") {
                    notes.removeAll()
                    store.clearAll()
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func note(for action: ShortcutAction) -> String? {
        if let note = notes[action] { return note }
        if store.unavailable.contains(action) { return "Another app is using this shortcut." }
        return nil
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
    let shortcut: KeyShortcut?
    let layoutGeneration: Int
    let reserved: Set<KeyShortcut>
    @Binding var isRecording: Bool
    let onRecord: (KeyShortcut) -> Void
    let onClear: () -> Void
    let onRejected: (String) -> Void

    func makeNSView(context: Context) -> RecorderField {
        RecorderField()
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.shortcut = shortcut
        field.reserved = reserved
        field.onRecord = onRecord
        field.onClear = onClear
        field.onRejected = onRejected
        field.onRecordingChange = { recording in
            if isRecording != recording { isRecording = recording }
        }
        field.needsDisplay = true
    }
}

final class RecorderField: NSView {
    var shortcut: KeyShortcut?
    var reserved: Set<KeyShortcut> = []
    var onRecord: ((KeyShortcut) -> Void)?
    var onClear: (() -> Void)?
    var onRejected: ((String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var liveModifiers: NSEvent.ModifierFlags = []
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            liveModifiers = []
            onRecordingChange?(isRecording)
            needsDisplay = true
            setAccessibilityValue(label)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { startRecording(); return true }

    override func mouseDown(with event: NSEvent) { startRecording() }

    private func startRecording() {
        window?.makeFirstResponder(self)
        isRecording = true
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
        guard isRecording else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if modifiers.isEmpty, event.keyCode == 53 { // Escape
            isRecording = false
            return
        }
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete
            isRecording = false
            if shortcut != nil { onClear?() }
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
        case nil:
            isRecording = false
            onRecord?(candidate)
        }
    }

    private var label: String {
        if isRecording {
            return liveModifiers.isEmpty ? "Type Shortcut…"
                : KeyShortcut(keyCode: 0, flags: liveModifiers).label { _ in "" }
        }
        return shortcut?.label() ?? "Record Shortcut"
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
