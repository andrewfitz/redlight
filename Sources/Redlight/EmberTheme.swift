import SwiftUI

/// Ember design tokens for the popover.
///
/// Everything keys off `ColorScheme` and `ColorSchemeContrast`, never `AppearanceController`,
/// so previews and the offscreen snapshot tests can force either appearance.
///
/// The Late preset keeps only the red channel and squeezes the bright half of the range
/// into a sliver, so state is always a step in brightness, never a change of hue alone.
/// Dark: a bright accent on a dark panel, with dark marks on the accent. Light: a deeper
/// accent, with every mark, line and action near-black. A colour drawn on top of a fill is
/// chosen by `EmberContrast`, which scores it both as it is normally seen and under Late.

/// An sRGB colour with 0…255 components, kept as numbers so tones can be mixed.
struct EmberRGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    static let black = EmberRGB(0, 0, 0)
    static let white = EmberRGB(255, 255, 255)

    var color: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255) }

    func opacity(_ alpha: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: alpha)
    }

    /// `fraction` of this colour over `other`, 0…1.
    func mixed(_ fraction: Double, over other: EmberRGB) -> EmberRGB {
        let f = min(1, max(0, fraction))
        return EmberRGB(r * f + other.r * (1 - f), g * f + other.g * (1 - f), b * f + other.b * (1 - f))
    }
}

/// Which fill a slider takes.
enum EmberTone: Hashable, Sendable {
    /// The accent itself: the colour temp slider.
    case accent
    /// The accent at a brightness, 0…1: the white point slider. 1 is the accent itself; lower
    /// is dimmer and less vivid, down to `EmberPalette.dimmestFill` at 0.
    case level(Double)
}

/// How well one flat colour reads on another, measured the two ways the popover is seen.
///
/// - `wcag`: the WCAG 2 contrast ratio, for ordinary viewing.
/// - `late`: the same ratio for what is left under the Late preset. Only the red channel
///   reaches the screen, through the preset's white-point curve, and luminance is taken
///   relative to the brightest red that curve can show. A pair of pale colours scores about
///   1 here however different their hues, and so does any pair whose reds are both bright.
///
/// `score` is the worse of the two. A cue has to pass both, so candidates are ranked by it.
enum EmberContrast {
    /// The Late preset's white point. Its colour temp of 0 is what removes green and blue.
    static let lateWhitepoint = 0.3

