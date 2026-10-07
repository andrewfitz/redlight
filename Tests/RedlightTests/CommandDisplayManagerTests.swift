import Testing
import Foundation
import CoreGraphics
@testable import Redlight

/// Retained by each suite fixture, so cleanup runs after the test's managers are released.
final class TestDefaultsRegistry {
    private var suites: [(name: String, defaults: UserDefaults)] = []

    func makeDefaults(prefix: String = "RedlightTests") -> UserDefaults {
        let name = "\(prefix)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        suites.append((name, defaults))
        return defaults
    }

    deinit {
        for suite in suites {
            suite.defaults.removePersistentDomain(forName: suite.name)
            suite.defaults.synchronize()
        }
    }
}

@MainActor @Suite struct CommandDisplayManagerTests {
    let defaultsRegistry = TestDefaultsRegistry()

    func freshDefaults() -> UserDefaults {
        defaultsRegistry.makeDefaults(prefix: "CommandDisplayManagerTests")
    }

    @Test func fixtureCleanupRemovesSynchronizedTestPreferences() {
        var registry: TestDefaultsRegistry? = TestDefaultsRegistry()
        let defaults = registry!.makeDefaults(prefix: "RedlightDefaultsCleanupTests")
        defaults.set(true, forKey: "redlight.cleanupMarker")
        defaults.synchronize()
        #expect(defaults.bool(forKey: "redlight.cleanupMarker"))
        registry = nil
        #expect(defaults.object(forKey: "redlight.cleanupMarker") == nil)
    }

    func makeManager(
        ids: @escaping () -> [CGDirectDisplayID] = { [1, 2] },
        keys: @escaping (CGDirectDisplayID) -> String = { "monitor-\($0)" },
        main: @escaping () -> CGDirectDisplayID = { 1 },
        defaults: UserDefaults,
        gamma: MockGammaController = MockGammaController(),
        location: FakeLocationProvider = FakeLocationProvider(),
        fadeDuration: TimeInterval = 0,
        uptime: @escaping () -> TimeInterval = { 0 },
        locationPromptActivation: @escaping () -> Void = {},
        onChange: @escaping (Bool) -> Void = { _ in }
    ) -> DisplayManager {
        DisplayManager(
            gamma: gamma, getDisplayIDs: ids, getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: keys, getMainDisplayID: main,
            defaults: defaults, location: location,
            now: { ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")! },
            adaptiveTransitionDuration: fadeDuration, displayTransitionDuration: fadeDuration,
            transitionUptime: uptime, locationPromptActivation: locationPromptActivation,
            onMasterStateChange: onChange)
    }

    @Test func persistedAdaptiveRequestsPermissionWithLaunchControlledActivation() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        let location = FakeLocationProvider()
        location.authorization = .notDetermined
        var activationCount = 0
        let manager = makeManager(
            defaults: defaults, location: location,
            locationPromptActivation: { activationCount += 1 })
        #expect(manager.adaptiveEnabled)
        #expect(location.requestCount == 1)
        #expect(activationCount == 1)
        manager.adaptiveEnabled = false
        manager.adaptiveEnabled = true
        #expect(location.requestCount == 2)
        #expect(activationCount == 1)

        let backgroundLocation = FakeLocationProvider()
        backgroundLocation.authorization = .notDetermined
        let backgroundManager = makeManager(
            defaults: defaults, location: backgroundLocation, locationPromptActivation: {})
        #expect(backgroundManager.adaptiveEnabled)
        #expect(backgroundLocation.requestCount == 1)
        #expect(activationCount == 1)
    }

