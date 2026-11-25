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

    @Test func legacyZoneNamesUseTheSameLocation() throws {
        for (alias, canonical) in [("US/Alaska", "America/Anchorage"), ("NZ", "Pacific/Auckland"),
                                   ("Asia/Calcutta", "Asia/Kolkata"), ("NZ-CHAT", "Pacific/Chatham"),
                                   ("Canada/Pacific", "America/Vancouver"), ("Canada/Eastern", "America/Toronto")] {
            let legacyZone = try #require(TimeZone(identifier: alias))
            let canonicalZone = try #require(TimeZone(identifier: canonical))
            let at = Date(timeIntervalSince1970: 1_750_000_000)
            let legacy = ApproximateLocation.from(legacyZone, at: at)
            let modern = ApproximateLocation.from(canonicalZone, at: at)
            #expect(legacy == modern)
        }
    }

    @Test func chathamQuarterHourZoneUsesTheIslandLocation() throws {
        let zone = try #require(TimeZone(identifier: "Pacific/Chatham"))
        let coord = ApproximateLocation.from(zone)
        #expect(abs(coord.latitude + 43.95) < 0.1)
        #expect(abs(coord.longitude + 176.55) < 0.1)
    }

    @Test func unknownZoneFallsBackToOffsetDerivedLongitude() {
        // Etc/GMT-3 is UTC+3 (POSIX sign inversion), no DST: 3 h × 15° = 45° E.
        let tz = TimeZone(identifier: "Etc/GMT-3")!
        let coord = ApproximateLocation.from(tz)
        #expect(abs(coord.longitude - 45) < 0.01)
        #expect(coord.latitude > -90 && coord.latitude < 90)
    }

    @Test func aZoneWithDaylightSavingMapsToTheSameCityAllYear() {
        // Nuuk observes DST. Neither its city nor its standard offset may move with it.
        let tz = TimeZone(identifier: "America/Nuuk")!
        let summer = ISO8601DateFormatter().date(from: "2025-07-01T12:00:00Z")!
        let winter = ISO8601DateFormatter().date(from: "2025-01-01T12:00:00Z")!
        let a = ApproximateLocation.from(tz, at: summer)
        let b = ApproximateLocation.from(tz, at: winter)
        #expect(a == b)
        #expect(abs(a.latitude - 64.18) < 0.1 && abs(a.longitude - (-51.73)) < 0.1)
        #expect(ApproximateLocation.standardOffset(of: tz, at: summer)
                == ApproximateLocation.standardOffset(of: tz, at: winter))
        let chicago = TimeZone(identifier: "America/Chicago")!
        #expect(ApproximateLocation.standardOffset(of: chicago, at: summer) == -6 * 3_600)
        #expect(ApproximateLocation.standardOffset(of: chicago, at: winter) == -6 * 3_600)
    }

    @Test func everyZoneTheSystemKnowsHasACity() throws {
        #expect(ZoneCoordinates.table.count == ZoneCoordinates.zoneCount)
        #expect(ZoneCoordinates.aliases.count == ZoneCoordinates.aliasCount)
        #expect(ZoneCoordinates.table.values.allSatisfy { abs($0.latitude) <= 90 && abs($0.longitude) <= 180 })
        #expect(ZoneCoordinates.aliases.values.allSatisfy { ZoneCoordinates.table[$0] != nil })
        // "GMT" is the one zone Foundation lists that is no place at all.
        let missing = TimeZone.knownTimeZoneIdentifiers.filter {
            ZoneCoordinates.table[ZoneCoordinates.aliases[$0] ?? $0] == nil
        }
        #expect(missing.allSatisfy { $0 == "GMT" }, "\(missing)")
    }

    @Test func zonesTheOldHeuristicPutInTheWrongHemisphereAreRight() throws {
        for (id, latitude, longitude) in [("America/Coyhaique", -45.57, -72.07), ("Atlantic/Stanley", -51.7, -57.85),
                                          ("Pacific/Pago_Pago", -14.27, -170.7), ("Atlantic/St_Helena", -15.92, -5.7),
                                          ("Asia/Srednekolymsk", 67.47, 153.72), ("America/Thule", 76.57, -68.78)] {
            guard let zone = TimeZone(identifier: id) else { continue }   // newer than this macOS
            let coord = ApproximateLocation.from(zone)
            #expect(abs(coord.latitude - latitude) < 0.1 && abs(coord.longitude - longitude) < 0.1, "\(id)")
        }
    }

    @Test func southernHemisphereZonesGetANegativeLatitude() {
        for id in ["Australia/Darwin", "America/La_Paz", "Africa/Maputo", "Pacific/Apia",
                   "Asia/Makassar", "Pacific/Chatham", "America/Cuiaba"] {
            let tz = TimeZone(identifier: id)!
            #expect(ApproximateLocation.from(tz).latitude < 0, "\(id)")
        }
    }

    @Test func farEasternOffsetsWrapWestOfTheAntimeridian() {
        // Etc/GMT-14 is UTC+14, standard time only. 14 h × 15° = 210° → −150°.
        let tz = TimeZone(identifier: "Etc/GMT-14")!
        let coord = ApproximateLocation.from(tz)
        #expect(abs(coord.longitude - (-150)) < 0.01)
    }
}
