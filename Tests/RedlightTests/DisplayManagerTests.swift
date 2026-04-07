import Testing
import Foundation
import CoreGraphics
@testable import Redlight

final class MockGammaController: GammaControlling {
    var applyCalls: [(displayID: CGDirectDisplayID, intensity: Float)] = []
    var restoreAllCount = 0

    func applyRedFilter(to displayID: CGDirectDisplayID, intensity: Float) {
        applyCalls.append((displayID, intensity))
    }

    func restoreAll() {
        restoreAllCount += 1
    }
}

@Suite struct DisplayManagerTests {
    let mock = MockGammaController()

    func makeManager(
        displayIDs: [CGDirectDisplayID] = [1],
        defaults: UserDefaults? = nil
    ) -> DisplayManager {
        let d = defaults ?? freshDefaults()
        return DisplayManager(
            gamma: mock,
            getDisplayIDs: { displayIDs },
            getDisplayName: { "Display \($0)" },
            defaults: d
        )
    }

    func freshDefaults() -> UserDefaults {
        let name = "RedlightTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func toggleOnAppliesRedFilter() {
        let manager = makeManager()
        manager.toggle(1)

        #expect(mock.applyCalls.count == 1)
        #expect(mock.applyCalls[0].displayID == 1)
        #expect(mock.applyCalls[0].intensity == 0.5)
    }

    @Test func toggleOffSingleDisplayRestoresAll() {
        let manager = makeManager()
        manager.toggle(1) // on
        mock.restoreAllCount = 0

        manager.toggle(1) // off

        #expect(mock.restoreAllCount == 1)
    }

    @Test func toggleOffReappliesFilterToRemainingActiveDisplays() {
        let manager = makeManager(displayIDs: [1, 2])
        manager.toggle(1) // on
        manager.toggle(2) // on
        mock.applyCalls.removeAll()
        mock.restoreAllCount = 0

        manager.toggle(1) // off — should restore all, then re-apply to display 2

        #expect(mock.restoreAllCount == 1)
        #expect(mock.applyCalls.count == 1)
        #expect(mock.applyCalls[0].displayID == 2)
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
            defaults: d
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
            defaults: d
        )

        #expect(manager2.displays[0].isEnabled == true)
    }
}
