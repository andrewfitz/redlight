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

    @Test func decodingNormalizesModifiersAndOversizedCodesCanBeLabeled() throws {
        let shortcut = try JSONDecoder().decode(KeyShortcut.self, from:
            Data("{\"keyCode\":4294967295,\"modifiers\":4294967295}".utf8))
        #expect(shortcut.modifiers == KeyShortcut.supportedModifiers)
        #expect(shortcut.problem(reserved: []) == .invalidKey)
        #expect(shortcut.label() == "⌃⌥⇧⌘Key 4294967295")
    }
}

@MainActor @Suite struct ShortcutStoreTests {
    let registry = TestDefaultsRegistry()

    @Test func malformedSavedAssignmentsPreserveValidShortcuts() {
        let defaults = registry.makeDefaults(prefix: "ShortcutStoreTests")
        let data = Data("""
        {"pause":{"keyCode":\(kVK_F13),"modifiers":0},"toggle":{"keyCode":"bad"},"future":null}
        """.utf8)
        defaults.set(data, forKey: "redlight.shortcuts")
        let store = ShortcutStore(defaults: defaults, reserved: { [] })
        #expect(store.shortcuts == [.pause: KeyShortcut(keyCode: UInt32(kVK_F13), modifiers: 0)])
    }

    @Test func assigningTakesTheShortcutFromItsPreviousActionAndPersists() {
        let defaults = registry.makeDefaults(prefix: "ShortcutStoreTests")
        let store = ShortcutStore(defaults: defaults, reserved: { [] })
        var changes = 0
        store.onChange = { changes += 1 }
        let shortcut = KeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: primary)
        #expect(store.set(shortcut, for: .toggle) == nil)
        #expect(store.set(shortcut, for: .pause) == .toggle)
        #expect(store.shortcut(for: .toggle) == nil)
        #expect(changes == 2)

        let reloaded = ShortcutStore(defaults: defaults, reserved: { [] })
        #expect(reloaded.shortcut(for: .pause) == shortcut)
        reloaded.clearAll()
        #expect(ShortcutStore(defaults: defaults, reserved: { [] }).shortcuts.isEmpty)
    }

    @Test func suggestedShortcutsAreValidDistinctAndLeaveExtrasUnassigned() {
        let store = ShortcutStore(defaults: registry.makeDefaults(prefix: "ShortcutStoreTests"), reserved: { [] })
        #expect(store.shortcuts.isEmpty)
        store.useSuggested(reserved: [])
        let assigned = Array(store.shortcuts.values)
        #expect(Set(assigned).count == assigned.count)
        #expect(assigned.allSatisfy { $0.problem(reserved: []) == nil })
        #expect(store.shortcut(for: .presetDay) == nil)
        #expect(store.shortcut(for: .adaptive) == nil)
    }

    @Test func reservedSuggestionsPreserveTheExistingAssignment() {
        let store = ShortcutStore(defaults: registry.makeDefaults(prefix: "ShortcutStoreTests"), reserved: { [] })
        let custom = KeyShortcut(keyCode: UInt32(kVK_F13), modifiers: 0)
        store.set(custom, for: .toggle)
        store.useSuggested(reserved: [ShortcutAction.toggle.suggested!])
        #expect(store.shortcut(for: .toggle) == custom)
        #expect(store.shortcut(for: .pause) == ShortcutAction.pause.suggested)
    }

    @Test func suggestedShortcutsMoveACombinationAnotherActionAlreadyUses() {
        let store = ShortcutStore(defaults: registry.makeDefaults(prefix: "ShortcutStoreTests"), reserved: { [] })
        let custom = KeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: primary)
        store.set(ShortcutAction.toggle.suggested, for: .presetDay)
        store.set(custom, for: .adaptive)
        store.useSuggested(reserved: [])
        #expect(store.shortcut(for: .toggle) == ShortcutAction.toggle.suggested)
        #expect(store.shortcut(for: .presetDay) == nil)
        #expect(store.shortcut(for: .adaptive) == custom)
        let assigned = Array(store.shortcuts.values)
        #expect(Set(assigned).count == assigned.count)
    }

    @Test func savedAssignmentKeysAreStable() {
        // These are the keys inside the saved "redlight.shortcuts" value.
        #expect(ShortcutAction.allCases.map(\.rawValue) == [
            "toggle", "pause", "warmer", "cooler", "dimmer", "brighter", "appearance", "adaptive",
            "presetDay", "presetWarm", "presetSunset", "presetNight", "presetDeepRed",
        ])
        #expect(ShortcutAction.presetLate.title == "Late Preset")
        #expect(ShortcutAction.presetLate.preset == .late)
        #expect(ShortcutAction.allCases.compactMap(\.preset) == CommandPreset.allCases)
    }

    @Test func aShortcutSavedForDeepRedStillBelongsToLate() throws {
        let defaults = registry.makeDefaults(prefix: "ShortcutStoreTests")
        let shortcut = KeyShortcut(keyCode: UInt32(kVK_F13), modifiers: 0)
        defaults.set(Data(#"{"presetDeepRed":{"keyCode":\#(kVK_F13),"modifiers":0}}"#.utf8), forKey: "redlight.shortcuts")
        let store = ShortcutStore(defaults: defaults, reserved: { [] })
        #expect(store.shortcuts == [.presetLate: shortcut])

        // Saving again keeps the same key, so an older copy of the app still reads it.
        store.set(KeyShortcut(keyCode: UInt32(kVK_F14), modifiers: 0), for: .presetDay)
        let data = try #require(defaults.data(forKey: "redlight.shortcuts"))
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(saved.keys) == ["presetDeepRed", "presetDay"])
    }
}

