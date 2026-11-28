import AppKit
import SwiftUI

/// Ember controls for the popover: flat fills, no gradients, no outlines at rest.
///
/// Each one is a native `Button` underneath, so it keeps the button trait, keyboard focus
/// (with "Keyboard navigation" on in System Settings, as for native controls) and Space
/// activation. Return also activates, focus shows as a flat band around the control, and
/// a disabled control dims. Hit areas are at least 24 pt tall even where the shape is smaller.
///
/// Assistive apps get the native control each one stands for: a switch and the Invert chip
/// are toggles, the segmented control is one picker, and a control whose title is drawn here
/// is named by that title unless its caller names it.

// MARK: - Tokens local to the layout

extension Font {
    /// The rounded system face at a mock size.
    static func ember(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

private struct EmberAnimationsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct EmberIsLeavingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for the controls of a pane that is sliding out (`EmberPager`). They take no
    /// keyboard focus and do nothing, and they look exactly as they did: a control reads
    /// this itself and keeps the keyboard off, instead of the pane being disabled, which
    /// would fade the controls that fade when disabled and could not be told apart from
    /// one that really is.
    var emberIsLeaving: Bool {
        get { self[EmberIsLeavingKey.self] }
        set { self[EmberIsLeavingKey.self] = newValue }
    }

    /// False stops the switch and segment animations, so an offscreen render never
    /// captures one halfway. Reduce Motion stops them as well.
    var emberAnimationsEnabled: Bool {
        get { self[EmberAnimationsEnabledKey.self] }
        set { self[EmberAnimationsEnabledKey.self] = newValue }
    }
}

enum EmberMotion {
    /// The mode switch: the selected segment, the pane sliding under it and the popover's
    /// height all move on this one curve, so they start and arrive together.
    ///
    /// A curve with an end, not a spring: the pane that has slid out is taken away when
    /// the curve ends, and a spring's last, invisible part runs on after that.
    static let modeSwitch: Animation = .timingCurve(0.2, 0.9, 0.25, 1, duration: modeSwitchDuration)
    /// The same curve for Core Animation, which slides the pager's pictures.
    @MainActor static var modeSwitchTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    }

    /// How far along the curve the motion is at `time`, 0 to 1 of its duration: for the
    /// popover's height, moved by hand once a frame alongside the pictures.
    nonisolated static func modeSwitchProgress(_ time: Double) -> Double {
        UnitBezier(x1: 0.2, y1: 0.9, x2: 0.25, y2: 1).value(at: min(1, max(0, time)))
    }
    static let modeSwitchDuration: TimeInterval = 0.32

    /// Something unfolding or folding in place: Per-App, the pause lengths, a rule's amounts.
    /// The mode switch's curve, a little quicker. A curve with an end for the same reason:
    /// the popover's height follows it frame by frame (`PopoverSlideHost.disclose`).
    static let disclosure: Animation = .timingCurve(0.2, 0.9, 0.25, 1, duration: disclosureDuration)
    static let disclosureDuration: TimeInterval = 0.28
    /// A control or a colour that changes in place, where nothing moves around it.
    static let quick: Animation = .easeOut(duration: 0.16)
}

/// Unfolds or folds part of the popover: `disclose { isExpanded.toggle() }`. The change
/// animates on `EmberMotion.disclosure` and the popover's height follows on the same curve.
/// With Reduce Motion, or animations off for an offscreen render, the change is made at once.
struct EmberDisclose {
    var host: PopoverSlideHost?
    var animates: Bool

    @MainActor func callAsFunction(_ change: () -> Void) {
        guard animates else { change(); return }
        if let host {
            host.disclose(change)
        } else {
            withAnimation(EmberMotion.disclosure) { change() }
        }
    }
}

extension EnvironmentValues {
    var emberDisclose: EmberDisclose {
        EmberDisclose(host: popoverSlideHost, animates: emberAnimationsEnabled && !accessibilityReduceMotion)
    }

    /// Whether this view's changes should move: animations on and Reduce Motion off.
    var emberMoves: Bool { emberAnimationsEnabled && !accessibilityReduceMotion }
}

extension AnyTransition {
    /// What `EmberDisclose` brings in: uncovered from its top down as the space for it opens,
    /// and covered from the bottom up as it closes, on the disclosure's own curve. What moves
    /// past it moves by exactly the part shown, so it never draws over a card around it.
    static var emberReveal: AnyTransition {
        .modifier(active: EmberRevealMask(shown: 0), identity: EmberRevealMask(shown: 1))
            .combined(with: .opacity)
    }

