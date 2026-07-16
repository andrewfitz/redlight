import CoreGraphics
import Testing
@testable import Redlight

@Suite struct GammaControllerTests {
    @Test func identityCalibrationKeepsLegacyFilterShape() {
        let table = GammaTableComposer.compose(
            original: nil, tableSize: 3,
            intensity: 0.6, whitepoint: 1, invert: false)

        #expect(table.r == [0, 0.5, 1])
        #expect(table.g == [0, 0.3, 0.6])
        #expect(abs(table.b[0] - 0) < 0.000_001)
        #expect(abs(table.b[1] - 0.1) < 0.000_001)
        #expect(abs(table.b[2] - 0.2) < 0.000_001)
    }

    @Test func filterComposesWithPerChannelCalibration() {
        let original: GammaTableComposer.Table = (
            r: [0, 0.4, 0.8],
            g: [0, 0.5, 0.9],
            b: [0, 0.6, 1]
        )
        let table = GammaTableComposer.compose(
            original: original, tableSize: 3,
            intensity: 0.5, whitepoint: 1, invert: false)

        #expect(table.r == [0, 0.4, 0.8])
        #expect(table.g == [0, 0.25, 0.45])
        #expect(table.b == [0, 0, 0])
    }

    @Test func inversionReversesTheCalibratedInput() {
        let original: GammaTableComposer.Table = (
            r: [0, 0.25, 0.8], g: [0, 0.5, 0.9], b: [0, 0.75, 1]
        )
        let table = GammaTableComposer.compose(
            original: original, tableSize: 3,
            intensity: 1, whitepoint: 1, invert: true)

        #expect(table.r == [0.8, 0.25, 0])
        #expect(table.g == [0.9, 0.5, 0])
        #expect(table.b == [1, 0.75, 0])
    }

    @Test func sourceCalibrationIsInterpolatedToOutputSize() {
        let original: GammaTableComposer.Table = (
            r: [0, 1], g: [0, 1], b: [0, 1]
        )
        let table = GammaTableComposer.compose(
            original: original, tableSize: 5,
            intensity: 1, whitepoint: 1, invert: false)

        #expect(table.r == [0, 0.25, 0.5, 0.75, 1])
    }
}
