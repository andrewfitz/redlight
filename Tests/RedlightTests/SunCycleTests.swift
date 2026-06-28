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

    @Test func nextEventFallingIsSunset() throws {
        // Equator, mid-afternoon: sun well above horizon, falling → next crossing is sunset (0°).
        let now = date("2025-03-20T15:00:00Z")
        let c = SunCycle(now: now, latitude: 0, longitude: 0, calendar: utc())
        let event = try #require(c.nextEvent)
        #expect(event.label == "sunset")
        let atCrossing = SolarCalculator.elevation(
            at: now.addingTimeInterval(event.seconds), latitude: 0, longitude: 0)
        #expect(abs(atCrossing - 0) < 0.5)        // really at the horizon
    }

    @Test func nextEventRisingFromDeepNightIsFirstLight() throws {
        // Equator, ~3am: sun ≈ −45°, rising → first up-crossing is −18° (first light).
        let now = date("2025-03-20T03:00:00Z")
        let c = SunCycle(now: now, latitude: 0, longitude: 0, calendar: utc())
        let event = try #require(c.nextEvent)
        #expect(event.label == "first light")
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
}
