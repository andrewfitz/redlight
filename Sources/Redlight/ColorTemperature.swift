import AppKit
import SwiftUI

/// How the popover writes Color temp: as a percent of the slider, or as the colour
/// temperature the displays show, in kelvin.
enum ColorTempUnit: String, CaseIterable, Sendable {
    case percent
    case kelvin
}

/// The chosen unit, kept in the defaults.
@MainActor
@Observable
final class ColorTempPreference {
    static let key = "redlight.colorTempUnit"

    var unit: ColorTempUnit {
        didSet { defaults.set(unit.rawValue, forKey: Self.key) }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unit = defaults.string(forKey: Self.key).flatMap(ColorTempUnit.init) ?? .percent
    }
}

/// The colour temperature, in kelvin, that each whole percent of Color temp gives on one display.
///
/// Color temp keeps red at full, scales green by its value and blue twice as fast, on the
/// display's own output curve. That colour, the display's white with those gains, is taken to
/// CIE XYZ through the display's ColorSync profile, absolutely, so the display's own white
/// counts and is not adapted to the profile connection space's D50. Its correlated colour
/// temperature is the temperature of the nearest point on the blackbody curve in the CIE 1960
/// uv diagram: Krystek's approximation from 1,000 to 15,000 K, and below 1,000 K, where it
/// drifts, Planck's law summed over the CIE 1931 colour matching functions.
///
/// 100% is the display's white: D65, about 6,500 K, on a standard or Apple display. 0% is the
/// display's red primary, which lies close to the curve's red end: about 990 K on an sRGB
/// display, 820 K on Display P3 and 640 K on Rec. 2020, so every setting has a temperature.
/// Only a colour redder than 500 K would have none, which `text` says as "< 500 K".
struct KelvinScale: Equatable, Sendable {
    /// One per whole percent, 0 to 100; nil where the colour is redder than 500 K.
    let kelvins: [Double?]

    /// The warmest temperature looked for. Even a Rec. 2020 red primary is warmer than
    /// 600 K; below 500 K the curve is all but at its end, the deepest visible red.
    static let floor = 500.0
    /// Below this Krystek's approximation drifts, and the curve is summed from Planck's law.
    static let krystekFloor = 1_000.0
    /// Farther than this from the blackbody curve, in uv, a colour has no temperature worth
    /// naming.
    static let maximumDistance = 0.02

    /// The kelvin a value shows, or nil below 500 K.
    func kelvin(_ value: Double) -> Double? {
        kelvins[min(100, max(0, SliderCore.percent(value)))]
    }

    /// "2,600 K", to the nearest 10 K, or "< 500 K".
    func text(_ value: Double) -> String {
        Self.text(kelvin: kelvin(value))
    }

    static func text(kelvin: Double?) -> String {
        guard let kelvin else { return "< 500 K" }
        return number((kelvin / 10).rounded() * 10) + " K"
    }

    /// The warmest and coolest temperatures this display's Color temp reaches.
    var bounds: ClosedRange<Double>? {
        let known = kelvins.compactMap { $0 }
        guard let low = known.min(), let high = known.max() else { return nil }
        return low...high
    }

    /// The Color temp percent, 0 to 100, that shows `kelvin`, between the whole percents
    /// either side of it; nil outside what this display reaches (within 5 K of its ends).
    func percent(forKelvin kelvin: Double) -> Double? {
        guard kelvin.isFinite, let bounds, kelvin >= bounds.lowerBound - 5, kelvin <= bounds.upperBound + 5 else {
            return nil
        }
        let target = min(bounds.upperBound, max(bounds.lowerBound, kelvin))
        for percent in 0..<100 {
            guard let low = kelvins[percent], let high = kelvins[percent + 1], low <= target, target <= high else { continue }
            return Double(percent) + (high > low ? (target - low) / (high - low) : 0)
        }
        return kelvins.lastIndex { $0 == target }.map(Double.init)
    }

    /// "2600 kelvin", for VoiceOver.
    func spoken(_ value: Double) -> String {
        guard let kelvin = kelvin(value) else { return "below 500 kelvin" }
        return "\(Int((kelvin / 10).rounded() * 10)) kelvin"
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
    }

