import CoreGraphics

// `CGDisplayForceToGray` ships in CoreGraphics (present in the .tbd / framework) but
// has no public header, so the Swift overlay doesn't expose it. Bind the existing C
// symbol directly. `boolean_t` is a C `int`, i.e. `Int32`.
@_silgen_name("CGDisplayForceToGray")
func CGDisplayForceToGray(_ forceToGray: Int32) -> Int32

protocol GammaControlling {
    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool)
    func restore(_ displayID: CGDirectDisplayID)
    func restoreAll()
    func setGrayscale(_ on: Bool)
}

struct GammaController: GammaControlling {
    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool) {
        // intensity: 1.0 = normal (no filter), 0.0 = pure red (full filter)
        // whitepoint: 1.0 = full brightness, 0.25 = heavy white reduction
        // invert: when true, remap input x → 1−x first (the innermost layer).
        // Uses a lookup table so darks are barely affected while bright
        // areas absorb most of the whitepoint reduction.
        let redMax: Float = 1.0
        let greenMax = intensity
        let blueMax = max(0, intensity * 2 - 1)

        let tableSize = 256
        var r = [CGGammaValue](repeating: 0, count: tableSize)
        var g = [CGGammaValue](repeating: 0, count: tableSize)
        var b = [CGGammaValue](repeating: 0, count: tableSize)

        let wp = whitepoint
        for i in 0..<tableSize {
            let x = Float(i) / Float(tableSize - 1)
            let base = invert ? (1 - x) : x        // invert = innermost layer
            // curve(0)=0, curve(1)=wp, darks ≈ base, whites compressed
            let oneMinusBase = 1 - base
            let curve = base * (wp + (1 - wp) * oneMinusBase * oneMinusBase)
            r[i] = redMax * curve
            g[i] = greenMax * curve
            b[i] = blueMax * curve
        }

        CGSetDisplayTransferByTable(displayID, UInt32(tableSize), &r, &g, &b)
    }

    func restore(_ displayID: CGDirectDisplayID) {
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

    func restoreAll() {
        _ = CGDisplayForceToGray(0)
        CGDisplayRestoreColorSyncSettings()
    }

    func setGrayscale(_ on: Bool) {
        _ = CGDisplayForceToGray(on ? 1 : 0)
    }
}
