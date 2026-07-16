import Testing
@testable import Redlight

@Suite struct AdaptiveMappingTests {
    let presets = Preset.defaults
    // Day(1.0,1.0) Warm(0.7,0.85) Sunset(0.5,0.65) Night(0.25,0.45) DeepRed(0.0,0.3)

    func banded(elevation: Double, iMin: Double = 0, iMax: Double = 1,
                wMin: Double = 0.3, wMax: Double = 1, presets: [Preset]? = nil)
        -> (intensity: Double, whitepoint: Double)
    {
        AdaptiveMapping.banded(
            elevation: elevation, minElevation: -70, presets: presets ?? self.presets,
            intensityMin: iMin, intensityMax: iMax, whitepointMin: wMin, whitepointMax: wMax)
    }

    @Test func dayMapsToBandMax() {
        let t = banded(elevation: 30, iMin: 0.2, iMax: 0.8)
        #expect(abs(t.intensity - 0.8) < 1e-9)
    }

    @Test func solarMidnightMapsToBandMin() {
        let t = banded(elevation: -70, iMin: 0.2, iMax: 0.8)
        #expect(abs(t.intensity - 0.2) < 1e-9)
    }

    @Test func factoryWhitepointBandPreservesNamedPresetAnchors() {
        let anchors: [(elevation: Double, preset: Int)] = [
            (30, 0), (6, 1), (0, 2), (-18, 3), (-70, 4),
        ]
        for anchor in anchors {
            let target = banded(elevation: anchor.elevation)
            #expect(abs(target.whitepoint - presets[anchor.preset].whitepoint) < 1e-9)
        }
    }

    @Test func resultAlwaysInsideBand() {
        for elev in stride(from: 20.0, through: -70.0, by: -5) {
            let t = banded(elevation: elev, iMin: 0.3, iMax: 0.6, wMin: 0.5, wMax: 0.7)
            #expect(t.intensity >= 0.3 - 1e-9 && t.intensity <= 0.6 + 1e-9)
            #expect(t.whitepoint >= 0.5 - 1e-9 && t.whitepoint <= 0.7 + 1e-9)
        }
    }

    @Test func invertedBandArgumentsAreNormalized() {
        let t = banded(elevation: 30, iMin: 0.8, iMax: 0.2)   // lo/hi swapped
        #expect(abs(t.intensity - 0.8) < 1e-9)                // day still maps to the high end
    }

    @Test func flatIntensityAnchorsClampInsteadOfPinningToMax() {
        // User saved Day.intensity == Deep Red.intensity → no Day…Deep span to normalize.
        // The old `frac = 1` fallback pinned the output to the band max at ALL elevations;
        // it must clamp the raw curve value into the band instead.
        var p = presets
        p[0].intensity = 0.5
        p[4].intensity = 0.5
        let night = banded(elevation: -70, iMin: 0.2, iMax: 0.8, presets: p)
        #expect(abs(night.intensity - 0.5) < 1e-9)            // not 0.8
        let day = banded(elevation: 30, iMin: 0.2, iMax: 0.8, presets: p)
        #expect(abs(day.intensity - 0.5) < 1e-9)
    }

    @Test func flatAnchorsStillRespectBandLimits() {
        var p = presets
        p[0].intensity = 0.9
        p[4].intensity = 0.9
        let t = banded(elevation: 30, iMin: 0.2, iMax: 0.6, presets: p)
        #expect(abs(t.intensity - 0.6) < 1e-9)                // raw 0.9 clamped to band max
    }

    @Test func shortPresetListFallsBackToRawTarget() {
        let t = AdaptiveMapping.banded(
            elevation: 10, minElevation: -70, presets: [],
            intensityMin: 0.2, intensityMax: 0.8, whitepointMin: 0.3, whitepointMax: 1)
        #expect(t.intensity == 1.0)
        #expect(t.whitepoint == 1.0)
    }
}
