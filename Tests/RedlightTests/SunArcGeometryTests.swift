import Foundation
import Testing
@testable import Redlight

@Suite struct SunArcGeometryTests {
    private func expectSeparated(_ guides: [SunArcGeometry.Guide]) {
        for pair in zip(guides, guides.dropFirst()) {
            #expect(pair.1.y - pair.0.y >= 4 - 1e-9)
        }
    }

    @Test func guidesUseTheSameDegreeScaleAsTheCurveAndHorizon() throws {
        let geometry = SunArcGeometry(elevations: [-30, 30], height: 70)
        // Plot runs from y=6 to y=64 and covers -33°...+33° including margins.
        let expected: [(Double, CGFloat)] = [
            (12, 24.454545), (6, 29.727273), (0, 35),
            (-6, 40.272727), (-12, 45.545455), (-18, 50.818182),
        ]
        let guides = geometry.guides()
        #expect(guides.count == expected.count)
        for (elevation, y) in expected {
            let guide = try #require(guides.first { $0.elevation == elevation })
            #expect(abs(guide.y - y) < 0.000001)
            #expect(guide.y == geometry.y(for: elevation))
        }
        expectSeparated(guides)
    }

    @Test func extremeEquatorialSpanDropsCrowdedAnchorsAndPreservesHorizon() throws {
        let geometry = SunArcGeometry(elevations: [-90, 90], height: 70)
        let guides = geometry.guides()
        #expect(guides.map(\.elevation) == [0, -18])
        let horizon = try #require(guides.first { $0.isHorizon })
        #expect(horizon.y == 35)
        for guide in guides { #expect(guide.y == geometry.y(for: guide.elevation)) }
        expectSeparated(guides)
    }

    @Test func polarAndTinySampleRangesKeepFiniteGuidesOnTheChart() throws {
        for elevations in [[20.0, 24.0], [-26.0, -24.0], [0.001, 0.002], [0.0, 0.0]] {
            let geometry = SunArcGeometry(elevations: elevations, height: 70)
            let guides = geometry.guides()
            let horizon = try #require(guides.first { $0.isHorizon })
            #expect(horizon.y == geometry.y(for: 0))
            for guide in guides {
                #expect(guide.y.isFinite)
                #expect(guide.y >= geometry.top)
                #expect(guide.y <= geometry.bottom)
                #expect(guide.y == geometry.y(for: guide.elevation))
            }
            expectSeparated(guides)
        }
        let tiny = SunArcGeometry(elevations: [0.001, 0.002], height: 70).guides()
        #expect(tiny.map(\.elevation) == [6, 0, -6, -12, -18])
    }

    @Test func horizonWinsAgainstDuplicateAndNearbyAnchorsWithoutMovingThem() throws {
        let geometry = SunArcGeometry(elevations: [-30, 30], height: 70)
        let guides = geometry.guides(elevations: [0, 0, 0.1, -0.1, 6, 12, .nan, .infinity])
        #expect(guides.map(\.elevation) == [12, 6, 0])
        #expect(try #require(guides.first { $0.isHorizon }).y == geometry.y(for: 0))
        expectSeparated(guides)
    }

    @Test func tinyCanvasKeepsOnlyHorizonAndEmptySamplesHaveASafeScale() {
        for height: CGFloat in [0, 3, 8, 12, 14] {
            let geometry = SunArcGeometry(elevations: [], height: height)
            let guides = geometry.guides()
            #expect(guides.count == 1)
            #expect(guides.first?.isHorizon == true)
            #expect(guides.first?.y.isFinite == true)
            #expect(geometry.top >= 0)
            #expect(geometry.bottom <= height)
        }
        let geometry = SunArcGeometry(elevations: [.nan, .infinity], height: 70)
        #expect(geometry.y(for: 0).isFinite)
        expectSeparated(geometry.guides())
    }
}
