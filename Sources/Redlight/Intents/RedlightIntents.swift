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
        ControlHandoff.shared.uninstall()
        handoff = { try await ControlHandoffClient().setOn($0) }
    }
}

enum RedlightPreset: String, AppEnum {
    case day, warm, sunset, night
    /// Saved Shortcuts store the raw value, so it keeps the preset's old name.
    case late = "deep-red"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Redlight Preset"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .day: "Day", .warm: "Warm", .sunset: "Sunset", .night: "Night", .late: "Late",
    ]
    var command: CommandPreset {
        switch self {
        case .day: .day
        case .warm: .warm
        case .sunset: .sunset
        case .night: .night
        case .late: .late
        }
    }
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
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.color: "Color Temp", .whitepoint: "White Point"]
    var command: CommandChannel { CommandChannel(rawValue: rawValue)! }
}

/// Spoken as "Make Redlight warmer". Lower Color Temp is redder, so warmer steps down.
enum RedlightAdjustment: String, AppEnum {
    case warmer, cooler, dimmer, brighter
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Adjustment"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .warmer: "warmer", .cooler: "cooler", .dimmer: "dimmer", .brighter: "brighter",
    ]
    func command(amount: Double) -> RedlightCommand {
        switch self {
        case .warmer: .step(.color, -amount)
        case .cooler: .step(.color, amount)
        case .dimmer: .step(.whitepoint, -amount)
        case .brighter: .step(.whitepoint, amount)
        }
    }
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

/// Minutes are optional so "Pause Redlight" in Siri still asks nothing and pauses for 30.
struct PauseRedlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Redlight"
    static let description = IntentDescription(
        "Suspends the color filter for 30 minutes, or for the minutes you choose (up to 24 hours). Invert stays on.")
    static let openAppWhenRun = false
    @Parameter(title: "Minutes", inclusiveRange: (1, 1440)) var minutes: Int?
    init() {}
    init(minutes: Int?) { self.minutes = minutes }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(minutes.map { .pauseFor(.minutes($0)) } ?? .pause(.on))
        return .result()
    }
}

struct PauseRedlightUntilSunriseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Redlight Until Sunrise"
    static let description = IntentDescription("Suspends the color filter until the next sunrise at Redlight's location, if one occurs within 25 hours. Invert stays on.")
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.pauseFor(.untilSunrise))
        return .result()
    }
}

struct ResumeRedlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Redlight"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.pause(.off))
        return .result()
    }
}

struct AdjustRedlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Adjust Redlight"
    static let description = IntentDescription(
        "Makes the filter warmer or cooler (Color Temp), or dimmer or brighter (White Point), from its current setting.")
    static let openAppWhenRun = false
    @Parameter(title: "Adjustment", default: .warmer) var adjustment: RedlightAdjustment
    @Parameter(title: "Amount", default: 5, inclusiveRange: (1, 100)) var amount: Double
    static var parameterSummary: some ParameterSummary {
        Summary("Make Redlight \(\.$adjustment) by \(\.$amount)%")
    }
    init() {}
    init(adjustment: RedlightAdjustment, amount: Double = 5) {
        self.adjustment = adjustment
        self.amount = amount
    }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(adjustment.command(amount: amount))
        return .result()
    }
}

struct SetRedlightColorIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Color Temp"
    static let openAppWhenRun = false
    @Parameter(title: "Color Temp", inclusiveRange: (0, 100)) var value: Double
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
    @Parameter(title: "White Point", inclusiveRange: (0, 100)) var value: Double
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

struct SetRedlightLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Location"
    static let description = IntentDescription(
        "Uses these coordinates for Adaptive instead of Location Services. South and west are negative.")
    static let openAppWhenRun = false
    @Parameter(title: "Latitude", inclusiveRange: (-90, 90)) var latitude: Double
    @Parameter(title: "Longitude", inclusiveRange: (-180, 180)) var longitude: Double
    init() {}
    init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.location(.manual(latitude: latitude, longitude: longitude)))
        return .result()
    }
}

struct UseAutomaticRedlightLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "Use Automatic Redlight Location"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.location(.automatic))
        return .result()
    }
}

struct SetRedlightBedtimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Redlight Bedtime"
    static let description = IntentDescription(
        "Adaptive reaches its deepest setting by this time (24-hour, local), even while the sun is still up. Mornings still follow the sun.")
    static let openAppWhenRun = false
    @Parameter(title: "Hour", inclusiveRange: (0, 23)) var hour: Int
    @Parameter(title: "Minute", default: 0, inclusiveRange: (0, 59)) var minute: Int
    static var parameterSummary: some ParameterSummary {
        Summary("Set Redlight bedtime to \(\.$hour):\(\.$minute)")
    }
    init() {}
    init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.bedtime(.at(hour: hour, minute: minute)))
        return .result()
    }
}

struct TurnOffRedlightBedtimeIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Redlight Bedtime"
    static let description = IntentDescription("Adaptive follows the sun alone again.")
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.bedtime(.off))
        return .result()
    }
}

struct PauseRedlightForAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Redlight for an App"
    static let description = IntentDescription(
        "Suspends the color filter whenever this app is in front. Use its bundle ID, such as com.apple.Photos. Invert stays on.")
    static let openAppWhenRun = false
    @Parameter(title: "Bundle ID") var bundleID: String
    init() {}
    init(bundleID: String) { self.bundleID = bundleID }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.apps(.add(bundleID)))
        return .result()
    }
}

struct StopPausingRedlightForAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Pausing Redlight for an App"
    static let openAppWhenRun = false
    @Parameter(title: "Bundle ID") var bundleID: String
    init() {}
    init(bundleID: String) { self.bundleID = bundleID }
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.apps(.remove(bundleID)))
        return .result()
    }
}

struct ListRedlightPauseAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Apps That Pause Redlight"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        .result(value: try IntentBridge.execute(.appsList).apps)
    }
}

struct ClearRedlightPauseAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Apps That Pause Redlight"
    static let openAppWhenRun = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        _ = try IntentBridge.execute(.apps(.clear))
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
    var text = "Redlight \(status.on ? "on" : "off")"
    if let pausedUntil = status.pausedUntil {
        text += " (paused, \(DisplayManager.pauseMinutesLeft(until: pausedUntil, now: Date())) min left)"
    }
    if let app = status.suspendedFor { text += " (suspended for \(app))" }
    text += "\nColor Temp: \(status.color.text)\nWhite Point: \(status.whitepoint.text)\nAdaptive: \(status.adaptive ? "on" : "off")"
    if let bedtime = status.bedtime { text += "\nBedtime: \(bedtime)" }
    text += "\nPreset: \(status.activePreset?.cliName ?? "custom")\nLimits: Color Temp \(status.limits.color.text), White Point \(status.limits.whitepoint.text)"
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
        AppShortcut(intent: PauseRedlightIntent(), phrases: ["Pause \(.applicationName)"], shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: ResumeRedlightIntent(), phrases: ["Resume \(.applicationName)"], shortTitle: "Resume", systemImageName: "play.fill")
        AppShortcut(intent: AdjustRedlightIntent(), phrases: ["Make \(.applicationName) \(\.$adjustment)"], shortTitle: "Adjust", systemImageName: "thermometer.sun")
    }
}
