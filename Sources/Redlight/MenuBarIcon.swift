import AppKit

/// A plain sun disc that sets as the filter deepens. Off is the sun fully up: an outlined
/// ring. On, the disc is solid and horizontal slits cut its lower part; the first slit sits
/// higher for each deeper level, so the icon doubles as a gauge. What is left of the disc
/// under a slit, each rung of it, is drawn at half strength: the part of the sun that has
/// gone down. An inversion with no tint is the solid disc with no slit.
///
/// Every image is a template, so macOS recolors it for either menu-bar appearance. The
/// level is still told by shape, the number of slits; the half strength only adds to it.
enum MenuBarIcon {
    /// How far the sun has set.
    enum Level: Int, CaseIterable, Sendable {
        /// No filter is showing: off, paused, or suspended for an app.
        case off
        /// Day and Warm.
        case low
        /// Sunset and Night.
        case mid
        /// Late.
        case deep
        /// Only an inversion is showing: the tint is off, paused, or suspended for an app.
        case inverted

        /// The level for a color-temp value, 1 (unfiltered) through 0 (Late). The steps fall
        /// halfway between the default presets on either side.
        ///
        /// `showsTint` is false when only an inversion is showing: the tint is off, paused or
        /// suspended. The sun is then solid with no line across it, whatever the colour temp
        /// is set to: the lines count a tint's depth, and there is no tint on screen.
        init(isActive: Bool, showsTint: Bool = true, intensity: Double) {
            guard isActive else { self = .off; return }
            guard showsTint else { self = .inverted; return }
            let value = intensity.isFinite ? intensity : 1
            switch value {
            case ...Self.deepCeiling: self = .deep
            case ...Self.midCeiling: self = .mid
            default: self = .low
            }
        }

        /// Halfway between Night (0.25) and Late (0).
        static let deepCeiling = 0.125
        /// Halfway between Warm (0.7) and Sunset (0.5).
        static let midCeiling = 0.6

        var accessibilityValue: String {
            switch self {
            case .off: "Inactive"
            case .low: "Active, light filter"
            case .mid: "Active, medium filter"
            case .deep: "Active, deepest filter"
            case .inverted: "Active, colors inverted"
            }
        }

        /// How many lines cross the sun.
        var slitCount: Int {
            switch self {
            case .off, .inverted: 0
            case .low: 1
            case .mid: 2
            case .deep: 3
            }
        }
    }

    static let size = NSSize(width: 18, height: 18)
    static let center = CGPoint(x: 9, y: 9)
    static let radius: CGFloat = 7.5
    /// The off ring's line width, matching a medium-weight system glyph.
    static let ringWidth: CGFloat = 1.25
    static let slitHeight: CGFloat = 1.5
    /// Bottom edge of each slit, lowest first, in points from the bottom of the image. Each
    /// slit is 1.5 pt, three clean pixel rows on a Retina display.
    static let slitOrigins: [CGFloat] = [4, 7, 10]

    /// How strongly the disc is drawn under a slit.
    static let rungAlpha: CGFloat = 0.5

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
            ctx.setFillColor(NSColor.black.cgColor)
            if level == .off {
                drawRing(in: ctx)
            } else {
                drawSun(in: ctx, level: level)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func disc(radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    }

    private static func drawRing(in ctx: CGContext) {
        ctx.addEllipse(in: disc(radius: radius))
        ctx.addEllipse(in: disc(radius: radius - ringWidth))
        ctx.drawPath(using: .eoFill)
    }

    private static func drawSun(in ctx: CGContext, level: Level) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.addEllipse(in: disc(radius: radius))
        ctx.clip()
        // Fill the bands around the slits rather than erasing, so the image is clear
        // wherever nothing is drawn.
        ctx.setFillColor(NSColor.black.withAlphaComponent(rungAlpha).cgColor)
        for rung in rungs(for: level) { ctx.fill(rung) }
        let top = slits(for: level).last?.maxY ?? 0
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: size.width, height: size.height - top))
    }
}