    // MARK: Working it out

    /// The scale on a display, worked out once for each display's profile.
    @MainActor static func forDisplay(_ id: CGDirectDisplayID) -> KelvinScale {
        let space = CGDisplayCopyColorSpace(id)
        let key = (space.copyICCData() as Data?).map { $0.hashValue } ?? Int(id)
        if let known = cache[key] { return known }
        let scale = KelvinScale(space: space)
        cache[key] = scale
        return scale
    }

    @MainActor private static var cache: [Int: KelvinScale] = [:]

    init(kelvins: [Double?]) {
        self.kelvins = kelvins
    }

    /// The scale in a display colour space.
    init(space: CGColorSpace) {
        guard let xyz = CGColorSpace(name: CGColorSpace.genericXYZ) else {
            kelvins = Array(repeating: nil, count: 101)
            return
        }
        kelvins = (0...100).map { percent in
            let t = CGFloat(percent) / 100
            guard let color = CGColor(colorSpace: space, components: [1, t, max(0, 2 * t - 1), 1]),
                  let converted = color.converted(to: xyz, intent: .absoluteColorimetric, options: nil),
                  let c = converted.components, c.count >= 3 else { return nil }
            return Self.correlatedTemperature(x: Double(c[0]), y: Double(c[1]), z: Double(c[2]))
        }
    }

    /// The temperature of the nearest point on the blackbody curve, or nil where that is the
    /// curve's red end or the colour is far from it.
    static func correlatedTemperature(x: Double, y: Double, z: Double) -> Double? {
        let d = x + 15 * y + 3 * z
        guard d > 0 else { return nil }
        let u = 4 * x / d, v = 6 * y / d
        func distance(_ t: Double) -> Double {
            let p = planckianUV(t)
            return hypot(u - p.u, v - p.v)
        }
        // Coarse, then fine around the nearest.
        var best = floor
        var bestDistance = distance(floor)
        var t = floor
        while t <= 15_000 {
            let d = distance(t)
            if d < bestDistance { best = t; bestDistance = d }
            t += 50
        }
        var low = max(floor, best - 50), high = min(15_000, best + 50)
        for _ in 0..<40 {
            let a = low + (high - low) / 3, b = high - (high - low) / 3
            if distance(a) < distance(b) { high = b } else { low = a }
        }
        best = (low + high) / 2
        bestDistance = distance(best)
        guard best > floor + 1, bestDistance <= maximumDistance else { return nil }
        return best
    }

    /// The blackbody curve in CIE 1960 uv: Krystek's from 1,000 K, summed below it.
    static func planckianUV(_ t: Double) -> (u: Double, v: Double) {
        t < krystekFloor ? summedPlanckianUV(t) : krystekUV(t)
    }

