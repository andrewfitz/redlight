import AppKit
import Testing
@testable import Redlight

@MainActor @Suite struct ColorTemperatureTests {
    /// The blackbody curve's own points, and the standard illuminants, come back at their
    /// temperatures.
    @Test func whitesOnAndNearTheBlackbodyCurveHaveTheirTemperatures() throws {
        // D65, the white of sRGB, Display P3 and Apple's displays: 6,504 K.
        let d65 = try #require(KelvinScale.correlatedTemperature(x: 0.95047, y: 1, z: 1.08883))
        #expect(abs(d65 - 6504) < 15, "\(d65)")
        // Illuminant A, a tungsten lamp: 2,856 K.
        let a = try #require(KelvinScale.correlatedTemperature(x: 1.09850, y: 1, z: 0.35585))
        #expect(abs(a - 2856) < 15, "\(a)")
        // A point made on the curve at 3,000 K.
        let p = KelvinScale.planckianUV(3000)
        let y = 1.0, x = 1.5 * p.u / p.v * y, z = (4 - p.u - 10 * p.v) / (2 * p.v) * y
        let back = try #require(KelvinScale.correlatedTemperature(x: x, y: y, z: z))
        #expect(abs(back - 3000) < 5, "\(back)")
        // sRGB's red primary lies by the curve's red end, at about 990 K.
        let red = try #require(KelvinScale.correlatedTemperature(x: 0.41, y: 0.21, z: 0.02))
        #expect(abs(red - 990) < 30, "\(red)")
        // A saturated green is far off the curve: no temperature.
        #expect(KelvinScale.correlatedTemperature(x: 0.36, y: 0.72, z: 0.12) == nil)
    }

    /// Below 1,000 K the curve is summed from Planck's law. It meets Krystek's there, and
    /// carries on to the deepest red: 1,000 K is x 0.6528, y 0.3444.
    @Test func theCurveBelowAThousandKelvinMeetsKrystekAndGoesOnToRed() {
        for t in [900.0, 1_000, 1_500, 2_000, 4_000, 6_500] {
            let summed = KelvinScale.summedPlanckianUV(t), krystek = KelvinScale.krystekUV(t)
            #expect(hypot(summed.u - krystek.u, summed.v - krystek.v) < 0.0005, "\(t) K")
        }
        let p = KelvinScale.summedPlanckianUV(1_000)
        let x = 3 * p.u / (2 * p.u - 8 * p.v + 4), y = 2 * p.v / (2 * p.u - 8 * p.v + 4)
        #expect(abs(x - 0.6528) < 0.001 && abs(y - 0.3444) < 0.001, "\(x), \(y)")
        // Redder at every step down.
        var last = KelvinScale.planckianUV(1_000).u
        for t in stride(from: 990.0, through: 500, by: -10) {
            let u = KelvinScale.planckianUV(t).u
            #expect(u > last, "\(t) K")
            last = u
        }
    }

    /// 0% is the display's red primary, and it has a real temperature: lower the wider the
    /// display's gamut.
    @Test func zeroPercentIsTheRedPrimarysTemperature() throws {
        let expected: [(CFString, Double)] = [(CGColorSpace.sRGB, 990), (CGColorSpace.displayP3, 820), (CGColorSpace.itur_2020, 640)]
        for (name, kelvin) in expected {
            let scale = KelvinScale(space: try #require(CGColorSpace(name: name)))
            #expect(scale.kelvins.allSatisfy { $0 != nil }, "\(name)")
            let bottom = try #require(scale.kelvin(0))
            #expect(abs(bottom - kelvin) < 30, "\(name): 0% is \(bottom) K")
        }
    }

    /// On an sRGB display Color temp runs from the display's white down the blackbody curve,
    /// always warmer as it goes, to its red primary near 990 K.
    @Test func colorTempOnAnSRGBDisplayRunsFromD65DownTheCurve() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let scale = KelvinScale(space: space)
        #expect(scale.kelvins.count == 101)
        let top = try #require(scale.kelvin(1))
        #expect(abs(top - 6504) < 40, "100% is \(top) K")
        let warm = try #require(scale.kelvin(0.7))
        #expect(abs(warm - 2900) < 150, "70% is \(warm) K")
        let red = try #require(scale.kelvin(0))
        #expect(abs(red - 990) < 30, "0% is \(red) K")
        // Warmer at every step down that has a temperature.
        var last = Double.infinity
        for percent in stride(from: 100, through: 0, by: -1) {
            guard let kelvin = scale.kelvins[percent] else { continue }
            #expect(kelvin < last + 1, "\(percent)%: \(kelvin) K after \(last) K")
            last = kelvin
        }
    }

