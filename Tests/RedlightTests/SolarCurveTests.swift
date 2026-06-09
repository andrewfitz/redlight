import Testing
@testable import Redlight

@Suite struct SolarCurveTests {
    let presets = Preset.defaults
    // defaults: Day(1.0,1.0)  Night[3](0.25,0.45)  Deep Red[4](0.0,0.3)

    @Test func daytimeIsDay() {
        let t = SolarCurve.target(elevation: 10, minElevation: -70, presets: presets)
        #expect(t.intensity == 1.0)
        #expect(t.whitepoint == 1.0)
    }

    @Test func civilDuskReachesNight() {
        let t = SolarCurve.target(elevation: -6, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - 0.25) < 0.0001)
        #expect(abs(t.whitepoint - 0.45) < 0.0001)
    }

    @Test func solarMidnightReachesDeepRed() {
        let t = SolarCurve.target(elevation: -70, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - 0.0) < 0.0001)
        #expect(abs(t.whitepoint - 0.3) < 0.0001)
    }

    @Test func twilightIsBetweenDayAndNight() {
        let t = SolarCurve.target(elevation: -3, minElevation: -70, presets: presets)
        #expect(t.intensity < 1.0 && t.intensity > 0.25)
    }

    @Test func deepeningIsMonotonic() {
        let a = SolarCurve.target(elevation: 0,   minElevation: -70, presets: presets).intensity
        let b = SolarCurve.target(elevation: -3,  minElevation: -70, presets: presets).intensity
        let c = SolarCurve.target(elevation: -6,  minElevation: -70, presets: presets).intensity
        let d = SolarCurve.target(elevation: -30, minElevation: -70, presets: presets).intensity
        #expect(a >= b && b >= c && c >= d)
    }

    @Test func shallowNightHoldsAtNight() {
        // minElevation above -6 → no Night→DeepRed segment; deep night holds at Night.
        let t = SolarCurve.target(elevation: -10, minElevation: -3, presets: presets)
        #expect(abs(t.intensity - 0.25) < 0.0001)
    }
}
