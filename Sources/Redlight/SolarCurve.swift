import Foundation

/// Maps real solar elevation to the adaptive filter target. The named presets line up with
/// what is happening outdoors: the gentle ramp begins while the sun is still up, reaches
/// Warm during golden hour, Sunset at the horizon, Night at astronomical dusk, then eases
/// toward Deep Red until solar midnight. Dawn mirrors dusk automatically.
enum SolarCurve {
    struct ElevationMarker: Identifiable, Sendable {
        let label: String
        let elevation: Double
        var id: Double { elevation }
    }

    // Fixed, real-world solar-elevation anchors used by both the curve and the sun graphic.
    // Civil and nautical dusk split the longer Sunset…Night leg into gently eased segments.
    static let dayElevation = 12.0
    static let warmElevation = 6.0
    static let sunsetElevation = 0.0
    static let civilDuskElevation = -6.0
    static let nauticalDuskElevation = -12.0
    static let nightElevation = -18.0

    static let elevationMarkers: [ElevationMarker] = [
        ElevationMarker(label: "Day", elevation: dayElevation),
        ElevationMarker(label: "Warm", elevation: warmElevation),
        ElevationMarker(label: "Sunset", elevation: sunsetElevation),
        ElevationMarker(label: "Civil", elevation: civilDuskElevation),
        ElevationMarker(label: "Nautical", elevation: nauticalDuskElevation),
        ElevationMarker(label: "Night", elevation: nightElevation),
    ]

    static func target(elevation: Double, minElevation: Double, presets: [Preset])
        -> (intensity: Double, whitepoint: Double)
    {
        guard presets.count >= 5 else { return (1.0, 1.0) }
        let day = values(presets[0]), warm = values(presets[1]), sunset = values(presets[2])
        let night = values(presets[3]), deep = values(presets[4])

        // The intermediate twilight values preserve a smooth Sunset…Night progression while
        // making the physical −6° and −12° boundaries real easing anchors in the curve.
        let civil = lerp(sunset, night, 1.0 / 3.0)
        let nautical = lerp(sunset, night, 2.0 / 3.0)

        if elevation >= dayElevation {
            return day
        } else if elevation >= warmElevation {
            return lerp(day, warm, segment(elevation, from: dayElevation, to: warmElevation))
        } else if elevation >= sunsetElevation {
            return lerp(warm, sunset, segment(elevation, from: warmElevation, to: sunsetElevation))
        } else if elevation >= civilDuskElevation {
            return lerp(sunset, civil, segment(elevation, from: sunsetElevation, to: civilDuskElevation))
        } else if elevation >= nauticalDuskElevation {
            return lerp(civil, nautical, segment(elevation, from: civilDuskElevation, to: nauticalDuskElevation))
        } else if elevation >= nightElevation {
            return lerp(nautical, night, segment(elevation, from: nauticalDuskElevation, to: nightElevation))
        } else {
            let denom = nightElevation - minElevation
            guard denom > 0 else { return (night.intensity, night.whitepoint) }
            return lerp(night, deep, ease((nightElevation - elevation) / denom))
        }
    }

    static func phaseLabel(elevation: Double) -> String {
        if elevation >= dayElevation { return "day" }
        if elevation >= warmElevation { return "low sun" }
        if elevation >= sunsetElevation { return "golden hour" }
        if elevation >= civilDuskElevation { return "civil twilight" }
        if elevation >= nauticalDuskElevation { return "nautical twilight" }
        if elevation >= nightElevation { return "astronomical twilight" }
        return "night"
    }

    private static func segment(_ elevation: Double, from upper: Double, to lower: Double) -> Double {
        ease((upper - elevation) / (upper - lower))
    }

    /// Smoothstep, clamped to [0, 1].
    private static func ease(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2
    }

    private static func values(_ preset: Preset) -> (intensity: Double, whitepoint: Double) {
        (preset.intensity, preset.whitepoint)
    }

    private static func lerp(
        _ a: (intensity: Double, whitepoint: Double),
        _ b: (intensity: Double, whitepoint: Double), _ f: Double
    )
        -> (intensity: Double, whitepoint: Double)
    {
        (a.intensity + (b.intensity - a.intensity) * f,
         a.whitepoint + (b.whitepoint - a.whitepoint) * f)
    }
}
