import ArgumentParser
import Foundation

struct ParsedCLICommand: Equatable {
    var command: RedlightCommand
    var json: Bool
}

enum CLIInformation: Error { case help, version }

private struct CommandArguments: ParsableArguments {
    @Argument(parsing: .captureForPassthrough) var values: [String] = []
}

enum CLIParser {
    static let help = """
    Usage: redlight <command> [--json]
      on | off | toggle | status | resume
      pause [minutes|until sunrise]
        Use 1–1440 minutes (default 30) or the next sunrise within 25 hours.
      peek <on|off|tap|renew>
        Renew extends an active Peek lease.
      color <0-100 | kelvin like 3400K> | whitepoint <0-100> | saturation <0-100>
      color <up|down> [step] | whitepoint <up|down> [step]
      saturation <up|down> [step] | saturation <on|off|toggle>
      reset <color|whitepoint>
      preset [save] <day|warm|sunset|night|late>
      adaptive <on|off|toggle>
      adaptive bedtime <HH:MM|off>
      adaptive wake <HH:MM|off>
      learn <on|off|toggle|reset|restore>
      location <latitude> <longitude> | location auto
      limits <color|whitepoint> <min> <max>   (color temp limits also in kelvin, like 1200K 6500K)
      display list
      display <number|name|all> [invert] <on|off|toggle>
      apps list | apps clear | apps remove <bundle-id>
      apps set <bundle-id> pause | hold <color> <white> [saturation] | shift <±color> <±white> [±saturation]
        While that app is in front: no tint, these values, or this much added to the sliders.
      appearance <light|dark|toggle>
      login <on|off> | update | quit
    Use --json for machine-readable output, --help for help, --version for version.
    """

