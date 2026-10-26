import AppKit

/// Runs assigned shortcuts through the shared command layer, so each behaves exactly like
/// the matching CLI, Siri, and menu action, and reports the result on the readout.
@MainActor
final class ShortcutController {
    /// A shorter press of the Pause shortcut pauses; a longer hold only peeks.
    static let tapThreshold: TimeInterval = 0.35
    /// Fallback limit for a held step whose key-up never arrives.
    static let maxRepeatDuration: TimeInterval = 4

    let store: ShortcutStore
    private let hotkeys: HotkeyRegistering
    private let manager: DisplayManager
    private let execute: (RedlightCommand) throws -> Status
    private let readout: ValueReadout
    private let uptime: () -> TimeInterval
    private let repeatDelay: () -> TimeInterval
    private let repeatInterval: () -> TimeInterval

    private var repeatTimer: Timer?
    private var repeatStartedAt: TimeInterval = 0
    private var peekStartedAt: TimeInterval?
    private var peekWatch: Timer?

    init(
        store: ShortcutStore,
        manager: DisplayManager,
        execute: @escaping (RedlightCommand) throws -> Status,
        hotkeys: HotkeyRegistering = CarbonHotkeys(),
        readout: ValueReadout = ValueHUD(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        repeatDelay: @escaping () -> TimeInterval = { NSEvent.keyRepeatDelay },
        repeatInterval: @escaping () -> TimeInterval = { NSEvent.keyRepeatInterval }
    ) {
        self.store = store
        self.manager = manager
        self.execute = execute
        self.hotkeys = hotkeys
        self.readout = readout
        self.uptime = uptime
        self.repeatDelay = repeatDelay
        self.repeatInterval = repeatInterval
        hotkeys.onEvent = { [weak self] id, pressed in self?.handle(id: id, pressed: pressed) }
        store.onChange = { [weak self] in self?.registerAll() }
        registerAll()
    }

    /// Re-register after any change. Everything is released while a recorder listens.
    func registerAll() {
        stopRepeating()
        endPeek()
        hotkeys.unregisterAll()
        guard !store.isRecording else { return }
        var refused = Set<ShortcutAction>()
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = store.shortcut(for: action) else { continue }
            if !hotkeys.register(shortcut, id: UInt32(index + 1)) { refused.insert(action) }
        }
        if store.unavailable != refused { store.unavailable = refused }
    }

    func handle(id: UInt32, pressed: Bool) {
        let index = Int(id) - 1
        guard ShortcutAction.allCases.indices.contains(index) else { return }
        let action = ShortcutAction.allCases[index]
        if action == .pause {
            pressed ? pausePressed() : pauseReleased()
        } else if action.repeats {
            // Some macOS versions resend the press while held; the timer already repeats.
            if pressed, repeatTimer != nil { return }
            pressed ? startRepeating(action) : stopRepeating()
        } else if pressed {
            perform(action)
        }
    }

    // MARK: - Actions

    private func perform(_ action: ShortcutAction) {
        do {
            switch action {
            case .toggle:
                readout.show(try execute(.master(.toggle)).on ? "Redlight On" : "Redlight Off", level: nil)
            case .appearance:
                let dark = try execute(.appearance(.toggle)).appearance == .dark
                readout.show(dark ? "Dark Mode" : "Light Mode", level: nil)
            case .adaptive:
                readout.show(try execute(.adaptive(.toggle)).adaptive ? "Adaptive On" : "Adaptive Off", level: nil)
            default:
                guard let preset = action.preset else { return }
                _ = try execute(.preset(preset))
                let name = manager.presets.indices.contains(preset.index)
                    ? manager.presets[preset.index].name : action.title
                readout.show(name, level: nil)
            }
        } catch {
            readout.show(error.localizedDescription, level: nil)
        }
    }

    /// One step. Returns false at a limit so a held key stops repeating.
    @discardableResult
    private func step(_ action: ShortcutAction) -> Bool {
        guard let (channel, percent) = action.step else { return false }
        let before = channel == .color ? manager.intensity : manager.whitepoint
        do {
            let status = try execute(.step(channel, percent))
            let after = channel == .color ? manager.intensity : manager.whitepoint
            let value = channel == .color ? status.color.set : status.whitepoint.set
            var text = "\(channel == .color ? "Color Temp" : "White Point") \(Int(value.rounded()))%"
            if after == before, manager.adaptiveEnabled { text += " · Adaptive limit" }
            if status.pausedUntil != nil { text += " · Paused" } else if !status.on { text += " · Off" }
            let floor = channel == .color ? 0.0 : 25.0
            readout.show(text, level: (value - floor) / (100 - floor))
            return after != before
        } catch {
            readout.show(error.localizedDescription, level: nil)
            return false
        }
    }

    // MARK: - Repeat

    private func startRepeating(_ action: ShortcutAction) {
        stopRepeating()
        guard step(action), let shortcut = store.shortcut(for: action) else { return }
        // Only trust the key state as a missed-release guard if it reports this press.
        let keyStateWorks = hotkeys.isKeyDown(shortcut)
        repeatStartedAt = uptime()
        let timer = Timer(timeInterval: max(0.01, repeatInterval()), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = keyStateWorks
                    ? self.hotkeys.isKeyDown(shortcut)
                    : self.uptime() - self.repeatStartedAt < Self.maxRepeatDuration
                if !held || !self.step(action) { self.stopRepeating() }
            }
        }
        timer.fireDate = Date().addingTimeInterval(repeatDelay())
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Pause and peek

    private func pausePressed() {
        guard peekStartedAt == nil else { return }
        if manager.isPaused {
            do {
                _ = try execute(.pause(.off))
                readout.show("Resumed", level: nil)
            } catch {
                readout.show(error.localizedDescription, level: nil)
            }
            return
        }
        guard manager.isOn else {
            readout.show("Redlight Is Off", level: nil)
            return
        }
        peekStartedAt = uptime()
        manager.setPeeking(true)
        guard let shortcut = store.shortcut(for: .pause), hotkeys.isKeyDown(shortcut) else { return }
        let watch = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hotkeys.isKeyDown(shortcut) else { return }
                self.pauseReleased()
            }
        }
        RunLoop.main.add(watch, forMode: .common)
        peekWatch = watch
    }

    private func pauseReleased() {
        guard let startedAt = peekStartedAt else { return }
        peekStartedAt = nil
        peekWatch?.invalidate()
        peekWatch = nil
        guard uptime() - startedAt < Self.tapThreshold else {
            manager.setPeeking(false)
            return
        }
        do {
            let status = try execute(.pause(.on))
            let time = status.pausedUntil?.formatted(date: .omitted, time: .shortened) ?? ""
            readout.show("Paused Until \(time)", level: nil)
        } catch {
            manager.setPeeking(false)
            readout.show(error.localizedDescription, level: nil)
        }
    }

    private func endPeek() {
        guard peekStartedAt != nil else { return }
        peekStartedAt = nil
        peekWatch?.invalidate()
        peekWatch = nil
        manager.setPeeking(false)
    }
}
