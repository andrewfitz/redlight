import Foundation

/// Maps sun elevation to the adaptive filter target, normalized into the user's intensity and
/// white-point bands (Day → max, deepest night → min). Shared by the live filter
/// (`DisplayManager.applyAdaptive`) and the sun-arc graphic, so both stay in sync.
enum AdaptiveMapping {
    /// A banded target, and whether the bedtime floor (not the sun) set either channel.
    struct Target: Equatable {
        var intensity: Double
        var whitepoint: Double
        var bedtime: Bool
    }

    static func banded(
        elevation: Double, minElevation: Double, rising: Bool = false, presets: [Preset],
        intensityMin: Double, intensityMax: Double,
        whitepointMin: Double, whitepointMax: Double,
        bedtime: BedtimeRamp.Weights = .inactive
    ) -> (intensity: Double, whitepoint: Double) {
        let t = target(
            elevation: elevation, minElevation: minElevation, rising: rising, presets: presets,
            intensityMin: intensityMin, intensityMax: intensityMax,
            whitepointMin: whitepointMin, whitepointMax: whitepointMax, bedtime: bedtime)
        return (t.intensity, t.whitepoint)
    }

    /// The sun curve, made redder (never less red) by the bedtime floor: per channel the lower
    /// of the sun's banded value and a floor easing from the band's Day end to its deepest end.
    /// Applied before the manual offset and the band clamp, so those stay exactly as they were.
    static func target(
        elevation: Double, minElevation: Double, rising: Bool = false, presets: [Preset],
        intensityMin: Double, intensityMax: Double,
        whitepointMin: Double, whitepointMax: Double,
        bedtime: BedtimeRamp.Weights = .inactive
    ) -> Target {
        let sun = sunBanded(
            elevation: elevation, minElevation: minElevation, rising: rising, presets: presets,
            intensityMin: intensityMin, intensityMax: intensityMax,
            whitepointMin: whitepointMin, whitepointMax: whitepointMax)
        // Unset or not yet ramping: the sun's own tuple, untouched.
        guard bedtime.progress > 0, presets.count >= 5 else {
            return Target(intensity: sun.intensity, whitepoint: sun.whitepoint, bedtime: false)
        }

        // Where the sun curve itself sits at solar midnight. Nights that dip below the horizon
        // are stretched to Deep Red there, so this is the band minimum and the release below
        // does nothing. Under the midnight sun it is far lighter, and the floor eases to it
        // over the last stretch instead of snapping at solar midnight.
        let midnight = sunBanded(
            elevation: minElevation, minElevation: minElevation, rising: false, presets: presets,
            intensityMin: intensityMin, intensityMax: intensityMax,
            whitepointMin: whitepointMin, whitepointMax: whitepointMax)
        func floor(lo: Double, hi: Double, atMidnight: Double) -> Double {
            // Weighted sums land exactly on the band ends at progress 0 and 1.
            let ramp = hi * (1 - bedtime.progress) + lo * bedtime.progress
            let released = lo * (1 - bedtime.release) + max(lo, atMidnight) * bedtime.release
            return max(ramp, released)
        }
        let iLo = min(intensityMin, intensityMax), iHi = max(intensityMin, intensityMax)
        let wLo = min(whitepointMin, whitepointMax), wHi = max(whitepointMin, whitepointMax)
        let iFloor = floor(lo: iLo, hi: iHi, atMidnight: midnight.intensity)
        let wFloor = floor(lo: wLo, hi: wHi, atMidnight: midnight.whitepoint)
        return Target(
            intensity: min(sun.intensity, iFloor), whitepoint: min(sun.whitepoint, wFloor),
            bedtime: iFloor < sun.intensity || wFloor < sun.whitepoint)
    }

    private static func sunBanded(
        elevation: Double, minElevation: Double, rising: Bool, presets: [Preset],
        intensityMin: Double, intensityMax: Double,
        whitepointMin: Double, whitepointMax: Double
    ) -> (intensity: Double, whitepoint: Double) {
        let t = SolarCurve.target(
            elevation: elevation, minElevation: minElevation, rising: rising, presets: presets)
        guard presets.count >= 5 else { return t }

        let iLo = min(intensityMin, intensityMax), iHi = max(intensityMin, intensityMax)
        let wLo = min(whitepointMin, whitepointMax), wHi = max(whitepointMin, whitepointMax)
        return (remap(t.intensity, day: presets[0].intensity, deep: presets[4].intensity, lo: iLo, hi: iHi),
                remap(t.whitepoint, day: presets[0].whitepoint, deep: presets[4].whitepoint, lo: wLo, hi: wHi))
    }