    @Test func startupPublishesRestoredFlagsBeforeReloadAndSkipsUnchangedSaves() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: "redlight.isOn")
        defaults.set(true, forKey: "redlight.display.monitor-2.enabled")
        var publications: [Bool] = []
        let manager = makeManager(defaults: defaults, onChange: { state in
            #expect(defaults.bool(forKey: "redlight.isOn") == state)
            publications.append(state)
        })
        #expect(manager.isOn)
        #expect(publications == [true])
        manager.intensity = 0.3
        manager.whitepoint = 0.5
        manager.refreshDisplays()
        #expect(publications == [true])
        manager.setEnabled(false, for: 2)
        #expect(publications == [true, false])
    }

    @Test func topologyPublishesDisconnectAndReconnectWithoutSettingsSave() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "redlight.display.monitor-2.enabled")
        var ids: [CGDirectDisplayID] = [1, 2]
        var publications: [Bool] = []
        let manager = makeManager(ids: { ids }, defaults: defaults,
                                  onChange: { publications.append($0) })
        ids = [1]
        manager.refreshDisplays()
        #expect(!manager.isOn)
        #expect(!defaults.bool(forKey: "redlight.isOn"))
        ids = [1, 2]
        manager.refreshDisplays()
        #expect(manager.isOn)
        #expect(publications == [true, false, true])
    }

    @Test func offOffOnRemembersOnlyEnabledDisplaysAndPreservesInversion() {
        let defaults = freshDefaults()
        let manager = makeManager(defaults: defaults)
        manager.setEnabled(true, for: 2)
        manager.setInverted(true, for: 1)
        manager.setAll(on: false)
        manager.setAll(on: false)
        #expect(!manager.isOn)
        #expect(defaults.stringArray(forKey: "redlight.masterEnabledDisplays") == ["monitor-2"])
        manager.setAll(on: true)
        #expect(!manager.displays[0].isEnabled)
        #expect(manager.displays[1].isEnabled)
        #expect(manager.displays[0].isInverted)
        manager.setAll(on: true)
        #expect(!manager.displays[0].isEnabled)
    }

    @Test func offWhileAlreadyOffClearsDisconnectedStableAndLegacyFlags() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "redlight.display.monitor-9.enabled")
        defaults.set(true, forKey: "redlight.display.9.enabled")
        defaults.set(true, forKey: "redlight.display.monitor-9.inverted")
        defaults.set(["monitor-2"], forKey: "redlight.masterEnabledDisplays")
        var ids: [CGDirectDisplayID] = [1]
        let manager = makeManager(ids: { ids }, defaults: defaults)
        #expect(!manager.isOn)
        manager.setAll(on: false)
        #expect(!defaults.bool(forKey: "redlight.display.monitor-9.enabled"))
        #expect(!defaults.bool(forKey: "redlight.display.9.enabled"))
        #expect(defaults.stringArray(forKey: "redlight.masterEnabledDisplays") == ["monitor-2"])
        ids = [1, 9]
        manager.refreshDisplays()
        #expect(!manager.displays[1].isEnabled)
        #expect(manager.displays[1].isInverted)
    }

    @Test func offClearsCachedAndLegacyFlagsAcrossReconnectAndAnotherSave() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "redlight.display.2.enabled")
        var ids: [CGDirectDisplayID] = [1, 2]
        let manager = makeManager(ids: { ids }, defaults: defaults)
        manager.intensity = 0.4 // fill the persistence cache while enabled
        ids = [1]
        manager.refreshDisplays()
        manager.setAll(on: false)
        ids = [1, 2]
        manager.refreshDisplays()
        manager.whitepoint = 0.5
        #expect(!manager.displays[1].isEnabled)
        #expect(!defaults.bool(forKey: "redlight.display.monitor-2.enabled"))
        #expect(!defaults.bool(forKey: "redlight.display.2.enabled"))
        manager.setEnabled(true, for: 2)
        #expect(defaults.bool(forKey: "redlight.display.monitor-2.enabled"))
    }

    @Test func rememberedSelectionSurvivesRelaunchAndCoreGraphicsIDChanges() {
        let defaults = freshDefaults()
        let manager = makeManager(defaults: defaults)
        manager.setEnabled(true, for: 2)
        manager.setAll(on: false)
        let restarted = makeManager(
            ids: { [31, 32] }, keys: { $0 == 31 ? "monitor-1" : "monitor-2" },
            main: { 31 }, defaults: defaults)
        restarted.setAll(on: true)
        #expect(!restarted.displays[0].isEnabled)
        #expect(restarted.displays[1].isEnabled)
    }

    @Test func onFallsBackToMainOrFirstWhenRememberedDisplaysAreMissing() {
        let defaults = freshDefaults()
        defaults.set(["missing-monitor"], forKey: "redlight.masterEnabledDisplays")
        let manager = makeManager(main: { 2 }, defaults: defaults)
        manager.setAll(on: true)
        #expect(!manager.displays[0].isEnabled)
        #expect(manager.displays[1].isEnabled)
        manager.setAll(on: false)
        let restarted = makeManager(ids: { [7, 8] }, main: { 99 }, defaults: defaults)
        restarted.setAll(on: true)
        #expect(restarted.displays[0].isEnabled)
        #expect(!restarted.displays[1].isEnabled)
    }

    @Test func onWithNoConnectedDisplaysDoesNotInventState() {
        let defaults = freshDefaults()
        let manager = makeManager(ids: { [] }, defaults: defaults)
        manager.setAll(on: true)
        #expect(!manager.isOn)
        #expect(!defaults.bool(forKey: "redlight.isOn"))
    }

    @Test func fadeStatusIncludesDisplayAndOutputTransitionsAndReportsTargets() throws {
        let defaults = freshDefaults()
        let gamma = MockGammaController()
        let location = FakeLocationProvider()
        location.coordinate = (0, 0)
        var uptime: TimeInterval = 0
        let manager = makeManager(defaults: defaults, gamma: gamma, location: location,
                                  fadeDuration: 2, uptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.setEnabled(true, for: 1)
        #expect(manager.commandIsFading)
        uptime = 1
        manager.tickTransitions()
        #expect(manager.commandTargetOutput == .init(intensity: 0.4, whitepoint: 0.5))
        let midFrame = try #require(gamma.applyCalls.last)
        #expect(abs(Double(midFrame.intensity) - 0.7) < 0.0001)
        manager.completeDisplayTransitions()
        #expect(!manager.commandIsFading)
        manager.adaptiveEnabled = true
        #expect(manager.commandIsFading)
        let target = manager.commandTargetOutput
        #expect(target.intensity > 0.9)
        uptime += 1
        manager.tickTransitions()
        #expect(manager.commandTargetOutput == target)
        manager.completeOutputTransition()
        #expect(!manager.commandIsFading)
    }

    @Test func interruptClearsBothPreviewsFlushesBandsAndInvalidatesOnlyOldGesture() throws {
        let defaults = freshDefaults()
        let gamma = MockGammaController()
        let manager = makeManager(defaults: defaults, gamma: gamma)
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.setEnabled(true, for: 1)
        let token = manager.beginSliderInteraction()
        manager.adaptiveMax = 0.8
        manager.previewIntensity(0.2)
        manager.previewWhitepoint(0.3)
        #expect(manager.isSliderInteractionCurrent(token))
        manager.interruptSliderInteraction()
        #expect(!manager.isSliderInteractionCurrent(token))
        #expect(defaults.double(forKey: "redlight.adaptiveMax") == 0.8)
        manager.intensity = 0.7
        let call = try #require(gamma.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5) < 0.0001)
        // The UI tests this token before writing any further values from the old drag.
        if manager.isSliderInteractionCurrent(token) { manager.intensity = 0.1 }
        #expect(manager.intensity == 0.7)
        let freshToken = manager.beginSliderInteraction()
        #expect(freshToken != token)
        #expect(manager.isSliderInteractionCurrent(freshToken))
        if manager.isSliderInteractionCurrent(freshToken) { manager.intensity = 0.6 }
        #expect(manager.intensity == 0.6)
    }

    @Test func stoppedPublicationPreservesSavedFlagsAndRestartPublishesRestoredState() {
        let defaults = freshDefaults()
        var publications: [Bool] = []
        let manager = makeManager(defaults: defaults, onChange: { publications.append($0) })
        manager.setEnabled(true, for: 2)
        manager.beginTerminationFade {}
        manager.publishStoppedState()
        manager.publishStoppedState()
        #expect(!defaults.bool(forKey: "redlight.isOn"))
        #expect(defaults.bool(forKey: "redlight.display.monitor-2.enabled"))
        #expect(publications == [false, true, false])
        let restarted = makeManager(defaults: defaults, onChange: { publications.append($0) })
        #expect(restarted.isOn)
        #expect(defaults.bool(forKey: "redlight.isOn"))
        #expect(publications == [false, true, false, true])
    }

    @Test func terminatingRejectsModelCommandsAndInvalidatesDragging() {
        let defaults = freshDefaults()
        let manager = makeManager(defaults: defaults)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 2)
        let token = manager.beginSliderInteraction()
        manager.beginTerminationFade {}
        manager.setAll(on: false)
        manager.setEnabled(false, for: 2)
        manager.setInverted(true, for: 1)
        manager.applyPreset(4)
        manager.saveToPreset(0)
        manager.previewIntensity(0.1)
        #expect(manager.displays[1].isEnabled)
        #expect(!manager.displays[0].isInverted)
        #expect(manager.intensity == 0.4)
        #expect(!manager.isSliderInteractionCurrent(token))
    }
}
