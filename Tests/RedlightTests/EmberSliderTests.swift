import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Redlight

/// The value ⇄ x mapping and the limit rules shared by both slider controls.
@Suite struct SliderCoreTests {
    let width: CGFloat = 240
    let inset: CGFloat = 9
    let range = 0.0...1.0

    func pos(_ v: Double) -> CGFloat {
        SliderCore.position(v, width: width, inset: inset, range: range)
    }

    @Test func mappingIsMonotonicAndInsetSymmetric() {
        #expect(pos(0) == inset)
        #expect(pos(1) == width - inset)
        #expect(abs(pos(0.5) - width / 2) < 1e-9)
        for v in stride(from: 0.1, through: 1.0, by: 0.1) {
            #expect(pos(v) > pos(v - 0.1))
        }
    }

    @Test func mappingRoundTripsAwayFromTheEnds() {
        for r in [0.0...1.0, 0.25...1.0] {
            for f in stride(from: 0.1, through: 0.9, by: 0.05) {
                let v = r.lowerBound + f * (r.upperBound - r.lowerBound)
                let x = SliderCore.position(v, width: width, inset: inset, range: r)
                let back = SliderCore.value(atX: x, width: width, inset: inset, snap: 4, range: r)
                #expect(abs(back - v) < 1e-9)
            }
        }
    }

    @Test func theEndsAreTakenExactlyWithinTheSnap() {
        for r in [0.0...1.0, 0.25...1.0] {
            func value(_ x: CGFloat) -> Double {
                SliderCore.value(atX: x, width: width, inset: inset, snap: 4, range: r)
            }
            #expect(value(-50) == r.lowerBound)
            #expect(value(0) == r.lowerBound)
            #expect(value(inset + 4) == r.lowerBound)
            #expect(value(inset + 4.5) > r.lowerBound)
            #expect(value(width - inset - 4) == r.upperBound)
            #expect(value(width - inset - 4.5) < r.upperBound)
            #expect(value(width) == r.upperBound)
            #expect(value(width + 50) == r.upperBound)
        }
    }

    @Test func clampToBandNormalizesItsBounds() {
        #expect(SliderCore.clampToBand(0.9, lower: 0.2, upper: 0.8) == 0.8)
        #expect(SliderCore.clampToBand(0.1, lower: 0.8, upper: 0.2) == 0.2)
        #expect(SliderCore.clampToBand(0.5, lower: 0.2, upper: 0.8) == 0.5)
    }

    @Test func limitsKeepTheirMinimumGap() {
        #expect(abs(SliderCore.editedValue(0.79, for: .lower, range: range, lower: 0.2, upper: 0.8, minGap: 0.05) - 0.75) < 1e-9)
        #expect(abs(SliderCore.editedValue(0.21, for: .upper, range: range, lower: 0.2, upper: 0.8, minGap: 0.05) - 0.25) < 1e-9)
        #expect(SliderCore.editedValue(-1, for: .lower, range: range, lower: 0.2, upper: 0.8, minGap: 0.05) == 0)
        #expect(SliderCore.editedValue(2, for: .upper, range: range, lower: 0.2, upper: 0.8, minGap: 0.05) == 1)
        // At the ends of the range the gap still holds.
        #expect(SliderCore.editedValue(0.01, for: .upper, range: range, lower: 0, upper: 0, minGap: 0.05) == 0.05)
        #expect(SliderCore.editedValue(0.99, for: .lower, range: range, lower: 1, upper: 1, minGap: 0.05) == 0.95)
    }

    @Test func aNarrowBandNeverMovesALimitOppositeTheRequestedDirection() {
        #expect(SliderCore.editedValue(0.53, for: .lower, range: range, lower: 0.5, upper: 0.52, minGap: 0.05) == 0.5)
        #expect(SliderCore.editedValue(0.49, for: .upper, range: range, lower: 0.5, upper: 0.52, minGap: 0.05) == 0.52)
        let widened = SliderCore.editedValue(0.49, for: .lower, range: range, lower: 0.5, upper: 0.52, minGap: 0.05)
        #expect(abs(widened - 0.47) < 1e-9)
    }

    @Test func stackedLimitsAreTakenByTheDragsDirection() {
        for pin in [0.0, 0.5, 1.0] {
            #expect(SliderCore.resolveStackedMarker(.lower, dx: 3, lower: pin, upper: pin) == .upper)
            #expect(SliderCore.resolveStackedMarker(.upper, dx: -3, lower: pin, upper: pin) == .lower)
            #expect(SliderCore.resolveStackedMarker(.lower, dx: 0, lower: pin, upper: pin) == .lower)
        }
        #expect(SliderCore.resolveStackedMarker(.lower, dx: 3, lower: 0.2, upper: 0.8) == .lower)
    }