@MainActor @Suite struct ShortcutControllerTests {
    let registry = TestDefaultsRegistry()
    private let hotkeys = FakeHotkeys()
    private let readout = FakeReadout()
    private let uptime = Uptime()

    private func makeController(
        gamma: MockGammaController = MockGammaController(),
        reserved: @escaping () -> Set<KeyShortcut> = { [] }
    ) -> (ShortcutController, DisplayManager) {
        let (controller, manager, _, _) = makeController(gamma: gamma, reserved: reserved, appSource: nil)
        return (controller, manager)
    }

    /// With the app rules wired as the app wires them, when `appSource` is given.
    private func makeController(
        gamma: MockGammaController = MockGammaController(),
        reserved: @escaping () -> Set<KeyShortcut> = { [] },
        appSource: FakeAppSource?
    ) -> (ShortcutController, DisplayManager, AppRulesController?, CommandHandler) {
        let defaults = registry.makeDefaults(prefix: "ShortcutControllerTests")
        let manager = DisplayManager(
            gamma: gamma, getDisplayIDs: { [1] },
            getDisplayName: { "Display \($0)" }, getDisplayPersistenceKey: { String($0) },
            defaults: defaults, location: FakeLocationProvider(),
            now: { Date(timeIntervalSince1970: 1_000_000) },
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0, peekTransitionDuration: 0,
            appRuleTransitionDuration: 0)
        var services = CommandServices(
            appearance: { false }, setAppearance: { _ in }, login: { .init(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "test" })
        let apps = appSource.map {
            AppRulesController(source: $0, defaults: defaults, ownBundleID: "com.redlight.app", ownProcessID: 999)
        }
        if let apps {
            apps.onChange = { manager.setActiveApp($0) }
            services.appRules = { apps.statusRules }
            services.changeApps = { try apps.apply($0) }
        }
        let handler = CommandHandler(manager: manager, services: services)
        let store = ShortcutStore(defaults: defaults, reserved: reserved)
        store.useSuggested(reserved: [])
        let uptime = uptime
        let controller = ShortcutController(
            store: store, manager: manager, execute: { try handler.execute($0) },
            hotkeys: hotkeys, readout: readout, uptime: { uptime.now },
            repeatDelay: { 60 }, repeatInterval: { 60 })
        return (controller, manager, apps, handler)
    }

    private func send(_ action: ShortcutAction, pressed: Bool, to controller: ShortcutController) {
        let shortcut = controller.store.shortcut(for: action)
        if let id = hotkeys.registered.first(where: { $0.value == shortcut })?.key {
            hotkeys.onEvent?(id, pressed)
        }
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

    @Test func savedSystemConflictsBecomeAvailableWhenTheConflictIsRemoved() throws {
        let toggle = try #require(ShortcutAction.toggle.suggested)
        var reserved: Set<KeyShortcut> = [toggle]
        let (controller, _) = makeController(reserved: { reserved })
        #expect(controller.store.shortcut(for: .toggle) == toggle)
        #expect(controller.store.unavailable == [.toggle])
        #expect(!hotkeys.registered.values.contains(toggle))

        reserved = []
        controller.store.refreshSystemShortcuts()
        #expect(controller.store.unavailable.isEmpty)
        #expect(hotkeys.registered.values.contains(toggle))
    }

    @Test func queuedEventsFromAnOldRegistrationDoNotDispatch() throws {
        let (controller, manager) = makeController()
        let toggle = try #require(ShortcutAction.toggle.suggested)
        let oldID = try #require(hotkeys.registered.first(where: { $0.value == toggle })?.key)
        controller.store.isRecording = true
        hotkeys.onEvent?(oldID, true)
        #expect(!manager.isOn)

        controller.store.isRecording = false
        hotkeys.onEvent?(oldID, true)
        #expect(!manager.isOn)
        send(.toggle, pressed: true, to: controller)
        #expect(manager.isOn)
    }

    @Test func stepsMoveTheTargetAndReportLimits() {
        let (controller, manager) = makeController()
        manager.setAll(on: true)
        send(.warmer, pressed: true, to: controller)
        send(.warmer, pressed: false, to: controller)
        #expect(abs(manager.intensity - 0.95) < 1e-9)
        #expect(readout.shown.last?.text == "Color Temp 95%")
        #expect(readout.shown.last?.level.map { abs($0 - 0.95) < 1e-9 } == true)

        manager.adaptiveEnabled = true
        manager.adaptiveMax = 0.95
        send(.cooler, pressed: true, to: controller)
        send(.cooler, pressed: false, to: controller)
        #expect(readout.shown.last?.text == "Color Temp 95% · Adaptive limit")

        manager.adaptiveMax = 1
        manager.intensity = 1
        send(.cooler, pressed: true, to: controller)
        send(.cooler, pressed: false, to: controller)
        #expect(readout.shown.last?.text == "Color Temp 100%")
    }

    /// The readout's bar is the slider's fill: the white point counts 0 to 100 % of its own
    /// scale, as the status reports it.
    @Test func aWhitePointStepFillsTheReadoutAsTheSliderShowsIt() {
        let (controller, manager) = makeController()
        manager.setAll(on: true)
        send(.dimmer, pressed: true, to: controller)
        send(.dimmer, pressed: false, to: controller)
        #expect(readout.shown.last?.text == "White Point 95%")
        #expect(readout.shown.last?.level.map { abs($0 - 0.95) < 1e-9 } == true)
    }

    @Test func aResentPressWhileHeldDoesNotStepTwice() {
        let (controller, manager) = makeController()
        send(.warmer, pressed: true, to: controller)
        send(.warmer, pressed: true, to: controller)
        #expect(abs(manager.intensity - 0.95) < 1e-9)
        send(.warmer, pressed: false, to: controller)
        send(.warmer, pressed: true, to: controller)
        #expect(abs(manager.intensity - 0.90) < 1e-9)
        send(.warmer, pressed: false, to: controller)
    }

    @Test func rollingOntoAnotherStepKeyStepsItAndKeepsItRepeating() {
        let (controller, manager) = makeController()
        send(.warmer, pressed: true, to: controller)
        send(.dimmer, pressed: true, to: controller)   // pressed before Warmer is released
        #expect(abs(manager.intensity - 0.95) < 1e-9)
        // Five percent of the white point's own scale: 95 % of the way from 0.25 to 1.
        #expect(abs(manager.whitepoint - 0.9625) < 1e-9)
        // A repeat event from the older held key must leave Dimmer in control.
        send(.warmer, pressed: true, to: controller)
        #expect(abs(manager.intensity - 0.95) < 1e-9)
        send(.warmer, pressed: false, to: controller)
        // Dimmer is still held and repeating, so a resent press must not step again.
        send(.dimmer, pressed: true, to: controller)
        #expect(abs(manager.whitepoint - 0.9625) < 1e-9)
        send(.dimmer, pressed: false, to: controller)
        send(.dimmer, pressed: true, to: controller)
        #expect(abs(manager.whitepoint - 0.925) < 1e-9)
        send(.dimmer, pressed: false, to: controller)
    }

    @Test func leavingTheWindowEndsRecordingAndRestoresHotkeys() {
        let (controller, _) = makeController()
        let window = ShortcutsWindowController(store: controller.store)
        controller.store.isRecording = true
        #expect(hotkeys.registered.isEmpty)
        window.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(!controller.store.isRecording)
        #expect(hotkeys.registered.count == 7)
    }

    @Test func tapPausesAndResumesWhileHoldOnlyPeeks() {
        let (controller, manager) = makeController()
        manager.setAll(on: true)

        send(.pause, pressed: true, to: controller)
        uptime.now += 0.1
        send(.pause, pressed: false, to: controller)
        #expect(manager.isPaused)
        #expect(readout.shown.last?.text == "Paused · 30 min")

        send(.pause, pressed: true, to: controller)
        send(.pause, pressed: false, to: controller)
        #expect(!manager.isPaused)
        #expect(readout.shown.last?.text == "Resumed")

        send(.pause, pressed: true, to: controller)
        uptime.now += 2
        send(.pause, pressed: false, to: controller)
        #expect(!manager.isPaused)
        #expect(manager.isFiltering)
    }

    @Test func holdingPauseDuringAnExistingPausePreservesItsDeadline() {
        let (controller, manager) = makeController()
        manager.setAll(on: true)
        manager.pause(for: 7200)
        let deadline = manager.pausedUntil
        send(.pause, pressed: true, to: controller)
        #expect(manager.isPaused)
        uptime.now += 2
        send(.pause, pressed: false, to: controller)
        #expect(manager.pausedUntil == deadline)
    }

    @Test func aHoldWithoutKeyStateOrReleaseEventuallyRestoresTheTint() async throws {
        let gamma = MockGammaController()
        let (controller, manager) = makeController(gamma: gamma)
        manager.intensity = 0.4
        manager.setAll(on: true)
        hotkeys.keyDown = false
        gamma.restoreCalls.removeAll()

        send(.pause, pressed: true, to: controller)
        #expect(gamma.restoreCalls.contains(1))
        gamma.applyCalls.removeAll()

        uptime.now += ShortcutController.untrackedHoldLimit
        // The loop ends as soon as the tint is back; the deadline only bounds a failure. A
        // long one keeps a busy parallel run from starving the main run loop past it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while gamma.applyCalls.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(gamma.applyCalls.last?.intensity == Float(0.4))
        #expect(!manager.isPaused)
        #expect(controller.store.shortcut(for: .pause) != nil)
    }

    @Test func stepsAndPauseKeepWorkingInAnAppThatPauses() {
        let (controller, manager) = makeController()
        manager.setAll(on: true)
        manager.setActiveApp(.photoshop(.pause))
        send(.warmer, pressed: true, to: controller)
        send(.warmer, pressed: false, to: controller)
        #expect(abs(manager.intensity - 0.95) < 1e-9)
        #expect(readout.shown.last?.text == "Color Temp 95% · Off for Photoshop")

        // A held peek changes nothing visible, and releasing it leaves the app's rule.
        send(.pause, pressed: true, to: controller)
        uptime.now += 2
        send(.pause, pressed: false, to: controller)
        #expect(manager.isPausedForApp)
        send(.pause, pressed: true, to: controller)
        uptime.now += 0.1
        send(.pause, pressed: false, to: controller)
        #expect(manager.isPaused)
        send(.warmer, pressed: true, to: controller)
        send(.warmer, pressed: false, to: controller)
        #expect(readout.shown.last?.text == "Color Temp 90% · Paused")
        send(.pause, pressed: true, to: controller)
        send(.pause, pressed: false, to: controller)
        #expect(!manager.isPaused)
        #expect(manager.isPausedForApp)
    }

    /// The step keys are pressed while using the app in front: under its Hold or Shift they
    /// edit that app's rule, while the command line's steps stay global.
    @Test func stepKeysEditTheRuleOfTheAppInFrontAndTheCommandLineStaysGlobal() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let (controller, manager, apps, handler) = makeController(appSource: source)
        let rules = try #require(apps)
        manager.setAll(on: true)
        manager.intensity = 0.6
        try rules.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))

