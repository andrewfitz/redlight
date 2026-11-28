import SwiftUI

/// The curve, the sun dot and the horizon share one linear solar-elevation scale.
/// `guides` places lines at true elevations and omits crowded ones rather than shifting
/// them; the chart draws only the horizon.
struct SunArcGeometry {
    struct Guide: Equatable {
        let elevation: Double
        let y: CGFloat
        var isHorizon: Bool { elevation == 0 }
    }

    let top: CGFloat
    let bottom: CGFloat
    let upperElevation: Double
    let lowerElevation: Double

    init(elevations: some Sequence<Double>, height: CGFloat, padding: CGFloat = 6) {
        let height = max(0, height)
        top = min(max(0, padding), height / 2)
        bottom = height - top
        var highest = -Double.infinity, lowest = Double.infinity
        for elevation in elevations where elevation.isFinite {
            highest = max(highest, elevation)
            lowest = min(lowest, elevation)
        }
        upperElevation = max(highest.isFinite ? highest : 10, 5) + 3
        lowerElevation = min(lowest, -18) - 3
    }

    func y(for elevation: Double) -> CGFloat {
        let span = max(1, upperElevation - lowerElevation)
        return top + CGFloat((upperElevation - elevation) / span) * (bottom - top)
    }

    func guides(
        elevations: [Double] = SolarCurve.elevationMarkers.map(\.elevation),
        minimumSeparation: CGFloat = 4
    ) -> [Guide] {
        // Always consider the horizon first, then the nearest physical anchors. Sorting
        // by elevation breaks equally distant ties deterministically.
        let candidates = Set([0] + elevations.filter(\.isFinite)).sorted {
            abs($0) == abs($1) ? $0 > $1 : abs($0) < abs($1)
        }
        var result: [Guide] = []
        for elevation in candidates {
            let guideY = y(for: elevation)
            guard guideY >= top, guideY <= bottom,
                  result.allSatisfy({ abs($0.y - guideY) >= max(0, minimumSeparation) })
            else { continue }
            result.append(Guide(elevation: elevation, y: guideY))
        }
        return result.sorted { $0.y < $1.y }
    }
}

/// Flat sun-arc chart: the day's elevation curve (x = local time, y = sun elevation) over one
/// horizon line. The area between curve and horizon is tinted where the sun is up and
/// shaded where it is down. The large dot is the sun right now; a small dot, a hairline and
/// a moon mark the Adaptive bedtime when one is set. The sunrise and sunset clock times
/// hang under the points where the curve crosses the horizon.
struct SunArcView: View {
    let cycle: SunCycle
    /// What is written on the chart. Made with `marks(for:…)` where the cycle is built, so
    /// that it is worked out once per cycle: this view's body also runs on every colour-temp
    /// tick, for the accent.
    let marks: Marks
    /// The arc's colours through the day for a palette, from what Auto will show at each
    /// sample of the cycle. With them the arc is drawn in the tint the screen will have at
    /// each time of day, as bright as its white point; without them, in the live accent from
    /// end to end. Asked for in the body, so that a change to what Auto would show redraws
    /// the arc.
    var tint: (@MainActor (EmberPalette) -> TintGradients?)? = nil

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent

    /// The times under the chart, the bedtime on it, and all of it in words.
    struct Marks: Equatable {
        /// Sunrise and sunset, in the order they fall on the chart.
        var labels: [ClockLabel] = []
        /// Where the Adaptive bedtime sits on the curve, when one is set and falls on it.
        var bedtime: BedtimeMark?
        /// The chart for assistive apps, which see it as one image.
        var description = ""
    }

    struct BedtimeMark: Equatable {
        let t: Double
        let elevation: Double
    }

    /// `nextEvent` is the manager's "Sunset in 1 h 12 m", or nil when no event is coming.
    static func marks(
        for cycle: SunCycle, bedtime: Bedtime?, nextEvent: String? = nil, calendar: Calendar, locale: Locale
    ) -> Marks {
        let samples = cycle.samples
        let bedtimeMark = bedtime.flatMap { mark(for: $0, in: samples, calendar: calendar) }
        let times = sunTimes(for: samples, calendar: calendar, locale: locale)
        return Marks(
            labels: clockLabels(for: samples, calendar: calendar, locale: locale),
            bedtime: bedtimeMark.map { BedtimeMark(t: $0.t, elevation: $0.elevation) },
            description: accessibilityDescription(
                nextEvent: nextEvent.map(spokenDuration),
                currentElevation: cycle.nowElevation, sunrise: times.sunrise, sunset: times.sunset,
                bedtime: bedtimeMark == nil ? nil : bedtime.map { bedtimeText($0, locale: locale) }))
    }

