import AppKit
import SwiftUI

/// Where Auto's two limit flags sit under a slider at one width. UI-free, so the placement
/// and the hit rules are testable.
///
/// Each flag is a small rounded chip with its percent, and a tip above it that points up at
/// the limit's exact place on the track: `EmberSliderFace.x`, the mapping the value uses.
/// Chips stay at least `minGap` apart centre to centre (they slide apart evenly, the tips stay
/// where they are) and inside the row at both ends. A pinned band (both limits on one value)
/// has one chip, "Fixed N%".
struct EmberFlagFace: Equatable {
    struct Chip: Equatable {
        /// The limit the chip sets; nil for a pinned band's one chip, which sets either.
        var bound: SliderCore.Bound?
        var text: String
        /// The limit's place on the track: where the tip points.
        var tipX: CGFloat
        var centerX: CGFloat
        var width: CGFloat

        /// The chip itself, in the row's coordinates.
        var frame: CGRect {
            CGRect(x: centerX - width / 2, y: EmberFlagFace.tipSize.height,
                   width: width, height: EmberFlagFace.chipHeight)
        }

        /// Where a press takes the flag: the row's whole height, and at least `hitWidth`
        /// across, around the chip.
        var hitRect: CGRect {
            let w = max(width, EmberFlagFace.hitWidth)
            return CGRect(x: centerX - w / 2, y: 0, width: w, height: EmberFlagFace.rowHeight)
        }
    }

    static let rowHeight: CGFloat = 26
    /// Space between the pill and the row.
    static let spacing: CGFloat = 3
    static let tipSize = CGSize(width: 10, height: 6)
    static let chipHeight: CGFloat = 16
    static let chipRadius: CGFloat = 7
    static let chipPadding: CGFloat = 6
    static let fontSize: CGFloat = 11
    /// Least distance between the two chips' centres.
    static let minGap: CGFloat = 46
    static let hitWidth: CGFloat = 28

    let chips: [Chip]

    init(lower: Double, upper: Double, range: ClosedRange<Double>, width: CGFloat,
         textWidth: (String) -> CGFloat = EmberFlagFace.textWidth) {
        func chipWidth(_ text: String) -> CGFloat { ceil(textWidth(text)) + 2 * Self.chipPadding }
        let lo = min(lower, upper), hi = max(lower, upper)
        let loX = EmberSliderFace.x(for: lo, width: width, range: range)
        let hiX = EmberSliderFace.x(for: hi, width: width, range: range)
        if lo == hi {
            let text = Self.pinnedText(lo)
            let w = chipWidth(text)
            chips = [Chip(bound: nil, text: text, tipX: loX,
                          centerX: Self.clamp(loX, half: w / 2, row: width), width: w)]
            return
        }
        let loText = SliderCore.percentText(lo), hiText = SliderCore.percentText(hi)
        let wl = chipWidth(loText), wu = chipWidth(hiText)
        let gap = max(Self.minGap, (wl + wu) / 2 + 6)
        var a = loX, b = hiX
        if b - a < gap {
            let mid = (a + b) / 2
            a = mid - gap / 2
            b = mid + gap / 2
        }
        a = max(a, wl / 2)
        b = min(b, width - wu / 2)
        // Pushed back in at an end: the other chip makes room.
        if b - a < gap {
            if a <= wl / 2 { b = a + gap } else { a = b - gap }
        }
        chips = [Chip(bound: .lower, text: loText, tipX: loX, centerX: a, width: wl),
                 Chip(bound: .upper, text: hiText, tipX: hiX, centerX: b, width: wu)]
    }

    static func pinnedText(_ value: Double) -> String { "Fixed \(SliderCore.percentText(value))" }

    /// The chip whose hit area holds `point`, the nearer one where both do.
    func chip(at point: CGPoint) -> Chip? {
        chips.filter { $0.hitRect.contains(point) }
            .min { abs($0.centerX - point.x) < abs($1.centerX - point.x) }
    }

