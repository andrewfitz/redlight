import Foundation
import Testing
@testable import Redlight

private final class ClientProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var port = false
    private var launches = 0
    private var commands: [RedlightCommand] = []
    func hasPort() -> Bool { lock.withLock { port } }
    func started() { lock.withLock { launches += 1; port = true } }
    func makePortAvailable() { lock.withLock { port = true } }
    func sent(_ command: RedlightCommand) -> Status {
        lock.withLock { commands.append(command) }
        return Status(on: true)
    }
    var launchCount: Int { lock.withLock { launches } }
    var sentCommands: [RedlightCommand] { lock.withLock { commands } }
}

@Suite struct CommandClientTests {
    @Test func stoppedReadAndStopCommandsNeverLaunch() async throws {
        for command: RedlightCommand in [.status, .master(.off), .quit] {
            let probe = ClientProbe()
            let client = CommandClient(hasPort: { probe.hasPort() }, isAppRunning: { false },
                                       launch: { probe.started() }, send: { probe.sent($0) })
            #expect(try await client.execute(command) == .notRunning)
            #expect(probe.launchCount == 0 && probe.sentCommands.isEmpty)
        }
    }

    @Test func stoppedToggleResolvesToExplicitOnBeforeStartupRestoresFlags() async throws {
        let probe = ClientProbe()
        let client = CommandClient(hasPort: { probe.hasPort() }, isAppRunning: { false },
                                   launch: { probe.started() }, send: { command in
            // Startup has restored an enabled external monitor. Toggle here would turn it off.
            #expect(command == .master(.on))
            return probe.sent(command)
        })
        #expect(try await client.execute(.master(.toggle)).on)
        #expect(probe.launchCount == 1)
        #expect(probe.sentCommands == [.master(.on)])
    }

    @Test func everyOtherStoppedCommandLaunchesAndSendsUnchanged() async throws {
        let commands: [RedlightCommand] = [
            .master(.on), .color(60), .whitepoint(80), .reset(.color), .preset(.night),
            .savePreset(.day), .adaptive(.on), .limits(.color, min: 0, max: 100),
            .displayList, .display(.all, .on), .invert(.all, .on), .appearance(.dark), .login(true), .update,
        ]
        for command in commands {
            let probe = ClientProbe()
            let client = CommandClient(hasPort: { probe.hasPort() }, isAppRunning: { false },
                                       launch: { probe.started() }, send: { probe.sent($0) })
            _ = try await client.execute(command)
            #expect(probe.launchCount == 1 && probe.sentCommands == [command])
        }
    }

    @Test func existingStartingOwnerAndRunningToggleNeverLaunchAnotherCopy() async throws {
        let probe = ClientProbe()
        probe.makePortAvailable()
        let client = CommandClient(hasPort: { probe.hasPort() }, isAppRunning: { false },
                                   launch: { probe.started() }, send: { probe.sent($0) })
        _ = try await client.execute(.master(.toggle))
        #expect(probe.launchCount == 0)
        #expect(probe.sentCommands == [.master(.toggle)])
    }

    @Test func runningAppWithoutPortWaitsForOwnerInsteadOfLaunching() async throws {
        let probe = ClientProbe()
        let client = CommandClient(hasPort: { probe.hasPort() }, isAppRunning: { true },
                                   isLegacyAppRunning: { false },
                                   launch: { probe.started() }, send: { probe.sent($0) },
                                   wait: { probe.makePortAvailable() })
        _ = try await client.execute(.color(70))
        #expect(probe.launchCount == 0 && probe.sentCommands == [.color(70)])
    }

