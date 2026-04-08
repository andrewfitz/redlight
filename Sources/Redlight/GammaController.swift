import CoreGraphics

protocol GammaControlling {
    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float)
    func restoreAll()
}

struct GammaController: GammaControlling {
    func applyFilter(to displayID: CGDirectDisplayID, intensity: Float, whitepoint: Float) {
        // intensity: 1.0 = normal (no filter), 0.0 = pure red (full filter)
        // whitepoint: 1.0 = full brightness, 0.25 = heavy white reduction
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
            // curve(0)=0, curve(1)=wp, darks ≈ x, whites compressed
            let oneMinusX = 1 - x
            let curve = x * (wp + (1 - wp) * oneMinusX * oneMinusX)
            r[i] = redMax * curve
            g[i] = greenMax * curve
            b[i] = blueMax * curve
        }

        CGSetDisplayTransferByTable(displayID, UInt32(tableSize), &r, &g, &b)
    }

    func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
    }
}