    /// A small control coming and going in place, such as Reset.
    static var emberPop: AnyTransition { .opacity.combined(with: .scale(scale: 0.6)) }
}

/// Shows the top `shown` of a view, through `EmberRevealShape`, which animates.
struct EmberRevealMask: ViewModifier {
    var shown: Double

    func body(content: Content) -> some View {
        content.mask { EmberRevealShape(shown: shown) }
    }
}

/// The view's rectangle down to `shown` of its height. It reaches past the view's edges by
/// a focus band's width, so a control's focus band is never cut off at rest.
struct EmberRevealShape: Shape {
    var shown: Double

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    static let margin: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let part = min(1, max(0, shown))
        let m = Self.margin
        // The bottom margin comes in only at the end, so it never shows a sliver early.
        let height = rect.height * part + (part >= 1 ? 2 * m : m)
        return Path(CGRect(x: rect.minX - m, y: rect.minY - m, width: rect.width + 2 * m, height: height))
    }
}

extension View {
    /// The transition for a part that `EmberDisclose` shows and hides. None where nothing
    /// moves, so an offscreen render never catches it fading.
    func emberRevealTransition() -> some View { modifier(EmberTransitionModifier(transition: .emberReveal)) }

    /// `AnyTransition.emberPop`, or none where nothing moves.
    func emberPopTransition() -> some View { modifier(EmberTransitionModifier(transition: .emberPop)) }
}

private struct EmberTransitionModifier: ViewModifier {
    let transition: AnyTransition
    @Environment(\.emberAnimationsEnabled) private var animates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(animates && !reduceMotion ? transition : .identity)
    }
}

extension View {
    /// Keeps the layout at the visible height while the hit area is at least `minimum` tall.
    func emberMinimumHit(visible height: CGFloat, minimum: CGFloat = 24) -> some View {
        let extra = max(0, minimum - height) / 2
        return padding(.vertical, extra).contentShape(Rectangle()).padding(.vertical, -extra)
    }

    /// The focus state: a flat band in the text colour whose outer edge is `shape` grown by
    /// `spread`. The gap inside it keeps the band apart from a control of its own colour; with
    /// a `spread` of 0 the band lies just inside the shape, for a region with no room around
    /// it. Nothing is drawn behind the control, so its label reads as it does unfocused.
    ///
    /// `color` overrides the band's colour. Leave it out: `EmberPalette.focusRing` is the one
    /// chosen to show on the panel, on a card and under the Late preset.
    func emberFocusHalo<S: Shape>(
        _ shape: S, isFocused: Bool, color: Color? = nil, spread: CGFloat = 4
    ) -> some View {
        modifier(EmberFocusBand(isFocused: isFocused, color: color, spread: spread) { rect, _ in
            shape.path(in: rect)
        })
    }

    /// A capsule's band has circular ends: a continuous curve that tight has a notch in it.
    func emberFocusHalo(
        _ shape: Capsule, isFocused: Bool, color: Color? = nil, spread: CGFloat = 4
    ) -> some View {
        modifier(EmberFocusBand(isFocused: isFocused, color: color, spread: spread) { rect, _ in
            Capsule(style: .circular).path(in: rect)
        })
    }

    /// A rounded rectangle's band follows its corners at the band's own distance, and turns
    /// circular where that makes it a capsule.
    func emberFocusHalo(
        _ shape: RoundedRectangle, isFocused: Bool, color: Color? = nil, spread: CGFloat = 4
    ) -> some View {
        modifier(EmberFocusBand(isFocused: isFocused, color: color, spread: spread) { rect, outset in
            let radius = max(0, shape.cornerSize.width + outset)
            let isCapsule = radius >= min(rect.width, rect.height) / 2 - 0.01
            return RoundedRectangle(cornerRadius: radius, style: isCapsule ? .circular : shape.style)
                .path(in: rect)
        })
    }
}

private struct EmberFocusBand: ViewModifier {
    let isFocused: Bool
    let color: Color?
    let spread: CGFloat
    /// The band's centre line: the control's shape in its frame grown by the second argument.
    let outline: @Sendable (CGRect, CGFloat) -> Path

