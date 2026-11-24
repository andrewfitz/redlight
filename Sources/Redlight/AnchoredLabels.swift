import CoreGraphics

/// Placement of short labels that hang under points on a row: the sunrise and sunset times
/// under the sun arc.
enum AnchoredLabels {
    /// Leading x of one label centred on `anchor` and kept inside `0…row`.
    static func origin(anchor: CGFloat, width: CGFloat, row: CGFloat) -> CGFloat {
        min(max(0, row - width), max(0, anchor - width / 2))
    }

    /// Leading xs of two labels, `first` hanging at or before `second`. Each is centred on its
    /// anchor when there is room. If they would come closer than `gap` they move apart
    /// evenly, and if that pushes one off an end of the row the pair slides back in.
    /// Labels too wide to share the row overlap from its two ends.
    static func origins(
        first: (anchor: CGFloat, width: CGFloat), second: (anchor: CGFloat, width: CGFloat),
        row: CGFloat, gap: CGFloat
    ) -> (first: CGFloat, second: CGFloat) {
        var a = origin(anchor: first.anchor, width: first.width, row: row)
        var b = origin(anchor: second.anchor, width: second.width, row: row)
        let overlap = a + first.width + gap - b
        guard overlap > 0 else { return (a, b) }
        a -= overlap / 2
        b += overlap / 2
        if a < 0 {
            b -= a
            a = 0
        }
        let overflow = b + second.width - row
        if overflow > 0 {
            b = max(0, b - overflow)
            a = max(0, a - overflow)
        }
        return (a, b)
    }
}
