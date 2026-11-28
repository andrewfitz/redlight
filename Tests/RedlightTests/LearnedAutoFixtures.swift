import Foundation
@testable import Redlight

/// The learned-Auto reference's runs, exported by
/// `docs/superpowers/reports/learned-auto-stress/v4/export_golden.py`.
enum LearnedAutoFixtures {
    static func json(_ name: String) throws -> Any {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/LearnedAuto")
        else { throw CocoaError(.fileNoSuchFile) }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }

    /// `[from, to, f]` as the reference writes a phase.
    static func phase(_ value: Any?) -> SolarCurve.Phase? {
        guard let row = value as? [Any], row.count == 3,
              let from = SolarCurve.Anchor(rawValue: Int(number(row[0]))),
              let to = SolarCurve.Anchor(rawValue: Int(number(row[1]))) else { return nil }
        return SolarCurve.Phase(from: from, to: to, fraction: number(row[2]))
    }

    /// The reference's `learner.baseline`: the curve's value at each anchor in a band, from
    /// the five preset values of one channel in slider units.
    static func baseline(_ presets: [Double], _ band: ClosedRange<Double>) -> [Double] {
        let day = presets[0], warm = presets[1], sunset = presets[2], night = presets[3], deep = presets[4]
        let values = [day, warm, sunset, (2 * sunset + night) / 3, (sunset + 2 * night) / 3, night, deep]
        let lo = band.lowerBound, hi = band.upperBound
        let side = values.map { value -> Double in
            guard day != deep else { return min(hi, max(lo, value)) }
            return lo + (hi - lo) * min(1, max(0, (value - deep) / (day - deep)))
        }
        return side + side[1...5]
    }

    /// The reference's curve with no bedtime or wake time: the anchors mixed by the phase.
    static func mix(_ anchors: [Double], _ phase: SolarCurve.Phase) -> Double {
        var value = 0.0
        for (anchor, weight) in phase.weights { value += anchors[anchor.rawValue] * weight }
        return value
    }
}
