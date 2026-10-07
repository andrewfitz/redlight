import AppIntents
import Foundation

@MainActor private enum AppIntentExecutor {
    static var execute: ((RedlightCommand) throws -> Status)?
    static var snapshot: (() -> Status)?
}

extension IntentBridge {
    static func install(execute: @escaping (RedlightCommand) throws -> Status,
                        snapshot: @escaping () -> Status) {
        AppIntentExecutor.execute = execute
        AppIntentExecutor.snapshot = snapshot
        setOn = { try execute(.master($0 ? .on : .off)).on }
        ControlHandoff.shared.install(setOn: { try execute(.master($0 ? .on : .off)).on })
    }

    static func execute(_ command: RedlightCommand) throws -> Status {
        guard let execute = AppIntentExecutor.execute else {
            throw CommandError.unreachable("Redlight's command handler is not ready.")
        }
        return try execute(command)
    }

    static func displays() throws -> [Status.Display] {
        guard let snapshot = AppIntentExecutor.snapshot else {
            throw CommandError.unreachable("Redlight's command handler is not ready.")
        }
        return snapshot().displays
    }

    static func uninstall() {
        AppIntentExecutor.execute = nil
        AppIntentExecutor.snapshot = nil
        setOn = nil
        handoff = { try await ControlHandoffClient().setOn($0) }
    }
}

enum RedlightPreset: String, AppEnum {
    case day, warm, sunset, night
    case deepRed = "deep-red"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Redlight Preset"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .day: "Day", .warm: "Warm", .sunset: "Sunset", .night: "Night", .deepRed: "Deep Red",
    ]
    var command: CommandPreset { CommandPreset(rawValue: rawValue)! }
}

enum RedlightMode: String, AppEnum {
    case on, off, toggle
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "State"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .on: "On", .off: "Off", .toggle: "Toggle",
    ]
    var command: CommandSwitch { CommandSwitch(rawValue: rawValue)! }
}

enum RedlightChannel: String, AppEnum {
    case color, whitepoint
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Level"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.color: "Color", .whitepoint: "White Point"]
    var command: CommandChannel { CommandChannel(rawValue: rawValue)! }
}

enum RedlightAppearance: String, AppEnum {
    case light, dark, toggle
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Appearance"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.light: "Light", .dark: "Dark", .toggle: "Toggle"]
    var command: CommandAppearance { CommandAppearance(rawValue: rawValue)! }
}

struct DisplayEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display"
    static let defaultQuery = DisplayEntityQuery()
    static let allID = "__redlight_all_displays__"
    let id: String
    let name: String
    let number: Int?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(number.map { "Display \($0)" } ?? "Every connected display")")
    }
    var selector: CommandDisplaySelector { id == Self.allID ? .all : .key(id) }
    static let all = DisplayEntity(id: allID, name: "All Displays", number: nil)
    init(id: String, name: String, number: Int? = nil) { self.id = id; self.name = name; self.number = number }
    init(_ display: Status.Display) { id = display.key; name = display.name; number = display.number }
}

struct DisplayEntityQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [DisplayEntity] {
        let available = [DisplayEntity.all] + (try IntentBridge.displays()).map(DisplayEntity.init)
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }
    @MainActor func suggestedEntities() async throws -> [DisplayEntity] {
        [DisplayEntity.all] + (try IntentBridge.displays()).map(DisplayEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [DisplayEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct SetRedlightStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight State"
    static let openAppWhenRun = false
    @Parameter(title: "State", default: .on) var mode: RedlightMode
    init() {}
    init(mode: RedlightMode) { self.mode = mode }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.master(mode.command))
        return .result()
    }
}

struct TurnOnRedlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Redlight"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.master(.on))
        return .result()
    }
}

struct TurnOffRedlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Redlight"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.master(.off))
        return .result()
    }
}

struct SetRedlightColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Color"
    static let openAppWhenRun = false
    @Parameter(title: "Color", inclusiveRange: (0, 100)) var value: Double
    init() {}
    init(value: Double) { self.value = value }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.color(value))
        return .result()
    }
}

struct SetRedlightWhitepointIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight White Point"
    static let openAppWhenRun = false
    @Parameter(title: "White Point", inclusiveRange: (25, 100)) var value: Double
    init() {}
    init(value: Double) { self.value = value }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.whitepoint(value))
        return .result()
    }
}

struct ResetRedlightLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Redlight Level"
    static let openAppWhenRun = false
    @Parameter(title: "Level", default: .color) var channel: RedlightChannel
    init() {}
    init(channel: RedlightChannel) { self.channel = channel }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.reset(channel.command))
        return .result()
    }
}

struct SetRedlightPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Preset"
    static let openAppWhenRun = false
    @Parameter(title: "Preset") var preset: RedlightPreset
    init() {}
    init(preset: RedlightPreset) { self.preset = preset }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.preset(preset.command))
        return .result()
    }
}

struct SaveRedlightPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Redlight Preset"
    static let openAppWhenRun = false
    @Parameter(title: "Preset") var preset: RedlightPreset
    init() {}
    init(preset: RedlightPreset) { self.preset = preset }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.savePreset(preset.command))
        return .result()
    }
}

