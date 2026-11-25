import Foundation

/// Maps sun elevation to the adaptive filter target, normalized into the user's intensity and
/// white-point bands (Day → max, deepest night → min). Shared by the live filter
/// (`DisplayManager.applyAdaptive`) and the sun-arc graphic, so both stay in sync.
enum AdaptiveMapping {
    /// A banded target, and whether the bedtime floor or the wake-time lift (not the sun)
    /// set either channel. While the lift is in charge it is the one reported.
    struct Target: Equatable {
        var intensity: Double
        var whitepoint: Double
        var bedtime: Bool
        var wake = false
    }

    static func banded(
        elevation: Double, minElevation: Double, maxElevation: Double = SolarCurve.highNoon,
        rising: Bool = false, presets: [Preset],
        intensityMin: Double, intensityMax: Double,
        whitepointMin: Double, whitepointMax: Double,
        bedtime: BedtimeRamp.Weights = .inactive
    ) -> (intensity: Double, whitepoint: Double) {
        let t = target(
            elevation: elevation, minElevation: minElevation, maxElevation: maxElevation,
            rising: rising, presets: presets,
            intensityMin: intensityMin, intensityMax: intensityMax,
            whitepointMin: whitepointMin, whitepointMax: whitepointMax, bedtime: bedtime)
        return (t.intensity, t.whitepoint)
    }

    /// The sun curve, made redder (never less red) by the bedtime floor: per channel the lower
    /// of the sun's banded value and a floor easing from the band's Day end to its deepest end.
    /// The wake-time lift then makes it clearer (never redder): the higher of that and a lift
    /// easing from the deepest end back to the Day end.
    /// Applied before the manual offset and the band clamp, so those stay exactly as they were.
    static func target(
        elevation: Double, minElevation: Double, maxElevation: Double = SolarCurve.highNoon,
        rising: Bool = false, presets: [Preset],
        intensityMin: Double, intensityMax: Double,
        whitepointMin: Double, whitepointMax: Double,
        bedtime: BedtimeRamp.Weights = .inactive
    ) -> Target {
        let sun = sunBanded(
            elevation: elevation, minElevation: minElevation, maxElevation: maxElevation,
            rising: rising, presets: presets,
            intensityMin: intensityMin, intensityMax: intensityMax,
            whitepointMin: whitepointMin, whitepointMax: whitepointMax)
        // Unset or not yet ramping: the sun's own tuple, untouched.
        guard bedtime.progress > 0 || bedtime.lift > 0, presets.count >= 5 else {
            return Target(intensity: sun.intensity, whitepoint: sun.whitepoint, bedtime: false)
        }
        let iLo = min(intensityMin, intensityMax), iHi = max(intensityMin, intensityMax)
        let wLo = min(whitepointMin, whitepointMax), wHi = max(whitepointMin, whitepointMax)
        var intensity = sun.intensity, whitepoint = sun.whitepoint

        if bedtime.progress > 0 {
            // Where the sun curve itself sits at solar midnight. The curve reaches Late there
            // on every night, so this is the band minimum and the release below does nothing.
            // Only within a few degrees of the poles is it lighter, and there the floor
            // eases to it over the last stretch instead of snapping at solar midnight.
            let midnight = sunBanded(
                elevation: minElevation, minElevation: minElevation, maxElevation: maxElevation,
                rising: false, presets: presets,
                intensityMin: intensityMin, intensityMax: intensityMax,
                whitepointMin: whitepointMin, whitepointMax: whitepointMax)
            func floor(lo: Double, hi: Double, atMidnight: Double) -> Double {
                if lo == hi { return lo }
                // Weighted sums land exactly on the band ends at progress 0 and 1.
                let ramp = hi * (1 - bedtime.progress) + lo * bedtime.progress
                let released = lo * (1 - bedtime.release) + max(lo, atMidnight) * bedtime.release
                return max(ramp, released)
            }
            intensity = min(intensity, floor(lo: iLo, hi: iHi, atMidnight: midnight.intensity))
            whitepoint = min(whitepoint, floor(lo: wLo, hi: wHi, atMidnight: midnight.whitepoint))
        }
        let floored = (intensity: intensity, whitepoint: whitepoint)

        if bedtime.lift > 0 {
            // It holds the Day end until solar noon, where the sun curve is at Day too.
            intensity = max(intensity, iLo * (1 - bedtime.lift) + iHi * bedtime.lift)
            whitepoint = max(whitepoint, wLo * (1 - bedtime.lift) + wHi * bedtime.lift)
        }
        let lifted = intensity > floored.intensity || whitepoint > floored.whitepoint
        return Target(
            intensity: intensity, whitepoint: whitepoint,
            bedtime: !lifted && (intensity < sun.intensity || whitepoint < sun.whitepoint),
            wake: lifted)
    }

