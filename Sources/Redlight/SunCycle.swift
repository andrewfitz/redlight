import Foundation

/// A snapshot of the sun's daily cycle at a location: the elevation curve across the local
/// calendar day, where "now" sits on it, and the time to the next twilight transition.
/// Pure — depends only on `SolarCalculator` and an injectable `Calendar`.
struct SunCycle {
    struct Sample {
        let t: Double            // fraction of the local day, 0…1
        let elevation: Double
        let rising: Bool         // before solar noon (morning side of the Adaptive curve)
        let date: Date           // the sample's instant, for the Adaptive bedtime floor
    }
    struct Event { let label: String; let seconds: Double; let elevation: Double }

    let samples: [Sample]
    let nowFraction: Double
    let nowElevation: Double
    let maxElevation: Double
    /// Time to the next elevation marker. The sun-arc graphic never reads this, so the
    /// forward scan only runs on demand.
    var nextEvent: Event? {
        SunCycle.findNextEvent(now: now, latitude: latitude, longitude: longitude)
    }
    private let now: Date
    private let latitude: Double
    private let longitude: Double

    /// The physical elevation markers shown on the sun arc.
    static let thresholds: [Double] = SolarCurve.elevationMarkers.map(\.elevation)
    /// The named horizon and twilight crossings only. The +12° and +6° curve anchors have
    /// no everyday name, so a "next event" shown to the user skips them.
    static let twilightThresholds: [Double] = [
        SolarCurve.sunsetElevation, SolarCurve.civilDuskElevation,
        SolarCurve.nauticalDuskElevation, SolarCurve.nightElevation,
    ]

