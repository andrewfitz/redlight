import AppKit

/// A filled circular sun partially hidden behind a bezeled monitor. The glass carries
/// state: 10% opacity when disabled, 70% when enabled. Both images are templates so macOS
/// recolors the same sun and bezel for either menu-bar appearance.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    static let monitorHeight: CGFloat = 11
    static let sunRadius: CGFloat = 5.4
    static let sunCenter = CGPoint(x: 9, y: 12)
    static let screenRect = CGRect(x: 2.1, y: 1.2, width: 13.8, height: 8.3)
    static let screenCornerRadius: CGFloat = 0.6
    static let activeScreenOpacity: CGFloat = 0.70
    static let inactiveScreenOpacity: CGFloat = 0.10

    @MainActor static func activeImage() -> NSImage { active }
    @MainActor static func inactiveImage() -> NSImage { inactive }

    @MainActor private static let active = templateImage(active: true)
    @MainActor private static let inactive = templateImage(active: false)

    private static func templateImage(active: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let screenOpacity = active ? activeScreenOpacity : inactiveScreenOpacity
            drawScreen(in: ctx, color: NSColor.black.withAlphaComponent(screenOpacity).cgColor)
            drawMonitor(in: ctx, color: NSColor.black.cgColor)
            drawSun(in: ctx, color: NSColor.black.cgColor)
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

    private static func drawMonitor(in ctx: CGContext, color: CGColor) {
        // Taller monitor: opaque bezel surrounding translucent glass.
        let monitor = CGRect(x: 0.5, y: 0, width: size.width - 1, height: monitorHeight)
        let frame = CGMutablePath()
        frame.addRoundedRect(in: monitor, cornerWidth: 1.5, cornerHeight: 1.5)
        frame.addRoundedRect(
            in: screenRect, cornerWidth: screenCornerRadius,
            cornerHeight: screenCornerRadius)
        ctx.addPath(frame)
        ctx.setFillColor(color)
        ctx.drawPath(using: .eoFill)
    }

    private static func drawSun(in ctx: CGContext, color: CGColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Occlude the lower sun, including inside the translucent screen. The underlying
        // ellipse keeps equal dimensions so the visible arc retains a circular shape.
        ctx.clip(to: CGRect(x: 0, y: monitorHeight,
                            width: size.width, height: size.height - monitorHeight))
        let sun = CGMutablePath()
        sun.addEllipse(in: CGRect(
            x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius,
            width: 2 * sunRadius, height: 2 * sunRadius))
        ctx.addPath(sun)
        ctx.setFillColor(color)
        ctx.drawPath(using: .eoFill)
    }
}
