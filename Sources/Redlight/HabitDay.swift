import Foundation

/// The learning day: 04:00 to 04:00 local, so that an evening and the night after it are one
/// day's evidence.
enum HabitDay {
    static let rolloverHour = 4

    private static var rollover: DateComponents { DateComponents(hour: rolloverHour, minute: 0, second: 0) }

    /// A day is never shorter than this. One that would be is a day begun on another time
    /// zone's clock, after a move west; it runs on to the following 04:00. A move east only
    /// shortens a day, and never below this, so days run from 12 to 36 hours.
    static let shortestDay: TimeInterval = 12 * 3600

    /// The latest 04:00 at or before `date`.
    static func start(containing date: Date, calendar: Calendar) -> Date {
        // The search is for a time strictly before its start, so begin just after `date`
        // to find a 04:00 that `date` is exactly on, and step back if that overshot.
        var found = calendar.nextDate(
            after: date.addingTimeInterval(1), matching: rollover, matchingPolicy: .nextTime,
            direction: .backward)
        if let overshot = found, overshot > date {
            found = calendar.nextDate(
                after: overshot, matching: rollover, matchingPolicy: .nextTime, direction: .backward)
        }
        return found ?? date.addingTimeInterval(-86_400)
    }

    /// The 04:00 that ends the day `start` opened. A day is 23 or 25 hours when the clocks
    /// change. After a move west the next local 04:00 can be a few hours off; a day that
    /// short would close on almost no evidence, so it ends at the 04:00 after.
    static func end(of start: Date, calendar: Calendar) -> Date {
        var end = calendar.nextDate(after: start, matching: rollover, matchingPolicy: .nextTime)
            ?? start.addingTimeInterval(86_400)
        if end.timeIntervalSince(start) < shortestDay {
            end = calendar.nextDate(after: end, matching: rollover, matchingPolicy: .nextTime)
                ?? end.addingTimeInterval(86_400)
        }
        return end
    }

    /// The seconds each anchor's stretch of the curve lasts between two times at a place:
    /// what the day offered, whether or not anyone was at the screen. Indexed by
    /// `SolarCurve.Anchor.rawValue`. An anchor the sun does not reach that day gets 0, so
    /// "half of what was offered" never asks more of it than the day had.
    static func offer(
        from start: Date, to end: Date, latitude: Double, longitude: Double, step: TimeInterval = 60
    ) -> [Double] {
        var offer = Array(repeating: 0.0, count: SolarCurve.Anchor.allCases.count)
        guard end > start, step > 0 else { return offer }
        var date = start
        while date < end {
            // The final sample can cover less than `step` seconds. Counting a full
            // interval there overstates the sun's offer and can make a barely attended
            // anchor satisfy the half-of-offer threshold at day close.
            let duration = min(step, end.timeIntervalSince(date))
            let solar = SolarCalculator.positionAndBounds(
                at: date, latitude: latitude, longitude: longitude)
            let phase = SolarCurve.phase(
                elevation: solar.elevation, minElevation: solar.minElevation,
                maxElevation: solar.maxElevation, rising: solar.rising)
            for (anchor, weight) in phase.weights { offer[anchor.rawValue] += duration * weight }
            date = date.addingTimeInterval(duration)
        }
        return offer
    }
}
