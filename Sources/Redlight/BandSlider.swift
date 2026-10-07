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

    /// Which handle a drag starting at (`x`, `dy` from the track's centerline) grabs.
    ///
    /// Markers are taller than the thumb, so their ends show as tabs above and below it.
    /// A press in that tab zone, on a tab, always grabs the marker, so a limit stays
    /// reachable even when the thumb sits right on it.
    ///
    /// Otherwise the nearest handle wins, with a deliberate tie-break for the case where
    /// clamping has parked the thumb exactly on a bracket: grabbing at/inside the band
    /// prefers the thumb (so it never becomes ungrabbable), grabbing outside the bracket
    /// prefers the marker (the only handle that can move that way).
    static func hitHandle(
        atX x: CGFloat, dy: CGFloat = 0, width: CGFloat, inset: CGFloat,
        range: ClosedRange<Double>,
        value v: Double, lower: Double, upper: Double, showBand: Bool,
        markerHitRadius: CGFloat = 12, tabZone: CGFloat = 6, tabHitRadius: CGFloat = 6
    ) -> Handle {
        guard showBand else { return .value }
        let visibleValue = clampToBand(v, lower: lower, upper: upper)
        let vX = position(visibleValue, width: width, inset: inset, range: range)
        let loX = position(lower, width: width, inset: inset, range: range)
        let hiX = position(upper, width: width, inset: inset, range: range)
        let dV = abs(vX - x), dLo = abs(loX - x), dHi = abs(hiX - x)
        if abs(dy) >= tabZone, min(dLo, dHi) <= tabHitRadius {
            return dLo <= dHi ? .lower : .upper
        }
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
    /// Called when a drag starts; returns a token for that drag.
    var onInteractionBegin: (() -> UInt64)? = nil
    /// False once the drag's token is stale (another change took over); the rest of that
    /// drag is ignored.
    var isInteractionCurrent: ((UInt64) -> Bool)? = nil

    @State private var active: BandSliderCore.Handle?
    @State private var interactionToken: UInt64?
    @State private var interactionGate = SliderInteractionGate()
    /// Handle position minus press position, so a grabbed handle doesn't jump to the pointer.
    @State private var grabOffset: CGFloat = 0

    private let thumbSize: CGFloat = 18
    private let markerW: CGFloat = 6
    // Taller than the thumb: the ends stay visible as tabs above and below it, which is
    // where a limit is grabbed when the thumb sits on it.
    private let markerH: CGFloat = 28
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
                        if active == nil {
                            let handle = BandSliderCore.hitHandle(
                                atX: g.startLocation.x, dy: g.startLocation.y - midY,
                                width: w, inset: inset, range: range,
                                value: value, lower: lowerBound, upper: upperBound,
                                showBand: showBand
                            )
                            active = handle
                            interactionToken = onInteractionBegin?()
                            interactionGate = SliderInteractionGate()
                            let start = g.startLocation.x
                            switch handle {
                            case .lower: grabOffset = loX - start
                            case .upper: grabOffset = hiX - start
                            // On the thumb: keep the grab point. On the bare track: jump there.
                            case .value: grabOffset = abs(valX - start) <= inset ? valX - start : 0
                            }
                        }
                        // Preserve the original token until release, including across
                        // redraws from the command that interrupted this gesture.
                        guard acceptsInteractionMutation() else { return }
                        let x = g.location.x + grabOffset
                        switch active ?? .value {
                        case .lower:
                            let v = min(val(x, w), upperBound - minGap)
                            lowerBound = max(range.lowerBound, v)
                            onPreview?(lowerBound)
                        case .upper:
                            let v = max(val(x, w), lowerBound + minGap)
                            upperBound = min(range.upperBound, v)
                            onPreview?(upperBound)
                        case .value:
                            // Hard limit: the thumb can never land outside the band.
                            let v = val(x, w)
                            value = showBand
                                ? BandSliderCore.clampToBand(v, lower: lowerBound, upper: upperBound)
                                : v
                        }
                    }
                    .onEnded { _ in finishInteraction() }
            )
        }
        .frame(height: markerH + 2)
        // DragGesture has no cancel callback. If the popover closes mid-drag, onEnded never
        // runs and the next drag anywhere would route to the stale handle.
        .onDisappear { finishInteraction() }
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

    /// Controls can disappear while the parent remains visible (for example, About).
    /// End this gesture's preview, but never clear a newer interaction's preview.
    private func finishInteraction() {
        interactionGate.endPreviewIfCurrent(
            token: interactionToken, isCurrent: isInteractionCurrent,
            isPreviewing: active == .lower || active == .upper, onPreviewEnd: onPreviewEnd
        )
        active = nil
        interactionToken = nil
        interactionGate = SliderInteractionGate()
    }

    private func acceptsInteractionMutation() -> Bool {
        interactionGate.permitsMutation(token: interactionToken, isCurrent: isInteractionCurrent)
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

    /// Accessibility adjustments are individual edits, so they acquire a fresh token and
    /// immediately finish. They can supersede a mouse gesture without inheriting its token.
    private func performAccessibilityEdit(_ edit: () -> Void) {
        let token = onInteractionBegin?()
        if let token, isInteractionCurrent?(token) == false { return }
        edit()
        if let token, isInteractionCurrent?(token) == false { return }
        onPreviewEnd?()
    }

    private var accessibleValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                performAccessibilityEdit {
                    let ranged = min(range.upperBound, max(range.lowerBound, newValue))
                    value = showBand
                        ? BandSliderCore.clampToBand(
                            ranged, lower: lowerBound, upper: upperBound)
                        : ranged
                }
            }
        )
    }

    private var accessibleLowerBound: Binding<Double> {
        Binding(
            get: { lowerBound },
            set: { newValue in
                performAccessibilityEdit {
                    let ceiling = max(range.lowerBound, upperBound - minGap)
                    lowerBound = min(max(range.lowerBound, newValue), ceiling)
                }
            }
        )
    }

    private var accessibleUpperBound: Binding<Double> {
        Binding(
            get: { upperBound },
            set: { newValue in
                performAccessibilityEdit {
                    let floor = min(range.upperBound, lowerBound + minGap)
                    upperBound = max(min(range.upperBound, newValue), floor)
                }
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
