import Foundation
import Testing
@testable import Redlight

@Suite struct SolarPhaseTests {
    /// `SolarCurve.target` as it was before `phase` was taken out of it.
    private func formerTarget(
        elevation: Double, minElevation: Double, maxElevation: Double, rising: Bool, presets: [Preset]
    ) -> (intensity: Double, whitepoint: Double) {
        typealias Pair = (intensity: Double, whitepoint: Double)
        func ease(_ t: Double) -> Double {
            let c = min(1, max(0, t)), remaining = 1 - c
            return c < 0.5 ? 2 * c * c : 1 - 2 * remaining * remaining
        }
        func segment(_ e: Double, from upper: Double, to lower: Double) -> Double {
            ease((upper - e) / (upper - lower))
        }
        func lerp(_ a: Pair, _ b: Pair, _ f: Double) -> Pair {
            if f == 0 { return a }
            if f == 1 { return b }
            return (a.intensity + (b.intensity - a.intensity) * f, a.whitepoint + (b.whitepoint - a.whitepoint) * f)
        }
        let slide = max(0, 4.0 - maxElevation) - max(0, minElevation - -6.0)
        var elevation = elevation + slide
        var minElevation = minElevation + slide
        let maxElevation = maxElevation + slide
        if elevation < 0, minElevation < 0, minElevation > -24.0 {
            elevation *= -24.0 / minElevation
            minElevation = -24.0
        }
        func values(_ p: Preset) -> Pair { (p.intensity, p.whitepoint) }
        let day = values(presets[0]), warm = values(presets[1]), sunset = values(presets[2])
        let night = values(presets[3]), deep = values(presets[4])
        let civil = lerp(sunset, night, 1.0 / 3.0)
        let nautical = lerp(sunset, night, 2.0 / 3.0)
        if rising, elevation >= 0 {
            if elevation >= 4 { return day }
            if elevation >= 2 { return lerp(day, warm, segment(elevation, from: 4, to: 2)) }
            return lerp(warm, sunset, segment(elevation, from: 2, to: 0))
        }
        let eveningDay = min(12.0, max(4.0, maxElevation))
        let eveningWarm = eveningDay / 2
        if elevation >= eveningDay { return day }
        if elevation >= eveningWarm { return lerp(day, warm, segment(elevation, from: eveningDay, to: eveningWarm)) }
        if elevation >= 0 { return lerp(warm, sunset, segment(elevation, from: eveningWarm, to: 0)) }
        if elevation >= -6 { return lerp(sunset, civil, segment(elevation, from: 0, to: -6)) }
        if elevation >= -12 { return lerp(civil, nautical, segment(elevation, from: -6, to: -12)) }
        if elevation >= -18 { return lerp(nautical, night, segment(elevation, from: -12, to: -18)) }
        let denom = -18.0 - minElevation
        guard denom > 0 else { return (night.intensity, night.whitepoint) }
        return lerp(night, deep, ease((-18.0 - elevation) / denom))
    }

