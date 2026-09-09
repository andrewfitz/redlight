import Foundation
import Testing
@testable import Redlight

@MainActor @Suite struct LocationProviderTests {
    @Test func missingCacheFallsBackToTimeZoneSoAdaptiveIsNeverStuck() throws {
        let name = "RedlightLocationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let provider = LocationProvider(
            defaults: defaults,
            timeZone: TimeZone(identifier: "America/Chicago")!
        )

        let coord = try #require(provider.coordinate)
        #expect(provider.isApproximate)
        #expect(abs(coord.latitude - 41.85) < 1.5)
        #expect(abs(coord.longitude - (-87.65)) < 1.5)
        #expect(defaults.object(forKey: "redlight.location.lat") == nil)
    }

    @Test func cachedCoordinateIsPreferredOverTimeZone() throws {
        let name = "RedlightLocationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(37.77, forKey: "redlight.location.lat")
        defaults.set(-122.42, forKey: "redlight.location.lon")

        let provider = LocationProvider(
            defaults: defaults,
            timeZone: TimeZone(identifier: "America/Chicago")!
        )

        let coord = try #require(provider.coordinate)
        #expect(!provider.isApproximate)
        #expect(abs(coord.latitude - 37.77) < 0.0001)
        #expect(abs(coord.longitude - (-122.42)) < 0.0001)
    }

    @Test func corruptCachedCoordinateFallsBackToTimeZone() throws {
        let name = "RedlightLocationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(Double.nan, forKey: "redlight.location.lat")
        defaults.set(500.0, forKey: "redlight.location.lon")

        let provider = LocationProvider(
            defaults: defaults,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )

        let coord = try #require(provider.coordinate)
        #expect(provider.isApproximate)
        #expect(abs(coord.latitude - 35.68) < 1.5)
    }
}