    @Environment(\.emberPalette) private var palette

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                let band = palette.focusBand
                EmberBandOutline(outline: outline, outset: spread - band / 2)
                    .stroke(color ?? palette.focusRing, style: StrokeStyle(lineWidth: band, lineJoin: .round))
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct EmberBandOutline: Shape {
    let outline: @Sendable (CGRect, CGFloat) -> Path
    let outset: CGFloat

    func path(in rect: CGRect) -> Path {
        outline(rect.insetBy(dx: -outset, dy: -outset), outset)
    }
}

// MARK: - Button base

struct EmberControlState {
    var isPressed = false
    var isFocused = false
    var isEnabled = true
}

/// The base of every Ember control. `label` draws the control from its live state and sets
/// its own content shape, which is how a small control gets a hit area larger than it looks.
struct EmberButton<Label: View>: View {
    /// What assistive apps call the button when its caller gives it no accessibility label:
    /// the title that `label` draws.
    var title: String? = nil
    let action: () -> Void
    @ViewBuilder let label: (EmberControlState) -> Label

    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.emberIsLeaving) private var isLeaving

    var body: some View {
        Button(action: action) { EmptyView() }
            // The look follows the state outside; `disabled` below is only the keyboard.
            .buttonStyle(EmberButtonBody(isFocused: isFocused, isEnabled: isEnabled, label: label))
            .disabled(isLeaving)
            .focused($isFocused)
            .focusEffectDisabled()
            // On the press only: a held Return would otherwise repeat the action, flipping a
            // switch on and off for as long as the key is down.
            .onKeyPress(.return, phases: .down) { _ in
                action()
                return .handled
            }
            .modifier(EmberDefaultName(title: title))
    }
}

/// Names a control by its drawn title. It sits innermost, so a caller's own
/// `accessibilityLabel` on the control replaces it.
private struct EmberDefaultName: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content.accessibilityLabel(title)
        } else {
            content
        }
    }
}

private struct EmberButtonBody<Label: View>: ButtonStyle {
    let isFocused: Bool
    let isEnabled: Bool
    let label: (EmberControlState) -> Label

    func makeBody(configuration: Configuration) -> some View {
        label(EmberControlState(isPressed: configuration.isPressed, isFocused: isFocused, isEnabled: isEnabled))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

// MARK: - Switch

/// A switch, 30 × 18 by default. The label is not drawn: rows show their own text. Assistive apps get a
/// native toggle with an on/off value; the explicit style on it is what stops it from
/// taking this style again.
///
/// The toggle that stands in has no label view. With one, the label is read out as an
/// element of its own beside the switch; hidden, it still sizes the element, which then no
/// longer matches the switch on screen. So the name is the accessibility label set on the
/// styled toggle, as `EmberSwitch` does: use that, not this style on its own.
struct EmberSwitchStyle: ToggleStyle {
    var height: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        EmberButton { configuration.isOn.toggle() } label: { state in
            EmberSwitchBody(isOn: configuration.isOn, isFocused: state.isFocused, height: height)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .toggleStyle(.switch)
        }
    }
}

private struct EmberSwitchBody: View {
    let isOn: Bool
    let isFocused: Bool
    let height: CGFloat

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.emberAnimationsEnabled) private var animates

    var body: some View {
        // Only a switch that is on shows the accent, so only then does it follow the colour temp.
        let track = isOn ? accent.rgb(for: palette) : nil
        // On or off, the knob is whichever of black and white reads on its track: the track
        // alone is too close to the card behind it to say that this is a switch.
        let knob = EmberSwitchFace.knob(isOn: isOn, accent: track ?? .black, palette: palette)
        Capsule()
            .fill(track?.color ?? palette.fillStrong)
            .overlay {
                // A switch on at 100% is nearly the card's colour in light.
                if let track, let edge = palette.edge(for: track, on: palette.card) {
                    Capsule().strokeBorder(edge, lineWidth: 1)
                }
            }
            .frame(width: height * 5 / 3, height: height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(knob.color)
                    .frame(width: height - 4, height: height - 4)
                    .shadow(color: .black.opacity(!isOn && knob.ink == .white ? 0.22 : 0), radius: 1, y: 1)
                    .padding(2)
            }
            .animation(reduceMotion || !animates ? nil : .easeOut(duration: 0.12), value: isOn)
            .emberFocusHalo(Capsule(), isFocused: isFocused)
            .emberMinimumHit(visible: height)
    }
}

