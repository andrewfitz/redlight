import AppKit
import SwiftUI

/// Slider settings use integer percentages. Only geometry, Auto and display output use fractions.
enum SliderPercent {
    static func whole(_ percent: Double) -> Int {
        guard percent.isFinite else { return 100 }
        // Ignore round-off from converting a display value back to slider units.
        let bounded = min(100, max(0, percent))
        return Int(((bounded * 1e10).rounded() / 1e10).rounded())
    }

    static func unit(_ percent: Int) -> Double { Double(percent) / 100 }
}

/// The white point as people are shown it and as they set it: 0 to 100 %.
///
/// What the displays take runs from 0.25 to 1, and that is what is handed
/// to the gamma tables. Below a quarter the screen is too dark to find the way back, so the
/// output stops there; a scale that began at 25 % only made people ask why. So the popover,
/// the command line and Shortcuts all show the output's place in its own range: 0.25 reads
/// 0 % and 1 reads 100 %. This is the one place that knows both.
enum WhitepointScale {
    /// What the displays take.
    static let output: ClosedRange<Double> = 0.25...1

    /// An output value as a fraction of the scale, 0…1. A value that is not a number is
    /// the top: no reduction.
    static func shown(_ output: Double) -> Double {
        guard output.isFinite else { return 1 }
        let span = Self.output.upperBound - Self.output.lowerBound
        return min(1, max(0, (output - Self.output.lowerBound) / span))
    }

    /// The output value for a fraction of the scale.
    static func output(_ shown: Double) -> Double {
        guard shown.isFinite else { return output.upperBound }
        let span = output.upperBound - output.lowerBound
        return min(output.upperBound, max(output.lowerBound, output.lowerBound + min(1, max(0, shown)) * span))
    }

    /// An output value in percent of the scale, as a status reports it. Rounded far below
    /// anything shown, so that a whole percent that was set reads back as itself and not as
    /// 79.99999999999999.
    static func percent(_ output: Double) -> Double {
        (shown(output) * 100 * 1e9).rounded() / 1e9
    }

    /// The output value for a percent of the scale.
    static func output(percent: Double) -> Double { output(percent / 100) }
}

/// Pure geometry and rules shared by the popover's sliders (`EmberSlider`) and the Auto
/// limit flags under them (`EmberSliderFlags`), kept free of views so they are unit-testable.
///
/// Both controls map a value to a point along a track that is inset by `inset` at each end,
/// so a handle at either end of the range still lies wholly on the track.
enum SliderCore {
    /// One end of a range.
    enum Bound: Hashable, Sendable { case lower, upper }

    /// Least distance Auto's two limits are set apart, by flag or by key, as a fraction of
    /// the slider's range: 5 % as the slider counts it.
    static let limitGap = 0.05

    /// That distance in a slider's own values.
    static func limitGap(in range: ClosedRange<Double>) -> Double {
        limitGap * (range.upperBound - range.lowerBound)
    }
    /// How far the pointer travels before a handle that was pressed where it stood starts to
    /// move. A click is rarely perfectly still, and it should change nothing.
    static let liveTravel: CGFloat = 2