    @Test func percentsAreWhole() {
        #expect(SliderCore.spokenPercent(0) == "0 percent")
        #expect(SliderCore.spokenPercent(0.455) == "46 percent")
        #expect(SliderCore.spokenPercent(0.2) == "20 percent")
    }
}

/// What the keys do to a focused slider handle.
@Suite struct SliderKeyStepTests {
    @Test func keysMapToSteps() {
        #expect(SliderKeyStep(.leftArrow) == .decrement)
        #expect(SliderKeyStep(.downArrow) == .decrement)
        #expect(SliderKeyStep(.rightArrow) == .increment)
        #expect(SliderKeyStep(.upArrow) == .increment)
        #expect(SliderKeyStep(.home) == .toMinimum)
        #expect(SliderKeyStep(.end) == .toMaximum)
        #expect(SliderKeyStep(.pageUp) == .pageUp)
        #expect(SliderKeyStep(.space) == nil)
        for key in SliderKeyStep.keys { #expect(SliderKeyStep(key) != nil) }
    }

    @Test func stepsAreOneAndTenWholePercents() {
        let r = 0.0...1.0
        #expect(SliderKeyStep.decrement.value(from: 0.8, in: r) == 0.79)
        #expect(SliderKeyStep.increment.value(from: 0.8, in: r) == 0.81)
        #expect(SliderKeyStep.decrement.value(from: 0.8, in: r, large: true) == 0.7)
        #expect(SliderKeyStep.increment.value(from: 0.8, in: r, large: true) == 0.9)
        #expect(SliderKeyStep.pageDown.value(from: 0.8, in: r) == 0.7)
        // From the percent shown: 45.37 % shows as 45 %.
        #expect(SliderKeyStep.increment.value(from: 0.4537, in: r) == 0.46)
        #expect(SliderKeyStep.decrement.value(from: 0.4537, in: r) == 0.44)
    }

    @Test func theEndsAreReachedExactly() {
        for r in [0.0...1.0, 0.25...1.0] {
            #expect(SliderKeyStep.toMinimum.value(from: 0.6, in: r) == r.lowerBound)
            #expect(SliderKeyStep.toMaximum.value(from: 0.6, in: r) == r.upperBound)
            #expect(SliderKeyStep.increment.value(from: 0.995, in: r) == 1)
            #expect(SliderKeyStep.increment.value(from: 0.95, in: r, large: true) == 1)
            #expect(SliderKeyStep.decrement.value(from: r.lowerBound + 0.03, in: r, large: true) == r.lowerBound)
            var v = r.lowerBound
            for _ in 0..<100 { v = SliderKeyStep.increment.value(from: v, in: r) }
            #expect(v == 1)
            for _ in 0..<100 { v = SliderKeyStep.decrement.value(from: v, in: r) }
            #expect(v == r.lowerBound)
        }
    }
}

/// The popover slider: where its pieces are drawn, and what a press does.
@Suite struct EmberSliderFaceTests {
    let width: CGFloat = 268
    let inset = EmberSliderFace.inset

    private func isClose(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }

    @Test func theFillKeepsAMinimumAtTheBottomAndEndsFlushAtTheTop() {
        for range in [0.0...1.0, 0.25...1.0] {
            let low = EmberSliderFace(value: range.lowerBound, range: range, band: nil, width: width)
            #expect(low.fill.start == 0)
            #expect(isClose(low.fill.length, EmberSliderFace.minimumFill))
            let high = EmberSliderFace(value: 1, range: range, band: nil, width: width)
            #expect(isClose(high.fill.end, width))
            #expect(isClose(width - (high.valueX + EmberSliderFace.grabSize.width / 2), EmberSliderFace.markGap))
        }
    }

    @Test func manualAndAPinnedBandShowAPlainLevel() {
        for band: ClosedRange<Double>? in [nil, 0.45...0.45] {
            let face = EmberSliderFace(value: 0.45, range: 0...1, band: band, width: width)
            #expect(face.tint == nil)
            #expect(face.fill.start == 0)
            #expect(isClose(face.fill.end, face.valueX + inset))
        }
    }

