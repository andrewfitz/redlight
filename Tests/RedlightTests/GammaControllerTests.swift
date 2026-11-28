import CoreGraphics
import Testing
@testable import Redlight

@Suite struct GammaControllerTests {
    @Test func saturationMatrixBlendsBetweenColorAndLuminance() {
        let full = SaturationColorMatrix.values(saturation: 1)
        #expect(full == [
            1, 0, 0, 0, 0,
            0, 1, 0, 0, 0,
            0, 0, 1, 0, 0,
            0, 0, 0, 1, 0,
        ])

        let gray = SaturationColorMatrix.values(saturation: 0)
        #expect(gray[0] == gray[5] && gray[5] == gray[10])
        #expect(gray[0] == 0.2126)
        #expect(gray[1] == 0.7152)
        #expect(gray[2] == 0.0722)
        #expect(abs(gray[0] + gray[1] + gray[2] - 1) < 0.0001)
    }

    @Test func saturationMatrixClampsItsInput() {
        #expect(SaturationColorMatrix.values(saturation: -1) == SaturationColorMatrix.values(saturation: 0))
        #expect(SaturationColorMatrix.values(saturation: 2) == SaturationColorMatrix.values(saturation: 1))
    }

    @Test func transientCaptureFailureDoesNotCompoundTheFilterOnLaterFrames() {
        var reads = 0
        var currentTable: GammaTableComposer.Table?
        let controller = GammaController(
            readTable: { _ in reads += 1; return currentTable },
            writeTable: { _, table in currentTable = table; return .success },
            resetTables: {})
        controller.applyFilter(to: 1, intensity: 0.5, whitepoint: 1, invert: false)
        controller.applyFilter(to: 1, intensity: 0.5, whitepoint: 1, invert: false)
        #expect(reads == 1)
        #expect(currentTable?.g.last == 0.5)
    }

    @Test func failedWriteDoesNotClaimTheDisplayOrResetOtherDisplaysOnRestore() {
        var resets = 0
        let controller = GammaController(
            readTable: { _ in nil },
            writeTable: { _, _ in .failure },
            resetTables: { resets += 1 })
        controller.applyFilter(to: 1, intensity: 0.5, whitepoint: 1, invert: false)
        controller.restore(1)
        controller.restoreAll()
        #expect(resets == 0)
        controller.resetForDisplayRecovery()
        #expect(resets == 1)
    }

    @Test func inversionResamplesFromCalibrationAndRestoreUsesTheNativeTable() {
        let original: GammaTableComposer.Table = (r: [0, 0.4, 0.8], g: [0, 0.6, 1], b: [0, 1, 1])
        var reads = 0
        var displayOne: GammaTableComposer.Table?
        let controller = GammaController(
            readTable: { _ in reads += 1; return original },
            writeTable: { id, table in
                if id == 1 { displayOne = table }
                return .success
            },
            resetTables: {})
        controller.applyFilter(to: 1, intensity: 0.5, whitepoint: 1, invert: false)
        controller.applyFilter(to: 2, intensity: 0.5, whitepoint: 1, invert: false)
        controller.applyFilter(to: 1, intensity: 0.5, whitepoint: 1, invert: true)
        #expect(reads == 2)
        #expect(displayOne?.r.first == 0.8)
        #expect(displayOne?.g.first == 0.5)
        #expect(displayOne?.b.first == 0)

        controller.restore(1)
        #expect(displayOne?.r == original.r)
        #expect(displayOne?.g == original.g)
        #expect(displayOne?.b == original.b)
    }

    @Test func filteredWritesPreserveEachDisplaysCalibrationResolution() {
        let controller = GammaController(
            readTable: { id in
                let size = id == 1 ? 128 : 1024
                let channel = (0..<size).map { Float($0) / Float(size - 1) }
                return (channel, channel, channel)
            },
            writeTable: { id, table in
                let size = id == 1 ? 128 : 1024
                #expect(table.r.count == size)
                #expect(table.g.count == size)
                #expect(table.b.count == size)
                #expect(table.g.last == 0.5)
                return .success
            },
            resetTables: {})
        for id: CGDirectDisplayID in [1, 2, 1] {
            controller.applyFilter(to: id, intensity: 0.5, whitepoint: 1, invert: false)
        }
    }

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
