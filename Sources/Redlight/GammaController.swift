import CoreGraphics

protocol GammaControlling {
    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool)
    func restore(_ displayID: CGDirectDisplayID)
    func restoreAll()
}

/// Builds Redlight's transfer table on top of the display's existing ColorSync table.
/// Keeping this pure makes the calibration-composition rules testable without touching a
/// real display. The source table can have any sample count; it is linearly resampled to
/// the transfer-table size requested by Core Graphics.
enum GammaTableComposer {
    typealias Table = (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])

    static func compose(
        original: Table?, tableSize: Int = 256,
        intensity: Float, whitepoint: Float, invert: Bool
    ) -> Table {
        precondition(tableSize > 1)
        let redMax: Float = 1
        let greenMax = intensity
        let blueMax = max(0, intensity * 2 - 1)
        var result: Table = (
            [CGGammaValue](repeating: 0, count: tableSize),
            [CGGammaValue](repeating: 0, count: tableSize),
            [CGGammaValue](repeating: 0, count: tableSize)
        )

        for i in 0..<tableSize {
            let x = Float(i) / Float(tableSize - 1)
            let input = invert ? 1 - x : x
            let baseR = sample(original?.r, at: input) ?? input
            let baseG = sample(original?.g, at: input) ?? input
            let baseB = sample(original?.b, at: input) ?? input
            result.r[i] = redMax * whitepointCurve(baseR, whitepoint: whitepoint)
            result.g[i] = greenMax * whitepointCurve(baseG, whitepoint: whitepoint)
            result.b[i] = blueMax * whitepointCurve(baseB, whitepoint: whitepoint)
        }
        return result
    }

    private static func sample(_ table: [CGGammaValue]?, at position: Float) -> Float? {
        guard let table, !table.isEmpty else { return nil }
        guard table.count > 1 else { return table[0] }
        let p = min(1, max(0, position)) * Float(table.count - 1)
        let lower = Int(p.rounded(.down))
        let upper = min(table.count - 1, lower + 1)
        let fraction = p - Float(lower)
        return table[lower] + (table[upper] - table[lower]) * fraction
    }

    private static func whitepointCurve(_ base: Float, whitepoint: Float) -> Float {
        let oneMinusBase = 1 - base
        return base * (whitepoint + (1 - whitepoint) * oneMinusBase * oneMinusBase)
    }
}

/// Owns the display gamma tables. Before the first modification of a display it snapshots
/// that display's current (ColorSync-calibrated) table, so `restore(_:)` can put the real
/// calibration back per display instead of blowing it away with an identity ramp — and
/// without `CGDisplayRestoreColorSyncSettings()`, which would reset every display at once.
/// `restore(_:)` on a display we never modified is a no-op, so repeatedly re-applying
/// state (every slider tick loops all displays) can't degrade untouched displays.
final class GammaController: GammaControlling {
    private var originalTables: [CGDirectDisplayID: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])] = [:]
    private var modified: Set<CGDirectDisplayID> = []

    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool) {
        // A neutral request means relinquish the table entirely, preserving ColorSync and
        // making this safe even if a caller forgets to special-case the neutral tuple.
        guard intensity != 1 || whitepoint != 1 || invert else {
            restore(displayID)
            return
        }

        // intensity: 1.0 = normal (no filter), 0.0 = pure red (full filter)
        // whitepoint: 1.0 = full brightness, 0.25 = heavy white reduction.
        // Note: all channels (red included) are scaled by `curve`, which peaks at `whitepoint`,
        // so reducing the white point also dims red — i.e. it lowers overall brightness.
        // invert: when true, remap input x → 1−x first (the innermost layer).
        // Uses a lookup table so darks are barely affected while bright
        // areas absorb most of the whitepoint reduction.
        captureOriginalIfNeeded(displayID)
        modified.insert(displayID)

        let tableSize = 256
        var table = GammaTableComposer.compose(
            original: originalTables[displayID], tableSize: tableSize,
            intensity: intensity, whitepoint: whitepoint, invert: invert
        )

        CGSetDisplayTransferByTable(
            displayID, UInt32(tableSize), &table.r, &table.g, &table.b)
    }

    func restore(_ displayID: CGDirectDisplayID) {
        guard modified.remove(displayID) != nil else { return }   // never touched → no-op
        if var t = originalTables.removeValue(forKey: displayID) {
            CGSetDisplayTransferByTable(displayID, UInt32(t.r.count), &t.r, &t.g, &t.b)
        } else {
            // Snapshot capture failed: fall back to a plain identity ramp, still per-display.
            let n = 256
            var r = [CGGammaValue](repeating: 0, count: n)
            var g = [CGGammaValue](repeating: 0, count: n)
            var b = [CGGammaValue](repeating: 0, count: n)
            for i in 0..<n {
                let x = CGGammaValue(Float(i) / Float(n - 1))
                r[i] = x; g[i] = x; b[i] = x
            }
            CGSetDisplayTransferByTable(displayID, UInt32(n), &r, &g, &b)
        }
    }

    func restoreAll() {
        originalTables.removeAll()
        modified.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    /// Snapshot the display's untouched gamma table once, before we first modify it.
    /// Dropped again on restore so a later session re-captures fresh calibration.
    private func captureOriginalIfNeeded(_ displayID: CGDirectDisplayID) {
        guard originalTables[displayID] == nil else { return }
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0 else { return }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = [CGGammaValue](repeating: 0, count: Int(capacity))
        var b = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &r, &g, &b, &sampleCount) == .success,
              sampleCount > 0 else { return }
        let n = Int(sampleCount)
        originalTables[displayID] = (Array(r[..<n]), Array(g[..<n]), Array(b[..<n]))
    }
}
