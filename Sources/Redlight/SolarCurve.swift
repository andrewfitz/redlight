import Foundation

/// Maps real solar elevation to the adaptive filter target. The named presets line up with
/// what is happening outdoors: the gentle ramp begins while the sun is still up, reaches
/// Warm during golden hour, Sunset at the horizon, Night at astronomical dusk, then eases
/// toward Late until solar midnight. Dawn mirrors dusk below the horizon; after sunrise
/// the screen clears quickly, reaching Day once the sun is a few degrees up.
///
/// Every day reaches Day at solar noon and Late at solar midnight, and the curve has no
/// step at either. Where the sun's own range does not cover the anchors (high-latitude
/// summer and winter) the anchors move to meet it; see `target`.
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

    /// Where the sun's centre is at the sunrise and sunset an almanac gives: 34′ of
    /// refraction at the horizon plus the sun's 16′ radius. The clock times under the sun
    /// arc, the countdown and "Until sunrise" use it. The curve's Sunset anchor and the
    /// horizon drawn on the arc stay at the geometric 0°.
    static let apparentHorizonElevation = -0.833

    // Morning above-horizon anchors: Day by +4°, roughly 20–35 minutes after sunrise at
    // mid-latitudes, instead of mirroring the slow evening ramp from +12°.
    static let morningDayElevation = 4.0
    static let morningWarmElevation = 2.0

    /// Where a short night's lowest point is mapped. Nights whose sun never sinks this far
    /// (high-latitude summer) are stretched so solar midnight still reaches Late; at
    /// −24° the stretch is 1, so the curve is continuous as nights lengthen.
    static let shortNightFloor = -24.0

    /// The shallowest night that is stretched. Where the sun stays above this at solar
    /// midnight (white nights and the midnight sun) the whole curve slides up instead, so
    /// the lowest point reads as this and the stretch never exceeds 4. Sliding is
    /// continuous from one night to the next; stretching alone was not, at the horizon.
    static let shallowNightElevation = -6.0

    /// The sun's elevation at a noon high enough for the fixed anchors: the default for
    /// callers that have no real day, such as the preset anchors' own tests.
    static let highNoon = 90.0

    static let elevationMarkers: [ElevationMarker] = [
        ElevationMarker(label: "Day", elevation: dayElevation),
        ElevationMarker(label: "Warm", elevation: warmElevation),
        ElevationMarker(label: "Sunset", elevation: sunsetElevation),
        ElevationMarker(label: "Civil", elevation: civilDuskElevation),
        ElevationMarker(label: "Nautical", elevation: nauticalDuskElevation),
        ElevationMarker(label: "Night", elevation: nightElevation),
    ]

    /// `rising` selects the morning side of the cycle (solar midnight → solar noon).
    /// `minElevation` and `maxElevation` are the sun's elevation at solar midnight and at
    /// solar noon that day. They move the anchors in three cases:
    ///
    /// - A noon below +12° brings the evening's Day anchor down to it (never below the
    ///   morning's +4°), so morning and evening agree at solar noon.
    /// - A noon below +4° (polar winter) slides the curve down, so noon still reaches Day.
    /// - A midnight above −6° slides the curve up, so midnight still reaches Late.
    static func target(elevation: Double, minElevation: Double, maxElevation: Double = highNoon,
                       rising: Bool = false, presets: [Preset])
        -> (intensity: Double, whitepoint: Double)
    {
        guard presets.count >= 5 else { return (1.0, 1.0) }
        let phase = phase(elevation: elevation, minElevation: minElevation,
                          maxElevation: maxElevation, rising: rising)
        let values = anchorValues(presets: presets)
        return lerp(values[phase.from.kind], values[phase.to.kind], phase.fraction)
    }

    /// A point of the curve that a learned adjustment can belong to. Day and Late are shared
    /// by the two halves of the cycle; the five between them exist once for the evening and
    /// once for the morning, where the same values fall at different times and elevations.
    enum Anchor: Int, CaseIterable, Codable, Sendable {
        case day = 0
        case eveningWarm, eveningSunset, eveningCivil, eveningNautical, eveningNight
        case late
        case morningWarm, morningSunset, morningCivil, morningNautical, morningNight

        /// Index into `anchorValues`: Day, Warm, Sunset, Civil, Nautical, Night, Late.
        var kind: Int { rawValue <= Anchor.late.rawValue ? rawValue : rawValue - Anchor.late.rawValue }
        var isMorning: Bool { rawValue > Anchor.late.rawValue }
    }

    /// Where the sun is between two anchors of the curve. `fraction` is already eased:
    /// 0 is all `from`, 1 is all `to`. On an anchor, and above Day, both ends are that anchor.
    struct Phase: Equatable, Sendable {
        let from: Anchor
        let to: Anchor
        let fraction: Double

        /// The one or two anchors around the sun and their shares, which add up to 1.
        var weights: [(anchor: Anchor, weight: Double)] {
            if from == to || fraction <= 0 { return [(from, 1)] }
            if fraction >= 1 { return [(to, 1)] }
            return [(from, 1 - fraction), (to, fraction)]
        }

        /// The anchor with the larger share; `from` when they are equal.
        var lead: Anchor { fraction > 0.5 ? to : from }
    }

    /// The anchors around a sun elevation, with the same moves `target` documents: the two
    /// slides, the short-night stretch and the evening's moving Day anchor.
    static func phase(elevation: Double, minElevation: Double, maxElevation: Double = highNoon,
                      rising: Bool = false) -> Phase
    {
        // Within a few degrees of the poles both slides apply and the sun's whole range is
        // narrower than the curve: the result stays continuous but covers only part of it.
        let slide = max(0, morningDayElevation - maxElevation)
            - max(0, minElevation - shallowNightElevation)
        var elevation = elevation + slide
        var minElevation = minElevation + slide
        let maxElevation = maxElevation + slide
        if elevation < 0, minElevation < 0, minElevation > shortNightFloor {
            elevation *= shortNightFloor / minElevation
            minElevation = shortNightFloor
        }

        if rising, elevation >= sunsetElevation {
            if elevation >= morningDayElevation { return Phase(from: .day, to: .day, fraction: 0) }
            if elevation >= morningWarmElevation {
                return Phase(from: .day, to: .morningWarm,
                             fraction: segment(elevation, from: morningDayElevation, to: morningWarmElevation))
            }
            return Phase(from: .morningWarm, to: .morningSunset,
                         fraction: segment(elevation, from: morningWarmElevation, to: sunsetElevation))
        }

        // Below the horizon dawn mirrors dusk, on the morning's own anchors.
        let warm: Anchor = rising ? .morningWarm : .eveningWarm
        let sunset: Anchor = rising ? .morningSunset : .eveningSunset
        let civil: Anchor = rising ? .morningCivil : .eveningCivil
        let nautical: Anchor = rising ? .morningNautical : .eveningNautical
        let night: Anchor = rising ? .morningNight : .eveningNight

        // At +12° and +4° these are the fixed evening and morning anchors.
        let eveningDay = min(dayElevation, max(morningDayElevation, maxElevation))
        let eveningWarm = eveningDay / 2
        if elevation >= eveningDay {
            return Phase(from: .day, to: .day, fraction: 0)
        } else if elevation >= eveningWarm {
            return Phase(from: .day, to: warm,
                         fraction: segment(elevation, from: eveningDay, to: eveningWarm))
        } else if elevation >= sunsetElevation {
            return Phase(from: warm, to: sunset,
                         fraction: segment(elevation, from: eveningWarm, to: sunsetElevation))
        } else if elevation >= civilDuskElevation {
            return Phase(from: sunset, to: civil,
                         fraction: segment(elevation, from: sunsetElevation, to: civilDuskElevation))
        } else if elevation >= nauticalDuskElevation {
            return Phase(from: civil, to: nautical,
                         fraction: segment(elevation, from: civilDuskElevation, to: nauticalDuskElevation))
        } else if elevation >= nightElevation {
            return Phase(from: nautical, to: night,
                         fraction: segment(elevation, from: nauticalDuskElevation, to: nightElevation))
        } else {
            let denom = nightElevation - minElevation
            guard denom > 0 else { return Phase(from: night, to: night, fraction: 0) }
            return Phase(from: night, to: .late, fraction: ease((nightElevation - elevation) / denom))
        }
    }

    /// The curve's values at Day, Warm, Sunset, Civil, Nautical, Night and Late, by
    /// `Anchor.kind`. Needs the five presets.
    static func anchorValues(presets: [Preset]) -> [(intensity: Double, whitepoint: Double)] {
        let day = values(presets[0]), warm = values(presets[1]), sunset = values(presets[2])
        let night = values(presets[3]), deep = values(presets[4])
        // The intermediate twilight values preserve a smooth Sunset…Night progression while
        // making the physical −6° and −12° boundaries real easing anchors in the curve.
        let civil = lerp(sunset, night, 1.0 / 3.0)
        let nautical = lerp(sunset, night, 2.0 / 3.0)
        return [day, warm, sunset, civil, nautical, night, deep]
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

    /// Quadratic ease-in-out, clamped to [0, 1].
    private static func ease(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        let remaining = 1 - c
        return c < 0.5 ? 2 * c * c : 1 - 2 * remaining * remaining
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
        if f == 0 { return a }
        if f == 1 { return b }
        return (a.intensity + (b.intensity - a.intensity) * f,
                a.whitepoint + (b.whitepoint - a.whitepoint) * f)
    }
}
