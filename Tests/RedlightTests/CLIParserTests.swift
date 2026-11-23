import Foundation
import Testing
@testable import Redlight

@Suite struct CLIParserTests {
    @Test func everyCommandForm() throws {
        let examples: [([String], RedlightCommand)] = [
            (["on"], .master(.on)), (["off"], .master(.off)), (["toggle"], .master(.toggle)),
            (["status"], .status), (["color", "0"], .color(0)), (["color", "100"], .color(100)),
            (["whitepoint", "25"], .whitepoint(25)), (["whitepoint", "72.5"], .whitepoint(72.5)),
            (["reset", "color"], .reset(.color)), (["reset", "whitepoint"], .reset(.whitepoint)),
            (["preset", "day"], .preset(.day)), (["preset", "deep-red"], .preset(.deepRed)),
            (["preset", "save", "warm"], .savePreset(.warm)),
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
            (["color", "up"], .step(.color, 5)), (["color", "down", "2.5"], .step(.color, -2.5)),
            (["whitepoint", "down"], .step(.whitepoint, -5)), (["whitepoint", "up", "10"], .step(.whitepoint, 10)),
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
            (["apps", "list"], .appsList), (["apps", "clear"], .apps(.clear)),
            (["apps", "add", "com.adobe.Photoshop"], .apps(.add("com.adobe.Photoshop"))),
            (["apps", "remove", "com.apple.Photos"], .apps(.remove("com.apple.Photos"))),
        ]
        for (arguments, expected) in examples {
            #expect(try CLIParser.parse(arguments) == ParsedCLICommand(command: expected, json: false))
            #expect(try CLIParser.parse(arguments + ["--json"]) == ParsedCLICommand(command: expected, json: true))
            #expect(try CLIParser.parse(["--json"] + arguments).command == expected)
        }
        for preset in CommandPreset.allCases {
            #expect(try CLIParser.parse(["preset", preset.rawValue]).command == .preset(preset))
            #expect(try CLIParser.parse(["preset", "save", preset.rawValue]).command == .savePreset(preset))
        }
        for state in CommandSwitch.allCases {
            #expect(try CLIParser.parse(["adaptive", state.rawValue]).command == .adaptive(state))
            #expect(try CLIParser.parse(["display", "all", "invert", state.rawValue]).command == .invert(.all, state))
        }
    }

    @Test func invalidInputAlwaysHasExitOne() {
        let examples = [
            [], ["unknown"], ["on", "extra"], ["status", "--bad"], ["color"],
            ["color", "nan"], ["color", "inf"], ["color", "-1"], ["color", "101"],
            ["whitepoint", "24"], ["whitepoint", "101"], ["reset", "all"],
            ["preset", "noon"], ["preset", "save"], ["adaptive", "yes"],
            ["limits", "whitepoint", "24", "100"],
            ["limits", "color", "100", "0"], ["display", "0", "on"],
            ["display", "all", "invert", "yes"], ["display", "", "on"],
            ["display", "all", "wrong", "on"], ["appearance", "system"],
            ["login", "toggle"], ["--version", "extra"],
            ["pause", "now"], ["resume", "5"], ["color", "up", "0"], ["color", "down", "101"],
            ["color", "up", "nan"], ["whitepoint", "up", "5", "5"],
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
            ["apps"], ["apps", "show"], ["apps", "list", "extra"], ["apps", "clear", "all"], ["apps", "add"],
            ["apps", "remove"], ["apps", "add", ""], ["apps", "add", "com.adobe Photoshop"],
            ["apps", "add", String(repeating: "a", count: 256)], ["apps", "add", "a.b", "c.d"],
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
    }

    @Test func appsUsageAndHelpNameTheForms() {
        func message(_ arguments: [String]) -> String {
            do { _ = try CLIParser.parse(arguments) } catch let error as CommandError { return error.message } catch {}
            return ""
        }
        #expect(message(["apps"]) == "Usage: redlight apps list | apps clear | apps <add|remove> <bundle-id>")
        #expect(message(["apps", "add", "a b"]).contains("bundle ID"))
        #expect(CLIParser.help.contains("apps list | apps clear | apps <add|remove> <bundle-id>"))
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