    @Test func autoFillsFromTheStartAndTintsUpToTheUpperLimit() throws {
        let manual = EmberSliderFace(value: 0.5, range: 0...1, band: nil, width: width)
        let face = EmberSliderFace(value: 0.5, range: 0...1, band: 0.2...0.8, width: width)
        // The same fill as in Manual: one colour from the start of the track.
        #expect(face.fill == manual.fill)
        let tint = try #require(face.tint)
        #expect(tint.start == face.fill.end)
        #expect(isClose(tint.end, EmberSliderFace.x(for: 0.8, width: width, range: 0...1) + inset))
        // An upper limit at the top of the range tints to the end of the pill.
        #expect(EmberSliderFace(value: 0.5, range: 0...1, band: 0.2...1, width: width).tint.map { isClose($0.end, width) } == true)
    }

    @Test func aValueOnOrAboveItsUpperLimitShowsNoTint() {
        for value in [0.8, 0.95] {
            let face = EmberSliderFace(value: value, range: 0...1, band: 0.2...0.8, width: width)
            #expect(face.tint == nil, "\(value)")
            #expect(face.fill.start == 0)
        }
        #expect(EmberSliderFace(value: 1, range: 0.25...1, band: 0.3...1, width: width).tint == nil)
    }

    @Test func theTooltipSaysWhereAutoKeepsTheValue() {
        #expect(EmberSlider.bandHelp(label: "Color temp", band: 0.595...0.918)
                == "Auto keeps color temp between 60% and 92%. Change the range in Settings.")
        #expect(EmberSlider.bandHelp(label: "White point", band: nil) == "")
        #expect(EmberSlider.bandHelp(label: "White point", band: 1...1) == "")
    }

    @Test func aPressOffTheGrabberTakesTheValueAtThePointer() {
        let valueX = EmberSliderFace.x(for: 0.8, width: width, range: 0...1)
        let x = EmberSliderFace.x(for: 0.3, width: width, range: 0...1)
        var drag = EmberSliderDrag(start: CGPoint(x: x, y: 14), valueX: valueX)
        let pressed = drag.value(pointerX: x, width: width, range: 0...1)
        #expect(pressed.map { abs($0 - 0.3) < 1e-9 } == true)
        // Then it follows the pointer 1:1.
        let moved = drag.value(pointerX: x + 25.4, width: width, range: 0...1)
        #expect(moved.map { abs($0 - (0.3 + 25.4 / (width - 2 * inset))) < 1e-9 } == true)
    }

    @Test func aClickOnTheGrabberChangesNothingAndADragKeepsItsGrip() {
        let valueX = EmberSliderFace.x(for: 0.45, width: width, range: 0...1)
        var drag = EmberSliderDrag(start: CGPoint(x: valueX + 2, y: 20), valueX: valueX)
        #expect(drag.value(pointerX: valueX + 2, width: width, range: 0...1) == nil)
        // Moved by 10 pt: the value moves by 10 pt, not to the pointer.
        let moved = drag.value(pointerX: valueX + 12, width: width, range: 0...1)
        let expected = EmberSliderFace.value(atX: valueX + 10, width: width, range: 0...1)
        #expect(moved == expected)
        // Just outside the grabber's reach a press jumps.
        var beside = EmberSliderDrag(start: CGPoint(x: valueX + EmberSliderFace.grabReach + 0.5, y: 14), valueX: valueX)
        #expect(beside.value(pointerX: valueX + EmberSliderFace.grabReach + 0.5, width: width, range: 0...1) != nil)
    }

    @Test func aDragPastEitherEndReachesItExactly() {
        for range in [0.0...1.0, 0.25...1.0] {
            let valueX = EmberSliderFace.x(for: 0.6, width: width, range: range)
            var right = EmberSliderDrag(start: CGPoint(x: valueX, y: 14), valueX: valueX)
            #expect(right.value(pointerX: width + 30, width: width, range: range) == range.upperBound)
            // A grip a little left of the grabber's centre still reaches the end.
            var gripped = EmberSliderDrag(start: CGPoint(x: valueX + 3, y: 14), valueX: valueX)
            #expect(gripped.value(pointerX: width, width: width, range: range) == range.upperBound)
            #expect(gripped.value(pointerX: 0, width: width, range: range) == range.lowerBound)
            // A press near either end takes the end itself.
            var nearEnd = EmberSliderDrag(start: CGPoint(x: width - 4, y: 14), valueX: valueX)
            #expect(nearEnd.value(pointerX: width - 4, width: width, range: range) == range.upperBound)
            var nearStart = EmberSliderDrag(start: CGPoint(x: 4, y: 14), valueX: valueX)
            #expect(nearStart.value(pointerX: 4, width: width, range: range) == range.lowerBound)
        }
    }