    /// Krystek's 1985 rational approximation of the blackbody curve in CIE 1960 uv, good
    /// from 1,000 to 15,000 K.
    static func krystekUV(_ t: Double) -> (u: Double, v: Double) {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t)
            / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t)
            / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        return (u, v)
    }

    /// The blackbody's colour at `t`, from Planck's law weighted by the CIE 1931 2° colour
    /// matching functions every 10 nm. It meets Krystek's to 0.0002 in uv from 900 K up.
    static func summedPlanckianUV(_ t: Double) -> (u: Double, v: Double) {
        var x = 0.0, y = 0.0, z = 0.0
        for (index, match) in colorMatching.enumerated() {
            let metres = (380 + 10 * Double(index)) * 1e-9
            // Planck's law without its constant factors, which cancel in the chromaticity.
            let radiance = 1 / (pow(metres, 5) * (exp(1.438_776_9e-2 / (metres * t)) - 1))
            x += radiance * match.x
            y += radiance * match.y
            z += radiance * match.z
        }
        let d = x + 15 * y + 3 * z
        return (4 * x / d, 6 * y / d)
    }

    /// CIE 1931 2° colour matching functions, 380 to 780 nm every 10 nm.
    static let colorMatching: [(x: Double, y: Double, z: Double)] = [
        (0.001368, 0.000039, 0.006450), (0.004243, 0.000120, 0.020050), (0.014310, 0.000396, 0.067850),
        (0.043510, 0.001210, 0.207400), (0.134380, 0.004000, 0.645600), (0.283900, 0.011600, 1.385600),
        (0.348280, 0.023000, 1.747060), (0.336200, 0.038000, 1.772110), (0.290800, 0.060000, 1.669200),
        (0.195360, 0.090980, 1.287640), (0.095640, 0.139020, 0.812950), (0.032010, 0.208020, 0.465180),
        (0.004900, 0.323000, 0.272000), (0.009300, 0.503000, 0.158200), (0.063270, 0.710000, 0.078250),
        (0.165500, 0.862000, 0.042160), (0.290400, 0.954000, 0.020300), (0.433450, 0.994950, 0.008750),
        (0.594500, 0.995000, 0.003900), (0.762100, 0.952000, 0.002100), (0.916300, 0.870000, 0.001650),
        (1.026300, 0.757000, 0.001100), (1.062200, 0.631000, 0.000800), (1.002600, 0.503000, 0.000340),
        (0.854450, 0.381000, 0.000190), (0.642400, 0.265000, 0.000050), (0.447900, 0.175000, 0.000020),
        (0.283500, 0.107000, 0), (0.164900, 0.061000, 0), (0.087400, 0.032000, 0), (0.046770, 0.017000, 0),
        (0.022700, 0.008210, 0), (0.011359, 0.004102, 0), (0.005790, 0.002091, 0), (0.002899, 0.001047, 0),
        (0.001440, 0.000520, 0), (0.000690, 0.000249, 0), (0.000332, 0.000120, 0), (0.000166, 0.000060, 0),
        (0.000083, 0.000030, 0), (0.000042, 0.000015, 0),
    ]
}

/// How a slider writes its value.
enum SliderUnit: Equatable, Sendable {
    /// Its place in its range, "40%".
    case percent
    /// Color temp in kelvin, on a display.
    case kelvin(KelvinScale)

    func text(_ value: Double, in range: ClosedRange<Double>) -> String {
        switch self {
        case .percent: SliderCore.percentText(value, in: range)
        case .kelvin(let scale): scale.text(value)
        }
    }

    func spoken(_ value: Double, in range: ClosedRange<Double>) -> String {
        switch self {
        case .percent: SliderCore.spokenPercent(value, in: range)
        case .kelvin(let scale): scale.spoken(value)
        }
    }
}

extension EnvironmentValues {
    /// How the slider this is in writes its value.
    @Entry var emberSliderUnit: SliderUnit = .percent
    /// How Color temp is written in the popover: percent, or kelvin on the displays.
    @Entry var emberColorTempUnit: SliderUnit = .percent
    /// The Color temp unit setting, for the row that changes it.
    @Entry var colorTempPreference: ColorTempPreference? = nil
}

/// Settings: Color temp as a percent or in kelvin.
struct ColorTempUnitRow: View {
    static let title = "Show color temp as"

    @Environment(\.colorTempPreference) private var preference

    var body: some View {
        if let preference {
            EmberRow {
                Text(Self.title)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                EmberSegmented(
                    label: Self.title,
                    options: [(value: ColorTempUnit.percent, title: "%"), (value: .kelvin, title: "K")],
                    selection: preference.unit, onCard: true, compact: true,
                    help: "Kelvin is the colour temperature the displays show, worked out from each display's colour profile: 100% is the display's own white, about 6,500 K."
                ) { preference.unit = $0 }
                .frame(width: 64)
            }
            if preference.unit == .kelvin {
                // Tucked under its row, with the card's own margin below it.
                Text(Self.calibrated)
                    .font(.ember(11))
                    .foregroundStyle(palette.tertiary)
                    .lineLimit(1)
                    .padding(.top, -1)
                    .padding(.bottom, 8)
            }
        }
    }

    static let calibrated = "Calibrated to your display's color profile"

    @Environment(\.emberPalette) private var palette
}
