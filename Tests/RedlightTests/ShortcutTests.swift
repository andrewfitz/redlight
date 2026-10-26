import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Redlight

@MainActor
private final class FakeHotkeys: HotkeyRegistering {
    var onEvent: ((UInt32, Bool) -> Void)?
    var registered: [UInt32: KeyShortcut] = [:]
    var refused: Set<KeyShortcut> = []
    var keyDown = true
    func register(_ shortcut: KeyShortcut, id: UInt32) -> Bool {
        guard !refused.contains(shortcut) else { return false }
        registered[id] = shortcut
        return true
    }
    func unregisterAll() { registered.removeAll() }
    func isKeyDown(_ shortcut: KeyShortcut) -> Bool { keyDown }
}

@MainActor
private final class FakeReadout: ValueReadout {
    var shown: [(text: String, level: Double?)] = []
    func show(_ text: String, level: Double?) { shown.append((text, level)) }
}

@MainActor
private final class Uptime { var now: TimeInterval = 100 }

private let primary = UInt32(controlKey | optionKey | cmdKey)

@Suite struct KeyShortcutTests {
    @Test func globalShortcutsNeedTwoModifiersIncludingCommandOrControl() {
        let r = UInt32(kVK_ANSI_R)
        #expect(KeyShortcut(keyCode: r, modifiers: primary).problem(reserved: []) == nil)
        #expect(KeyShortcut(keyCode: r, modifiers: UInt32(cmdKey | shiftKey)).problem(reserved: []) == nil)
        #expect(KeyShortcut(keyCode: r, modifiers: UInt32(cmdKey)).problem(reserved: []) == .needsModifiers)
        #expect(KeyShortcut(keyCode: r, modifiers: UInt32(controlKey)).problem(reserved: []) == .needsModifiers)
        // ⌥⇧ alone: no ⌘ or ⌃, and macOS no longer delivers it as a hotkey.
        #expect(KeyShortcut(keyCode: r, modifiers: UInt32(optionKey | shiftKey)).problem(reserved: []) == .needsModifiers)
        #expect(KeyShortcut(keyCode: r, modifiers: 0).problem(reserved: []) == .needsModifiers)
    }

    @Test func extraFunctionKeysMayStandAlone() {
        #expect(KeyShortcut(keyCode: UInt32(kVK_F13), modifiers: 0).problem(reserved: []) == nil)
        #expect(KeyShortcut(keyCode: UInt32(kVK_F19), modifiers: 0).problem(reserved: []) == nil)
        #expect(KeyShortcut(keyCode: UInt32(kVK_F5), modifiers: 0).problem(reserved: []) == .needsModifiers)
    }

    @Test func systemShortcutsAreRejected() {
        let spotlight = KeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey))
        #expect(spotlight.problem(reserved: [spotlight]) == .reservedBySystem)
    }

    @Test func labelsUseAppleModifierOrderAndKeyNames() {
        let all = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        #expect(KeyShortcut(keyCode: 1, modifiers: all).label { _ in "X" } == "⌃⌥⇧⌘X")
        #expect(KeyShortcut(keyCode: UInt32(kVK_UpArrow), modifiers: primary).label() == "⌃⌥⌘↑")
        #expect(KeyShortcut(keyCode: UInt32(kVK_F13), modifiers: 0).label() == "F13")
    }

    @Test func modifierFlagsRoundTrip() {
        let flags: NSEvent.ModifierFlags = [.command, .control]
        let shortcut = KeyShortcut(keyCode: 0, flags: flags.union(.capsLock))
        #expect(shortcut.modifierFlags == flags)
        #expect(shortcut.modifiers == UInt32(cmdKey | controlKey))
    }
}

@MainActor @Suite struct ShortcutStoreTests {
    let registry = TestDefaultsRegistry()

    @Test func assigningTakesTheShortcutFromItsPreviousActionAndPersists() {
        let defaults = registry.makeDefaults(prefix: "ShortcutStoreTests")
        let store = ShortcutStore(defaults: defaults)
        var changes = 0
        store.onChange = { changes += 1 }
        let shortcut = KeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: primary)
        #expect(store.set(shortcut, for: .toggle) == nil)
        #expect(store.set(shortcut, for: .pause) == .toggle)
        #expect(store.shortcut(for: .toggle) == nil)
        #expect(changes == 2)

