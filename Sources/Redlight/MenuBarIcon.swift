import AppKit

/// The app icon, reduced to the two marks that survive at menu-bar size: a sun half-disc
/// setting behind the top edge of a bezeled monitor.
///
/// Drawn rather than shipped as an asset, and produced as a *template* image so macOS
/// recolors it to contrast the menu bar — dark glyph on a light bar, light glyph on a dark
/// bar — and applies the right vibrancy. This is the standard behavior for a menu-bar extra
/// and the reason no shadow/outline hack is needed to stay legible in either appearance.
///
/// State is carried by shape, not color: the sun is a filled disc when a filter is live and
/// a thin arc when it isn't, so "is Redlight doing anything right now" reads at a glance in
/// light or dark. The screen is drawn at partial alpha so the monitor reads as glass.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 14)
    static let monitorHeight: CGFloat = 8.5
    static let sunRadius: CGFloat = 5.4
    static let screenRect = CGRect(x: 2.1, y: 1.2, width: 13.8, height: 5.7)
    static let screenCornerRadius: CGFloat = 0.6
    static let screenOpacity: CGFloat = 0.70  // 30% transparent glass

    static func activeImage() -> NSImage { templateImage(active: true) }
    static func inactiveImage() -> NSImage { templateImage(active: false) }

    /// A template image: only the alpha channel matters, so any fill color works and macOS
    /// supplies the final color. The bezel is opaque (the app's identity), the screen is
    /// partial alpha (glass), the sun is opaque.
    private static func templateImage(active: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Height is monitorH + sun radius exactly — no dead space above the sun. The
            // monitor is the taller mark; the sun rides on top without dominating it.
            //
            // Translucent screen glass first, then the opaque bezel ring and sun on top. The
            // bezel ring and screen hole are disjoint, so the glass keeps its partial alpha.
            drawScreen(
                in: ctx,
                color: NSColor.black.withAlphaComponent(screenOpacity).cgColor)
            drawGlyph(in: ctx, active: active, color: NSColor.black.cgColor)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawScreen(in ctx: CGContext, color: CGColor) {
        ctx.addPath(CGPath(
            roundedRect: screenRect,
            cornerWidth: screenCornerRadius,
            cornerHeight: screenCornerRadius,
            transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    private static func drawGlyph(in ctx: CGContext, active: Bool, color: CGColor) {
        // Monitor: a case with a transparent inset screen. Its top edge is the horizon.
        let monitor = CGRect(x: 0.5, y: 0, width: size.width - 1, height: monitorHeight)
        let frame = CGMutablePath()
        frame.addRoundedRect(in: monitor, cornerWidth: 1.5, cornerHeight: 1.5)
        frame.addRoundedRect(
            in: screenRect, cornerWidth: screenCornerRadius,
            cornerHeight: screenCornerRadius)
        ctx.addPath(frame)
        ctx.setFillColor(color)
        ctx.drawPath(using: .eoFill)

        // Sun: upper half-disc resting on the monitor's top edge.
        let center = CGPoint(x: size.width / 2, y: monitor.maxY)
        let r = sunRadius
        ctx.saveGState()
        ctx.clip(to: CGRect(
            x: 0, y: center.y, width: size.width,
            height: size.height - center.y))
        if active {
            ctx.addEllipse(in: CGRect(
                x: center.x - r, y: center.y - r,
                width: r * 2, height: r * 2))
            ctx.setFillColor(color)
            ctx.fillPath()
        } else {
            let lineWidth: CGFloat = 1.5
            ctx.addEllipse(in: CGRect(
                x: center.x - r + lineWidth / 2,
                y: center.y - r + lineWidth / 2,
                width: (r - lineWidth / 2) * 2,
                height: (r - lineWidth / 2) * 2))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.strokePath()

            // Rays: 2 per side, only when off, so the idle icon reads as a sun. The disc
            // nearly fills the height, so they fan outward toward the free corners rather
            // than straight up. Hidden when active (a filled disc needs no rays).
            let rayInner = r + 0.6
            let rayOuter = r + 1.9
            ctx.setLineWidth(1.0)
            ctx.setLineCap(.round)
            for degrees in [20.0, 45.0, 135.0, 160.0] {
                let a = degrees * .pi / 180
                ctx.move(to: CGPoint(
                    x: center.x + rayInner * cos(a), y: center.y + rayInner * sin(a)))
                ctx.addLine(to: CGPoint(
                    x: center.x + rayOuter * cos(a), y: center.y + rayOuter * sin(a)))
            }
            ctx.setStrokeColor(color)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
