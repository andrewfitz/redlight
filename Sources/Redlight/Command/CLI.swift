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
      on | off | toggle | status
      color <0-100> | whitepoint <25-100>
      reset <color|whitepoint>
      preset [save] <day|warm|sunset|night|deep-red>
      adaptive <on|off|toggle>
      limits <color|whitepoint> <min> <max>
      display list
      display <number|name|all> [invert] <on|off|toggle>
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
        func level(_ text: String, channel: CommandChannel) throws -> Double {
            let minimum: Double = channel == .color ? 0 : 25
            guard let value = Double(text), value.isFinite, (minimum...100).contains(value) else {
                throw CommandError.invalidInput("\(channel.rawValue) must be a finite percentage from \(Int(minimum)) to 100.")
            }
            return value
        }
        let command: RedlightCommand
        switch verb {
        case "on", "off", "toggle":
            try count(0, verb)
            command = .master(try enumeration(verb, valid: CommandSwitch.allCases))
        case "status", "update", "quit":
            try count(0, verb)
            command = verb == "status" ? .status : verb == "update" ? .update : .quit
        case "color", "whitepoint":
            try count(1, "\(verb) <percentage>")
            let value = try level(tail[0], channel: verb == "color" ? .color : .whitepoint)
            command = verb == "color" ? .color(value) : .whitepoint(value)
        case "reset":
            try count(1, "reset <color|whitepoint>")
            command = .reset(try enumeration(tail[0], valid: CommandChannel.allCases))
        case "preset":
            if tail.first == "save" {
                try count(2, "preset save <day|warm|sunset|night|deep-red>")
                command = .savePreset(try enumeration(tail[1], valid: CommandPreset.allCases))
            } else {
                try count(1, "preset <day|warm|sunset|night|deep-red>")
                command = .preset(try enumeration(tail[0], valid: CommandPreset.allCases))
            }
        case "adaptive":
            try count(1, "adaptive <on|off|toggle>")
            command = .adaptive(try enumeration(tail[0], valid: CommandSwitch.allCases))
        case "limits":
            try count(3, "limits <color|whitepoint> <min> <max>")
            let channel = try enumeration(tail[0], valid: CommandChannel.allCases)
            let minimum = try level(tail[1], channel: channel)
            let maximum = try level(tail[2], channel: channel)
            guard minimum < maximum else { throw CommandError.invalidInput("Limits require min < max.") }
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
            } else if parsed.command == .displayList {
                writeOutput(status.displays.map {
                    "\($0.number): \($0.name) — \($0.enabled ? "on" : "off"), invert \($0.inverted ? "on" : "off")"
                }.joined(separator: "\n"))
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

    private static func describe(_ status: Status) -> String {
        guard status.running else { return "not running" }
        return """
        Redlight \(status.version): \(status.on ? "on" : "off")
        Color: \(status.color.set)% (target \(status.color.target)%)
        White point: \(status.whitepoint.set)% (target \(status.whitepoint.target)%)
        Limits: color \(status.limits.color.min)–\(status.limits.color.max)%, white point \(status.limits.whitepoint.min)–\(status.limits.whitepoint.max)%
        Preset: \(status.activePreset?.rawValue ?? "custom"); Adaptive: \(status.adaptive ? "on" : "off")\(status.fading ? "; fading" : "")
        Elevation: \(status.elevation.map { "\($0)°" } ?? "unavailable")
        Appearance: \(status.appearance.rawValue); Launch at login: \(status.login.enabled ? "on" : "off")\(status.login.requiresApproval ? " (approval required)" : "")
        \(status.statusLine)
        \(status.displays.map { "\($0.number): \($0.name) — \($0.enabled ? "on" : "off"), invert \($0.inverted ? "on" : "off")" }.joined(separator: "\n"))
        """
    }
}
