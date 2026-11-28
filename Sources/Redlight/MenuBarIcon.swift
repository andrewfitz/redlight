import AppKit

/// A plain sun disc that sets as the filter deepens. With no filter to show it is the whole
/// sun: off, an inversion with no tint, and a color temp of 100 % are all the solid disc. From
/// 99 % down, horizontal slits cut its lower part; the first slit sits higher for each deeper
/// level, so the icon doubles as a gauge. What lies under a slit, each rung, is the sea: it
/// is drawn faded, and a little wider for each slit, while the sun above the last slit is a
/// little smaller for each. A sun going down over the water.
///
/// Every image is a template, so macOS recolors it for either menu-bar appearance. The
/// level is told by shape, the number of slits; the fading only adds to it.
enum MenuBarIcon {
    /// How far the sun has set.
    enum Level: Int, CaseIterable, Sendable {
        /// No filter is showing: off, paused, or suspended for an app.
        case off
        /// A filter is on with the color temp at 100 %: no warmth to count.
        case clear
        /// 99 % down to 67 %: Warm.
        case low
        /// 66 % down to 34 %: Sunset.
        case mid
        /// 33 % and under: Night and Late.
        case deep
        /// Only an inversion is showing: the tint is off, paused, or suspended for an app.
        case inverted

        /// The level for a color-temp value, 1 (unfiltered) through 0 (Late). The lines come
        /// at whole percents as the popover writes them: the first at 99 %, and the other two
        /// a third and two thirds of the way down, at 66 % and 33 %.
        ///
        /// `showsTint` is false when only an inversion is showing: the tint is off, paused or
        /// suspended. The sun is then whole, whatever the colour temp is set to: the lines
        /// count a tint's depth, and there is no tint on screen.
        init(isActive: Bool, showsTint: Bool = true, intensity: Double) {
            guard isActive else { self = .off; return }
            guard showsTint else { self = .inverted; return }
            switch SliderCore.percent(intensity.isFinite ? intensity : 1) {
            case ...Self.thirdLinePercent: self = .deep
            case ...Self.secondLinePercent: self = .mid
            case ...Self.firstLinePercent: self = .low
            default: self = .clear
            }
        }

        /// The highest color temp, in whole percent, that shows each line.
        static let firstLinePercent = 99
        static let secondLinePercent = 66
        static let thirdLinePercent = 33

        var accessibilityValue: String {
            switch self {
            case .off: "Inactive"
            case .clear: "Active, no color filter"
            case .low: "Active, light filter"
            case .mid: "Active, medium filter"
            case .deep: "Active, deepest filter"
            case .inverted: "Active, colors inverted"
            }
        }

        /// How many lines cross the sun.
        var slitCount: Int {
            switch self {
            case .off, .clear, .inverted: 0
            case .low: 1
            case .mid: 2
            case .deep: 3
            }
        }
    }

    static let size = NSSize(width: 18, height: 18)
    static let center = CGPoint(x: 9, y: 9)
    static let radius: CGFloat = 7.5
    static let slitHeight: CGFloat = 1.5
    /// Bottom edge of each slit, lowest first, in points from the bottom of the image. Each
    /// slit is 1.5 pt, three clean pixel rows on a Retina display.
    static let slitOrigins: [CGFloat] = [4, 7, 10]

    /// A hair taken off the sun's radius as soon as it has a line, on top of the steps.
    static let sunInset: CGFloat = 0.25
    /// How much smaller the sun's radius is for each line across it, and how much further the
    /// sea reaches to each side. Half a point is one clean pixel on a Retina display.
    static let step: CGFloat = 0.5

    /// The radius of the sun above a level's last slit: the whole disc with no line, then a
    /// little smaller with each one.
    static func sunRadius(for level: Level) -> CGFloat {
        let lines = CGFloat(level.slitCount)
        return lines == 0 ? radius : radius - sunInset - lines * step
    }

    /// The oval the rungs under a level's slits are cut from: as tall as the whole disc, and
    /// a little wider with each line.
    static func sea(for level: Level) -> CGRect {
        let reach = radius + CGFloat(level.slitCount) * step
        return CGRect(x: center.x - reach, y: center.y - radius, width: 2 * reach, height: 2 * radius)
    }

    /// How strongly the sea is drawn.
    static let rungAlpha: CGFloat = 0.4

    /// The bands of the disc under a level's slits, lowest first: the cap under the first
    /// slit, then what lies between each slit and the next. The disc above the last slit is
    /// not one of them.
    static func rungs(for level: Level) -> [CGRect] {
        var bottom: CGFloat = 0
        return slits(for: level).map { slit in
            defer { bottom = slit.maxY }
            return CGRect(x: 0, y: bottom, width: size.width, height: slit.minY - bottom)
        }
    }

    /// The slits a level shows: the lowest one first, one more per level.
    static func slits(for level: Level) -> [CGRect] {
        slitOrigins.prefix(level.slitCount).map {
            CGRect(x: 0, y: $0, width: size.width, height: slitHeight)
        }
    }

    @MainActor static func image(for level: Level) -> NSImage { images[level.rawValue] }

    @MainActor private static let images = Level.allCases.map(templateImage)

    private static func templateImage(_ level: Level) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(level, in: ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ level: Level, in ctx: CGContext) {
        // Fill the bands around the slits rather than erasing, so the image is clear
        // wherever nothing is drawn.
        ctx.saveGState()
        ctx.addEllipse(in: sea(for: level))
        ctx.clip()
        ctx.setFillColor(NSColor.black.withAlphaComponent(rungAlpha).cgColor)
        for rung in rungs(for: level) { ctx.fill(rung) }
        ctx.restoreGState()

        ctx.saveGState()
        defer { ctx.restoreGState() }
        let sun = sunRadius(for: level)
        ctx.addEllipse(in: CGRect(x: center.x - sun, y: center.y - sun, width: 2 * sun, height: 2 * sun))
        ctx.clip()
        let top = slits(for: level).last?.maxY ?? 0
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: size.width, height: size.height - top))
    }
}
