import AppKit
import Carbon.HIToolbox
import Observation

enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case toggle, pause, warmer, cooler, dimmer, brighter, appearance, adaptive
    case presetDay, presetWarm, presetSunset, presetNight, presetDeepRed

    var title: String {
        switch self {
        case .toggle: "Turn Redlight On or Off"
        case .pause: "Pause for 30 Minutes"
        case .warmer: "Warmer"
        case .cooler: "Cooler"
        case .dimmer: "Dimmer White Point"
        case .brighter: "Brighter White Point"
        case .appearance: "Toggle Light/Dark Mode"
        case .adaptive: "Toggle Adaptive"
        case .presetDay: "Day Preset"
        case .presetWarm: "Warm Preset"
        case .presetSunset: "Sunset Preset"
        case .presetNight: "Night Preset"
        case .presetDeepRed: "Deep Red Preset"
        }
    }

    /// Step actions repeat while held, like a key in a text field.
    var repeats: Bool { step != nil }

    /// Lower Color Temp is redder, so Warmer steps the value down.
    var step: (channel: CommandChannel, percent: Double)? {
        switch self {
        case .warmer: (.color, -5)
        case .cooler: (.color, 5)
        case .dimmer: (.whitepoint, -5)
        case .brighter: (.whitepoint, 5)
        default: nil
        }
    }

    var preset: CommandPreset? {
        switch self {
        case .presetDay: .day
        case .presetWarm: .warm
        case .presetSunset: .sunset
        case .presetNight: .night
        case .presetDeepRed: .deepRed
        default: nil
        }
    }

    /// Offered by "Use Suggested"; nothing is assigned until the user asks. ⌥⌘D is the
    /// system's Dock toggle, so Light/Dark uses ⌥⌘A.
    var suggested: KeyShortcut? {
        let primary = UInt32(optionKey | cmdKey)
        let key: Int? = switch self {
        case .toggle: kVK_ANSI_R
        case .pause: kVK_ANSI_P
        case .warmer: kVK_ANSI_LeftBracket
        case .cooler: kVK_ANSI_RightBracket
        case .dimmer: kVK_ANSI_Minus
        case .brighter: kVK_ANSI_Equal
        case .appearance: kVK_ANSI_A
        default: nil
        }
        return key.map { KeyShortcut(keyCode: UInt32($0), modifiers: primary) }
    }
}

/// Assigned shortcuts, persisted as one JSON value. Registration is the controller's job;
/// it observes `onChange` and reports combinations macOS refused in `unavailable`.
@MainActor
@Observable
final class ShortcutStore {
    private(set) var shortcuts: [ShortcutAction: KeyShortcut] = [:]
    /// Assigned but unavailable because the system or another app owns the combination.
    var unavailable: Set<ShortcutAction> = []
    private(set) var systemReserved: Set<KeyShortcut>
    /// True while a recorder listens, so pressing an assigned shortcut records it.
    var isRecording = false {
        didSet { if isRecording != oldValue { onChange?() } }
    }
    /// Bumped when the keyboard layout changes so labels re-render.
    private(set) var layoutGeneration = 0
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reservedShortcuts: () -> Set<KeyShortcut>
    @ObservationIgnored nonisolated(unsafe) private var layoutObserver: NSObjectProtocol?
    private static let key = "redlight.shortcuts"

    init(defaults: UserDefaults = .standard, reserved: @escaping () -> Set<KeyShortcut> = KeyShortcut.systemReserved) {
        self.defaults = defaults
        reservedShortcuts = reserved
        systemReserved = reserved()
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: KeyShortcut].self, from: data) {
            var used = Set<KeyShortcut>()
            for action in ShortcutAction.allCases {
                guard let shortcut = saved[action.rawValue], shortcut.problem(reserved: []) == nil,
                      used.insert(shortcut).inserted else { continue }
                shortcuts[action] = shortcut
            }
        }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutGeneration += 1 }
        }
    }

    deinit {
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
    }

    func shortcut(for action: ShortcutAction) -> KeyShortcut? { shortcuts[action] }

    func refreshSystemShortcuts() {
        let current = reservedShortcuts()
        if systemReserved != current {
            systemReserved = current
            onChange?()
        } else if unavailable.contains(where: { action in
            shortcuts[action].map { !current.contains($0) } ?? false
        }) {
            // Another app may have released its hotkey since the last window opening.
            onChange?()
        }
    }

    /// Assigns `shortcut`, taking it from any other action. Returns that previous owner.
    @discardableResult
    func set(_ shortcut: KeyShortcut?, for action: ShortcutAction) -> ShortcutAction? {
        guard shortcut?.problem(reserved: []) == nil, shortcuts[action] != shortcut else { return nil }
        var previousOwner: ShortcutAction?
        if let shortcut,
           let owner = shortcuts.first(where: { $0.value == shortcut && $0.key != action })?.key {
            shortcuts[owner] = nil
            previousOwner = owner
        }
        shortcuts[action] = shortcut
        commit()
        return previousOwner
    }

    func useSuggested(reserved: Set<KeyShortcut>) {
        let previous = shortcuts
        for action in ShortcutAction.allCases {
            guard let suggested = action.suggested, suggested.problem(reserved: reserved) == nil else { continue }
            // As in `set`: a combination belongs to one action, so take it from another.
            for (owner, shortcut) in shortcuts where shortcut == suggested && owner != action {
                shortcuts[owner] = nil
            }
            shortcuts[action] = suggested
        }
        if shortcuts != previous { commit() }
    }

    func clearAll() {
        guard !shortcuts.isEmpty else { return }
        shortcuts.removeAll()
        commit()
    }

    private func commit() {
        let named = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(named) { defaults.set(data, forKey: Self.key) }
        onChange?()
    }
}
