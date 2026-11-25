import Testing
import Foundation
@testable import Redlight

@Suite struct SunCycleTests {
    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func dayEndsAtMidnightAfterSkippedMidnight() {
        var calendar = utc()
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let cycle = SunCycle(now: date("2018-11-04T12:00:00Z"), latitude: -23.55,
                             longitude: -46.63, calendar: calendar)
        #expect(cycle.samples.first?.date == date("2018-11-04T03:00:00Z"))
        #expect(cycle.samples.last?.date == date("2018-11-05T02:00:00Z"))
    }

    @Test func crossingCanLandExactlyAtEndOfScan() {
        let now = date("2025-03-20T06:00:00Z")
        for horizon in [60.0, 120.0, 150.0] {
            let threshold = SolarCalculator.elevation(at: now.addingTimeInterval(horizon),
                                                     latitude: 0, longitude: 0)
            let event = SunCycle.findNextEvent(now: now, latitude: 0, longitude: 0,
                                               thresholds: [threshold], rising: true, horizon: horizon)
            #expect(event?.seconds == horizon)
        }
    }

    @Test func samplesSpanDayMonotonically() {
        let c = SunCycle(now: date("2025-03-20T15:00:00Z"),
                         latitude: 0, longitude: 0, calendar: utc())
        #expect(c.samples.count == 73)
        #expect(c.samples.first!.t == 0)
        #expect(abs(c.samples.last!.t - 1) < 1e-9)
        for i in 1..<c.samples.count { #expect(c.samples[i].t > c.samples[i - 1].t) }
    }

    @Test func nextEventFallingUsesFirstAdaptiveDegreeMarker() throws {
        // Equator, mid-afternoon: the next curve anchor is +12°, well before sunset.
        let now = date("2025-03-20T15:00:00Z")
        let c = SunCycle(now: now, latitude: 0, longitude: 0, calendar: utc())
        let event = try #require(c.nextEvent)
        #expect(event.elevation == SolarCurve.dayElevation)
        let atCrossing = SolarCalculator.elevation(
            at: now.addingTimeInterval(event.seconds), latitude: 0, longitude: 0)
        #expect(abs(atCrossing - SolarCurve.dayElevation) < 0.5)
    }

    @Test func nextEventRisingFromDeepNightIsFirstLight() throws {
        // Equator, ~3am: sun ≈ −45°, rising → first up-crossing is −18° (first light).
        let now = date("2025-03-20T03:00:00Z")
        let c = SunCycle(now: now, latitude: 0, longitude: 0, calendar: utc())
        let event = try #require(c.nextEvent)
        #expect(event.label == "first light")
        #expect(event.elevation == SolarCurve.nightElevation)
        let atCrossing = SolarCalculator.elevation(
            at: now.addingTimeInterval(event.seconds), latitude: 0, longitude: 0)
        #expect(abs(atCrossing - (-18)) < 0.5)
    }

    @Test func polarDayHasNoNextEvent() {
        // Near the north pole at the June solstice the sun never crosses a threshold.
        let c = SunCycle(now: date("2025-06-21T12:00:00Z"),
                         latitude: 89.9, longitude: 0, calendar: utc())
        #expect(c.nextEvent == nil)
        #expect(c.maxElevation > 0)               // and stays up all day
    }

    @Test func polarNightHasNoNextEvent() {
        // North pole in December: the sun stays below −18° all day — no transitions.
        let c = SunCycle(now: date("2025-12-21T12:00:00Z"),
                         latitude: 89.9, longitude: 0, calendar: utc())
        #expect(c.nextEvent == nil)
        #expect(c.nowElevation < -18)
    }

    @Test func nextSunriseSkipsTheSunsetAhead() throws {
        // Equator, mid-afternoon: the first horizon crossing is sunset, not sunrise.
        let now = date("2025-03-20T15:00:00Z")
        #expect(SunCycle.findNextEvent(now: now, latitude: 0, longitude: 0, thresholds: [0])?.label == "sunset")
        let sunrise = try #require(SunCycle.nextSunrise(after: now, latitude: 0, longitude: 0))
        #expect(sunrise.timeIntervalSince(now) > 12 * 3_600)
        #expect(sunrise.timeIntervalSince(now) < 24 * 3_600)
        // The apparent sunrise: the sun's centre is still 0.833° below the geometric horizon.
        #expect(abs(SolarCalculator.elevation(at: sunrise, latitude: 0, longitude: 0)
                    - SolarCurve.apparentHorizonElevation) < 0.01)
        #expect(SolarCalculator.elevation(at: sunrise.addingTimeInterval(-600), latitude: 0, longitude: 0) < 0)
        #expect(SolarCalculator.elevation(at: sunrise.addingTimeInterval(600), latitude: 0, longitude: 0) > 0)
    }

    @Test func nextSunriseBeforeDawnIsThatMorning() throws {
        let now = date("2025-03-20T03:00:00Z")
        let sunrise = try #require(SunCycle.nextSunrise(after: now, latitude: 0, longitude: 0))
        #expect(sunrise.timeIntervalSince(now) > 2 * 3_600)
        #expect(sunrise.timeIntervalSince(now) < 4 * 3_600)
    }

    @Test func shortNightBetweenScanSamplesStillHasSunsetAndSunrise() throws {
        // Near the Arctic Circle on the solstice, the sun dips below the horizon for seconds.
        let now = date("2025-06-22T00:01:00Z")
        let latitude = 66.5642325
        func elevation(_ seconds: Double) -> Double {
            SolarCalculator.elevation(at: now.addingTimeInterval(seconds), latitude: latitude, longitude: 0)
        }
        #expect(elevation(0) > 0 && elevation(60) < 0 && elevation(120) > 0)
        let sunset = try #require(SunCycle.findNextEvent(now: now, latitude: latitude, longitude: 0,
                                                         thresholds: [0], horizon: 120))
        let sunrise = try #require(SunCycle.findNextEvent(now: now, latitude: latitude, longitude: 0,
                                                          thresholds: [0], rising: true, horizon: 300))
        #expect(sunset.label == "sunset")
        #expect((50...57).contains(sunset.seconds))
        #expect(sunrise.label == "sunrise")
        #expect((63...70).contains(sunrise.seconds))
        // The sun never reaches the apparent horizon that night, so no sunrise is announced.
        #expect(SunCycle.nextSunrise(after: now, latitude: latitude, longitude: 0) == nil)
    }

    @Test func resumingAtAnEventDoesNotRepeatTheCrossing() throws {
        for (time, rising) in [("2025-03-20T06:00:00Z", true), ("2025-03-20T18:00:00Z", false)] {
            let now = date(time)
            let threshold = SolarCalculator.elevation(at: now.addingTimeInterval(31.5),
                                                      latitude: 0, longitude: 0)
            let event = try #require(SunCycle.findNextEvent(now: now, latitude: 0, longitude: 0,
                                                            thresholds: [threshold], rising: rising, horizon: 120))
            let resumed = now.addingTimeInterval(event.seconds)
            #expect(SunCycle.findNextEvent(now: resumed, latitude: 0, longitude: 0,
                                           thresholds: [threshold], horizon: 120) == nil)
        }
    }

    @Test func multipleCrossingsInOneStepChooseTheFirstInEitherDirection() throws {
        for (time, isRising) in [("2025-03-20T06:00:00Z", true), ("2025-03-20T18:00:00Z", false)] {
            let now = date(time)
            let first = SolarCalculator.elevation(at: now.addingTimeInterval(30), latitude: 0, longitude: 0)
            let second = SolarCalculator.elevation(at: now.addingTimeInterval(90), latitude: 0, longitude: 0)
            let event = try #require(SunCycle.findNextEvent(now: now, latitude: 0, longitude: 0,
                                                            thresholds: [second, first], rising: isRising))
            #expect(event.elevation == first)
            #expect(abs(event.seconds - 30) < 1)
        }
    }

    @Test func polarDayAndNightHaveNoSunrise() {
        #expect(SunCycle.nextSunrise(after: date("2025-06-21T12:00:00Z"), latitude: 89.9, longitude: 0) == nil)
        #expect(SunCycle.nextSunrise(after: date("2025-12-21T12:00:00Z"), latitude: 89.9, longitude: 0) == nil)
    }

    @Test func degenerateSampleCountDoesNotCrash() {
        // sampleCount < 2 used to divide by zero (t = i / (sampleCount − 1)).
        let c = SunCycle(now: date("2025-03-20T15:00:00Z"),
                         latitude: 0, longitude: 0, calendar: utc(), sampleCount: 1)
        #expect(c.samples.count == 2)
        #expect(c.samples.first!.t == 0)
        #expect(abs(c.samples.last!.t - 1) < 1e-9)
    }

    @Test func crossingLandsOnThresholdFromAllPhases() {
        // Sweep several start times; every reported event must actually sit on one of
        // the thresholds (bisection convergence + earliest-crossing selection).
        for hour in ["01", "05", "09", "13", "17", "21"] {
            let now = date("2025-03-20T\(hour):00:00Z")
            let c = SunCycle(now: now, latitude: 40, longitude: -74, calendar: utc())
            guard let event = c.nextEvent else { continue }
            let elev = SolarCalculator.elevation(
                at: now.addingTimeInterval(event.seconds), latitude: 40, longitude: -74)
            let nearest = SunCycle.thresholds.map { abs(elev - $0) }.min()!
            #expect(nearest < 0.5)
            #expect(event.seconds >= 0 && event.seconds <= 86_400)
        }
    }

    @Test func adaptiveElevationMarkersCrossTheArcAtDawnAndDusk() throws {
        let cycle = SunCycle(now: date("2025-03-20T12:00:00Z"),
                             latitude: 0, longitude: 0, calendar: utc())
        for marker in SolarCurve.elevationMarkers {
            let crossings = cycle.crossingFractions(at: marker.elevation)
            try #require(crossings.count == 2)
            #expect(crossings[0] < cycle.nowFraction)
            #expect(crossings[1] > cycle.nowFraction)
        }
    }

    @Test func nextSunriseIsFoundJustAfterALaterAutumnSunrise() throws {
        // 65°N in October: each sunrise is minutes later than the last, so a minute after
        // one sunrise the next is more than 24 hours away.
        let start = Date(timeIntervalSince1970: 1_790_812_800)   // 2026-10-01 00:00 UTC
        let first = try #require(SunCycle.nextSunrise(after: start, latitude: 65, longitude: 0))
        let after = first.addingTimeInterval(60)
        let second = try #require(SunCycle.nextSunrise(after: after, latitude: 65, longitude: 0))
        let gap = second.timeIntervalSince(after)
        #expect(gap > 86_400 - 60 && gap < 90_000)
    }
}
