import SwiftUI

/// A value slider with optional adaptive-band bracket markers, over an arbitrary `range`.
///
/// The round thumb sets the live value (a manual nudge while adaptive is on) and is inset
/// by its radius so it never clips at the ends. When `showBand` is true, two draggable
/// bracket markers set the adaptive min/max band; they map across the full track width, so
/// the range floor sits flush left and the ceiling flush right. The span between them is
/// shaded and the live thumb rides within it.
///
/// A single drag gesture routes to whichever handle (lower marker, upper marker, or thumb)
/// is nearest where the drag began, so the handles never fight for the same hit area. While
/// a marker is dragged, `onPreview` fires with its value so the caller can apply it live;
/// `onPreviewEnd` fires on release so the caller can revert to the real value.
struct BandSlider: View {
    @Binding var value: Double          // live value, within `range`
    @Binding var lowerBound: Double     // adaptive min
    @Binding var upperBound: Double     // adaptive max
    var range: ClosedRange<Double> = 0...1
    var showBand: Bool
    var minGap: Double = 0.05
    var onPreview: ((Double) -> Void)? = nil
    var onPreviewEnd: (() -> Void)? = nil

    @State private var active: Handle?
    private enum Handle { case lower, upper, value }

    private let thumbSize: CGFloat = 18
    private let markerW: CGFloat = 6
    private let markerH: CGFloat = 18
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let midY = geo.size.height / 2
            let valX = thumbPos(value, w)
            let loX = markerPos(lowerBound, w)
            let hiX = markerPos(upperBound, w)
            // Value fill starts at the left bracket when a band is shown (stays within the
            // band); otherwise it runs to the very left edge like a normal slider.
            let fillLeft: CGFloat = showBand ? loX : 0

            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)
                    .position(x: w / 2, y: midY)

                if showBand {
                    Capsule()
                        .fill(Color.red.opacity(0.18))
                        .frame(width: max(0, hiX - loX), height: trackHeight)
                        .position(x: (loX + hiX) / 2, y: midY)
                }

                Capsule()
                    .fill(Color.red.opacity(0.55))
                    .frame(width: max(0, valX - fillLeft), height: trackHeight)
                    .position(x: (fillLeft + valX) / 2, y: midY)

                if showBand {
                    marker.position(x: loX, y: midY)
                    marker.position(x: hiX, y: midY)
                }

                thumb.position(x: valX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let handle = active ?? nearestHandle(toX: g.startLocation.x, w: w)
                        active = handle
                        switch handle {
                        case .lower:
                            let v = min(markerVal(g.location.x, w), upperBound - minGap)
                            lowerBound = v
                            onPreview?(v)
                        case .upper:
                            let v = max(markerVal(g.location.x, w), lowerBound + minGap)
                            upperBound = v
                            onPreview?(v)
                        case .value:
                            value = thumbVal(g.location.x, w)
                        }
                    }
                    .onEnded { _ in
                        if active == .lower || active == .upper { onPreviewEnd?() }
                        active = nil
                    }
            )
        }
        .frame(height: markerH + 8)
    }

    private func nearestHandle(toX x: CGFloat, w: CGFloat) -> Handle {
        guard showBand else { return .value }
        let candidates: [(Handle, CGFloat)] = [
            (.lower, markerPos(lowerBound, w)),
            (.upper, markerPos(upperBound, w)),
            (.value, thumbPos(value, w)),
        ]
        return candidates.min(by: { abs($0.1 - x) < abs($1.1 - x) })!.0
    }

    // MARK: - Value ⇄ position mapping

    private var span: Double { range.upperBound - range.lowerBound }
    private func frac(_ v: Double) -> Double { span > 0 ? clamp01((v - range.lowerBound) / span) : 0 }
    private func unfrac(_ f: Double) -> Double { range.lowerBound + clamp01(f) * span }

    // Thumb: inset by its radius so the circle never clips at the ends.
    private func thumbPos(_ v: Double, _ w: CGFloat) -> CGFloat {
        let usable = max(1, w - thumbSize)
        return CGFloat(frac(v)) * usable + thumbSize / 2
    }
    private func thumbVal(_ px: CGFloat, _ w: CGFloat) -> Double {
        let usable = max(1, w - thumbSize)
        return unfrac(Double((px - thumbSize / 2) / usable))
    }

    // Markers: map across the full track (only ±markerW/2 so the bracket sits flush at
    // each edge), so the range ends are reachable.
    private func markerPos(_ v: Double, _ w: CGFloat) -> CGFloat {
        let usable = max(1, w - markerW)
        return CGFloat(frac(v)) * usable + markerW / 2
    }
    private func markerVal(_ px: CGFloat, _ w: CGFloat) -> Double {
        let usable = max(1, w - markerW)
        return unfrac(Double((px - markerW / 2) / usable))
    }

    private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    // MARK: - Pieces

    private var thumb: some View {
        Circle()
            .fill(.white)
            .frame(width: thumbSize, height: thumbSize)
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5))
            .shadow(radius: 1, y: 0.5)
    }

    private var marker: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.red.opacity(0.9))
            .frame(width: markerW, height: markerH)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
    }
}
