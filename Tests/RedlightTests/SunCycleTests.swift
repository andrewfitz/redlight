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
}
