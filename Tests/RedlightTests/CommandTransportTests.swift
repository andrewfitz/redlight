import CoreFoundation
import Foundation
import Testing
@testable import Redlight

@Suite(.serialized) struct CommandTransportTests {
    @MainActor
    private func pumpTrackingMode(_ mode: CFRunLoopMode) -> CFRunLoopRunResult {
        CFRunLoopRunInMode(mode, 5, false)
    }

    // Other main-actor tests can keep the Swift executor busy without servicing
    // Core Foundation sources. Drive the server's run loop while its client waits.
    @MainActor
    private func exchange(_ send: @escaping @Sendable () async throws -> Status) async throws -> Status {
        let finished = DispatchSemaphore(value: 0)
        let client = Task.detached {
            defer { finished.signal() }
            return try await send()
        }
        pumpDefaultMode(until: finished)
        return try await client.value
    }

    @MainActor
    private func pumpDefaultMode(until finished: DispatchSemaphore) {
        while finished.wait(timeout: .now()) == .timedOut {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
    }

    @Test @MainActor func serverServicesCommandsInTrackingCommonMode() async throws {
        let name = "com.redlight.test.\(UUID().uuidString)"
        let modeName = "com.redlight.test.tracking.\(UUID().uuidString)"
        let mode = CFRunLoopMode(rawValue: modeName as CFString)
        let server = try CommandServer.reserve(name: name)
        var servicingMode: String?
        try server.installHandler { _ in
            servicingMode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String }
            CFRunLoopStop(CFRunLoopGetMain())
            return Status(on: true)
        }
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), mode)
        let client = Task.detached {
            try CommandClient.sendSynchronously(.master(.on), portName: name)
        }
        // A tracking-mode loop cannot service a default-mode-only command source.
        // Stop from the handler, or return after the transport's bounded timeout.
        let result = pumpTrackingMode(mode)
        #expect(result == .stopped)
        #expect(servicingMode == modeName)
        #expect(try await client.value.on)
        withExtendedLifetime(server) {}
    }

    @Test @MainActor func requestReplyOnMainRunLoopFromDefaultClient() async throws {
        let name = "com.redlight.test.\(UUID().uuidString)"
        let server = try CommandServer.reserve(name: name)
        var received: [RedlightCommand] = []
        try server.installHandler { command in
            received.append(command)
            return Status(on: true, color: .init(set: 42, target: 42))
        }
        let result = try await exchange { try await CommandClient(portName: name).execute(.color(42)) }
        #expect(result.on && result.color.set == 42)
        #expect(received == [.color(42)])
        withExtendedLifetime(server) {}
    }

    @Test @MainActor func handlerErrorsCrossWireAndVersionMismatchNeverExecutes() async throws {
        let name = "com.redlight.test.\(UUID().uuidString)"
        let server = try CommandServer.reserve(name: name)
        var called = 0
        try server.installHandler { _ in
            called += 1
            throw CommandError.invalidInput("No matching display")
        }
        do {
            _ = try await exchange { try CommandClient.sendSynchronously(.display(.name("missing"), .on), portName: name) }
            Issue.record("Expected handler error")
        } catch let error as CommandError {
            #expect(error.message == "No matching display" && error.exitCode == 1)
        }
        #expect(called == 1)
        do {
            _ = try await exchange {
                try CommandClient.sendRequestSynchronously(CommandRequest(v: 99, command: .status), portName: name)
            }
            Issue.record("Expected protocol version error")
        } catch let error as CommandError { #expect(error.message.contains("update Redlight")) }
        #expect(called == 1)
        do {
            _ = try await exchange {
                try CommandClient.sendRawRequestSynchronously(Data("{\"v\":99,\"command\":{\"futureCommand\":{}}}".utf8), portName: name)
            }
            Issue.record("Unknown future command should request an update")
        } catch let error as CommandError {
            #expect(error.exitCode == 2 && error.message.contains("update Redlight"))
        }
        #expect(called == 1)
        withExtendedLifetime(server) {}
    }

    @Test @MainActor func duplicateCachedPortDoesNotInvalidateOwner() async throws {
        let name = "com.redlight.test.\(UUID().uuidString)"
        let server = try CommandServer.reserve(name: name)
        #expect(throws: CommandError.self) { try CommandServer.reserve(name: name) }
        try server.installHandler { _ in Status(on: true) }
        #expect(try await exchange { try CommandClient.sendSynchronously(.status, portName: name) }.on)
        withExtendedLifetime(server) {}
    }

    @Test func missingPortIsUnreachable() async {
        do {
            _ = try await Task.detached {
                try CommandClient.sendSynchronously(.status, portName: "com.redlight.test.\(UUID().uuidString)")
            }.value
            Issue.record("Missing port succeeded")
        } catch let error as CommandError { #expect(error.exitCode == 2) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
}