    /// A point where the sampled curve passes through the horizon.
    struct HorizonCrossing: Equatable {
        /// Fraction of the local day, 0…1.
        let t: Double
        let date: Date
        /// True for a sunrise.
        let rising: Bool
    }

    /// A clock time to hang under the chart at day fraction `t`.
    struct ClockLabel: Equatable {
        let t: Double
        let text: String
    }

    nonisolated static let chartHeight: CGFloat = 66
    // The curve's scale runs between these two lines of the chart, which leaves room for
    // the sun's halo above the highest point of the curve.
    nonisolated private static let plotTop: CGFloat = 8
    nonisolated private static let plotBottom: CGFloat = chartHeight - 2
    private static let labelSpacing: CGFloat = 2
    private static let labelHeight: CGFloat = 12
    private static let labelGap: CGFloat = 6
    /// The canvas is this much wider than the chart on each side, so the round ends of the
    /// curve, the sun's halo at midnight and a late bedtime's moon are not cut off.
    nonisolated static let bleed: CGFloat = 10
    private static let moonScale: CGFloat = 0.7
    /// From the top of the moon's box down to the line it floats above.
    private static let moonRise: CGFloat = 15

    /// The curve's width: thick enough to read the tint changing along it.
    static let lineWidth: CGFloat = 2.75

    var body: some View {
        let palette = self.palette
        let samples = cycle.samples
        let labels = marks.labels
        let bedtimeMark = marks.bedtime
        let now = (t: cycle.nowFraction, elevation: cycle.nowElevation)
        // Colours are settled here: the canvas draws later, when the environment is not readable.
        let accent = self.accent.rgb(for: palette)
        let dayArea = palette.dayArea(accent: accent)
        let arcLine = palette.arcLine(accent: accent)
        let halo = palette.arcHalo(accent: accent)
        let dot = palette.arcDot(accent: accent)
        let horizon = palette.isIncreasedContrast ? palette.text.opacity(0.85) : palette.tertiary.opacity(0.55)
        let gradients = tint?(palette)

        Canvas { ctx, size in
            let bleed = Self.bleed
            let w = size.width - 2 * bleed
            guard w > 0, samples.count > 1 else { return }
            let plot = Plot(samples: samples, width: size.width)

            func x(_ t: Double) -> CGFloat { plot.x(t) }
            func y(_ e: Double) -> CGFloat { plot.y(e) }
            func disc(_ centre: CGPoint, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: 2 * radius, height: 2 * radius))
            }
            // Hairlines sit on whole pixels at 1x and 2x.
            let horizonY = Self.snapped(y(0))

            let points = samples.map { CGPoint(x: x($0.t), y: y($0.elevation)) }
            let curve = Self.smoothPath(points)
            // Everything between the curve and the horizon, on either side of it.
            var area = curve
            area.addLine(to: CGPoint(x: x(1), y: horizonY))
            area.addLine(to: CGPoint(x: x(0), y: horizonY))
            area.closeSubpath()

