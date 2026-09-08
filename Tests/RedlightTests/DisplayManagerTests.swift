import Testing
import Foundation
import CoreGraphics
@testable import Redlight

final class MockGammaController: GammaControlling {
    var applyCalls: [(displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool)] = []
    var restoreCalls: [CGDirectDisplayID] = []
    var restoreAllCount = 0

    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool) {
        applyCalls.append((displayID, intensity, whitepoint, invert))
    }

    func restore(_ displayID: CGDirectDisplayID) {
        restoreCalls.append(displayID)
    }

    func restoreAll() {
        restoreAllCount += 1
    }
}

final class FakeLocationProvider: LocationProviding {
    var coordinate: (latitude: Double, longitude: Double)?
    var authorization: LocationAuthorization = .authorized
    var onChange: (() -> Void)?
    var isApproximate = false
    var requestCount = 0
    func requestWhenInUse() { requestCount += 1 }
}

@MainActor @Suite struct DisplayManagerTests {
    let mock = MockGammaController()
    let fakeLocation = FakeLocationProvider()

    func makeManager(
        displayIDs: [CGDirectDisplayID] = [1],
        defaults: UserDefaults? = nil,
        location: LocationProviding? = nil,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 0) },
        transitionDuration: TimeInterval = 0,
        displayTransitionDuration: TimeInterval = 0,
        transitionUptime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) -> DisplayManager {
        let d = defaults ?? freshDefaults()
        return DisplayManager(
            gamma: mock,
            getDisplayIDs: { displayIDs },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: d,
            location: location ?? fakeLocation,
            now: now,
            adaptiveTransitionDuration: transitionDuration,
            displayTransitionDuration: displayTransitionDuration,
            transitionUptime: transitionUptime
        )
    }

    func freshDefaults() -> UserDefaults {
        let name = "RedlightTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func neutralEnabledFilterLeavesColorSyncUntouched() {
        let manager = makeManager()
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()
        manager.toggle(1)

        #expect(mock.applyCalls.isEmpty)
        #expect(mock.restoreCalls == [1])
    }

    @Test func nonNeutralEnabledFilterAppliesGamma() {
        let manager = makeManager()
        manager.intensity = 0.7
        mock.applyCalls.removeAll()

        manager.toggle(1)

        #expect(mock.applyCalls.count == 1)
        #expect(mock.applyCalls[0].displayID == 1)
        #expect(mock.applyCalls[0].intensity == Float(0.7))
    }

    @Test func defaultsAreAnUnfilteredDisplay() {
        // "Default" must mean no filter at all — 1.0 intensity is an untouched display
        // (0.0 is pure red), and 1.0 whitepoint is no reduction.
        #expect(DisplayManager.Defaults.intensity == 1.0)
        #expect(DisplayManager.Defaults.whitepoint == 1.0)
        #expect(DisplayManager.Defaults.whitepointMin == 0.3)
        #expect(DisplayManager.Defaults.adaptiveFadeDuration == 2.0)
        #expect(DisplayManager.Defaults.displayFadeDuration == 0.7)
    }

    @Test func resetRestoresUnfilteredDefaults() {
        let manager = makeManager()
        manager.intensity = 0.2
        manager.whitepoint = 0.4
        manager.adaptiveMin = 0.3
        manager.adaptiveMax = 0.8
        manager.adaptiveWpMin = 0.5
        manager.adaptiveWpMax = 0.9

        manager.resetIntensity()
        manager.resetWhitepoint()

        #expect(manager.intensity == 1.0)
        #expect(manager.whitepoint == 1.0)
        #expect(manager.intensityBand == 0.0...1.0)
        #expect(manager.whitepointBand == 0.3...1.0)
        #expect(manager.intensityIsDefault)
        #expect(manager.whitepointIsDefault)
    }

    @Test func toggleOffSingleDisplayRestoresThatDisplay() {
        let manager = makeManager()
        manager.toggle(1) // on
        mock.restoreCalls.removeAll()

        manager.toggle(1) // off

        #expect(mock.restoreCalls == [1])
    }

    @Test func toggleOffLeavesOtherDisplaysUntouched() {
        let manager = makeManager(displayIDs: [1, 2])
        manager.toggle(1)
        manager.toggle(2)
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()

        manager.toggle(1) // off — restore only display 1

        #expect(mock.restoreCalls == [1])
        #expect(manager.displays.first { $0.id == 2 }?.isEnabled == true)
    }

    @Test func displayToggleFadesInAndOutOverSevenTenths() throws {
        var uptime: TimeInterval = 10
        let manager = makeManager(
            displayTransitionDuration: DisplayManager.Defaults.displayFadeDuration,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()

        manager.toggle(1)
        #expect(manager.displays[0].isEnabled)
        #expect(manager.isAnyActive)
        #expect(mock.applyCalls.isEmpty)  // amount 0 starts from the untouched display

        uptime += 0.35
        manager.tickDisplayTransitions()
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.75) < 0.0001)

        uptime += 0.36
        manager.tickDisplayTransitions()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5) < 0.0001)

        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()
        manager.toggle(1)
        call = try #require(mock.applyCalls.last)
        #expect(!manager.displays[0].isEnabled)   // checkbox endpoint persists immediately
        #expect(manager.isAnyActive)              // tray remains active until fade-out ends
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)
        #expect(mock.restoreCalls.isEmpty)

        uptime += 0.35
        manager.tickDisplayTransitions()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.75) < 0.0001)

        uptime += 0.36
        manager.tickDisplayTransitions()
        #expect(mock.restoreCalls == [1])
        #expect(!manager.isAnyActive)
    }

    @Test func enabledDisplayFadesInOnStartupWithoutChangingPersistence() throws {
        let defaults = freshDefaults()
        defaults.set(0.4, forKey: "redlight.intensity")
        defaults.set(0.5, forKey: "redlight.whitepoint")
        defaults.set(true, forKey: "redlight.display.1.enabled")
        var uptime: TimeInterval = 15

        let manager = makeManager(
            defaults: defaults,
            displayTransitionDuration: 0.7,
            transitionUptime: { uptime })

        #expect(manager.displays[0].isEnabled)
        #expect(defaults.bool(forKey: "redlight.display.1.enabled"))
        #expect(mock.applyCalls.isEmpty)
        #expect(mock.restoreCalls.last == 1)     // first launch frame is calibrated/neutral

        mock.restoreCalls.removeAll()
        uptime += 0.35
        manager.tickTransitions()
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.75) < 0.0001)

        uptime += 0.35
        manager.tickTransitions()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5) < 0.0001)
        #expect(defaults.bool(forKey: "redlight.display.1.enabled"))
    }

    @Test func adaptiveStartupFadeUsesCurrentSolarTargetWithoutFullFlash() throws {
        let defaults = freshDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(true, forKey: "redlight.display.1.enabled")
        defaults.set(1.0, forKey: "redlight.intensity")  // deliberately stale daytime value
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let midnight = ISO8601DateFormatter().date(from: "2025-03-21T00:00:00Z")!
        var uptime: TimeInterval = 16

        let manager = makeManager(
            defaults: defaults,
            location: location,
            now: { midnight },
            displayTransitionDuration: 0.7,
            transitionUptime: { uptime })

        #expect(manager.intensity < 0.5)          // logical target is already current solar red
        #expect(mock.applyCalls.isEmpty)          // but the first rendered frame is neutral
        let target = manager.intensity

        uptime += 0.35
        manager.tickTransitions()
        var call = try #require(mock.applyCalls.last)
        #expect(Double(call.intensity) > target && Double(call.intensity) < 1)

        uptime += 0.35
        manager.tickTransitions()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - target) < 0.0001)
    }

    @Test func terminationFadesOutAndPreservesEnabledCheckbox() throws {
        let defaults = freshDefaults()
        var uptime: TimeInterval = 17
        let manager = makeManager(
            defaults: defaults,
            displayTransitionDuration: 0.7,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggle(1)
        manager.completeDisplayTransitions()
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()

        var completionCount = 0
        manager.beginTerminationFade { completionCount += 1 }
        #expect(manager.isTerminating)
        #expect(manager.displays[0].isEnabled)
        #expect(defaults.bool(forKey: "redlight.display.1.enabled"))
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)  // no quit-edge jump
        #expect(completionCount == 0)

        uptime += 0.35
        manager.tickTransitions()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.75) < 0.0001)
        #expect(completionCount == 0)

        uptime += 0.35
        manager.tickTransitions()
        #expect(mock.restoreCalls.last == 1)
        #expect(mock.restoreAllCount == 1)
        #expect(completionCount == 1)
        #expect(defaults.bool(forKey: "redlight.display.1.enabled"))

        manager.tickTransitions()
        #expect(completionCount == 1)
        #expect(mock.restoreAllCount == 1)
    }

    @Test func terminationFreezesCurrentAdaptiveFrameWhileFadingOut() throws {
        var uptime: TimeInterval = 18
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            location: location,
            now: { noon },
            transitionDuration: 2,
            displayTransitionDuration: 0.7,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggle(1)
        manager.completeDisplayTransitions()
        manager.adaptiveEnabled = true

        uptime += 1
        manager.tickTransitions()               // current Adaptive frame = 0.7 / 0.75
        let before = try #require(mock.applyCalls.last)
        #expect(abs(Double(before.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(before.whitepoint) - 0.75) < 0.0001)

        manager.beginTerminationFade {}
        let start = try #require(mock.applyCalls.last)
        #expect(abs(start.intensity - before.intensity) < 0.0001)
        #expect(abs(start.whitepoint - before.whitepoint) < 0.0001)

        uptime += 0.35
        manager.tickTransitions()
        let halfway = try #require(mock.applyCalls.last)
        #expect(abs(Double(halfway.intensity) - 0.85) < 0.0001)
        #expect(abs(Double(halfway.whitepoint) - 0.875) < 0.0001)
    }

    @Test func terminationStartsFromLastRenderedFrameAfterRunLoopDelay() throws {
        var uptime: TimeInterval = 20
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            location: location,
            now: { noon },
            transitionDuration: 2,
            displayTransitionDuration: 0.7,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggle(1)
        manager.adaptiveEnabled = true

        uptime += 0.175
        manager.tickTransitions()
        let lastRendered = try #require(mock.applyCalls.last)

        uptime += 0.35                         // time advances, but no frame gets rendered
        manager.beginTerminationFade {}
        let quitStart = try #require(mock.applyCalls.last)

        #expect(abs(quitStart.intensity - lastRendered.intensity) < 0.0001)
        #expect(abs(quitStart.whitepoint - lastRendered.whitepoint) < 0.0001)
        #expect(quitStart.invert == lastRendered.invert)
    }

    @Test func terminationPersistsPendingBandMarkerEdit() {
        let defaults = freshDefaults()
        let manager = makeManager(defaults: defaults)
        manager.adaptiveMin = 0.35
        manager.adaptiveMax = 0.8

        manager.beginTerminationFade {}

        #expect(abs(defaults.double(forKey: "redlight.adaptiveMin") - 0.35) < 1e-9)
        #expect(abs(defaults.double(forKey: "redlight.adaptiveMax") - 0.8) < 1e-9)
        let relaunched = makeManager(defaults: defaults)
        #expect(abs(relaunched.adaptiveMin - 0.35) < 1e-9)
        #expect(abs(relaunched.adaptiveMax - 0.8) < 1e-9)
    }

    @Test func disconnectingLastMonitorCompletesTerminationFade() {
        let uptime: TimeInterval = 19
        var ids: [CGDirectDisplayID] = [1, 2]
        let defaults = freshDefaults()
        let manager = DisplayManager(
            gamma: mock,
            getDisplayIDs: { ids },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: defaults,
            location: FakeLocationProvider(),
            displayTransitionDuration: 0.7,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.toggle(2)
        manager.completeDisplayTransitions()

        var completed = false
        manager.beginTerminationFade { completed = true }
        ids = [1]
        manager.refreshDisplays()

        #expect(completed)
        #expect(mock.restoreAllCount == 1)
        #expect(defaults.bool(forKey: "redlight.display.2.enabled"))
    }

    @Test func rapidDisplayRetoggleContinuesFromCurrentFadeFrame() throws {
        var uptime: TimeInterval = 20
        let manager = makeManager(
            displayTransitionDuration: 1,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggle(1)
        uptime += 1
        manager.tickDisplayTransitions()  // fully on

        manager.toggle(1)                 // begin fading out
        uptime += 0.5
        manager.tickDisplayTransitions()
        let before = try #require(mock.applyCalls.last)
        #expect(abs(Double(before.intensity) - 0.7) < 0.0001)

        manager.toggle(1)                 // reverse from exactly that rendered amount
        var after = try #require(mock.applyCalls.last)
        #expect(abs(after.intensity - before.intensity) < 0.0001)
        #expect(abs(after.whitepoint - before.whitepoint) < 0.0001)

        uptime += 0.5
        manager.tickDisplayTransitions()
        after = try #require(mock.applyCalls.last)
        #expect(Double(after.intensity) < Double(before.intensity))
        #expect(Double(after.whitepoint) < Double(before.whitepoint))
        manager.completeDisplayTransitions()
        after = try #require(mock.applyCalls.last)
        #expect(abs(Double(after.intensity) - 0.4) < 0.0001)
        #expect(manager.displays[0].isEnabled)
    }

    @Test func displayFadeKeepsInvertAndEndsAtPureInvert() throws {
        var uptime: TimeInterval = 30
        let manager = makeManager(
            displayTransitionDuration: 1,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggleInvert(1)
        manager.toggle(1)
        uptime += 1
        manager.tickDisplayTransitions()
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()

        manager.toggle(1)
        uptime += 0.5
        manager.tickDisplayTransitions()
        var call = try #require(mock.applyCalls.last)
        #expect(call.invert)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)

        uptime += 0.5
        manager.tickDisplayTransitions()
        call = try #require(mock.applyCalls.last)
        #expect(call.invert)
        #expect(call.intensity == 1)
        #expect(call.whitepoint == 1)
        #expect(mock.restoreCalls.isEmpty)
    }

    @Test func displayFadeComposesWithAdaptiveFade() throws {
        var uptime: TimeInterval = 40
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            location: location,
            now: { noon },
            transitionDuration: 2,
            displayTransitionDuration: 1,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5

        manager.toggle(1)
        uptime += 0.5
        manager.tickDisplayTransitions()       // monitor amount = 0.5
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.75) < 0.0001)

        manager.adaptiveEnabled = true         // equatorial noon target = 1 / 1
        manager.advanceOutputTransition(toProgress: 0.5)
        call = try #require(mock.applyCalls.last)
        // Global output is now 0.7 / 0.75, still mixed through the monitor's 0.5 amount.
        #expect(abs(Double(call.intensity) - 0.85) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.875) < 0.0001)

        manager.advanceDisplayTransitions(toProgress: 1)
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.75) < 0.0001)
        manager.completeOutputTransition()
    }

    @Test func sharedFadeTickIsSingleWriteAndContinuousThroughReversal() throws {
        var uptime: TimeInterval = 50
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            location: location,
            now: { noon },
            transitionDuration: 2,
            displayTransitionDuration: 1,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggle(1)
        manager.adaptiveEnabled = true
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()

        uptime += 0.5
        manager.tickTransitions()
        #expect(mock.applyCalls.count == 1)      // one coherent LUT write, not one per fade
        let before = try #require(mock.applyCalls.last)
        #expect(abs(Double(before.intensity) - 0.746875) < 0.0001)
        #expect(abs(Double(before.whitepoint) - 0.7890625) < 0.0001)

        manager.toggle(1)                       // reverse the monitor while Adaptive moves
        let reversed = try #require(mock.applyCalls.last)
        #expect(abs(reversed.intensity - before.intensity) < 0.0001)
        #expect(abs(reversed.whitepoint - before.whitepoint) < 0.0001)

        mock.applyCalls.removeAll()
        uptime += 0.5
        manager.tickTransitions()
        #expect(mock.applyCalls.count == 1)
        let call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.925) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.9375) < 0.0001)

        uptime += 0.5
        manager.tickTransitions()               // monitor reaches its unfiltered endpoint
        #expect(mock.restoreCalls.last == 1)
        #expect(!manager.displays[0].isEnabled)

        uptime += 0.5
        manager.tickTransitions()               // Adaptive reaches its own endpoint
        #expect(manager.intensity == 1)
        #expect(manager.whitepoint == 1)
    }

    @Test func restoreAllCancelsInFlightFadesBeforeRestoring() {
        var uptime: TimeInterval = 60
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            location: location,
            now: { noon },
            transitionDuration: 2,
            displayTransitionDuration: 1,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.toggle(1)
        manager.adaptiveEnabled = true

        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()
        manager.restoreAllDisplays()
        #expect(mock.restoreAllCount == 1)

        uptime += 3
        manager.tickTransitions()
        manager.completeDisplayTransitions()
        manager.completeOutputTransition()
        #expect(mock.applyCalls.isEmpty)
        #expect(mock.restoreCalls.isEmpty)
        #expect(mock.restoreAllCount == 1)
    }

    @Test func wakeCatchesUpDelayedDisplayFadeBeforeRendering() throws {
        var uptime: TimeInterval = 70
        let manager = makeManager(
            displayTransitionDuration: 1,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggle(1)
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()

        uptime += 2                             // simulate a suspended/delayed run loop
        manager.handleWake()

        let call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5) < 0.0001)
        #expect(mock.restoreCalls.isEmpty)
    }

    @Test func intensityChangeUpdatesActiveDisplaysOnly() {
        let manager = makeManager(displayIDs: [1, 2])
        manager.toggle(1) // enable display 1 only
        mock.applyCalls.removeAll()

        manager.intensity = 0.8

        #expect(mock.applyCalls.count == 1)
        #expect(mock.applyCalls[0].displayID == 1)
        #expect(mock.applyCalls[0].intensity == Float(0.8))
    }

    @Test func isAnyActiveReflectsToggleState() {
        let manager = makeManager(displayIDs: [1, 2])

        #expect(manager.isAnyActive == false)
        manager.toggle(1)
        #expect(manager.isAnyActive == true)
        manager.toggle(1)
        #expect(manager.isAnyActive == false)
    }

    @Test func persistenceRoundTripsIntensity() {
        let d = freshDefaults()
        let manager1 = makeManager(defaults: d)
        manager1.intensity = 0.7

        let manager2 = DisplayManager(
            gamma: mock,
            getDisplayIDs: { [1] },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: d,
            location: FakeLocationProvider()
        )

        #expect(manager2.intensity == 0.7)
    }

    @Test func persistenceRoundTripsDisplayState() {
        let d = freshDefaults()
        let manager1 = makeManager(displayIDs: [1], defaults: d)
        manager1.toggle(1)

        // Second instance picks up persisted state via refreshDisplays() in init
        let manager2 = DisplayManager(
            gamma: mock,
            getDisplayIDs: { [1] },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: d,
            location: FakeLocationProvider()
        )

        #expect(manager2.displays[0].isEnabled == true)
    }

    @Test func displayStateFollowsStableDisplayKeyWhenNumericIDChanges() {
        let d = freshDefaults()
        let first = DisplayManager(
            gamma: mock,
            getDisplayIDs: { [1] },
            getDisplayName: { _ in "Display" },
            getDisplayPersistenceKey: { _ in "physical-display-a" },
            defaults: d,
            location: FakeLocationProvider()
        )
        first.toggle(1)

        let second = DisplayManager(
            gamma: mock,
            getDisplayIDs: { [99] },
            getDisplayName: { _ in "Display" },
            getDisplayPersistenceKey: { _ in "physical-display-a" },
            defaults: d,
            location: FakeLocationProvider()
        )

        #expect(second.displays[0].isEnabled)
    }

    @Test func legacyNumericDisplayKeyMigratesToStableKey() {
        let d = freshDefaults()
        d.set(true, forKey: "redlight.display.7.enabled")

        let manager = DisplayManager(
            gamma: mock,
            getDisplayIDs: { [7] },
            getDisplayName: { _ in "Display" },
            getDisplayPersistenceKey: { _ in "physical-display-b" },
            defaults: d,
            location: FakeLocationProvider()
        )

        #expect(manager.displays[0].isEnabled)
        #expect(d.bool(forKey: "redlight.display.physical-display-b.enabled"))
    }

    @Test func enablingAdaptiveAppliesCurveValueAndRequestsLocation() {
        let loc = FakeLocationProvider()
        loc.coordinate = (0, 0)
        // 2025-03-20 12:00 UTC, equator → daytime → Day preset (intensity 1.0).
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.toggle(1)            // enable red filter on display 1
        mock.applyCalls.removeAll()

        manager.adaptiveEnabled = true

        #expect(loc.requestCount == 1)
        #expect(manager.intensity == 1.0)          // curve drove it to Day
        #expect(mock.applyCalls.isEmpty)           // neutral Day restores ColorSync
        #expect(mock.restoreCalls.last == 1)
    }

    @Test func enablingAdaptiveFortyFiveMinutesBeforeSunsetAppliesCurrentTransition() throws {
        // Nashville in midsummer: the sun is +8.3° and reaches the horizon in about 45m.
        let date = ISO8601DateFormatter().date(from: "2025-07-14T00:15:30Z")!
        let latitude = 36.1627, longitude = -86.7816
        let loc = FakeLocationProvider()
        loc.coordinate = (latitude, longitude)
        let cycle = SunCycle(now: date, latitude: latitude, longitude: longitude)
        let event = try #require(cycle.nextEvent)
        #expect(event.elevation == SolarCurve.warmElevation)
        #expect(event.seconds > 0 && event.seconds < 45 * 60)

        let manager = makeManager(location: loc, now: { date })
        manager.toggle(1)
        mock.applyCalls.removeAll()

        manager.adaptiveEnabled = true

        #expect(loc.requestCount == 1)
        #expect(manager.intensity < manager.intensityBand.upperBound)
        #expect(manager.intensity > manager.intensityBand.lowerBound)
        #expect(manager.whitepoint < manager.whitepointBand.upperBound)
        #expect(manager.whitepoint > manager.whitepointBand.lowerBound)
        #expect(mock.applyCalls.last?.intensity == Float(manager.intensity))
        #expect(mock.applyCalls.last?.whitepoint == Float(manager.whitepoint))
        #expect(manager.adaptiveStatusText.hasPrefix("Following the sun · "))
        #expect(manager.adaptiveStatusText.contains("+8."))
        #expect(!manager.adaptiveStatusText.contains("twilight"))
    }

    @Test func manualSliderSetsBaselineKeepsAdaptive() {
        let loc = FakeLocationProvider()
        loc.coordinate = (0, 0)
        // 2025-03-20 12:00 UTC, equator → daytime → curve intensity 1.0.
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveEnabled = true
        #expect(manager.intensity == 1.0)

        manager.intensity = 0.8    // user nudges down → offset −0.2

        #expect(manager.adaptiveEnabled == true)         // stays adaptive
        manager.applyAdaptive()                          // re-run same instant
        #expect(abs(manager.intensity - 0.8) < 1e-9)     // nudge preserved
    }

    @Test func whitepointSliderSetsBaselineKeepsAdaptive() {
        let loc = FakeLocationProvider()
        loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveEnabled = true

        manager.whitepoint = 0.6   // offset −0.4

        #expect(manager.adaptiveEnabled == true)
        manager.applyAdaptive()
        #expect(abs(manager.whitepoint - 0.6) < 1e-9)
    }

    @Test func adaptiveOffHoldsLiveAdjustedValues() {
        let loc = FakeLocationProvider()
        loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveEnabled = true
        manager.intensity = 0.8    // offset −0.2

        manager.adaptiveEnabled = false
        #expect(abs(manager.intensity - 0.8) < 1e-9)
        manager.adaptiveEnabled = true   // same valid target + offset remains unchanged

        #expect(abs(manager.intensity - 0.8) < 1e-9)
    }

    @Test func adaptiveRoundTripHoldsLivePairLimitsAndOffsets() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.intensity = 0.65
        manager.whitepoint = 0.70
        manager.adaptiveMin = 0.2
        manager.adaptiveMax = 0.8
        manager.adaptiveWpMin = 0.5
        manager.adaptiveWpMax = 0.9

        manager.adaptiveEnabled = true
        #expect(abs(manager.intensity - 0.8) < 1e-9)
        #expect(abs(manager.whitepoint - 0.9) < 1e-9)
        manager.intensity = 0.7                 // retain −0.1 Adaptive nudges
        manager.whitepoint = 0.8

        manager.adaptiveEnabled = false
        #expect(abs(manager.intensity - 0.7) < 1e-9)
        #expect(abs(manager.whitepoint - 0.8) < 1e-9)
        #expect(manager.intensityBand == 0.2...0.8)
        #expect(manager.whitepointBand == 0.5...0.9)

        manager.adaptiveEnabled = true
        #expect(abs(manager.intensity - 0.7) < 1e-9)
        #expect(abs(manager.whitepoint - 0.8) < 1e-9)
        #expect(manager.intensityBand == 0.2...0.8)
        #expect(manager.whitepointBand == 0.5...0.9)
    }

    @Test func adaptiveEnableFadesAndDisableHoldsExactCurrentFrame() throws {
        let defaults = freshDefaults()
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        var uptime: TimeInterval = 10
        let manager = makeManager(
            defaults: defaults,
            location: loc,
            now: { noon },
            transitionDuration: DisplayManager.Defaults.adaptiveFadeDuration,
            transitionUptime: { uptime })
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.adaptiveMax = 0.8
        manager.adaptiveWpMax = 0.9
        manager.toggle(1)
        mock.applyCalls.removeAll()

        manager.adaptiveEnabled = true
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5) < 0.0001)
        #expect(abs(manager.intensity - 0.8) < 1e-9)  // model target is immediate
        #expect(abs(manager.whitepoint - 0.9) < 1e-9)

        uptime += 1
        manager.tickOutputTransition()  // halfway through the production two-second fade
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.6) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.7) < 0.0001)

        let callCountBeforeHold = mock.applyCalls.count
        manager.adaptiveEnabled = false
        #expect(abs(manager.intensity - 0.6) < 1e-9)
        #expect(abs(manager.whitepoint - 0.7) < 1e-9)
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.6) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.7) < 0.0001)
        #expect(mock.applyCalls.count == callCountBeforeHold + 1)
        #expect(!defaults.bool(forKey: "redlight.adaptiveEnabled"))
        #expect(abs(defaults.double(forKey: "redlight.intensity") - 0.6) < 1e-9)
        #expect(abs(defaults.double(forKey: "redlight.whitepoint") - 0.7) < 1e-9)
        #expect(abs(defaults.double(forKey: "redlight.manualIntensity") - 0.6) < 1e-9)
        #expect(abs(defaults.double(forKey: "redlight.manualWhitepoint") - 0.7) < 1e-9)

        let heldCallCount = mock.applyCalls.count
        uptime += 1
        manager.tickOutputTransition()
        #expect(mock.applyCalls.count == heldCallCount)  // no movement after Adaptive is off

        manager.adaptiveEnabled = true
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.6) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.7) < 0.0001)
        #expect(abs(manager.intensity - 0.8) < 1e-9)
        #expect(abs(manager.whitepoint - 0.9) < 1e-9)

        uptime += 1
        manager.tickOutputTransition()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.8) < 0.0001)
        manager.completeOutputTransition()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.8) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.9) < 0.0001)
    }

    @Test func rapidAdaptiveRetoggleContinuesFromCurrentFadeFrame() throws {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon }, transitionDuration: 1)
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.adaptiveMax = 0.8
        manager.adaptiveWpMax = 0.9
        manager.toggle(1)

        manager.adaptiveEnabled = true
        manager.advanceOutputTransition(toProgress: 0.5)  // rendered 0.6 / 0.7
        manager.adaptiveEnabled = false
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.6) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.7) < 0.0001)

        let heldCallCount = mock.applyCalls.count
        manager.advanceOutputTransition(toProgress: 0.5)
        #expect(mock.applyCalls.count == heldCallCount)
        manager.adaptiveEnabled = true
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.6) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.7) < 0.0001)
        manager.advanceOutputTransition(toProgress: 0.5)
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.7) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.8) < 0.0001)
        manager.completeOutputTransition()
    }

    @Test func adaptiveOffHoldsAndPersistsLivePairAcrossRelaunch() {
        let defaults = freshDefaults()
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let firstLocation = FakeLocationProvider(); firstLocation.coordinate = (0, 0)
        let first = makeManager(defaults: defaults, location: firstLocation, now: { noon })
        first.intensity = 0.4
        first.whitepoint = 0.5
        first.adaptiveEnabled = true

        let secondLocation = FakeLocationProvider(); secondLocation.coordinate = (0, 0)
        let second = makeManager(defaults: defaults, location: secondLocation, now: { noon })
        #expect(second.adaptiveEnabled)
        second.adaptiveEnabled = false
        #expect(abs(second.intensity - 1.0) < 1e-9)
        #expect(abs(second.whitepoint - 1.0) < 1e-9)

        let third = makeManager(defaults: defaults, location: FakeLocationProvider())
        #expect(!third.adaptiveEnabled)
        #expect(abs(third.intensity - 1.0) < 1e-9)
        #expect(abs(third.whitepoint - 1.0) < 1e-9)
    }

    @Test func missingLocationHoldsManualOutputThenFadesWhenResolved() throws {
        let location = FakeLocationProvider()
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            location: location, now: { noon }, transitionDuration: 1)
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggle(1)
        mock.applyCalls.removeAll()

        manager.adaptiveEnabled = true
        #expect(manager.adaptiveStatusText == "Locating…")
        #expect(mock.applyCalls.isEmpty)  // the already-rendered manual output stays put

        location.coordinate = (0, 0)
        location.onChange?()
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5) < 0.0001)

        manager.advanceOutputTransition(toProgress: 0.5)
        call = try #require(mock.applyCalls.last)
        #expect(Double(call.intensity) > 0.4)
        #expect(Double(call.whitepoint) > 0.5)
        manager.completeOutputTransition()
    }

    @Test func adaptiveOffOnWithMissingLocationHoldsUntilValidTarget() throws {
        let location = FakeLocationProvider()
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            location: location, now: { noon }, transitionDuration: 1)
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.toggle(1)
        mock.applyCalls.removeAll()

        manager.adaptiveEnabled = true
        #expect(manager.adaptiveStatusText == "Locating…")
        #expect(abs(manager.intensity - 0.4) < 1e-9)
        #expect(abs(manager.whitepoint - 0.5) < 1e-9)

        manager.adaptiveEnabled = false
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5) < 0.0001)
        #expect(abs(manager.intensity - 0.4) < 1e-9)
        #expect(abs(manager.whitepoint - 0.5) < 1e-9)

        manager.adaptiveEnabled = true
        #expect(manager.adaptiveStatusText == "Locating…")
        let heldCallCount = mock.applyCalls.count
        manager.advanceOutputTransition(toProgress: 0.5)
        #expect(mock.applyCalls.count == heldCallCount)

        location.coordinate = (0, 0)
        location.onChange?()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.4) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5) < 0.0001)

        manager.advanceOutputTransition(toProgress: 0.5)
        call = try #require(mock.applyCalls.last)
        #expect(Double(call.intensity) > 0.4)
        #expect(Double(call.whitepoint) > 0.5)
    }

    @Test func adaptiveOffHoldsEditedChannelAndRenderedOtherChannel() throws {
        let defaults = freshDefaults()
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            defaults: defaults,
            location: location,
            now: { noon },
            transitionDuration: 1)
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.adaptiveMax = 0.8
        manager.adaptiveWpMax = 0.9
        manager.toggle(1)

        manager.adaptiveEnabled = true
        manager.advanceOutputTransition(toProgress: 0.25)
        manager.intensity = 0.65  // user owns this channel; white point keeps fading
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.65) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5625) < 0.0001)

        manager.adaptiveEnabled = false
        call = try #require(mock.applyCalls.last)
        #expect(abs(manager.intensity - 0.65) < 1e-9)
        #expect(abs(manager.whitepoint - 0.5625) < 1e-9)
        #expect(abs(Double(call.intensity) - 0.65) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 0.5625) < 0.0001)
        #expect(abs(defaults.double(forKey: "redlight.manualIntensity") - 0.65) < 1e-9)
        #expect(abs(defaults.double(forKey: "redlight.manualWhitepoint") - 0.5625) < 1e-9)

        let heldCallCount = mock.applyCalls.count
        manager.advanceOutputTransition(toProgress: 1)
        #expect(mock.applyCalls.count == heldCallCount)
    }

    @Test func manualIntensityEditLeavesWhitepointFadeRunning() throws {
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(
            location: location, now: { noon }, transitionDuration: 1)
        manager.intensity = 0.4
        manager.whitepoint = 0.5
        manager.adaptiveMax = 0.8
        manager.toggle(1)
        manager.adaptiveEnabled = true
        manager.advanceOutputTransition(toProgress: 0.25)
        let whitepointBeforeEdit = try #require(mock.applyCalls.last).whitepoint

        manager.intensity = 0.65
        var call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.65) < 0.0001)
        #expect(abs(call.whitepoint - whitepointBeforeEdit) < 0.0001)

        manager.advanceOutputTransition(toProgress: 0.5)
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.65) < 0.0001)
        #expect(call.whitepoint > whitepointBeforeEdit)

        manager.completeOutputTransition()
        call = try #require(mock.applyCalls.last)
        #expect(abs(Double(call.intensity) - 0.65) < 0.0001)
        #expect(abs(Double(call.whitepoint) - 1.0) < 0.0001)
    }

    @Test func adaptiveOffDoesNotRestoreStalePresetIdentity() {
        let location = FakeLocationProvider(); location.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: location, now: { noon })
        manager.applyPreset(2)
        #expect(manager.activePresetIndex == 2)

        manager.adaptiveEnabled = true
        #expect(manager.activePresetIndex == nil)
        manager.adaptiveEnabled = false
        #expect(manager.activePresetIndex == nil)
    }

    @Test func adaptiveBaselinePersists() {
        let d = freshDefaults()
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let loc1 = FakeLocationProvider(); loc1.coordinate = (0, 0)
        let m1 = makeManager(defaults: d, location: loc1, now: { noon })
        m1.adaptiveEnabled = true
        m1.intensity = 0.8         // offset −0.2 persisted

        let loc2 = FakeLocationProvider(); loc2.coordinate = (0, 0)
        let m2 = makeManager(defaults: d, location: loc2, now: { noon })
        #expect(abs(m2.intensity - 0.8) < 1e-9)   // restored + applied at launch
    }

    @Test func adaptiveRemapsIntoBandAtDay() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveMin = 0.2
        manager.adaptiveMax = 0.8
        manager.adaptiveEnabled = true
        // daytime curve intensity 1.0 → banded = 0.2 + 0.6 * 1.0 = 0.8
        #expect(abs(manager.intensity - 0.8) < 1e-9)
    }

    @Test func adaptiveRemapsIntoBandAtNight() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        // Equator equinox solar midnight → sun far below horizon → curve intensity ~0.
        let midnight = ISO8601DateFormatter().date(from: "2025-03-21T00:00:00Z")!
        let manager = makeManager(location: loc, now: { midnight })
        manager.adaptiveMin = 0.2
        manager.adaptiveMax = 0.8
        manager.adaptiveEnabled = true
        // banded = 0.2 + 0.6 * ~0 ≈ 0.2 (floor)
        #expect(manager.intensity >= 0.2 - 1e-6)
        #expect(manager.intensity < 0.5)
    }

    @Test func adaptiveRemapsWhitepointIntoBand() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveWpMin = 0.5
        manager.adaptiveWpMax = 0.9
        manager.adaptiveEnabled = true
        // daytime whitepoint fraction 1.0 → banded = wpMax = 0.9
        #expect(abs(manager.whitepoint - 0.9) < 1e-9)
    }

    @Test func persistenceRoundTripsWhitepointBand() {
        let d = freshDefaults()
        let m1 = makeManager(defaults: d)
        m1.adaptiveWpMin = 0.4
        m1.adaptiveWpMax = 0.8
        m1.flushBandRefresh()          // band writes are coalesced; flush persists now
        let m2 = makeManager(defaults: d, location: FakeLocationProvider())
        #expect(abs(m2.adaptiveWpMin - 0.4) < 1e-9)
        #expect(abs(m2.adaptiveWpMax - 0.8) < 1e-9)
    }

    @Test func previewIntensityOverridesThenReverts() {
        let manager = makeManager()           // neutral intensity 1.0
        manager.toggle(1)                     // enable display 1
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()

        manager.previewIntensity(0.1)
        #expect(mock.applyCalls.last?.intensity == Float(0.1))

        manager.endPreview()
        #expect(mock.restoreCalls.last == 1)   // neutral value restores the calibrated table
    }

    @Test func adaptiveTickPushesGammaOncePerDisplay() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let midnight = ISO8601DateFormatter().date(from: "2025-03-21T00:00:00Z")!
        let manager = makeManager(location: loc, now: { midnight })
        manager.toggle(1)                 // enable display 1
        manager.adaptiveEnabled = true
        mock.applyCalls.removeAll()

        manager.applyAdaptive()           // one adaptive tick
        // Sets intensity + whitepoint internally, then applies ONCE (not once per setter).
        #expect(mock.applyCalls.count == 1)
    }

    @Test func manualNudgeWithBandPreserved() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveMin = 0.2
        manager.adaptiveMax = 0.8
        manager.adaptiveEnabled = true          // banded day = 0.8
        manager.intensity = 0.6                 // nudge → offset −0.2
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.6) < 1e-9)
    }

    @Test func persistenceRoundTripsAdaptiveBand() {
        let d = freshDefaults()
        let m1 = makeManager(defaults: d)
        m1.adaptiveMin = 0.3
        m1.adaptiveMax = 0.7
        m1.flushBandRefresh()          // band writes are coalesced; flush persists now
        let m2 = makeManager(defaults: d, location: FakeLocationProvider())
        #expect(abs(m2.adaptiveMin - 0.3) < 1e-9)
        #expect(abs(m2.adaptiveMax - 0.7) < 1e-9)
    }

    @Test func applyingPresetDisablesAdaptive() {
        let loc = FakeLocationProvider()
        loc.coordinate = (0, 0)
        let manager = makeManager(location: loc)
        manager.adaptiveEnabled = true

        manager.applyPreset(2)

        #expect(manager.adaptiveEnabled == false)
        #expect(manager.activePresetIndex == 2)
    }

    @Test func adaptiveEnabledPersists() {
        let d = freshDefaults()
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let m1 = makeManager(defaults: d, location: loc)
        m1.adaptiveEnabled = true

        let m2 = makeManager(defaults: d, location: FakeLocationProvider())
        #expect(m2.adaptiveEnabled == true)
    }

    @Test func invertOnlyAppliesPureInvertToOffDisplay() {
        let manager = makeManager()           // display 1 red filter OFF
        mock.applyCalls.removeAll()

        manager.toggleInvert(1)

        #expect(mock.applyCalls.count == 1)
        #expect(mock.applyCalls[0].invert == true)
        #expect(mock.applyCalls[0].intensity == Float(1.0))   // no red
        #expect(mock.applyCalls[0].whitepoint == Float(1.0))
    }

    @Test func invertOffRestoresWhenRedAlsoOff() {
        let manager = makeManager()
        manager.toggleInvert(1)  // on
        mock.restoreCalls.removeAll()

        manager.toggleInvert(1)  // off

        #expect(mock.restoreCalls == [1])
    }

    @Test func invertCountsAsActive() {
        let manager = makeManager()
        #expect(manager.isAnyActive == false)
        manager.toggleInvert(1)
        #expect(manager.isAnyActive == true)
    }

    @Test func invertPersists() {
        let d = freshDefaults()
        let m1 = makeManager(defaults: d)
        m1.toggleInvert(1)
        let m2 = makeManager(defaults: d, location: FakeLocationProvider())
        #expect(m2.displays[0].isInverted == true)
    }

    // MARK: - Band hard-limit regressions

    @Test func manualNudgeCannotEscapeBand() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveMin = 0.2
        manager.adaptiveMax = 0.8
        manager.adaptiveEnabled = true          // banded day = 0.8

        manager.intensity = 1.0                 // nudge past the band ceiling

        #expect(abs(manager.intensity - 0.8) < 1e-9)   // hard-clamped immediately
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.8) < 1e-9)   // and stays clamped on the next tick
    }

    @Test func whitepointNudgeCannotEscapeBand() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveWpMin = 0.5
        manager.adaptiveWpMax = 0.9
        manager.adaptiveEnabled = true          // banded day wp = 0.9

        manager.whitepoint = 1.0

        #expect(abs(manager.whitepoint - 0.9) < 1e-9)
        manager.applyAdaptive()
        #expect(abs(manager.whitepoint - 0.9) < 1e-9)
    }

    @Test func repeatedClampedNudgesDoNotWindUpOffset() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveMin = 0.2
        manager.adaptiveMax = 0.8
        manager.adaptiveEnabled = true

        for _ in 0..<5 {                         // hammer past the ceiling repeatedly
            manager.intensity = 1.0
            manager.applyAdaptive()
        }
        #expect(abs(manager.intensity - 0.8) < 1e-9)

        manager.intensity = 0.6                  // then a real in-band nudge
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.6) < 1e-9)   // no drift accumulated
    }

    @Test func adaptiveEditsWhileLocatingArePreservedWhenCurveResolves() {
        let loc = FakeLocationProvider()         // no coordinate yet → "Locating…"
        let midnight = ISO8601DateFormatter().date(from: "2025-03-21T00:00:00Z")!
        let manager = makeManager(location: loc, now: { midnight })
        manager.adaptiveEnabled = true
        #expect(manager.adaptiveStatusText == "Locating…")

        manager.intensity = 0.9                  // nudges with NO curve baseline yet
        manager.whitepoint = 0.65

        loc.coordinate = (0, 0)
        manager.applyAdaptive()                  // location arrives
        #expect(abs(manager.intensity - 0.9) < 1e-9)
        #expect(abs(manager.whitepoint - 0.65) < 1e-9)
        #expect(manager.adaptiveStatusText.contains("adjusted"))
    }

    @Test func adaptivePendingEditsRespectBandsBeforeAndAfterLocationResolves() {
        let loc = FakeLocationProvider()
        let midnight = ISO8601DateFormatter().date(from: "2025-03-21T00:00:00Z")!
        let manager = makeManager(location: loc, now: { midnight })
        manager.adaptiveEnabled = true
        manager.intensity = 0.9
        manager.whitepoint = 0.9

        manager.adaptiveMax = 0.5
        manager.adaptiveWpMax = 0.6
        manager.flushBandRefresh()
        #expect(abs(manager.intensity - 0.5) < 1e-9)
        #expect(abs(manager.whitepoint - 0.6) < 1e-9)

        loc.coordinate = (0, 0)
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.5) < 1e-9)
        #expect(abs(manager.whitepoint - 0.6) < 1e-9)
    }

    // MARK: - Band invariant (lo ≤ hi, in range)

    @Test func modelEnforcesBandOrder() {
        let manager = makeManager()
        manager.adaptiveMin = 0.7
        manager.adaptiveMax = 0.4                // below min → min follows down
        #expect(manager.adaptiveMin <= manager.adaptiveMax)
        #expect(abs(manager.adaptiveMax - 0.4) < 1e-9)

        manager.adaptiveWpMax = 0.5
        manager.adaptiveWpMin = 0.8              // above max → max follows up
        #expect(manager.adaptiveWpMin <= manager.adaptiveWpMax)
        #expect(abs(manager.adaptiveWpMin - 0.8) < 1e-9)
    }

    @Test func modelClampsBandToRange() {
        let manager = makeManager()
        manager.adaptiveMax = 1.5
        #expect(manager.adaptiveMax == 1.0)
        manager.adaptiveMin = -0.5
        #expect(manager.adaptiveMin == 0.0)
        manager.adaptiveWpMin = 0.1
        #expect(manager.adaptiveWpMin == 0.25)
    }

    @Test func persistedInvertedBandIsNormalizedAtLaunch() {
        let d = freshDefaults()
        d.set(0.9, forKey: "redlight.adaptiveMin")   // saved backwards
        d.set(0.2, forKey: "redlight.adaptiveMax")
        let manager = makeManager(defaults: d)
        #expect(manager.adaptiveMin <= manager.adaptiveMax)
        #expect(abs(manager.adaptiveMin - 0.2) < 1e-9)
        #expect(abs(manager.adaptiveMax - 0.9) < 1e-9)
    }

    // MARK: - Band change coalescing

    @Test func bandChangeIsCoalescedUntilFlush() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveEnabled = true           // banded day = 1.0
        #expect(abs(manager.intensity - 1.0) < 1e-9)

        manager.adaptiveMax = 0.6                // mid-drag: deferred, no recompute yet
        #expect(abs(manager.intensity - 1.0) < 1e-9)

        manager.flushBandRefresh()               // drag settles
        #expect(abs(manager.intensity - 0.6) < 1e-9)   // re-clamped into the new band
    }

    @Test func endPreviewFlushesPendingBandChange() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.toggle(1)
        manager.adaptiveEnabled = true

        manager.adaptiveMax = 0.6                // marker drag…
        manager.previewIntensity(0.6)
        manager.endPreview()                     // …released

        #expect(abs(manager.intensity - 0.6) < 1e-9)
        #expect(mock.applyCalls.last?.intensity == Float(0.6))   // filter reverted to applied value
    }

    // MARK: - Adaptive off / presets

    @Test func disablingAdaptivePreservesOffsetsAndHoldsLiveValues() {
        let d = freshDefaults()
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(defaults: d, location: loc, now: { noon })
        manager.intensity = 0.6                 // saved manual target
        manager.adaptiveEnabled = true
        manager.intensity = 0.8                  // offset −0.2, persisted

        manager.adaptiveEnabled = false

        #expect(abs(d.double(forKey: "redlight.adaptiveOffsetIntensity") + 0.2) < 1e-9)
        #expect(manager.adaptiveStatusText.isEmpty)
        #expect(abs(manager.intensity - 0.8) < 1e-9)
        #expect(abs(d.double(forKey: "redlight.manualIntensity") - 0.8) < 1e-9)

        manager.adaptiveEnabled = true
        #expect(abs(manager.intensity - 0.8) < 1e-9)   // same valid target stays continuous
    }

    @Test func saveToPresetWhileAdaptiveKeepsAdaptiveDriving() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveEnabled = true           // day → intensity 1.0

        manager.saveToPreset(4)                  // redefine Deep Red = current (1.0, 1.0)

        #expect(manager.adaptiveEnabled == true)
        #expect(manager.activePresetIndex == nil)          // adaptive isn't a preset
        #expect(manager.presets[4].intensity == 1.0)
        // Day and Deep Red anchors now coincide (flat curve) — the mapping must not
        // blow up or pin to the band max; the raw value clamps into the band.
        manager.applyAdaptive()
        #expect(manager.intensity >= 0.0 && manager.intensity <= 1.0)
    }

    @Test func savingAdjustedAdaptivePresetDoesNotDoubleApplyOffset() throws {
        let base = ISO8601DateFormatter().date(from: "2025-07-14T00:15:30Z")!
        let latitude = 36.1627, longitude = -86.7816
        let cycle = SunCycle(now: base, latitude: latitude, longitude: longitude)
        let sunset = try #require(cycle.nextEvent)
        let date = base.addingTimeInterval(sunset.seconds)
        let loc = FakeLocationProvider(); loc.coordinate = (latitude, longitude)
        let manager = makeManager(location: loc, now: { date })
        manager.adaptiveEnabled = true
        manager.intensity = 0.6
        manager.whitepoint = 0.7

        manager.saveToPreset(2)

        #expect(abs(manager.intensity - 0.6) < 1e-9)
        #expect(abs(manager.whitepoint - 0.7) < 1e-9)
        #expect(abs(manager.presets[2].intensity - 0.6) < 1e-9)
        #expect(abs(manager.presets[2].whitepoint - 0.7) < 1e-9)
    }

    @Test func adjustedAdaptiveSampleMatchesLiveDisplay() {
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveEnabled = true
        manager.intensity = 0.75
        let elevation = SolarCalculator.elevation(at: noon, latitude: 0, longitude: 0)
        let minimum = SolarCalculator.elevationAtSolarMidnight(
            at: noon, latitude: 0, longitude: 0)

        let sample = manager.adaptiveIntensity(at: elevation, minElevation: minimum)

        #expect(abs(sample - manager.intensity) < 1e-9)
    }

    @Test func saveToPresetWhenManualMarksPresetActive() {
        let manager = makeManager()
        manager.intensity = 0.42
        manager.saveToPreset(1)
        #expect(manager.presets[1].intensity == 0.42)
        #expect(manager.activePresetIndex == 1)
    }

    // MARK: - Display list robustness

    @Test func duplicateDisplayIDsDoNotTrap() {
        let manager = makeManager(displayIDs: [1, 1, 2])   // used to trap uniqueKeysWithValues
        #expect(manager.displays.map(\.id) == [1, 2])
    }

    @Test func disconnectingActiveDisplayClearsItsGammaSnapshot() {
        var ids: [CGDirectDisplayID] = [1, 2]
        let manager = DisplayManager(
            gamma: mock,
            getDisplayIDs: { ids },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: freshDefaults(),
            location: FakeLocationProvider()
        )
        manager.intensity = 0.7
        manager.toggle(2)
        mock.restoreCalls.removeAll()
        mock.restoreAllCount = 0

        ids = [1]
        manager.refreshDisplays()

        #expect(mock.restoreAllCount == 1)
        #expect(manager.displays.map(\.id) == [1])
    }

    @Test func monitorWakeRecapturesColorSyncBeforeReapplyingFilter() {
        // Turning a third-party panel off and on often retrains the link without changing
        // the CoreGraphics display ID. The GPU LUT and ColorSync profile are both reset, so
        // the pre-sleep snapshot is stale: writing it back on disable leaves a residual
        // red cast. ColorSync-restore + recapture, then re-apply, matches what Quit does.
        let ids: [CGDirectDisplayID] = [1]
        let manager = DisplayManager(
            gamma: mock,
            getDisplayIDs: { ids },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: freshDefaults(),
            location: FakeLocationProvider()
        )
        manager.intensity = 0.4
        manager.toggle(1)
        manager.completeDisplayTransitions()
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()
        mock.restoreAllCount = 0

        manager.refreshDisplays()

        #expect(mock.restoreAllCount == 1)
        #expect(mock.applyCalls.contains { call in
            call.displayID == 1 && abs(call.intensity - 0.4) < 0.0001
        })
    }

    @Test func adaptiveStartupAppliesCurrentCurveWithoutPersistedValueFlash() {
        let d = freshDefaults()
        d.set(true, forKey: "redlight.display.1.enabled")
        d.set(true, forKey: "redlight.adaptiveEnabled")
        d.set(1.0, forKey: "redlight.intensity")
        let midnight = ISO8601DateFormatter().date(from: "2025-03-21T00:00:00Z")!
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)

        _ = makeManager(defaults: d, location: loc, now: { midnight })

        #expect(mock.applyCalls.count == 1)
        #expect(mock.applyCalls[0].intensity < 0.5)
    }

    @Test func adaptiveRetriesApproximateLocationUntilAPreciseFixArrives() {
        var date = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let loc = FakeLocationProvider()
        loc.coordinate = (41.8, -87.6)
        loc.isApproximate = true
        let manager = makeManager(location: loc, now: { date })
        manager.adaptiveEnabled = true
        #expect(loc.requestCount == 1)

        date.addTimeInterval(59)
        manager.applyAdaptive()
        #expect(loc.requestCount == 1)

        date.addTimeInterval(2)
        manager.applyAdaptive()
        #expect(loc.requestCount == 2)
    }

    @Test func approximateFixStillPublishesCoordinateForTheSunArc() {
        let loc = FakeLocationProvider()
        loc.coordinate = (41.8, -87.6)
        loc.isApproximate = true
        let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let manager = makeManager(location: loc, now: { noon })
        manager.adaptiveEnabled = true

        #expect(manager.coordinate != nil)
        #expect(manager.adaptiveStatusText.contains("time zone"))
        #expect(!manager.adaptiveStatusText.contains("Locating"))
    }

    @Test func adaptiveRetriesMissingLocationWithoutContinuousPolling() {
        var date = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
        let loc = FakeLocationProvider()
        let manager = makeManager(location: loc, now: { date })
        manager.adaptiveEnabled = true
        #expect(loc.requestCount == 1)

        date.addTimeInterval(59)
        manager.applyAdaptive()
        #expect(loc.requestCount == 1)

        date.addTimeInterval(2)
        manager.applyAdaptive()
        #expect(loc.requestCount == 2)
    }

    @Test func wakeRefreshesLocationAndAppliesAdaptiveOnce() {
        let midnight = ISO8601DateFormatter().date(from: "2025-03-21T00:00:00Z")!
        let loc = FakeLocationProvider(); loc.coordinate = (0, 0)
        let manager = makeManager(location: loc, now: { midnight })
        manager.toggle(1)
        manager.adaptiveEnabled = true
        mock.applyCalls.removeAll()

        manager.handleWake()

        #expect(loc.requestCount == 2)
        #expect(mock.applyCalls.count == 1)
    }
}
