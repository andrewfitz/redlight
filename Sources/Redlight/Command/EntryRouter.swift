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
        // LaunchServices may supply a process serial number and Cocoa defaults.
        // Every argument must belong to that launch before starting app services.
        var options = arguments.dropFirst().makeIterator()
        while let option = options.next() {
            if option.hasPrefix("-psn_") {
                let parts = option.dropFirst(5).split(separator: "_", omittingEmptySubsequences: false)
                guard parts.count == 2, parts.allSatisfy({ UInt32($0) != nil }) else {
                    return true
                }
            } else if option.hasPrefix("-NS") || option.hasPrefix("-Apple") {
                guard options.next() != nil else { return true }
            } else {
                return true
            }
        }
        return false
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
            reportError(error.localizedDescription)
            return 2
        }
    }
}
