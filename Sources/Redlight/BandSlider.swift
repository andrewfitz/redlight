import AppKit
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

    static func editedValue(
        _ proposed: Double, for handle: Handle, range: ClosedRange<Double>,
        lower: Double, upper: Double, showBand: Bool, minGap: Double
    ) -> Double {
        let v = clampToBand(proposed, lower: range.lowerBound, upper: range.upperBound)
        let gap = max(0, minGap)
        switch handle {
        case .value:
            // The owner moves both limits when editing an existing pin.
            return showBand && lower != upper ? clampToBand(v, lower: lower, upper: upper) : v
        case .lower:
            let ceiling = max(range.lowerBound, upper - gap)
            // An existing narrow band can widen, and a move toward its other limit
            // leaves it where it is instead of jumping in the opposite direction.
            if lower > ceiling, v >= lower { return lower }
            return min(v, ceiling)
        case .upper:
            let floor = min(range.upperBound, lower + gap)
            if upper < floor, v <= upper { return upper }
            return max(v, floor)
        }
    }

    /// When both markers overlap, choose the one that can move in the drag's direction.
    static func resolveStackedMarker(_ handle: Handle, dx: CGFloat, lower: Double, upper: Double) -> Handle {
        guard handle != .value, lower == upper, dx != 0 else { return handle }
        return dx < 0 ? .lower : .upper
    }

    static func isOnThumb(dx: CGFloat, dy: CGFloat, radius: CGFloat) -> Bool {
        hypot(dx, dy) <= radius
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
        let nearestMarker = min(dLo, dHi)
        if abs(dy) >= tabZone, nearestMarker <= tabHitRadius {
            return dLo <= dHi ? .lower : .upper
        }
        if lower == upper, isOnThumb(dx: dV, dy: dy, radius: inset) { return .value }
        // Brackets have a finite hit target. Elsewhere the track always moves the value.
        guard nearestMarker <= markerHitRadius else { return .value }
        if dV <= dLo && dV <= dHi {
            // Tied with a coincident marker: outside the bracket means the marker.
            if dV == dLo && x < loX { return .lower }
            if dV == dHi && x > hiX { return .upper }
            return .value
        }
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

/// Where the pieces of the Ember pill sit for one set of values at one width. UI-free, so
/// the ends of the range, a value resting on a limit, and the narrowest bands are testable.
///
/// Each handle's centre is `BandSliderCore.position` with `inset`, the same x the hit test
/// uses. A fill or band edge lies `inset` beyond its handle. That one rule gives:
/// - a fill that is still `minimumFill` long at the bottom of the range, so the grabber
///   never loses the colour it is drawn on;
/// - a fill that ends flush with the pill at the top of the range;
/// - limit notches that stay inside the pill when a limit is at either end.
///
/// It also routes a press to a handle (`handle(atX:…)`), starting from the grabber as it is
/// drawn here and only then asking `BandSliderCore`.
struct BandSliderFace: Equatable {
    struct Span: Equatable {
        var start: CGFloat
        var end: CGFloat
        var length: CGFloat { max(0, end - start) }
        var mid: CGFloat { (start + end) / 2 }
        func contains(_ x: CGFloat) -> Bool { start <= x && x <= end }
    }

    static let grabSize = CGSize(width: 4, height: 16)
    static let notchSize = CGSize(width: 2, height: 8)
    /// Clear space between a mark and the end of the fill or band it sits in.
    static let markGap: CGFloat = 5
    /// Inset of the shared value ⇄ x mapping: a mark's gap plus half the grabber.
    static let inset: CGFloat = markGap + grabSize.width / 2
    static let minimumFill: CGFloat = 2 * inset
    /// Travel over which a notch gives way to its ticks as the grabber closes in on it.
    static let notchFade: CGFloat = 3
    /// Height of the line a limit shows as while the grabber covers its notch: its two ends
    /// stand clear above and below the grabber, a point inside the pill.
    static let tickHeight: CGFloat = EmberMetrics.sliderHeight - 2
    /// Distance from the pill's centre line where the grabber's own area ends and the limit
    /// tabs (the ticks, and the pill's edges over any notch) begin.
    static let tabZone: CGFloat = grabSize.height / 2 + 0.5
    /// How far to either side of the drawn grabber a press still counts as on it.
    static let grabSlop: CGFloat = 2

    let valueX: CGFloat
    let lowerX: CGFloat
    let upperX: CGFloat
    /// True when the two limits coincide: the value is fixed and the slider reads as a plain
    /// level from the start of the track, as it did before Ember.
    let isPinned: Bool
    let fill: Span
    /// The allowed range. Nil without a band, and for a pinned one: a range with no length
    /// would only show as a fringe around the end of the fill.
    let band: Span?

    init(
        value: Double, lower: Double, upper: Double,
        range: ClosedRange<Double>, showBand: Bool, width: CGFloat
    ) {
        let inset = Self.inset
        func x(_ v: Double) -> CGFloat {
            BandSliderCore.position(v, width: width, inset: inset, range: range)
        }
        let shown = showBand ? BandSliderCore.clampToBand(value, lower: lower, upper: upper) : value
        valueX = x(shown)
        lowerX = x(lower)
        upperX = x(upper)
        isPinned = showBand && lower == upper
        let fillEnd = min(width, valueX + inset)
        if showBand, !isPinned {
            let start = max(0, min(lowerX, upperX) - inset)
            band = Span(start: start, end: min(width, max(lowerX, upperX) + inset))
            fill = Span(start: start, end: fillEnd)
        } else {
            band = nil
            fill = Span(start: 0, end: fillEnd)
        }
    }

    /// Centre of the lower-limit notch: `markGap` inside the leading end of the band.
    var lowerNotchX: CGFloat { lowerX - Self.inset + Self.markGap + Self.notchSize.width / 2 }
    /// Centre of the upper-limit notch: `markGap` inside the trailing end of the band.
    var upperNotchX: CGFloat { upperX + Self.inset - Self.markGap - Self.notchSize.width / 2 }

    /// The lower notch sits on the fill and gives way as the grabber reaches it, so a value
    /// resting on its lower limit shows one clean mark instead of two fused ones.
    var lowerNotchOpacity: Double {
        let notchEnd = lowerNotchX + Self.notchSize.width / 2
        return Self.fade(clearance: valueX - Self.grabSize.width / 2 - notchEnd)
    }

    /// The upper notch gives way as the grabber reaches it. Under the fill it stays, in the
    /// colour that reads on the fill.
    var upperNotchOpacity: Double {
        let notchStart = upperNotchX - Self.notchSize.width / 2
        return Self.fade(clearance: notchStart - (valueX + Self.grabSize.width / 2))
    }

    /// A notch the grabber covers shows as a tick above and below the grabber instead, so a
    /// value resting on a limit still shows that there is a limit there to take hold of.
    var lowerTickOpacity: Double { 1 - lowerNotchOpacity }
    var upperTickOpacity: Double { 1 - upperNotchOpacity }

    /// True when the upper notch lies over the fill, so it takes the colour that reads on
    /// the fill and not the one that reads on the band.
    var upperNotchIsOnFill: Bool { fill.contains(upperNotchX) }

    /// Where limit captions hang: under each end of the band, or under the grabber when the
    /// band is pinned and there is one number to show.
    var captionAnchors: (first: CGFloat, second: CGFloat?) {
        guard let band else { return (valueX, nil) }
        return (band.start, band.end)
    }

    static func fade(clearance: CGFloat) -> Double {
        Double(min(1, max(0, clearance / notchFade)))
    }

    static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: Hit testing

    /// True for a point (`dx`, `dy` from the grabber's centre) on the grabber as drawn: a
    /// bar, not a disc. `slop` widens it to either side.
    static func isOnGrabber(dx: CGFloat, dy: CGFloat, slop: CGFloat = grabSlop) -> Bool {
        abs(dx) <= grabSize.width / 2 + slop && abs(dy) <= tabZone
    }

    /// Which handle a press at `x`, `dy` from the pill's centre line, takes hold of.
    ///
    /// A press on the grabber always takes the value, also when the value rests on a limit
    /// or the band is pinned. The limit under the grabber is taken by its ticks, above and
    /// below the grabber, or from beside the grabber on the side the limit can move to.
    /// Everything else is `BandSliderCore.hitHandle`, with its tab zone starting where the
    /// grabber ends.
    static func handle(
        atX x: CGFloat, dy: CGFloat, width: CGFloat, range: ClosedRange<Double>,
        value: Double, lower: Double, upper: Double, showBand: Bool
    ) -> BandSliderCore.Handle {
        guard showBand else { return .value }
        let shown = BandSliderCore.clampToBand(value, lower: lower, upper: upper)
        let valueX = BandSliderCore.position(shown, width: width, inset: inset, range: range)
        if isOnGrabber(dx: x - valueX, dy: dy) { return .value }
        return BandSliderCore.hitHandle(
            atX: x, dy: dy, width: width, inset: inset, range: range,
            value: value, lower: lower, upper: upper, showBand: true, tabZone: tabZone)
    }

    /// True when a press that took the value keeps its distance from the grabber instead of
    /// bringing the grabber to the pointer: on the grabber, or in the clear space beside it.
    static func keepsGrabOffset(dx: CGFloat, dy: CGFloat) -> Bool {
        isOnGrabber(dx: dx, dy: dy, slop: markGap)
    }
}

/// Placement of short labels that hang under points on a row: the limit captions here, and
/// the sunrise and sunset times under the sun arc.
enum AnchoredLabels {
    /// Leading x of one label centred on `anchor` and kept inside `0…row`.
    static func origin(anchor: CGFloat, width: CGFloat, row: CGFloat) -> CGFloat {
        min(max(0, row - width), max(0, anchor - width / 2))
    }

    /// Leading xs of two labels, `first` hanging at or before `second`. Each is centred on its
    /// anchor when there is room. If they would come closer than `gap` they move apart
    /// evenly, and if that pushes one off an end of the row the pair slides back in.
    /// Labels too wide to share the row overlap from its two ends.
    static func origins(
        first: (anchor: CGFloat, width: CGFloat), second: (anchor: CGFloat, width: CGFloat),
        row: CGFloat, gap: CGFloat
    ) -> (first: CGFloat, second: CGFloat) {
        var a = origin(anchor: first.anchor, width: first.width, row: row)
        var b = origin(anchor: second.anchor, width: second.width, row: row)
        let overlap = a + first.width + gap - b
        guard overlap > 0 else { return (a, b) }
        a -= overlap / 2
        b += overlap / 2
        if a < 0 {
            b -= a
            a = 0
        }
        let overflow = b + second.width - row
        if overflow > 0 {
            b = max(0, b - overflow)
            a = max(0, a - overflow)
        }
        return (a, b)
    }
}

/// Lays one or two labels under their anchors, measuring the labels themselves.
private struct AnchoredLabelRow: Layout {
    var first: CGFloat
    var second: CGFloat?
    var gap: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.reduce(CGFloat(0)) { max($0, $1.sizeThatFits(.unspecified).height) }
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let size = label.sizeThatFits(.unspecified)
        func place(_ subview: LayoutSubview, at x: CGFloat) {
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.midY), anchor: .leading,
                          proposal: .unspecified)
        }
        guard let second, subviews.count > 1 else {
            place(label, at: AnchoredLabels.origin(anchor: first, width: size.width, row: bounds.width))
            return
        }
        let other = subviews[1].sizeThatFits(.unspecified)
        let xs = AnchoredLabels.origins(
            first: (first, size.width), second: (second, other.width), row: bounds.width, gap: gap)
        place(label, at: xs.first)
        place(subviews[1], at: xs.second)
    }
}