    private static func linear(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance, 0…1.
    static func luminance(_ color: EmberRGB) -> Double {
        0.2126 * linear(color.r / 255) + 0.7152 * linear(color.g / 255) + 0.0722 * linear(color.b / 255)
    }

    static func wcag(_ a: EmberRGB, _ b: EmberRGB) -> Double {
        ratio(luminance(a), luminance(b))
    }

    /// What the Late preset sends to the screen for a channel value, both 0…1: the curve
    /// `GammaTableComposer` applies to the red channel of an uncalibrated display.
    static func lateOutput(_ base: Double) -> Double {
        let base = min(1, max(0, base))
        let rest = 1 - base
        return base * (lateWhitepoint + (1 - lateWhitepoint) * rest * rest)
    }

    /// The light a colour gives under Late, relative to the most that Late can give.
    static func lateLuminance(_ color: EmberRGB) -> Double {
        linear(lateOutput(color.r / 255)) / linear(lateOutput(1))
    }

    static func late(_ a: EmberRGB, _ b: EmberRGB) -> Double {
        ratio(lateLuminance(a), lateLuminance(b))
    }

    /// The worse of the two ratios.
    static func score(_ a: EmberRGB, _ b: EmberRGB) -> Double {
        min(wcag(a, b), late(a, b))
    }

    private static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The grey with the same luminance as `color`.
    static func grey(matching color: EmberRGB) -> EmberRGB {
        let light = luminance(color)
        let encoded = light <= 0.0031308 ? light * 12.92 : 1.055 * pow(light, 1 / 2.4) - 0.055
        return EmberRGB(encoded * 255, encoded * 255, encoded * 255)
    }

    /// The candidate that scores highest on `fill`; the first of equals.
    static func best(of candidates: [EmberRGB], on fill: EmberRGB) -> EmberRGB {
        var best = candidates.first ?? .black
        var bestScore = score(best, fill)
        for candidate in candidates.dropFirst() {
            let candidateScore = score(candidate, fill)
            if candidateScore > bestScore {
                best = candidate
                bestScore = candidateScore
            }
        }
        return best
    }

    /// A colour to draw on a fill: an ink and how much of it.
    struct Mark: Equatable, Sendable {
        var ink: EmberRGB
        var alpha: Double

        var color: Color { ink.opacity(alpha) }
        /// The flat colour the mark shows as on `fill`.
        func over(_ fill: EmberRGB) -> EmberRGB { ink.mixed(alpha, over: fill) }
    }

    /// The best-scoring candidate on `fill`, at the least strength from `minimumAlpha` up
    /// that scores `target`. Where even the solid ink falls short, the solid ink.
    static func mark(
        on fill: EmberRGB, candidates: [EmberRGB] = [.black, .white],
        minimumAlpha: Double = 1, target: Double
    ) -> Mark {
        let ink = best(of: candidates, on: fill)
        func reaches(_ alpha: Double) -> Bool { score(ink.mixed(alpha, over: fill), fill) >= target }
        var low = min(1, max(0, minimumAlpha))
        if reaches(low) { return Mark(ink: ink, alpha: low) }
        guard reaches(1) else { return Mark(ink: ink, alpha: 1) }
        var high = 1.0
        for _ in 0..<14 {
            let middle = (low + high) / 2
            if reaches(middle) { high = middle } else { low = middle }
        }
        return Mark(ink: ink, alpha: high)
    }

    /// `fill` moved toward `anchor` by the least amount that makes `isEnough` true. The fill
    /// itself when it already is; the anchor when nothing on the way is.
    static func lifted(
        _ fill: EmberRGB, toward anchor: EmberRGB, until isEnough: (EmberRGB) -> Bool
    ) -> EmberRGB {
        if isEnough(fill) { return fill }
        guard isEnough(anchor) else { return anchor }
        var low = 0.0, high = 1.0
        for _ in 0..<14 {
            let middle = (low + high) / 2
            if isEnough(anchor.mixed(middle, over: fill)) { high = middle } else { low = middle }
        }
        return anchor.mixed(high, over: fill)
    }
}

/// The one accent: a flat colour for the colour-temp value on screen right now.
/// 1 = unfiltered (white, in dark), 0 = the Late preset (deep red).
enum EmberTint {
    private static let dark: [(Double, EmberRGB)] = [
        (0, EmberRGB(204, 44, 26)), (0.34, EmberRGB(232, 84, 46)),
        (0.7, EmberRGB(248, 156, 86)), (1, .white),
    ]
    /// Deeper than the dark scale, and with no white: white does not show on the pale panel,
    /// and the accent has to stay darker than it. Its red end is as deep as it can go with a
    /// black mark on it still at 3:1.
    private static let light: [(Double, EmberRGB)] = [
        (0, EmberRGB(166, 52, 32)), (0.34, EmberRGB(176, 74, 34)),
        (0.7, EmberRGB(190, 108, 38)), (1, EmberRGB(196, 146, 48)),
    ]

    /// A pale warm tone: what an action fill moves toward when the live accent is too deep
    /// for its label. Not white, so a lifted red stays an ember red and not a pink.
    static let palest = EmberRGB(255, 226, 180)

    static func rgb(intensity: Double, scheme: ColorScheme) -> EmberRGB {
        let stops = scheme == .dark ? dark : light
        let value = intensity.isFinite ? min(1, max(0, intensity)) : 1
        for index in 1..<stops.count where value <= stops[index].0 {
            let (lowerAt, lower) = stops[index - 1]
            let (upperAt, upper) = stops[index]
            let fraction = (value - lowerAt) / (upperAt - lowerAt)
            return upper.mixed(fraction, over: lower)
        }
        return stops[stops.count - 1].1
    }
}

struct EmberPalette: Equatable, Sendable {
    /// What a colour drawn on a fill is for. Each kind has its own strength.
    enum MarkKind: Sendable {
        /// A slider's value handle at rest.
        case grabber
        /// A handle that is pressed or has keyboard focus, and a switch knob: the solid ink.
        case solid
        /// A quiet mark, visible but softer than the grabber: an off switch's knob.
        case notch
        /// The check on a preset swatch.
        case check
    }