    /// Fraction of `range` for a value, clamped to [0, 1].
    static func frac(_ v: Double, range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (v - range.lowerBound) / span))
    }

    /// Value → x on a track inset by `inset` at both ends.
    static func position(_ v: Double, width: CGFloat, inset: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        let usable = max(1, width - 2 * inset)
        return CGFloat(frac(v, range: range)) * usable + inset
    }

    /// x → value, the inverse of `position`, clamped into `range`. Within `snap` of the
    /// position of either end of the range (and anywhere past it) the value is exactly that
    /// end, so 0 % and 100 % are reached with a flick and never land on 99.6 %.
    ///
    /// `snapsLower` and `snapsUpper` switch the snap off at one end, for a handle that is
    /// being moved away from it: a handle at 99 % taken one point left would otherwise jump
    /// to 100 %.
    static func value(
        atX x: CGFloat, width: CGFloat, inset: CGFloat, snap: CGFloat = 0,
        snapsLower: Bool = true, snapsUpper: Bool = true, range: ClosedRange<Double>
    ) -> Double {
        let usable = max(1, width - 2 * inset)
        if x <= inset + (snapsLower ? snap : 0) { return range.lowerBound }
        if x >= inset + usable - (snapsUpper ? snap : 0) { return range.upperBound }
        let f = min(1, max(0, Double((x - inset) / usable)))
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    /// Clamp a value into a band (lo/hi order normalized).
    static func clampToBand(_ v: Double, lower: Double, upper: Double) -> Double {
        let lo = min(lower, upper), hi = max(lower, upper)
        return min(hi, max(lo, v))
    }

    /// The value a limit takes when it is moved toward `proposed`.
    ///
    /// The two limits are either at least `minGap` apart or on one value (a pinned band).
    /// Short of the other limit by the gap is the nearest a limit can stand apart from it.
    /// Taken closer, it holds there until it is more than halfway across the gap, and then it
    /// is on the other limit: the band is pinned. Taken back past halfway it stands apart
    /// again. So a flag dragged onto the other merges with it, and a merged flag dragged
    /// away opens the band by the gap. A limit never passes the other, and never moves it.
    ///
    /// Where the other limit is nearer an end of the range than the gap, there is no room on
    /// that side to stand apart, and a limit merged with it stays merged: a band pinned at
    /// 98 % opens downward only.
    ///
    /// A band already narrower than the gap without being pinned (set from the CLI) has its
    /// limit where no drag would put it. It is left there until it is taken past one of the
    /// same two thresholds: toward the other limit, halfway to it, where it merges; away,
    /// the halfway point of the gap, where it stands the gap apart (or as far as the range
    /// goes). Past that point the ordinary rule gives the same answer, so nothing flickers.
    static func editedValue(
        _ proposed: Double, for bound: Bound, range: ClosedRange<Double>,
        lower: Double, upper: Double, minGap: Double
    ) -> Double {
        let v = clampToBand(proposed, lower: range.lowerBound, upper: range.upperBound)
        let gap = max(0, minGap)
        switch bound {
        case .lower:
            let hasRoom = upper - gap >= range.lowerBound - roomTolerance
            let apart = max(range.lowerBound, upper - gap)
            if hasRoom, v <= apart { return v }
            if lower > apart || !hasRoom, lower < upper {
                if v < lower { return v < (apart + upper) / 2 ? apart : lower }
                return v >= (lower + upper) / 2 ? upper : lower
            }
            guard hasRoom else { return upper }
            return v >= (apart + upper) / 2 ? upper : apart
        case .upper:
            let hasRoom = lower + gap <= range.upperBound + roomTolerance
            let apart = min(range.upperBound, lower + gap)
            if hasRoom, v >= apart { return v }
            if upper < apart || !hasRoom, upper > lower {
                if v > upper { return v > (apart + lower) / 2 ? apart : upper }
                return v <= (lower + upper) / 2 ? lower : upper
            }
            guard hasRoom else { return lower }
            return v <= (apart + lower) / 2 ? lower : apart
        }
    }

    /// Slack for "the gap fits before the end of the range": 30 % less 5 % is not exactly 25 %.
    private static let roomTolerance = 1e-9

    /// True where a limit merged with the other at `pin` can leave it on this side: the gap
    /// fits between the pin and that end of the range.
    static func canOpen(_ bound: Bound, from pin: Double, range: ClosedRange<Double>, minGap: Double) -> Bool {
        let gap = max(0, minGap)
        return bound == .lower ? pin - gap >= range.lowerBound - roomTolerance
            : pin + gap <= range.upperBound + roomTolerance
    }

    /// The value a limit takes for one step of a key or an assistive app toward `proposed`.
    ///
    /// A step is too short to cross the gap as a drag does, so where `editedValue` would
    /// hold the limit it goes on to the next place it can stand: a step toward the other
    /// limit from the gap's edge merges with it, and a step away from a merged limit opens
    /// the band by the gap. No key is ever dead while there is somewhere to go.
    static func steppedValue(
        _ proposed: Double, for bound: Bound, range: ClosedRange<Double>,
        lower: Double, upper: Double, minGap: Double
    ) -> Double {
        let current = bound == .lower ? lower : upper
        let other = bound == .lower ? upper : lower
        let edited = editedValue(proposed, for: bound, range: range, lower: lower, upper: upper, minGap: minGap)
        let v = clampToBand(proposed, lower: range.lowerBound, upper: range.upperBound)
        // Held where it is, give or take the rounding of the gap's own arithmetic.
        guard abs(edited - current) < 1e-9, abs(v - current) > 1e-9 else { return edited }
        let towardOther = bound == .lower ? v > current : v < current
        if lower == upper {
            // Pinned. Toward the other limit is past it, and a side with no room for the gap
            // is closed: nowhere to go.
            guard !towardOther, canOpen(bound, from: current, range: range, minGap: minGap) else { return current }
            let gap = max(0, minGap)
            return bound == .lower ? max(range.lowerBound, upper - gap) : min(range.upperBound, lower + gap)
        }
        if towardOther { return other }
        // Held against a step away: only a band narrower than the gap does that. The step
        // takes the limit out to the gap, or as far as the range goes.
        let gap = max(0, minGap)
        return bound == .lower ? max(range.lowerBound, upper - gap) : min(range.upperBound, lower + gap)
    }

    /// When both limits sit on one spot, the one that can leave it in the drag's direction:
    /// `dx` is how far the flag's handle is from that spot, negative to the left. Where only
    /// one of them has room to leave (the spot is on an end of the range, or nearer it than
    /// the gap), it is that one whichever way the drag goes: taken the other way, the press
    /// could do nothing until released.
    static func resolveStackedMarker(
        _ bound: Bound, dx: CGFloat, lower: Double, upper: Double, range: ClosedRange<Double>,
        minGap: Double = SliderCore.limitGap
    ) -> Bound {
        guard lower == upper, dx != 0 else { return bound }
        let below = canOpen(.lower, from: lower, range: range, minGap: minGap)
        let above = canOpen(.upper, from: upper, range: range, minGap: minGap)
        if below != above { return below ? .lower : .upper }
        return dx < 0 ? .lower : .upper
    }

    /// The limit a key moves from the stop of `focused`. Both stops of a pinned band sit on
    /// one value, and each limit can only leave it one way, so there the key's direction
    /// chooses: up moves the maximum, down the minimum.
    static func keyBound(_ focused: Bound, proposed: Double, lower: Double, upper: Double) -> Bound {
        guard lower == upper else { return focused }
        if proposed > upper { return .upper }
        if proposed < lower { return .lower }
        return focused
    }

    /// The whole percent a slider shows for a value: its place in the slider's range, so
    /// the bottom of any slider is 0 and the top 100.
    static func percent(_ value: Double, in range: ClosedRange<Double> = 0...1) -> Int {
        SliderPercent.whole(frac(value, range: range) * 100)
    }

    /// Whole percent as the popover writes it: "20%".
    static func percentText(_ value: Double, in range: ClosedRange<Double> = 0...1) -> String {
        "\(percent(value, in: range))%"
    }

    /// Whole percent for VoiceOver: "20 percent".
    static func spokenPercent(_ value: Double, in range: ClosedRange<Double> = 0...1) -> String {
        "\(percent(value, in: range)) percent"
    }
}

