import AppKit
import SwiftUI

/// Pure geometry and rules shared by the popover's sliders (`EmberSlider`) and the Settings
/// range control (`EmberRangeSlider`), kept free of views so they are unit-testable.
///
/// Both controls map a value to a point along a track that is inset by `inset` at each end,
/// so a handle at either end of the range still lies wholly on the track.
enum SliderCore {
    /// One end of a range.
    enum Bound: Equatable, Sendable { case lower, upper }

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
    static func value(
        atX x: CGFloat, width: CGFloat, inset: CGFloat, snap: CGFloat = 0, range: ClosedRange<Double>
    ) -> Double {
        let usable = max(1, width - 2 * inset)
        if x <= inset + snap { return range.lowerBound }
        if x >= inset + usable - snap { return range.upperBound }
        let f = min(1, max(0, Double((x - inset) / usable)))
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    /// Clamp a value into a band (lo/hi order normalized).
    static func clampToBand(_ v: Double, lower: Double, upper: Double) -> Double {
        let lo = min(lower, upper), hi = max(lower, upper)
        return min(hi, max(lo, v))
    }

    /// The value a limit takes when it is moved toward `proposed`, keeping at least `minGap`
    /// between the two limits.
    ///
    /// An existing band narrower than `minGap` (set from the CLI, or pinned) can widen, and
    /// a move toward its other limit leaves the limit where it is instead of making it jump
    /// the other way.
    static func editedValue(
        _ proposed: Double, for bound: Bound, range: ClosedRange<Double>,
        lower: Double, upper: Double, minGap: Double
    ) -> Double {
        let v = clampToBand(proposed, lower: range.lowerBound, upper: range.upperBound)
        let gap = max(0, minGap)
        switch bound {
        case .lower:
            let ceiling = max(range.lowerBound, upper - gap)
            if lower > ceiling, v >= lower { return lower }
            return min(v, ceiling)
        case .upper:
            let floor = min(range.upperBound, lower + gap)
            if upper < floor, v <= upper { return upper }
            return max(v, floor)
        }
    }

    /// When both limits sit on one spot, the one that can move in the drag's direction.
    static func resolveStackedMarker(_ bound: Bound, dx: CGFloat, lower: Double, upper: Double) -> Bound {
        guard lower == upper, dx != 0 else { return bound }
        return dx < 0 ? .lower : .upper
    }

    /// Whole percent for VoiceOver: "20 percent".
    static func spokenPercent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) percent"
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
        let shown = value.isFinite ? (value * 100).rounded() : range.lowerBound * 100
        return min(range.upperBound, max(range.lowerBound, (shown + percents) / 100))
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