    @Test func targetIsBitForBitWhatItWasBeforePhase() {
        var custom = Preset.defaults
        custom[1].intensity = 0.9; custom[2].intensity = 0.2; custom[3].whitepoint = 0.9
        var checked = 0
        for presets in [Preset.defaults, custom] {
            for minElevation in stride(from: -80.0, through: 4.0, by: 6.5) {
                for maxElevation in [-3.0, 0, 3.5, 4, 7, 12, 30, 90] where maxElevation > minElevation {
                    for step in 0...60 {
                        let elevation = minElevation + (maxElevation - minElevation) * Double(step) / 60
                        for rising in [false, true] {
                            let old = formerTarget(
                                elevation: elevation, minElevation: minElevation,
                                maxElevation: maxElevation, rising: rising, presets: presets)
                            let new = SolarCurve.target(
                                elevation: elevation, minElevation: minElevation,
                                maxElevation: maxElevation, rising: rising, presets: presets)
                            #expect(old.intensity.bitPattern == new.intensity.bitPattern)
                            #expect(old.whitepoint.bitPattern == new.whitepoint.bitPattern)
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked > 10_000)
    }

    @Test func phaseMatchesTheReference() throws {
        let rows = try #require(try LearnedAutoFixtures.json("phase") as? [[Any]])
        #expect(rows.count > 1000)
        var seen = Set<Int>()
        for row in rows {
            let n = LearnedAutoFixtures.number
            let expected = try #require(LearnedAutoFixtures.phase(Array(row[4...6])))
            let phase = SolarCurve.phase(
                elevation: n(row[0]), minElevation: n(row[1]), maxElevation: n(row[2]), rising: n(row[3]) == 1)
            let got = phase.weights, want = expected.weights
            #expect(got.map(\.anchor) == want.map(\.anchor), "row \(row)")
            for (a, b) in zip(got, want) { #expect(abs(a.weight - b.weight) < 1e-12, "row \(row)") }
            got.forEach { seen.insert($0.anchor.rawValue) }
        }
        #expect(seen.count == SolarCurve.Anchor.allCases.count)
    }

    @Test func weightsAddUpToOneAndTheLeadHasTheLargerShare() {
        for elevation in stride(from: -40.0, through: 40.0, by: 0.37) {
            for rising in [false, true] {
                let phase = SolarCurve.phase(elevation: elevation, minElevation: -40, maxElevation: 40, rising: rising)
                let weights = phase.weights
                #expect(abs(weights.reduce(0) { $0 + $1.weight } - 1) < 1e-12)
                #expect(weights.allSatisfy { $0.weight > 0 })
                let largest = weights.max { $0.weight < $1.weight }!
                #expect(weights.first { $0.anchor == phase.lead }!.weight == largest.weight)
            }
        }
    }

    @Test func theTargetIsTheAnchorsMixedByThePhase() {
        let values = SolarCurve.anchorValues(presets: Preset.defaults)
        for elevation in stride(from: -40.0, through: 40.0, by: 0.61) {
            for rising in [false, true] {
                let phase = SolarCurve.phase(elevation: elevation, minElevation: -40, maxElevation: 40, rising: rising)
                let target = SolarCurve.target(
                    elevation: elevation, minElevation: -40, maxElevation: 40, rising: rising, presets: Preset.defaults)
                let mixed = phase.weights.reduce(0) { $0 + values[$1.anchor.kind].intensity * $1.weight }
                #expect(abs(mixed - target.intensity) < 1e-12)
            }
        }
    }

    @Test func anchorTargetsAreTheCurveOnEachAnchorAndMatchTheReference() {
        let targets = AdaptiveMapping.anchorTargets(
            presets: Preset.defaults, intensityMin: 0.3, intensityMax: 0.9,
            whitepointMin: 0.625, whitepointMax: 1)
        #expect(targets.intensity.count == 12 && targets.whitepoint.count == 12)
        let color = LearnedAutoFixtures.baseline(Preset.defaults.map(\.intensity), 0.3...0.9)
        for (a, b) in zip(targets.intensity, color) { #expect(abs(a - b) < 1e-12) }
        // White point: the reference works in slider units, and the remap commutes with them.
        let slider = LearnedAutoFixtures.baseline(Preset.defaults.map { WhitepointScale.shown($0.whitepoint) }, 0.5...1)
        for (a, b) in zip(targets.whitepoint, slider) { #expect(abs(WhitepointScale.shown(a) - b) < 1e-12) }
        #expect(targets.intensity[SolarCurve.Anchor.day.rawValue] == 0.9)
        #expect(targets.intensity[SolarCurve.Anchor.late.rawValue] == 0.3)
        #expect(targets.intensity[SolarCurve.Anchor.morningCivil.rawValue]
            == targets.intensity[SolarCurve.Anchor.eveningCivil.rawValue])
    }
}
