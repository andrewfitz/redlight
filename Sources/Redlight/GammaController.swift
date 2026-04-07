import CoreGraphics

protocol GammaControlling {
    func applyRedFilter(to displayID: CGDirectDisplayID, intensity: Float)
    func restoreAll()
}

struct GammaController: GammaControlling {
    func applyRedFilter(to displayID: CGDirectDisplayID, intensity: Float) {
        // intensity: 1.0 = normal (no filter), 0.0 = pure red (full filter)
        // Blue drops to zero by the halfway point, green fades linearly.
        // This produces a warm normal → orange → red transition (no purple).
        let green = intensity
        let blue = max(0, intensity * 2 - 1)
        _ = CGSetDisplayTransferByFormula(
            displayID,
            0, 1.0,   1.0,   // red: always full
            0, green,  1.0,   // green: linear fade
            0, blue,   1.0    // blue: gone by 50%, avoids purple
        )
    }

    func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
    }
}
