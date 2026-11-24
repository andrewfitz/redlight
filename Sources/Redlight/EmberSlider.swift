import AppKit
import SwiftUI

/// Where the pieces of the popover's Ember slider sit for one value at one width. UI-free,
/// so the ends of the range and the read-only Auto band are testable.
///
/// The grabber's centre is `SliderCore.position` with `inset`, and a fill ends `inset` past
/// it. That one rule gives a fill that is still `minimumFill` long at the bottom of the
/// range, so the grabber never loses the colour it is drawn on, and a fill that ends flush
/// with the pill at the top of the range.
///
/// The fill always runs in full colour from the start of the track to the value, in Auto as
/// in Manual. In Auto the stretch from the value up to Auto's upper limit shows in the
/// slightly stronger track tone (`tint`), read-only: how far up Auto may still go. A value
/// resting on its upper limit shows no tint, and a pinned band is a plain level.
struct EmberSliderFace: Equatable {
    struct Span: Equatable {
        var start: CGFloat
        var end: CGFloat
        var length: CGFloat { max(0, end - start) }
        var mid: CGFloat { (start + end) / 2 }
    }

    static let grabSize = CGSize(width: 4, height: 16)
    /// Clear space between the grabber and the end of the fill it sits in.
    static let markGap: CGFloat = 5
    /// Inset of the value ⇄ x mapping: the grabber's gap plus half the grabber.
    static let inset: CGFloat = markGap + grabSize.width / 2
    static let minimumFill: CGFloat = 2 * inset
    /// Within this distance of where either end of the range is drawn (and anywhere past
    /// it), the pointer takes exactly that end.
    static let endSnap: CGFloat = 4
    /// How far above and below the pill a press still takes the slider.
    static let verticalSlop: CGFloat = 4
    /// How far to either side of the grabber's centre a press counts as a press on the
    /// grabber: the value stays where it is until the pointer moves, and then follows it
    /// at the distance it was taken at.
    static let grabReach: CGFloat = grabSize.width / 2 + 3

    let valueX: CGFloat
    /// The fill in full colour, from the start of the track. The grabber sits `markGap`
    /// inside its trailing end.
    let fill: Span
    /// The visible stretch from the end of the fill to the end of Auto's upper limit, in the
    /// stronger track tone. Nil in Manual, for a pinned band, and for a value at or above its
    /// upper limit.
    let tint: Span?

    /// `limits` is Auto's band, or nil in Manual.
    init(value: Double, range: ClosedRange<Double>, band limits: ClosedRange<Double>?, width: CGFloat) {
        let inset = Self.inset
        valueX = Self.x(for: value, width: width, range: range)
        fill = Span(start: 0, end: min(width, valueX + inset))
        if let limits, limits.lowerBound < limits.upperBound {
            let upperEnd = min(width, Self.x(for: limits.upperBound, width: width, range: range) + inset)
            tint = upperEnd > fill.end ? Span(start: fill.end, end: upperEnd) : nil
        } else {
            tint = nil
        }
    }

    static func x(for value: Double, width: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        SliderCore.position(value, width: width, inset: inset, range: range)
    }

    /// The value under the pointer, the ends taken within `endSnap`.
    static func value(atX x: CGFloat, width: CGFloat, range: ClosedRange<Double>) -> Double {
        SliderCore.value(atX: x, width: width, inset: inset, snap: endSnap, range: range)
    }
}

/// One press on the slider, from mouse-down to mouse-up.
///
/// A press anywhere on the pill takes the slider: the value jumps to the pointer and then
/// follows it, and past either end it holds that end. A press on the grabber itself leaves
/// the value alone until the pointer moves (a click there changes nothing, so a preset
/// stays chosen), and then the value follows at the distance the grabber was taken at.
struct EmberSliderDrag: Equatable {
    let start: CGPoint
    /// The grabber's x minus the pointer's: kept for a press on the grabber, 0 elsewhere.
    let offset: CGFloat
    /// False while a press on the grabber has not moved.
    private(set) var isLive: Bool

    init(start: CGPoint, valueX: CGFloat) {
        self.start = start
        let dx = valueX - start.x
        if abs(dx) <= EmberSliderFace.grabReach {
            offset = dx
            isLive = false
        } else {
            offset = 0
            isLive = true
        }
    }

    /// The value for the pointer at `x`, or nil while nothing is to change.
    mutating func value(pointerX x: CGFloat, width: CGFloat, range: ClosedRange<Double>) -> Double? {
        if !isLive {
            guard x != start.x else { return nil }
            isLive = true
        }
        return EmberSliderFace.value(atX: x + offset, width: width, range: range)
    }
}

