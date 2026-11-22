import CoreLocation
import Foundation
import Testing
@testable import Redlight

@MainActor @Suite struct LocationProviderTests {
    private final class TestManager: CLLocationManager {
        var status = CLAuthorizationStatus.notDetermined
        var cachedLocation: CLLocation?
        var authorizationRequests = 0
        var locationRequests = 0

        override var authorizationStatus: CLAuthorizationStatus { status }
        override var location: CLLocation? { cachedLocation }
        override func requestWhenInUseAuthorization() { authorizationRequests += 1 }
        override func requestLocation() { locationRequests += 1 }
        override func stopUpdatingLocation() {}
    }

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

    private func freshDefaults() -> UserDefaults {
        let name = "RedlightLocationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // These tests never reach a Core Location request: with a manual coordinate set the
    // provider returns before asking, and clearing leaves the fresh request to its owner.
    @Test func manualCoordinateOverridesTheCachedFixPersistsAndClears() throws {
        let defaults = freshDefaults()
        defaults.set(37.77, forKey: "redlight.location.lat")
        defaults.set(-122.42, forKey: "redlight.location.lon")
        let provider = LocationProvider(defaults: defaults, timeZone: TimeZone(identifier: "America/Chicago")!)
        var changes = 0
        provider.onChange = { changes += 1 }

        provider.setManualCoordinate((latitude: 51.5, longitude: -0.13))
        #expect(changes == 1)
        let manual = try #require(provider.coordinate)
        #expect(manual.latitude == 51.5 && manual.longitude == -0.13)
        #expect(provider.manualCoordinate?.latitude == 51.5)
        #expect(!provider.isApproximate)
        #expect(defaults.double(forKey: "redlight.location.manualLat") == 51.5)
        #expect(defaults.double(forKey: "redlight.location.manualLon") == -0.13)
        // The cached automatic fix is kept for when the user returns to automatic.
        #expect(defaults.double(forKey: "redlight.location.lat") == 37.77)
        provider.requestWhenInUse()
        #expect(!provider.wantsFix)

        let relaunched = LocationProvider(defaults: defaults, timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(relaunched.coordinate?.latitude == 51.5)
        #expect(relaunched.manualCoordinate?.longitude == -0.13)
        var relaunchedChanges = 0
        relaunched.onChange = { relaunchedChanges += 1 }
        relaunched.setManualCoordinate(nil)
        #expect(relaunchedChanges == 1)
        #expect(relaunched.manualCoordinate == nil)
        #expect(relaunched.coordinate?.latitude == 37.77)
        #expect(!relaunched.isApproximate)
        #expect(defaults.object(forKey: "redlight.location.manualLat") == nil)
        #expect(defaults.object(forKey: "redlight.location.manualLon") == nil)
    }

    @Test func manualCoordinateReplacesAndRestoresTheTimeZoneFallback() throws {
        let provider = LocationProvider(defaults: freshDefaults(), timeZone: TimeZone(identifier: "America/Chicago")!)
        #expect(provider.isApproximate)
        provider.setManualCoordinate((latitude: -33.87, longitude: 151.21))
        #expect(!provider.isApproximate)
        #expect(provider.coordinate?.latitude == -33.87)
        provider.setManualCoordinate(nil)
        #expect(provider.isApproximate)
        let fallback = try #require(provider.coordinate)
        #expect(abs(fallback.latitude - 41.85) < 1.5)
    }

    @Test func invalidManualCoordinateIsIgnored() {
        let provider = LocationProvider(defaults: freshDefaults(), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        var changes = 0
        provider.onChange = { changes += 1 }
        for bad in [(91.0, 0.0), (-90.5, 0.0), (0.0, 180.5), (Double.nan, 0.0), (0.0, -Double.infinity)] {
            provider.setManualCoordinate((latitude: bad.0, longitude: bad.1))
        }
        #expect(changes == 0)
        #expect(provider.manualCoordinate == nil)
        #expect(provider.isApproximate)
    }

    @Test func corruptPersistedManualCoordinateIsIgnoredOnLoad() {
        let cases: [(Any?, Any?)] = [
            (Double.nan, 10.0), (95.0, 10.0), (10.0, 200.0), (10.0, nil), ("north", 10.0), (true, 10.0),
        ]
        for (lat, lon) in cases {
            let defaults = freshDefaults()
            if let lat { defaults.set(lat, forKey: "redlight.location.manualLat") }
            if let lon { defaults.set(lon, forKey: "redlight.location.manualLon") }
            let provider = LocationProvider(defaults: defaults, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
            #expect(provider.manualCoordinate == nil)
            #expect(provider.isApproximate)
            #expect(abs((provider.coordinate?.latitude ?? 0) - 35.68) < 1.5)
        }
    }

    @Test func oneShotRetriesOnlyWhenAskedAfterFailureOrInvalidFix() {
        let manager = TestManager()
        let provider = LocationProvider(defaults: freshDefaults(), manager: manager)
        provider.requestWhenInUse()
        provider.requestWhenInUse()
        #expect(manager.authorizationRequests == 1)
        manager.status = .authorizedAlways
        provider.locationManagerDidChangeAuthorization(manager)
        provider.locationManagerDidChangeAuthorization(manager)
        #expect(provider.wantsFix)
        #expect(manager.locationRequests == 1)

        provider.locationManager(manager, didFailWithError: CLError(.locationUnknown))
        #expect(!provider.wantsFix)
        provider.locationManagerDidChangeAuthorization(manager)
        #expect(manager.locationRequests == 1)
        provider.requestWhenInUse()
        #expect(manager.locationRequests == 2)
        provider.locationManager(manager, didUpdateLocations: [])
        #expect(!provider.wantsFix)
        #expect(provider.isApproximate)
    }

    @Test func aFixDeliveredAfterCancellationLeavesTheAutomaticLocationUntouched() {
        let manager = TestManager()
        manager.status = .authorizedAlways
        let defaults = freshDefaults()
        let chicago = TimeZone(identifier: "America/Chicago")!
        let provider = LocationProvider(defaults: defaults, timeZone: chicago, manager: manager)
        provider.requestWhenInUse()
        #expect(manager.locationRequests == 1)
        provider.setManualCoordinate((latitude: 10, longitude: 20))

        let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 30, longitude: 40),
                             altitude: 0, horizontalAccuracy: 1_000, verticalAccuracy: -1, timestamp: Date())
        provider.locationManager(manager, didUpdateLocations: [fix])
        #expect(defaults.object(forKey: "redlight.location.lat") == nil)
        provider.setManualCoordinate(nil)
        #expect(provider.isApproximate)
        #expect(provider.coordinate?.latitude == ApproximateLocation.from(chicago).latitude)
    }

    @Test func recentValidCachedFixSkipsHardwareAndInvalidCachedFixDoesNot() {
        let manager = TestManager()
        manager.status = .authorizedAlways
        let provider = LocationProvider(defaults: freshDefaults(), manager: manager)
        func fix(_ accuracy: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 30, longitude: 40),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: Date())
        }
        manager.cachedLocation = fix(1_000)
        provider.requestWhenInUse()
        #expect(manager.locationRequests == 0)
        #expect(provider.coordinate?.latitude == 30)
        #expect(!provider.wantsFix)

        manager.cachedLocation = fix(-1)
        provider.requestWhenInUse()
        #expect(manager.locationRequests == 1)
        #expect(provider.wantsFix)
    }

