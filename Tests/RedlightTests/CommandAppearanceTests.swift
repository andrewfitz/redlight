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
        appearance.toggle()
        #expect(writes == [true, false])
        #expect(!appearance.isDark)
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

    @Test func silentBackendFailureIsReported() {
        let appearance = AppearanceController(read: { false }, write: { _ in })
        #expect(throws: CommandError.self) { try appearance.setDark(true) }
        #expect(!appearance.isDark)
    }
}
