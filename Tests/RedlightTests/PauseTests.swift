import CoreGraphics
import Foundation
import Testing
@testable import Redlight

@MainActor
private final class Clock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    var uptime: TimeInterval = 100
    var displayIDs: [CGDirectDisplayID] = [1, 2]
}

@MainActor @Suite struct PauseTests {
    let mock = MockGammaController()
    let defaultsRegistry = TestDefaultsRegistry()
    private let clock = Clock()

    func makeManager(
        displayIDs: [CGDirectDisplayID] = [1, 2],
        defaults: UserDefaults? = nil,
        fadeDuration: TimeInterval = 0
    ) -> DisplayManager {
        let clock = clock
        return DisplayManager(
            gamma: mock,
            getDisplayIDs: { displayIDs },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: defaults ?? defaultsRegistry.makeDefaults(prefix: "PauseTests"),
            location: FakeLocationProvider(),
            now: { clock.date },
            adaptiveTransitionDuration: 0,
            displayTransitionDuration: fadeDuration,
            peekTransitionDuration: fadeDuration,
            transitionUptime: { clock.uptime }
        )
    }

    @Test func pauseSuspendsOnlyTheTintAndResumes() {
        let manager = makeManager()
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setInverted(true, for: 2)
        #expect(manager.pause())
        #expect(manager.isPaused)
        #expect(!manager.isFiltering)
        #expect(manager.isOn)
        // Display 1 is neutral; display 2 keeps its inversion with no tint.
        #expect(mock.restoreCalls.last == 1)
        let inverted = mock.applyCalls.last { $0.displayID == 2 }
        #expect(inverted?.invert == true && inverted?.intensity == 1)
        #expect(manager.isAnyActive) // Invert is still showing

        mock.applyCalls.removeAll()
        manager.resume()
        #expect(!manager.isPaused)
        #expect(mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(0.4))
    }

    @Test func countdownRoundsUpToWholeMinutes() {
        let until = Date(timeIntervalSince1970: 10_000)
        func left(_ seconds: TimeInterval) -> Int {
            DisplayManager.pauseMinutesLeft(until: until, now: until.addingTimeInterval(-seconds))
        }
        #expect(left(30 * 60) == 30)
        #expect(left(29 * 60 + 1) == 30)
        #expect(left(29 * 60) == 29)
        #expect(left(59) == 1)
        #expect(left(0) == 1)
    }

    @Test func pauseNeedsAFilterAndMasterOnResumes() {
        let manager = makeManager()
        #expect(!manager.pause())
        manager.setAll(on: true)
        #expect(manager.pause())
        manager.setAll(on: true)
        #expect(!manager.isPaused)
        #expect(manager.isFiltering)
    }

    @Test(arguments: [true, false]) func masterSwitchEndsPauseAfterPausedDisplayWasUnplugged(on: Bool) {
        let clock = clock
        let manager = DisplayManager(
            gamma: mock,
            getDisplayIDs: { clock.displayIDs },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            getMainDisplayID: { 1 },
            defaults: defaultsRegistry.makeDefaults(prefix: "PauseTests"),
            location: FakeLocationProvider(),
            now: { clock.date },
            adaptiveTransitionDuration: 0,
            displayTransitionDuration: 0,
            peekTransitionDuration: 0,
            transitionUptime: { clock.uptime }
        )
        manager.intensity = 0.4
        manager.setEnabled(true, for: 2)
        #expect(manager.pause())

        clock.displayIDs = [1]
        manager.refreshDisplays()
        #expect(manager.isPaused)
        #expect(!manager.isOn)

        mock.applyCalls.removeAll()
        manager.setAll(on: on)
        #expect(!manager.isPaused)
        #expect(manager.isFiltering == on)
        if on {
            #expect(mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(0.4))
        }
    }

    @Test func turningOffEndsThePauseWithoutReshowingTheFilter() {
        let manager = makeManager(fadeDuration: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.pause()
        manager.advancePauseTransition(toProgress: 1)
        mock.applyCalls.removeAll()

        manager.setAll(on: false)
        #expect(!manager.isPaused)
        manager.completeDisplayTransitions()
        // Nothing tinted is ever written on the way out.
        #expect(mock.applyCalls.allSatisfy { $0.intensity == 1 })
        #expect(!manager.isAnyActive)
    }

    @Test func expiryResumesAndClockChangesAreCapped() {
        let manager = makeManager()
        manager.setEnabled(true, for: 1)
        manager.pause()
        let until = try! #require(manager.pausedUntil)
        #expect(until == clock.date.addingTimeInterval(DisplayManager.Defaults.pauseDuration))

        clock.date = clock.date.addingTimeInterval(-3_600) // clock set back an hour
        manager.refreshPause()
        #expect(manager.pausedUntil == clock.date.addingTimeInterval(DisplayManager.Defaults.pauseDuration))

        clock.date = clock.date.addingTimeInterval(DisplayManager.Defaults.pauseDuration + 1)
        manager.handleWake()
        #expect(!manager.isPaused)
    }

    @Test func pauseSurvivesRelaunchUntilItExpires() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "PauseTests")
        let first = makeManager(defaults: defaults)
        first.setEnabled(true, for: 1)
        first.pause()

