import Foundation
import Testing
@testable import Redlight

@Suite struct CommandWireTests {
    @Test func incompatibleReplySchemaStillReportsVersionMismatch() {
        let data = Data(#"{"v":99,"ok":true,"status":{"futureStatus":"on"}}"#.utf8)
        #expect(throws: CommandError.system("Command protocol version mismatch; update Redlight.")) {
            try CommandClient.decodeReply(data)
        }
    }

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
                     .wake(.at(hour: 7, minute: 0)), .wake(.at(hour: 23, minute: 59)), .wake(.off),
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
        for version in [0, 1, 2, 3, 5, -1] {
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

    @Test func pauseTimestampAcceptsFractionalSecondsAndRejectsMalformedDates() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Status())) as? [String: Any])
        object["pausedUntil"] = "1970-01-01T00:00:01.500Z"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Status.self, from: data).pausedUntil == Date(timeIntervalSince1970: 1.5))
        object["pausedUntil"] = "invalid"
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Status.self, from: invalid) }
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

    @Test func theProtocolKeepsTheVersionTwoPauseEncoding() throws {
        #expect(CommandRequest.currentVersion == 4)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (command, json) in [(RedlightCommand.pause(.on), #"{"pause":{"_0":"on"}}"#),
                                (.pause(.off), #"{"pause":{"_0":"off"}}"#)] {
            #expect(String(decoding: try encoder.encode(command), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(RedlightCommand.self, from: Data(json.utf8)) == command)
        }
    }

    @Test func wakeIsAnAdditiveProtocolFourCommandAndStatusField() throws {
        #expect(CommandRequest.currentVersion == 4)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (command, json) in [(RedlightCommand.wake(.at(hour: 7, minute: 5)), #"{"wake":{"_0":{"at":{"hour":7,"minute":5}}}}"#),
                                (.wake(.off), #"{"wake":{"_0":{"off":{}}}}"#)] {
            #expect(String(decoding: try encoder.encode(command), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(RedlightCommand.self, from: Data(json.utf8)) == command)
            #expect(!command.isReadOnly)
        }

        let status = Status(on: true, adaptive: true, bedtime: "22:30", wake: "07:05")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(object["wake"] as? String == "07:05")
        #expect(try JSONDecoder().decode(Status.self, from: JSONEncoder().encode(status)) == status)
        object.removeValue(forKey: "wake")
        let older = try JSONDecoder().decode(Status.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.bedtime == "22:30" && older.wake == nil)
        let unset = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Status(on: true))) as? [String: Any])
        #expect(unset["wake"] == nil)
    }

    @Test func bedtimeIsAnAdditiveProtocolThreeCommandAndStatusField() throws {
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
        let data = Data(#"{"v":\#(CommandRequest.currentVersion),"command":{"unknown":{}}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CommandRequest.self, from: data)
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
        #expect(CommandPreset.late.index == Preset.defaults.count - 1)
    }

    /// The preset is named Late, but both directions of the wire keep "deep-red": a peer on
    /// the same protocol version that predates the rename neither sends nor decodes "late".
    @Test func latePresetKeepsItsDeepRedWireValueInBothDirections() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json(_ command: RedlightCommand) throws -> String {
            String(decoding: try encoder.encode(CommandRequest(command: command)), as: UTF8.self)
        }
        let apply = #"{"command":{"preset":{"_0":"deep-red"}},"v":\#(CommandRequest.currentVersion)}"#
        let save = #"{"command":{"savePreset":{"_0":"deep-red"}},"v":\#(CommandRequest.currentVersion)}"#
        #expect(try json(.preset(.late)) == apply)
        #expect(try json(.savePreset(.late)) == save)
        #expect(try JSONDecoder().decode(CommandRequest.self, from: Data(apply.utf8)).command == .preset(.late))
        #expect(try JSONDecoder().decode(CommandRequest.self, from: Data(save.utf8)).command == .savePreset(.late))

        let status = Status(on: true, activePreset: .late, version: "1.2")
        let encoded = try JSONEncoder().encode(CommandReply.success(status))
        let reply = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((reply["status"] as? [String: Any])?["activePreset"] as? String == "deep-red")

        // A reply as an app from before the rename writes it.
        let older = Data(#"""
        {"v":\#(CommandRequest.currentVersion),"ok":true,"status":{"running":true,"on":true,"displays":[],"color":{"set":0,"target":0},\#
        "whitepoint":{"set":30,"target":30},"activePreset":"deep-red","adaptive":false,"statusLine":"",\#
        "limits":{"color":{"min":0,"max":100},"whitepoint":{"min":30,"max":100}},"appearance":"dark",\#
        "login":{"enabled":false,"requiresApproval":false},"version":"1.5.1","fading":false}}
        """#.utf8)
        #expect(try CommandClient.decodeReply(older).activePreset == .late)
    }

    @Test func everyPopoverDescriptorDispatchesTheActualPayload() {
        let pairs: [(PopoverAction, RedlightCommand)] = [
            (.master(.toggle), .master(.toggle)), (.pause(.on), .pause(.on)),
            (.reset(.color), .reset(.color)), (.reset(.whitepoint), .reset(.whitepoint)),
            (.preset(.late), .preset(.late)), (.savePreset(.warm), .savePreset(.warm)),
            (.adaptive(.off), .adaptive(.off)),
            (.display(.key("selected-display"), .on), .display(.key("selected-display"), .on)),
            (.invert(.key("selected-display"), .off), .invert(.key("selected-display"), .off)),
            (.appearance(.toggle), .appearance(.toggle)), (.login(true), .login(true)),
            (.update, .update), (.quit, .quit),
            (.pauseFor(.minutes(60)), .pauseFor(.minutes(60))), (.pauseFor(.untilSunrise), .pauseFor(.untilSunrise)),
            (.location(.manual(latitude: 51.5, longitude: -0.13)), .location(.manual(latitude: 51.5, longitude: -0.13))),
            (.location(.automatic), .location(.automatic)),
            (.bedtime(.at(hour: 22, minute: 30)), .bedtime(.at(hour: 22, minute: 30))), (.bedtime(.off), .bedtime(.off)),
            (.wake(.at(hour: 7, minute: 0)), .wake(.at(hour: 7, minute: 0))), (.wake(.off), .wake(.off)),
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
