import Foundation

/// Maps sun elevation to the adaptive filter target, normalized into the user's intensity and
/// white-point bands (Day → max, deepest night → min). Shared by the live filter
/// (`DisplayManager.applyAdaptive`) and the sun-arc graphic, so both stay in sync.
enum AdaptiveMapping {
    static func banded(
        elevation: Double, minElevation: Double, presets: [Preset],
        intensityMin: Double, intensityMax: Double,
        whitepointMin: Double, whitepointMax: Double
    ) -> (intensity: Double, whitepoint: Double) {
        let t = SolarCurve.target(elevation: elevation, minElevation: minElevation, presets: presets)
        guard presets.count >= 5 else { return t }

        let iLo = min(intensityMin, intensityMax), iHi = max(intensityMin, intensityMax)
        let wLo = min(whitepointMin, whitepointMax), wHi = max(whitepointMin, whitepointMax)
        return (remap(t.intensity, day: presets[0].intensity, deep: presets[4].intensity, lo: iLo, hi: iHi),
                remap(t.whitepoint, day: presets[0].whitepoint, deep: presets[4].whitepoint, lo: wLo, hi: wHi))
    }

    /// Normalize a curve value from its Day…Deep Red anchors onto the band. When the user
    /// has saved identical anchors (a flat curve) there is no fraction to take — fall back
    /// to clamping the raw value into the band instead of pinning to either end.
    private static func remap(_ v: Double, day: Double, deep: Double, lo: Double, hi: Double) -> Double {
        guard day != deep else { return min(hi, max(lo, v)) }
        let frac = min(1, max(0, (v - deep) / (day - deep)))
        return lo + (hi - lo) * frac
    }
}
