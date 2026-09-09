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

    @Test func tokyoTimeZoneMapsNearTheCity() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let coord = ApproximateLocation.from(tz)
        #expect(abs(coord.latitude - 35.68) < 1.5)
        #expect(abs(coord.longitude - 139.69) < 1.5)
    }

    @Test func unknownZoneFallsBackToOffsetDerivedLongitude() {
        // Etc/GMT-3 is UTC+3 (POSIX sign inversion), no DST: 3 h × 15° = 45° E.
        let tz = TimeZone(identifier: "Etc/GMT-3")!
        let coord = ApproximateLocation.from(tz)
        #expect(abs(coord.longitude - 45) < 0.01)
        #expect(coord.latitude > -90 && coord.latitude < 90)
    }

    @Test func offsetFallbackIgnoresDaylightSaving() {
        // Nuuk observes DST. During summer its offset is UTC-1 but the city sits at
        // UTC-2 standard time (≈ -30° … -51° W). The fallback must not drift 15° east
        // every summer because it read the daylight offset.
        let tz = TimeZone(identifier: "America/Nuuk")!
        let summer = ISO8601DateFormatter().date(from: "2025-07-01T12:00:00Z")!
        let winter = ISO8601DateFormatter().date(from: "2025-01-01T12:00:00Z")!
        let a = ApproximateLocation.from(tz, at: summer)
        let b = ApproximateLocation.from(tz, at: winter)
        #expect(abs(a.longitude - b.longitude) < 0.01)
        #expect(abs(a.longitude - (-30)) < 0.01)
    }

    @Test func southernHemisphereZonesGetANegativeLatitude() {
        let tz = TimeZone(identifier: "Australia/Darwin")!   // not in the city table
        #expect(ApproximateLocation.from(tz).latitude < 0)
    }
}
