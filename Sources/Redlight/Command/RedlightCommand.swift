import Foundation

enum CommandSwitch: String, Codable, Sendable, CaseIterable {
    case on, off, toggle

    func resolve(current: Bool) -> Bool {
        switch self {
        case .on: true
        case .off: false
        case .toggle: !current
        }
    }
}

enum CommandChannel: String, Codable, Sendable, CaseIterable { case color, whitepoint }
enum CommandAppearance: String, Codable, Sendable, CaseIterable { case light, dark, toggle }
enum CommandPreset: String, Codable, Sendable, CaseIterable {
    case day, warm, sunset, night
    case deepRed = "deep-red"

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

enum CommandDisplaySelector: Codable, Sendable, Equatable {
    case number(Int)
    case name(String)
    case all
    /// Stable persistence key used by an App Entity or a popover display row.
    case key(String)
}

enum RedlightCommand: Codable, Sendable, Equatable {
    case master(CommandSwitch)
    case status
    case color(Double)
    case whitepoint(Double)
    case reset(CommandChannel)
    case preset(CommandPreset)
    case savePreset(CommandPreset)
    case adaptive(CommandSwitch)
    case limits(CommandChannel, min: Double, max: Double)
    case displayList
    case display(CommandDisplaySelector, CommandSwitch)
    case invert(CommandDisplaySelector, CommandSwitch)
    case appearance(CommandAppearance)
    case login(Bool)
    case update
    case quit

    var isReadOnly: Bool { self == .status || self == .displayList }
}

/// All levels are percentages, and targets are endpoints rather than fade frames.
struct Status: Codable, Sendable, Equatable {
    struct Display: Codable, Sendable, Equatable {
        var key: String
        var number: Int
        var name: String
        var enabled: Bool
        var inverted: Bool
    }
    struct Level: Codable, Sendable, Equatable {
        var set: Double
        var target: Double
    }
    struct Band: Codable, Sendable, Equatable {
        var min: Double
        var max: Double
    }
    struct Limits: Codable, Sendable, Equatable {
        var color: Band
        var whitepoint: Band
    }
    struct Login: Codable, Sendable, Equatable {
        var enabled: Bool
        var requiresApproval: Bool
    }

    var running: Bool = true
    var on: Bool = false
    var displays: [Display] = []
    var color: Level = Level(set: 100, target: 100)
    var whitepoint: Level = Level(set: 100, target: 100)
    var activePreset: CommandPreset?
    var adaptive: Bool = false
    var elevation: Double?
    var statusLine: String = ""
    var limits: Limits = Limits(color: Band(min: 0, max: 100), whitepoint: Band(min: 30, max: 100))
    var appearance: CommandAppearance = .light
    var login: Login = Login(enabled: false, requiresApproval: false)
    var version: String = ""
    var fading: Bool = false

    static var notRunning: Status { Status(running: false) }

    private enum CodingKeys: String, CodingKey {
        case running, on, displays, color, whitepoint, activePreset, adaptive, elevation
        case statusLine, limits, appearance, login, version, fading
    }

    init(
        running: Bool = true, on: Bool = false, displays: [Display] = [],
        color: Level = Level(set: 100, target: 100),
        whitepoint: Level = Level(set: 100, target: 100), activePreset: CommandPreset? = nil,
        adaptive: Bool = false, elevation: Double? = nil, statusLine: String = "",
        limits: Limits = Limits(color: Band(min: 0, max: 100), whitepoint: Band(min: 30, max: 100)),
        appearance: CommandAppearance = .light,
        login: Login = Login(enabled: false, requiresApproval: false), version: String = "", fading: Bool = false
    ) {
        self.running = running
        self.on = on
        self.displays = displays
        self.color = color
        self.whitepoint = whitepoint
        self.activePreset = activePreset
        self.adaptive = adaptive
        self.elevation = elevation
        self.statusLine = statusLine
        self.limits = limits
        self.appearance = appearance
        self.login = login
        self.version = version
        self.fading = fading
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let running = try values.decode(Bool.self, forKey: .running)
        if !running { self = .notRunning; return }
        self.init(
            running: running, on: try values.decode(Bool.self, forKey: .on),
            displays: try values.decode([Display].self, forKey: .displays),
            color: try values.decode(Level.self, forKey: .color),
            whitepoint: try values.decode(Level.self, forKey: .whitepoint),
            activePreset: try values.decodeIfPresent(CommandPreset.self, forKey: .activePreset),
            adaptive: try values.decode(Bool.self, forKey: .adaptive),
            elevation: try values.decodeIfPresent(Double.self, forKey: .elevation),
            statusLine: try values.decode(String.self, forKey: .statusLine),
            limits: try values.decode(Limits.self, forKey: .limits),
            appearance: try values.decode(CommandAppearance.self, forKey: .appearance),
            login: try values.decode(Login.self, forKey: .login),
            version: try values.decode(String.self, forKey: .version),
            fading: try values.decode(Bool.self, forKey: .fading)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(running, forKey: .running)
        guard running else { return }
        try values.encode(on, forKey: .on)
        try values.encode(displays, forKey: .displays)
        try values.encode(color, forKey: .color)
        try values.encode(whitepoint, forKey: .whitepoint)
        try values.encodeIfPresent(activePreset, forKey: .activePreset)
        try values.encode(adaptive, forKey: .adaptive)
        try values.encodeIfPresent(elevation, forKey: .elevation)
        try values.encode(statusLine, forKey: .statusLine)
        try values.encode(limits, forKey: .limits)
        try values.encode(appearance, forKey: .appearance)
        try values.encode(login, forKey: .login)
        try values.encode(version, forKey: .version)
        try values.encode(fading, forKey: .fading)
    }
}

struct CommandError: Error, LocalizedError, Codable, Sendable, Equatable {
    enum Code: String, Codable, Sendable { case invalidInput, system, unreachable }
    var code: Code
    var message: String
    var errorDescription: String? { message }
    var exitCode: Int { code == .invalidInput ? 1 : 2 }

    static func invalidInput(_ message: String) -> Self { Self(code: .invalidInput, message: message) }
    static func system(_ message: String) -> Self { Self(code: .system, message: message) }
    static func unreachable(_ message: String) -> Self { Self(code: .unreachable, message: message) }
}

struct CommandRequest: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var v: Int = currentVersion
    var command: RedlightCommand

    func validateVersion() throws {
        guard v == Self.currentVersion else {
            throw CommandError.system("Command protocol version mismatch; update Redlight.")
        }
    }
}

struct CommandReply: Codable, Sendable, Equatable {
    var v: Int = CommandRequest.currentVersion
    var ok: Bool
    var error: CommandError?
    var status: Status?

    static func success(_ status: Status) -> Self { Self(ok: true, status: status) }
    static func failure(_ error: CommandError, status: Status? = nil) -> Self {
        Self(ok: false, error: error, status: status)
    }

    func validateVersion() throws {
        guard v == CommandRequest.currentVersion else {
            throw CommandError.system("Command protocol version mismatch; update Redlight.")
        }
    }
}
