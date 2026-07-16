import SwiftUI

/// Pure geometry + interaction rules for `BandSlider`, kept UI-free so the clamp and
/// hit-test invariants are unit-testable.
///
/// One shared value ⇄ pixel mapping (inset by the thumb radius on both ends) is used for
/// the thumb AND the band markers, so a thumb at `lowerBound` lands exactly on the lower
/// bracket instead of drifting past it.
enum BandSliderCore {
    enum Handle { case lower, upper, value }

    /// Fraction of `range` for a value, clamped to [0, 1].
    static func frac(_ v: Double, range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (v - range.lowerBound) / span))
    }

    /// Shared value → x mapping: both thumb and markers ride the same inset track.
    static func position(_ v: Double, width: CGFloat, inset: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        let usable = max(1, width - 2 * inset)
        return CGFloat(frac(v, range: range)) * usable + inset
    }

    /// Shared x → value mapping (inverse of `position`), clamped into `range`.
    static func value(atX x: CGFloat, width: CGFloat, inset: CGFloat, range: ClosedRange<Double>) -> Double {
        let usable = max(1, width - 2 * inset)
        let f = min(1, max(0, Double((x - inset) / usable)))
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    /// Clamp a live value into the band (lo/hi order normalized).
    static func clampToBand(_ v: Double, lower: Double, upper: Double) -> Double {
        let lo = min(lower, upper), hi = max(lower, upper)
        return min(hi, max(lo, v))
    }

    /// Which handle a drag starting at `x` grabs.
    ///
    /// Nearest handle wins, with a deliberate tie-break for the case where clamping has
    /// parked the thumb exactly on a bracket: grabbing at/inside the band prefers the
    /// thumb (so it never becomes ungrabbable), grabbing outside the bracket prefers the
    /// marker (the only handle that can move that way).
    static func hitHandle(
        atX x: CGFloat, width: CGFloat, inset: CGFloat, range: ClosedRange<Double>,
        value v: Double, lower: Double, upper: Double, showBand: Bool,
        markerHitRadius: CGFloat = 12
    ) -> Handle {
        guard showBand else { return .value }
        let visibleValue = clampToBand(v, lower: lower, upper: upper)
        let vX = position(visibleValue, width: width, inset: inset, range: range)
        let loX = position(lower, width: width, inset: inset, range: range)
        let hiX = position(upper, width: width, inset: inset, range: range)
        let dV = abs(vX - x), dLo = abs(loX - x), dHi = abs(hiX - x)
        if dV <= dLo && dV <= dHi {
            // Tied with a coincident marker: outside the bracket means the marker.
            if dV == dLo && x < loX { return .lower }
            if dV == dHi && x > hiX { return .upper }
            return .value
        }
        // Brackets have a finite hit target. A click elsewhere on the track behaves like a
        // normal slider click and moves the value instead of unexpectedly changing a bound.
        let nearestMarker = min(dLo, dHi)
        guard nearestMarker <= markerHitRadius else { return .value }
        return dLo <= dHi ? .lower : .upper
    }
}

/// A value slider with optional adaptive-band bracket markers, over an arbitrary `range`.
///
/// The round thumb sets the live value (a manual nudge while adaptive is on) and is inset
/// by its radius so it never clips at the ends. When `showBand` is true, two draggable
/// bracket markers set the adaptive min/max band; the thumb is hard-clamped into the band,
/// both while dragging and when rendered. Thumb and markers share one value ⇄ pixel
/// mapping, so a thumb at a bound sits exactly on its bracket.
///
/// A single drag gesture routes to whichever handle (lower marker, upper marker, or thumb)
/// is nearest where the drag began; ties on a coincident thumb/marker prefer the thumb
/// inside the band and the marker outside it, so neither can become ungrabbable. While
/// a marker is dragged, `onPreview` fires with its value so the caller can apply it live;
/// `onPreviewEnd` fires on release so the caller can revert to the real value.
struct BandSlider: View {
    @Binding var value: Double          // live value, within `range`
    @Binding var lowerBound: Double     // adaptive min
    @Binding var upperBound: Double     // adaptive max
    var range: ClosedRange<Double> = 0...1
    var showBand: Bool
    var label: String = "Value"
    var minGap: Double = 0.05
    var onPreview: ((Double) -> Void)? = nil
    var onPreviewEnd: (() -> Void)? = nil

    @State private var active: BandSliderCore.Handle?

