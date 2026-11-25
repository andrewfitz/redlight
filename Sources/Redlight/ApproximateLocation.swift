import Foundation

/// City-level coordinate inferred from the Mac's time zone. Used when Core Location cannot
/// get a fix (common on desktop Macs that are ethernet-only, with no Wi-Fi scan for
/// triangulation) so Adaptive and the sun-arc graphic still have a solar position to follow.
/// The cities come from the tz database, in `ZoneCoordinates`.
enum ApproximateLocation {
    static func from(_ timeZone: TimeZone, at date: Date = Date()) -> (latitude: Double, longitude: Double) {
        // Foundation preserves older IANA identifiers when they are used as the system zone.
        let identifier = ZoneCoordinates.aliases[timeZone.identifier] ?? timeZone.identifier
        if let known = ZoneCoordinates.table[identifier] { return known }
        // Zones with no city: Etc/GMT±N, and any zone newer than the generated table.
        return (inferredLatitude(identifier), standardMeridian(of: timeZone, at: date))
    }

    /// The zone's UTC offset without daylight saving, in seconds. A location fix is tied
    /// to it: a different one means the Mac has moved a time zone since the fix was taken.
    static func standardOffset(of timeZone: TimeZone, at date: Date = Date()) -> Int {
        timeZone.secondsFromGMT(for: date) - Int(timeZone.daylightSavingTimeOffset(for: date).rounded())
    }

    /// The longitude where the zone's standard time is the mean solar time.
    private static func standardMeridian(of timeZone: TimeZone, at date: Date) -> Double {
        // Standard offset only: the daylight-saving hour would otherwise shift the
        // estimate 15° east for half the year. 240 s per degree of longitude.
        // UTC+13/+14 zones (Apia, Kiritimati) sit west of the antimeridian: wrap, don't clamp.
        var longitude = Double(standardOffset(of: timeZone, at: date)) / 240.0
        if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
        return longitude
    }

    /// A latitude for a zone the table does not have, from its region alone.
    private static func inferredLatitude(_ identifier: String) -> Double {
        let id = identifier.lowercased()
        if id.hasPrefix("antarctica/") { return -75 }
        if id.hasPrefix("arctic/") { return 78 }
        if id.hasPrefix("australia/") || id.hasPrefix("pacific/auckland") { return -36 }
        // Southern-hemisphere zones without a table entry. Getting the hemisphere wrong
        // inverts the seasons, so err toward a generic southern latitude for these.
        if id.contains("argentina") || id.contains("sao_paulo") || id.contains("santiago")
            || id.contains("montevideo") || id.hasPrefix("africa/johannesburg")
            || id.hasPrefix("africa/maseru") || id.hasPrefix("africa/mbabane")
            || id.hasPrefix("africa/gaborone") || id.hasPrefix("africa/blantyre")
            || id.hasPrefix("africa/lubumbashi") || id.hasPrefix("africa/kigali")
            || id.hasPrefix("africa/bujumbura") || id.hasPrefix("america/cuiaba")
            || id.hasPrefix("america/campo_grande") || id.hasPrefix("america/porto_velho")
            || id.hasPrefix("america/rio_branco") || id.hasPrefix("america/maceio")
            || id.hasPrefix("america/belem") || id.hasPrefix("america/araguaina")
            || id.hasPrefix("pacific/efate") || id.hasPrefix("pacific/norfolk")
            || id.hasPrefix("pacific/pitcairn")
            || id.hasPrefix("pacific/easter") || id.hasPrefix("pacific/rarotonga")
            || id.hasPrefix("pacific/niue") || id.hasPrefix("pacific/bougainville")
            || id.hasPrefix("indian/reunion") || id.hasPrefix("indian/mahe")
            || id.hasPrefix("indian/christmas") || id.hasPrefix("indian/cocos") {
            return -20
        }
        if id.hasPrefix("europe/") { return 50 }
        if id.hasPrefix("asia/") { return 30 }
        if id.hasPrefix("africa/") { return 5 }
        if id.hasPrefix("pacific/") { return 0 }
        if id.hasPrefix("atlantic/") { return 30 }
        if id.hasPrefix("indian/") { return -5 }
        return 40
    }
}