    let isDark: Bool
    /// True for the Increase Contrast setting: stronger text levels, fills and marks.
    let isIncreasedContrast: Bool
    /// The popover surface.
    let background: EmberRGB
    /// Primary text; the quieter levels are alphas of it.
    let textRGB: EmberRGB
    /// The warm tone every neutral fill is an alpha of.
    let wash: EmberRGB
    let secondaryAlpha: Double
    let tertiaryAlpha: Double
    let fillAlpha: Double
    let fillStrongAlpha: Double
    let troughAlpha: Double
    let raisedRGB: EmberRGB
    let raisedAlpha: Double
    let nightAlpha: Double
    /// The white point slider's fill at the bottom of its range, before any lift: how far
    /// the accent moves toward its own grey, and how much of that is left over black (dark)
    /// or over the panel (light).
    let dimMuting: Double
    let dimFraction: Double
    /// Least strength of a grabber and of a notch: the design's own values.
    let grabberAlpha: Double
    let notchAlpha: Double
    /// The score a grabber or check, a notch, and an action label must reach.
    let markTarget: Double
    let notchTarget: Double
    let actionTarget: Double
    /// Width of the focus band.
    let focusBand: CGFloat

    var text: Color { textRGB.color }
    var secondary: Color { textRGB.opacity(secondaryAlpha) }
    var tertiary: Color { textRGB.opacity(tertiaryAlpha) }
    /// Cards, slider tracks and quiet buttons.
    var fill: Color { wash.opacity(fillAlpha) }
    /// The allowed range on a slider, an off switch, and chips that sit on a card.
    var fillStrong: Color { wash.opacity(fillStrongAlpha) }
    /// The segmented control's background.
    var trough: Color { wash.opacity(troughAlpha) }
    /// The selected segment.
    var raised: Color { raisedRGB.opacity(raisedAlpha) }
    /// The part of the sun arc below the horizon.
    var nightArea: Color { wash.opacity(nightAlpha) }
    /// The band drawn around a control that has keyboard focus: the text colour, which is
    /// the strongest thing on the panel both as it is normally seen and under Late.
    var focusRingRGB: EmberRGB { textRGB }
    var focusRing: Color { focusRingRGB.color }

    // MARK: Surfaces as numbers

    /// A card, or a slider track, on the panel.
    var card: EmberRGB { wash.mixed(fillAlpha, over: background) }

    /// `fillStrong` as it shows on a card or on the bare panel.
    func strong(onCard: Bool) -> EmberRGB {
        wash.mixed(fillStrongAlpha, over: onCard ? card : background)
    }

    /// The allowed range of a slider: `fillStrong` on the track.
    var sliderBand: EmberRGB { strong(onCard: true) }

    // MARK: Marks

    private var ink: EmberRGB { EmberRGB(35, 31, 28) }

    /// The ink and strength of a mark of `kind` on `fill`.
    func markSpec(_ kind: MarkKind, on fill: EmberRGB) -> EmberContrast.Mark {
        switch kind {
        case .grabber:
            EmberContrast.mark(on: fill, minimumAlpha: grabberAlpha, target: markTarget)
        case .solid:
            EmberContrast.mark(on: fill, minimumAlpha: 1, target: markTarget)
        case .notch:
            EmberContrast.mark(on: fill, minimumAlpha: notchAlpha, target: notchTarget)
        case .check:
            EmberContrast.mark(on: fill, minimumAlpha: 0.6, target: markTarget)
        }
    }

    func mark(_ kind: MarkKind, on fill: EmberRGB) -> Color { markSpec(kind, on: fill).color }

    /// The check on a preset swatch of colour `fill`.
    func check(on fill: EmberRGB) -> Color { mark(.check, on: fill) }

    // MARK: Accent-derived colours

    /// Fill and label of a committed action as numbers: Resume, Invert when on, Set.
    ///
    /// Dark: the accent, moved toward its pale end where it is too deep for the label to
    /// reach `actionTarget`. Light: near-black with a white label.
    func actionRGB(accent: EmberRGB) -> (background: EmberRGB, foreground: EmberRGB) {
        guard isDark else { return (ink, .white) }
        let fill = EmberContrast.lifted(accent, toward: EmberTint.palest) {
            EmberContrast.score(.black, $0) >= actionTarget
        }
        return (fill, .black)
    }

    func action(accent: EmberRGB) -> (background: Color, foreground: Color) {
        let colors = actionRGB(accent: accent)
        return (colors.background.color, colors.foreground.color)
    }

    func arcLine(accent: EmberRGB) -> Color { isDark ? accent.color : ink.opacity(0.82) }
    func arcDot(accent: EmberRGB) -> Color { isDark ? accent.color : ink.color }
    func arcHalo(accent: EmberRGB) -> Color { accent.opacity(0.3) }
    func dayArea(accent: EmberRGB) -> Color { accent.opacity(isDark ? 0.20 : 0.30) }

