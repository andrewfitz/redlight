import Testing
@testable import Redlight

@MainActor @Suite struct CommandAppearanceTests {
    @Test func explicitAppearanceIsIdempotentAndCanBeReversed() throws {
        var dark = false
        var writes: [Bool] = []
        let appearance = AppearanceController(read: { dark }, write: {
            writes.append($0)
            dark = $0
        })
        try appearance.setDark(false)
        try appearance.setDark(true)
        try appearance.setDark(true)
        #expect(writes == [true])
        #expect(appearance.isDark)
        try appearance.setDark(false)
        #expect(writes == [true, false])
        #expect(!appearance.isDark)
    }

    @Test func commandToggleReadsExternalChangesWhileSnapshotsUseTheCache() throws {
        var dark = false
        var reads = 0
        let appearance = AppearanceController(read: { reads += 1; return dark }, write: { dark = $0 })
        let registry = TestDefaultsRegistry()
        let manager = DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [] },
            defaults: registry.makeDefaults(prefix: "CommandAppearanceTests"), location: FakeLocationProvider())
        let handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { appearance.isDark }, refreshAppearance: { appearance.refresh() },
            setAppearance: { try appearance.setDark($0) },
            login: { Status.Login(enabled: false, requiresApproval: false) }, setLogin: { _ in },
            update: {}, quit: {}, version: { "test" }))

        dark = true
        let beforeSnapshot = reads
        #expect(handler.snapshot().appearance == .light)
        #expect(reads == beforeSnapshot)
        #expect(try handler.execute(.appearance(.toggle)).appearance == .light)
        #expect(!dark)
    }

    @Test func deniedAppearanceDoesNotClaimSuccess() {
        let appearance = AppearanceController(read: { false }, write: { _ in
            throw CommandError.system("Automation permission denied.")
        })
        #expect(throws: CommandError.system("Automation permission denied.")) {
            try appearance.setDark(true)
        }
        #expect(!appearance.isDark)
    }

    @Test func failedWriteAfterExternalChangeReportsCurrentAppearance() {
        var dark = false
        let appearance = AppearanceController(read: { dark }, write: { _ in
            throw CommandError.system("Automation permission denied.")
        })
        dark = true
        #expect(throws: CommandError.self) { try appearance.setDark(false) }
        #expect(appearance.isDark)
    }

    @Test func silentBackendFailureIsReported() {
        let appearance = AppearanceController(read: { false }, write: { _ in })
        #expect(throws: CommandError.self) { try appearance.setDark(true) }
        #expect(!appearance.isDark)
    }
}
