import CoreGraphics

protocol GammaControlling {
    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool)
    func restore(_ displayID: CGDirectDisplayID)
    func restoreAll()
    func displaysDidChange()
}

extension GammaControlling {
    func displaysDidChange() {}
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
    typealias Table = GammaTableComposer.Table
    private let readTable: (CGDirectDisplayID) -> Table?
    private let writeTable: (CGDirectDisplayID, inout Table) -> CGError
    private let resetTables: () -> Void
    private var originalTables: [CGDirectDisplayID: Table] = [:]
    private var modified: Set<CGDirectDisplayID> = []

    init(
        readTable: @escaping (CGDirectDisplayID) -> Table? = GammaController.readCalibration,
        writeTable: @escaping (CGDirectDisplayID, inout Table) -> CGError = { id, table in
            CGSetDisplayTransferByTable(id, UInt32(table.r.count), &table.r, &table.g, &table.b)
        },
        resetTables: @escaping () -> Void = CGDisplayRestoreColorSyncSettings
    ) {
        self.readTable = readTable
        self.writeTable = writeTable
        self.resetTables = resetTables
    }

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
        // A failed initial read uses the identity fallback for this entire session.
        // Once a write succeeds, a later read would capture our own filtered table.
        let original = modified.contains(displayID) ? originalTables[displayID] : readTable(displayID)

        let tableSize = 256
        var table = GammaTableComposer.compose(
            original: original, tableSize: tableSize,
            intensity: intensity, whitepoint: whitepoint, invert: invert
        )

        if writeTable(displayID, &table) == .success {
            modified.insert(displayID)
            originalTables[displayID] = original
        }
    }

    func restore(_ displayID: CGDirectDisplayID) {
        guard modified.contains(displayID) else { return }   // never touched → no-op
        // Writing the captured table back via `CGSetDisplayTransferByTable` does not fully
        // reinstall ColorSync on some third-party monitors after a link retrain. When this
        // is the last display we own, ColorSync-restore everything — the same call Quit uses.
        if modified == [displayID] {
            restoreAll()
            return
        }
        var table = originalTables[displayID] ?? GammaTableComposer.compose(
            original: nil, intensity: 1, whitepoint: 1, invert: false)
        if writeTable(displayID, &table) == .success {
            modified.remove(displayID)
            originalTables.removeValue(forKey: displayID)
        }
    }

    func restoreAll() {
        originalTables.removeAll()
        modified.removeAll()
        resetTables()
    }

    /// Snapshot the display's untouched gamma table once, before we first modify it.
    /// Dropped again on restore so a later session re-captures fresh calibration.
    private static func readCalibration(_ displayID: CGDirectDisplayID) -> Table? {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = [CGGammaValue](repeating: 0, count: Int(capacity))
        var b = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &r, &g, &b, &sampleCount) == .success,
              sampleCount > 0, sampleCount <= capacity else { return nil }
        let n = Int(sampleCount)
        return (Array(r[..<n]), Array(g[..<n]), Array(b[..<n]))
    }
}