/// The colours of a switch as numbers, so their contrast can be tested.
enum EmberSwitchFace {
    /// The track as it shows on a card: the accent when on, `fillStrong` when off. The
    /// header's switch sits on the bare panel, where the off track is a shade darker; the
    /// knob chosen for the card reads there too.
    static func track(isOn: Bool, accent: EmberRGB, palette: EmberPalette) -> EmberRGB {
        isOn ? accent : palette.strong(onCard: true)
    }

    /// On: the solid ink that reads on the accent. Off: an ink on the quiet track, a step
    /// softer than the on knob where the track allows it.
    static func knob(isOn: Bool, accent: EmberRGB, palette: EmberPalette) -> EmberContrast.Mark {
        palette.markSpec(isOn ? .solid : .notch, on: track(isOn: isOn, accent: accent, palette: palette))
    }
}

/// A labelled switch: `label` is what VoiceOver reads; the row draws its own text.
struct EmberSwitch: View {
    let label: String
    @Binding var isOn: Bool

    let height: CGFloat

    init(_ label: String, height: CGFloat = 18, isOn: Binding<Bool>) {
        self.height = height
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(EmberSwitchStyle(height: height))
            .accessibilityLabel(label)
    }
}

// MARK: - Chips

/// A 20 pt chip: quiet on a card, or the committed-action fill.
struct EmberChipLabel: View {
    let title: String
    var isProminent = false
    var isFocused = false
    var height: CGFloat = 20
    /// Nil is a capsule.
    var cornerRadius: CGFloat? = nil
    /// The quiet fill: `fillStrong` on a card, `fill` on the bare panel.
    var onCard = true
    /// Space between the title and each end of the chip.
    var horizontalPadding: CGFloat = 8

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent

    var body: some View {
        // A quiet chip has nothing of the accent in it and does not follow the colour temp.
        let action = isProminent ? palette.action(accent: accent) : nil
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? height / 2, style: .continuous)
        Text(title)
            .font(.ember(11.5, isProminent ? .semibold : .regular))
            .foregroundStyle(action?.foreground ?? palette.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(shape.fill(action?.background ?? (onCard ? palette.fillStrong : palette.fill)))
            .emberFocusHalo(shape, isFocused: isFocused)
            .emberMinimumHit(visible: height)
    }
}

/// The Invert chip: a toggle drawn as a chip that fills when on. Assistive apps get a
/// native checkbox named by the title, or by the caller's accessibility label.
struct EmberChipToggle: View {
    let title: String
    @Binding var isOn: Bool
    var horizontalPadding: CGFloat = 8

    var body: some View {
        EmberButton { isOn.toggle() } label: { state in
            EmberChipLabel(title: title, isProminent: isOn, isFocused: state.isFocused,
                           horizontalPadding: horizontalPadding)
        }
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn).toggleStyle(.checkbox)
        }
    }
}

/// A small action drawn as a chip: Reset, Set, the pause lengths.
struct EmberChipButton: View {
    let title: String
    var isProminent = false
    var height: CGFloat = 20
    var cornerRadius: CGFloat? = nil
    var onCard = true
    let action: () -> Void

    var body: some View {
        EmberButton(title: title, action: action) { state in
            EmberChipLabel(title: title, isProminent: isProminent, isFocused: state.isFocused,
                           height: height, cornerRadius: cornerRadius, onCard: onCard)
        }
    }
}

// MARK: - Segmented control

