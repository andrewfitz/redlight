import Testing
import Foundation
@testable import Redlight

@Suite struct SolarCalculatorTests {
    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    @Test func noonAtEquatorEquinoxIsHigh() {
        let elev = SolarCalculator.elevation(
            at: date("2025-03-20T12:00:00Z"), latitude: 0, longitude: 0)
        #expect(elev > 80)
    }

    @Test func londonSummerNoonElevation() {
        // London ≈ solar noon ~12:02 UTC on the June solstice; alt ≈ 62°.
        let elev = SolarCalculator.elevation(
            at: date("2025-06-21T12:00:00Z"), latitude: 51.5, longitude: -0.13)
        #expect(elev > 58 && elev < 65)
    }

    @Test func midnightIsBelowHorizon() {
        let elev = SolarCalculator.elevation(
            at: date("2025-03-20T00:00:00Z"), latitude: 0, longitude: 0)
        #expect(elev < -80)
    }

    @Test func solarMidnightElevationPolarSummerIsAboveHorizon() {
        // North pole, June solstice: midnight sun ≈ +23°.
        let m = SolarCalculator.elevationAtSolarMidnight(
            at: date("2025-06-21T00:00:00Z"), latitude: 90, longitude: 0)
        #expect(m > 21 && m < 25)
    }

    @Test func solarMidnightElevationPolarWinterIsBelowHorizon() {
        let m = SolarCalculator.elevationAtSolarMidnight(
            at: date("2025-12-21T00:00:00Z"), latitude: 90, longitude: 0)
        #expect(m < -21 && m > -25)
    }

    @Test func solarMidnightElevationEquatorEquinoxIsStraightDown() {
        let m = SolarCalculator.elevationAtSolarMidnight(
            at: date("2025-03-20T00:00:00Z"), latitude: 0, longitude: 0)
        #expect(m < -88)
    }

    @Test func solarMidnightEquatorDecemberUsesAbsoluteValue() {
        // |0 + (−23.44)| − 90 ≈ −66.6 (a signed formula would give −113, far out of range).
        let m = SolarCalculator.elevationAtSolarMidnight(
            at: date("2025-12-21T00:00:00Z"), latitude: 0, longitude: 0)
        #expect(m < -64 && m > -70)
    }

    @Test func solarNoonElevationEquatorEquinox() {
        let n = SolarCalculator.elevationAtSolarNoon(
            at: date("2025-03-20T12:00:00Z"), latitude: 0, longitude: 0)
        #expect(abs(n - 90) < 1.0)        // sun overhead at equinox on the equator
    }

    @Test func solarNoonElevationLondonSummer() {
        let n = SolarCalculator.elevationAtSolarNoon(
            at: date("2025-06-21T12:00:00Z"), latitude: 51.5, longitude: -0.13)
        #expect(n > 58 && n < 65)         // ≈ 61.9°
    }
}
