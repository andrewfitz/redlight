import Foundation
import Testing
@testable import Redlight

@Suite struct SolarCurveTests {
    let presets = Preset.defaults
    // Day(1.0,1.0) Warm(0.7,0.85) Sunset(0.5,0.65) Night(0.25,0.45) Late(0.0,0.3)

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

    @Test func solarMidnightReachesLate() {
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

    @Test func shortNightStillReachesLateAtItsLowestPoint() {
        // Sun bottoms out at −10° (high-latitude summer): the night is stretched so its
        // lowest point is Late, and it still passes Night on the way down.
        let t = SolarCurve.target(elevation: -10, minElevation: -10, presets: presets)
        #expect(abs(t.intensity - 0.0) < 0.0001)
        #expect(abs(t.whitepoint - 0.3) < 0.0001)
        let night = SolarCurve.target(elevation: -7.5, minElevation: -10, presets: presets)
        #expect(abs(night.intensity - 0.25) < 0.0001)
        let sunset = SolarCurve.target(elevation: 0, minElevation: -10, presets: presets)
        #expect(abs(sunset.intensity - 0.5) < 0.0001)
    }

    @Test func shortNightStretchIsContinuousAtTheFloor() {
        for e in [-3.0, -9, -15, -20, -23] {
            let at = SolarCurve.target(elevation: e, minElevation: -24, presets: presets)
            let near = SolarCurve.target(elevation: e, minElevation: -23.999, presets: presets)
            #expect(abs(at.intensity - near.intensity) < 0.001)
        }
    }

    // MARK: - Anchors that move with the sun's range

    /// The sun's lowest and highest elevation on a spread of days through the year.
    private func ranges(latitude: Double) -> [(min: Double, max: Double)] {
        stride(from: 0.0, to: 365, by: 5).map { day in
            let date = Date(timeIntervalSince1970: 1_767_225_600 + day * 86_400)   // 2026-01-01
            return (SolarCalculator.elevationAtSolarMidnight(at: date, latitude: latitude, longitude: 0),
                    SolarCalculator.elevationAtSolarNoon(at: date, latitude: latitude, longitude: 0))
        }
    }

    private func target(_ elevation: Double, _ range: (min: Double, max: Double), rising: Bool)
        -> (intensity: Double, whitepoint: Double)
    {
        SolarCurve.target(elevation: elevation, minElevation: range.min, maxElevation: range.max,
                          rising: rising, presets: presets)
    }

    @Test func everyDayReachesDayAtSolarNoonAndLateAtSolarMidnight() {
        // Up to 84°: nearer the poles the sun's whole range is narrower than the curve.
        for latitude in [0.0, 35, 51.5, 56, 60, 64, 66.5, 68, 70, 78, 84, -34, -54, -70, -84] {
            for range in ranges(latitude: latitude) {
                for rising in [false, true] {
                    let noon = target(range.max, range, rising: rising)
                    #expect(noon.intensity == 1 && noon.whitepoint == 1, "noon at \(latitude)°, \(range)")
                    let midnight = target(range.min, range, rising: rising)
                    #expect(abs(midnight.intensity) < 1e-9 && abs(midnight.whitepoint - 0.3) < 1e-9,
                            "midnight at \(latitude)°, \(range)")
                }
            }
        }
    }

    @Test func morningAndEveningAgreeAtSolarNoonAndMidnightEverywhere() {
        for latitude in [56.0, 60, 64, 66.5, 68, 70, 78, 85, 88, 89.9, -66, -89.9] {
            for range in ranges(latitude: latitude) {
                for elevation in [range.max, range.min] {
                    let morning = target(elevation, range, rising: true)
                    let evening = target(elevation, range, rising: false)
                    #expect(abs(morning.intensity - evening.intensity) < 1e-9, "\(latitude)°, \(range)")
                    #expect(abs(morning.whitepoint - evening.whitepoint) < 1e-9, "\(latitude)°, \(range)")
                }
            }
        }
    }

