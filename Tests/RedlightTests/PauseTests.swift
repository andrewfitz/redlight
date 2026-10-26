import CoreGraphics
import Foundation
import Testing
@testable import Redlight

@MainActor
private final class Clock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    var uptime: TimeInterval = 100
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

    @Test func pauseNeedsAFilterAndMasterOnResumes() {
        let manager = makeManager()
        #expect(!manager.pause())
        manager.setAll(on: true)
        #expect(manager.pause())
        manager.setAll(on: true)
        #expect(!manager.isPaused)
        #expect(manager.isFiltering)
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