/// What a key does to a focused slider handle.
///
/// Left and Down take 1 % off, Right and Up add 1 %, with Shift 10 %; Page Down and Page Up
/// are 10 % too. Home and End (fn-Left and fn-Right) go to the ends of the range. A step
/// lands on a whole percent, counted from the percent the slider shows, so the steps read
/// 46, 47, 48 and the ends are always reached exactly.
enum SliderKeyStep: Equatable, Sendable {
    case decrement, increment, toMinimum, toMaximum, pageDown, pageUp

    /// The keys a slider handle listens to.
    static let keys: Set<KeyEquivalent> = [
        .leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end, .pageUp, .pageDown,
    ]

    init?(_ key: KeyEquivalent) {
        switch key {
        case .leftArrow, .downArrow: self = .decrement
        case .rightArrow, .upArrow: self = .increment
        case .home: self = .toMinimum
        case .end: self = .toMaximum
        case .pageDown: self = .pageDown
        case .pageUp: self = .pageUp
        default: return nil
        }
    }

    func value(from value: Double, in range: ClosedRange<Double>, large: Bool = false) -> Double {
        let percents: Double
        switch self {
        case .toMinimum: return range.lowerBound
        case .toMaximum: return range.upperBound
        case .decrement: percents = large ? -10 : -1
        case .increment: percents = large ? 10 : 1
        case .pageDown: percents = -10
        case .pageUp: percents = 10
        }
        // In the percent the slider shows: its place in the range, not the value itself.
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return range.lowerBound }
        let shown = value.isFinite ? ((value - range.lowerBound) / span * 100).rounded() : 0
        let next = min(100, max(0, shown + percents))
        // The ends exactly, whatever the arithmetic in between leaves.
        if next <= 0 { return range.lowerBound }
        if next >= 100 { return range.upperBound }
        return range.lowerBound + span * next / 100
    }
}

/// Focus is drawn on a slider only when it arrived by keyboard: neither a click that
/// focuses a handle nor the popover handing a handle its first focus leaves it looking
/// focused. A key press on a focused handle shows it from then on.
enum SliderFocus {
    static func drawsFocus(handleIsFocused: Bool, isDragging: Bool, event: NSEvent.EventType?) -> Bool {
        handleIsFocused && !isDragging && event == .keyDown
    }
}

/// The actual gesture uses this gate before every write, preview, and release callback.
/// Cancellation sticks until the view creates a new gate for a fresh gesture, even if
/// a subsequent view update supplies a different current-token callback.
struct SliderInteractionGate {
    private(set) var isInterrupted = false

    mutating func permitsMutation(token: UInt64?, isCurrent: ((UInt64) -> Bool)?) -> Bool {
        if let token, isCurrent?(token) == false { isInterrupted = true }
        return !isInterrupted
    }

    mutating func endPreviewIfCurrent(
        token: UInt64?, isCurrent: ((UInt64) -> Bool)?,
        isPreviewing: Bool, onPreviewEnd: (() -> Void)?
    ) {
        guard isPreviewing, permitsMutation(token: token, isCurrent: isCurrent) else { return }
        onPreviewEnd?()
    }
}