            var below = ctx
            below.clip(to: Path(CGRect(x: 0, y: horizonY, width: size.width,
                                       height: max(0, size.height - horizonY))))
            below.fill(area, with: .color(palette.nightArea))
            var above = ctx
            above.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY)))
            // Left to right is the day, so a gradient along x is a colour for each time.
            let dayStart = CGPoint(x: x(0), y: 0), dayEnd = CGPoint(x: x(1), y: 0)
            above.fill(area, with: gradients.map {
                .linearGradient($0.area, startPoint: dayStart, endPoint: dayEnd)
            } ?? .color(dayArea))

            var line = Path()
            line.move(to: CGPoint(x: x(0), y: horizonY))
            line.addLine(to: CGPoint(x: x(1), y: horizonY))
            ctx.stroke(line, with: .color(horizon), lineWidth: 1)

            var bedtimePoint: CGPoint?
            if let bedtimeMark {
                let point = CGPoint(x: Self.snapped(x(bedtimeMark.t)), y: y(bedtimeMark.elevation))
                var drop = Path()
                drop.move(to: point)
                drop.addLine(to: CGPoint(x: point.x, y: horizonY))
                ctx.stroke(drop, with: .color(palette.tertiary), lineWidth: 1)
                bedtimePoint = point
            }

            ctx.stroke(curve, with: gradients.map {
                .linearGradient($0.line, startPoint: dayStart, endPoint: dayEnd)
            } ?? .color(arcLine),
                       style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))

            if let point = bedtimePoint {
                ctx.fill(disc(point, 2.5), with: .color(palette.secondary))
                let scale = Self.moonScale
                let top = Self.moonTop(horizonY: horizonY, curveY: point.y)
                let moon = Self.moonGlyph.applying(
                    CGAffineTransform(translationX: point.x - 8 * scale, y: top).scaledBy(x: scale, y: scale))
                ctx.fill(moon, with: .color(palette.secondary))
            }

            let sun = CGPoint(x: x(now.t), y: y(now.elevation))
            ctx.fill(disc(sun, 9), with: .color(halo))
            ctx.fill(disc(sun, 4.5), with: .color(dot))

            guard !labels.isEmpty else { return }
            let midY = Self.chartHeight + Self.labelSpacing + Self.labelHeight / 2
            let texts = labels.map { label in
                var text = ctx.resolve(Text(verbatim: label.text).font(.system(size: 10)).monospacedDigit())
                text.shading = .color(palette.tertiary)
                return text
            }
            let widths = texts.map { $0.measure(in: CGSize(width: 400, height: 40)).width }
            if texts.count == 1 {
                let origin = AnchoredLabels.origin(anchor: x(labels[0].t) - bleed, width: widths[0], row: w)
                ctx.draw(texts[0], at: CGPoint(x: bleed + origin, y: midY), anchor: .leading)
            } else {
                let origins = AnchoredLabels.origins(
                    first: (x(labels[0].t) - bleed, widths[0]),
                    second: (x(labels[1].t) - bleed, widths[1]),
                    row: w, gap: Self.labelGap)
                ctx.draw(texts[0], at: CGPoint(x: bleed + origins.first, y: midY), anchor: .leading)
                ctx.draw(texts[1], at: CGPoint(x: bleed + origins.second, y: midY), anchor: .leading)
            }
        }
        .frame(height: Self.chartHeight + Self.labelSpacing + Self.labelHeight)
        .padding(.horizontal, -Self.bleed)
        .allowsHitTesting(false)
        // The chart is one image to assistive apps, so everything written on it is in its text.
        .accessibilityRepresentation {
            Text(marks.description)
        }
    }

    /// Where the chart puts a time of day and an elevation, in a canvas `width` wide: the
    /// canvas reaches `bleed` past the row on either side.
    struct Plot {
        let width: CGFloat
        let geometry: SunArcGeometry

        init(samples: [SunCycle.Sample], width: CGFloat) {
            self.width = width
            geometry = SunArcGeometry(
                elevations: samples.lazy.map(\.elevation),
                height: SunArcView.plotBottom - SunArcView.plotTop, padding: 0)
        }

        nonisolated func x(_ t: Double) -> CGFloat { SunArcView.bleed + CGFloat(t) * (width - 2 * SunArcView.bleed) }
        nonisolated func y(_ elevation: Double) -> CGFloat { SunArcView.plotTop + geometry.y(for: elevation) }
    }

    /// The centre of the sun dot, in a canvas as wide as the row plus `bleed` on each side.
    static func sunCentre(for cycle: SunCycle, rowWidth: CGFloat) -> CGPoint {
        let plot = Plot(samples: cycle.samples, width: rowWidth + 2 * bleed)
        return CGPoint(x: plot.x(cycle.nowFraction), y: plot.y(cycle.nowElevation))
    }

    /// The arc's line and the area under it, each a gradient along the day.
    struct TintGradients: Equatable {
        var line: Gradient
        var area: Gradient
    }

    /// The arc's line and the area under it as gradients along the day, from what Auto shows
    /// at each sample: the colour temp's tint, as bright as the white point makes it, the way
    /// the white point slider's own fill is. The line keeps `EmberPalette.arcLineContrast`
    /// on the panel however dim. The light appearance has its own, deeper scale, made to show
    /// on a pale panel; with Increase Contrast on, its line stays ink and only the area is
    /// tinted. Nil without a value for every sample.
    static func tintGradients(
        _ track: [DisplayManager.AutoTint]?, samples: [SunCycle.Sample], palette: EmberPalette
    ) -> TintGradients? {
        guard let track, track.count == samples.count, samples.count > 1 else { return nil }
        let scheme: ColorScheme = palette.isDark ? .dark : .light
        let inkLine = !palette.isDark && palette.isIncreasedContrast
        var line: [Gradient.Stop] = [], area: [Gradient.Stop] = []
        for (sample, point) in zip(samples, track) {
            let tint = EmberTint.rgb(intensity: point.intensity, scheme: scheme)
            let fill = palette.sliderFillRGB(.level(SliderRow.level(whitepoint: point.whitepoint)), accent: tint)
            let location = CGFloat(min(1, max(0, sample.t)))
            let stroke = inkLine ? palette.arcLine(accent: tint) : palette.arcLineRGB(dimmed: fill, tint: tint).color
            line.append(Gradient.Stop(color: stroke, location: location))
            area.append(Gradient.Stop(color: palette.dayArea(accent: fill), location: location))
        }
        return TintGradients(line: Gradient(stops: line), area: Gradient(stops: area))
    }

    static func accessibilitySummary(currentElevation: Double) -> String {
        "Solar elevation \(degreeLabel(currentElevation))."
    }

    /// The chart in words: what comes next, the sun's height now, then each time that is drawn
    /// on it. A day without a sunrise or a sunset, an arc without a bedtime mark and a sky with
    /// no event coming leave theirs out.
    static func accessibilityDescription(
        nextEvent: String? = nil, currentElevation: Double, sunrise: String?, sunset: String?, bedtime: String?
    ) -> String {
        var sentences = nextEvent.map { ["\($0)."] } ?? []
        sentences.append(accessibilitySummary(currentElevation: currentElevation))
        if let sunrise { sentences.append("Sunrise \(sunrise).") }
        if let sunset { sentences.append("Sunset \(sunset).") }
        if let bedtime { sentences.append("Bedtime \(bedtime).") }
        return sentences.joined(separator: " ")
    }

    /// A countdown as VoiceOver should say it: "Sunset in 1 h 12 m" becomes "Sunset in 1 hour
    /// 12 minutes". The letters would otherwise be read as letters. Text without a count and
    /// a unit comes back as it is.
    static func spokenDuration(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in words.indices.dropFirst() {
            guard let count = Int(words[index - 1]) else { continue }
            switch words[index] {
            case "h": words[index] = count == 1 ? "hour" : "hours"
            case "m": words[index] = count == 1 ? "minute" : "minutes"
            default: break
            }
        }
        return words.joined(separator: " ")
    }

    /// The clock times of the day's sunrise and sunset, as the labels under the chart show them.
    static func sunTimes(
        for samples: [SunCycle.Sample], calendar: Calendar, locale: Locale
    ) -> (sunrise: String?, sunset: String?) {
        guard let dayStart = samples.first?.date else { return (nil, nil) }
        let (sunrise, sunset) = sunriseAndSunset(in: samples)
        func text(_ crossing: HorizonCrossing?) -> String? {
            crossing.map { clockText(for: $0.date, dayStart: dayStart, calendar: calendar, locale: locale) }
        }
        return (text(sunrise), text(sunset))
    }

    /// A bedtime as a localized short time. It is a wall-clock time, the same on every day.
    static func bedtimeText(_ bedtime: Bedtime, locale: Locale) -> String {
        Date(timeIntervalSinceReferenceDate: Double(bedtime.minuteOfDay) * 60).formatted(Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, timeZone: .gmt))
    }

    static func degreeLabel(_ elevation: Double) -> String {
        guard let rounded = Int(exactly: elevation.rounded()) else { return "unavailable" }
        if rounded > 0 { return "+\(rounded)°" }
        if rounded < 0 { return "−\(rounded.magnitude)°" }
        return "0°"
    }

    /// Catmull-Rom interpolation as cubic Béziers — smooth through every point.
    static func smoothPath(_ p: [CGPoint]) -> Path {
        var path = Path()
        guard p.count > 1 else { return path }
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)]
            let p1 = p[i]
            let p2 = p[i + 1]
            let p3 = p[min(p.count - 1, i + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    // MARK: - Horizon crossings

    /// Where the sampled curve passes through the horizon, in time order, interpolated
    /// between the samples on either side. A sample exactly on the horizon is the crossing
    /// when the sun is on opposite sides before and after it; a curve that only touches the
    /// horizon and turns back does not cross. Polar day and polar night give none.
    /// `level` is the elevation that counts as the horizon.
    static func horizonCrossings(in samples: [SunCycle.Sample], at level: Double = 0) -> [HorizonCrossing] {
        var result: [HorizonCrossing] = []
        // The last sample that was clearly above or below the horizon.
        var previous: Int?
        for index in samples.indices {
            let elevation = samples[index].elevation
            guard elevation.isFinite, elevation != level else { continue }
            defer { previous = index }
            guard let previous, (samples[previous].elevation > level) != (elevation > level) else { continue }
            let a: SunCycle.Sample, b: SunCycle.Sample, f: Double
            if index == previous + 1 {
                a = samples[previous]
                b = samples[index]
                f = (a.elevation - level) / (a.elevation - b.elevation)
            } else {
                // One or more samples sat on the horizon: cross in the middle of them.
                a = samples[previous + 1]
                b = samples[index - 1]
                f = 0.5
            }
            result.append(HorizonCrossing(
                t: a.t + (b.t - a.t) * f,
                date: a.date.addingTimeInterval(b.date.timeIntervalSince(a.date) * f),
                rising: elevation > level))
        }
        return result
    }

    /// The first sunrise and the last sunset of the sampled day, as an almanac times them:
    /// at the apparent horizon, a few minutes outside the geometric crossings.
    static func sunriseAndSunset(
        in samples: [SunCycle.Sample]
    ) -> (sunrise: HorizonCrossing?, sunset: HorizonCrossing?) {
        let crossings = horizonCrossings(in: samples, at: SolarCurve.apparentHorizonElevation)
        return (crossings.first { $0.rising }, crossings.last { !$0.rising })
    }

    /// The sunrise and sunset times, in the order they fall on the chart.
    static func clockLabels(
        for samples: [SunCycle.Sample], calendar: Calendar, locale: Locale
    ) -> [ClockLabel] {
        guard let dayStart = samples.first?.date else { return [] }
        let (sunrise, sunset) = sunriseAndSunset(in: samples)
        return [sunrise, sunset].compactMap { $0 }.sorted { $0.t < $1.t }.map {
            ClockLabel(t: $0.t, text: clockText(for: $0.date, dayStart: dayStart,
                                                calendar: calendar, locale: locale))
        }
    }

    /// A localized short time, to the nearest minute, on the clock the cycle was built with.
    ///
    /// `calendar` is the environment's, which is the one the popover builds the cycle with.
    /// If the cycle's day was cut in some other time zone, its start is not a midnight in
    /// `calendar`; the time then comes from the cycle's own clock, as time since its midnight.
    static func clockText(for date: Date, dayStart: Date, calendar: Calendar, locale: Locale) -> String {
        var calendar = calendar
        var seconds = date.timeIntervalSinceReferenceDate
        if calendar.startOfDay(for: dayStart) != dayStart {
            calendar.timeZone = .gmt
            seconds = date.timeIntervalSince(dayStart)
        }
        let instant = Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded() * 60)
        return instant.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar,
            timeZone: calendar.timeZone))
    }

    // MARK: - Bedtime

    /// Where the bedtime falls on the sampled day and how high the sun is then.
    static func mark(
        for bedtime: Bedtime, in samples: [SunCycle.Sample], calendar: Calendar
    ) -> (t: Double, elevation: Double)? {
        guard let t = dayFraction(of: bedtime, in: samples, calendar: calendar),
              let elevation = elevation(at: t, in: samples) else { return nil }
        return (t, elevation)
    }

    /// The bedtime as a fraction of the sampled local day, which is 23 or 25 hours long when
    /// the clocks change.
    static func dayFraction(
        of bedtime: Bedtime, in samples: [SunCycle.Sample], calendar: Calendar
    ) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let length = last.date.timeIntervalSince(first.date)
        guard length > 0 else { return nil }
        if calendar.startOfDay(for: first.date) == first.date,
           let date = calendar.date(bySettingHour: bedtime.hour, minute: bedtime.minute,
                                    second: 0, of: first.date) {
            let t = date.timeIntervalSince(first.date) / length
            if (0...1).contains(t) { return t }
        }
        return Double(bedtime.minuteOfDay) / 1440
    }

    /// The curve's elevation at day fraction `t`, between the two samples around it.
    static func elevation(at t: Double, in samples: [SunCycle.Sample]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return first.elevation }
        for index in samples.indices.dropFirst() where t <= samples[index].t {
            let a = samples[index - 1], b = samples[index]
            let span = b.t - a.t
            return span > 0 ? a.elevation + (b.elevation - a.elevation) * (t - a.t) / span : b.elevation
        }
        return last.elevation
    }

    /// Top of the moon's box. It floats above the horizon, or above the curve where the sun
    /// is still up at bedtime and the hairline rises there instead. With no room above, it
    /// goes under the horizon.
    static func moonTop(horizonY: CGFloat, curveY: CGFloat) -> CGFloat {
        let above = min(horizonY, curveY) - moonRise
        return above >= 0 ? above : horizonY + 4
    }

    /// A crescent in a 16-point box: a disc with a second disc cut from its upper right.
    private static let moonGlyph: Path = {
        func disc(_ x: CGFloat, _ y: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x - 5.6, y: y - 5.6, width: 11.2, height: 11.2))
        }
        return disc(7.77, 8.23).subtracting(disc(11.83, 4.17))
    }()

    private static func snapped(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