        clock.date = clock.date.addingTimeInterval(60)
        let relaunched = makeManager(defaults: defaults)
        #expect(relaunched.isPaused)
        #expect(!relaunched.isFiltering)

        clock.date = clock.date.addingTimeInterval(DisplayManager.Defaults.pauseDuration)
        let late = makeManager(defaults: defaults)
        #expect(!late.isPaused)
        #expect(late.isFiltering)
    }

    @Test func timedPauseUsesAndPersistsItsOwnLength() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "PauseTests")
        let manager = makeManager(defaults: defaults)
        manager.setEnabled(true, for: 1)
        #expect(manager.pause(for: 2 * 3_600))
        #expect(manager.pausedUntil == clock.date.addingTimeInterval(2 * 3_600))
        #expect(manager.pauseLength == 2 * 3_600)
        #expect(defaults.double(forKey: "redlight.pauseLength") == 2 * 3_600)
        #expect(defaults.double(forKey: "redlight.pausedUntil") == clock.date.addingTimeInterval(2 * 3_600).timeIntervalSince1970)

        manager.resume()
        #expect(defaults.object(forKey: "redlight.pausedUntil") == nil)
        #expect(defaults.object(forKey: "redlight.pauseLength") == nil)

        // The default pause records its 30 minutes too.
        manager.pause()
        #expect(manager.pauseLength == DisplayManager.Defaults.pauseDuration)
        #expect(defaults.double(forKey: "redlight.pauseLength") == DisplayManager.Defaults.pauseDuration)
    }

    @Test func pauseLengthIsClampedToOneMinuteThroughOneDay() {
        let manager = makeManager()
        manager.setEnabled(true, for: 1)
        manager.pause(for: 10)
        #expect(manager.pausedUntil == clock.date.addingTimeInterval(60))
        manager.pause(for: 100_000)
        #expect(manager.pausedUntil == clock.date.addingTimeInterval(86_400))
        manager.pause(for: .nan)
        #expect(manager.pausedUntil == clock.date.addingTimeInterval(DisplayManager.Defaults.pauseDuration))
    }

    @Test func clockChangesAreCappedAtThePausesOwnLength() {
        let manager = makeManager()
        manager.setEnabled(true, for: 1)
        manager.pause(for: 2 * 3_600)
        clock.date = clock.date.addingTimeInterval(-3 * 3_600) // clock set back three hours
        manager.refreshPause()
        #expect(manager.pausedUntil == clock.date.addingTimeInterval(2 * 3_600))
        #expect(manager.pauseLength == 2 * 3_600)
    }

    @Test func longPauseSurvivesRelaunchWithoutTheThirtyMinuteCap() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "PauseTests")
        let first = makeManager(defaults: defaults)
        first.setEnabled(true, for: 1)
        first.pause(for: 3 * 3_600)
        let until = first.pausedUntil

        clock.date = clock.date.addingTimeInterval(60)
        let relaunched = makeManager(defaults: defaults)
        #expect(relaunched.isPaused)
        #expect(relaunched.pausedUntil == until)
        #expect(relaunched.pauseLength == 3 * 3_600)
    }

    @Test(arguments: [30.0, 43_200.0, 86_900.0])
    func absolutePausePreservesItsDeadlineAcrossClockChangesAndRelaunch(length: TimeInterval) {
        let defaults = defaultsRegistry.makeDefaults(prefix: "PauseTests")
        let manager = makeManager(defaults: defaults)
        manager.setEnabled(true, for: 1)
        let deadline = clock.date.addingTimeInterval(length)
        #expect(manager.pause(until: deadline))
        #expect(manager.pausedUntil == deadline)
        #expect(manager.pauseLength == length)

        clock.date = clock.date.addingTimeInterval(-120)
        manager.refreshPause()
        #expect(manager.pausedUntil == deadline)
        let relaunched = makeManager(defaults: defaults)
        #expect(relaunched.pausedUntil == deadline)
        #expect(relaunched.pauseLength == length)

        clock.date = deadline
        relaunched.refreshPause()
        #expect(!relaunched.isPaused)
        #expect(defaults.object(forKey: "redlight.pauseUsesDeadline") == nil)
    }

    @Test func absolutePauseRequiresAFutureDeadlineAndAFixedPauseReplacesItsMode() {
        let manager = makeManager()
        manager.setEnabled(true, for: 1)
        #expect(!manager.pause(until: clock.date))
        #expect(!manager.pause(until: Date(timeIntervalSince1970: .infinity)))
        #expect(manager.pause(until: clock.date.addingTimeInterval(30)))
        #expect(manager.pause(for: 60))
        clock.date = clock.date.addingTimeInterval(-120)
        manager.refreshPause()
        #expect(manager.pausedUntil == clock.date.addingTimeInterval(60))
    }

    @Test func pauseSavedByAnOlderVersionKeepsTheThirtyMinuteCap() {
        for storedLength: Any? in [nil, Double.nan, 1e9, -5.0, "long"] {
            let defaults = defaultsRegistry.makeDefaults(prefix: "PauseTests")
            defaults.set(true, forKey: "redlight.display.1.enabled")
            defaults.set(clock.date.addingTimeInterval(5 * 3_600).timeIntervalSince1970, forKey: "redlight.pausedUntil")
            if let storedLength { defaults.set(storedLength, forKey: "redlight.pauseLength") }
            let manager = makeManager(defaults: defaults)
            #expect(manager.isPaused)
            #expect(manager.pausedUntil == clock.date.addingTimeInterval(DisplayManager.Defaults.pauseDuration))
            #expect(manager.pauseLength == DisplayManager.Defaults.pauseDuration)
        }
    }

    @Test func countdownTextReadsNaturallyForLongPauses() {
        let until = Date(timeIntervalSince1970: 100_000)
        func text(_ seconds: TimeInterval) -> String {
            DisplayManager.pauseCountdownText(until: until, now: until.addingTimeInterval(-seconds))
        }
        #expect(text(30 * 60) == "30 min")
        #expect(text(59 * 60) == "59 min")
        #expect(text(59 * 60 + 1) == "1 h")
        #expect(text(72 * 60) == "1 h 12 m")
        #expect(text(120 * 60) == "2 h")
        #expect(text(24 * 3_600) == "24 h")
        #expect(text(10) == "1 min")
        func spoken(_ seconds: TimeInterval) -> String {
            DisplayManager.pauseCountdownAccessibilityText(until: until, now: until.addingTimeInterval(-seconds))
        }
        #expect(spoken(30 * 60) == "Paused, 30 minutes left")
        #expect(spoken(10) == "Paused, 1 minute left")
        #expect(spoken(60 * 60) == "Paused, 1 hour left")
        #expect(spoken(72 * 60) == "Paused, 1 hour 12 minutes left")
        #expect(spoken(121 * 60) == "Paused, 2 hours 1 minute left")
        #expect(DisplayManager.pauseLengthText(30 * 60) == "30 min")
        #expect(DisplayManager.pauseLengthText(90 * 60) == "1 h 30 m")
        #expect(DisplayManager.pauseLengthText(14.5 * 3_600) == "14 h 30 m")
    }

    @Test func nextSunriseUsesTheProviderCoordinate() throws {
        let location = FakeLocationProvider()
        let clock = clock
        clock.date = ISO8601DateFormatter().date(from: "2025-03-20T15:00:00Z")!
        let manager = DisplayManager(
            gamma: mock, getDisplayIDs: { [1] }, getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: defaultsRegistry.makeDefaults(prefix: "PauseTests"),
            location: location, now: { clock.date },
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0)
        #expect(manager.nextSunrise() == nil)
        location.setManualCoordinate((latitude: 0, longitude: 0))
        let expected = try #require(SunCycle.nextSunrise(after: clock.date, latitude: 0, longitude: 0))
        #expect(manager.nextSunrise() == expected)
        clock.date = ISO8601DateFormatter().date(from: "2025-06-21T12:00:00Z")!
        location.setManualCoordinate((latitude: 89.9, longitude: 0))   // polar day
        #expect(manager.nextSunrise() == nil)
    }

    @Test func peekShowsTrueColorsOnlyWhileHeld() {
        let manager = makeManager(fadeDuration: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()

        mock.restoreCalls.removeAll()
        manager.setPeeking(true)
        manager.advancePauseTransition(toProgress: 1)
        #expect(mock.restoreCalls.contains(1))
        #expect(!manager.isPaused)
        #expect(manager.isFiltering)

        mock.applyCalls.removeAll()
        manager.setPeeking(false)
        manager.advancePauseTransition(toProgress: 1)
        #expect(mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(0.4))
    }

    @Test func pausingDuringAPeekStaysOffAfterRelease() {
        let manager = makeManager()
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setPeeking(true)
        manager.pause()
        mock.applyCalls.removeAll()
        manager.setPeeking(false)
        #expect(mock.applyCalls.allSatisfy { $0.intensity == 1 })
        #expect(manager.isPaused)
    }

    @Test func quittingWhilePausedDoesNotFadeAHiddenFilter() {
        let manager = makeManager(fadeDuration: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.pause()
        manager.advancePauseTransition(toProgress: 1)
        var finished = false
        manager.beginTerminationFade { finished = true }
        #expect(finished)
    }
}
