import AppKit

/// Runs assigned shortcuts through the shared command layer, so each behaves exactly like
/// the matching CLI, Siri, and menu action, and reports the result on the readout.
@MainActor
final class ShortcutController {
    /// A shorter press of the Pause shortcut pauses; a longer hold only peeks.
    static let tapThreshold: TimeInterval = 0.35
    /// Limit a hold when neither Carbon nor the physical key state can report its release.
    static let untrackedHoldLimit: TimeInterval = 4

    private struct Hold {
        let shortcut: KeyShortcut
        let startedAt: TimeInterval
        var hasObservedKeyDown: Bool
    }

    let store: ShortcutStore
    private let hotkeys: HotkeyRegistering
    private let manager: DisplayManager
    private let execute: (RedlightCommand) throws -> Status
    private let readout: ValueReadout
    private let uptime: () -> TimeInterval
    private let repeatDelay: () -> TimeInterval
    private let repeatInterval: () -> TimeInterval

    private var nextRegistrationID: UInt32 = 0
    private var registrations: [UInt32: (action: ShortcutAction, shortcut: KeyShortcut)] = [:]
    private var heldActions: [ShortcutAction: Hold] = [:]
    private var releaseWatch: Timer?
    private var repeatTimer: Timer?
    private var repeatingAction: ShortcutAction?
    private var peekStartedAt: TimeInterval?
    private var pauseWasActive = false

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
    private func registerAll() {
        clearRegistrations()
        guard !store.isRecording else { return }
        var refused = Set<ShortcutAction>()
        for action in ShortcutAction.allCases {
            guard let shortcut = store.shortcut(for: action) else { continue }
            nextRegistrationID &+= 1
            if store.systemReserved.contains(shortcut) || !hotkeys.register(shortcut, id: nextRegistrationID) {
                refused.insert(action)
            } else {
                registrations[nextRegistrationID] = (action, shortcut)
            }
        }
        if store.unavailable != refused { store.unavailable = refused }
    }

    private func clearRegistrations() {
        stopRepeating()
        endPeek()
        heldActions.removeAll()
        stopReleaseWatch()
        guard !registrations.isEmpty else { return }
        registrations.removeAll()
        hotkeys.unregisterAll()
    }

    isolated deinit { clearRegistrations() }

    private func handle(id: UInt32, pressed: Bool) {
        // Ignore events queued for registrations removed while recording or editing.
        guard let (action, shortcut) = registrations[id] else { return }
        guard pressed else {
            release(action)
            return
        }
        // Carbon can resend a press while held, including for keys we rolled off.
        guard heldActions[action] == nil else { return }
        heldActions[action] = Hold(shortcut: shortcut, startedAt: uptime(),
                                   hasObservedKeyDown: hotkeys.isKeyDown(shortcut))
        startReleaseWatch()
        if action == .pause {
            pausePressed()
        } else if action.repeats {
            startRepeating(action)
        } else {
            perform(action)
        }
    }

    private func release(_ action: ShortcutAction, expired: Bool = false) {
        guard heldActions.removeValue(forKey: action) != nil else { return }
        if heldActions.isEmpty { stopReleaseWatch() }
        if repeatingAction == action { stopRepeating() }
        if action == .pause {
            expired ? endPeek() : pauseReleased()
        }
    }

    private func startReleaseWatch() {
        guard releaseWatch == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHeldKeys() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    private func stopReleaseWatch() {
        releaseWatch?.invalidate()
        releaseWatch = nil
    }

    private func checkHeldKeys() {
        for action in heldActions.keys { _ = isHeld(action) }
    }

    private func isHeld(_ action: ShortcutAction) -> Bool {
        guard let hold = heldActions[action] else { return false }
        if hotkeys.isKeyDown(hold.shortcut) {
            if !hold.hasObservedKeyDown { heldActions[action]?.hasObservedKeyDown = true }
            return true
        }
        if hold.hasObservedKeyDown {
            release(action)
            return false
        }
        if uptime() - hold.startedAt >= Self.untrackedHoldLimit {
            release(action, expired: true)
            return false
        }
        return true
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
            let floor = channel == .color ? 0.0 : 25.0
            let band = channel == .color ? manager.intensityBand : manager.whitepointBand
            let narrowerLimit = percent < 0 ? band.lowerBound > floor / 100 : band.upperBound < 1
            if after == before, manager.adaptiveEnabled, band.lowerBound != band.upperBound, narrowerLimit {
                text += " · Adaptive limit"
            }
            if status.pausedUntil != nil { text += " · Paused" }
            else if status.suspendedFor != nil { text += " · Suspended" }
            else if !status.on { text += " · Off" }
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
        guard step(action) else { return }
        let delay = repeatDelay()
        let interval = repeatInterval()
        guard delay.isFinite, delay >= 0, interval.isFinite, interval > 0 else { return }
        let timer = Timer(timeInterval: max(0.01, interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isHeld(action) else { return }
                if !self.step(action) { self.stopRepeating() }
            }
        }
        timer.fireDate = Date().addingTimeInterval(delay)
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
        repeatingAction = action
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingAction = nil
    }

    // MARK: - Pause and peek

    private func pausePressed() {
        guard peekStartedAt == nil else { return }
        guard manager.isOn else {
            readout.show("Redlight Is Off", level: nil)
            return
        }
        pauseWasActive = manager.isPaused
        peekStartedAt = uptime()
        manager.setPeeking(true)
    }

    private func pauseReleased() {
        guard let startedAt = peekStartedAt else { return }
        peekStartedAt = nil
        guard uptime() - startedAt < Self.tapThreshold else {
            manager.setPeeking(false)
            return
        }
        do {
            if pauseWasActive {
                manager.setPeeking(false)
                _ = try execute(.pause(.off))
                readout.show("Resumed", level: nil)
                return
            }
            _ = try execute(.pause(.on))
            manager.setPeeking(false)
            readout.show("Paused · \(DisplayManager.pauseLengthText(manager.pauseLength))", level: nil)
        } catch {
            manager.setPeeking(false)
            readout.show(error.localizedDescription, level: nil)
        }
    }

    private func endPeek() {
        guard peekStartedAt != nil else { return }
        peekStartedAt = nil
        manager.setPeeking(false)
    }
}
