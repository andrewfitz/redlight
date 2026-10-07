import SwiftUI

/// The curve, sun dot, and guide lines share one linear solar-elevation scale.
/// Guides stay at their true elevations; crowded guides are omitted rather than shifted.
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

    init(elevations: [Double], height: CGFloat, padding: CGFloat = 6) {
        let height = max(0, height)
        top = min(max(0, padding), height / 2)
        bottom = height - top
        let finiteElevations = elevations.filter(\.isFinite)
        upperElevation = max(finiteElevations.max() ?? 10, 5) + 3
        lowerElevation = min(finiteElevations.min() ?? -18, -18) - 3
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

/// Clean, flat sun-arc graphic. The smooth elevation curve (x = local time, y = sun
/// elevation) over an area tinted by the applied adaptive intensity — clear by day, red at
/// night. The larger dot is the sun right now.
struct SunArcView: View {
    let cycle: SunCycle
    var intensities: [Double] = []                 // applied intensity per sample (0…1)

    var body: some View {
        Canvas { ctx, size in
                let geometry = SunArcGeometry(
                    elevations: cycle.samples.map(\.elevation), height: size.height)
                let bottom = geometry.bottom
                let w = size.width
                let xPad: CGFloat = 8                       // keep the sun dot off the edges

                func y(_ e: Double) -> CGFloat { geometry.y(for: e) }
                func x(_ t: Double) -> CGFloat { xPad + CGFloat(t) * (w - 2 * xPad) }
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
                    // Same x mapping as the curve, so stop `t` lands under its sample.
                    ctx.fill(area, with: .linearGradient(Gradient(stops: stops),
                                                         startPoint: CGPoint(x: x(0), y: 0),
                                                         endPoint: CGPoint(x: x(1), y: 0)))
                } else {
                    ctx.fill(area, with: .color(.orange.opacity(0.18)))
                }

                // Physical solar-elevation anchors use the exact curve scale. The
                // horizon wins when adjacent guides would crowd this compact chart.
                for guide in geometry.guides() {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: guide.y))
                    line.addLine(to: CGPoint(x: w, y: guide.y))
                    // `.primary` adapts to both Light and Dark Mode.
                    ctx.stroke(line, with: .color(.primary.opacity(guide.isHorizon ? 0.22 : 0.16)),
                               style: StrokeStyle(lineWidth: 1, dash: guide.isHorizon ? [3, 3] : [2, 3]))
                }

                // Curve — single clean stroke.
                ctx.stroke(curve, with: .color(.orange),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // Sun dot — flat fill, thin outline.
                let core: Color = cycle.nowElevation >= 0
                    ? Color(red: 1, green: 0.86, blue: 0.4) : .red
                let dot = CGRect(x: sx - 4, y: sy - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: dot), with: .color(core))
                ctx.stroke(Path(ellipseIn: dot), with: .color(.primary.opacity(0.6)),
                           lineWidth: 0.75)
        }
        .frame(height: 70)
        .accessibilityRepresentation {
            Text(Self.accessibilitySummary(currentElevation: cycle.nowElevation))
        }
    }

    static func accessibilitySummary(currentElevation: Double) -> String {
        "Solar elevation \(degreeLabel(currentElevation))."
    }

    static func degreeLabel(_ elevation: Double) -> String {
        let rounded = Int(elevation.rounded())
        if rounded > 0 { return "+\(rounded)°" }
        if rounded < 0 { return "−\(abs(rounded))°" }
        return "0°"
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
