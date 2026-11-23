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

enum CommandChannel: String, Codable, Sendable, CaseIterable {
    case color, whitepoint

    /// User-facing name; the raw value stays the CLI and wire spelling.
    var displayName: String { self == .color ? "Color temp" : "White point" }
}
enum CommandAppearance: String, Codable, Sendable, CaseIterable { case light, dark, toggle }
enum CommandPreset: String, Codable, Sendable, CaseIterable {
    case day, warm, sunset, night
    case deepRed = "deep-red"

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// A pause with its own length. The plain `pause(.on)` stays the 30-minute default.
enum CommandPauseLength: Codable, Sendable, Equatable {
    /// Whole minutes, 1 through 1440 (24 hours).
    case minutes(Int)
    /// The next sunrise at the current location, within 25 hours.
    case untilSunrise

    static let minuteRange = 1...1440
}

enum CommandLocation: Codable, Sendable, Equatable {
    /// Core Location, falling back to the time zone's city.
    case automatic
    /// Degrees: latitude −90…90, longitude −180…180.
    case manual(latitude: Double, longitude: Double)
}

/// Adaptive's "deepest by" time, 24-hour local wall clock, or off.
enum CommandBedtime: Codable, Sendable, Equatable {
    case off
    /// Hour 0…23, minute 0…59.
    case at(hour: Int, minute: Int)
}

/// Changes to the apps that suspend the tint while in front, by bundle identifier.
enum CommandApps: Codable, Sendable, Equatable {
    case add(String)
    case remove(String)
    case clear
}

/// Where Adaptive's coordinate comes from: a fix (current or last known), the user, or
/// the time zone's city.
enum CommandLocationSource: String, Codable, Sendable, CaseIterable { case auto, manual, timeZone }

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
    /// Relative percentage change from the current target, resolved by the running app.
    case step(CommandChannel, Double)
    case pause(CommandSwitch)
    /// Starts a pause of this length, replacing any pause already running.
    case pauseFor(CommandPauseLength)
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
    case location(CommandLocation)
    case bedtime(CommandBedtime)
    case appsList
    case apps(CommandApps)
    case update
    case quit

    var isReadOnly: Bool { self == .status || self == .displayList || self == .appsList }
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
        /// "10.0–80.0%", or "fixed at 60.0%" when equal limits pin the value.
        var text: String { min == max ? "fixed at \(min)%" : "\(min)–\(max)%" }
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
    var pausedUntil: Date?
    /// Absent from apps older than protocol 3.
    var locationSource: CommandLocationSource?
    /// Adaptive's bedtime as "22:30"; absent when off, and from older apps.
    var bedtime: String?
    /// The chosen app in front that is suspending the tint; absent when none is.
    var suspendedFor: String?
    /// Bundle IDs of the apps that suspend the tint; absent from JSON when there are none.
    var apps: [String] = []

    static var notRunning: Status { Status(running: false) }

    private enum CodingKeys: String, CodingKey {
        case running, on, displays, color, whitepoint, activePreset, adaptive, elevation
        case statusLine, limits, appearance, login, version, fading, pausedUntil, locationSource, bedtime
        case suspendedFor, apps
    }

    init(
        running: Bool = true, on: Bool = false, displays: [Display] = [],
        color: Level = Level(set: 100, target: 100),
        whitepoint: Level = Level(set: 100, target: 100), activePreset: CommandPreset? = nil,
        adaptive: Bool = false, elevation: Double? = nil, statusLine: String = "",
        limits: Limits = Limits(color: Band(min: 0, max: 100), whitepoint: Band(min: 30, max: 100)),
        appearance: CommandAppearance = .light,
        login: Login = Login(enabled: false, requiresApproval: false), version: String = "", fading: Bool = false,
        pausedUntil: Date? = nil, locationSource: CommandLocationSource? = nil, bedtime: String? = nil,
        suspendedFor: String? = nil, apps: [String] = []
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
        self.pausedUntil = pausedUntil
        self.locationSource = locationSource
        self.bedtime = bedtime
        self.suspendedFor = suspendedFor
        self.apps = apps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let running = try values.decode(Bool.self, forKey: .running)
        if !running { self = .notRunning; return }
        let pausedUntil = try values.decodeIfPresent(String.self, forKey: .pausedUntil).map { timestamp in
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: timestamp) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            guard let date = formatter.date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .pausedUntil, in: values, debugDescription: "Expected an ISO 8601 timestamp.")
            }
            return date
        }
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
            fading: try values.decode(Bool.self, forKey: .fading),
            pausedUntil: pausedUntil,
            locationSource: try values.decodeIfPresent(CommandLocationSource.self, forKey: .locationSource),
            bedtime: try values.decodeIfPresent(String.self, forKey: .bedtime),
            suspendedFor: try values.decodeIfPresent(String.self, forKey: .suspendedFor),
            apps: try values.decodeIfPresent([String].self, forKey: .apps) ?? []
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
        try values.encodeIfPresent(
            pausedUntil.map { ISO8601DateFormatter().string(from: $0) }, forKey: .pausedUntil)
        try values.encodeIfPresent(locationSource, forKey: .locationSource)
        try values.encodeIfPresent(bedtime, forKey: .bedtime)
        try values.encodeIfPresent(suspendedFor, forKey: .suspendedFor)
        if !apps.isEmpty { try values.encode(apps, forKey: .apps) }
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

struct CommandProtocolHeader: Decodable { var v: Int }

struct CommandRequest: Codable, Sendable, Equatable {
    /// 2 added `step` and `pause`; 3 added `pauseFor`, `location`, `bedtime`, `appsList`,
    /// `apps`, `Status.locationSource`, `Status.bedtime`, `Status.suspendedFor` and
    /// `Status.apps`.
    /// An older app answers "update Redlight" instead of failing to decode.
    static let currentVersion = 3
    var v: Int
    var command: RedlightCommand

    init(v: Int = currentVersion, command: RedlightCommand) {
        self.v = v
        self.command = command
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        v = try values.decode(Int.self, forKey: .v)
        // A future client may send a command this version cannot decode.
        try Self.validateVersion(v)
        command = try values.decode(RedlightCommand.self, forKey: .command)
    }

    func validateVersion() throws {
        try Self.validateVersion(v)
    }

    private static func validateVersion(_ version: Int) throws {
        guard version == currentVersion else {
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
