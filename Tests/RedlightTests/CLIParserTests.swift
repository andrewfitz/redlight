import Foundation
import Testing
@testable import Redlight

@Suite struct CLIParserTests {
    @Test func everyCommandForm() throws {
        let examples: [([String], RedlightCommand)] = [
            (["on"], .master(.on)), (["off"], .master(.off)), (["toggle"], .master(.toggle)),
            (["status"], .status), (["color", "0"], .color(0)), (["color", "100"], .color(100)),
            (["whitepoint", "25"], .whitepoint(25)), (["whitepoint", "72.5"], .whitepoint(72.5)),
            (["saturation", "0"], .saturation(0)), (["saturation", "72.5"], .saturation(72.5)),
            // The white point runs from 0 to 100 like the colour temp.
            (["whitepoint", "0"], .whitepoint(0)), (["limits", "whitepoint", "0", "5"], .limits(.whitepoint, min: 0, max: 5)),
            (["reset", "color"], .reset(.color)), (["reset", "whitepoint"], .reset(.whitepoint)),
            (["preset", "day"], .preset(.day)), (["preset", "late"], .preset(.late)),
            (["preset", "deep-red"], .preset(.late)),
            (["preset", "save", "warm"], .savePreset(.warm)), (["preset", "save", "late"], .savePreset(.late)),
            (["preset", "save", "deep-red"], .savePreset(.late)),
            (["adaptive", "toggle"], .adaptive(.toggle)),
            (["limits", "color", "0", "100"], .limits(.color, min: 0, max: 100)),
            (["limits", "whitepoint", "25", "90"], .limits(.whitepoint, min: 25, max: 90)),
            (["limits", "color", "40", "40"], .limits(.color, min: 40, max: 40)),
            (["display", "list"], .displayList), (["display", "1", "off"], .display(.number(1), .off)),
            (["display", "Studio Display", "on"], .display(.name("Studio Display"), .on)),
            (["display", "all", "toggle"], .display(.all, .toggle)),
            (["display", "2", "invert", "toggle"], .invert(.number(2), .toggle)),
            (["appearance", "dark"], .appearance(.dark)), (["appearance", "light"], .appearance(.light)),
            (["appearance", "toggle"], .appearance(.toggle)),
            (["login", "on"], .login(true)), (["login", "off"], .login(false)),
            (["update"], .update), (["quit"], .quit),
            (["pause"], .pause(.on)), (["resume"], .pause(.off)),
            (["peek", "on"], .peek(.on)), (["peek", "off"], .peek(.off)), (["peek", "tap"], .peek(.tap)),
            (["peek", "renew"], .peek(.renew)),
            (["color", "up"], .step(.color, 5)), (["color", "down", "2.5"], .step(.color, -2.5)),
            (["whitepoint", "down"], .step(.whitepoint, -5)), (["whitepoint", "up", "10"], .step(.whitepoint, 10)),
            (["saturation", "off"], .saturationEnabled(.off)), (["saturation", "on"], .saturationEnabled(.on)),
            (["saturation", "toggle"], .saturationEnabled(.toggle)),
            (["saturation", "up"], .saturationStep(5)), (["saturation", "down", "10"], .saturationStep(-10)),
            (["pause", "90"], .pauseFor(.minutes(90))), (["pause", "1"], .pauseFor(.minutes(1))),
            (["pause", "1440"], .pauseFor(.minutes(1440))), (["pause", "until", "sunrise"], .pauseFor(.untilSunrise)),
            (["location", "40.71", "-74.01"], .location(.manual(latitude: 40.71, longitude: -74.01))),
            (["location", "-33.87", "151.21"], .location(.manual(latitude: -33.87, longitude: 151.21))),
            (["location", "-90", "-180"], .location(.manual(latitude: -90, longitude: -180))),
            (["location", "90", "180"], .location(.manual(latitude: 90, longitude: 180))),
            (["location", "auto"], .location(.automatic)),
            (["adaptive", "bedtime", "22:30"], .bedtime(.at(hour: 22, minute: 30))),
            (["adaptive", "bedtime", "0:00"], .bedtime(.at(hour: 0, minute: 0))),
            (["adaptive", "bedtime", "23:59"], .bedtime(.at(hour: 23, minute: 59))),
            (["adaptive", "bedtime", "07:05"], .bedtime(.at(hour: 7, minute: 5))),
            (["adaptive", "bedtime", "off"], .bedtime(.off)),
            (["adaptive", "wake", "7:00"], .wake(.at(hour: 7, minute: 0))),
            (["adaptive", "wake", "06:45"], .wake(.at(hour: 6, minute: 45))),
            (["adaptive", "wake", "off"], .wake(.off)),
            (["learn", "on"], .learn(.on)), (["learn", "off"], .learn(.off)),
            (["learn", "toggle"], .learn(.toggle)), (["learn", "reset"], .learn(.reset)),
            (["learn", "restore"], .learn(.restore)),
            (["apps", "list"], .appsList), (["apps", "clear"], .apps(.clear)),
            (["apps", "set", "com.adobe.Photoshop", "pause"], .apps(.set("com.adobe.Photoshop", .pause))),
            (["apps", "set", "com.adobe.Photoshop", "hold", "40", "70", "0"],
             .apps(.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70, saturation: 0)))),
            (["apps", "set", "com.apple.Photos", "shift", "0", "0", "-60"],
             .apps(.set("com.apple.Photos", .shift(color: 0, whitepoint: 0, saturation: -60)))),
            (["apps", "set", "com.adobe.Photoshop", "hold", "40", "70"],
             .apps(.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70)))),
            (["apps", "set", "com.adobe.Photoshop", "hold", "0", "100"],
             .apps(.set("com.adobe.Photoshop", .hold(color: 0, whitepoint: 100)))),
            // Signed amounts: a leading minus is a number here, not an option.
            (["apps", "set", "com.apple.Photos", "shift", "-10", "+5"],
             .apps(.set("com.apple.Photos", .shift(color: -10, whitepoint: 5)))),
            (["apps", "set", "com.apple.Photos", "shift", "-100", "100"],
             .apps(.set("com.apple.Photos", .shift(color: -100, whitepoint: 100)))),
            (["apps", "set", "com.apple.Photos", "shift", "2.5", "0"],
             .apps(.set("com.apple.Photos", .shift(color: 3, whitepoint: 0)))),
            (["apps", "remove", "com.apple.Photos"], .apps(.remove("com.apple.Photos"))),
        ]
        for (arguments, expected) in examples {
            #expect(try CLIParser.parse(arguments) == ParsedCLICommand(command: expected, json: false))
            #expect(try CLIParser.parse(arguments + ["--json"]) == ParsedCLICommand(command: expected, json: true))
            #expect(try CLIParser.parse(["--json"] + arguments).command == expected)
        }
        for preset in CommandPreset.allCases {
            // The wire spelling stays accepted so existing scripts keep working.
            for name in [preset.cliName, preset.rawValue] {
                #expect(try CLIParser.parse(["preset", name]).command == .preset(preset))
                #expect(try CLIParser.parse(["preset", "save", name]).command == .savePreset(preset))
            }
        }
        for state in CommandSwitch.allCases {
            #expect(try CLIParser.parse(["adaptive", state.rawValue]).command == .adaptive(state))
            #expect(try CLIParser.parse(["display", "all", "invert", state.rawValue]).command == .invert(.all, state))
        }
    }

    @Test func presetHelpAndErrorsNameLateWhileDeepRedStillParses() {
        func message(_ arguments: [String]) -> String {
            do { _ = try CLIParser.parse(arguments) } catch let error as CommandError { return error.message } catch {}
            return ""
        }
        #expect(CommandPreset.allCases.map(\.cliName) == ["day", "warm", "sunset", "night", "late"])
        #expect(CommandPreset(cliName: "late") == .late)
        #expect(CommandPreset(cliName: "deep-red") == .late)
        for name in ["Late", "Deep Red", "deepRed", "deep_red", ""] { #expect(CommandPreset(cliName: name) == nil) }

        #expect(CLIParser.help.contains("preset [save] <day|warm|sunset|night|late>"))
        #expect(!CLIParser.help.contains("deep-red"))
        #expect(message(["preset"]) == "Usage: redlight preset <day|warm|sunset|night|late>")
        #expect(message(["preset", "save"]) == "Usage: redlight preset save <day|warm|sunset|night|late>")
        for arguments in [["preset", "noon"], ["preset", "save", "noon"]] {
            #expect(message(arguments) == "Invalid value 'noon'; valid values: day, warm, sunset, night, late.")
        }
    }

    @Test func statusNamesLateInTextAndKeepsTheWireValueInJSON() async throws {
        let status = Status(on: true, activePreset: .late, version: "1.2")
        let client = CommandClient(hasPort: { true }, send: { _ in status })
        var output = ""
        #expect(await RedlightCLI.run(arguments: ["status"], client: client, writeOutput: { output = $0 }) == 0)
        #expect(output.contains("Preset: late;"))
        #expect(!output.localizedCaseInsensitiveContains("deep"))

        // Scripts read `--json`, so it keeps the value they already match on.
        #expect(await RedlightCLI.run(arguments: ["status", "--json"], client: client, writeOutput: { output = $0 }) == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(object["activePreset"] as? String == "deep-red")
    }

    @Test func helpListsLearn() {
        #expect(CLIParser.help.contains("learn <on|off|toggle|reset|restore>"))
        #expect(CLIParser.help.contains("peek <on|off|tap|renew>"))
    }

    @Test func invalidInputAlwaysHasExitOne() {
        let examples = [
            [], ["unknown"], ["on", "extra"], ["status", "--bad"], ["color"],
            ["color", "nan"], ["color", "inf"], ["color", "-1"], ["color", "101"],
            ["whitepoint", "-1"], ["whitepoint", "101"], ["saturation", "-1"], ["saturation", "101"],
            ["saturation", "nan"], ["reset", "all"],
            ["preset", "noon"], ["preset", "save"], ["adaptive", "yes"],
            ["learn"], ["learn", "maybe"], ["learn", "on", "now"],
            ["limits", "whitepoint", "-1", "100"],
            ["limits", "color", "100", "0"], ["display", "0", "on"],
            ["display", "all", "invert", "yes"], ["display", "", "on"],
            ["display", "all", "wrong", "on"], ["appearance", "system"],
            ["login", "toggle"], ["--version", "extra"],
            ["pause", "now"], ["resume", "5"], ["peek"], ["peek", "maybe"], ["peek", "on", "extra"],
            ["color", "up", "0"], ["color", "down", "101"],
            ["color", "up", "nan"], ["whitepoint", "up", "5", "5"],
            ["saturation", "up", "0"], ["saturation", "down", "101"],
            ["pause", "0"], ["pause", "1441"], ["pause", "-5"], ["pause", "1.5"], ["pause", "nan"],
            ["pause", "until"], ["pause", "until", "sunset"], ["pause", "90", "extra"],
            ["pause", "until", "sunrise", "extra"],
            ["location"], ["location", "40"], ["location", "91", "0"], ["location", "-90.1", "0"],
            ["location", "0", "181"], ["location", "0", "-180.5"], ["location", "nan", "0"],
            ["location", "0", "inf"], ["location", "north", "1"], ["location", "auto", "extra"],
            ["location", "1", "2", "3"],
            ["adaptive"], ["adaptive", "on", "extra"], ["adaptive", "22:30"], ["adaptive", "bedtime"],
            ["adaptive", "bedtime", "24:00"], ["adaptive", "bedtime", "22:60"], ["adaptive", "bedtime", "22"],
            ["adaptive", "bedtime", "-1:00"], ["adaptive", "bedtime", "+5:00"], ["adaptive", "bedtime", "on"],
            ["adaptive", "bedtime", "10:30pm"], ["adaptive", "bedtime", "22:30", "extra"],
            ["adaptive", "bedtime", "off", "extra"],
            ["adaptive", "wake"], ["adaptive", "wake", "24:00"], ["adaptive", "wake", "7"],
            ["adaptive", "wake", "on"], ["adaptive", "wake", "7am"], ["adaptive", "wake", "07:00", "extra"],
            ["apps"], ["apps", "show"], ["apps", "list", "extra"], ["apps", "clear", "all"],
            ["apps", "add", "com.adobe.Photoshop"], ["apps", "remove"], ["apps", "remove", "a.b", "c.d"],
            ["apps", "set"], ["apps", "set", "com.adobe.Photoshop"], ["apps", "set", "", "pause"],
            ["apps", "set", "com.adobe Photoshop", "pause"], ["apps", "set", String(repeating: "a", count: 256), "pause"],
            ["apps", "set", "a.b", "pause", "extra"], ["apps", "set", "a.b", "glow"],
            ["apps", "set", "a.b", "hold"], ["apps", "set", "a.b", "hold", "40"], ["apps", "set", "a.b", "hold", "40", "70", "101"],
            ["apps", "set", "a.b", "hold", "-1", "70"], ["apps", "set", "a.b", "hold", "40", "101"],
            ["apps", "set", "a.b", "hold", "forty", "70"], ["apps", "set", "a.b", "hold", "nan", "70"],
            ["apps", "set", "a.b", "shift", "-101", "0"], ["apps", "set", "a.b", "shift", "0", "inf"],
        ]
        for args in examples {
            do {
                _ = try CLIParser.parse(args)
                Issue.record("Accepted invalid input: \(args)")
            } catch let error as CommandError { #expect(error.exitCode == 1) }
            catch { Issue.record("Unexpected error for \(args): \(error)") }
        }
    }

    @Test func locationAndPauseErrorsNameTheValidRange() {
        func message(_ arguments: [String]) -> String {
            do { _ = try CLIParser.parse(arguments) } catch let error as CommandError { return error.message } catch {}
            return ""
        }
        #expect(message(["location", "91", "0"]).contains("Latitude"))
        #expect(message(["location", "91", "0"]).contains("90"))
        #expect(message(["location", "0", "181"]).contains("Longitude"))
        #expect(message(["location", "0", "181"]).contains("180"))
        #expect(message(["pause", "0"]).contains("1440"))
        #expect(CLIParser.help.contains("pause [minutes|until sunrise]"))
        #expect(CLIParser.help.contains("location <latitude> <longitude> | location auto"))
    }

    @Test func adaptiveBedtimeIsAddedWithoutChangingAdaptiveErrors() {
        func message(_ arguments: [String]) -> String {
            do { _ = try CLIParser.parse(arguments) } catch let error as CommandError { return error.message } catch {}
            return ""
        }
        #expect(message(["adaptive"]) == "Usage: redlight adaptive <on|off|toggle>")
        #expect(message(["adaptive", "on", "extra"]) == "Usage: redlight adaptive <on|off|toggle>")
        #expect(message(["adaptive", "yes"]) == "Invalid value 'yes'; valid values: on, off, toggle.")
        #expect(message(["adaptive", "bedtime", "24:00"]).contains("23:59"))
        #expect(message(["adaptive", "bedtime"]).contains("adaptive bedtime <HH:MM|off>"))
        #expect(CLIParser.help.contains("adaptive bedtime <HH:MM|off>"))
        #expect(message(["adaptive", "wake", "24:00"]) == Bedtime.invalidWakeMessage)
        #expect(message(["adaptive", "wake"]).contains("adaptive wake <HH:MM|off>"))
        #expect(CLIParser.help.contains("adaptive wake <HH:MM|off>"))
    }

    @Test func appsUsageAndHelpNameTheForms() {
        func message(_ arguments: [String]) -> String {
            do { _ = try CLIParser.parse(arguments) } catch let error as CommandError { return error.message } catch {}
            return ""
        }
        #expect(message(["apps"]) == "Usage: redlight apps list | apps clear | apps set <bundle-id> <rule> | apps remove <bundle-id>")
        #expect(message(["apps", "set", "a.b"])
                == "Usage: redlight apps set <bundle-id> pause | hold <color> <white> [saturation] | shift <±color> <±white> [±saturation]")
        #expect(message(["apps", "set", "a b", "pause"]).contains("bundle ID"))
        #expect(message(["apps", "set", "a.b", "hold", "120", "0"]).contains("from 0 to 100"))
        #expect(message(["apps", "set", "a.b", "shift", "120", "0"]).contains("from -100 to 100"))
        #expect(CLIParser.help.contains("apps list | apps clear | apps remove <bundle-id>"))
        #expect(CLIParser.help.contains("apps set <bundle-id> pause | hold <color> <white> [saturation] | shift <±color> <±white> [±saturation]"))
    }

    @Test func emptyDisplayListWritesNoPhantomRow() async {
        let client = CommandClient(hasPort: { true }, send: { _ in Status(displays: []) })
        var rows = [String]()
        let code = await RedlightCLI.run(arguments: ["display", "list"], client: client,
                                         writeOutput: { rows.append($0) })
        #expect(code == 0)
        #expect(rows.isEmpty)
    }

    @Test func helpAndVersionAreSuccessfulInformationalRequests() {
        #expect(throws: CLIInformation.self) { try CLIParser.parse(["--help"]) }
        #expect(throws: CLIInformation.self) { try CLIParser.parse(["color", "--help"]) }
        #expect(throws: CLIInformation.self) { try CLIParser.parse(["--version"]) }
    }
}
