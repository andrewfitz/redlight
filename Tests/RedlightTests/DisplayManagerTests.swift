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

    var grayscaleCalls: [Bool] = []
    func setGrayscale(_ on: Bool) { grayscaleCalls.append(on) }
}

final class FakeLocationProvider: LocationProviding {
    var coordinate: (latitude: Double, longitude: Double)?
    var authorization: LocationAuthorization = .authorized
    var onChange: (() -> Void)?
    var requestCount = 0
    func requestWhenInUse() { requestCount += 1 }
}

@Suite struct DisplayManagerTests {
    let mock = MockGammaController()
    let fakeLocation = FakeLocationProvider()

    func makeManager(
        displayIDs: [CGDirectDisplayID] = [1],
        defaults: UserDefaults? = nil,
        location: LocationProviding? = nil,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> DisplayManager {
        let d = defaults ?? freshDefaults()
        return DisplayManager(
            gamma: mock,
            getDisplayIDs: { displayIDs },
            getDisplayName: { "Display \($0)" },
            defaults: d,
            location: location ?? fakeLocation,
            now: now
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
            defaults: d,
            location: FakeLocationProvider()
        )

        #expect(manager2.displays[0].isEnabled == true)
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
        #expect(mock.applyCalls.last?.intensity == Float(1.0))
    }

    @Test func manualSliderDisablesAdaptive() {
        let loc = FakeLocationProvider()
        loc.coordinate = (0, 0)
        let manager = makeManager(location: loc)
        manager.adaptiveEnabled = true
        #expect(manager.adaptiveEnabled == true)

        manager.intensity = 0.4    // user grabs the slider

        #expect(manager.adaptiveEnabled == false)
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

    @Test func grayscaleTogglesForcesGray() {
        let manager = makeManager()
        manager.grayscale = true
        #expect(mock.grayscaleCalls.last == true)
        manager.grayscale = false
        #expect(mock.grayscaleCalls.last == false)
    }

    @Test func grayscalePersists() {
        let d = freshDefaults()
        let m1 = makeManager(defaults: d)
        m1.grayscale = true
        let m2 = makeManager(defaults: d, location: FakeLocationProvider())
        #expect(m2.grayscale == true)
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
}