        send(.warmer, pressed: true, to: controller)
        send(.warmer, pressed: false, to: controller)
        #expect(rules.rule(for: "com.adobe.Photoshop") == .hold(color: 35, whitepoint: 70))
        #expect(manager.intensity == 0.6, "the global value is untouched")
        #expect(readout.shown.last?.text == "Color Temp 35% · Photoshop: Hold")
        send(.dimmer, pressed: true, to: controller)
        send(.dimmer, pressed: false, to: controller)
        #expect(rules.rule(for: "com.adobe.Photoshop") == .hold(color: 35, whitepoint: 65))

        // The command line, as scripts use it, does not depend on the app in front.
        _ = try handler.execute(.step(.color, -10))
        #expect(abs(manager.intensity - 0.5) < 1e-9)
        #expect(rules.rule(for: "com.adobe.Photoshop") == .hold(color: 35, whitepoint: 65))

        // A Shift moves what is shown; at the end of the slider a held key stops.
        try rules.set("com.adobe.Photoshop", .shift(color: 0, whitepoint: 0))
        send(.cooler, pressed: true, to: controller)
        send(.cooler, pressed: false, to: controller)
        #expect(rules.rule(for: "com.adobe.Photoshop") == .shift(color: 5, whitepoint: 0))
        #expect(readout.shown.last?.text == "Color Temp 55% · Photoshop: Shift")
        try rules.set("com.adobe.Photoshop", .hold(color: 100, whitepoint: 70))
        send(.cooler, pressed: true, to: controller)
        send(.cooler, pressed: false, to: controller)
        #expect(rules.rule(for: "com.adobe.Photoshop") == .hold(color: 100, whitepoint: 70))