    /// Normalize a curve value from its Day…Deep Red anchors onto the band. When the user
    /// has saved identical anchors (a flat curve) there is no fraction to take — fall back
    /// to clamping the raw value into the band instead of pinning to either end.
    private static func remap(_ v: Double, day: Double, deep: Double, lo: Double, hi: Double) -> Double {
        guard day != deep else { return min(hi, max(lo, v)) }
        let frac = min(1, max(0, (v - deep) / (day - deep)))
        return lo + (hi - lo) * frac
    }
}

/// "Deepest by" for Adaptive: a local wall-clock time by which the filter reaches the deepest
/// end of its band, whatever the sun is doing. Nil (the default) means off.
struct Bedtime: Equatable, Hashable, Sendable {
    let hour: Int
    let minute: Int

    init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// The persisted form: minutes after local midnight, 0 through 1439.
    init?(minuteOfDay: Int) {
        guard (0..<1440).contains(minuteOfDay) else { return nil }
        self.init(hour: minuteOfDay / 60, minute: minuteOfDay % 60)
    }

    var minuteOfDay: Int { hour * 60 + minute }
    /// Always 24-hour and zero-padded, as the CLI and status report it: "07:05".
    var text: String { String(format: "%02d:%02d", hour, minute) }

    static let invalidMessage = "Bedtime must be a 24-hour time from 00:00 to 23:59, such as 22:30."

    /// Strict 24-hour "H:MM" or "HH:MM". Signs, seconds and am/pm are rejected.
    static func parse(_ text: String) throws -> Bedtime {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        func digits(_ part: Substring, count: ClosedRange<Int>) -> Int? {
            guard count.contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard parts.count == 2, let hour = digits(parts[0], count: 1...2),
              let minute = digits(parts[1], count: 2...2),
              let bedtime = Bedtime(hour: hour, minute: minute) else {
            throw CommandError.invalidInput(invalidMessage)
        }
        return bedtime
    }
}

/// When the bedtime floor applies. The ramp runs over the two hours of elapsed time before
/// the bedtime, then holds until solar midnight. Only the evening side counts: from solar
/// midnight the sun is rising and the morning is the sun curve alone.
enum BedtimeRamp {
    static let rampLength: TimeInterval = 2 * 3_600
    /// The last stretch before solar midnight, over which the floor eases back to the sun's
    /// own value there. That only matters under the midnight sun; see `AdaptiveMapping.target`.
    static let releaseLength: TimeInterval = 3_600

    struct Weights: Equatable, Sendable {
        /// 0 until the ramp starts, smoothstep to 1 at bedtime, 1 until solar midnight.
        var progress: Double
        /// 0, then smoothstep to 1 across the last `releaseLength` before solar midnight.
        var release: Double

        static let inactive = Weights(progress: 0, release: 0)
    }

    static func weights(at date: Date, bedtime: Bedtime?, longitude: Double, calendar: Calendar) -> Weights {
        guard let bedtime else { return .inactive }
        return weights(at: date, bedtime: bedtime,
                       solarMidnight: SolarCalculator.nextSolarMidnight(after: date, longitude: longitude),
                       calendar: calendar)
    }

    /// `solarMidnight` ends the evening that `date` belongs to; the evening began at solar
    /// noon, twelve hours earlier. Tonight's bedtime is its first occurrence at least one ramp
    /// after solar noon, so a ramp never starts on the morning side and noon stays continuous.
    /// A bedtime that falls after solar midnight has no effect that night.
    static func weights(at date: Date, bedtime: Bedtime, solarMidnight: Date, calendar: Calendar) -> Weights {
        let eveningStart = solarMidnight.addingTimeInterval(-12 * 3_600)
        guard date >= eveningStart, date < solarMidnight else { return .inactive }
        // `.nextTime` moves a time skipped by a DST change to the first real time after it;
        // a repeated time takes its first occurrence.
        let earliest = eveningStart.addingTimeInterval(rampLength)
        guard let at = calendar.nextDate(
                after: earliest.addingTimeInterval(-1),
                matching: DateComponents(hour: bedtime.hour, minute: bedtime.minute, second: 0),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
              at <= solarMidnight else { return .inactive }
        let progress = smoothstep(date.timeIntervalSince(at.addingTimeInterval(-rampLength)) / rampLength)
        guard progress > 0 else { return .inactive }
        let release = smoothstep(
            date.timeIntervalSince(solarMidnight.addingTimeInterval(-releaseLength)) / releaseLength)
        return Weights(progress: progress, release: release)
    }

    private static func smoothstep(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return c * c * (3 - 2 * c)
    }
}
