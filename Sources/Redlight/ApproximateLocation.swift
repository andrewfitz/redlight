import Foundation

/// City-level coordinate inferred from the Mac's time zone. Used when Core Location cannot
/// get a fix (common on desktop Macs that are ethernet-only, with no Wi-Fi scan for
/// triangulation) so Adaptive and the sun-arc graphic still have a solar position to follow.
enum ApproximateLocation {
    static func from(_ timeZone: TimeZone) -> (latitude: Double, longitude: Double) {
        if let known = coordinates[timeZone.identifier] { return known }
        let longitude = Double(timeZone.secondsFromGMT()) / 240.0
        return (inferredLatitude(timeZone.identifier), longitude)
    }

    /// Representative coordinates of the IANA zone's named city. Close enough for solar
    /// elevation; Core Location replaces this whenever a real fix arrives.
    private static let coordinates: [String: (latitude: Double, longitude: Double)] = [
        "America/New_York": (40.71, -74.01),
        "America/Chicago": (41.85, -87.65),
        "America/Denver": (39.74, -104.98),
        "America/Los_Angeles": (34.05, -118.24),
        "America/Anchorage": (61.22, -149.90),
        "America/Adak": (51.88, -176.66),
        "America/Phoenix": (33.45, -112.07),
        "America/Boise": (43.62, -116.20),
        "America/Detroit": (42.33, -83.05),
        "America/Indiana/Indianapolis": (39.77, -86.16),
        "America/Kentucky/Louisville": (38.25, -85.76),
        "America/Toronto": (43.65, -79.38),
        "America/Vancouver": (49.28, -123.12),
        "America/Edmonton": (53.55, -113.49),
        "America/Winnipeg": (49.90, -97.14),
        "America/Halifax": (44.65, -63.57),
        "America/St_Johns": (47.56, -52.71),
        "America/Mexico_City": (19.43, -99.13),
        "America/Tijuana": (32.51, -117.04),
        "America/Sao_Paulo": (-23.55, -46.63),
        "America/Argentina/Buenos_Aires": (-34.60, -58.38),
        "America/Santiago": (-33.45, -70.67),
        "America/Bogota": (4.71, -74.07),
        "America/Lima": (-12.05, -77.04),
        "America/Caracas": (10.48, -66.90),
        "Europe/London": (51.51, -0.13),
        "Europe/Dublin": (53.35, -6.26),
        "Europe/Lisbon": (38.72, -9.14),
        "Europe/Paris": (48.86, 2.35),
        "Europe/Berlin": (52.52, 13.40),
        "Europe/Amsterdam": (52.37, 4.89),
        "Europe/Brussels": (50.85, 4.35),
        "Europe/Madrid": (40.42, -3.70),
        "Europe/Rome": (41.90, 12.50),
        "Europe/Zurich": (47.38, 8.54),
        "Europe/Vienna": (48.21, 16.37),
        "Europe/Prague": (50.08, 14.44),
        "Europe/Warsaw": (52.23, 21.01),
        "Europe/Stockholm": (59.33, 18.07),
        "Europe/Oslo": (59.91, 10.75),
        "Europe/Copenhagen": (55.68, 12.57),
        "Europe/Helsinki": (60.17, 24.94),
        "Europe/Athens": (37.98, 23.73),
        "Europe/Bucharest": (44.43, 26.10),
        "Europe/Moscow": (55.76, 37.62),
        "Europe/Istanbul": (41.01, 28.98),
        "Africa/Cairo": (30.04, 31.24),
        "Africa/Johannesburg": (-26.20, 28.04),
        "Africa/Lagos": (6.52, 3.38),
        "Africa/Nairobi": (-1.29, 36.82),
        "Asia/Tokyo": (35.68, 139.69),
        "Asia/Seoul": (37.57, 126.98),
        "Asia/Shanghai": (31.23, 121.47),
        "Asia/Hong_Kong": (22.32, 114.17),
        "Asia/Taipei": (25.03, 121.57),
        "Asia/Singapore": (1.35, 103.82),
        "Asia/Bangkok": (13.76, 100.50),
        "Asia/Jakarta": (-6.21, 106.85),
        "Asia/Manila": (14.60, 120.98),
        "Asia/Kolkata": (22.57, 88.36),
        "Asia/Dubai": (25.20, 55.27),
        "Asia/Tehran": (35.69, 51.39),
        "Asia/Jerusalem": (31.77, 35.22),
        "Australia/Sydney": (-33.87, 151.21),
        "Australia/Melbourne": (-37.81, 144.96),
        "Australia/Brisbane": (-27.47, 153.03),
        "Australia/Perth": (-31.95, 115.86),
        "Australia/Adelaide": (-34.93, 138.60),
        "Australia/Hobart": (-42.88, 147.33),
        "Pacific/Auckland": (-36.85, 174.76),
        "Pacific/Honolulu": (21.31, -157.86),
        "Pacific/Fiji": (-18.14, 178.44),
        "Atlantic/Reykjavik": (64.15, -21.94),
    ]

    private static func inferredLatitude(_ identifier: String) -> Double {
        let id = identifier.lowercased()
        if id.hasPrefix("antarctica/") { return -75 }
        if id.hasPrefix("arctic/") { return 78 }
        if id.hasPrefix("australia/") || id.hasPrefix("pacific/auckland") { return -36 }
        if id.contains("argentina") || id.contains("sao_paulo") || id.contains("santiago")
            || id.contains("montevideo") || id.hasPrefix("africa/johannesburg") {
            return -34
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
