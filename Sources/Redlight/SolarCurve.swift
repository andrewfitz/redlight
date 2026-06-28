import Foundation

/// Maps sun elevation to a filter target across the standard astronomical twilight phases,
/// driven entirely by `SolarCalculator` elevation (location/date/time). Eased per segment:
///   Day (≥0°) → Warm (civil dusk, −6°) → Sunset (nautical, −12°)
///   → Night (astronomical, −18°) → Deep Red (solar midnight).
/// Dawn mirrors dusk automatically — elevation is the only input.
enum SolarCurve {
    static func target(elevation: Double, minElevation: Double, presets: [Preset])
        -> (intensity: Double, whitepoint: Double)
    {
        guard presets.count >= 5 else { return (1.0, 1.0) }
        let day = presets[0], warm = presets[1], sunset = presets[2]
        let night = presets[3], deep = presets[4]

        if elevation >= 0 {
            return (day.intensity, day.whitepoint)              // day
        } else if elevation >= -6 {
            return lerp(day, warm, ease(-elevation / 6))        // civil twilight
        } else if elevation >= -12 {
            return lerp(warm, sunset, ease((-elevation - 6) / 6))   // nautical twilight
        } else if elevation >= -18 {
            return lerp(sunset, night, ease((-elevation - 12) / 6)) // astronomical twilight
        } else {
            let denom = (-minElevation) - 18                    // depth below astronomical night
            guard denom > 0 else { return (night.intensity, night.whitepoint) }
            return lerp(night, deep, ease((-elevation - 18) / denom))
        }
    }

    /// Smoothstep, clamped to [0, 1].
    private static func ease(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2
    }

    private static func lerp(_ a: Preset, _ b: Preset, _ f: Double)
        -> (intensity: Double, whitepoint: Double)
    {
        (a.intensity + (b.intensity - a.intensity) * f,
         a.whitepoint + (b.whitepoint - a.whitepoint) * f)
    }
}