/// The popover's Ember slider: a thick pill whose fill shows the value, over any `range`,
/// and in Auto a row of flags under it for Auto's minimum and maximum.
///
/// The whole pill, and a few points above it (and down to the flag row below it), is the
/// value's handle (`EmberSliderDrag`). In Auto the track shows the band past the fill
/// (`EmberSliderFace`), and the flags (`EmberSliderFlags`) set its limits; a flag is taken
/// only in its own row. Without `onLimitChange` the band is shown but has no flags.
///
/// Keyboard: the value, then the minimum, then the maximum are Tab stops, each taking the
/// keys of `SliderKeyStep`. Focus is drawn only when it arrived by keyboard: on the value as
/// the grabber itself, wider, taller and darker. Accessibility: a slider named `label` with
/// its value in percent, and in Auto "`label` minimum" and "`label` maximum".
struct EmberSlider: View {
    let value: Double
    var range: ClosedRange<Double> = 0...1
    /// Auto's allowed range. Nil in Manual.
    var band: ClosedRange<Double>? = nil
    var label: String = "Value"
    /// Which Ember fill the slider takes.
    var tone: EmberTone = .accent
    /// Every value the slider sets, by pointer, key or assistive app.
    let onChange: (Double) -> Void
    /// Sets one of Auto's limits, from its flag. Nil: no flags.
    var onLimitChange: ((SliderCore.Bound, Double) -> Void)? = nil
    /// While a flag is dragged: its value, to show on the displays.
    var onPreview: ((Double) -> Void)? = nil
    /// When a flag is released, or a limit set by key: back to the real output.
    var onPreviewEnd: (() -> Void)? = nil
    /// Called when a drag or a discrete edit starts; returns a token for it.
    var onInteractionBegin: (() -> UInt64)? = nil
    /// False once the token is stale (a command took over); the rest of that drag is ignored.
    var isInteractionCurrent: ((UInt64) -> Bool)? = nil

    @State private var drag: EmberSliderDrag?
    @State private var interactionToken: UInt64?
    @State private var interactionGate = SliderInteractionGate()
    @State private var isHovering = false
    @GestureState private var gestureInProgress = false
    @FocusState private var isFocused: Bool
    @State private var showsFocus = false

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Emphasis: Equatable { case rest, hover, pressed, focused }

    private static let pillHeight = EmberMetrics.sliderHeight
    private static let slop = EmberSliderFace.verticalSlop

    private var isPinned: Bool { band.map { $0.lowerBound == $0.upperBound } ?? false }
    private var showsFlags: Bool { band != nil && onLimitChange != nil }

    /// The value as drawn: in Auto it never sits outside the band, also while a flag is
    /// dragged across it and Auto has not yet followed.
    private var shown: Double {
        band.map { SliderCore.clampToBand(value, lower: $0.lowerBound, upper: $0.upperBound) } ?? value
    }