struct EmberSegmented<Value: Hashable>: View {
    /// What VoiceOver calls the group.
    let label: String
    let options: [(value: Value, title: String)]
    let selection: Value
    /// On a card the trough takes the stronger fill.
    var onCard = false
    /// Switch-sized, for a choice at the end of a card row: as tall as an `EmberSwitch`.
    var compact = false
    /// Optional selected-label color for a state that needs a subtle visual cue.
    var selectedForeground: Color? = nil
    /// The tooltip, and the help assistive apps give for each option.
    var help: String? = nil
    /// How the selected segment travels to a new option.
    var motion: EmberSegmentMotion = .quick
    let select: (Value) -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.emberAnimationsEnabled) private var animates

    /// A compact control's segments: with the frame around them, as tall as a switch.
    static var compactHeight: CGFloat { 14 }
    private var innerRadius: CGFloat { compact ? 6 : 8 }

    var body: some View {
        let selected = options.firstIndex { $0.value == selection } ?? 0
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let isSelected = index == selected
                EmberButton(title: options[index].title) {
                    if !isSelected { select(options[index].value) }
                } label: { state in
                    Text(options[index].title)
                        .font(.ember(compact ? 11.5 : 12.5, isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? (selectedForeground ?? palette.text) : palette.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? Self.compactHeight : EmberMetrics.segmentHeight)
                        .contentShape(Rectangle())
                        .emberFocusHalo(RoundedRectangle(cornerRadius: innerRadius, style: .continuous),
                                        isFocused: state.isFocused, spread: 0)
                }
            }
        }
        // Drawn and moved by Core Animation: a SwiftUI animation, however small, has SwiftUI
        // draw the whole popover again on every frame it runs.
        .background {
            SegmentHighlight(index: selected, count: options.count, palette: palette, onCard: onCard,
                             cornerRadius: innerRadius,
                             motion: reduceMotion || !animates ? nil : motion)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: innerRadius + 2, style: .continuous)
            .fill(onCard ? palette.fillStrong : palette.trough))
        .modifier(EmberTooltip(text: help))
        // One picker with a selected value, not a row of unrelated buttons. Its label is
        // hidden so that it names the picker without being read as an element of its own.
        // The help goes on the options: on the picker itself SwiftUI would give it as the
        // role description, in place of "tab group".
        .accessibilityRepresentation {
            if options.indices.contains(selected) {
                Picker(label, selection: Binding(
                    get: { options[selected].value },
                    set: { if $0 != options[selected].value { select($0) } }
                )) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].title)
                            .accessibilityHint(help ?? "")
                            .tag(options[index].value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityValue(options[selected].title)
            }
        }
    }
}

/// A tooltip for the pointer only. What assistive apps are told is set on the control's
/// accessibility representation, which replaces anything set on the drawn view.
private struct EmberTooltip: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

// MARK: - Cards and rows

struct EmberCard<Content: View>: View {
    var verticalPadding: CGFloat = 2
    @ViewBuilder let content: Content

    @Environment(\.emberPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, EmberMetrics.cardInset)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: EmberMetrics.cardRadius, style: .continuous)
                .fill(palette.fill))
    }
}

/// The hairline between two rows of a card. It takes no height, so every row keeps its own.
private struct EmberRowDivider: ViewModifier {
    let isShown: Bool
    @Environment(\.emberPalette) private var palette

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if isShown { Rectangle().fill(palette.fill).frame(height: 1) }
        }
    }
}

/// One line of a card, `EmberMetrics.rowHeight` tall.
struct EmberRow<Content: View>: View {
    /// True on every row but a card's first.
    var divider = false
    /// Space between the row's pieces.
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
            .frame(height: EmberMetrics.rowHeight)
            .modifier(EmberRowDivider(isShown: divider))
    }
}

/// A card line that is one button: Location, Keyboard shortcuts, Apps.
struct EmberRowButton<Content: View>: View {
    var divider = false
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        EmberButton(action: action) { state in
            HStack(spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: EmberMetrics.rowHeight)
                .contentShape(Rectangle())
                .background {
                    // The band runs inside the row's own height and a little into the card's
                    // inset, clear of the row's text.
                    Color.clear
                        .emberFocusHalo(RoundedRectangle(cornerRadius: 8, style: .continuous),
                                        isFocused: state.isFocused, spread: 0)
                        .padding(.horizontal, -8)
                        .padding(.vertical, 3)
                }
        }
        .modifier(EmberRowDivider(isShown: divider))
    }
}

/// The small chevron at the end of a row or a split control.
struct EmberChevron: View {
    enum Direction: String {
        case right = "chevron.right", left = "chevron.left", down = "chevron.down", up = "chevron.up"
    }

    let direction: Direction
    var size: CGFloat = 9

    var body: some View {
        // Up is down turned over, so a disclosure turns the one glyph instead of swapping it.
        let turned = direction == .up
        Image(systemName: turned ? Direction.down.rawValue : direction.rawValue)
            .font(.system(size: size, weight: .semibold))
            .rotationEffect(.degrees(turned ? 180 : 0))
            .accessibilityHidden(true)
    }
}

// MARK: - Pill and icon buttons