    init(now: Date, latitude: Double, longitude: Double,
         calendar: Calendar = .current, sampleCount: Int = 73, reusing previous: SunCycle? = nil) {
        let sampleCount = max(2, sampleCount)
        let dayStart = calendar.startOfDay(for: now)
        // Actual local day length — 23/25 h on DST transition days, not a hardcoded 24 h.
        let dayEnd = calendar.dateInterval(of: .day, for: now)?.end
            ?? dayStart.addingTimeInterval(86_400)
        let daySeconds = dayEnd.timeIntervalSince(dayStart)

        if let previous, previous.latitude == latitude, previous.longitude == longitude,
           previous.samples.count == sampleCount, previous.samples.first?.date == dayStart,
           previous.samples.last?.date == dayEnd {
            samples = previous.samples
        } else {
            samples = (0..<sampleCount).map { i in
                let t = Double(i) / Double(sampleCount - 1)
                let date = dayStart.addingTimeInterval(t * daySeconds)
                let position = SolarCalculator.position(at: date, latitude: latitude, longitude: longitude)
                return Sample(t: t, elevation: position.elevation, rising: position.rising, date: date)
            }
        }

        nowFraction = min(1, max(0, now.timeIntervalSince(dayStart) / daySeconds))
        nowElevation = SolarCalculator.elevation(at: now, latitude: latitude, longitude: longitude)
        maxElevation = SolarCalculator.elevationAtSolarNoon(at: now, latitude: latitude, longitude: longitude)
        self.now = now
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Fractions of this local day where the sampled solar arc crosses a real elevation
    /// marker, interpolated between the display samples.
    func crossingFractions(at elevation: Double) -> [Double] {
        guard samples.count > 1 else { return [] }
        let epsilon = 1e-9
        var result: [Double] = []

        func appendUnique(_ t: Double) {
            guard result.last.map({ abs($0 - t) > epsilon }) ?? true else { return }
            result.append(t)
        }

        for i in 0..<(samples.count - 1) {
            let a = samples[i], b = samples[i + 1]
            let da = a.elevation - elevation, db = b.elevation - elevation
            if abs(da) <= epsilon { appendUnique(a.t) }
            if da * db < 0 {
                let f = da / (da - db)
                appendUnique(a.t + (b.t - a.t) * f)
            }
        }
        if let last = samples.last, abs(last.elevation - elevation) <= epsilon {
            appendUnique(last.t)
        }
        return result
    }

    /// The next upward horizon crossing, or nil in polar day or night. It looks 25 hours
    /// ahead: in autumn tomorrow's sunrise is later than today's, so just after sunrise the
    /// next one is more than 24 hours away.
    /// A horizon-only scan would return the sunset first during the day, so it is rising-only.
    static func nextSunrise(after now: Date, latitude: Double, longitude: Double) -> Date? {
        findNextEvent(now: now, latitude: latitude, longitude: longitude,
                      thresholds: [SolarCurve.sunsetElevation], rising: true, horizon: 90_000)
            .map { now.addingTimeInterval($0.seconds) }
    }

    /// Scan forward in two-minute steps, refining local extrema so short excursions near
    /// the polar circles can still supply both crossings. Bisect each crossing to within one second.
    static func findNextEvent(
        now: Date, latitude: Double, longitude: Double, thresholds: [Double] = SunCycle.thresholds,
        rising: Bool? = nil, horizon: Double = 86_400
    ) -> Event? {
        guard horizon.isFinite, horizon > 0, !thresholds.isEmpty else { return nil }
        let step: Double = 120
        typealias Point = (offset: Double, elevation: Double)
        func point(at offset: Double) -> Point {
            (offset, SolarCalculator.elevation(at: now.addingTimeInterval(offset),
                                               latitude: latitude, longitude: longitude))
        }

        func turningPoint(_ a: Point, _ b: Point, _ c: Point) -> Point? {
            let isMaximum = b.elevation >= a.elevation && b.elevation >= c.elevation
            let isMinimum = b.elevation <= a.elevation && b.elevation <= c.elevation
            guard isMaximum != isMinimum else { return nil }
            var lo = a.offset, hi = c.offset
            while hi - lo > 0.02 {
                let third = (hi - lo) / 3
                let left = point(at: lo + third), right = point(at: hi - third)
                if (left.elevation < right.elevation) == isMaximum {
                    lo = left.offset
                } else {
                    hi = right.offset
                }
            }
            return point(at: (lo + hi) / 2)
        }

        func crossing(from a: Point, to b: Point, endsAtTurn: Bool = false) -> Event? {
            let isRising = b.elevation > a.elevation
            guard rising == nil || rising == isRising else { return nil }
            var first: Double?
            for threshold in thresholds {
                // Touching a threshold at a turning point without passing it is no crossing.
                if endsAtTurn && b.elevation == threshold { continue }
                if isRising, a.elevation < threshold, threshold <= b.elevation {
                    first = min(first ?? threshold, threshold)
                } else if !isRising, b.elevation <= threshold, threshold < a.elevation {
                    first = max(first ?? threshold, threshold)
                }
            }
            guard let threshold = first else { return nil }
            let name = label(threshold: threshold, rising: isRising)
            if b.elevation == threshold {
                return Event(label: name, seconds: b.offset, elevation: threshold)
            }
            var lo = a.offset, hi = b.offset
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                let elevation = point(at: mid).elevation
                let crossed = isRising ? elevation >= threshold : elevation <= threshold
                if crossed { hi = mid } else { lo = mid }
            }
            // Scheduling the event at the crossed end prevents a subsequent scan
            // from reporting the same transition again.
            return Event(label: name, seconds: hi, elevation: threshold)
        }

        var last = point(at: 0)
        var a = point(at: -step), b = last, c = point(at: min(step, horizon))
        while true {
            // Look one sample beyond each end to find turns near now and the horizon.
            if let turn = turningPoint(a, b, c), turn.offset > last.offset, turn.offset <= horizon {
                if let event = crossing(from: last, to: turn, endsAtTurn: true) { return event }
                last = turn
            }
            if b.offset > last.offset {
                if let event = crossing(from: last, to: b) { return event }
                last = b
            }
            if b.offset == horizon { return nil }
            a = b
            b = c
            c = point(at: b.offset == horizon ? horizon + step : min(b.offset + step, horizon))
        }
    }

    /// Event names paired with the phase vocabulary shown in the status line
    /// (civil / nautical / astronomical twilight).
    private static func label(threshold thr: Double, rising: Bool) -> String {
        switch (thr, rising) {
        case (0, false):   return "sunset"
        case (-6, false):  return "civil dusk"
        case (-12, false): return "nautical dusk"
        case (-18, false): return "fully dark"
        case (-18, true):  return "first light"
        case (-12, true):  return "nautical dawn"
        case (-6, true):   return "civil dawn"
        case (0, true):    return "sunrise"
        default:           return "transition"
        }
    }
}
