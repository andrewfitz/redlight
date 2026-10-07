import Foundation
import Testing
@testable import Redlight

@Suite struct EntryRouterTests {
    @Test @MainActor func legacyPeerCheckExcludesSelfAndTerminatedPeers() throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        try EntryRouter.requireNoLegacyApplication(peers: [
            .init(pid: ownPID, terminated: false, finishedLaunching: true),
            .init(pid: ownPID + 1, terminated: true, finishedLaunching: true),
            .init(pid: ownPID + 2, terminated: false, finishedLaunching: false),
        ])
        #expect(throws: CommandError.self) {
            try EntryRouter.requireNoLegacyApplication(peers: [.init(pid: ownPID + 1, terminated: false, finishedLaunching: true)])
        }
    }
    @Test func argumentRoutingIsCaseSensitiveAndPreservesLaunchServices() {
        for args in [
            ["/usr/local/bin/redlight"], ["redlight", "bad"], ["Redlight", "status"],
            ["Redlight", "--help"], ["Redlight", "-h"], ["Redlight", "--version"],
            ["Redlight", "bad"], ["Redlight", "--json", "status"],
            ["Redlight", "--typo"], ["Redlight", "-z"],
        ] { #expect(EntryRouter.isCLI(arguments: args)) }
        for args in [
            ["/Applications/Redlight.app/Contents/MacOS/Redlight"], ["Redlight"],
            ["Redlight", "-psn_0_1234"], ["Redlight", "-NSDocumentRevisionsDebugMode", "YES"],
            ["Redlight", "-ApplePersistenceIgnoreState", "YES"],
        ] { #expect(!EntryRouter.isCLI(arguments: args)) }
    }

    @Test @MainActor func cliNeverReservesOrConstructsAppLifecycle() {
        var reserved = false
        var appInitialized = false
        var delivered: [String] = []
        let code = EntryRouter.run(arguments: ["redlight", "status"], reserveOwner: {
            reserved = true
            return 1
        }, runApplication: { _ in appInitialized = true }, runCLI: {
            delivered = $0
            return 0
        })
        #expect(code == 0)
        #expect(delivered == ["status"])
        #expect(!reserved && !appInitialized)
    }

    @Test @MainActor func duplicateNeverRunsRecoveryOrTermination() {
        var appCallbacks = 0
        var cliCallbacks = 0
        let code = EntryRouter.run(arguments: ["Redlight"], reserveOwner: { () throws -> Int in
            throw CommandError.unreachable("Taken")
        }, runApplication: { _ in appCallbacks += 1 }, runCLI: { _ in
            cliCallbacks += 1
            return 0
        }, reportError: { _ in })
        #expect(code == 2)
        #expect(appCallbacks == 0 && cliCallbacks == 0)
    }

    @Test @MainActor func reservationPrecedesApplicationCallbacks() {
        var events: [String] = []
        let code = EntryRouter.run(arguments: ["Redlight"], reserveOwner: {
            events.append("reserved")
            return 7
        }, runApplication: { owner in
            #expect(owner == 7)
            events.append("recovery-model-lifecycle")
        }, runCLI: { _ in 9 })
        #expect(code == 0)
        #expect(events == ["reserved", "recovery-model-lifecycle"])
    }
}
