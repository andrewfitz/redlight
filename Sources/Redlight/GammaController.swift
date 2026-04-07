import CoreGraphics

protocol GammaControlling {
    func applyRedFilter(to displayID: CGDirectDisplayID, intensity: Float)
    func restoreAll()
}

struct GammaController: GammaControlling {
    func applyRedFilter(to displayID: CGDirectDisplayID, intensity: Float) {
        _ = CGSetDisplayTransferByFormula(
            displayID,
            0, intensity, 1.0,   // red: ramp from 0 to intensity
            0, 0,         1.0,   // green: zeroed
            0, 0,         1.0    // blue: zeroed
        )
    }

    func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
    }
}
