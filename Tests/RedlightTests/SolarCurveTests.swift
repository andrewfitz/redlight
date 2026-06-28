import Testing
@testable import Redlight

@Suite struct SolarCurveTests {
    let presets = Preset.defaults
    // Day(1.0,1.0) Warm(0.7,0.85) Sunset(0.5,0.65) Night(0.25,0.45) DeepRed(0.0,0.3)

    @Test func daytimeIsDay() {
        let t = SolarCurve.target(elevation: 10, minElevation: -70, presets: presets)
        #expect(t.intensity == 1.0)
        #expect(t.whitepoint == 1.0)
    }

    @Test func civilDuskReachesWarm() {
        let t = SolarCurve.target(elevation: -6, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - 0.7) < 0.0001)
        #expect(abs(t.whitepoint - 0.85) < 0.0001)
    }

    @Test func nauticalDuskReachesSunset() {
        let t = SolarCurve.target(elevation: -12, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - 0.5) < 0.0001)
        #expect(abs(t.whitepoint - 0.65) < 0.0001)
    }

    @Test func astronomicalDuskReachesNight() {
        let t = SolarCurve.target(elevation: -18, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - 0.25) < 0.0001)
        #expect(abs(t.whitepoint - 0.45) < 0.0001)
    }

    @Test func solarMidnightReachesDeepRed() {
        let t = SolarCurve.target(elevation: -70, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - 0.0) < 0.0001)
        #expect(abs(t.whitepoint - 0.3) < 0.0001)
    }

    @Test func civilTwilightBetweenDayAndWarm() {
        let t = SolarCurve.target(elevation: -3, minElevation: -70, presets: presets)
        #expect(t.intensity < 1.0 && t.intensity > 0.7)
    }

    @Test func deepeningIsMonotonic() {
        let elevations = [0.0, -6, -12, -18, -30]
        let vals = elevations.map {
            SolarCurve.target(elevation: $0, minElevation: -70, presets: presets).intensity
        }
        for i in 1..<vals.count { #expect(vals[i - 1] >= vals[i]) }
    }

    @Test func shallowNightNeverReachesDeepRed() {
        // Sun bottoms out at −10° → deepest sample lands between Warm and Sunset, not Deep Red.
        let t = SolarCurve.target(elevation: -10, minElevation: -10, presets: presets)
        #expect(t.intensity < 0.7 && t.intensity > 0.5)
    }
}