    @Test func legacyRunningAppAndFailedLaunchAreExitTwo() async {
        let probe = ClientProbe()
        let legacy = CommandClient(hasPort: { false }, isAppRunning: { true }, isLegacyAppRunning: { true }, launch: { probe.started() },
                                   send: { probe.sent($0) }, startupTimeout: .zero)
        do { _ = try await legacy.execute(.status); Issue.record("Legacy server unexpectedly replied") }
        catch let error as CommandError { #expect(error.exitCode == 2); #expect(error.message.contains("running")) }
        catch { Issue.record("Unexpected error \(error)") }
        #expect(probe.launchCount == 0)
        let failed = CommandClient(hasPort: { false }, isAppRunning: { false },
                                   launch: { throw CommandError.system("launch failed") })
        do { _ = try await failed.execute(.master(.on)); Issue.record("Launch unexpectedly succeeded") }
        catch let error as CommandError { #expect(error.exitCode == 2 && error.message == "launch failed") }
        catch { Issue.record("Unexpected error \(error)") }
    }

    @Test func newlyAvailablePortWinsOverStaleLegacyVerdict() async throws {
        let probe = ClientProbe()
        let client = CommandClient(hasPort: { probe.hasPort() }, isAppRunning: { true },
                                   isLegacyAppRunning: { probe.makePortAvailable(); return true },
                                   launch: { probe.started() }, send: { probe.sent($0) })
        _ = try await client.execute(.master(.toggle))
        #expect(probe.launchCount == 0 && probe.sentCommands == [.master(.toggle)])
    }

    @Test func bundleResolutionUsesExecutableRatherThanSymlinkDirectory() throws {
        let executable = URL(fileURLWithPath: "/Applications/Redlight.app/Contents/MacOS/Redlight")
        #expect(try CommandClient.appBundleURL(forExecutable: executable).path == "/Applications/Redlight.app")
        #expect(throws: CommandError.self) {
            try CommandClient.appBundleURL(forExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/redlight"))
        }
    }

    @Test func cliExitCodesAndJSONErrorsAreScriptReadable() async throws {
        let stopped = CommandClient(hasPort: { false }, isAppRunning: { false })
        var output = ""
        var errorOutput = ""
        #expect(await RedlightCLI.run(arguments: ["status", "--json"], client: stopped,
                                     writeOutput: { output = $0 }, writeError: { errorOutput = $0 }) == 0)
        #expect(try JSONDecoder().decode(Status.self, from: Data(output.utf8)) == .notRunning)
        #expect(errorOutput.isEmpty)
        #expect(await RedlightCLI.run(arguments: ["color", "nan", "--json"], client: stopped,
                                     writeOutput: { output = $0 }, writeError: { errorOutput = $0 }) == 1)
        #expect(try JSONDecoder().decode(CommandReply.self, from: Data(errorOutput.utf8)).error?.code == .invalidInput)
        let failed = CommandClient(hasPort: { true }, send: { _ in throw CommandError.unreachable("unavailable") })
        #expect(await RedlightCLI.run(arguments: ["on", "--json"], client: failed,
                                     writeOutput: { output = $0 }, writeError: { errorOutput = $0 }) == 2)
        #expect(try JSONDecoder().decode(CommandReply.self, from: Data(errorOutput.utf8)).error?.code == .unreachable)
        #expect(await RedlightCLI.run(arguments: ["--help"], client: stopped, writeOutput: { output = $0 }) == 0)
        #expect(output.contains("Usage:"))
        #expect(await RedlightCLI.run(arguments: ["--version"], client: stopped, writeOutput: { output = $0 }) == 0)
        #expect(!output.isEmpty)
    }

    @Test func humanStatusReportsEveryFeatureAndTarget() async {
        let status = Status(
            on: true, displays: [.init(key: "display", number: 1, name: "Studio", enabled: true, inverted: true)],
            color: .init(set: 42, target: 43), whitepoint: .init(set: 70, target: 71),
            activePreset: .night, adaptive: true, elevation: -10.5, statusLine: "Night below horizon",
            limits: .init(color: .init(min: 10, max: 80), whitepoint: .init(min: 30, max: 90)),
            appearance: .dark, login: .init(enabled: true, requiresApproval: true), version: "1.2", fading: true
        )
        let client = CommandClient(hasPort: { true }, send: { _ in status })
        var output = ""
        #expect(await RedlightCLI.run(arguments: ["status"], client: client, writeOutput: { output = $0 }) == 0)
        for field in ["Redlight 1.2: on", "42.0% (target 43.0%)", "70.0% (target 71.0%)",
                      "color 10.0–80.0%", "white point 30.0–90.0%", "Preset: night", "Adaptive: on",
                      "fading", "Elevation: -10.5°", "Appearance: dark", "Launch at login: on (approval required)",
                      "Night below horizon", "1: Studio", "invert on"] {
            #expect(output.contains(field))
        }
    }
}