    static func parse(_ arguments: [String]) throws -> ParsedCLICommand {
        let json = arguments.contains("--json")
        let input = arguments.filter { $0 != "--json" }
        if input.contains("--help") || input.contains("-h") { throw CLIInformation.help }
        if input == ["--version"] { throw CLIInformation.version }
        let values: [String]
        do { values = try CommandArguments.parse(input).values }
        catch { throw CommandError.invalidInput("Invalid command arguments. \(help)") }
        guard let verb = values.first else { throw CommandError.invalidInput(help) }
        let tail = Array(values.dropFirst())
        func count(_ expected: Int, _ usage: String) throws {
            guard tail.count == expected else { throw CommandError.invalidInput("Usage: redlight \(usage)") }
        }
        /// "3400K" or "3400k": a colour temperature, or nil for anything without the K.
        func kelvin(_ text: String) throws -> Double? {
            guard let last = text.last, last == "K" || last == "k" else { return nil }
            guard let value = Double(text.dropLast()), value.isFinite, value > 0 else {
                throw CommandError.invalidInput("A colour temperature is written like 3400K.")
            }
            return value
        }
        func level(_ text: String, channel: CommandChannel) throws -> Double {
            guard let value = Double(text), value.isFinite, (0...100).contains(value) else {
                throw CommandError.invalidInput("\(channel.displayName) must be a finite percentage from 0 to 100.")
            }
            return value
        }
        let command: RedlightCommand
        switch verb {
        case "on", "off", "toggle":
            try count(0, verb)
            command = .master(try enumeration(verb, valid: CommandSwitch.allCases))
        case "pause", "resume":
            if verb == "pause", !tail.isEmpty {
                command = .pauseFor(try pauseLength(tail))
                break
            }
            try count(0, verb)
            command = .pause(verb == "pause" ? .on : .off)
        case "peek":
            try count(1, "peek <on|off|tap|renew>")
            command = .peek(try enumeration(tail[0], valid: CommandPeek.allCases))
        case "status", "update", "quit":
            try count(0, verb)
            command = verb == "status" ? .status : verb == "update" ? .update : .quit
        case "color", "whitepoint", "saturation":
            if verb == "saturation" {
                if let word = tail.first, let state = CommandSwitch(rawValue: word) {
                    try count(1, "saturation <on|off|toggle>")
                    command = .saturationEnabled(state)
                    break
                }
                if let direction = tail.first, direction == "up" || direction == "down" {
                    guard tail.count <= 2 else { throw CommandError.invalidInput("Usage: redlight saturation <up|down> [step]") }
                    let amount = try tail.count == 2 ? stepAmount(tail[1]) : 5
                    command = .saturationStep(direction == "up" ? amount : -amount)
                    break
                }
                try count(1, "saturation <percentage>")
                guard let value = Double(tail[0]), value.isFinite, (0...100).contains(value) else {
                    throw CommandError.invalidInput("Saturation must be a finite percentage from 0 to 100.")
                }
                command = .saturation(value)
                break
            }
            let channel: CommandChannel = verb == "color" ? .color : .whitepoint
            if let direction = tail.first, direction == "up" || direction == "down" {
                // Words rather than +5/-5: a leading minus would parse as an option.
                guard tail.count <= 2 else { throw CommandError.invalidInput("Usage: redlight \(verb) <up|down> [step]") }
                let amount = try tail.count == 2 ? stepAmount(tail[1]) : 5
                command = .step(channel, direction == "up" ? amount : -amount)
                break
            }
            try count(1, verb == "color" ? "color <percentage | kelvin like 3400K>" : "\(verb) <percentage>")
            if verb == "color", let kelvin = try kelvin(tail[0]) {
                command = .colorKelvin(kelvin)
                break
            }
            let value = try level(tail[0], channel: channel)
            command = verb == "color" ? .color(value) : .whitepoint(value)
        case "reset":
            try count(1, "reset <color|whitepoint>")
            command = .reset(try enumeration(tail[0], valid: CommandChannel.allCases))
        case "preset":
            if tail.first == "save" {
                try count(2, "preset save <day|warm|sunset|night|late>")
                command = .savePreset(try preset(tail[1]))
            } else {
                try count(1, "preset <day|warm|sunset|night|late>")
                command = .preset(try preset(tail[0]))
            }
        case "adaptive":
            if tail.first == "bedtime" {
                try count(2, "adaptive bedtime <HH:MM|off>")
                if tail[1] == "off" { command = .bedtime(.off); break }
                let bedtime = try Bedtime.parse(tail[1])
                command = .bedtime(.at(hour: bedtime.hour, minute: bedtime.minute))
                break
            }
            if tail.first == "wake" {
                try count(2, "adaptive wake <HH:MM|off>")
                if tail[1] == "off" { command = .wake(.off); break }
                let wake = try Bedtime.parse(tail[1], invalidMessage: Bedtime.invalidWakeMessage)
                command = .wake(.at(hour: wake.hour, minute: wake.minute))
                break
            }
            try count(1, "adaptive <on|off|toggle>")
            command = .adaptive(try enumeration(tail[0], valid: CommandSwitch.allCases))
        case "learn":
            try count(1, "learn <on|off|toggle|reset|restore>")
            command = .learn(try enumeration(tail[0], valid: CommandLearn.allCases))
        case "location":
            if tail == ["auto"] { command = .location(.automatic); break }
            try count(2, "location <latitude> <longitude>, or location auto")
            let coordinate = try ManualLocation.parse(latitude: tail[0], longitude: tail[1])
            command = .location(.manual(latitude: coordinate.latitude, longitude: coordinate.longitude))
        case "limits":
            try count(3, "limits <color|whitepoint> <min> <max>")
            let channel = try enumeration(tail[0], valid: CommandChannel.allCases)
            if channel == .color {
                let low = try kelvin(tail[1]), high = try kelvin(tail[2])
                if let low, let high {
                    guard low <= high else { throw CommandError.invalidInput("Limits require min ≤ max.") }
                    command = .limitsKelvin(min: low, max: high)
                    break
                }
                guard low == nil, high == nil else {
                    throw CommandError.invalidInput("Give both color temp limits in percent, or both in kelvin.")
                }
            }
            let minimum = try level(tail[1], channel: channel)
            let maximum = try level(tail[2], channel: channel)
            guard minimum <= maximum else { throw CommandError.invalidInput("Limits require min ≤ max.") }
            command = .limits(channel, min: minimum, max: maximum)
        case "display":
            if tail == ["list"] { command = .displayList; break }
            guard tail.count == 2 || (tail.count == 3 && tail[1] == "invert") else {
                throw CommandError.invalidInput("Usage: redlight display <number|name|all> [invert] <on|off|toggle>, or display list")
            }
            let selector: CommandDisplaySelector
            if tail[0] == "all" { selector = .all }
            else if let number = Int(tail[0]) {
                guard number > 0 else { throw CommandError.invalidInput("Display numbers start at 1; use display list.") }
                selector = .number(number)
            } else {
                guard !tail[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !tail[0].hasPrefix("-") else {
                    throw CommandError.invalidInput("Specify a display number, name or all; use display list.")
                }
                selector = .name(tail[0])
            }
            let state = try enumeration(tail.last!, valid: CommandSwitch.allCases)
            command = tail.count == 3 ? .invert(selector, state) : .display(selector, state)
        case "apps":
            switch tail.first {
            case "list", "clear":
                try count(1, appsUsage)
                command = tail[0] == "list" ? .appsList : .apps(.clear)
            case "remove":
                try count(2, "apps remove <bundle-id>")
                command = .apps(.remove(try AppBundleID.validate(tail[1])))
            case "set":
                guard tail.count >= 3 else { throw CommandError.invalidInput("Usage: redlight \(appRuleUsage)") }
                command = .apps(.set(try AppBundleID.validate(tail[1]), try appRule(tail.dropFirst(2))))
            default:
                throw CommandError.invalidInput("Usage: redlight \(appsUsage)")
            }
        case "appearance":
            try count(1, "appearance <light|dark|toggle>")
            command = .appearance(try enumeration(tail[0], valid: CommandAppearance.allCases))
        case "login":
            try count(1, "login <on|off>")
            guard tail[0] == "on" || tail[0] == "off" else { throw CommandError.invalidInput("login accepts on or off.") }
            command = .login(tail[0] == "on")
        default: throw CommandError.invalidInput("Unknown command '\(verb)'. \(help)")
        }
        return ParsedCLICommand(command: command, json: json)
    }

    static let appsUsage = "apps list | apps clear | apps set <bundle-id> <rule> | apps remove <bundle-id>"
    static let appRuleUsage = "apps set <bundle-id> pause | hold <color> <white> [saturation] | shift <±color> <±white> [±saturation]"

    /// `pause`, `hold 40 70` or `shift -10 +5`: the words after `apps set <bundle-id>`.
    private static func appRule(_ words: ArraySlice<String>) throws -> AppRule {
        let words = Array(words)
        switch words.first {
        case "pause" where words.count == 1:
            return .pause
        case "hold", "shift":
            let values = words.dropFirst().compactMap(Double.init)
            guard (2...3).contains(values.count), values.count == words.count - 1 else {
                throw CommandError.invalidInput("Usage: redlight \(appRuleUsage)")
            }
            let saturation = values.count == 3 ? values[2] : nil
            return try AppRule(kind: words.first == "hold" ? .hold : .shift,
                               color: values[0], whitepoint: values[1], saturation: saturation)
        default:
            throw CommandError.invalidInput("Usage: redlight \(appRuleUsage)")
        }
    }

    /// Whole minutes keep `pause 90` unambiguous; "until sunrise" is two words.
    private static func pauseLength(_ tail: [String]) throws -> CommandPauseLength {
        if tail == ["until", "sunrise"] { return .untilSunrise }
        guard tail.count == 1, let minutes = Int(tail[0]), CommandPauseLength.minuteRange.contains(minutes) else {
            throw CommandError.invalidInput(
                "Usage: redlight pause [minutes|until sunrise]; minutes must be a whole number from 1 to 1440.")
        }
        return .minutes(minutes)
    }

    private static func preset(_ text: String) throws -> CommandPreset {
        guard let value = CommandPreset(cliName: text) else {
            throw CommandError.invalidInput(
                "Invalid value '\(text)'; valid values: \(CommandPreset.allCases.map(\.cliName).joined(separator: ", ")).")
        }
        return value
    }

    private static func stepAmount(_ text: String) throws -> Double {
        guard let value = Double(text), value.isFinite, value > 0, value <= 100 else {
            throw CommandError.invalidInput("A step must be a percentage greater than 0 and up to 100.")
        }
        return value
    }

    private static func enumeration<T: RawRepresentable>(_ text: String, valid: [T]) throws -> T where T.RawValue == String {
        guard let value = valid.first(where: { $0.rawValue == text }) else {
            throw CommandError.invalidInput("Invalid value '\(text)'; valid values: \(valid.map(\.rawValue).joined(separator: ", ")).")
        }
        return value
    }
}

enum RedlightCLI {
    static func run(
        arguments: [String], client: CommandClient = CommandClient(),
        writeOutput: (String) -> Void = { print($0) },
        writeError: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> Int32 {
        do {
            let parsed = try CLIParser.parse(arguments)
            let status = try await client.execute(parsed.command)
            if parsed.json {
                writeOutput(String(decoding: try JSONEncoder().encode(status), as: UTF8.self))
            } else if parsed.command == .status {
                writeOutput(describe(status))
            } else if parsed.command == .displayList, !status.displays.isEmpty {
                writeOutput(status.displays.map {
                    "\($0.number): \($0.name) — \($0.enabled ? "on" : "off"), invert \($0.inverted ? "on" : "off")"
                }.joined(separator: "\n"))
            } else if parsed.command == .appsList, !status.appRules.isEmpty {
                writeOutput(status.appRules.map(appRuleLine).joined(separator: "\n"))
            }
            return 0
        } catch CLIInformation.help {
            writeOutput(CLIParser.help)
            return 0
        } catch CLIInformation.version {
            writeOutput(version())
            return 0
        } catch {
            let commandError = error as? CommandError ?? .system(error.localizedDescription)
            if arguments.contains("--json"), let data = try? JSONEncoder().encode(CommandReply.failure(commandError)) {
                writeError(String(decoding: data, as: UTF8.self))
            } else { writeError(commandError.message) }
            return Int32(commandError.exitCode)
        }
    }

    /// A PATH symlink can make Bundle.main describe the link's directory. Resolve
    /// the executable before reading the shipping app's metadata, just as launch does.
    static func version(executableURL: URL? = nil) -> String {
        guard let executable = executableURL ?? (try? CommandClient.realExecutableURL()),
              let appURL = try? CommandClient.appBundleURL(forExecutable: executable.resolvingSymlinksInPath()),
              let bundle = Bundle(url: appURL),
              let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "development"
        }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return "development" }
        return AboutInfo.version(
            shortVersion: version,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// "com.adobe.Photoshop (Photoshop): hold color temp 40%, white point 70%". The bundle ID
    /// leads, so a script can take the first word.
    static func appRuleLine(_ app: Status.App) -> String {
        "\(app.bundleID)\(app.name == app.bundleID ? "" : " (\(app.name))"): \(app.rule.text)"
    }

    static func describe(_ status: Status) -> String {
        guard status.running else { return "not running" }
        return """
        Redlight \(status.version): \(status.on ? "on" : "off")\(status.pausedUntil.map { "; paused, \(DisplayManager.pauseMinutesLeft(until: $0, now: Date())) min left" } ?? "")
        Color temp: \(status.color.text)\(status.colorKelvin.map { ", \($0.text)" } ?? "")
        White point: \(status.whitepoint.text)
        Saturation: \(status.saturationText)
        Limits: color temp \(status.limits.color.text), white point \(status.limits.whitepoint.text)
        Preset: \(status.activePreset?.cliName ?? "custom"); Adaptive: \(status.adaptive ? "on" : "off")\(status.bedtime.map { "; bedtime \($0)" } ?? "")\(status.wake.map { "; wake \($0)" } ?? "")\(status.learning?.enabled == true ? "; learning" : "")\(status.fading ? "; fading" : "")\(status.learning.flatMap { $0.enabled ? "\nLearned: \($0.text)" : nil } ?? "")
        Elevation: \(status.elevation.map { "\($0)°" } ?? "unavailable")
        Appearance: \(status.appearance.rawValue); Launch at login: \(status.login.enabled ? "on" : "off")\(status.login.requiresApproval ? " (approval required)" : "")
        \(status.statusLine)
        \(status.displays.map { "\($0.number): \($0.name) — \($0.enabled ? "on" : "off"), invert \($0.inverted ? "on" : "off")" }.joined(separator: "\n"))
        """
    }
}