    @Test func manualLocationTextValidationNamesTheRange() throws {
        let parsed = try ManualLocation.parse(latitude: " 51.5 ", longitude: "-0.13")
        #expect(parsed.latitude == 51.5 && parsed.longitude == -0.13)
        #expect(ManualLocation.isValid(latitude: 90, longitude: -180))
        #expect(!ManualLocation.isValid(latitude: 90.01, longitude: 0))
        #expect(!ManualLocation.isValid(latitude: 0, longitude: .infinity))
        // Prefilled field text round-trips through the parser in any locale.
        #expect(ManualLocation.text(51.5) == "51.5")
        #expect(ManualLocation.text(-0.12784) == "-0.1278")
        #expect(ManualLocation.text(10) == "10")
        #expect(ManualLocation.text(-33.000_01) == "-33")
        for (lat, lon, word) in [("91", "0", "Latitude"), ("", "0", "Latitude"), ("nan", "0", "Latitude"),
                                 ("0", "181", "Longitude"), ("0", "east", "Longitude"), ("0", "inf", "Longitude")] {
            do {
                _ = try ManualLocation.parse(latitude: lat, longitude: lon)
                Issue.record("Accepted \(lat), \(lon)")
            } catch let error as CommandError {
                #expect(error.code == .invalidInput)
                #expect(error.message.contains(word))
            }
        }
    }
}
