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
            (["display", "list"], .displayList), (["display", "1", "off"], .display(.number(1), .off)),
            (["display", "Studio Display", "on"], .display(.name("Studio Display"), .on)),
            (["display", "all", "toggle"], .display(.all, .toggle)),
            (["display", "2", "invert", "toggle"], .invert(.number(2), .toggle)),
            (["appearance", "dark"], .appearance(.dark)), (["appearance", "light"], .appearance(.light)),
            (["appearance", "toggle"], .appearance(.toggle)),
            (["login", "on"], .login(true)), (["login", "off"], .login(false)),
            (["update"], .update), (["quit"], .quit),
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
            ["limits", "color", "40", "40"], ["limits", "whitepoint", "24", "100"],
            ["limits", "color", "100", "0"], ["display", "0", "on"],
            ["display", "all", "invert", "yes"], ["display", "", "on"],
            ["display", "all", "wrong", "on"], ["appearance", "system"],
            ["login", "toggle"], ["--version", "extra"],
        ]
        for args in examples {
            do {
                _ = try CLIParser.parse(args)
                Issue.record("Accepted invalid input: \(args)")
            } catch let error as CommandError { #expect(error.exitCode == 1) }
            catch { Issue.record("Unexpected error for \(args): \(error)") }
        }
    }

    @Test func helpAndVersionAreSuccessfulInformationalRequests() {
        #expect(throws: CLIInformation.self) { try CLIParser.parse(["--help"]) }
        #expect(throws: CLIInformation.self) { try CLIParser.parse(["color", "--help"]) }
        #expect(throws: CLIInformation.self) { try CLIParser.parse(["--version"]) }
    }
}
