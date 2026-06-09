import Foundation

/// Pure NOAA solar-position math. No system/location dependencies.
enum SolarCalculator {
    /// Sun elevation in degrees above the horizon at `date` for the location.
    static func elevation(at date: Date, latitude: Double, longitude: Double) -> Double {
        let t = julianCentury(date)
        let decl = solarDeclination(t)
        let eqTime = equationOfTime(t)

        let trueSolarTime = (utcMinutes(date) + eqTime + 4 * longitude)
            .truncatingRemainder(dividingBy: 1440)
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let latR = rad(latitude), declR = rad(decl), haR = rad(hourAngle)
        let cosZenith = sin(latR) * sin(declR) + cos(latR) * cos(declR) * cos(haR)
        let zenith = acos(min(1, max(-1, cosZenith)))
        return 90 - deg(zenith)
    }

    /// Sun elevation in degrees at the night's lowest point (lower culmination):
    /// closed form `|latitude + declination| − 90` (independent of longitude).
    static func elevationAtSolarMidnight(at date: Date, latitude: Double, longitude: Double) -> Double {
        let decl = solarDeclination(julianCentury(date))
        return abs(latitude + decl) - 90
    }

    // MARK: - NOAA intermediate terms (all angles in degrees)

    private static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }
    private static func julianCentury(_ date: Date) -> Double {
        (julianDay(date) - 2451545.0) / 36525.0
    }
    private static func utcMinutes(_ date: Date) -> Double {
        let dayFraction = date.timeIntervalSince1970 / 86400.0
        return (dayFraction - floor(dayFraction)) * 1440.0
    }

    private static func solarDeclination(_ t: Double) -> Double {
        let obliq = obliquityCorrected(t)
        let lambda = sunApparentLongitude(t)
        return deg(asin(sin(rad(obliq)) * sin(rad(lambda))))
    }

    private static func equationOfTime(_ t: Double) -> Double {
        let l0 = geomMeanLongitude(t)
        let m = geomMeanAnomaly(t)
        let e = eccentricity(t)
        let y = pow(tan(rad(obliquityCorrected(t) / 2)), 2)
        let term = y * sin(2 * rad(l0))
            - 2 * e * sin(rad(m))
            + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
            - 0.5 * y * y * sin(4 * rad(l0))
            - 1.25 * e * e * sin(2 * rad(m))
        return 4 * deg(term) // minutes
    }

    private static func geomMeanLongitude(_ t: Double) -> Double {
        (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
    }
    private static func geomMeanAnomaly(_ t: Double) -> Double {
        357.52911 + t * (35999.05029 - 0.0001537 * t)
    }
    private static func eccentricity(_ t: Double) -> Double {
        0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    }
    private static func sunEquationOfCenter(_ t: Double) -> Double {
        let m = geomMeanAnomaly(t)
        return sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(rad(2 * m)) * (0.019993 - 0.000101 * t)
            + sin(rad(3 * m)) * 0.000289
    }
    private static func sunApparentLongitude(_ t: Double) -> Double {
        let trueLong = geomMeanLongitude(t) + sunEquationOfCenter(t)
        return trueLong - 0.00569 - 0.00478 * sin(rad(125.04 - 1934.136 * t))
    }
    private static func obliquityCorrected(_ t: Double) -> Double {
        let seconds = 21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))
        let mean = 23 + (26 + seconds / 60) / 60
        return mean + 0.00256 * cos(rad(125.04 - 1934.136 * t))
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }
}