    @Test func rangesThatCoverTheAnchorsLeaveTheCurveAlone() {
        for range in [(min: -6.0, max: 12.0), (min: -30.0, max: 40.0), (min: -70.0, max: 90.0)] {
            for rising in [false, true] {
                for elevation in stride(from: range.max, through: range.min, by: -0.75) {
                    let moved = target(elevation, range, rising: rising)
                    let fixed = SolarCurve.target(elevation: elevation, minElevation: range.min,
                                                  rising: rising, presets: presets)
                    #expect(moved.intensity == fixed.intensity && moved.whitepoint == fixed.whitepoint)
                }
            }
        }
    }

    @Test func aLowNoonBringsTheEveningDayAnchorDownToMeetIt() {
        // Stockholm at the winter solstice: the sun peaks at +7.2°.
        let range = (min: -54.0, max: 7.2)
        let noon = target(7.2, range, rising: false)
        #expect(noon.intensity == 1 && noon.whitepoint == 1)
        #expect(abs(target(3.6, range, rising: false).intensity - 0.7) < 1e-9)
        #expect(abs(target(0, range, rising: false).intensity - 0.5) < 1e-9)
        // Below the horizon, and all morning, nothing moves.
        for elevation in [6.0, 3, 0, -5, -20] {
            let moved = target(elevation, range, rising: true)
            let fixed = SolarCurve.target(elevation: elevation, minElevation: range.min, rising: true, presets: presets)
            #expect(moved.intensity == fixed.intensity)
        }
        #expect(target(-9, range, rising: false).intensity
                == SolarCurve.target(elevation: -9, minElevation: range.min, presets: presets).intensity)
    }

    @Test func theNightsDeepestValueHasNoCliffWhenTheSunStopsSetting() {
        // The midnight sun arrives over a few nights: the lowest point passes 0°.
        for elevation in [20.0, 9, 4, 1.5] {
            let before = target(elevation, (min: -0.01, max: 45), rising: false)
            let after = target(elevation, (min: 0.01, max: 45), rising: false)
            #expect(abs(before.intensity - after.intensity) < 0.01)
            #expect(abs(before.whitepoint - after.whitepoint) < 0.01)
        }
        // And the slide takes over from the stretch without a seam.
        for elevation in [8.0, 2, -1, -4, -5.9] {
            let stretched = target(elevation, (min: -6.001, max: 45), rising: false)
            let slid = target(elevation, (min: -5.999, max: 45), rising: false)
            #expect(abs(stretched.intensity - slid.intensity) < 0.001)
        }
    }

    @Test func polarNightStillReachesDayAtNoonAndLateAtMidnight() {
        // 70°N at the winter solstice: the sun peaks at −3.4°.
        let range = (min: -43.4, max: -3.4)
        for rising in [false, true] {
            #expect(target(-3.4, range, rising: rising).intensity == 1)
            #expect(abs(target(-43.4, range, rising: rising).intensity) < 1e-9)
        }
        #expect(target(-10, range, rising: false).intensity < 1)
    }

    @Test func morningClearsToDayFourDegreesAfterSunrise() {
        let morning = SolarCurve.target(elevation: 4, minElevation: -70, rising: true, presets: presets)
        let evening = SolarCurve.target(elevation: 4, minElevation: -70, rising: false, presets: presets)
        #expect(morning.intensity == 1.0 && morning.whitepoint == 1.0)
        #expect(evening.intensity < 1.0)
        let warm = SolarCurve.target(elevation: 2, minElevation: -70, rising: true, presets: presets)
        #expect(abs(warm.intensity - 0.7) < 0.0001)
    }

    @Test func morningMirrorsEveningUpToTheHorizon() {
        for e in [0.0, -3, -6, -12, -18, -40] {
            let morning = SolarCurve.target(elevation: e, minElevation: -70, rising: true, presets: presets)
            let evening = SolarCurve.target(elevation: e, minElevation: -70, rising: false, presets: presets)
            #expect(morning.intensity == evening.intensity)
            #expect(morning.whitepoint == evening.whitepoint)
        }
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