    private static func clamp(_ x: CGFloat, half: CGFloat, row: CGFloat) -> CGFloat {
        min(max(x, half), max(half, row - half))
    }

    /// The width of a chip's label as drawn: the rounded system face at `fontSize`, semibold
    /// (the weight of a dragged chip, so a chip keeps its size when it lights up), with
    /// tabular digits.
    static func textWidth(_ text: String) -> CGFloat {
        let base = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? base
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// One press on a flag, from mouse-down to mouse-up.
///
/// The flag moves with the pointer from where it was taken: its tip keeps its distance from
/// the pointer, so nothing jumps on the press. Every value goes through
/// `SliderCore.editedValue`, so the limits keep `minGap` apart, and the ends snap as the
/// value does. A pinned band's chip is taken by the direction of the first movement: left
/// the lower limit, right the upper one.
struct EmberFlagDrag: Equatable {
    let start: CGPoint
    private(set) var bound: SliderCore.Bound
    /// The tip's x minus the pointer's.
    let offset: CGFloat
    private(set) var hasMoved = false
    /// A press on a pinned band's chip that has not moved yet.
    private(set) var awaitsDirection: Bool

    init(start: CGPoint, chip: EmberFlagFace.Chip) {
        self.start = start
        bound = chip.bound ?? .lower
        offset = chip.tipX - start.x
        awaitsDirection = chip.bound == nil
    }

    /// The limit to move and its new value for the pointer at `x`; nil while nothing moves.
    mutating func proposal(
        pointerX x: CGFloat, width: CGFloat, range: ClosedRange<Double>,
        lower: Double, upper: Double, minGap: Double
    ) -> (bound: SliderCore.Bound, value: Double)? {
        if !hasMoved {
            let dx = x - start.x
            guard dx != 0 else { return nil }
            if awaitsDirection {
                bound = SliderCore.resolveStackedMarker(bound, dx: dx, lower: lower, upper: upper)
                awaitsDirection = false
            }
            hasMoved = true
        }
        let proposed = EmberSliderFace.value(atX: x + offset, width: width, range: range)
        return (bound, SliderCore.editedValue(
            proposed, for: bound, range: range, lower: lower, upper: upper, minGap: minGap))
    }
}

/// The flag row under a slider in Auto: Auto's minimum and maximum (`EmberFlagFace`).
///
/// A flag is taken only here, never from the pill above. While one is dragged it lights up
/// (the text colour, with the panel's colour for its label), `onPreview` gets its value so the
/// caller can show that limit on the displays, and `onPreviewEnd` comes on release. A drag is
/// abandoned once its interaction token is stale. Keyboard: each limit is a Tab stop and
/// takes the keys of `SliderKeyStep`; focus is drawn only when it arrived by keyboard.
struct EmberSliderFlags: View {
    let lower: Double
    let upper: Double
    let range: ClosedRange<Double>
    let width: CGFloat
    var minGap: Double = 0.05
    let onLimitChange: (SliderCore.Bound, Double) -> Void
    var onPreview: ((Double) -> Void)? = nil
    var onPreviewEnd: (() -> Void)? = nil
    var onInteractionBegin: (() -> UInt64)? = nil
    var isInteractionCurrent: ((UInt64) -> Bool)? = nil

    @State private var drag: EmberFlagDrag?
    @State private var interactionToken: UInt64?
    @State private var interactionGate = SliderInteractionGate()
    @State private var isPreviewing = false
    @GestureState private var gestureInProgress = false
    @FocusState private var focused: SliderCore.Bound?
    @State private var showsFocus = false

    @Environment(\.emberPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let face = EmberFlagFace(lower: lower, upper: upper, range: range, width: width)
        ZStack(alignment: .topLeading) {
            // The keyboard's stops, one per limit, a fixed size around each chip so the Tab
            // order stays put. A pinned band's chip carries both.
            ForEach([SliderCore.Bound.lower, .upper], id: \.self) { bound in
                let chip = face.chips.first { $0.bound == bound || $0.bound == nil } ?? face.chips[0]
                Color.clear
                    .frame(width: EmberFlagFace.hitWidth, height: EmberFlagFace.rowHeight - 6)
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
                    .position(x: chip.centerX, y: EmberFlagFace.rowHeight / 2)
            }
            ForEach(face.chips, id: \.bound) { chip in
                flag(chip)
            }
        }
        .frame(width: width, height: EmberFlagFace.rowHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($gestureInProgress) { _, inProgress, _ in inProgress = true }
                .onChanged { g in
                    if let drag, drag.start != g.startLocation { finishInteraction() }
                    if drag == nil {
                        // Only a press on a flag takes one; elsewhere the row does nothing.
                        guard let chip = face.chip(at: g.startLocation) else { return }
                        if showsFocus { showsFocus = false }
                        interactionToken = onInteractionBegin?()
                        interactionGate = SliderInteractionGate()
                        drag = EmberFlagDrag(start: g.startLocation, chip: chip)
                    }
                    updateDrag(pointerX: g.location.x)
                }
                .onEnded { g in
                    guard drag?.start == g.startLocation else { return }
                    updateDrag(pointerX: g.location.x)
                    finishInteraction()
                }
        )
        .onChange(of: gestureInProgress) { _, inProgress in
            if !inProgress, drag != nil { finishInteraction() }
        }
        .onChange(of: focused) { _, bound in
            showsFocus = SliderFocus.drawsFocus(
                handleIsFocused: bound != nil, isDragging: drag != nil, event: NSApp?.currentEvent?.type)
        }
        .onDisappear { finishInteraction() }
    }

    private func value(of bound: SliderCore.Bound) -> Double {
        bound == .lower ? lower : upper
    }

    private func updateDrag(pointerX x: CGFloat) {
        guard var current = drag, interactionGate.permitsMutation(
            token: interactionToken, isCurrent: isInteractionCurrent) else { return }
        let proposal = current.proposal(pointerX: x, width: width, range: range,
                                        lower: lower, upper: upper, minGap: minGap)
        if current != drag {
            drag = current
            // The limit taken is the one the keys move next.
            if !current.awaitsDirection, focused != current.bound { focused = current.bound }
        }
        guard let proposal, proposal.value != value(of: proposal.bound) else { return }
        onLimitChange(proposal.bound, proposal.value)
        isPreviewing = true
        onPreview?(proposal.value)
    }

    /// The popover can drop the row while it stays open (Auto turned off from the CLI). End
    /// this gesture's preview, but never a newer interaction's.
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
    func discreteEdit(_ proposed: Double, for bound: SliderCore.Bound) {
        Self.discreteEdit(proposed, for: bound, range: range, lower: lower, upper: upper, minGap: minGap,
                          onLimitChange: onLimitChange, onPreviewEnd: onPreviewEnd,
                          onInteractionBegin: onInteractionBegin, isInteractionCurrent: isInteractionCurrent)
    }

    nonisolated static func discreteEdit(
        _ proposed: Double, for bound: SliderCore.Bound, range: ClosedRange<Double>,
        lower: Double, upper: Double, minGap: Double,
        onLimitChange: (SliderCore.Bound, Double) -> Void, onPreviewEnd: (() -> Void)?,
        onInteractionBegin: (() -> UInt64)?, isInteractionCurrent: ((UInt64) -> Bool)?
    ) {
        let v = SliderCore.editedValue(proposed, for: bound, range: range,
                                       lower: lower, upper: upper, minGap: minGap)
        guard v.isFinite, v != (bound == .lower ? lower : upper) else { return }
        let token = onInteractionBegin?()
        if let token, isInteractionCurrent?(token) == false { return }
        onLimitChange(bound, v)
        if let token, isInteractionCurrent?(token) == false { return }
        onPreviewEnd?()
    }

    // MARK: - Pieces

    private func isActive(_ chip: EmberFlagFace.Chip) -> Bool {
        guard let drag else { return false }
        // A pinned band's one chip lights up as soon as it is taken.
        if chip.bound == nil { return true }
        return !drag.awaitsDirection && chip.bound == drag.bound
    }

    private func isFocusShown(_ chip: EmberFlagFace.Chip) -> Bool {
        guard showsFocus, let focused else { return false }
        return chip.bound == nil || chip.bound == focused
    }

    /// A chip and its tip, drawn as one bubble. Lit while dragged: the text colour, its label
    /// in the panel's colour.
    private func flag(_ chip: EmberFlagFace.Chip) -> some View {
        let active = isActive(chip)
        let fill = active ? palette.text : palette.fillStrong
        let shape = RoundedRectangle(cornerRadius: EmberFlagFace.chipRadius, style: .continuous)
        let corners = FlagBubble.topCorners(chip: chip.frame, tipX: chip.tipX)
        return ZStack(alignment: .topLeading) {
            FlagBubble(chip: chip.frame, tipX: chip.tipX, leading: corners.leading, trailing: corners.trailing)
                .fill(fill)
                // Only the corners animate: the tip follows the pointer exactly, and the corner
                // it reaches eases square so the two join, like bubbles meeting.
                .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.2), value: corners)
            Text(chip.text)
                .font(.ember(EmberFlagFace.fontSize, active ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(active ? palette.background.color : palette.secondary)
                .frame(width: chip.width, height: EmberFlagFace.chipHeight)
                .emberFocusHalo(shape, isFocused: isFocusShown(chip), spread: 3)
                .position(x: chip.centerX, y: chip.frame.midY)
        }
        .allowsHitTesting(false)
    }
}

/// A flag's chip and tip as one shape. The tip points at its limit wherever that is. When the
/// limit nears an end of the chip, as it does at the ends of the scale where the chip is held
/// inside the row, the chip's top corner on that side squares off so the tip runs straight
/// into the chip's side and the two stay one piece. A tip beyond the chip's edge, as when two
/// close flags are pushed apart, leans out from the corner.
struct FlagBubble: Shape {
    struct Corners: Equatable {
        var leading: CGFloat
        var trailing: CGFloat
    }

    let chip: CGRect
    let tipX: CGFloat
    var leading: CGFloat
    var trailing: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(leading, trailing) }
        set { leading = newValue.first; trailing = newValue.second }
    }

