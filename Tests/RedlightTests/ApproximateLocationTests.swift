import Foundation
import Testing
@testable import Redlight

@Suite struct ApproximateLocationTests {
    @Test func chicagoTimeZoneMapsNearTheCity() {
        let tz = TimeZone(identifier: "America/Chicago")!
        let coord = ApproximateLocation.from(tz)
        #expect(abs(coord.latitude - 41.85) < 1.5)
        #expect(abs(coord.longitude - (-87.65)) < 1.5)
    }

    @Test func londonTimeZoneMapsNearTheCity() {
        let tz = TimeZone(identifier: "Europe/London")!
        let coord = ApproximateLocation.from(tz)
        #expect(abs(coord.latitude - 51.5) < 1.5)
        #expect(abs(coord.longitude - 0) < 2)
    }

    @Test func unknownTimeZoneStillYieldsAFiniteCoordinate() {
        let tz = TimeZone(secondsFromGMT: -5 * 3600)!
        let coord = ApproximateLocation.from(tz)
        #expect(coord.latitude.isFinite)
        #expect(coord.longitude.isFinite)
        #expect(abs(coord.longitude - (-75)) < 1)
    }
}
