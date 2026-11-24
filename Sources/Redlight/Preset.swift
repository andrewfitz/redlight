import Foundation

struct Preset: Codable, Equatable {
    var name: String
    var intensity: Double
    var whitepoint: Double

    static let defaults: [Preset] = [
        Preset(name: "Day", intensity: 1.0, whitepoint: 1.0),
        Preset(name: "Warm", intensity: 0.7, whitepoint: 0.85),
        Preset(name: "Sunset", intensity: 0.5, whitepoint: 0.65),
        Preset(name: "Night", intensity: 0.25, whitepoint: 0.45),
        Preset(name: "Late", intensity: 0.0, whitepoint: 0.3),
    ]

    /// The last slot's name before it became "Late". Presets cannot be renamed in the app,
    /// so a saved last slot with exactly this name is the old default and is migrated on load.
    static let legacyLastName = "Deep Red"
}
