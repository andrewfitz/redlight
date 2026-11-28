import AppKit
import SwiftUI

/// Where Auto's two limit flags sit under a slider at one width. UI-free, so the placement
/// and the hit rules are testable.
///
/// Each flag is a small rounded chip with its percent, and a tail above it that points up at
/// the limit's place on the track: `EmberSliderFace.x`, the mapping the value uses. Chips
/// stay at least `minGap` apart centre to centre (they slide apart evenly) and inside the row
/// at both ends. A chip moved off its limit that way keeps its tail on the side nearest the
/// limit (`FlagBubble`): it points toward the limit, no longer at its exact place. A pinned
/// band (both limits on one value) has one chip, "Fixed N%".
struct EmberFlagFace: Equatable {
    struct Chip: Equatable {
        /// The limit the chip sets; nil for a pinned band's one chip, which sets either.
        var bound: SliderCore.Bound?
        var text: String
        /// The limit's place on the track: where the tail points, or the side it leans to.
        var tipX: CGFloat
        var centerX: CGFloat
        var width: CGFloat

        /// The chip itself, in the row's coordinates.
        var frame: CGRect {
            CGRect(x: centerX - width / 2, y: EmberFlagFace.tipSize.height,
                   width: width, height: EmberFlagFace.chipHeight)
        }

        /// Where a press takes the flag: the row's whole height and `hitSlop` under it, and
        /// at least `hitWidth` across, around the chip.
        var hitRect: CGRect {
            let w = max(width, EmberFlagFace.hitWidth)
            return CGRect(x: centerX - w / 2, y: 0, width: w,
                          height: EmberFlagFace.rowHeight + EmberFlagFace.hitSlop)
        }
    }

    /// The tip and the chip, with nothing under them: the next block's gap follows.
    static let rowHeight: CGFloat = tipSize.height + chipHeight
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
    /// How far under the row a press still takes a flag, into the gap before the next block:
    /// with it a flag's hit area is 24 pt tall.
    static let hitSlop: CGFloat = 2

    let chips: [Chip]

