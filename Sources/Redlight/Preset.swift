import Foundation

struct Preset: Codable, Equatable {
    var name: String
    private(set) var colorPercent: Int
    private(set) var whitepointPercent: Int

    var intensity: Double {
        get { SliderPercent.unit(colorPercent) }
        set { colorPercent = SliderPercent.whole(newValue * 100) }
    }

    var whitepoint: Double {
        get { WhitepointScale.output(percent: Double(whitepointPercent)) }
        set { whitepointPercent = SliderPercent.whole(WhitepointScale.percent(newValue)) }
    }

    init(name: String, intensity: Double, whitepoint: Double) {
        self.name = name
        colorPercent = SliderPercent.whole(intensity * 100)
        whitepointPercent = SliderPercent.whole(WhitepointScale.percent(whitepoint))
    }

    private init(name: String, colorPercent: Int, whitepointPercent: Int) {
        self.name = name
        self.colorPercent = colorPercent
        self.whitepointPercent = whitepointPercent
    }

    private enum LegacyKeys: CodingKey { case intensity, whitepoint }
    private enum CodingKeys: CodingKey { case name, colorPercent, whitepointPercent }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        name = try values.decode(String.self, forKey: .name)
        colorPercent = try values.decodeIfPresent(Int.self, forKey: .colorPercent).map { min(100, max(0, $0)) }
            ?? SliderPercent.whole(legacy.decode(Double.self, forKey: .intensity) * 100)
        whitepointPercent = try values.decodeIfPresent(Int.self, forKey: .whitepointPercent).map { min(100, max(0, $0)) }
            ?? SliderPercent.whole(WhitepointScale.percent(legacy.decode(Double.self, forKey: .whitepoint)))
    }

    static let defaults: [Preset] = [
        Preset(name: "Day", colorPercent: 100, whitepointPercent: 100),
        Preset(name: "Warm", colorPercent: 70, whitepointPercent: 80),
        Preset(name: "Sunset", colorPercent: 50, whitepointPercent: 53),
        Preset(name: "Night", colorPercent: 25, whitepointPercent: 27),
        Preset(name: "Late", colorPercent: 0, whitepointPercent: 7),
    ]

    /// The last slot's name before it became "Late". Presets cannot be renamed in the app,
    /// so a saved last slot with exactly this name is the old default and is migrated on load.
    static let legacyLastName = "Deep Red"
}