/// The Ember slider: a thick pill whose fill shows the value, with an optional adaptive
/// band, over an arbitrary `range`.
///
/// Without a band the fill runs from the start of the track to the value. With `showBand`
/// the allowed range is a second, stronger pill; the fill runs from the lower limit to the
/// value, two small notches mark the limits, and a caption row under the pill names them.
/// The value is hard-clamped into the band, both while dragging and when rendered.
///
/// The grabber bar is what `BandSliderCore` calls the thumb and the notches are its markers.
/// All three share one value ⇄ pixel mapping (`BandSliderFace.inset`), so the drawing and the
/// hit test agree. A single drag gesture routes to whichever handle is nearest where the
/// drag began. A press on the grabber itself always takes the value. Beside a grabber that
/// rests on a limit, the side inside the band is the value and the side outside it the limit.
/// A press near the top or bottom edge of the pill over a limit always takes the limit: that
/// is where the ticks of a covered notch show. Existing pinned bands can move together with
/// the grabber or be widened by dragging a notch in the direction of either limit. While a
/// notch is dragged, `onPreview` fires with its value so the caller can apply it live;
/// `onPreviewEnd` fires on release so the caller can revert to the real value.
struct BandSlider: View {
    @Binding var value: Double          // live value, within `range`
    @Binding var lowerBound: Double     // adaptive min
    @Binding var upperBound: Double     // adaptive max
    var range: ClosedRange<Double> = 0...1
    var showBand: Bool
    var label: String = "Value"
    var minGap: Double = 0.05
    /// Which Ember fill the slider takes.
    var tone: EmberTone = .accent
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
    @State private var gestureStart: CGPoint?
    @State private var hasMoved = false
    @State private var isPreviewing = false
    @GestureState private var gestureInProgress = false
    @FocusState private var focusedHandle: BandSliderCore.Handle?
    /// Focus is drawn only when it arrived by keyboard, so neither a click that focuses a
    /// handle nor the popover handing a handle its first focus leaves it looking focused.
    @State private var showsFocus = false

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Emphasis { case rest, pressed, focused }