/// The pill, `EmberMetrics.controlHeight` tall: Open Settings, About, Quit.
struct EmberPillButton: View {
    let title: String
    var systemImage: String? = nil
    /// The committed-action fill, as on Resume.
    var isProminent = false
    let action: () -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent

    var body: some View {
        // Read here, in the button's own body, and only for the fill that is made of it.
        let colors = isProminent ? palette.action(accent: accent) : nil
        EmberButton(title: title, action: action) { state in
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title).lineLimit(1).fixedSize()
            }
            .font(.ember(12.5, isProminent ? .semibold : .medium))
            .foregroundStyle(colors?.foreground ?? palette.text)
            .padding(.horizontal, 11)
            .frame(height: EmberMetrics.controlHeight)
            .background(Capsule().fill(colors?.background ?? palette.fill))
            .contentShape(Capsule())
            .emberFocusHalo(Capsule(), isFocused: state.isFocused)
        }
    }
}

/// The round button of the header, `EmberMetrics.controlHeight` across, with an optional dot.
struct EmberIconButton: View {
    let systemImage: String
    var showsDot = false
    /// The circle's diameter. Under 24 pt the hit area is still 24 pt tall.
    var size: CGFloat = EmberMetrics.controlHeight
    var symbolSize: CGFloat = 12.5
    /// A quiet button draws its glyph in the secondary text colour: Reset beside a value.
    var isQuiet = false
    let action: () -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent

    var body: some View {
        // Read here, in the button's own body, and only when there is a dot to colour.
        let dot = showsDot ? palette.arcDot(accent: accent) : nil
        EmberButton(action: action) { state in
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: isQuiet ? .semibold : .medium))
                .foregroundStyle(isQuiet ? palette.secondary : palette.text)
                .frame(width: size, height: size)
                .background(Circle().fill(palette.fill))
                .overlay(alignment: .topTrailing) {
                    if let dot {
                        Circle().fill(dot).frame(width: 7, height: 7)
                    }
                }
                .contentShape(Circle())
                .emberFocusHalo(Circle(), isFocused: state.isFocused)
                .emberMinimumHit(visible: size)
        }
    }
}

/// A text-only action: Back, Save to a preset…, Cancel, the repository link.
struct EmberLinkButton<Label: View>: View {
    /// The drawn title when the label is more than plain text: the button's default name
    /// for assistive apps.
    var title: String? = nil
    let action: () -> Void
    @ViewBuilder let label: Label

    @Environment(\.emberPalette) private var palette

    var body: some View {
        EmberButton(title: title, action: action) { state in
            label
                .font(.ember(12))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .emberFocusHalo(RoundedRectangle(cornerRadius: 6, style: .continuous),
                                isFocused: state.isFocused, spread: 6)
                .emberMinimumHit(visible: 16)
        }
    }
}

extension EmberLinkButton where Label == Text {
    init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, action: action) { Text(title) }
    }
}

// MARK: - Fields

/// A 24 pt text field on a card. Focus shows as the focus band just inside the field, a
/// brighter fill and the caret.
struct EmberTextField: View {
    let placeholder: String
    @Binding var text: String

