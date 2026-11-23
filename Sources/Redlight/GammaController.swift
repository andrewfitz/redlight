import CoreGraphics

protocol GammaControlling {
    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool)
    func restore(_ displayID: CGDirectDisplayID)
    func restoreAll()
    func resetForDisplayRecovery()
    func displaysDidChange()
}

extension GammaControlling {
    func resetForDisplayRecovery() { restoreAll() }
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
        let source = resample(original: original, tableSize: tableSize, invert: invert)
        var result = makeTable(size: tableSize)
        render(source, intensity: intensity, whitepoint: whitepoint, into: &result)
        return result
    }

    static func makeTable(size: Int) -> Table {
        let channel = [CGGammaValue](repeating: 0, count: size)
        return (channel, channel, channel)
    }

    static func resample(original: Table?, tableSize: Int, invert: Bool) -> Table {
        precondition(tableSize > 1)
        let positions = (0..<tableSize).map { i in
            let x = Float(i) / Float(tableSize - 1)
            return invert ? 1 - x : x
        }
        guard let original else { return (positions, positions, positions) }
        return (
            positions.map { sample(original.r, at: $0) },
            positions.map { sample(original.g, at: $0) },
            positions.map { sample(original.b, at: $0) }
        )
    }

    static func render(_ source: Table, intensity: Float, whitepoint: Float, into result: inout Table) {
        renderChannel(source.r, whitepoint: whitepoint, gain: 1, into: &result.r)
        renderChannel(source.g, whitepoint: whitepoint, gain: intensity, into: &result.g)
        renderChannel(source.b, whitepoint: whitepoint, gain: max(0, intensity * 2 - 1), into: &result.b)
    }

    private static func sample(_ table: [CGGammaValue], at position: Float) -> Float {
        guard !table.isEmpty else { return position }
        guard table.count > 1 else { return table[0] }
        let p = position * Float(table.count - 1)
        let lower = Int(p.rounded(.down))
        let upper = min(table.count - 1, lower + 1)
        let fraction = p - Float(lower)
        return table[lower] + (table[upper] - table[lower]) * fraction
    }

    private static func renderChannel(
        _ source: [CGGammaValue], whitepoint: Float, gain: Float, into result: inout [CGGammaValue]
    ) {
        let reduction = 1 - whitepoint
        result.withUnsafeMutableBufferPointer { result in
            for i in result.indices {
                let base = source[i]
                let oneMinusBase = 1 - base
                result[i] = gain * (base * (whitepoint + reduction * oneMinusBase * oneMinusBase))
            }
        }
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
    private struct Calibration {
        let original: Table?
        let sampled: Table
        let isInverted: Bool
    }

    private static let tableSize = 256
    private static let identity = GammaTableComposer.resample(original: nil, tableSize: tableSize, invert: false)
    private static let invertedIdentity = GammaTableComposer.resample(original: nil, tableSize: tableSize, invert: true)

    private let readTable: (CGDirectDisplayID) -> Table?
    private let writeTable: (CGDirectDisplayID, Table) -> CGError
    private let resetTables: () -> Void
    private var calibrations: [CGDirectDisplayID: Calibration] = [:]
    private var outputs: [Int: Table] = [:]

    init(
        readTable: @escaping (CGDirectDisplayID) -> Table? = GammaController.readCalibration,
        writeTable: @escaping (CGDirectDisplayID, Table) -> CGError = { id, table in
            CGSetDisplayTransferByTable(id, UInt32(table.r.count), table.r, table.g, table.b)
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
        let cached = calibrations[displayID]
        let calibration: Calibration
        if let cached, cached.isInverted == invert {
            calibration = cached
        } else {
            let original = if let cached { cached.original } else { readTable(displayID) }
            let sampled = if let original {
                invert ? Table(r: Array(original.r.reversed()), g: Array(original.g.reversed()),
                               b: Array(original.b.reversed())) : original
            } else {
                invert ? Self.invertedIdentity : Self.identity
            }
            calibration = Calibration(original: original, sampled: sampled, isInverted: invert)
        }
        let size = calibration.sampled.r.count
        GammaTableComposer.render(calibration.sampled, intensity: intensity, whitepoint: whitepoint,
                                  into: &outputs[size, default: GammaTableComposer.makeTable(size: size)])
        guard let output = outputs[size] else { return }
        if writeTable(displayID, output) == .success, cached?.isInverted != invert {
            calibrations[displayID] = calibration
        }
    }

    func restore(_ displayID: CGDirectDisplayID) {
        guard let calibration = calibrations[displayID] else { return }
        // Writing the captured table back via `CGSetDisplayTransferByTable` does not fully
        // reinstall ColorSync on some third-party monitors after a link retrain. When this
        // is the last display we own, ColorSync-restore everything — the same call Quit uses.
        if calibrations.count == 1 {
            restoreAll()
            return
        }
        if writeTable(displayID, calibration.original ?? Self.identity) == .success {
            calibrations.removeValue(forKey: displayID)
        }
    }

    func restoreAll() {
        guard !calibrations.isEmpty else { return }
        resetForDisplayRecovery()
    }

    func resetForDisplayRecovery() {
        calibrations.removeAll()
        outputs.removeAll()
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
        let unused = Int(capacity - sampleCount)
        r.removeLast(unused)
        g.removeLast(unused)
        b.removeLast(unused)
        return (r, g, b)
    }
}
