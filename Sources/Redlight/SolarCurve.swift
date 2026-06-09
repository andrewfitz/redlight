import Foundation

/// Maps sun elevation to a filter target by interpolating across the preset ladder:
/// Day (sun up) → Night (civil dusk, −6°) → Deep Red (solar midnight, `minElevation`).
enum SolarCurve {
    static func target(elevation: Double, minElevation: Double, presets: [Preset])
        -> (intensity: Double, whitepoint: Double)
    {
        guard presets.count >= 5 else { return (1.0, 1.0) }
        let day = presets[0], night = presets[3], deep = presets[4]

        if elevation >= 0 {
            return (day.intensity, day.whitepoint)
        } else if elevation >= -6 {
            let f = ease(-elevation / 6)            // 0 at horizon → 1 at civil dusk
            return lerp(day, night, f)
        } else {
            let denom = (-minElevation) - 6         // depth of night below civil
            guard denom > 0 else { return (night.intensity, night.whitepoint) }
            let f = ease(min(1, max(0, (-elevation - 6) / denom)))
            return lerp(night, deep, f)
        }
    }

    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    private static func lerp(_ a: Preset, _ b: Preset, _ f: Double)
        -> (intensity: Double, whitepoint: Double)
    {
        (a.intensity + (b.intensity - a.intensity) * f,
         a.whitepoint + (b.whitepoint - a.whitepoint) * f)
    }
}
