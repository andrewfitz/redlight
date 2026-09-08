import Testing
@testable import Redlight

@MainActor @Suite struct MenuBarViewTests {
    @Test func sunArcAccessibilityReportsCurrentElevationWithoutPhaseJargon() {
        let summary = SunArcView.accessibilitySummary(currentElevation: 0.8)
        #expect(summary.contains("Solar elevation +1°"))
        #expect(!summary.lowercased().contains("marker"))
        #expect(!summary.lowercased().contains("civil"))
        #expect(!summary.lowercased().contains("nautical"))
        #expect(!summary.lowercased().contains("astronomical"))
    }
}
