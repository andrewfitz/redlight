import Foundation
import Testing
@testable import Redlight

@MainActor @Suite struct MenuBarViewTests {
    @Test func sunArcAccessibilityReportsCurrentElevationWithoutPhaseJargon() {
        let summary = SunArcView.accessibilitySummary(currentElevation: 0.8)
        #expect(summary.contains("Solar elevation +1°"))
        #expect(!summary.lowercased().contains("marker"))
        #expect(!summary.lowercased().contains("civil"))
        #expect(!summary.lowercased().contains("nautical"))
        #expect(!summary.lowercased().contains("astronomical"))
    }

    @Test func inlinePauseLengthsAreLabelledAndDispatchTheirLength() {
        #expect(PauseLengthRow.options.map(\.title) == ["30 m", "1 h", "2 h", "Until sunrise"])
        #expect(PauseLengthRow.options.map(\.accessibility) == [
            "Pause for 30 minutes", "Pause for 1 hour", "Pause for 2 hours", "Pause until sunrise",
        ])
        #expect(PauseLengthRow.options.map(\.length) == [
            .minutes(30), .minutes(60), .minutes(120), .untilSunrise,
        ])
    }

    @Test func bedtimeRowRoundTripsThroughItsTimeField() {
        #expect(BedtimeRow.suggested == Bedtime(hour: 22, minute: 30))
        for zone in ["UTC", "America/New_York", "Australia/Lord_Howe", "Asia/Kathmandu"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            for minute in stride(from: 0, to: 1440, by: 7) {
                let bedtime = Bedtime(minuteOfDay: minute)!
                #expect(BedtimeRow.bedtime(from: BedtimeRow.date(for: bedtime, calendar: calendar),
                                           calendar: calendar) == bedtime)
            }
        }
    }
}