    /// The slider's height: the pill, and in Auto the flag row under it.
    nonisolated static func height(showsFlags: Bool) -> CGFloat {
        EmberMetrics.sliderHeight + (showsFlags ? EmberFlagFace.spacing + EmberFlagFace.rowHeight : 0)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: EmberFlagFace.spacing) {
                pill(width: geo.size.width)
                if let band, let onLimitChange {
                    EmberSliderFlags(
                        lower: band.lowerBound, upper: band.upperBound, range: range, width: geo.size.width,
                        onLimitChange: onLimitChange, onPreview: onPreview, onPreviewEnd: onPreviewEnd,
                        onInteractionBegin: onInteractionBegin, isInteractionCurrent: isInteractionCurrent)
                }
            }
        }
        .frame(height: Self.height(showsFlags: showsFlags))
        // A cancelled gesture resets GestureState even when SwiftUI skips onEnded.
        .onChange(of: gestureInProgress) { _, inProgress in
            if !inProgress, drag != nil { finishInteraction() }
        }
        .onChange(of: isFocused) { _, focused in
            showsFocus = SliderFocus.drawsFocus(
                handleIsFocused: focused, isDragging: drag != nil, event: NSApp?.currentEvent?.type)
        }
        .onDisappear { finishInteraction() }
        .accessibilityRepresentation {
            VStack {
                Slider(value: Binding(get: { shown }, set: { discreteEdit($0) }), in: range) { Text(label) }
                    .accessibilityLabel(label)
                    .accessibilityValue(SliderCore.spokenPercent(shown))
                if let band, showsFlags {
                    limitSlider(.lower, band: band)
                    limitSlider(.upper, band: band)
                }
            }
        }
    }

    private func limitSlider(_ bound: SliderCore.Bound, band: ClosedRange<Double>) -> some View {
        let name = "\(label) \(bound == .lower ? "minimum" : "maximum")"
        let current = bound == .lower ? band.lowerBound : band.upperBound
        return Slider(value: Binding(get: { current }, set: { proposed in
            guard let onLimitChange else { return }
            EmberSliderFlags.discreteEdit(
                proposed, for: bound, range: range, lower: band.lowerBound, upper: band.upperBound,
                minGap: 0.05, onLimitChange: onLimitChange, onPreviewEnd: onPreviewEnd,
                onInteractionBegin: onInteractionBegin, isInteractionCurrent: isInteractionCurrent)
        }), in: range) { Text(name) }
            .accessibilityLabel(name)
            .accessibilityValue(isPinned
                ? "Fixed at \(SliderCore.spokenPercent(current))" : SliderCore.spokenPercent(current))
    }

    private func pill(width w: CGFloat) -> some View {
        // Every mark is chosen for the fill it is drawn on.
        let fill = palette.sliderFillRGB(tone, accent: accent.rgb(for: palette))
        let grabRest = palette.mark(.grabber, on: fill)
        let grabStrong = palette.mark(.solid, on: fill)
        let midY = Self.pillHeight / 2
        let face = EmberSliderFace(value: shown, range: range, band: band, width: w)
        // Below the pill the handle reaches only as far as the flag row.
        let below = showsFlags ? EmberFlagFace.spacing : Self.slop
        return ZStack {
            palette.fill

            if let tint = face.tint {
                // Drawn from the start of the track, under the fill, so the fill's rounded
                // end lies on the tint and not on a seam.
                span(.init(start: 0, end: tint.end), color: palette.fillStrong, midY: midY)
            }
            span(face.fill, color: fill.color, midY: midY)

            // The value's keyboard stop: the whole pill, so it keeps one place in the Tab
            // order wherever the value is.
            Color.clear
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(keys: SliderKeyStep.keys) { press in
                    if !showsFocus { showsFocus = true }
                    guard let step = SliderKeyStep(press.key) else { return .ignored }
                    discreteEdit(step.value(from: shown, in: range, large: press.modifiers.contains(.shift)))
                    return .handled
                }

            grab(x: face.valueX, midY: midY, rest: grabRest, strong: grabStrong)
        }
        .frame(width: w, height: Self.pillHeight)
        // A short fill at the start of the track keeps to the track's own corners.
        .clipShape(RoundedRectangle(cornerRadius: EmberMetrics.sliderRadius))
        // The handle reaches a little above the pill, and below it down to the flag row.
        .padding(.top, Self.slop)
        .padding(.bottom, below)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($gestureInProgress) { _, inProgress, _ in inProgress = true }
                .onChanged { g in
                    if let drag, drag.start != g.startLocation { finishInteraction() }
                    if drag == nil {
                        if showsFocus { showsFocus = false }
                        interactionToken = onInteractionBegin?()
                        interactionGate = SliderInteractionGate()
                        drag = EmberSliderDrag(start: g.startLocation, valueX: face.valueX)
                    }
                    updateDrag(pointerX: g.location.x, width: w)
                }
                .onEnded { g in
                    guard drag?.start == g.startLocation else { return }
                    updateDrag(pointerX: g.location.x, width: w)
                    finishInteraction()
                }
        )
        .padding(.top, -Self.slop)
        .padding(.bottom, -below)
    }

    private func updateDrag(pointerX x: CGFloat, width: CGFloat) {
        // Preserve the original token until release, including across redraws from the
        // command that interrupted this gesture.
        guard var current = drag, interactionGate.permitsMutation(
            token: interactionToken, isCurrent: isInteractionCurrent) else { return }
        let next = current.value(pointerX: x, width: width, range: range)
        if current != drag { drag = current }
        guard let next, next != shown else { return }
        onChange(next)
    }

    private func finishInteraction() {
        drag = nil
        interactionToken = nil
        interactionGate = SliderInteractionGate()
    }

    /// A key press or an assistive app's adjustment: one edit with a fresh token of its
    /// own, which can supersede a drag without inheriting its token.
    private func discreteEdit(_ proposed: Double) {
        let v = min(range.upperBound, max(range.lowerBound, proposed))
        guard v.isFinite, v != shown else { return }
        let token = onInteractionBegin?()
        if let token, isInteractionCurrent?(token) == false { return }
        onChange(v)
    }

    // MARK: - Pieces

    private var emphasis: Emphasis {
        if showsFocus, isFocused { return .focused }
        if drag != nil { return .pressed }
        return isHovering ? .hover : .rest
    }

    /// Short enough to read as a response, never as motion. Scoped to the grabber's own size
    /// and colour: its position is applied outside it, so it tracks the pointer 1:1.
    private var emphasisAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    nonisolated static func grabberSize(_ emphasis: Emphasis) -> CGSize {
        switch emphasis {
        case .rest: EmberSliderFace.grabSize
        case .hover: CGSize(width: 5, height: 18)
        case .pressed: CGSize(width: 5, height: 20)
        case .focused: CGSize(width: 6, height: 22)
        }
    }

    private func span(_ span: EmberSliderFace.Span, color: Color, midY: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: EmberMetrics.sliderRadius)
            .fill(color)
            .frame(width: span.length, height: Self.pillHeight)
            .position(x: span.mid, y: midY)
    }

    /// The grabber: at rest the design's bar; hovered a little larger; pressed or focused
    /// larger again and in the solid ink.
    private func grab(x: CGFloat, midY: CGFloat, rest: Color, strong: Color) -> some View {
        let state = emphasis
        let size = Self.grabberSize(state)
        return Color.clear
            .frame(width: EmberSliderFace.grabSize.width, height: EmberSliderFace.grabSize.height)
            .overlay {
                Capsule()
                    .fill(state == .rest || state == .hover ? rest : strong)
                    .frame(width: size.width, height: size.height)
                    .animation(emphasisAnimation, value: state)
            }
            .position(x: x, y: midY)
            .allowsHitTesting(false)
    }
}