    @FocusState private var isFocused: Bool
    @Environment(\.emberPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.emberIsLeaving) private var isLeaving

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        TextField(placeholder, text: $text)
            .disabled(isLeaving)
            .textFieldStyle(.plain)
            .font(.ember(12).monospacedDigit())
            .foregroundStyle(palette.text)
            .focused($isFocused)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(shape.fill(isFocused ? palette.raised : palette.fillStrong))
            .emberFocusHalo(shape, isFocused: isFocused, spread: 0)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The native hour-and-minute field without its bezel, so it sits in an Ember chip. It
/// keeps the system's editing: digits, arrow keys and the locale's 12- or 24-hour form.
struct EmberTimeField: NSViewRepresentable {
    @Binding var date: Date
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = EmberDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = [.hourMinute]
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.focusRingType = .none
        let base = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        picker.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 12) } ?? base
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        // The cell is the element assistive apps see.
        picker.setAccessibilityLabel(label)
        picker.cell?.setAccessibilityLabel(label)
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        let coordinator = context.coordinator
        coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
        // Each of these redraws the field when set, changed or not, and this runs whenever
        // the row around the field is evaluated.
        let text = context.environment.emberPalette.textRGB
        if coordinator.text != text {
            coordinator.text = text
            picker.textColor = NSColor(text.color)
        }
        let isEnabled = context.environment.isEnabled
        if picker.isEnabled != isEnabled { picker.isEnabled = isEnabled }
        let isLeaving = context.environment.emberIsLeaving
        if picker.refusesFirstResponder != isLeaving { picker.refusesFirstResponder = isLeaving }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSDatePicker, context: Context) -> CGSize? {
        // The size does not depend on the time shown, so it is not measured on every update.
        // It does depend on the window's scale: the first measure comes before there is one.
        let scale = nsView.window?.backingScaleFactor
        if let measured = context.coordinator.measured, measured.scale == scale { return measured.size }
        let size = nsView.fittingSize
        context.coordinator.measured = (scale, size)
        return size
    }

    @MainActor
    final class Coordinator: NSObject {
        var date: Binding<Date>
        /// The text colour the field has been given.
        var text: EmberRGB?
        /// The field's size, and the window scale it was measured at.
        var measured: (scale: CGFloat?, size: CGSize)?

        init(date: Binding<Date>) { self.date = date }

        @objc func changed(_ sender: NSDatePicker) {
            date.wrappedValue = sender.dateValue
        }
    }
}

// MARK: - Text pieces

/// The small caption over a settings card.
struct EmberGroupLabel: View {
    let title: String
    @Environment(\.emberPalette) private var palette

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.ember(11, .semibold))
            .foregroundStyle(palette.tertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A failure the user has to see: brighter than the hints, and never by hue alone.
struct EmberErrorText: View {
    let message: String
    /// The command error sits in its own box; a field error sits under its field.
    var isBoxed = false

    @Environment(\.emberPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(message)
                .font(.ember(isBoxed ? 12 : 11, .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isBoxed ? 10 : 0)
        .padding(.vertical, isBoxed ? 8 : 0)
        .background {
            if isBoxed {
                RoundedRectangle(cornerRadius: EmberMetrics.sliderRadius, style: .continuous)
                    .fill(palette.fillStrong)
            }
        }
    }
}

private struct EmberTitleFocus: ViewModifier {
    let focus: (binding: AccessibilityFocusState<MenuBarPage?>.Binding, page: MenuBarPage)?

    func body(content: Content) -> some View {
        if let focus {
            content.accessibilityFocused(focus.binding, equals: focus.page)
        } else {
            content
        }
    }
}

/// Back on the left, the title centred: the header of a pushed page.
struct EmberPageHeader: View {
    static let backTitle = "Back"

    let title: String
    /// Where Back goes, read after the button's name when it says more than "Back". The
    /// name itself is always the visible word, so it is spoken and found as it is seen.
    var backLabel = EmberPageHeader.backTitle
    /// Sends VoiceOver to the title when the page is shown. On the title alone, so that it
    /// lands there and not on whichever of Back and the title comes first.
    var titleFocus: (binding: AccessibilityFocusState<MenuBarPage?>.Binding, page: MenuBarPage)? = nil
    let back: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.ember(14, .semibold))
                .tracking(-0.14)
                .accessibilityAddTraits(.isHeader)
                .modifier(EmberTitleFocus(focus: titleFocus))
            HStack(spacing: 0) {
                EmberLinkButton(title: Self.backTitle, action: back) {
                    HStack(spacing: 3) {
                        EmberChevron(direction: .left)
                        Text(Self.backTitle)
                    }
                }
                .accessibilityHint(backLabel == Self.backTitle ? "" : backLabel)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 20)
    }
}

/// A date picker that a pane out of play keeps from the keyboard altogether. On its own,
/// `refusesFirstResponder` only stops a click from giving it the keyboard: Tab still visits it.
final class EmberDatePicker: NSDatePicker {
    override var canBecomeKeyView: Bool { !refusesFirstResponder && super.canBecomeKeyView }
    override var acceptsFirstResponder: Bool { !refusesFirstResponder && super.acceptsFirstResponder }
}

/// A cubic timing curve from (0, 0) to (1, 1) through two control points, as CSS and Core
/// Animation define it: the progress at a moment, found by solving for the moment's x.
struct UnitBezier {
    let x1: Double, y1: Double, x2: Double, y2: Double

    func value(at x: Double) -> Double {
        sample(y1, y2, at: solve(x))
    }

