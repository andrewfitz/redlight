import Testing
@testable import Redlight

@Suite struct SolarCurveTests {
    let presets = Preset.defaults
    // Day(1.0,1.0) Warm(0.7,0.85) Sunset(0.5,0.65) Night(0.25,0.45) DeepRed(0.0,0.3)

    @Test func daytimeAboveRampIsDay() {
        let t = SolarCurve.target(elevation: 30, minElevation: -70, presets: presets)
        #expect(t.intensity == 1.0)
        #expect(t.whitepoint == 1.0)
    }

    @Test func warmAnchorIsGoldenHour() {
        let t = SolarCurve.target(elevation: 6, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - 0.7) < 0.0001)
        #expect(abs(t.whitepoint - 0.85) < 0.0001)
    }

    @Test func sunsetAnchorIsAtTheHorizon() {
        let t = SolarCurve.target(elevation: 0, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - 0.5) < 0.0001)
        #expect(abs(t.whitepoint - 0.65) < 0.0001)
    }

    @Test func fortyFiveMinutesBeforeSunsetIsAlreadyWarming() {
        // Nashville in midsummer is about +8.3° when geometric sunset is 45 minutes away.
        let t = SolarCurve.target(elevation: 8.3, minElevation: -75, presets: presets)
        #expect(t.intensity < 1.0 && t.intensity > 0.7)
        #expect(t.whitepoint < 1.0 && t.whitepoint > 0.85)
    }

    @Test func civilDuskUsesFirstTwilightStep() {
        let t = SolarCurve.target(elevation: -6, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - (0.5 + (0.25 - 0.5) / 3)) < 0.0001)
        #expect(abs(t.whitepoint - (0.65 + (0.45 - 0.65) / 3)) < 0.0001)
    }

    @Test func nauticalDuskUsesSecondTwilightStep() {
        let t = SolarCurve.target(elevation: -12, minElevation: -70, presets: presets)
        #expect(abs(t.intensity - (0.5 + 2 * (0.25 - 0.5) / 3)) < 0.0001)
        #expect(abs(t.whitepoint - (0.65 + 2 * (0.45 - 0.65) / 3)) < 0.0001)
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

    @Test func civilTwilightBetweenSunsetAndNight() {
        let t = SolarCurve.target(elevation: -3, minElevation: -70, presets: presets)
        #expect(t.intensity < 0.5 && t.intensity > 0.25)
    }

    @Test func deepeningIsMonotonic() {
        let elevations = [30.0, 12, 8.3, 6, 0, -6, -12, -18, -30]
        let vals = elevations.map {
            SolarCurve.target(elevation: $0, minElevation: -70, presets: presets).intensity
        }
        for i in 1..<vals.count { #expect(vals[i - 1] >= vals[i]) }
    }

    @Test func shallowNightNeverReachesDeepRed() {
        // Sun bottoms out at −10° → deepest sample stays on the twilight leg, not Deep Red.
        let t = SolarCurve.target(elevation: -10, minElevation: -10, presets: presets)
        #expect(t.intensity < 0.5 && t.intensity > 0.25)
    }

    @Test func phaseLabelsFollowTheSameElevationMarkers() {
        #expect(SolarCurve.phaseLabel(elevation: 15) == "day")
        #expect(SolarCurve.phaseLabel(elevation: 8) == "low sun")
        #expect(SolarCurve.phaseLabel(elevation: 3) == "golden hour")
        #expect(SolarCurve.phaseLabel(elevation: -3) == "civil twilight")
        #expect(SolarCurve.phaseLabel(elevation: -9) == "nautical twilight")
        #expect(SolarCurve.phaseLabel(elevation: -15) == "astronomical twilight")
        #expect(SolarCurve.phaseLabel(elevation: -30) == "night")
    }
}
