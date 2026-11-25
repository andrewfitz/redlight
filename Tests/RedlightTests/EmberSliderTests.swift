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

    @Test func limitsStandTheGapApartOrMerge() {
        func lower(_ v: Double, _ lo: Double = 0.2, _ hi: Double = 0.8) -> Double {
            SliderCore.editedValue(v, for: .lower, range: range, lower: lo, upper: hi, minGap: 0.05)
        }
        func upper(_ v: Double, _ lo: Double = 0.2, _ hi: Double = 0.8) -> Double {
            SliderCore.editedValue(v, for: .upper, range: range, lower: lo, upper: hi, minGap: 0.05)
        }
        // Up to the gap a limit goes where it is taken, and to the ends of the range.
        #expect(lower(0.6) == 0.6 && upper(0.4) == 0.4)
        #expect(lower(-1) == 0 && upper(2) == 1)
        // Closer than the gap it holds at the gap, until it is more than halfway across.
        #expect(abs(lower(0.76) - 0.75) < 1e-9 && abs(lower(0.774) - 0.75) < 1e-9)
        #expect(abs(upper(0.24) - 0.25) < 1e-9 && abs(upper(0.226) - 0.25) < 1e-9)
        // Then it is on the other limit, and stays there however far past it is taken.
        #expect(lower(0.776) == 0.8 && lower(0.8) == 0.8 && lower(0.95) == 0.8 && lower(2) == 0.8)
        #expect(upper(0.224) == 0.2 && upper(0.2) == 0.2 && upper(0.05) == 0.2 && upper(-1) == 0.2)
        // A merged limit stays merged until it is taken back past halfway, and then stands
        // the gap apart.
        #expect(lower(0.78, 0.8, 0.8) == 0.8)
        #expect(abs(lower(0.77, 0.8, 0.8) - 0.75) < 1e-9 && lower(0.7, 0.8, 0.8) == 0.7)
        #expect(upper(0.22, 0.2, 0.2) == 0.2)
        #expect(abs(upper(0.23, 0.2, 0.2) - 0.25) < 1e-9 && upper(0.4, 0.2, 0.2) == 0.4)
        // On an end of the range the gap still holds for the limit that can leave it.
        #expect(upper(0.01, 0, 0) == 0 && upper(0.03, 0, 0) == 0.05)
        #expect(lower(0.99, 1, 1) == 1 && lower(0.97, 1, 1) == 0.95)
        // Where the other limit is closer to an end than the gap, there is no place apart on
        // that side: a limit merged with it stays merged, and leaves on the other side.
        #expect(lower(0, 0.02, 0.02) == 0.02 && lower(0.01, 0.02, 0.02) == 0.02)
        #expect(abs(upper(0.06, 0.02, 0.02) - 0.07) < 1e-9 && upper(0.3, 0.02, 0.02) == 0.3)
        #expect(upper(1, 0.98, 0.98) == 0.98 && abs(lower(0.94, 0.98, 0.98) - 0.93) < 1e-9)
        // A band left that narrow by the CLI stays as it is, or merges.
        #expect(lower(0.005, 0, 0.02) == 0 && lower(0.015, 0, 0.02) == 0.02)
        #expect(upper(0.995, 0.98, 1) == 1 && upper(0.985, 0.98, 1) == 0.98)
    }

    /// A band narrower than the gap without being pinned can only come from the CLI.
    @Test func aNarrowBandNeverMovesALimitOppositeTheRequestedDirection() {
        func lower(_ v: Double) -> Double {
            SliderCore.editedValue(v, for: .lower, range: range, lower: 0.5, upper: 0.52, minGap: 0.05)
        }
        func upper(_ v: Double) -> Double {
            SliderCore.editedValue(v, for: .upper, range: range, lower: 0.5, upper: 0.52, minGap: 0.05)
        }
        // Toward the other limit: left where it is, then merged past halfway.
        #expect(lower(0.505) == 0.5 && lower(0.53) == 0.52)
        #expect(upper(0.515) == 0.52 && upper(0.49) == 0.5)
        // Away: widened to the gap.
        #expect(abs(lower(0.49) - 0.47) < 1e-9)
        #expect(abs(upper(0.53) - 0.55) < 1e-9)
    }

    @Test func stackedLimitsAreTakenByTheDragsDirection() {
        for range in [0.0...1.0, 0.25...1.0] {
            let pin = 0.5
            #expect(SliderCore.resolveStackedMarker(.lower, dx: 3, lower: pin, upper: pin, range: range) == .upper)
            #expect(SliderCore.resolveStackedMarker(.upper, dx: -3, lower: pin, upper: pin, range: range) == .lower)
            #expect(SliderCore.resolveStackedMarker(.lower, dx: 0, lower: pin, upper: pin, range: range) == .lower)
            // On an end of the range only one limit can leave it, whichever way the drag starts.
            for dx in [CGFloat(-3), 3] {
                let top = range.upperBound, bottom = range.lowerBound
                #expect(SliderCore.resolveStackedMarker(.lower, dx: dx, lower: top, upper: top, range: range) == .lower)
                #expect(SliderCore.resolveStackedMarker(.upper, dx: dx, lower: top, upper: top, range: range) == .lower)
                #expect(SliderCore.resolveStackedMarker(.lower, dx: dx, lower: bottom, upper: bottom, range: range) == .upper)
            }
        }
        #expect(SliderCore.resolveStackedMarker(.lower, dx: 3, lower: 0.2, upper: 0.8, range: 0...1) == .lower)
    }

    /// From either keyboard stop of a pinned band, a key that raises moves the maximum and
    /// one that lowers moves the minimum. Apart, each stop moves its own limit.
    @Test func aKeyOnAPinnedBandMovesTheLimitThatCanGoThatWay() {
        for stop in [SliderCore.Bound.lower, .upper] {
            #expect(SliderCore.keyBound(stop, proposed: 0.61, lower: 0.6, upper: 0.6) == .upper)
            #expect(SliderCore.keyBound(stop, proposed: 0.59, lower: 0.6, upper: 0.6) == .lower)
            #expect(SliderCore.keyBound(stop, proposed: 0.6, lower: 0.6, upper: 0.6) == stop)
            #expect(SliderCore.keyBound(stop, proposed: 0.9, lower: 0.2, upper: 0.8) == stop)
        }
        // The step that follows is a real one: the band opens by the gap.
        let opened = SliderCore.steppedValue(0.61, for: .upper, range: 0...1, lower: 0.6, upper: 0.6,
                                             minGap: SliderCore.limitGap)
        #expect(abs(opened - 0.65) < 1e-9)
    }

    @Test func anEndDoesNotPullBackAHandleMovedAwayFromIt() {
        let width: CGFloat = 272, inset = EmberSliderFace.inset
        let at99 = SliderCore.position(0.99, width: width, inset: inset, range: 0...1)
        // Toward the end, and for a press at the pointer: the end, within the snap.
        #expect(SliderCore.value(atX: at99 + 1, width: width, inset: inset, snap: 4, range: 0...1) == 1)
        // Away from it: the value under the handle.
        let away = SliderCore.value(atX: at99 - 1, width: width, inset: inset, snap: 4, snapsUpper: false, range: 0...1)
        #expect(away < 0.99 && away > 0.98)
        let at1 = SliderCore.position(0.01, width: width, inset: inset, range: 0...1)
        let up = SliderCore.value(atX: at1 + 1, width: width, inset: inset, snap: 4, snapsLower: false, range: 0...1)
        #expect(up > 0.01 && up < 0.02)
        // Past the end it is still the end.
        #expect(SliderCore.value(atX: width + 5, width: width, inset: inset, snap: 4, snapsUpper: false, range: 0...1) == 1)
        #expect(SliderCore.value(atX: -5, width: width, inset: inset, snap: 4, snapsLower: false, range: 0...1) == 0)
    }

    @Test func percentsAreWhole() {
        #expect(SliderCore.spokenPercent(0) == "0 percent")
        #expect(SliderCore.spokenPercent(0.455) == "46 percent")
        #expect(SliderCore.spokenPercent(0.2) == "20 percent")
    }

    @Test func aSlidersPercentIsItsPlaceInItsOwnRange() {
        // The white point's range starts at 0.25 on the displays and at 0 % for everyone.
        let white = WhitepointScale.output
        #expect(SliderCore.percentText(0.25, in: white) == "0%")
        #expect(SliderCore.percentText(1, in: white) == "100%")
        #expect(SliderCore.percentText(0.625, in: white) == "50%")
        #expect(SliderCore.spokenPercent(0.45, in: white) == "27 percent")
        #expect(SliderCore.percentText(0.3, in: white) == "7%")
        #expect(EmberFlagFace.pinnedText(0.25, in: white) == "Fixed 0%")
        // Outside the range is an end, and the colour temp's range reads as before.
        #expect(SliderCore.percent(0.1, in: white) == 0 && SliderCore.percent(2, in: white) == 100)
        #expect(SliderCore.percentText(0.455) == "46%")
        // The gap the flags keep is 5 % of whichever slider they are under.
        #expect(SliderCore.limitGap(in: 0...1) == 0.05)
        #expect(abs(SliderCore.limitGap(in: white) - 0.0375) < 1e-12)
        // The flags write the same percent as the header: both ask the slider's range.
        let face = EmberFlagFace(lower: 0.25, upper: 0.625, range: white, width: 272)
        #expect(face.chips.map(\.text) == ["0%", "50%"])
        #expect(EmberFlagFace(lower: 1, upper: 1, range: white, width: 272).chips.map(\.text) == ["Fixed 100%"])
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

    @Test func stepsCountInThePercentTheSliderShows() {
        // On the white point's range a key is one hundredth of the way from 0.25 to 1, and
        // every stop shows a whole percent.
        let r = WhitepointScale.output
        #expect(abs(SliderKeyStep.increment.value(from: 0.25, in: r) - 0.2575) < 1e-12)
        #expect(abs(SliderKeyStep.increment.value(from: 0.625, in: r, large: true) - 0.7) < 1e-12)
        #expect(SliderKeyStep.decrement.value(from: 0.25, in: r) == 0.25)
        var value = r.lowerBound
        for step in 1...100 {
            value = SliderKeyStep.increment.value(from: value, in: r)
            #expect(SliderCore.percent(value, in: r) == step)
            #expect(abs(WhitepointScale.percent(value) - Double(step)) < 1e-6)
        }
        #expect(value == 1)
        for step in (0..<100).reversed() {
            value = SliderKeyStep.decrement.value(from: value, in: r)
            #expect(SliderCore.percent(value, in: r) == step)
        }
        #expect(value == 0.25)
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
        // A click is rarely still: under the travel that makes it a drag, still nothing.
        for jitter in [CGFloat(-1.5), -0.5, 0.5, 1.5] {
            #expect(drag.value(pointerX: valueX + 2 + jitter, width: width, range: 0...1) == nil, "\(jitter)")
        }
        #expect(!drag.isLive)
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

    /// A grabber near an end, taken and moved away from it, moves away: the end's snap only
    /// pulls a handle that is moving toward it.
    @Test func aGrabberNearAnEndCanBeTakenAwayFromIt() {
        let range = 0.0...1.0, travel = SliderCore.liveTravel
        // So close to the end that the travel which makes the press a drag ends inside the
        // end's snap: only the direction keeps the value from jumping to the end.
        let high = EmberSliderFace.x(for: 0.995, width: width, range: range)
        #expect(EmberSliderFace.value(atX: high - travel, width: width, range: range) == 1)
        var left = EmberSliderDrag(start: CGPoint(x: high, y: 14), valueX: high)
        let lowered = left.value(pointerX: high - travel, width: width, range: range)
        #expect(lowered.map { $0 < 0.995 } == true, "\(String(describing: lowered))")
        // Brought back to where it was taken, it is where it was.
        let back = left.value(pointerX: high, width: width, range: range)
        #expect(back.map { abs($0 - 0.995) < 1e-9 } == true, "\(String(describing: back))")
        var right = EmberSliderDrag(start: CGPoint(x: high, y: 14), valueX: high)
        #expect(right.value(pointerX: high + travel, width: width, range: range) == 1)

        let low = EmberSliderFace.x(for: 0.005, width: width, range: range)
        #expect(EmberSliderFace.value(atX: low + travel, width: width, range: range) == 0)
        var up = EmberSliderDrag(start: CGPoint(x: low, y: 14), valueX: low)
        let raised = up.value(pointerX: low + travel, width: width, range: range)
        #expect(raised.map { $0 > 0.005 } == true, "\(String(describing: raised))")
    }

    @Test func theGrabberGrowsWithItsState() {
        let sizes = [EmberSlider.Emphasis.rest, .hover, .pressed, .focused].map(EmberSlider.grabberSize)
        #expect(sizes[0] == EmberSliderFace.grabSize)
        for (a, b) in zip(sizes, sizes.dropFirst()) { #expect(b.height > a.height) }
        #expect(sizes[3].height < EmberMetrics.sliderHeight)
    }

    /// A press where one of Auto's limits is drawn takes the limit itself. The pointer reaches
    /// the slider through a window's coordinates, so its place is a rounding step off: the
    /// value would land that far under 20 %, and a value under the minimum moves the minimum.
    @Test func aPressWhereALimitIsDrawnTakesTheLimitItself() {
        let range = 0.0...1.0, limits = [0.2, 0.8]
        let popover = EmberMetrics.width - 2 * EmberMetrics.padding
        let at20 = EmberSliderFace.x(for: 0.2, width: popover, range: range)
        #expect(EmberSliderFace.value(atX: at20.nextDown, width: popover, range: range) < 0.2)
        #expect(EmberSliderFace.limit(atX: at20.nextDown, among: limits, width: popover, range: range) == 0.2)
        for width in [popover, 268, 300] {
            for limit in limits {
                let x = EmberSliderFace.x(for: limit, width: width, range: range)
                for dx in [CGFloat(-0.9), -0.5, 0, 0.5, 0.9] {
                    #expect(EmberSliderFace.limit(atX: x + dx, among: limits, width: width, range: range) == limit,
                            "width \(width) limit \(limit) dx \(dx)")
                }
                // Clear of the limit the value is the pointer's, on either side of it.
                for dx in [CGFloat(-2), 2] {
                    #expect(EmberSliderFace.limit(atX: x + dx, among: limits, width: width, range: range) == nil,
                            "width \(width) limit \(limit) dx \(dx)")
                }
            }
        }
        // Close limits: the nearer one. No limits: none.
        let close = [0.5, 0.502]
        let a = EmberSliderFace.x(for: 0.5005, width: popover, range: range)
        let b = EmberSliderFace.x(for: 0.5015, width: popover, range: range)
        #expect(EmberSliderFace.limit(atX: a, among: close, width: popover, range: range) == 0.5)
        #expect(EmberSliderFace.limit(atX: b, among: close, width: popover, range: range) == 0.502)
        #expect(EmberSliderFace.limit(atX: at20, among: [], width: popover, range: range) == nil)
        // A limit so near an end that its place is inside the end's own snap: still the limit,
        // where the value under the pointer would be the end.
        let at99 = EmberSliderFace.x(for: 0.99, width: popover, range: range)
        #expect(EmberSliderFace.value(atX: at99, width: popover, range: range) == 1)
        #expect(EmberSliderFace.limit(atX: at99, among: [0.2, 0.99], width: popover, range: range) == 0.99)
    }

    /// Only a limit that is still where the press found it holds the value. One the drag has
    /// pushed moves with the value, so a slow push is not taken in steps; a pinned band's pin
    /// moves with it too.
    @Test func aLimitTheDragHasPushedNoLongerHoldsTheValue() {
        let drag = EmberSliderDrag(start: CGPoint(x: 100, y: 12), valueX: 30, limits: 0.2...0.8)
        #expect(drag.restingLimits(in: 0.2...0.8) == [0.2, 0.8])
        #expect(drag.restingLimits(in: 0.2...0.83) == [0.2])
        #expect(drag.restingLimits(in: 0.15...0.8) == [0.8])
        #expect(EmberSliderDrag(start: .zero, valueX: 30, limits: 0.6...0.6).restingLimits(in: 0.6...0.6).isEmpty)
        #expect(EmberSliderDrag(start: .zero, valueX: 30).restingLimits(in: 0.2...0.8).isEmpty)
    }
}