    /// A slider fill as a number, so the marks on it can be chosen.
    ///
    /// A level runs in a straight line from `dimmestFill` at 0 to the accent itself at 1, so
    /// every step of the white point slider changes its colour and none changes it twice.
    func sliderFillRGB(_ tone: EmberTone, accent: EmberRGB) -> EmberRGB {
        switch tone {
        case .accent:
            return accent
        case .level(let level):
            return accent.mixed(level.isFinite ? level : 1, over: dimmestFill(accent: accent))
        }
    }

    /// The white point slider's fill at the bottom of its range: the accent with less colour
    /// and less light. White becomes a grey; a red becomes a slightly duller, dimmer red.
    ///
    /// Dark dims toward black. Light has no room to: its accent is already as deep as a mark
    /// on it allows, so there the fill fades toward the panel instead.
    ///
    /// Dark stops dimming where the fill would no longer carry the accent's mark at
    /// `notchTarget` or would come too close to the band under it. At the red end that is
    /// early: under Late only red reaches the screen, and a black mark needs a bright red to
    /// stand on. Light stops fading where the fill would come too close to the band; a mark
    /// only gains from a paler fill.
    func dimmestFill(accent: EmberRGB) -> EmberRGB {
        let muted = EmberContrast.grey(matching: accent).mixed(dimMuting, over: accent)
        let band = sliderBand
        guard isDark else {
            return EmberContrast.lifted(muted.mixed(dimFraction, over: background), toward: muted) {
                EmberContrast.wcag($0, band) >= Self.bandWCAG
            }
        }
        let ink = EmberContrast.best(of: [.black, .white], on: accent)
        return EmberContrast.lifted(muted.mixed(dimFraction, over: .black), toward: muted) { fill in
            EmberContrast.score(ink, fill) >= notchTarget + 0.1
                && EmberContrast.wcag(fill, band) >= Self.bandWCAG
                && EmberContrast.late(fill, band) >= Self.bandLate
        }
    }

    /// How far a slider fill stays from the band under it, as it is normally seen and, in
    /// dark, under Late. Light's fills are the darker of the two, and Late cannot tell them
    /// from the band by lightness however deep they are.
    static let bandWCAG = 1.45
    static let bandLate = 1.6

    // MARK: Palettes

    static func `for`(_ scheme: ColorScheme) -> EmberPalette { scheme == .dark ? dark : light }

    static func `for`(_ scheme: ColorScheme, contrast: ColorSchemeContrast) -> EmberPalette {
        switch (scheme == .dark, contrast == .increased) {
        case (true, false): dark
        case (true, true): darkIncreased
        case (false, false): light
        case (false, true): lightIncreased
        }
    }

    static let dark = makeDark(increased: false)
    static let darkIncreased = makeDark(increased: true)
    static let light = makeLight(increased: false)
    static let lightIncreased = makeLight(increased: true)

    private static func makeDark(increased: Bool) -> EmberPalette {
        EmberPalette(
            isDark: true, isIncreasedContrast: increased, background: EmberRGB(30, 27, 25),
            textRGB: EmberRGB(248, 242, 236), wash: EmberRGB(255, 238, 224),
            secondaryAlpha: increased ? 0.84 : 0.68, tertiaryAlpha: increased ? 0.70 : 0.52,
            // The strong fill gains little here: any brighter and neither a white nor a black
            // mark on it reads both ways.
            fillAlpha: 0.06, fillStrongAlpha: increased ? 0.14 : 0.12, troughAlpha: 0.06,
            raisedRGB: EmberRGB(255, 238, 224), raisedAlpha: increased ? 0.22 : 0.17, nightAlpha: 0.045,
            dimMuting: 0.35, dimFraction: 0.55, grabberAlpha: 0.50, notchAlpha: 0.22,
            markTarget: increased ? 7 : 4.5, notchTarget: increased ? 4.5 : 3,
            actionTarget: increased ? 7 : 4.6, focusBand: increased ? 3.5 : 2.5)
    }