    private static let radius = EmberFlagFace.chipRadius
    private static let half = EmberFlagFace.tipSize.width / 2
    private static let tipHeight = EmberFlagFace.tipSize.height

    /// The top corners' radii for a tip at `tipX`: full while the tip's base clears the
    /// corner, shrinking to square as the base reaches the chip's side.
    static func topCorners(chip: CGRect, tipX: CGFloat) -> Corners {
        func corner(_ room: CGFloat) -> CGFloat { min(radius, max(0, room - half)) }
        return Corners(leading: corner(tipX - chip.minX), trailing: corner(chip.maxX - tipX))
    }

    func path(in rect: CGRect) -> Path {
        let r = Self.radius, top = chip.minY, bottom = chip.maxY
        let left = chip.minX, right = chip.maxX
        let apexX = tipX
        // The tip's base sits on the chip's top edge, between the two top corners.
        let baseLeft = min(max(apexX - Self.half, left + leading), right - trailing)
        let baseRight = max(min(apexX + Self.half, right - trailing), left + leading)
        var path = Path()
        path.move(to: CGPoint(x: left, y: bottom - r))
        path.addLine(to: CGPoint(x: left, y: top + leading))
        if leading > 0 {
            path.addQuadCurve(to: CGPoint(x: left + leading, y: top), control: CGPoint(x: left, y: top))
        }
        path.addLine(to: CGPoint(x: baseLeft, y: top))
        path.addLine(to: CGPoint(x: apexX, y: top - Self.tipHeight))
        path.addLine(to: CGPoint(x: baseRight, y: top))
        path.addLine(to: CGPoint(x: right - trailing, y: top))
        if trailing > 0 {
            path.addQuadCurve(to: CGPoint(x: right, y: top + trailing), control: CGPoint(x: right, y: top))
        }
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
        path.closeSubpath()
        return path
    }
}
