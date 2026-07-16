import Testing
@testable import Redlight

@MainActor @Suite struct MenuBarViewTests {
    @Test func sunArcAccessibilityListsDegreeMarkersWithoutPhaseJargon() {
        let summary = SunArcView.accessibilitySummary(currentElevation: 0.8)
        #expect(summary.contains("Solar elevation +1°"))
        for marker in SolarCurve.elevationMarkers {
            #expect(summary.contains(SunArcView.degreeLabel(marker.elevation)))
        }
        #expect(!summary.lowercased().contains("civil"))
        #expect(!summary.lowercased().contains("nautical"))
        #expect(!summary.lowercased().contains("astronomical"))
    }
}