        // A Shift already past the end of the slider stays as saved, and a held key stops.
        manager.intensity = 0.8
        try rules.set("com.adobe.Photoshop", .shift(color: 50, whitepoint: 0))
        send(.cooler, pressed: true, to: controller)
        send(.cooler, pressed: false, to: controller)
        #expect(rules.rule(for: "com.adobe.Photoshop") == .shift(color: 50, whitepoint: 0))
        #expect(readout.shown.last?.text == "Color Temp 100% · Photoshop: Shift")
        try rules.set("com.adobe.Photoshop", .hold(color: 100, whitepoint: 70))
        manager.intensity = 0.5

        // Elsewhere the keys are global again.
        source.activate(.safari)
        send(.warmer, pressed: true, to: controller)
        send(.warmer, pressed: false, to: controller)
        #expect(abs(manager.intensity - 0.45) < 1e-9)
        #expect(rules.rule(for: "com.adobe.Photoshop") == .hold(color: 100, whitepoint: 70))
    }

    @Test func pauseWhileOffExplainsInsteadOfPeeking() {
        let (controller, manager) = makeController()
        send(.pause, pressed: true, to: controller)
        send(.pause, pressed: false, to: controller)
        #expect(!manager.isPaused)
        #expect(readout.shown.last?.text == "Redlight Is Off")
    }

    @Test func toggleReportsTheNewState() {
        let (controller, manager) = makeController()
        send(.toggle, pressed: true, to: controller)
        #expect(manager.isOn)
        #expect(readout.shown.last?.text == "Redlight On")
        send(.toggle, pressed: true, to: controller)
        #expect(manager.isOn)
        send(.toggle, pressed: false, to: controller)
        send(.toggle, pressed: true, to: controller)
        #expect(readout.shown.last?.text == "Redlight Off")
    }

    @Test func thePresetShortcutShowsThePresetName() {
        let (controller, manager) = makeController()
        controller.store.set(KeyShortcut(keyCode: UInt32(kVK_F13), modifiers: 0), for: .presetLate)
        send(.presetLate, pressed: true, to: controller)
        #expect(manager.activePresetIndex == 4)
        #expect(readout.shown.last?.text == "Late")
    }
}
