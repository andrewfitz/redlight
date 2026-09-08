import Foundation

/// A snapshot of the sun's daily cycle at a location: the elevation curve across the local
/// calendar day, where "now" sits on it, and the time to the next twilight transition.
/// Pure — depends only on `SolarCalculator` and an injectable `Calendar`.
struct SunCycle {
    struct Sample { let t: Double; let elevation: Double }   // t in [0,1] = fraction of local day
    struct Event { let label: String; let seconds: Double; let elevation: Double }

    let samples: [Sample]
    let nowFraction: Double
    let nowElevation: Double
    let maxElevation: Double
    let nextEvent: Event?

    /// Every physical elevation anchor that can change the Adaptive curve. The next-event
    /// countdown uses this same set.
    static let thresholds: [Double] = SolarCurve.elevationMarkers.map(\.elevation)

    init(now: Date, latitude: Double, longitude: Double,
         calendar: Calendar = .current, sampleCount: Int = 73) {
        let sampleCount = max(2, sampleCount)
        let dayStart = calendar.startOfDay(for: now)
        // Actual local day length — 23/25 h on DST transition days, not a hardcoded 24 h.
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let daySeconds = dayEnd.timeIntervalSince(dayStart)

        var pts: [Sample] = []
        pts.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleCount - 1)
            let date = dayStart.addingTimeInterval(t * daySeconds)
            let e = SolarCalculator.elevation(at: date, latitude: latitude, longitude: longitude)
            pts.append(Sample(t: t, elevation: e))
        }
        samples = pts

        nowFraction = min(1, max(0, now.timeIntervalSince(dayStart) / daySeconds))
        nowElevation = SolarCalculator.elevation(at: now, latitude: latitude, longitude: longitude)
        maxElevation = SolarCalculator.elevationAtSolarNoon(at: now, latitude: latitude, longitude: longitude)
        nextEvent = SunCycle.findNextEvent(now: now, latitude: latitude, longitude: longitude)
    }

    /// Fractions of this local day where the sampled solar arc crosses a real elevation
    /// marker. Linear interpolation between the dense samples is accurate enough for the
    /// next-event math and keeps times tied to the actual day.
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

    /// Forward-scan `[now, now+24h]` in 2-min steps for the next crossing of any threshold,
    /// then bisect to ~2 s. When several thresholds flip within one step, the earliest in
    /// time wins. Direction is read across the step.
    private static func findNextEvent(now: Date, latitude: Double, longitude: Double) -> Event? {
        let step: Double = 120
        let horizon: Double = 86_400
        func elev(_ offset: Double) -> Double {
            SolarCalculator.elevation(at: now.addingTimeInterval(offset),
                                      latitude: latitude, longitude: longitude)
        }
        func crossing(_ thr: Double, _ a: Double, _ b: Double) -> Double {
            var lo = a, hi = b
            var fLo = elev(lo) - thr
            for _ in 0..<6 {
                let mid = (lo + hi) / 2
                let fMid = elev(mid) - thr
                if fLo * fMid <= 0 { hi = mid } else { lo = mid; fLo = fMid }
            }
            return (lo + hi) / 2
        }

        var prevOffset: Double = 0
        var prev = elev(0)
        var offset = step
        while offset <= horizon {
            let cur = elev(offset)
            var best: (thr: Double, at: Double)?
            for thr in thresholds where (prev - thr) * (cur - thr) < 0 {
                let at = crossing(thr, prevOffset, offset)
                if best == nil || at < best!.at { best = (thr, at) }
            }
            if let best {
                return Event(
                    label: label(threshold: best.thr, rising: cur > prev),
                    seconds: best.at,
                    elevation: best.thr)
            }
            prevOffset = offset
            prev = cur
            offset += step
        }
        return nil
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
