import AppKit
import SwiftUI

/// Where the range control's thumbs sit at one width. UI-free, so the hit rules are testable.
///
/// A thin track with two round thumbs. A thumb's centre is `SliderCore.position` with
/// `inset` (half a thumb), so a thumb at either end of the range ends flush with the track.
struct EmberRangeFace: Equatable {
    static let thumbDiameter: CGFloat = 16
    /// A thumb takes a press within this square around its centre: easy to grab, at least
    /// 24 pt each way.
    static let hitSize: CGFloat = 28
    static let trackHeight: CGFloat = 6
    /// The control's height: one hit target.
    static let height: CGFloat = hitSize
    static let inset: CGFloat = thumbDiameter / 2
    /// Within this distance of where either end of the range is drawn, a thumb takes
    /// exactly that end.
    static let endSnap: CGFloat = 4

    let lowerX: CGFloat
    let upperX: CGFloat
    /// Both limits on one spot (a band pinned from the CLI): the thumbs lie on each other.
    let isStacked: Bool

    init(lower: Double, upper: Double, range: ClosedRange<Double>, width: CGFloat) {
        lowerX = Self.x(for: min(lower, upper), width: width, range: range)
        upperX = Self.x(for: max(lower, upper), width: width, range: range)
        isStacked = lower == upper
    }

    static func x(for value: Double, width: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        SliderCore.position(value, width: width, inset: inset, range: range)
    }

    static func value(atX x: CGFloat, width: CGFloat, range: ClosedRange<Double>) -> Double {
        SliderCore.value(atX: x, width: width, inset: inset, snap: endSnap, range: range)
    }

    func x(of bound: SliderCore.Bound) -> CGFloat { bound == .lower ? lowerX : upperX }
}

/// One press on the range control, from mouse-down to mouse-up.
///
/// The press takes the nearer thumb. On the thumb (within `hitSize`), nothing moves until the
/// pointer does, and the thumb then follows at the distance it was taken at; on the bare
/// track the thumb jumps to the pointer. Two stacked thumbs are taken by the direction of the
/// first movement: left the lower limit, right the upper one. Every value goes through
/// `SliderCore.editedValue`, so the limits keep `minGap` apart.
struct EmberRangeDrag: Equatable {
    let start: CGPoint
    private(set) var bound: SliderCore.Bound
    /// The thumb's x minus the pointer's: kept for a press on the thumb, 0 elsewhere.
    let offset: CGFloat
    let isOnThumb: Bool
    private(set) var hasMoved = false
    /// A press on stacked thumbs that has not moved yet.
    private(set) var awaitsDirection: Bool

    init(start: CGPoint, face: EmberRangeFace) {
        self.start = start
        let toLower = abs(start.x - face.lowerX), toUpper = abs(start.x - face.upperX)
        let bound: SliderCore.Bound = if toLower != toUpper {
            toLower < toUpper ? .lower : .upper
        } else {
            start.x <= face.lowerX ? .lower : .upper
        }
        self.bound = bound
        let thumbX = face.x(of: bound)
        isOnThumb = abs(start.x - thumbX) <= EmberRangeFace.hitSize / 2
        offset = isOnThumb ? thumbX - start.x : 0
        awaitsDirection = isOnThumb && face.isStacked
    }

    /// The limit to move and its new value for the pointer at `x`; nil while nothing moves.
    mutating func proposal(
        pointerX x: CGFloat, width: CGFloat, range: ClosedRange<Double>,
        lower: Double, upper: Double, minGap: Double
    ) -> (bound: SliderCore.Bound, value: Double)? {
        if isOnThumb, !hasMoved {
            let dx = x - start.x
            guard dx != 0 else { return nil }
            if awaitsDirection {
                bound = SliderCore.resolveStackedMarker(bound, dx: dx, lower: lower, upper: upper)
                awaitsDirection = false
            }
        }
        hasMoved = true
        let proposed = EmberRangeFace.value(atX: x + offset, width: width, range: range)
        return (bound, SliderCore.editedValue(
            proposed, for: bound, range: range, lower: lower, upper: upper, minGap: minGap))
    }
}