    init(lower: Double, upper: Double, range: ClosedRange<Double>, width: CGFloat,
         unit: SliderUnit = .percent,
         textWidth: (String) -> CGFloat = EmberFlagFace.textWidth) {
        func chipWidth(_ text: String) -> CGFloat { ceil(textWidth(text)) + 2 * Self.chipPadding }
        let lo = min(lower, upper), hi = max(lower, upper)
        let loX = EmberSliderFace.x(for: lo, width: width, range: range)
        let hiX = EmberSliderFace.x(for: hi, width: width, range: range)
        if lo == hi {
            let text = Self.pinnedText(lo, in: range, unit: unit)
            let w = chipWidth(text)
            chips = [Chip(bound: nil, text: text, tipX: loX,
                          centerX: Self.clamp(loX, half: w / 2, row: width), width: w)]
            return
        }
        let loText = unit.text(lo, in: range), hiText = unit.text(hi, in: range)
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

    static func pinnedText(_ value: Double, in range: ClosedRange<Double> = 0...1, unit: SliderUnit = .percent) -> String {
        "Fixed \(unit.text(value, in: range))"
    }

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
/// The flag moves with the pointer from where it was taken, once the pointer has travelled
/// `SliderCore.liveTravel`: its limit keeps its distance from the pointer, so nothing jumps
/// on the press and a click changes nothing. Every value goes through
/// `SliderCore.editedValue`: the limits stay `minGap` apart until the flag is taken more
/// than halfway across that gap, and then they are on one value, one flag. An end of the
/// range snaps as the value's does when the flag is moved toward it.
///
/// While the limits share one value the flag is both of them, at the press and again after
/// a merge in mid-drag. The side of that value the handle is on picks the limit that leaves
/// it: left the lower limit, right the upper one, and on an end of the range the only limit
/// that can. So a flag dragged through the other merges with it and then carries the other
/// one on, and the limit left behind stays where they met.
struct EmberFlagDrag: Equatable {
    let start: CGPoint
    private(set) var bound: SliderCore.Bound
    /// The tip's x minus the pointer's.
    let offset: CGFloat
    private(set) var hasMoved = false
    /// A press on a pinned band's chip that has not yet taken a limit off the pin.
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
        let dx = x - start.x
        if !hasMoved {
            guard abs(dx) >= SliderCore.liveTravel else { return nil }
            hasMoved = true
        }
        let handleX = x + offset
        if lower == upper {
            let pinX = EmberSliderFace.x(for: lower, width: width, range: range)
            bound = SliderCore.resolveStackedMarker(bound, dx: handleX - pinX, lower: lower, upper: upper,
                                                    range: range, minGap: minGap)
        }
        // A limit that stood near an end and is taken away from it is not pulled back there.
        let proposed = EmberSliderFace.value(atX: handleX, width: width, range: range,
                                             snapsLower: dx < 0, snapsUpper: dx > 0)
        let value = SliderCore.editedValue(
            proposed, for: bound, range: range, lower: lower, upper: upper, minGap: minGap)
        if awaitsDirection, value != (bound == .lower ? lower : upper) { awaitsDirection = false }
        return (bound, value)
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
    /// Nil: 5 % of the slider's range, as the slider counts percent.
    var minGap: Double? = nil
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
    @Environment(\.emberIsLeaving) private var isLeaving
    @Environment(\.emberSliderUnit) private var unit

    var body: some View {
        let face = EmberFlagFace(lower: lower, upper: upper, range: range, width: width, unit: unit)
        ZStack(alignment: .topLeading) {
            // The keyboard's stops, one per limit, a fixed size around each chip so the Tab
            // order stays put. A pinned band's chip carries both.
            ForEach([SliderCore.Bound.lower, .upper], id: \.self) { bound in
                let chip = face.chips.first { $0.bound == bound || $0.bound == nil } ?? face.chips[0]
                Color.clear
                    .frame(width: EmberFlagFace.hitWidth, height: EmberFlagFace.chipHeight)
                    .focusable(!isLeaving)
                    .focusEffectDisabled()
                    .focused($focused, equals: bound)
                    .onKeyPress(keys: SliderKeyStep.keys) { press in
                        if !showsFocus { showsFocus = true }
                        guard let step = SliderKeyStep(press.key) else { return .ignored }
                        let proposed = step.value(from: value(of: bound), in: range,
                                                  large: press.modifiers.contains(.shift))
                        // From either stop of a pinned band the key's direction picks the limit.
                        let target = SliderCore.keyBound(bound, proposed: proposed, lower: lower, upper: upper)
                        // The limit that moved is the one the next key moves.
                        if discreteEdit(proposed, for: target), target != bound { focused = target }
                        return .handled
                    }
                    .position(x: chip.centerX, y: chip.frame.midY)
            }
            // Always two flags, so that they can slide into one and out again: on a pinned
            // band both are the same chip in the same place, and the maximum's is not drawn.
            let isPinned = face.chips.count == 1
            ForEach([SliderCore.Bound.lower, .upper], id: \.self) { bound in
                let chip = face.chips.first { $0.bound == bound || $0.bound == nil } ?? face.chips[0]
                EmberFlag(chip: chip, isActive: isActive(chip), isFocusShown: isFocusShown(chip),
                          isPinned: isPinned, isDrawn: !isPinned || bound == .lower)
                    // The flag that stays is on top: the other goes in under it as it fades.
                    .zIndex(bound == .lower ? 1 : 0)
            }
        }
        .frame(width: width, height: EmberFlagFace.rowHeight, alignment: .topLeading)
        // The hit area reaches a little under the row; the layout keeps the row's height.
        .padding(.bottom, EmberFlagFace.hitSlop)
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
                        // The displays show the limit from the press on, before it moves:
                        // pressing a flag is asking what its limit looks like.
                        if interactionGate.permitsMutation(token: interactionToken, isCurrent: isInteractionCurrent) {
                            isPreviewing = true
                            onPreview?(value(of: chip.bound ?? .lower))
                        }
                    }
                    updateDrag(pointerX: g.location.x)
                }
                .onEnded { g in
                    guard drag?.start == g.startLocation else { return }
                    updateDrag(pointerX: g.location.x)
                    finishInteraction()
                }
        )
        .padding(.bottom, -EmberFlagFace.hitSlop)
        .onChange(of: gestureInProgress) { _, inProgress in
            if !inProgress, drag != nil { finishInteraction() }
        }
        .onChange(of: focused) { _, bound in
            showsFocus = SliderFocus.drawsFocus(
                handleIsFocused: bound != nil, isDragging: drag != nil, event: NSApp?.currentEvent?.type)
        }
        .onDisappear { finishInteraction() }
    }

    private var gap: Double { minGap ?? SliderCore.limitGap(in: range) }

    private func value(of bound: SliderCore.Bound) -> Double {
        bound == .lower ? lower : upper
    }

    private func updateDrag(pointerX x: CGFloat) {
        guard var current = drag, interactionGate.permitsMutation(
            token: interactionToken, isCurrent: isInteractionCurrent) else { return }
        let proposal = current.proposal(pointerX: x, width: width, range: range,
                                        lower: lower, upper: upper, minGap: gap)
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
    @discardableResult
    func discreteEdit(_ proposed: Double, for bound: SliderCore.Bound) -> Bool {
        Self.discreteEdit(proposed, for: bound, range: range, lower: lower, upper: upper, minGap: gap,
                          onLimitChange: onLimitChange, onPreviewEnd: onPreviewEnd,
                          onInteractionBegin: onInteractionBegin, isInteractionCurrent: isInteractionCurrent)
    }

    /// `isStep` is true for a key: a step that the gap would hold goes on across it
    /// (`SliderCore.steppedValue`). An assistive app names the value it wants, and gets the
    /// place that value would be dragged to, the same however often it asks. True when the
    /// limit was written.
    @discardableResult
    nonisolated static func discreteEdit(
        _ proposed: Double, for bound: SliderCore.Bound, range: ClosedRange<Double>,
        lower: Double, upper: Double, minGap: Double, isStep: Bool = true,
        onLimitChange: (SliderCore.Bound, Double) -> Void, onPreviewEnd: (() -> Void)?,
        onInteractionBegin: (() -> UInt64)?, isInteractionCurrent: ((UInt64) -> Bool)?
    ) -> Bool {
        // Before the clamp, which would turn a value that is not a number into an end.
        guard proposed.isFinite else { return false }
        let v = isStep
            ? SliderCore.steppedValue(proposed, for: bound, range: range, lower: lower, upper: upper, minGap: minGap)
            : SliderCore.editedValue(proposed, for: bound, range: range, lower: lower, upper: upper, minGap: minGap)
        guard v != (bound == .lower ? lower : upper) else { return false }
        let token = onInteractionBegin?()
        if let token, isInteractionCurrent?(token) == false { return false }
        onLimitChange(bound, v)
        if let token, isInteractionCurrent?(token) == false { return true }
        onPreviewEnd?()
        return true
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
}

/// One flag: a chip and its tail, drawn as one bubble. Lit while dragged: the text colour, its
/// label in the panel's colour.
///
/// The flag follows its limit exactly. Only two things animate: the tail's change of shape,
/// and the merge. When the band becomes pinned or stops being so, the flag slides and grows
/// from where it was to where it is now, its label fades into the new one, and the flag that
/// is no longer drawn fades out under the other: two flags close into one, one opens into two.
private struct EmberFlag: View {
    let chip: EmberFlagFace.Chip
    let isActive: Bool
    let isFocusShown: Bool
    let isPinned: Bool
    /// False for the maximum's flag on a pinned band, which lies under the minimum's.
    let isDrawn: Bool

    @Environment(\.emberPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.emberAnimationsEnabled) private var animates

    var body: some View {
        // The flat colour `fillStrong` shows as on the panel, so that two flags crossing as
        // they merge do not darken where they overlap.
        let fill = isActive ? palette.text : palette.strong(onCard: false).color
        let shape = RoundedRectangle(cornerRadius: EmberFlagFace.chipRadius, style: .continuous)
        // The bubble is drawn in the flag's own frame, which is what moves and grows.
        let tip = chip.tipX - chip.frame.minX
        let hooks = FlagBubble.hooks(
            chip: CGRect(x: 0, y: EmberFlagFace.tipSize.height, width: chip.width, height: EmberFlagFace.chipHeight),
            tipX: tip)
        let moves = !reduceMotion && animates
        ZStack(alignment: .top) {
            FlagBubble(tipX: tip, leading: hooks.leading, trailing: hooks.trailing)
                .fill(fill)
                // An arrow tail follows its limit exactly; only its change of shape animates, as
                // it turns into a chat-bubble tail at the chip's side and back.
                .animation(moves ? .spring(duration: 0.26, bounce: 0.18) : nil, value: hooks)
            Text(chip.text)
                .font(.ember(EmberFlagFace.fontSize, isActive ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.opacity)
                .foregroundStyle(isActive ? palette.background.color : palette.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: EmberFlagFace.chipHeight)
                .emberFocusHalo(shape, isFocused: isFocusShown, spread: 3)
                .padding(.top, EmberFlagFace.tipSize.height)
        }
        .frame(width: chip.width, height: EmberFlagFace.rowHeight)
        .offset(x: chip.frame.minX)
        .opacity(isDrawn ? 1 : 0)
        .animation(moves ? .spring(duration: 0.32, bounce: 0.22) : nil, value: isPinned)
        .allowsHitTesting(false)
    }
}

/// A flag's chip and tail as one shape.
///
/// Away from the chip's sides the tail is a small arrow with soft flanks and a rounded point,
/// centred on its limit. When the limit nears a side of the chip, as it does at the ends of the
/// scale where the chip is held inside the row, or when two close flags are pushed apart, the
/// tail turns into a chat-bubble tail on that side: the chip's corner squares off, the side runs
/// straight up into the tail's point, and the inner edge sweeps back down to the chip's top in
/// one concave curve. `leading` and `trailing` say how far the tail has turned on each side,
/// 0 to 1, so the change can animate.
struct FlagBubble: Shape {
    struct Hooks: Equatable {
        var leading: CGFloat
        var trailing: CGFloat
    }

    /// The chip in the shape's coordinates. Nil: the shape's own rectangle below the tail,
    /// so that a flag whose frame is animated grows and moves with it.
    var chip: CGRect? = nil
    /// The limit's place, in the same coordinates as the chip.
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
    /// How far along the chip's top a chat-bubble tail's inner edge reaches.
    private static let hookReach: CGFloat = 11
    /// How far back from the point the rounding starts.
    private static let tipRounding: CGFloat = 1.6

    /// Where the tail is a chat-bubble tail: on the side the limit is close to, if either.
    static func hooks(chip: CGRect, tipX: CGFloat) -> Hooks {
        let roomLeading = tipX - chip.minX, roomTrailing = chip.maxX - tipX
        guard min(roomLeading, roomTrailing) < radius + half else { return Hooks(leading: 0, trailing: 0) }
        return roomLeading <= roomTrailing ? Hooks(leading: 1, trailing: 0) : Hooks(leading: 0, trailing: 1)
    }

    private struct Tail {
        var footL: CGFloat, footR: CGFloat, apexX: CGFloat
        var controlL: CGPoint, controlR: CGPoint

        func mixed(_ other: Tail, _ t: CGFloat) -> Tail {
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
            func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: mix(a.x, b.x), y: mix(a.y, b.y)) }
            return Tail(footL: mix(footL, other.footL), footR: mix(footR, other.footR),
                        apexX: mix(apexX, other.apexX),
                        controlL: mix(controlL, other.controlL), controlR: mix(controlR, other.controlR))
        }
    }

    func path(in rect: CGRect) -> Path {
        let chip = self.chip ?? CGRect(x: rect.minX, y: rect.minY + Self.tipHeight,
                                       width: rect.width, height: EmberFlagFace.chipHeight)
        let r = Self.radius, h = Self.tipHeight, top = chip.minY, bottom = chip.maxY
        let left = chip.minX, right = chip.maxX
        let tl = min(1, max(0, leading)), tr = min(1, max(0, trailing))

        // The arrow, centred on the limit and clear of the corners.
        let apex0 = min(max(tipX, left + r + Self.half), right - r - Self.half)
        let footL0 = apex0 - Self.half, footR0 = apex0 + Self.half
        var tail = Tail(footL: footL0, footR: footR0, apexX: apex0,
                        controlL: CGPoint(x: footL0 + (apex0 - footL0) * 0.55, y: top),
                        controlR: CGPoint(x: footR0 - (footR0 - apex0) * 0.55, y: top))
        // A chat-bubble tail on either side. Both are mixed in: while the tail changes sides
        // one is still leaving as the other arrives, and dropping either would make it jump.
        if tl > 0 {
            tail = tail.mixed(Tail(footL: left, footR: left + Self.hookReach, apexX: left + 0.5,
                                   controlL: CGPoint(x: left, y: top - h * 0.55),
                                   controlR: CGPoint(x: left + 3.2, y: top - 0.2)), tl)
        }
        if tr > 0 {
            tail = tail.mixed(Tail(footL: right - Self.hookReach, footR: right, apexX: right - 0.5,
                                   controlL: CGPoint(x: right - 3.2, y: top - 0.2),
                                   controlR: CGPoint(x: right, y: top - h * 0.55)), tr)
        }
        let leadR = r * (1 - tl), trailR = r * (1 - tr)
        let apex = CGPoint(x: tail.apexX, y: top - h)
        func towardApex(_ point: CGPoint) -> CGPoint {
            let dx = point.x - apex.x, dy = point.y - apex.y
            let length = max(0.001, (dx * dx + dy * dy).squareRoot())
            let step = min(Self.tipRounding, length / 2)
            return CGPoint(x: apex.x + dx / length * step, y: apex.y + dy / length * step)
        }

        var path = Path()
        path.move(to: CGPoint(x: left, y: bottom - r))
        path.addLine(to: CGPoint(x: left, y: top + leadR))
        if leadR > 0.01 {
            path.addQuadCurve(to: CGPoint(x: left + leadR, y: top), control: CGPoint(x: left, y: top))
        }
        path.addLine(to: CGPoint(x: max(tail.footL, left + leadR), y: top))
        path.addQuadCurve(to: towardApex(tail.controlL), control: tail.controlL)
        path.addQuadCurve(to: towardApex(tail.controlR), control: apex)
        path.addQuadCurve(to: CGPoint(x: min(tail.footR, right - trailR), y: top), control: tail.controlR)
        path.addLine(to: CGPoint(x: right - trailR, y: top))
        if trailR > 0.01 {
            path.addQuadCurve(to: CGPoint(x: right, y: top + trailR), control: CGPoint(x: right, y: top))
        }
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
        path.closeSubpath()
        return path
    }
}
