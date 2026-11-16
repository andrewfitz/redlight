import Foundation
import Testing
@testable import Redlight

@Suite struct CommandWireTests {
    @Test func everyCommandRoundTripsThroughVersionedRequest() throws {
        var commands: [RedlightCommand] = [.status, .displayList, .color(0), .color(100), .whitepoint(25), .whitepoint(100), .login(true), .login(false), .update, .quit]
        for state in CommandSwitch.allCases {
            commands += [.master(state), .adaptive(state), .pause(state)]
            for selector: CommandDisplaySelector in [.number(2), .name("Studio Display"), .all, .key("uuid-display-1")] {
                commands += [.display(selector, state), .invert(selector, state)]
            }
        }
        for channel in CommandChannel.allCases {
            commands += [.reset(channel), .limits(channel, min: channel == .color ? 0 : 25, max: 100),
                         .step(channel, 5), .step(channel, -2.5)]
        }
        for preset in CommandPreset.allCases { commands += [.preset(preset), .savePreset(preset)] }
        for appearance in CommandAppearance.allCases { commands.append(.appearance(appearance)) }
        commands += [.pauseFor(.minutes(1)), .pauseFor(.minutes(90)), .pauseFor(.untilSunrise),
                     .location(.automatic), .location(.manual(latitude: -33.87, longitude: 151.21)),
                     .bedtime(.at(hour: 22, minute: 30)), .bedtime(.at(hour: 0, minute: 0)), .bedtime(.off),
                     .appsList, .apps(.add("com.adobe.Photoshop")), .apps(.remove("com.apple.Photos")), .apps(.clear)]
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
            appearance: .dark, login: .init(enabled: true, requiresApproval: false), version: "1.2.3", fading: true,
            pausedUntil: Date(timeIntervalSince1970: 1_800_000_000), locationSource: .manual
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
        for version in [0, 1, 2, 4, -1] {
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

    @Test func statusFromAnOlderAppDecodesWithoutPause() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Status(on: true, pausedUntil: Date()))) as? [String: Any])
        object.removeValue(forKey: "pausedUntil")
        let decoded = try JSONDecoder().decode(Status.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.on)
        #expect(decoded.pausedUntil == nil)
    }

    @Test func statusFromAnOlderAppDecodesWithoutLocationSource() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Status(on: true, locationSource: .timeZone))) as? [String: Any])
        #expect(object["locationSource"] as? String == "timeZone")
        object.removeValue(forKey: "locationSource")
        let decoded = try JSONDecoder().decode(Status.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.on)
        #expect(decoded.locationSource == nil)
        #expect(CommandLocationSource.allCases.map(\.rawValue) == ["auto", "manual", "timeZone"])
    }

    @Test func protocolThreeKeepsTheVersionTwoPauseEncoding() throws {
        #expect(CommandRequest.currentVersion == 3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (command, json) in [(RedlightCommand.pause(.on), #"{"pause":{"_0":"on"}}"#),
                                (.pause(.off), #"{"pause":{"_0":"off"}}"#)] {
            #expect(String(decoding: try encoder.encode(command), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(RedlightCommand.self, from: Data(json.utf8)) == command)
        }
    }

    @Test func bedtimeIsAnAdditiveProtocolThreeCommandAndStatusField() throws {
        #expect(CommandRequest.currentVersion == 3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (command, json) in [(RedlightCommand.bedtime(.at(hour: 22, minute: 30)), #"{"bedtime":{"_0":{"at":{"hour":22,"minute":30}}}}"#),
                                (.bedtime(.off), #"{"bedtime":{"_0":{"off":{}}}}"#)] {
            #expect(String(decoding: try encoder.encode(command), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(RedlightCommand.self, from: Data(json.utf8)) == command)
        }

        let status = Status(on: true, adaptive: true, bedtime: "22:30")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(object["bedtime"] as? String == "22:30")
        #expect(try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status)) == status)
        object.removeValue(forKey: "bedtime")
        let older = try JSONDecoder().decode(Status.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.adaptive)
        #expect(older.bedtime == nil)
        let unset = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Status(on: true))) as? [String: Any])
        #expect(unset["bedtime"] == nil)
    }

    @Test func appsAreAdditiveProtocolThreeCommandsAndStatusFields() throws {
        #expect(CommandRequest.currentVersion == 3)
        #expect(RedlightCommand.appsList.isReadOnly)
        #expect(!RedlightCommand.apps(.clear).isReadOnly)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (command, json) in [(RedlightCommand.appsList, #"{"appsList":{}}"#),
                                (.apps(.add("com.adobe.Photoshop")), #"{"apps":{"_0":{"add":{"_0":"com.adobe.Photoshop"}}}}"#),
                                (.apps(.remove("com.adobe.Photoshop")), #"{"apps":{"_0":{"remove":{"_0":"com.adobe.Photoshop"}}}}"#),
                                (.apps(.clear), #"{"apps":{"_0":{"clear":{}}}}"#)] {
            #expect(String(decoding: try encoder.encode(command), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(RedlightCommand.self, from: Data(json.utf8)) == command)
        }

        let status = Status(on: true, suspendedFor: "Photoshop", apps: ["com.adobe.Photoshop"])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(object["suspendedFor"] as? String == "Photoshop")
        #expect(object["apps"] as? [String] == ["com.adobe.Photoshop"])
        #expect(try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status)) == status)
        object.removeValue(forKey: "suspendedFor")
        object.removeValue(forKey: "apps")
        let older = try JSONDecoder().decode(Status.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.on)
        #expect(older.suspendedFor == nil)
        #expect(older.apps.isEmpty)
        // With no apps chosen and nothing suspended, a status reply is byte-for-byte unchanged.
        let unset = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Status(on: true))) as? [String: Any])
        #expect(unset["suspendedFor"] == nil)
        #expect(unset["apps"] == nil)
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
            (.master(.toggle), .master(.toggle)), (.pause(.on), .pause(.on)),
            (.reset(.color), .reset(.color)), (.reset(.whitepoint), .reset(.whitepoint)),
            (.preset(.deepRed), .preset(.deepRed)), (.savePreset(.warm), .savePreset(.warm)),
            (.adaptive(.off), .adaptive(.off)),
            (.display(.key("selected-display"), .on), .display(.key("selected-display"), .on)),
            (.invert(.key("selected-display"), .off), .invert(.key("selected-display"), .off)),
            (.appearance(.toggle), .appearance(.toggle)), (.login(true), .login(true)),
            (.update, .update), (.quit, .quit),
            (.pauseFor(.minutes(60)), .pauseFor(.minutes(60))), (.pauseFor(.untilSunrise), .pauseFor(.untilSunrise)),
            (.location(.manual(latitude: 51.5, longitude: -0.13)), .location(.manual(latitude: 51.5, longitude: -0.13))),
            (.location(.automatic), .location(.automatic)),
            (.bedtime(.at(hour: 22, minute: 30)), .bedtime(.at(hour: 22, minute: 30))), (.bedtime(.off), .bedtime(.off)),
            (.apps(.add("com.adobe.Photoshop")), .apps(.add("com.adobe.Photoshop"))),
            (.apps(.remove("com.adobe.Photoshop")), .apps(.remove("com.adobe.Photoshop"))), (.apps(.clear), .apps(.clear)),
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