/// Auto's range for one channel, on the Settings page: a thin Ember track, the range in the
/// slider's fill, and a round thumb for each limit (`EmberRangeDrag`).
///
/// While a thumb is dragged, `onPreview` gets its value, so the caller can show that limit
/// on the displays; `onPreviewEnd` comes on release, so it can go back to the real value.
/// A drag is abandoned once its interaction token is stale. Keyboard: each thumb is a Tab
/// stop and takes the keys of `SliderKeyStep`. Accessibility: two sliders, "<label> minimum"
/// and "<label> maximum".
struct EmberRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    var range: ClosedRange<Double> = 0...1
    var label: String = "Range"
    var minGap: Double = 0.05
    var tone: EmberTone = .accent
    var onPreview: ((Double) -> Void)? = nil
    var onPreviewEnd: (() -> Void)? = nil
    var onInteractionBegin: (() -> UInt64)? = nil
    var isInteractionCurrent: ((UInt64) -> Bool)? = nil

    @State private var drag: EmberRangeDrag?
    @State private var interactionToken: UInt64?
    @State private var interactionGate = SliderInteractionGate()
    @State private var isPreviewing = false
    @State private var hovered: SliderCore.Bound?
    @GestureState private var gestureInProgress = false
    @FocusState private var focused: SliderCore.Bound?
    @State private var showsFocus = false

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Emphasis: Equatable { case rest, hover, pressed, focused }

    var body: some View {
        let fill = palette.sliderFillRGB(tone, accent: accent.rgb(for: palette))
        return GeometryReader { geo in
            let w = geo.size.width
            let midY = EmberRangeFace.height / 2
            let face = EmberRangeFace(lower: lower, upper: upper, range: range, width: w)

            ZStack {
                Capsule()
                    .fill(palette.fillStrong)
                    .frame(width: w, height: EmberRangeFace.trackHeight)
                    .position(x: w / 2, y: midY)
                Rectangle()
                    .fill(fill.color)
                    .frame(width: max(0, face.upperX - face.lowerX), height: EmberRangeFace.trackHeight)
                    .position(x: (face.lowerX + face.upperX) / 2, y: midY)
                // The lower thumb first, so it comes first in the Tab order also when the
                // two lie on one spot.
                thumb(.lower, x: face.lowerX, midY: midY)
                thumb(.upper, x: face.upperX, midY: midY)
            }
            .frame(height: EmberRangeFace.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let near = EmberRangeDrag(start: point, face: face)
                    hovered = near.isOnThumb ? near.bound : nil
                case .ended:
                    hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($gestureInProgress) { _, inProgress, _ in inProgress = true }
                    .onChanged { g in
                        if let drag, drag.start != g.startLocation { finishInteraction() }
                        if drag == nil {
                            if showsFocus { showsFocus = false }
                            interactionToken = onInteractionBegin?()
                            interactionGate = SliderInteractionGate()
                            drag = EmberRangeDrag(start: g.startLocation, face: face)
                        }
                        updateDrag(pointerX: g.location.x, width: w)
                    }
                    .onEnded { g in
                        guard drag?.start == g.startLocation else { return }
                        updateDrag(pointerX: g.location.x, width: w)
                        finishInteraction()
                    }
            )
        }
        .frame(height: EmberRangeFace.height)
        .onChange(of: gestureInProgress) { _, inProgress in
            if !inProgress, drag != nil { finishInteraction() }
        }
        .onChange(of: focused) { _, bound in
            showsFocus = SliderFocus.drawsFocus(
                handleIsFocused: bound != nil, isDragging: drag != nil, event: NSApp?.currentEvent?.type)
        }
        .onDisappear { finishInteraction() }
        .accessibilityRepresentation {
            VStack {
                Slider(value: accessibleValue(.lower), in: range) { Text("\(label) minimum") }
                    .accessibilityLabel("\(label) minimum")
                    .accessibilityValue(SliderCore.spokenPercent(lower))
                Slider(value: accessibleValue(.upper), in: range) { Text("\(label) maximum") }
                    .accessibilityLabel("\(label) maximum")
                    .accessibilityValue(SliderCore.spokenPercent(upper))
            }
        }
    }

    private func value(of bound: SliderCore.Bound) -> Double {
        bound == .lower ? lower : upper
    }

    private func write(_ v: Double, to bound: SliderCore.Bound) {
        switch bound {
        case .lower: lower = v
        case .upper: upper = v
        }
    }

    private func updateDrag(pointerX x: CGFloat, width: CGFloat) {
        guard var current = drag, interactionGate.permitsMutation(
            token: interactionToken, isCurrent: isInteractionCurrent) else { return }
        let proposal = current.proposal(pointerX: x, width: width, range: range,
                                        lower: lower, upper: upper, minGap: minGap)
        if current != drag {
            drag = current
            // The thumb taken is the one the keys move next.
            if current.hasMoved || !current.awaitsDirection, focused != current.bound {
                focused = current.bound
            }
        }
        guard let proposal, proposal.value != value(of: proposal.bound) else { return }
        write(proposal.value, to: proposal.bound)
        isPreviewing = true
        onPreview?(proposal.value)
    }

    /// Controls can disappear while the popover stays (Settings to About). End this
    /// gesture's preview, but never a newer interaction's.
    private func finishInteraction() {
        interactionGate.endPreviewIfCurrent(
            token: interactionToken, isCurrent: isInteractionCurrent,
            isPreviewing: isPreviewing, onPreviewEnd: onPreviewEnd)
        drag = nil
        interactionToken = nil
        interactionGate = SliderInteractionGate()
        isPreviewing = false
    }

    /// A key press or an assistive app's adjustment: one edit with a fresh token, which then
    /// applies at once (`onPreviewEnd` lands Auto in the new range).
    private func discreteEdit(_ proposed: Double, for bound: SliderCore.Bound) {
        let v = SliderCore.editedValue(proposed, for: bound, range: range,
                                       lower: lower, upper: upper, minGap: minGap)
        guard v.isFinite, v != value(of: bound) else { return }
        let token = onInteractionBegin?()
        if let token, isInteractionCurrent?(token) == false { return }
        write(v, to: bound)
        if let token, isInteractionCurrent?(token) == false { return }
        onPreviewEnd?()
    }

    private func accessibleValue(_ bound: SliderCore.Bound) -> Binding<Double> {
        Binding(get: { value(of: bound) }, set: { discreteEdit($0, for: bound) })
    }

    // MARK: - Pieces

    private func emphasis(of bound: SliderCore.Bound) -> Emphasis {
        if showsFocus, focused == bound { return .focused }
        if let drag, drag.bound == bound, !drag.awaitsDirection { return .pressed }
        if drag == nil, hovered == bound { return .hover }
        return .rest
    }

    nonisolated static func thumbDiameter(_ emphasis: Emphasis) -> CGFloat {
        switch emphasis {
        case .rest: EmberRangeFace.thumbDiameter
        case .hover: EmberRangeFace.thumbDiameter + 1
        case .pressed, .focused: EmberRangeFace.thumbDiameter + 2
        }
    }

    /// A thumb in the text colour, the strongest ink on the card both ways the popover is
    /// seen, ringed in the card's own colour so it stands apart from the fill it sits on.
    /// Its Tab stop keeps one size wherever the thumb is and however it is drawn.
    private func thumb(_ bound: SliderCore.Bound, x: CGFloat, midY: CGFloat) -> some View {
        let state = emphasis(of: bound)
        let diameter = Self.thumbDiameter(state)
        return Color.clear
            .frame(width: EmberRangeFace.hitSize, height: EmberRangeFace.hitSize)
            .focusable()
            .focusEffectDisabled()
            .focused($focused, equals: bound)
            .onKeyPress(keys: SliderKeyStep.keys) { press in
                if !showsFocus { showsFocus = true }
                guard let step = SliderKeyStep(press.key) else { return .ignored }
                discreteEdit(step.value(from: value(of: bound), in: range,
                                        large: press.modifiers.contains(.shift)), for: bound)
                return .handled
            }
            .overlay {
                Circle()
                    .fill(palette.text)
                    .overlay(Circle().strokeBorder(palette.card.color, lineWidth: 2))
                    .frame(width: diameter, height: diameter)
                    .emberFocusHalo(Circle(), isFocused: state == .focused, spread: 3)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state)
                    .allowsHitTesting(false)
            }
            .position(x: x, y: midY)
    }
}
