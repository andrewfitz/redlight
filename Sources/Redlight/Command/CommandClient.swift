import AppKit
import CoreFoundation
import Foundation
import MachO

struct CommandClient: Sendable {
    var hasPort: @Sendable () -> Bool
    var isAppRunning: @Sendable () async -> Bool
    var isLegacyAppRunning: @Sendable () async -> Bool
    var launch: @Sendable () async throws -> Void
    var send: @Sendable (RedlightCommand) async throws -> Status
    var wait: @Sendable () async throws -> Void
    var startupTimeout: Duration

    init(
        portName: String = CommandServer.portName,
        hasPort: (@Sendable () -> Bool)? = nil,
        isAppRunning: @escaping @Sendable () async -> Bool = {
            await MainActor.run { !RedlightRunningPeer.others(RedlightRunningPeer.current()).isEmpty }
        },
        isLegacyAppRunning: @escaping @Sendable () async -> Bool = {
            await MainActor.run { RedlightRunningPeer.others(RedlightRunningPeer.current()).contains(where: \.finishedLaunching) }
        },
        launch: @escaping @Sendable () async throws -> Void = { try await launchOwnApplication() },
        send: (@Sendable (RedlightCommand) async throws -> Status)? = nil,
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) },
        startupTimeout: Duration = .seconds(5)
    ) {
        self.hasPort = hasPort ?? { CFMessagePortCreateRemote(nil, portName as CFString) != nil }
        self.isAppRunning = isAppRunning
        self.isLegacyAppRunning = isLegacyAppRunning
        self.launch = launch
        self.send = send ?? { command in
            try await Task.detached { try Self.sendSynchronously(command, portName: portName) }.value
        }
        self.wait = wait
        self.startupTimeout = startupTimeout
    }

    func execute(_ command: RedlightCommand) async throws -> Status {
        if hasPort() { return try await send(command) }
        let running = await isAppRunning()
        // Liveness queries suspend. A starting owner may have published its port
        // between those queries; always prefer that server over a legacy verdict.
        if hasPort() { return try await send(command) }
        if running {
            let legacy = await isLegacyAppRunning()
            if hasPort() { return try await send(command) }
            if legacy {
                throw CommandError.unreachable("Redlight is running but its command server is unavailable. Quit the older copy and reopen the current version.")
            }
        }
        if !running {
            switch command {
            case .status, .master(.off), .quit: return .notRunning
            default: break
            }
        }
        let resolved: RedlightCommand = !running && command == .master(.toggle) ? .master(.on) : command
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startupTimeout)
        if !running { try await launch() }
        while !hasPort() {
            guard clock.now < deadline else {
                throw CommandError.unreachable(running
                    ? "Redlight is running but its command server is unavailable. Quit the older copy and reopen the current version."
                    : "Redlight did not start its command server within five seconds.")
            }
            try await wait()
        }
        return try await send(resolved)
    }

    /// Public internally for detached transport tests; never call on a server's main actor.
    static func sendSynchronously(_ command: RedlightCommand, portName: String) throws -> Status {
        try sendRequestSynchronously(CommandRequest(command: command), portName: portName)
    }

    static func sendRequestSynchronously(_ request: CommandRequest, portName: String) throws -> Status {
        try sendRawRequestSynchronously(JSONEncoder().encode(request), portName: portName)
    }

    static func sendRawRequestSynchronously(_ data: Data, portName: String) throws -> Status {
        guard let remote = CFMessagePortCreateRemote(nil, portName as CFString) else {
            throw CommandError.unreachable("Redlight's command server is unavailable.")
        }
        var replyData: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(remote, 1, data as CFData, 5, 5, CFRunLoopMode.defaultMode.rawValue, &replyData)
        guard result == kCFMessagePortSuccess, let replyData else {
            throw CommandError.unreachable("Redlight did not reply to the command (transport error \(result)).")
        }
        let reply: CommandReply
        do {
            reply = try JSONDecoder().decode(CommandReply.self, from: replyData.takeRetainedValue() as Data)
        } catch {
            throw CommandError.unreachable("Redlight returned an invalid command reply: \(error.localizedDescription)")
        }
        try reply.validateVersion()
        guard reply.ok, let status = reply.status else {
            throw reply.error ?? CommandError.system("Redlight returned no command result.")
        }
        return status
    }

    static func realExecutableURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw CommandError.system("Unable to locate the Redlight executable.")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
    }

    static func appBundleURL(forExecutable executable: URL) throws -> URL {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else {
            throw CommandError.unreachable("Run the redlight CLI from an installed Redlight.app, or start Redlight first.")
        }
        return bundle
    }

    @MainActor
    static func launchOwnApplication() async throws {
        let bundle = try appBundleURL(forExecutable: realExecutableURL())
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = ApplicationLaunchCompletion(continuation)
            completion.timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(5))
                    completion.finish(.failure(.unreachable("Redlight did not launch within five seconds.")))
                } catch { /* Completion cancelled its timeout. */ }
            }
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
                let result: Result<Void, CommandError>
                if let error { result = .failure(.system("Unable to launch Redlight: \(error.localizedDescription)")) }
                else if app == nil { result = .failure(.system("Unable to launch Redlight.")) }
                else { result = .success(()) }
                Task { @MainActor in completion.finish(result) }
            }
        }
    }
}

@MainActor
private final class ApplicationLaunchCompletion {
    private var continuation: CheckedContinuation<Void, Error>?
    var timeout: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Void, CommandError>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result.mapError { $0 as Error })
    }
}
