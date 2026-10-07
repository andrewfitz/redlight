import Foundation
import Testing
@testable import Redlight

@Suite struct CommandWireTests {
    @Test func everyCommandRoundTripsThroughVersionedRequest() throws {
        var commands: [RedlightCommand] = [.status, .displayList, .color(0), .color(100), .whitepoint(25), .whitepoint(100), .login(true), .login(false), .update, .quit]
        for state in CommandSwitch.allCases {
            commands += [.master(state), .adaptive(state)]
            for selector: CommandDisplaySelector in [.number(2), .name("Studio Display"), .all, .key("uuid-display-1")] {
                commands += [.display(selector, state), .invert(selector, state)]
            }
        }
        for channel in CommandChannel.allCases {
            commands += [.reset(channel), .limits(channel, min: channel == .color ? 0 : 25, max: 100)]
        }
        for preset in CommandPreset.allCases { commands += [.preset(preset), .savePreset(preset)] }
        for appearance in CommandAppearance.allCases { commands.append(.appearance(appearance)) }
        for command in commands {
            let request = CommandRequest(command: command)
            let decoded = try JSONDecoder().decode(CommandRequest.self, from: JSONEncoder().encode(request))
            #expect(decoded == request)
            try decoded.validateVersion()
        }
    }

    @Test func statusAndErrorRepliesRoundTrip() throws {
        let status = Status(
            on: true,
            displays: [.init(key: "uuid", number: 1, name: "Retina", enabled: true, inverted: false)],
            color: .init(set: 30, target: 30), whitepoint: .init(set: 45, target: 45),
            activePreset: .night, adaptive: true, elevation: -14.2, statusLine: "Following the sun",
            appearance: .dark, login: .init(enabled: true, requiresApproval: false), version: "1.2.3", fading: true
        )
        for reply in [CommandReply.success(status), .failure(.invalidInput("color must be 0 to 100")), .failure(.system("Needs approval"), status: status), .failure(.unreachable("Redlight did not respond"))] {
            let data = try JSONEncoder().encode(reply)
            let decoded = try JSONDecoder().decode(CommandReply.self, from: data)
            #expect(decoded == reply)
            try decoded.validateVersion()
        }
    }

    @Test func stoppedStatusHasOnlyRunningAndDecodesWithoutOtherFields() throws {
        let encoded = try JSONEncoder().encode(Status.notRunning)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Bool])
        #expect(object == ["running": false])
        let decoded = try JSONDecoder().decode(Status.self, from: Data("{\"running\":false}".utf8))
        #expect(decoded == .notRunning)
    }

    @Test func versionMismatchRequiresUpdateAndSystemExitCode() {
        for version in [0, 2, -1] {
            do {
                try CommandRequest(v: version, command: .status).validateVersion()
                Issue.record("Accepted protocol version \(version)")
            } catch let error as CommandError {
                #expect(error.code == .system)
                #expect(error.exitCode == 2)
                #expect(error.message.contains("update Redlight"))
            } catch { Issue.record("Unexpected error: \(error)") }
            do {
                try CommandReply(v: version, ok: true, status: .notRunning).validateVersion()
                Issue.record("Accepted reply protocol version \(version)")
            } catch let error as CommandError {
                #expect(error.exitCode == 2)
            } catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func invalidCommandPayloadIsRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CommandRequest.self, from: Data("{\"v\":1,\"command\":{\"unknown\":{}}}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CommandRequest.self, from: Data("{\"command\":{\"status\":{}}}".utf8))
        }
    }

    @Test func exitCodesAndPresetCLIValuesAreStable() {
        #expect(CommandError.invalidInput("bad input").exitCode == 1)
        #expect(CommandError.system("failed action").exitCode == 2)
        #expect(CommandError.unreachable("no server").exitCode == 2)
        #expect(CommandPreset.allCases.map(\.rawValue) == ["day", "warm", "sunset", "night", "deep-red"])
        #expect(CommandPreset.allCases.map(\.index) == Array(Preset.defaults.indices))
    }

    @Test func everyPopoverDescriptorDispatchesTheActualPayload() {
        let pairs: [(PopoverAction, RedlightCommand)] = [
            (.master(.toggle), .master(.toggle)),
            (.reset(.color), .reset(.color)), (.reset(.whitepoint), .reset(.whitepoint)),
            (.preset(.deepRed), .preset(.deepRed)), (.savePreset(.warm), .savePreset(.warm)),
            (.adaptive(.off), .adaptive(.off)),
            (.display(.key("selected-display"), .on), .display(.key("selected-display"), .on)),
            (.invert(.key("selected-display"), .off), .invert(.key("selected-display"), .off)),
            (.appearance(.toggle), .appearance(.toggle)), (.login(true), .login(true)),
            (.update, .update), (.quit, .quit)
        ]
        for descriptor in PopoverActionDescriptor.allCases {
            #expect(pairs.contains { $0.0.descriptor == descriptor })
        }
        for (action, expected) in pairs { #expect(action.command == expected) }
        for preset in CommandPreset.allCases {
            #expect(PopoverAction.preset(preset).command == .preset(preset))
            #expect(PopoverAction.savePreset(preset).command == .savePreset(preset))
        }
    }
}
