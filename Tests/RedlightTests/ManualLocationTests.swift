import CoreGraphics
import Foundation
import Testing
@testable import Redlight

@MainActor
private final class Uptime {
    var value: TimeInterval = 100
}

@MainActor @Suite struct ManualLocationTests {
    let defaultsRegistry = TestDefaultsRegistry()
    let noon = ISO8601DateFormatter().date(from: "2025-03-20T12:00:00Z")!
    private let uptime = Uptime()

    func makeManager(
        location: FakeLocationProvider, defaults: UserDefaults? = nil, fadeDuration: TimeInterval = 0,
        activation: @escaping () -> Void = {}
    ) -> DisplayManager {
        let noon = noon, uptime = uptime
        return DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [1] }, getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: defaults ?? defaultsRegistry.makeDefaults(prefix: "ManualLocationTests"),
            location: location, now: { noon },
            adaptiveTransitionDuration: fadeDuration, displayTransitionDuration: 0,
            transitionUptime: { uptime.value }, locationPromptActivation: activation)
    }

    @Test func manualLocationNeverPromptsOrRequestsAndSaysManual() {
        for authorization in [LocationAuthorization.notDetermined, .denied, .authorized] {
            let defaults = defaultsRegistry.makeDefaults(prefix: "ManualLocationTests")
            defaults.set(true, forKey: "redlight.adaptiveEnabled")
            let location = FakeLocationProvider()
            location.authorization = authorization
            location.setManualCoordinate((latitude: 51.5, longitude: -0.13))
            var activations = 0
            let manager = makeManager(location: location, defaults: defaults, activation: { activations += 1 })

            #expect(manager.adaptiveEnabled)
            #expect(manager.manualLocation?.latitude == 51.5)
            #expect(manager.coordinate?.longitude == -0.13)
            #expect(manager.adaptiveStatusText.hasPrefix("Following the sun"))
            #expect(manager.adaptiveStatusText.hasSuffix(" · manual"))
            #expect(!manager.adaptiveStatusText.contains("last known"))
            #expect(!manager.adaptiveStatusText.contains("51.5"))

            manager.handleWake()
            manager.adaptiveEnabled = false
            manager.adaptiveEnabled = true
            #expect(location.requestCount == 0)
            #expect(activations == 0)
        }
    }

    @Test func settingAndClearingFadesToTheNewTargetAndClearingAsksAgain() {
        let location = FakeLocationProvider()
        location.coordinate = (latitude: 0, longitude: 0)   // local noon
        let manager = makeManager(location: location, fadeDuration: 1)
        manager.adaptiveEnabled = true
        manager.completeOutputTransition()
        let automatic = manager.intensity
        let requests = location.requestCount

        manager.setManualLocation((latitude: 0, longitude: 180))   // local midnight
        #expect(location.manualCoordinate?.longitude == 180)
        #expect(manager.manualLocation?.longitude == 180)
        #expect(manager.coordinate?.longitude == 180)
        #expect(manager.commandIsFading)
        #expect(manager.intensity < automatic)
        #expect(manager.adaptiveStatusText.hasSuffix(" · manual"))
        #expect(location.requestCount == requests)
        manager.completeOutputTransition()

        manager.setManualLocation(nil)
        #expect(location.manualCoordinate == nil)
        #expect(manager.manualLocation == nil)
        #expect(location.requestCount == requests + 1)
        #expect(manager.commandIsFading)
        #expect(manager.intensity == automatic)
        #expect(!manager.adaptiveStatusText.contains("manual"))
    }

    @Test func clearingWhileAdaptiveIsOffLeavesLocationIdle() {
        let location = FakeLocationProvider()
        let manager = makeManager(location: location)
        manager.setManualLocation((latitude: 10, longitude: 10))
        #expect(manager.manualLocation?.latitude == 10)
        manager.setManualLocation(nil)
        #expect(location.requestCount == 0)
        #expect(manager.manualLocation == nil)
    }
}