    private static func sunBanded(
        elevation: Double, minElevation: Double, maxElevation: Double, rising: Bool, presets: [Preset],
        intensityMin: Double, intensityMax: Double,
        whitepointMin: Double, whitepointMax: Double
    ) -> (intensity: Double, whitepoint: Double) {
        let t = SolarCurve.target(
            elevation: elevation, minElevation: minElevation, maxElevation: maxElevation,
            rising: rising, presets: presets)
        guard presets.count >= 5 else { return t }

        let iLo = min(intensityMin, intensityMax), iHi = max(intensityMin, intensityMax)
        let wLo = min(whitepointMin, whitepointMax), wHi = max(whitepointMin, whitepointMax)
        return (remap(t.intensity, day: presets[0].intensity, deep: presets[4].intensity, lo: iLo, hi: iHi),
                remap(t.whitepoint, day: presets[0].whitepoint, deep: presets[4].whitepoint, lo: wLo, hi: wHi))
    }

    /// Normalize a curve value from its Day…Late anchors onto the band. When the user
    /// has saved identical anchors (a flat curve) there is no fraction to take — fall back
    /// to clamping the raw value into the band instead of pinning to either end.
    private static func remap(_ v: Double, day: Double, deep: Double, lo: Double, hi: Double) -> Double {
        guard day != deep else { return min(hi, max(lo, v)) }
        let frac = min(1, max(0, (v - deep) / (day - deep)))
        if frac == 1 { return hi }
        return min(hi, lo + (hi - lo) * frac)
    }
}