/// Auto's limit flags under the slider: where the chips sit, and what a press on one does.
@Suite struct EmberFlagTests {
    let width: CGFloat = 268
    let range = 0.0...1.0
    /// A stand-in for the font: 6 pt a character, so placements are exact.
    private func face(_ lower: Double, _ upper: Double, range: ClosedRange<Double> = 0...1) -> EmberFlagFace {
        EmberFlagFace(lower: lower, upper: upper, range: range, width: width) { CGFloat($0.count) * 6 }
    }

    private func required(_ proposal: (bound: SliderCore.Bound, value: Double)?,
                          sourceLocation: SourceLocation = #_sourceLocation) throws
        -> (bound: SliderCore.Bound, value: Double) {
        try #require(proposal, sourceLocation: sourceLocation)
    }

    @Test func tipsPointAtTheLimitsOnTheValuesScale() throws {
        let f = face(0.6, 0.92)
        try #require(f.chips.count == 2)
        #expect(f.chips[0].bound == .lower && f.chips[0].text == "60%")
        #expect(f.chips[1].bound == .upper && f.chips[1].text == "92%")
        #expect(f.chips[0].tipX == EmberSliderFace.x(for: 0.6, width: width, range: range))
        #expect(f.chips[1].tipX == EmberSliderFace.x(for: 0.92, width: width, range: range))
        // Far enough apart: each chip is centred on its tip.
        #expect(f.chips[0].centerX == f.chips[0].tipX && f.chips[1].centerX == f.chips[1].tipX)
        // The white point's scale starts at 25 %.
        let white = face(0.3, 1, range: 0.25...1)
        #expect(white.chips[0].tipX == EmberSliderFace.x(for: 0.3, width: width, range: 0.25...1))
    }

    @Test func closeChipsSlideApartAndTheirTipsStay() throws {
        let f = face(0.45, 0.5)
        try #require(f.chips.count == 2)
        #expect(f.chips[1].centerX - f.chips[0].centerX >= EmberFlagFace.minGap - 1e-9)
        // Apart evenly about the middle of the two limits.
        let mid = (f.chips[0].tipX + f.chips[1].tipX) / 2
        #expect(abs((f.chips[0].centerX + f.chips[1].centerX) / 2 - mid) < 1e-9)
        #expect(f.chips[0].tipX == EmberSliderFace.x(for: 0.45, width: width, range: range))
        #expect(!f.chips[0].frame.intersects(f.chips[1].frame))
    }

    @Test func chipsStayInsideTheRowAtTheEnds() throws {
        for (lo, hi) in [(0.0, 0.05), (0.95, 1.0), (0.0, 1.0)] {
            let f = face(lo, hi)
            try #require(f.chips.count == 2)
            #expect(f.chips[0].frame.minX >= -1e-9, "\(lo)…\(hi)")
            #expect(f.chips[1].frame.maxX <= width + 1e-9, "\(lo)…\(hi)")
            #expect(f.chips[1].centerX - f.chips[0].centerX >= EmberFlagFace.minGap - 1e-9)
        }
    }

    @Test func aPinnedBandHasOneChip() throws {
        for pin in [0.0, 0.6, 1.0] {
            let f = face(pin, pin)
            try #require(f.chips.count == 1)
            let chip = f.chips[0]
            #expect(chip.bound == nil && chip.text == "Fixed \(Int(pin * 100))%")
            #expect(chip.frame.minX >= 0 && chip.frame.maxX <= width)
            #expect(chip.tipX == EmberSliderFace.x(for: pin, width: width, range: range))
        }
    }

    @Test func aFlagIsTakenOnlyInItsRowAndEasily() throws {
        let f = face(0.2, 0.8)
        for chip in f.chips {
            // As tall as every other control's hit area.
            #expect(chip.hitRect.width >= 28 && chip.hitRect.height >= 24)
            #expect(f.chip(at: CGPoint(x: chip.centerX, y: chip.frame.midY))?.bound == chip.bound)
            #expect(f.chip(at: CGPoint(x: chip.centerX, y: 1))?.bound == chip.bound)
        }
        // Between the flags, nothing.
        #expect(f.chip(at: CGPoint(x: width / 2, y: 12)) == nil)
        #expect(EmberFlagFace.rowHeight >= 20)
    }

    @Test func aFlagMovesFromWhereItIsTakenAndNeverJumps() throws {
        let f = face(0.2, 0.8)
        let chip = f.chips[0]
        let start = CGPoint(x: chip.centerX + 8, y: 12)
        var drag = EmberFlagDrag(start: start, chip: chip)
        #expect(drag.proposal(pointerX: start.x, width: width, range: range, lower: 0.2, upper: 0.8, minGap: 0.05) == nil)
        // A click is rarely still: under the travel that makes it a drag, still nothing.
        for jitter in [CGFloat(-1.5), 0.5, 1.5] {
            #expect(drag.proposal(pointerX: start.x + jitter, width: width, range: range,
                                  lower: 0.2, upper: 0.8, minGap: 0.05) == nil, "\(jitter)")
        }
        let moved = try required(drag.proposal(pointerX: start.x + 25.4, width: width, range: range,
                                               lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(moved.bound == .lower)
        #expect(abs(moved.value - (0.2 + 25.4 / (width - 2 * EmberSliderFace.inset))) < 1e-9)
    }

    @Test func flagsKeepTheirGapAndReachTheEndsExactly() throws {
        let f = face(0.2, 0.8)
        var lower = EmberFlagDrag(start: CGPoint(x: f.chips[0].tipX, y: 12), chip: f.chips[0])
        // Short of the maximum by less than the gap: held at the gap.
        let held = try required(lower.proposal(pointerX: EmberSliderFace.x(for: 0.77, width: width, range: range),
                                               width: width, range: range, lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(held.bound == .lower && abs(held.value - 0.75) < 1e-9)
        // Onto it and past it: merged, and the maximum is not pushed.
        let pushed = try required(lower.proposal(pointerX: width + 40, width: width, range: range,
                                                 lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(pushed.bound == .lower && pushed.value == 0.8)
        let toStart = try required(lower.proposal(pointerX: -40, width: width, range: range,
                                                  lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(toStart.value == 0)
        var upper = EmberFlagDrag(start: CGPoint(x: f.chips[1].centerX, y: 12), chip: f.chips[1])
        let toEnd = try required(upper.proposal(pointerX: width + 40, width: width, range: range,
                                                lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(toEnd.value == 1)
        // Within the snap of the end's position, exactly the end.
        var near = EmberFlagDrag(start: CGPoint(x: f.chips[1].tipX, y: 12), chip: f.chips[1])
        let snapped = try required(near.proposal(pointerX: width - EmberSliderFace.inset - 3, width: width,
                                                 range: range, lower: 0.2, upper: 0.8, minGap: 0.05))
        #expect(snapped.value == 1)
    }

    @Test func aPinnedChipSplitsInTheDragsDirection() throws {
        let f = face(0.6, 0.6)
        for (dx, bound) in [(CGFloat(-12), SliderCore.Bound.lower), (12, .upper)] {
            var drag = EmberFlagDrag(start: CGPoint(x: f.chips[0].centerX, y: 12), chip: f.chips[0])
            #expect(drag.awaitsDirection)
            let moved = try required(drag.proposal(pointerX: f.chips[0].centerX + dx, width: width, range: range,
                                                   lower: 0.6, upper: 0.6, minGap: 0.05))
            #expect(moved.bound == bound && !drag.awaitsDirection)
            #expect(bound == .lower ? moved.value <= 0.55 + 1e-9 : moved.value >= 0.65 - 1e-9)
        }
    }

    /// A click on "Fixed 60%" with a point of travel must not split the band by the whole gap.
    @Test func aClickOnAPinnedChipLeavesItPinned() {
        let f = face(0.6, 0.6)
        var drag = EmberFlagDrag(start: CGPoint(x: f.chips[0].centerX, y: 12), chip: f.chips[0])
        for jitter in [CGFloat(-1.5), -0.5, 0.5, 1.5] {
            #expect(drag.proposal(pointerX: f.chips[0].centerX + jitter, width: width, range: range,
                                  lower: 0.6, upper: 0.6, minGap: 0.05) == nil, "\(jitter)")
        }
        #expect(drag.awaitsDirection)
    }

    /// A band pinned on an end of the range: the one limit that can leave it is taken
    /// whichever way the drag starts, so turning back moves it instead of doing nothing.
    @Test func aChipPinnedOnAnEndCanAlwaysBeDraggedOffIt() throws {
        let top = face(1, 1)
        var drag = EmberFlagDrag(start: CGPoint(x: top.chips[0].centerX, y: 12), chip: top.chips[0])
        let outward = try required(drag.proposal(pointerX: top.chips[0].centerX + 6, width: width, range: range,
                                                 lower: 1, upper: 1, minGap: 0.05))
        #expect(outward.bound == .lower && outward.value == 1)
        let back = try required(drag.proposal(pointerX: top.chips[0].centerX - 40, width: width, range: range,
                                              lower: 1, upper: 1, minGap: 0.05))
        #expect(back.bound == .lower && back.value < 0.95 + 1e-9)

        let bottom = face(0, 0)
        var up = EmberFlagDrag(start: CGPoint(x: bottom.chips[0].centerX, y: 12), chip: bottom.chips[0])
        _ = up.proposal(pointerX: bottom.chips[0].centerX - 6, width: width, range: range,
                        lower: 0, upper: 0, minGap: 0.05)
        let raised = try required(up.proposal(pointerX: bottom.chips[0].centerX + 40, width: width, range: range,
                                              lower: 0, upper: 0, minGap: 0.05))
        #expect(raised.bound == .upper && raised.value > 0.05 - 1e-9)
    }

    /// A limit near an end, taken and moved away from it, moves away.
    @Test func aFlagNearAnEndCanBeTakenAwayFromIt() throws {
        // So close to the end that the travel which makes the press a drag ends inside the
        // end's snap: only the direction keeps the limit from jumping to the end.
        let f = face(0.2, 0.995), travel = SliderCore.liveTravel
        #expect(EmberSliderFace.value(atX: f.chips[1].tipX - travel, width: width, range: range) == 1)
        var drag = EmberFlagDrag(start: CGPoint(x: f.chips[1].centerX, y: 12), chip: f.chips[1])
        let moved = try required(drag.proposal(pointerX: f.chips[1].centerX - travel, width: width, range: range,
                                               lower: 0.2, upper: 0.995, minGap: 0.05))
        #expect(moved.bound == .upper && moved.value < 0.995)
    }

    @Test func aValueThatIsNotANumberSetsNoLimit() {
        var written = 0
        for bad in [Double.nan, .infinity, -.infinity] {
            EmberSliderFlags.discreteEdit(
                bad, for: .lower, range: 0...1, lower: 0.2, upper: 0.8, minGap: 0.05,
                onLimitChange: { _, _ in written += 1 }, onPreviewEnd: nil,
                onInteractionBegin: nil, isInteractionCurrent: nil)
        }
        #expect(written == 0)
    }

    @Test func keysAndAssistiveAppsSetALimitAndApplyIt() {
        var written: [(SliderCore.Bound, Double)] = []
        var applied = 0
        func edit(_ proposed: Double, _ bound: SliderCore.Bound, lower: Double = 0.2, upper: Double = 0.8) {
            EmberSliderFlags.discreteEdit(
                proposed, for: bound, range: 0...1, lower: lower, upper: upper, minGap: 0.05,
                onLimitChange: { written.append(($0, $1)) }, onPreviewEnd: { applied += 1 },
                onInteractionBegin: nil, isInteractionCurrent: nil)
        }
        edit(SliderKeyStep.decrement.value(from: 0.2, in: 0...1), .lower)
        #expect(written.last?.0 == .lower && written.last?.1 == 0.19 && applied == 1)
        // Home on the maximum takes it as far down as it goes: onto the minimum.
        edit(SliderKeyStep.toMinimum.value(from: 0.8, in: 0...1), .upper)
        #expect(written.last?.0 == .upper && written.last?.1 == 0.2)
        // Nothing to change: nothing written, nothing applied.
        edit(0.2, .lower)
        #expect(written.count == 2 && applied == 2)
    }

    @Test func manualHasNoFlagRow() {
        #expect(EmberSlider.height(showsFlags: false) == EmberMetrics.sliderHeight)
        #expect(EmberSlider.height(showsFlags: true)
                == EmberMetrics.sliderHeight + EmberFlagFace.spacing + EmberFlagFace.rowHeight)
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

    /// A limit taken past the value carries the value with it: once the drag ends, Auto
    /// lands inside the new band, and the displays show what the slider shows.
    @Test func aLimitDraggedPastTheValueCarriesTheValue() {
        let (manager, _, gamma) = makeManager(Self.auto.merging(["redlight.adaptiveWpMax": 0.9]) { $1 }, at: Self.evening)
        let start = manager.intensity
        let token = manager.beginSliderInteraction()
        // The upper limit dragged below the value, previewed as a flag drag does.
        manager.adaptiveMax = start - 0.1
        manager.previewIntensity(start - 0.1)
        #expect(gamma.applyCalls.last.map { abs(Double($0.intensity) - (start - 0.1)) < 1e-6 } == true)
        #expect(manager.isSliderInteractionCurrent(token))
        manager.endPreview()
        #expect(manager.intensity <= manager.adaptiveMax + 1e-12)
        #expect(gamma.applyCalls.last.map { abs(Double($0.intensity) - manager.intensity) < 1e-6 } == true)
        // And the lower limit dragged above it.
        manager.adaptiveMin = 0.65
        manager.adaptiveMax = 0.9
        manager.endPreview()
        #expect(manager.intensity >= 0.65 - 1e-12 && manager.intensity <= 0.9 + 1e-12)
        #expect(gamma.applyCalls.last.map { abs(Double($0.intensity) - manager.intensity) < 1e-6 } == true)
    }
}

@Suite struct FlagBubbleTests {
    let chip = CGRect(x: 0, y: 6, width: 40, height: 16)

    @Test func aTipInTheMiddleIsAnArrow() {
        #expect(FlagBubble.hooks(chip: chip, tipX: 20) == FlagBubble.Hooks(leading: 0, trailing: 0))
        #expect(FlagBubble.hooks(chip: chip, tipX: 12) == FlagBubble.Hooks(leading: 0, trailing: 0))
    }

    @Test func nearASideTheTailBecomesAChatBubbleTailOnThatSide() {
        #expect(FlagBubble.hooks(chip: chip, tipX: 8) == FlagBubble.Hooks(leading: 1, trailing: 0))
        #expect(FlagBubble.hooks(chip: chip, tipX: -3) == FlagBubble.Hooks(leading: 1, trailing: 0))
        #expect(FlagBubble.hooks(chip: chip, tipX: 38) == FlagBubble.Hooks(leading: 0, trailing: 1))
    }

    @Test func aChatBubbleTailRisesStraightOutOfTheChipsSide() {
        let path = FlagBubble(chip: chip, tipX: 7, leading: 1, trailing: 0)
            .path(in: CGRect(x: 0, y: 0, width: 40, height: 22))
        // The side carries on up into the tail: just inside the side, above the chip's top.
        #expect(path.contains(CGPoint(x: 0.6, y: 3)))
        // The inner edge sweeps back down: clear above the chip's top, further along.
        #expect(!path.contains(CGPoint(x: 8, y: 2)))
        // The squared corner and the chip's body are filled.
        #expect(path.contains(CGPoint(x: 0.5, y: 6.5)))
        #expect(path.contains(CGPoint(x: 20, y: 14)))
    }

    @Test func anArrowIsCentredOnItsLimitAndClearOfTheCorners() {
        let path = FlagBubble(chip: chip, tipX: 20, leading: 0, trailing: 0)
            .path(in: CGRect(x: 0, y: 0, width: 40, height: 22))
        #expect(path.contains(CGPoint(x: 20, y: 2)))
        #expect(!path.contains(CGPoint(x: 0.5, y: 6.3)))
    }
}