    private func sample(_ p1: Double, _ p2: Double, at t: Double) -> Double {
        let c = 3 * p1, b = 3 * (p2 - p1) - c, a = 1 - c - b
        return ((a * t + b) * t + c) * t
    }

    private func slope(at t: Double) -> Double {
        let c = 3 * x1, b = 3 * (x2 - x1) - c, a = 1 - c - b
        return (3 * a * t + 2 * b) * t + c
    }

    private func solve(_ x: Double) -> Double {
        // Newton's method, then halving where the slope is too flat for it.
        var t = x
        for _ in 0..<8 {
            let error = sample(x1, x2, at: t) - x
            if abs(error) < 1e-7 { return t }
            let d = slope(at: t)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        var low = 0.0, high = 1.0
        t = x
        while low < high {
            let value = sample(x1, x2, at: t)
            if abs(value - x) < 1e-7 { return t }
            if x > value { low = t } else { high = t }
            t = (high - low) / 2 + low
            if high - low < 1e-9 { break }
        }
        return t
    }
}

/// How a segmented control's selected segment travels: for Core Animation.
struct EmberSegmentMotion: Equatable {
    let duration: TimeInterval
    /// The control points of the timing curve.
    let curve: [Float]

    static let quick = EmberSegmentMotion(duration: 0.15, curve: [0, 0, 0.58, 1])
    /// With the panes under the mode control, on `EmberMotion.modeSwitch`'s curve.
    static let modeSwitch = EmberSegmentMotion(duration: EmberMotion.modeSwitchDuration, curve: [0.2, 0.9, 0.25, 1])

    @MainActor var timing: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: curve[0], curve[1], curve[2], curve[3])
    }
}

/// The selected segment's raised face, a layer that slides between the options.
private struct SegmentHighlight: NSViewRepresentable {
    let index: Int
    let count: Int
    let palette: EmberPalette
    let onCard: Bool
    var cornerRadius: CGFloat = 8
    /// Nil moves it at once.
    let motion: EmberSegmentMotion?

    func makeNSView(context: Context) -> HighlightView { HighlightView() }

    func updateNSView(_ view: HighlightView, context: Context) {
        let shadow = palette.isDark ? EmberRGB(0, 0, 0) : EmberRGB(70, 45, 20)
        // Opaque, as SwiftUI blended it over the trough: Core Animation blends a translucent
        // layer over another differently, and the face came out darker.
        let trough = onCard
            ? palette.wash.mixed(palette.fillStrongAlpha, over: palette.card)
            : palette.wash.mixed(palette.troughAlpha, over: palette.background)
        view.radius = cornerRadius
        view.update(index: index, count: count,
                    fill: palette.raisedRGB.mixed(palette.raisedAlpha, over: trough).cgColor(),
                    shadow: shadow.cgColor(alpha: palette.isDark ? 0.25 : 0.16),
                    shadowRadius: palette.isDark ? 1 : 1.5, motion: motion)
    }

    final class HighlightView: NSView {
        private let face = CALayer()
        var radius: CGFloat = 8 {
            didSet { face.cornerRadius = radius; needsLayout = true }
        }
        private var index = 0
        private var count = 1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            face.cornerRadius = 8
            face.cornerCurve = .continuous
            face.shadowOpacity = 1
            face.shadowOffset = CGSize(width: 0, height: -1)
            layer?.addSublayer(face)
        }

        /// Never unarchived.
        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            face.frame = slot(index)
            face.shadowPath = CGPath(roundedRect: face.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            CATransaction.commit()
        }

        func update(index: Int, count: Int, fill: CGColor, shadow: CGColor, shadowRadius: CGFloat,
                    motion: EmberSegmentMotion?) {
            let moved = index != self.index && count == self.count
            self.index = index
            self.count = max(1, count)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            face.backgroundColor = fill
            face.shadowColor = shadow
            face.shadowRadius = shadowRadius
            let from = face.presentation()?.position ?? face.position
            face.frame = slot(index)
            CATransaction.commit()
            guard moved, let motion, window != nil else { return }
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: from)
            move.toValue = NSValue(point: face.position)
            move.duration = motion.duration
            move.timingFunction = motion.timing
            face.add(move, forKey: "position")
        }

        private func slot(_ index: Int) -> CGRect {
            let width = bounds.width / CGFloat(count)
            return CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
    }
}