    private let thumbSize: CGFloat = 18
    private let markerW: CGFloat = 6
    private let markerH: CGFloat = 18
    private let trackHeight: CGFloat = 4
    private var inset: CGFloat { thumbSize / 2 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let midY = geo.size.height / 2
            // Render the thumb clamped into the band even if the model briefly lags a
            // marker drag — it must never draw outside the brackets.
            let renderValue = showBand
                ? BandSliderCore.clampToBand(value, lower: lowerBound, upper: upperBound)
                : value
            let valX = pos(renderValue, w)
            let loX = pos(lowerBound, w)
            let hiX = pos(upperBound, w)
            // The track spans exactly the travel range, so the range ends ARE the track ends:
            // a marker dragged to the floor sits flush on the left cap, not short of it. (The
            // travel range is inset by the thumb radius — that's what keeps the thumb from
            // clipping — so a full-width track could never be reached at either end.)
            let trackLeft = pos(range.lowerBound, w)
            let trackRight = pos(range.upperBound, w)
            // Value fill starts at the left bracket when a band is shown (stays within the
            // band); otherwise it runs to the track's left end like a normal slider.
            let fillLeft: CGFloat = showBand ? loX : trackLeft

            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: max(0, trackRight - trackLeft), height: trackHeight)
                    .position(x: (trackLeft + trackRight) / 2, y: midY)

                if showBand {
                    Capsule()
                        .fill(Color.red.opacity(0.18))
                        .frame(width: max(0, hiX - loX), height: trackHeight)
                        .position(x: (loX + hiX) / 2, y: midY)
                }

                Capsule()
                    .fill(Color.red.opacity(0.55))
                    .frame(width: max(0, valX - fillLeft), height: trackHeight)
                    .position(x: (fillLeft + valX) / 2, y: midY)

                if showBand {
                    marker.position(x: loX, y: midY)
                    marker.position(x: hiX, y: midY)
                }

                thumb.position(x: valX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let handle = active ?? BandSliderCore.hitHandle(
                            atX: g.startLocation.x, width: w, inset: inset, range: range,
                            value: value, lower: lowerBound, upper: upperBound, showBand: showBand
                        )
                        active = handle
                        switch handle {
                        case .lower:
                            let v = min(val(g.location.x, w), upperBound - minGap)
                            lowerBound = max(range.lowerBound, v)
                            onPreview?(lowerBound)
                        case .upper:
                            let v = max(val(g.location.x, w), lowerBound + minGap)
                            upperBound = min(range.upperBound, v)
                            onPreview?(upperBound)
                        case .value:
                            // Hard limit: the thumb can never land outside the band.
                            let v = val(g.location.x, w)
                            value = showBand
                                ? BandSliderCore.clampToBand(v, lower: lowerBound, upper: upperBound)
                                : v
                        }
                    }
                    .onEnded { _ in
                        if active == .lower || active == .upper { onPreviewEnd?() }
                        active = nil
                    }
            )
        }
        .frame(height: markerH + 8)
        .accessibilityRepresentation {
            VStack {
                Slider(value: accessibleValue, in: range) { Text(label) }
                    .accessibilityLabel("\(label) current value")
                    .accessibilityValue(Self.percentLabel(value))
                if showBand {
                    Slider(value: accessibleLowerBound, in: range) {
                        Text("\(label) adaptive minimum")
                    }
                    .accessibilityLabel("\(label) adaptive minimum")
                    .accessibilityValue(Self.percentLabel(lowerBound))
                    Slider(value: accessibleUpperBound, in: range) {
                        Text("\(label) adaptive maximum")
                    }
                    .accessibilityLabel("\(label) adaptive maximum")
                    .accessibilityValue(Self.percentLabel(upperBound))
                }
            }
        }
    }

    // MARK: - Value ⇄ position mapping (shared by thumb and markers)

    private func pos(_ v: Double, _ w: CGFloat) -> CGFloat {
        BandSliderCore.position(v, width: w, inset: inset, range: range)
    }
    private func val(_ px: CGFloat, _ w: CGFloat) -> Double {
        BandSliderCore.value(atX: px, width: w, inset: inset, range: range)
    }

    private static func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) percent"
    }

    private var accessibleValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                let ranged = min(range.upperBound, max(range.lowerBound, newValue))
                value = showBand
                    ? BandSliderCore.clampToBand(
                        ranged, lower: lowerBound, upper: upperBound)
                    : ranged
            }
        )
    }

    private var accessibleLowerBound: Binding<Double> {
        Binding(
            get: { lowerBound },
            set: {
                let ceiling = max(range.lowerBound, upperBound - minGap)
                lowerBound = min(max(range.lowerBound, $0), ceiling)
            }
        )
    }

    private var accessibleUpperBound: Binding<Double> {
        Binding(
            get: { upperBound },
            set: {
                let floor = min(range.upperBound, lowerBound + minGap)
                upperBound = max(min(range.upperBound, $0), floor)
            }
        )
    }

    // MARK: - Pieces

    private var thumb: some View {
        Circle()
            .fill(.white)
            .frame(width: thumbSize, height: thumbSize)
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5))
            .shadow(radius: 1, y: 0.5)
    }

    private var marker: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.red.opacity(0.9))
            .frame(width: markerW, height: markerH)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
    }
}
