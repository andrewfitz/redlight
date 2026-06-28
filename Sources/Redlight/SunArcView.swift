import SwiftUI

/// Clean, flat sun-arc graphic. The smooth elevation curve (x = local time, y = sun
/// elevation) over an area tinted by the applied adaptive intensity — clear by day, red at
/// night. Horizon and the intensity band (two guide lines) are drawn as thin vectors.
struct SunArcView: View {
    let cycle: SunCycle
    var intensities: [Double] = []                 // applied intensity per sample (0…1)
    var intensityLimits: ClosedRange<Double> = 0...1

    var body: some View {
        Canvas { ctx, size in
            let pad: CGFloat = 6
            let top = pad, bottom = size.height - pad
            let h = bottom - top
            let w = size.width
            let xPad: CGFloat = 8                       // keep the sun dot off the edges

            // One linear elevation→y scale with margin (smooth, no kink). Polar-safe span.
            let elevs = cycle.samples.map(\.elevation)
            let hiE = max(elevs.max() ?? 10, 5) + 3
            let loE = min(elevs.min() ?? -18, -18) - 3
            let spanE = max(1, hiE - loE)
            func y(_ e: Double) -> CGFloat { top + CGFloat((hiE - e) / spanE) * h }
            func x(_ t: Double) -> CGFloat { xPad + CGFloat(t) * (w - 2 * xPad) }
            let horizonY = y(0)
            let sx = x(cycle.nowFraction), sy = y(cycle.nowElevation)

            // Smooth curve + the area beneath it.
            let pts = cycle.samples.map { CGPoint(x: x($0.t), y: y($0.elevation)) }
            let curve = Self.smoothPath(pts)
            var area = curve
            area.addLine(to: CGPoint(x: pts.last!.x, y: bottom))
            area.addLine(to: CGPoint(x: pts.first!.x, y: bottom))
            area.closeSubpath()

            // Tint the area by the applied intensity across the day (clear day → red night).
            if intensities.count == cycle.samples.count, !intensities.isEmpty {
                let stops = zip(cycle.samples, intensities).map { sample, i in
                    Gradient.Stop(color: Self.intensityColor(i), location: sample.t)
                }
                ctx.fill(area, with: .linearGradient(Gradient(stops: stops),
                                                     startPoint: CGPoint(x: 0, y: 0),
                                                     endPoint: CGPoint(x: w, y: 0)))
            } else {
                ctx.fill(area, with: .color(.orange.opacity(0.18)))
            }

            // Intensity band guide lines (top = clear, bottom = full red).
            func bandY(_ v: Double) -> CGFloat { top + CGFloat(1 - min(1, max(0, v))) * h }
            for v in [intensityLimits.upperBound, intensityLimits.lowerBound] where v > 0 && v < 1 {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: bandY(v)))
                line.addLine(to: CGPoint(x: w, y: bandY(v)))
                ctx.stroke(line, with: .color(.white.opacity(0.20)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            // Horizon.
            var hz = Path()
            hz.move(to: CGPoint(x: 0, y: horizonY)); hz.addLine(to: CGPoint(x: w, y: horizonY))
            ctx.stroke(hz, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Curve — single clean stroke.
            ctx.stroke(curve, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Sun dot — flat fill, thin outline.
            let core: Color = cycle.nowElevation >= 0 ? Color(red: 1, green: 0.86, blue: 0.4) : .red
            let dot = CGRect(x: sx - 4, y: sy - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: dot), with: .color(core))
            ctx.stroke(Path(ellipseIn: dot), with: .color(.white.opacity(0.7)), lineWidth: 0.75)
        }
        .frame(height: 70)
    }

    /// Applied intensity → tint. 1 = clear/warm (no filter), 0 = deep red (full filter).
    static func intensityColor(_ v: Double) -> Color {
        let c = min(1, max(0, v))
        return Color(red: 0.95, green: 0.20 + 0.70 * c, blue: 0.15 + 0.55 * c, opacity: 0.70 - 0.25 * c)
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
}
