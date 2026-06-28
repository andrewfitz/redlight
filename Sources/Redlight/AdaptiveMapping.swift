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

        let dayI = presets[0].intensity, deepI = presets[4].intensity
        let dayW = presets[0].whitepoint, deepW = presets[4].whitepoint
        let fracI = dayI != deepI ? (t.intensity - deepI) / (dayI - deepI) : 1
        let fracW = dayW != deepW ? (t.whitepoint - deepW) / (dayW - deepW) : 1

        let iLo = min(intensityMin, intensityMax), iHi = max(intensityMin, intensityMax)
        let wLo = min(whitepointMin, whitepointMax), wHi = max(whitepointMin, whitepointMax)
        return (iLo + (iHi - iLo) * clamp01(fracI),
                wLo + (wHi - wLo) * clamp01(fracW))
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}