    @Test func kelvinIsWrittenToTenKelvinAndSaysWhenItIsBelowTheCurve() {
        let scale = KelvinScale(kelvins: (0...100).map { $0 < 20 ? nil : 1000 + Double($0) * 55.37 })
        #expect(scale.text(1) == "6,540 K")
        #expect(scale.text(0.5) == "3,770 K")
        #expect(scale.text(0.1) == "< 500 K")
        #expect(scale.spoken(0.5) == "3770 kelvin")
        #expect(scale.spoken(0) == "below 500 kelvin")
        #expect(SliderUnit.kelvin(scale).text(0.5, in: 0...1) == "3,770 K")
        #expect(SliderUnit.percent.text(0.5, in: 0...1) == "50%")
    }

    @Test func theUnitIsPercentUntilChosenAndIsKept() {
        let registry = TestDefaultsRegistry()
        let defaults = registry.makeDefaults()
        let first = ColorTempPreference(defaults: defaults)
        #expect(first.unit == .percent)
        first.unit = .kelvin
        #expect(ColorTempPreference(defaults: defaults).unit == .kelvin)
    }

    /// The command line takes a colour temperature for Color temp and its limits, and only
    /// for those.
    @Test func theCommandLineReadsKelvin() throws {
        #expect(try CLIParser.parse(["color", "3400K"]).command == .colorKelvin(3400))
        #expect(try CLIParser.parse(["color", "2700k"]).command == .colorKelvin(2700))
        #expect(try CLIParser.parse(["color", "40"]).command == .color(40))
        #expect(try CLIParser.parse(["limits", "color", "1200K", "6500K"]).command == .limitsKelvin(min: 1200, max: 6500))
        #expect(throws: CommandError.self) { try CLIParser.parse(["limits", "color", "1200K", "80"]) }
        #expect(throws: CommandError.self) { try CLIParser.parse(["limits", "color", "6500K", "1200K"]) }
        #expect(throws: CommandError.self) { try CLIParser.parse(["whitepoint", "3400K"]) }
        #expect(throws: CommandError.self) { try CLIParser.parse(["color", "K"]) }
    }

    @Test func kelvinTurnsIntoTheColorTempThatShowsIt() throws {
        let scale = KelvinScale(kelvins: (0...100).map { $0 < 20 ? nil : 1000 + Double($0) * 55 })
        #expect(scale.bounds == 2100...6500)
        #expect(scale.percent(forKelvin: 6500) == 100)
        #expect(scale.percent(forKelvin: 3750) == 50)
        let between = try #require(scale.percent(forKelvin: 3777.5))
        #expect(abs(between - 50.5) < 1e-9)
        #expect(scale.percent(forKelvin: 6503) == 100, "a few kelvin past the white is the white")
        #expect(scale.percent(forKelvin: 9000) == nil)
        #expect(scale.percent(forKelvin: 1500) == nil)
    }

    /// Status carries the kelvin beside the percent, and a status without it still reads.
    @Test func statusCarriesKelvinAndReadsWithoutIt() throws {
        var status = Status(color: Status.Level(set: 70, target: 70))
        status.colorKelvin = Status.Kelvin(set: 2900, target: 2900)
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(Status.self, from: data).colorKelvin?.set == 2900)
        #expect(status.colorKelvin?.text == "2,900 K")
        #expect(Status.Kelvin(set: 2900, target: 1500).text == "2,900 K, target 1,500 K")
        #expect(Status.Kelvin(set: nil, target: nil).text == "< 500 K")
        status.colorKelvin = nil
        let older = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(Status.self, from: older).colorKelvin == nil)
        #expect(RedlightCLI.describe(Status(color: Status.Level(set: 70, target: 70), colorKelvin: Status.Kelvin(set: 2900, target: 2900)))
            .contains("Color temp: \(Status.Level(set: 70, target: 70).text), 2,900 K"))
    }
}