    private static let pillHeight = EmberMetrics.sliderHeight
    private static let captionSpacing: CGFloat = 1
    private static let captionHeight: CGFloat = 12
    private var inset: CGFloat { BandSliderFace.inset }
    private var isPinned: Bool { showBand && lowerBound == upperBound }
    // The model can briefly lag a marker drag. Keep the visual and accessible value in sync.
    private var displayedValue: Double {
        showBand ? BandSliderCore.clampToBand(value, lower: lowerBound, upper: upperBound) : value
    }

    var body: some View {
        // Every mark is chosen for the fill it is drawn on.
        let fill = palette.sliderFillRGB(tone, accent: accent.rgb(for: palette))
        let grabRest = palette.mark(.grabber, on: fill)
        let onFillStrong = palette.mark(.solid, on: fill)
        let notchOnFill = palette.mark(.notch, on: fill)
        let notchOnBand = palette.mark(.notch, on: palette.sliderBand)
        let onBandStrong = palette.mark(.solid, on: palette.sliderBand)
        return GeometryReader { geo in
            let w = geo.size.width
            // The centre line of the pill, not of the whole view: the captions hang below it.
            let midY = Self.pillHeight / 2
            let face = BandSliderFace(value: value, lower: lowerBound, upper: upperBound,
                                      range: range, showBand: showBand, width: w)
            let valX = face.valueX
            let loX = face.lowerX
            let hiX = face.upperX

            VStack(alignment: .leading, spacing: Self.captionSpacing) {
                ZStack {
                    palette.fill

                    if let band = face.band {
                        span(band, color: palette.fillStrong, midY: midY)
                    }
                    span(face.fill, color: fill.color, midY: midY)

                    if showBand {
                        // A covered notch is under the fill, so its ticks take the fill's colour.
                        tick(x: face.lowerNotchX, midY: midY, color: notchOnFill,
                             opacity: face.lowerTickOpacity)
                        tick(x: face.upperNotchX, midY: midY, color: notchOnFill,
                             opacity: face.upperTickOpacity)
                        notch(.lower, x: face.lowerNotchX, valueX: valX, midY: midY,
                              rest: notchOnFill, opacity: face.lowerNotchOpacity,
                              emphasised: onFillStrong)
                        notch(.upper, x: face.upperNotchX, valueX: valX, midY: midY,
                              rest: face.upperNotchIsOnFill ? notchOnFill : notchOnBand,
                              opacity: face.upperNotchOpacity,
                              emphasised: face.upperNotchIsOnFill ? onFillStrong : onBandStrong)
                    }

                    grab(x: valX, midY: midY, rest: grabRest, emphasised: onFillStrong)
                }
                .frame(height: Self.pillHeight)
                // A short fill at the start of the track keeps to the track's own corners.
                .clipShape(RoundedRectangle(cornerRadius: EmberMetrics.sliderRadius))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($gestureInProgress) { _, inProgress, _ in inProgress = true }
                        .onChanged { g in
                            if active != nil, gestureStart != g.startLocation { finishInteraction() }
                            if active == nil {
                                let handle = BandSliderFace.handle(
                                    atX: g.startLocation.x, dy: g.startLocation.y - midY,
                                    width: w, range: range,
                                    value: value, lower: lowerBound, upper: upperBound,
                                    showBand: showBand
                                )
                                active = handle
                                if showsFocus { showsFocus = false }
                                interactionToken = onInteractionBegin?()
                                interactionGate = SliderInteractionGate()
                                gestureStart = g.startLocation
                                let start = g.startLocation.x
                                switch handle {
                                case .lower: grabOffset = loX - start
                                case .upper: grabOffset = hiX - start
                                // On the grabber: keep the grab point. On the bare track: jump there.
                                case .value:
                                    let onThumb = BandSliderFace.keepsGrabOffset(
                                        dx: valX - start, dy: g.startLocation.y - midY)
                                    grabOffset = onThumb ? valX - start : 0
                                    hasMoved = !onThumb
                                }
                            }
                            updateDrag(g, width: w)
                        }
                        .onEnded { g in
                            guard gestureStart == g.startLocation else { return }
                            updateDrag(g, width: w)
                            finishInteraction()
                        }
                )

                if showBand {
                    captions(face.captionAnchors, color: palette.tertiary)
                }
            }
        }
        .frame(height: showBand
               ? Self.pillHeight + Self.captionSpacing + Self.captionHeight : Self.pillHeight)
        // A cancelled gesture resets GestureState even when SwiftUI skips onEnded.
        .onChange(of: gestureInProgress) { _, inProgress in
            if !inProgress, active != nil { finishInteraction() }
        }
        .onChange(of: focusedHandle) { _, handle in
            showsFocus = Self.drawsFocus(
                handleIsFocused: handle != nil, isDragging: active != nil,
                event: NSApp?.currentEvent?.type)
        }
        .onDisappear { finishInteraction() }
        .accessibilityRepresentation {
            VStack {
                Slider(value: accessibleValue(for: .value), in: range) { Text(label) }
                    .accessibilityLabel("\(label) current value")
                    .accessibilityValue(Self.percentLabel(displayedValue) + (isPinned ? ", fixed" : ""))
                if showBand {
                    Slider(value: accessibleValue(for: .lower), in: range) {
                        Text("\(label) adaptive minimum")
                    }
                    .accessibilityLabel("\(label) adaptive minimum")
                    .accessibilityValue(Self.percentLabel(lowerBound))
                    Slider(value: accessibleValue(for: .upper), in: range) {
                        Text("\(label) adaptive maximum")
                    }
                    .accessibilityLabel("\(label) adaptive maximum")
                    .accessibilityValue(Self.percentLabel(upperBound))
                }
            }
        }
    }

    private func updateDrag(_ g: DragGesture.Value, width w: CGFloat) {
        // Preserve the original token until release, including across
        // redraws from the command that interrupted this gesture.
        guard var handle = active, acceptsInteractionMutation() else { return }
        if !hasMoved {
            guard g.translation.width != 0 else { return }
            handle = BandSliderCore.resolveStackedMarker(
                handle, dx: g.translation.width, lower: lowerBound, upper: upperBound)
            active = handle
            hasMoved = true
        }
        let v = editedValue(val(g.location.x + grabOffset, w), for: handle)
        guard v != currentValue(for: handle) else { return }
        switch handle {
        case .lower:
            lowerBound = v
            isPreviewing = true
            onPreview?(v)
        case .upper:
            upperBound = v
            isPreviewing = true
            onPreview?(v)
        case .value:
            value = v
        }
    }

    /// Controls can disappear while the parent remains visible (for example, About).
    /// End this gesture's preview, but never clear a newer interaction's preview.
    private func finishInteraction() {
        interactionGate.endPreviewIfCurrent(
            token: interactionToken, isCurrent: isInteractionCurrent,
            isPreviewing: isPreviewing, onPreviewEnd: onPreviewEnd
        )
        active = nil
        interactionToken = nil
        interactionGate = SliderInteractionGate()
        gestureStart = nil
        hasMoved = false
        isPreviewing = false
    }

    private func acceptsInteractionMutation() -> Bool {
        interactionGate.permitsMutation(token: interactionToken, isCurrent: isInteractionCurrent)
    }

    // MARK: - Position → value mapping (the inverse of the one `BandSliderFace` draws with)

    private func val(_ px: CGFloat, _ w: CGFloat) -> Double {
        BandSliderCore.value(atX: px, width: w, inset: inset, range: range)
    }

    private static func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) percent"
    }

    private func currentValue(for handle: BandSliderCore.Handle) -> Double {
        switch handle {
        case .lower: lowerBound
        case .upper: upperBound
        case .value: value
        }
    }

    private func editedValue(_ proposed: Double, for handle: BandSliderCore.Handle) -> Double {
        BandSliderCore.editedValue(proposed, for: handle, range: range, lower: lowerBound,
                                   upper: upperBound, showBand: showBand, minGap: minGap)
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

    private func accessibleValue(for handle: BandSliderCore.Handle) -> Binding<Double> {
        Binding(
            get: { handle == .value ? displayedValue : currentValue(for: handle) },
            set: { setDiscreteValue($0, for: handle) }
        )
    }

    private func keyboardHandle<Content: View>(_ content: Content, for handle: BandSliderCore.Handle) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focusedHandle, equals: handle)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                if !showsFocus { showsFocus = true }
                let delta = press.key == .rightArrow || press.key == .upArrow ? 0.01 : -0.01
                let current = handle == .value ? displayedValue : currentValue(for: handle)
                setDiscreteValue(current + delta, for: handle)
                return .handled
            }
    }

    private func setDiscreteValue(_ proposed: Double, for handle: BandSliderCore.Handle) {
        let v = editedValue(proposed, for: handle)
        guard v != currentValue(for: handle) else { return }
        performAccessibilityEdit {
            switch handle {
            case .lower: lowerBound = v
            case .upper: upperBound = v
            case .value: value = v
            }
        }
    }

    /// Whether a handle that has just taken focus shows it. Only when a key press moved the
    /// focus there: not during a drag, and not when focus arrived with a click or with the
    /// popover opening. An arrow key on a focused handle shows it from then on.
    static func drawsFocus(handleIsFocused: Bool, isDragging: Bool, event: NSEvent.EventType?) -> Bool {
        handleIsFocused && !isDragging && event == .keyDown
    }

    // MARK: - Pieces

    private func emphasis(of handle: BandSliderCore.Handle) -> Emphasis {
        if showsFocus, focusedHandle == handle { return .focused }
        return active == handle ? .pressed : .rest
    }

    /// Short enough to read as a response, never as motion. Scoped to a mark's own size and
    /// colour: positions are applied outside it, so a handle tracks the pointer 1:1.
    private var emphasisAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    private func span(_ span: BandSliderFace.Span, color: Color, midY: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: EmberMetrics.sliderRadius)
            .fill(color)
            .frame(width: span.length, height: Self.pillHeight)
            .position(x: span.mid, y: midY)
    }

    /// A handle's place in the layout: its size at rest, whatever size its mark is drawn at
    /// and wherever `shift` moves it. SwiftUI orders the Tab stops by where the focusable
    /// views lie. A handle that grew or moved when it took the focus could change places
    /// with its neighbour, and Tab would then go back and forth between the two: a limit
    /// under the grabber did, so Tab never got past a value resting on its limit.
    private func handleSlot<Mark: View>(_ rest: CGSize, shift: CGFloat = 0, mark: Mark) -> some View {
        Color.clear
            .frame(width: rest.width, height: rest.height)
            .overlay { mark.offset(x: shift) }
    }

    /// The value handle. With no focus ring, focus is the bar itself: wider, taller, darker.
    /// A press only lengthens and darkens it.
    private func grab(x: CGFloat, midY: CGFloat, rest: Color, emphasised: Color) -> some View {
        let state = emphasis(of: .value)
        let size: CGSize = switch state {
        case .rest: BandSliderFace.grabSize
        case .pressed: CGSize(width: 4, height: 20)
        case .focused: CGSize(width: 6, height: 22)
        }
        return keyboardHandle(
            handleSlot(BandSliderFace.grabSize, mark: Capsule()
                .fill(state == .rest ? rest : emphasised)
                .frame(width: size.width, height: size.height)
                .animation(emphasisAnimation, value: state)),
            for: .value
        )
        .position(x: x, y: midY)
        .zIndex(1)
    }

    /// The ends of a limit whose notch the grabber covers. Not a handle of its own: the notch
    /// under the grabber takes the focus and the press.
    private func tick(x: CGFloat, midY: CGFloat, color: Color, opacity: Double) -> some View {
        Capsule()
            .fill(color)
            .frame(width: BandSliderFace.notchSize.width, height: BandSliderFace.tickHeight)
            .opacity(opacity)
            .position(x: x, y: midY)
            .allowsHitTesting(false)
    }

    /// A limit handle. Pressed or focused it grows taller than the grabber and comes in
    /// front of it, so it shows even when the value is resting on that limit. There it
    /// lines up with the grabber (`valueX`), so the two read as one taller bar, not as a pair
    /// a point apart.
    private func notch(
        _ handle: BandSliderCore.Handle, x: CGFloat, valueX: CGFloat, midY: CGFloat,
        rest: Color, opacity: Double, emphasised: Color
    ) -> some View {
        let state = emphasis(of: handle)
        let size = state == .rest ? BandSliderFace.notchSize : CGSize(width: 4, height: 22)
        let aligned = state != .rest && abs(x - valueX) < BandSliderFace.grabSize.width / 2
        return keyboardHandle(
            handleSlot(BandSliderFace.notchSize, shift: aligned ? valueX - x : 0, mark: Capsule()
                .fill(state == .rest ? rest : emphasised)
                .frame(width: size.width, height: size.height)
                .opacity(state == .rest ? opacity : 1)
                .animation(emphasisAnimation, value: state)),
            for: handle
        )
        .position(x: x, y: midY)
        .zIndex(state == .rest ? 0 : 2)
    }

    private func captions(_ anchors: (first: CGFloat, second: CGFloat?), color: Color) -> some View {
        AnchoredLabelRow(first: anchors.first, second: anchors.second) {
            Text(verbatim: BandSliderFace.percentText(lowerBound))
            if anchors.second != nil {
                Text(verbatim: BandSliderFace.percentText(upperBound))
            }
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(color)
        .frame(height: Self.captionHeight)
        .allowsHitTesting(false)
    }
}
