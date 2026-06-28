import SwiftUI

/// Compact sun-arc graphic. The smooth elevation curve (x = local time, y = sun elevation)
/// sits over an area tinted by the **actual adaptive intensity** at each moment — clear by
/// day, deep red at night. A slim colorbar on the right shows the intensity colormap with
/// tick marks at the user's min/max limits.
struct SunArcView: View {
    let cycle: SunCycle
    var intensities: [Double] = []                 // applied intensity per sample (0…1)
    var intensityLimits: ClosedRange<Double> = 0...1

    var body: some View {
        Canvas { ctx, size in
            let pad: CGFloat = 6
            let top = pad, bottom = size.height - pad
            let h = bottom - top
            let legendW: CGFloat = 22
            let plotW = max(1, size.width - legendW - 8)

            // One linear elevation→y scale with margin (smooth, no kink). Polar-safe span.
            let elevs = cycle.samples.map(\.elevation)
            let hiE = max(elevs.max() ?? 10, 5) + 3
            let loE = min(elevs.min() ?? -18, -18) - 3
            let spanE = max(1, hiE - loE)
            func y(_ e: Double) -> CGFloat { top + CGFloat((hiE - e) / spanE) * h }
            func x(_ t: Double) -> CGFloat { CGFloat(t) * plotW }
            let horizonY = y(0)
            let sx = x(cycle.nowFraction), sy = y(cycle.nowElevation)

            // Backdrop.
            ctx.fill(Path(CGRect(x: 0, y: top, width: plotW, height: h)),
                     with: .color(Color(red: 0.12, green: 0.12, blue: 0.15)))

            // Smooth curve + the area beneath it.
            let pts = cycle.samples.map { CGPoint(x: x($0.t), y: y($0.elevation)) }
            let curve = Self.smoothPath(pts)
            var area = curve
            area.addLine(to: CGPoint(x: pts.last!.x, y: bottom))
            area.addLine(to: CGPoint(x: pts.first!.x, y: bottom))
            area.closeSubpath()

            // Tint the area by the applied intensity across the day (horizontal gradient).
            if intensities.count == cycle.samples.count, !intensities.isEmpty {
                let stops = zip(cycle.samples, intensities).map { sample, i in
                    Gradient.Stop(color: Self.intensityColor(i), location: sample.t)
                }
                ctx.fill(area, with: .linearGradient(Gradient(stops: stops),
                                                     startPoint: CGPoint(x: 0, y: 0),
                                                     endPoint: CGPoint(x: plotW, y: 0)))
            } else {
                ctx.fill(area, with: .color(.orange.opacity(0.22)))
            }

            // Horizon (subtle dashed).
            var hz = Path()
            hz.move(to: CGPoint(x: 0, y: horizonY)); hz.addLine(to: CGPoint(x: plotW, y: horizonY))
            ctx.stroke(hz, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // "Now" guide.
            var guide = Path()
            guide.move(to: CGPoint(x: sx, y: top)); guide.addLine(to: CGPoint(x: sx, y: bottom))
            ctx.stroke(guide, with: .color(.white.opacity(0.12)), lineWidth: 1)

            // Curve: soft underglow + amber gradient stroke.
            ctx.stroke(curve, with: .color(.orange.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            let lineGrad = Gradient(colors: [.yellow.opacity(0.95), .orange, .red.opacity(0.7)])
            ctx.stroke(curve, with: .linearGradient(lineGrad,
                                                    startPoint: CGPoint(x: 0, y: top),
                                                    endPoint: CGPoint(x: 0, y: bottom)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Sun dot with radial halo.
            let core: Color = cycle.nowElevation >= 0 ? Color(red: 1, green: 0.93, blue: 0.62)
                                                      : Color(red: 1, green: 0.5, blue: 0.36)
            ctx.fill(Path(ellipseIn: CGRect(x: sx - 10, y: sy - 10, width: 20, height: 20)),
                     with: .radialGradient(Gradient(colors: [core.opacity(0.55), core.opacity(0)]),
                                           center: CGPoint(x: sx, y: sy), startRadius: 0, endRadius: 10))
            let dot = CGRect(x: sx - 4.5, y: sy - 4.5, width: 9, height: 9)
            ctx.fill(Path(ellipseIn: dot), with: .color(core))
            ctx.stroke(Path(ellipseIn: dot), with: .color(.white.opacity(0.65)), lineWidth: 0.5)

            // Intensity legend (right): colormap bar + min/max limit ticks.
            let lo = intensityLimits.lowerBound, hi = intensityLimits.upperBound
            let barX = size.width - legendW / 2
            let bar = CGRect(x: barX - 4, y: top, width: 8, height: h)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 4),
                     with: .linearGradient(Gradient(colors: [Self.intensityColor(1), Self.intensityColor(0)]),
                                           startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bottom)))
            ctx.stroke(Path(roundedRect: bar, cornerRadius: 4), with: .color(.white.opacity(0.15)), lineWidth: 0.5)

            func legendY(_ v: Double) -> CGFloat { top + CGFloat(1 - v) * h }   // v=1 top, v=0 bottom
            for v in [hi, lo] {
                var tick = Path()
                tick.move(to: CGPoint(x: barX - 7, y: legendY(v)))
                tick.addLine(to: CGPoint(x: barX + 6, y: legendY(v)))
                ctx.stroke(tick, with: .color(.white.opacity(0.85)), lineWidth: 1)
                ctx.draw(Text("\(Int((v * 100).rounded()))").font(.system(size: 7, weight: .medium))
                            .foregroundColor(.white.opacity(0.75)),
                         at: CGPoint(x: barX, y: legendY(v) + (v == hi ? -7 : 8)))
            }
        }
        .frame(height: 80)
    }

    /// Applied intensity → tint. 1 = clear/warm (no filter), 0 = deep red (full filter).
    static func intensityColor(_ v: Double) -> Color {
        let c = min(1, max(0, v))
        return Color(red: 0.95, green: 0.20 + 0.70 * c, blue: 0.15 + 0.55 * c, opacity: 0.85 - 0.30 * c)
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