        let reloaded = ShortcutStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .pause) == shortcut)
        reloaded.clearAll()
        #expect(ShortcutStore(defaults: defaults).shortcuts.isEmpty)
    }

    @Test func suggestedShortcutsAreValidDistinctAndLeaveExtrasUnassigned() {
        let store = ShortcutStore(defaults: registry.makeDefaults(prefix: "ShortcutStoreTests"))
        #expect(store.shortcuts.isEmpty)
        store.useSuggested()
        let assigned = Array(store.shortcuts.values)
        #expect(Set(assigned).count == assigned.count)
        #expect(assigned.allSatisfy { $0.problem(reserved: []) == nil })
        #expect(store.shortcut(for: .presetDay) == nil)
        #expect(store.shortcut(for: .adaptive) == nil)
    }
}

@MainActor @Suite struct ShortcutControllerTests {
    let registry = TestDefaultsRegistry()
    private let hotkeys = FakeHotkeys()
    private let readout = FakeReadout()
    private let uptime = Uptime()

    private func makeController() -> (ShortcutController, DisplayManager) {
        let defaults = registry.makeDefaults(prefix: "ShortcutControllerTests")
        let manager = DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [1] },
            getDisplayName: { "Display \($0)" }, getDisplayPersistenceKey: { String($0) },
            defaults: defaults, location: FakeLocationProvider(),
            now: { Date(timeIntervalSince1970: 1_000_000) },
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0, peekTransitionDuration: 0)
        let handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in }, login: { .init(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "test" }))
        let store = ShortcutStore(defaults: defaults)
        store.useSuggested()
        let uptime = uptime
        let controller = ShortcutController(
            store: store, manager: manager, execute: { try handler.execute($0) },
            hotkeys: hotkeys, readout: readout, uptime: { uptime.now },
            repeatDelay: { 60 }, repeatInterval: { 60 })
        return (controller, manager)
    }

    private func id(_ action: ShortcutAction) -> UInt32 {
        UInt32(ShortcutAction.allCases.firstIndex(of: action)! + 1)
    }

    @Test func registersAssignedShortcutsAndReportsRefusals() {
        hotkeys.refused = [ShortcutAction.appearance.suggested!]
        let (controller, _) = makeController()
        #expect(hotkeys.registered.count == 6)
        #expect(controller.store.unavailable == [.appearance])

        controller.store.isRecording = true
        #expect(hotkeys.registered.isEmpty)
        controller.store.isRecording = false
        #expect(hotkeys.registered.count == 6)
    }

    @Test func stepsMoveTheTargetAndReportLimits() {
        let (controller, manager) = makeController()
        manager.setAll(on: true)
        controller.handle(id: id(.warmer), pressed: true)
        controller.handle(id: id(.warmer), pressed: false)
        #expect(abs(manager.intensity - 0.95) < 1e-9)
        #expect(readout.shown.last?.text == "Color 95%")
        #expect(readout.shown.last?.level.map { abs($0 - 0.95) < 1e-9 } == true)

        manager.adaptiveEnabled = true
        manager.adaptiveMax = 0.95
        controller.handle(id: id(.cooler), pressed: true)
        controller.handle(id: id(.cooler), pressed: false)
        #expect(readout.shown.last?.text == "Color 95% · Adaptive limit")
    }

    @Test func tapPausesAndResumesWhileHoldOnlyPeeks() {
        let (controller, manager) = makeController()
        manager.setAll(on: true)

        controller.handle(id: id(.pause), pressed: true)
        uptime.now += 0.1
        controller.handle(id: id(.pause), pressed: false)
        #expect(manager.isPaused)
        #expect(readout.shown.last?.text.hasPrefix("Paused Until") == true)

        controller.handle(id: id(.pause), pressed: true)
        controller.handle(id: id(.pause), pressed: false)
        #expect(!manager.isPaused)
        #expect(readout.shown.last?.text == "Resumed")

        controller.handle(id: id(.pause), pressed: true)
        uptime.now += 2
        controller.handle(id: id(.pause), pressed: false)
        #expect(!manager.isPaused)
        #expect(manager.isFiltering)
    }

    @Test func pauseWhileOffExplainsInsteadOfPeeking() {
        let (controller, manager) = makeController()
        controller.handle(id: id(.pause), pressed: true)
        controller.handle(id: id(.pause), pressed: false)
        #expect(!manager.isPaused)
        #expect(readout.shown.last?.text == "Redlight Is Off")
    }

    @Test func toggleReportsTheNewState() {
        let (controller, manager) = makeController()
        controller.handle(id: id(.toggle), pressed: true)
        #expect(manager.isOn)
        #expect(readout.shown.last?.text == "Redlight On")
        controller.handle(id: id(.toggle), pressed: true)
        #expect(readout.shown.last?.text == "Redlight Off")
    }
}