struct SetRedlightAdaptiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Adaptive"
    static let openAppWhenRun = false
    @Parameter(title: "State", default: .on) var mode: RedlightMode
    init() {}
    init(mode: RedlightMode) { self.mode = mode }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.adaptive(mode.command))
        return .result()
    }
}

struct TurnOnRedlightAdaptiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Redlight Adaptive"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.adaptive(.on))
        return .result()
    }
}

struct SetRedlightLimitsIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Limits"
    static let openAppWhenRun = false
    @Parameter(title: "Level", default: .color) var channel: RedlightChannel
    @Parameter(title: "Minimum", inclusiveRange: (0, 100)) var minimum: Double
    @Parameter(title: "Maximum", inclusiveRange: (0, 100)) var maximum: Double
    init() {}
    init(channel: RedlightChannel, minimum: Double, maximum: Double) { self.channel = channel; self.minimum = minimum; self.maximum = maximum }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.limits(channel.command, min: minimum, max: maximum))
        return .result()
    }
}

struct SetRedlightDisplayIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Display"
    static let openAppWhenRun = false
    @Parameter(title: "Display") var display: DisplayEntity
    @Parameter(title: "State", default: .on) var mode: RedlightMode
    init() {}
    init(display: DisplayEntity, mode: RedlightMode) { self.display = display; self.mode = mode }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.display(display.selector, mode.command))
        return .result()
    }
}

struct SetRedlightInvertIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Display Inversion"
    static let openAppWhenRun = false
    @Parameter(title: "Display") var display: DisplayEntity
    @Parameter(title: "State", default: .on) var mode: RedlightMode
    init() {}
    init(display: DisplayEntity, mode: RedlightMode) { self.display = display; self.mode = mode }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.invert(display.selector, mode.command))
        return .result()
    }
}

struct SetRedlightAppearanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Appearance"
    static let openAppWhenRun = false
    @Parameter(title: "Appearance", default: .toggle) var appearance: RedlightAppearance
    init() {}
    init(appearance: RedlightAppearance) { self.appearance = appearance }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.appearance(appearance.command))
        return .result()
    }
}

struct SetRedlightLoginIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Launch at Login"
    static let openAppWhenRun = false
    @Parameter(title: "Enabled") var enabled: Bool
    init() {}
    init(enabled: Bool) { self.enabled = enabled }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.login(enabled))
        return .result()
    }
}

struct UpdateRedlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Redlight Updates"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.update)
        return .result()
    }
}

struct QuitRedlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit Redlight"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.quit)
        return .result()
    }
}

struct GetRedlightStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Redlight Status"
    static let openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let status = try IntentBridge.execute(.status)
        return .result(value: redlightStatusText(status))
    }
}

struct ListRedlightDisplaysIntent: AppIntent {
    static let title: LocalizedStringResource = "List Redlight Displays"
    static let openAppWhenRun = false
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[DisplayEntity]> {
        let status = try IntentBridge.execute(.displayList)
        return .result(value: status.displays.map(DisplayEntity.init))
    }
}

func redlightStatusText(_ status: Status) -> String {
    guard status.running else { return "Redlight is not running." }
    let displays = status.displays.map { "\($0.number). \($0.name): \($0.enabled ? "on" : "off"), inversion \($0.inverted ? "on" : "off")" }.joined(separator: "\n")
    var text = "Redlight \(status.on ? "on" : "off")\nColor: \(status.color.set)% (target \(status.color.target)%)\nWhite Point: \(status.whitepoint.set)% (target \(status.whitepoint.target)%)\nAdaptive: \(status.adaptive ? "on" : "off")"
    text += "\nPreset: \(status.activePreset?.rawValue ?? "custom")\nLimits: Color \(status.limits.color.min)–\(status.limits.color.max)%, White Point \(status.limits.whitepoint.min)–\(status.limits.whitepoint.max)%"
    text += "\nAppearance: \(status.appearance.rawValue)\nLaunch at Login: \(status.login.enabled ? "on" : "off")\(status.login.requiresApproval ? " (approval needed)" : "")\nVersion: \(status.version)"
    if let elevation = status.elevation { text += "\nSolar elevation: \(elevation)°" }
    if !status.statusLine.isEmpty { text += "\n" + status.statusLine }
    if status.fading { text += "\nFading" }
    if !displays.isEmpty { text += "\n" + displays }
    return text
}

struct RedlightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnOnRedlightIntent(), phrases: ["Turn on \(.applicationName)"], shortTitle: "Turn On", systemImageName: "sun.max")
        AppShortcut(intent: TurnOffRedlightIntent(), phrases: ["Turn off \(.applicationName)"], shortTitle: "Turn Off", systemImageName: "sun.max")
        AppShortcut(intent: SetRedlightPresetIntent(), phrases: ["Set \(.applicationName) to \(\.$preset)"], shortTitle: "Set Preset", systemImageName: "sun.horizon")
        AppShortcut(intent: TurnOnRedlightAdaptiveIntent(), phrases: ["Turn on \(.applicationName) Adaptive"], shortTitle: "Adaptive", systemImageName: "sun.and.horizon")
    }
}
