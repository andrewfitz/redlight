import AppKit

/// A plain sun disc that sets as the filter deepens. Off is the sun fully up: an outlined
/// ring. On, the disc is solid and horizontal slits cut its lower part; the first slit sits
/// higher for each deeper level, so the icon doubles as a gauge.
///
/// Every image is a template, so macOS recolors it for either menu-bar appearance. All
/// fills are opaque: state is told by shape, never by partial alpha.
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

        /// The level for a color-temp value, 1 (unfiltered) through 0 (Late). The steps fall
        /// halfway between the default presets on either side.
        init(isActive: Bool, intensity: Double) {
            guard isActive else { self = .off; return }
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
            }
        }
    }

    static let size = NSSize(width: 18, height: 18)
    static let center = CGPoint(x: 9, y: 9)
    static let radius: CGFloat = 7.5
    /// The off ring's line width, matching a medium-weight system glyph.
    static let ringWidth: CGFloat = 1.25
    static let slitHeight: CGFloat = 1
    /// Bottom edge of each slit, lowest first, in points from the bottom of the image. Slits
    /// sit on whole points so they stay one clean pixel row on a 1x display.
    static let slitOrigins: [CGFloat] = [4, 7, 10]

    /// The slits a level shows: the lowest one first, one more per level.
    static func slits(for level: Level) -> [CGRect] {
        slitOrigins.prefix(level.rawValue).map {
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
                drawSun(in: ctx, slits: slits(for: level))
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

    private static func drawSun(in ctx: CGContext, slits: [CGRect]) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.addEllipse(in: disc(radius: radius))
        ctx.clip()
        // Fill the bands between the slits rather than erasing, so the image stays opaque
        // where it is drawn and clear everywhere else.
        var bottom: CGFloat = 0
        for slit in slits {
            ctx.fill(CGRect(x: 0, y: bottom, width: size.width, height: slit.minY - bottom))
            bottom = slit.maxY
        }
        ctx.fill(CGRect(x: 0, y: bottom, width: size.width, height: size.height - bottom))
    }
}