/// "Deepest by" for Adaptive: a local wall-clock time by which the filter reaches the deepest
/// end of its band, whatever the sun is doing. Nil (the default) means off.
/// "Clear by", the wake time, is the same kind of value for the Day end of the band.
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
    /// The same message for the wake time, which is the same kind of value.
    static let invalidWakeMessage = "Wake time must be a 24-hour time from 00:00 to 23:59, such as 07:00."

    /// Strict 24-hour "H:MM" or "HH:MM". Signs, seconds and am/pm are rejected.
    static func parse(_ text: String, invalidMessage: String = Bedtime.invalidMessage) throws -> Bedtime {
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

/// When the bedtime floor and the wake-time lift apply.
///
/// A night runs from one solar noon to the next, with solar midnight in the middle. The
/// bedtime ramp runs over the two hours of elapsed time before the bedtime, then holds.
/// With no wake time it holds until solar midnight: from there the sun is rising and the
/// morning is the sun curve alone. With a wake time it holds through the night instead, the
/// lift eases the tint off over the hour before the wake time, and the Day end is held until
/// solar noon, where the sun curve is at Day too.
enum BedtimeRamp {
    static let rampLength: TimeInterval = 2 * 3_600
    /// The maximum time allowed for the floor to ease back to the sun's midnight value.
    /// The release starts after bedtime and only matters when the sun's value is above the floor.
    static let releaseLength: TimeInterval = 3_600
    /// How long before the wake time the tint starts to lift.
    static let wakeRampLength: TimeInterval = 3_600

    struct Weights: Equatable, Sendable {
        /// 0 until the ramp starts, smoothstep to 1 at bedtime, then 1 until solar midnight,
        /// or until the wake time when there is one.
        var progress: Double
        /// 0 until bedtime or the last `releaseLength` before solar midnight, whichever is
        /// later. Always 0 with a wake time: the lift ends that night, not the release.
        var release: Double
        /// 0 until the lift starts, smoothstep to 1 at the wake time, 1 until solar noon.
        var lift = 0.0

        static let inactive = Weights(progress: 0, release: 0)
    }

    /// The instants a night's bedtime and wake time fall at, for those that apply to it.
    struct Schedule: Equatable, Sendable {
        var bedtime: Date?
        var wake: Date?
    }

    static func weights(
        at date: Date, bedtime: Bedtime?, wake: Bedtime? = nil, longitude: Double, calendar: Calendar
    ) -> Weights {
        guard bedtime != nil || wake != nil else { return .inactive }
        let next = SolarCalculator.nextSolarMidnight(after: date, longitude: longitude)
        if date >= next.addingTimeInterval(-12 * 3_600) {
            return weights(at: date, bedtime: bedtime, wake: wake, solarMidnight: next, calendar: calendar)
        }
        // The morning side belongs to the night that began it. Without a wake time that
        // is the sun curve alone.
        guard wake != nil else { return .inactive }
        let previous = SolarCalculator.nextSolarMidnight(
            after: date.addingTimeInterval(-86_400), longitude: longitude)
        return weights(at: date, bedtime: bedtime, wake: wake, solarMidnight: previous, calendar: calendar)
    }

    /// `solarMidnight` is the middle of the night `date` belongs to: it ends the evening that
    /// began at solar noon, twelve hours earlier, and begins the morning that ends at the next.
    ///
    /// - The wake time is its first occurrence at least one wake ramp after solar midnight,
    ///   so a lift never starts on the evening side. One after solar noon does not apply.
    /// - The bedtime is its first occurrence at least one ramp after solar noon, so a ramp
    ///   never starts on the morning side and noon stays continuous. It must fall by solar
    ///   midnight, or, with a wake time, by the start of the lift.
    static func schedule(
        bedtime: Bedtime?, wake: Bedtime?, solarMidnight: Date, calendar: Calendar
    ) -> Schedule {
        // `.nextTime` moves a time skipped by a DST change to the first real time after it;
        // a repeated time takes its first occurrence.
        func first(_ time: Bedtime, from earliest: Date) -> Date? {
            calendar.nextDate(
                after: earliest.addingTimeInterval(-1),
                matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        }
        let noonBefore = solarMidnight.addingTimeInterval(-12 * 3_600)
        let noonAfter = solarMidnight.addingTimeInterval(12 * 3_600)
        let wakeAt = wake.flatMap { first($0, from: solarMidnight.addingTimeInterval(wakeRampLength)) }
            .flatMap { $0 <= noonAfter ? $0 : nil }
        let latestBedtime = wakeAt?.addingTimeInterval(-wakeRampLength) ?? solarMidnight
        let bedtimeAt = bedtime.flatMap { first($0, from: noonBefore.addingTimeInterval(rampLength)) }
            .flatMap { $0 <= latestBedtime ? $0 : nil }
        return Schedule(bedtime: bedtimeAt, wake: wakeAt)
    }

    static func weights(
        at date: Date, bedtime: Bedtime?, wake: Bedtime? = nil, solarMidnight: Date, calendar: Calendar
    ) -> Weights {
        guard date >= solarMidnight.addingTimeInterval(-12 * 3_600),
              date < solarMidnight.addingTimeInterval(12 * 3_600) else { return .inactive }
        let schedule = schedule(bedtime: bedtime, wake: wake, solarMidnight: solarMidnight, calendar: calendar)
        var weights = Weights.inactive
        if let at = schedule.bedtime, date < schedule.wake ?? solarMidnight {
            weights.progress = smoothstep(date.timeIntervalSince(at.addingTimeInterval(-rampLength)) / rampLength)
            if weights.progress > 0, schedule.wake == nil {
                let releaseStart = max(at, solarMidnight.addingTimeInterval(-releaseLength))
                if date > releaseStart {
                    weights.release = smoothstep(
                        date.timeIntervalSince(releaseStart) / solarMidnight.timeIntervalSince(releaseStart))
                }
            }
        }
        if let at = schedule.wake {
            weights.lift = smoothstep(
                date.timeIntervalSince(at.addingTimeInterval(-wakeRampLength)) / wakeRampLength)
        }
        return weights
    }

    private static func smoothstep(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return c * c * (3 - 2 * c)
    }
}