    private static func makeLight(increased: Bool) -> EmberPalette {
        EmberPalette(
            isDark: false, isIncreasedContrast: increased, background: EmberRGB(252, 250, 247),
            textRGB: EmberRGB(35, 31, 28), wash: EmberRGB(70, 45, 20),
            secondaryAlpha: increased ? 0.90 : 0.78, tertiaryAlpha: increased ? 0.80 : 0.64,
            fillAlpha: 0.07, fillStrongAlpha: increased ? 0.20 : 0.13, troughAlpha: increased ? 0.14 : 0.10,
            raisedRGB: .white, raisedAlpha: 1, nightAlpha: 0.06,
            dimMuting: 0.35, dimFraction: 0.60, grabberAlpha: 0.88, notchAlpha: 0.42,
            markTarget: increased ? 7 : 4.5, notchTarget: increased ? 4.5 : 3,
            actionTarget: increased ? 7 : 4.6, focusBand: increased ? 3.5 : 2.5)
    }
}

enum EmberMetrics {
    static let width: CGFloat = 300
    static let padding: CGFloat = 14
    /// Vertical gap between the popover's blocks.
    static let spacing: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let cardInset: CGFloat = 12
    /// One line of a card. A switch's focus band (18 + 2 × 4) and a chip's (20 + 2 × 4)
    /// both stay inside it.
    static let rowHeight: CGFloat = 30
    static let sliderHeight: CGFloat = 24
    static let sliderRadius: CGFloat = 8
    /// The header's pills and round button, and the Settings bar's pills.
    static let controlHeight: CGFloat = 26
    /// One option of a segmented control, inside its 2 pt trough.
    static let segmentHeight: CGFloat = 24
    /// A preset's swatch.
    static let swatchHeight: CGFloat = 34
}

/// The live accent, published once for a whole popover.
///
/// It is a reference that stays the same while the colour temp moves, so a slider tick does
/// not reach every view that could paint with the accent. A view asks for the colour in its
/// own body, on the branch that paints with it. That read is what ties the view to the
/// colour temp: a switch that is off, a quiet chip or a button without its dot never asks,
/// and is not evaluated again on a tick.
@MainActor
final class EmberAccent: Equatable, Sendable {
    /// The colour temp now, 0…1. Reading an observable model here is what a view follows.
    fileprivate var intensity: @MainActor () -> Double

    nonisolated init(intensity: @escaping @MainActor () -> Double) {
        self.intensity = intensity
    }

    /// The accent in the palette's appearance, for the colour temp as it is now.
    func rgb(for palette: EmberPalette) -> EmberRGB {
        EmberTint.rgb(intensity: intensity(), scheme: palette.isDark ? .dark : .light)
    }

    /// The same source is the same value, whatever the colour temp: an environment that is
    /// written again with it has not changed.
    nonisolated static func == (lhs: EmberAccent, rhs: EmberAccent) -> Bool { lhs === rhs }
}

extension EmberPalette {
    /// Fill and label of a committed action for the live accent. Light draws these
    /// near-black whatever the accent is, so there the colour temp is not read.
    @MainActor
    func action(accent: EmberAccent) -> (background: Color, foreground: Color) {
        action(accent: isDark ? accent.rgb(for: self) : .black)
    }

    /// The dot on the Settings button for the live accent; fixed in light, as above.
    @MainActor
    func arcDot(accent: EmberAccent) -> Color {
        arcDot(accent: isDark ? accent.rgb(for: self) : .black)
    }
}

private struct EmberAccentKey: EnvironmentKey {
    /// Outside a scope: the middle of the scale.
    static let defaultValue = EmberAccent(intensity: { 0.7 })
}

extension EnvironmentValues {
    /// Where the current tint comes from. Set by `EmberAccentScope`; ask it for the colour
    /// with `rgb(for:)` only where the colour is painted.
    var emberAccent: EmberAccent {
        get { self[EmberAccentKey.self] }
        set { self[EmberAccentKey.self] = newValue }
    }

    /// The palette for this environment's appearance and its Increase Contrast setting.
    /// Read it with `@Environment(\.emberPalette)`.
    var emberPalette: EmberPalette {
        EmberPalette.for(colorScheme, contrast: colorSchemeContrast)
    }
}

/// Publishes the accent for the live colour-temp value.
///
/// The colour temp is not read here. The scope hands down one `EmberAccent` for its whole
/// life, and each view that paints with the accent reads the value in its own body, so a
/// slider tick evaluates those views and nothing else under the scope.
struct EmberAccentScope<Content: View>: View {
    let intensity: @MainActor () -> Double
    let content: Content
    @State private var accent: EmberAccent

    init(intensity: @escaping @MainActor () -> Double, @ViewBuilder content: () -> Content) {
        self.intensity = intensity
        self.content = content()
        _accent = State(initialValue: EmberAccent(intensity: intensity))
    }

    var body: some View {
        // The one reference, handed the caller's latest closure. No view is told of this:
        // views follow the model the closure reads, so the closure should read one.
        let _ = accent.intensity = intensity
        content.environment(\.emberAccent, accent)
    }
}
