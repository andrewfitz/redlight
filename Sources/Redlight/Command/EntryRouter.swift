import AppKit
import Foundation

struct RedlightRunningPeer: Sendable {
    var pid: Int32
    var terminated: Bool
    var finishedLaunching: Bool

    @MainActor
    static func current() -> [Self] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.redlight.app" || $0.executableURL?.lastPathComponent == "Redlight"
        }.map { Self(pid: $0.processIdentifier, terminated: $0.isTerminated, finishedLaunching: $0.isFinishedLaunching) }
    }

    static func others(_ peers: [Self], ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) -> [Self] {
        peers.filter { $0.pid != ownPID && !$0.terminated }
    }
}

/// Decides the process role before any app object, recovery hook or display owner exists.
enum EntryRouter {
    static let commands: Set<String> = [
        "on", "off", "toggle", "status", "color", "whitepoint", "reset", "preset",
        "adaptive", "limits", "display", "appearance", "login", "update", "quit",
    ]

    /// A previous version has no reservation port. Refuse to become a second gamma
    /// owner even if this version successfully reserved the new port.
    @MainActor
    static func requireNoLegacyApplication(peers: [RedlightRunningPeer]? = nil) throws {
        if RedlightRunningPeer.others(peers ?? RedlightRunningPeer.current()).contains(where: \.finishedLaunching) {
            throw CommandError.unreachable("Another Redlight copy is already running. Quit it before starting this version.")
        }
    }

    static func isCLI(arguments: [String]) -> Bool {
        guard let executable = arguments.first else { return false }
        if URL(fileURLWithPath: executable).lastPathComponent == "redlight" { return true }
        guard let first = arguments.dropFirst().first else { return false }
        if commands.contains(first) || ["--help", "-h", "--version", "--json"].contains(first) {
            return true
        }
        // LaunchServices supplies options such as -psn_…, -NSDocumentRevisionsDebugMode.
        // A bare positional argument is a mistyped CLI command, not an app launch.
        if first.hasPrefix("-psn_") || first.hasPrefix("-NS") || first.hasPrefix("-Apple") {
            return false
        }
        return true
    }

    @MainActor
    static func run<Owner>(
        arguments: [String],
        reserveOwner: () throws -> Owner,
        runApplication: (Owner) -> Void,
        runCLI: ([String]) -> Int32,
        reportError: (String) -> Void = { NSLog("Redlight: %@", $0) }
    ) -> Int32 {
        if isCLI(arguments: arguments) { return runCLI(Array(arguments.dropFirst())) }
        do {
            let owner = try reserveOwner()
            // The caller retains ownership throughout its blocking application run.
            withExtendedLifetime(owner) { runApplication(owner) }
            return 0
        } catch {
            reportError(String(describing: error))
            return 2
        }
    }
}