    @Test func theGrabberGrowsWithItsState() {
        let sizes = [EmberSlider.Emphasis.rest, .hover, .pressed, .focused].map(EmberSlider.grabberSize)
        #expect(sizes[0] == EmberSliderFace.grabSize)
        for (a, b) in zip(sizes, sizes.dropFirst()) { #expect(b.height > a.height) }
        #expect(sizes[3].height < EmberMetrics.sliderHeight)
    }
}

/// The Settings range control: which thumb a press takes, and how a drag moves it.
@Suite struct EmberRangeSliderTests {
    let width: CGFloat = 244
    let range = 0.0...1.0

    private func face(_ lower: Double, _ upper: Double) -> EmberRangeFace {
        EmberRangeFace(lower: lower, upper: upper, range: range, width: width)
    }

    /// `#require` for a proposal, which has to be made outside the macro: it mutates the drag.
    private func required(_ proposal: (bound: SliderCore.Bound, value: Double)?,
                          sourceLocation: SourceLocation = #_sourceLocation) throws
        -> (bound: SliderCore.Bound, value: Double) {
        try #require(proposal, sourceLocation: sourceLocation)
    }

    @Test func thumbsAreEasyToGrab() {
        #expect(EmberRangeFace.hitSize >= 24)
        #expect(EmberRangeFace.hitSize > EmberRangeFace.thumbDiameter)
        #expect(EmberRangeSlider.thumbDiameter(.pressed) > EmberRangeSlider.thumbDiameter(.rest))
    }

    @Test func aPressTakesTheNearerThumbAndHoldsItUntilItMoves() throws {
        let f = face(0.2, 0.8)
        var drag = EmberRangeDrag(start: CGPoint(x: f.lowerX + 6, y: 14), face: f)
        #expect(drag.bound == .lower && drag.isOnThumb)
        #expect(drag.proposal(pointerX: f.lowerX + 6, width: width, range: range,
                              lower: 0.2, upper: 0.8, minGap: 0.05) == nil)
        let moved = try required(drag.proposal(pointerX: f.lowerX + 16, width: width, range: range,
                                               lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(moved.bound == .lower)
        #expect(abs(moved.value - EmberRangeFace.value(atX: f.lowerX + 10, width: width, range: range)) < 1e-9)
        let upper = EmberRangeDrag(start: CGPoint(x: f.upperX - 13, y: 14), face: f)
        #expect(upper.bound == .upper && upper.isOnThumb)
    }

    @Test func aPressOnTheTrackJumpsTheNearerThumbThere() throws {
        let f = face(0.2, 0.8)
        let x = EmberRangeFace.x(for: 0.45, width: width, range: range)
        var drag = EmberRangeDrag(start: CGPoint(x: x, y: 14), face: f)
        #expect(drag.bound == .lower && !drag.isOnThumb)
        let pressed = try required(drag.proposal(pointerX: x, width: width, range: range,
                                                 lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(abs(pressed.value - 0.45) < 1e-9)
    }

    @Test func thumbsStopAtTheMinimumGapAndReachTheEnds() throws {
        let f = face(0.2, 0.8)
        var lower = EmberRangeDrag(start: CGPoint(x: f.lowerX, y: 14), face: f)
        let pushed = try required(lower.proposal(pointerX: width, width: width, range: range,
                                                 lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(pushed.bound == .lower && abs(pushed.value - 0.75) < 1e-9)
        let toStart = try required(lower.proposal(pointerX: -20, width: width, range: range,
                                                  lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(toStart.value == 0)
        var upper = EmberRangeDrag(start: CGPoint(x: f.upperX, y: 14), face: f)
        let toEnd = try required(upper.proposal(pointerX: width + 20, width: width, range: range,
                                                lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(toEnd.value == 1)
    }

    @Test func stackedThumbsComeApartInTheDragsDirection() throws {
        let f = face(0.6, 0.6)
        #expect(f.isStacked && f.lowerX == f.upperX)
        for (dx, bound) in [(CGFloat(-12), SliderCore.Bound.lower), (12, .upper)] {
            var drag = EmberRangeDrag(start: CGPoint(x: f.lowerX, y: 14), face: f)
            #expect(drag.awaitsDirection)
            #expect(drag.proposal(pointerX: f.lowerX, width: width, range: range,
                                  lower: 0.6, upper: 0.6, minGap: 0.05) == nil)
            let moved = try required(drag.proposal(pointerX: f.lowerX + dx, width: width, range: range,
                                                   lower: 0.6, upper: 0.6, minGap: 0.05))
            #expect(moved.bound == bound)
            #expect(bound == .lower ? moved.value <= 0.55 + 1e-9 : moved.value >= 0.65 - 1e-9)
            #expect(!drag.awaitsDirection)
        }
        // Off the thumbs, the side of the press decides.
        let left = EmberRangeDrag(start: CGPoint(x: f.lowerX - 40, y: 14), face: f)
        #expect(left.bound == .lower && !left.awaitsDirection)
        let right = EmberRangeDrag(start: CGPoint(x: f.lowerX + 40, y: 14), face: f)
        #expect(right.bound == .upper && !right.awaitsDirection)
    }

    @Test func theRangeIsWrittenAsPercents() {
        #expect(AutoRangeRow.rangeText(lower: 0.2, upper: 1) == "20–100%")
        #expect(AutoRangeRow.rangeText(lower: 0.595, upper: 0.918) == "60–92%")
        #expect(AutoRangeRow.rangeText(lower: 1, upper: 1) == "Fixed at 100%")
        #expect(AutoRangeRow.defaultRange(.color) == 0...1)
        #expect(AutoRangeRow.defaultRange(.whitepoint) == 0.3...1)
    }
}

/// The popover's sliders write through `setIntensityPushingBand` and its white point twin:
/// any value, in Auto too, without the screen jumping on the next tick.
@MainActor @Suite struct SliderPushTests {
    /// The early afternoon in Chicago on the March equinox: Auto rests on the top of its bands.
    static let afternoon = Date(timeIntervalSince1970: 1_774_030_000)
    /// 18:40 the same day: the sun a few degrees up, Auto partway down its bands.
    static let evening = Date(timeIntervalSince1970: 1_774_050_000)

    private let registry = TestDefaultsRegistry()

    private func makeManager(
        _ values: [String: Any], at now: Date = SliderPushTests.afternoon, location hasLocation: Bool = true
    ) -> (DisplayManager, UserDefaults, MockGammaController) {
        let defaults = registry.makeDefaults()
        for (key, value) in values { defaults.set(value, forKey: key) }
        let location = FakeLocationProvider()
        if hasLocation { location.coordinate = (41.88, -87.63) }
        let gamma = MockGammaController()
        let manager = DisplayManager(
            gamma: gamma, getDisplayIDs: { [1] },
            getDisplayName: { _ in "Display" }, getDisplayPersistenceKey: { _ in "push-display" },
            getMainDisplayID: { 1 }, defaults: defaults, location: location, now: { now },
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0, peekTransitionDuration: 0,
            locationPromptActivation: {})
        manager.setEnabled(true, for: 1)
        return (manager, defaults, gamma)
    }

    private static let auto: [String: Any] = [
        "redlight.adaptiveEnabled": true, "redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8,
        "redlight.adaptiveWpMin": 0.45, "redlight.adaptiveWpMax": 1.0,
    ]

    @Test func aValueAboveTheBandPushesTheUpperLimitAndStays() {
        // A white point under 100 %, so the displays get a filter and not the neutral restore.
        let (manager, defaults, gamma) = makeManager(Self.auto.merging(["redlight.adaptiveWpMax": 0.9]) { $1 })
        #expect(abs(manager.intensity - 0.8) < 1e-9)
        manager.setIntensityPushingBand(1.0)
        #expect(manager.intensity == 1.0)
        #expect(manager.adaptiveMax == 1.0 && manager.adaptiveMin == 0.2)
        // Measured against the curve of the wider band: at the top of it, no adjustment.
        #expect(manager.adaptiveIntensityAdjustment == 0)
        manager.applyAdaptive()
        #expect(manager.intensity == 1.0)
        #expect(gamma.applyCalls.last?.intensity == 1.0)
        #expect(defaults.double(forKey: "redlight.adaptiveMax") == 1.0)
    }

    @Test func aValueBelowTheBandPushesTheLowerLimitAndStays() {
        let (manager, _, _) = makeManager(Self.auto)
        manager.setIntensityPushingBand(0)
        #expect(manager.intensity == 0)
        #expect(manager.adaptiveMin == 0 && manager.adaptiveMax == 0.8)
        manager.applyAdaptive()
        #expect(manager.intensity == 0)
    }

    @Test func aPushPartwayDownTheCurveKeepsTheValueOnTheNextTick() {
        let (manager, _, _) = makeManager(Self.auto, at: Self.evening)
        let start = manager.intensity
        #expect(start > 0.2 + 1e-6 && start < 0.8 - 1e-6, "the evening is not partway down the band: \(start)")
        manager.setIntensityPushingBand(0.95)
        #expect(manager.intensity == 0.95 && manager.adaptiveMax == 0.95)
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.95) < 1e-9, "the next tick moved the value to \(manager.intensity)")
        // Back inside the band: the limit stays where it was pushed.
        manager.setIntensityPushingBand(0.5)
        #expect(manager.intensity == 0.5 && manager.adaptiveMax == 0.95)
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.5) < 1e-9)
    }

    @Test func aValueInsideTheBandLeavesTheLimits() {
        let (manager, _, _) = makeManager(Self.auto)
        manager.setIntensityPushingBand(0.5)
        #expect(manager.intensity == 0.5)
        #expect(manager.adaptiveMin == 0.2 && manager.adaptiveMax == 0.8)
    }

    @Test func aPinnedBandMovesWithTheValue() {
        let (manager, _, _) = makeManager(Self.auto.merging(
            ["redlight.adaptiveMin": 0.6, "redlight.adaptiveMax": 0.6]) { $1 })
        manager.setIntensityPushingBand(0.3)
        #expect(manager.intensity == 0.3 && manager.adaptiveMin == 0.3 && manager.adaptiveMax == 0.3)
        manager.setIntensityPushingBand(1)
        #expect(manager.intensity == 1 && manager.adaptiveMin == 1 && manager.adaptiveMax == 1)
        manager.applyAdaptive()
        #expect(manager.intensity == 1)
    }

    @Test func theWhitePointPushesItsOwnLimits() {
        let (manager, _, _) = makeManager(Self.auto)
        manager.setWhitepointPushingBand(0.1)
        #expect(manager.whitepoint == 0.25 && manager.adaptiveWpMin == 0.25 && manager.adaptiveWpMax == 1)
        #expect(manager.adaptiveMin == 0.2 && manager.adaptiveMax == 0.8, "the colour temp's limits moved")
        manager.applyAdaptive()
        #expect(manager.whitepoint == 0.25)
        // A pinned white point (as the owner keeps it) moves with the value.
        let (pinned, _, _) = makeManager(Self.auto.merging(
            ["redlight.adaptiveWpMin": 1.0, "redlight.adaptiveWpMax": 1.0]) { $1 })
        pinned.setWhitepointPushingBand(0.5)
        #expect(pinned.whitepoint == 0.5 && pinned.adaptiveWpMin == 0.5 && pinned.adaptiveWpMax == 0.5)
    }

    @Test func manualTakesAnyValueAndLeavesTheLimits() {
        let (manager, _, _) = makeManager(["redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8])
        manager.applyPreset(3)
        manager.setIntensityPushingBand(0)
        #expect(manager.intensity == 0 && manager.activePresetIndex == nil)
        #expect(manager.adaptiveMin == 0.2 && manager.adaptiveMax == 0.8)
        manager.setIntensityPushingBand(.nan)
        #expect(manager.intensity == 0)
    }

    @Test func withoutALocationThePushedValueWaitsForTheCurve() {
        let (manager, _, _) = makeManager(Self.auto, location: false)
        manager.setIntensityPushingBand(1)
        #expect(manager.intensity == 1 && manager.adaptiveMax == 1)
    }

    /// The range card's Reset restores the range only: the value, the preset and Auto's
    /// adjustment stay. (The slider's Reset also restores the value.)
    @Test func theRangeCardsResetLeavesTheValue() throws {
        let (manager, _, _) = makeManager(["redlight.adaptiveMin": 0.2, "redlight.adaptiveMax": 0.8,
                                          "redlight.adaptiveWpMin": 0.5])
        manager.applyPreset(3)
        let preset = manager.intensity
        let handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "Test" }))
        let dispatch = PopoverDispatch(handler: handler, session: PopoverSession())
        #expect(dispatch(.limits(.color, min: 0, max: 100)))
        #expect(manager.adaptiveMin == DisplayManager.Defaults.intensityMin)
        #expect(manager.adaptiveMax == DisplayManager.Defaults.intensityMax)
        #expect(dispatch(.limits(.whitepoint, min: 30, max: 100)))
        #expect(manager.adaptiveWpMin == DisplayManager.Defaults.whitepointMin)
        #expect(manager.intensity == preset && manager.activePresetIndex == 3)
    }
}
