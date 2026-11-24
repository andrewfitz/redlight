import Testing
import CoreGraphics
@testable import Redlight

@Suite struct BandSliderCoreTests {
    let width: CGFloat = 240
    let inset: CGFloat = 9            // thumbSize / 2
    let range = 0.0...1.0

    func pos(_ v: Double) -> CGFloat {
        BandSliderCore.position(v, width: width, inset: inset, range: range)
    }

    // MARK: - One shared value ⇄ pixel mapping

    @Test func mappingIsMonotonicAndInsetSymmetric() {
        // Thumb and markers share this one mapping (this was the "thumb sits past the
        // bracket" bug: two different insets meant one value → two different x's).
        #expect(pos(0) == inset)                  // flush with the inset track ends
        #expect(pos(1) == width - inset)
        #expect(abs(pos(0.5) - width / 2) < 1e-9)
        for v in stride(from: 0.1, through: 1.0, by: 0.1) {
            #expect(pos(v) > pos(v - 0.1))
        }
    }

    @Test func mappingRoundTrips() {
        for v in stride(from: 0.0, through: 1.0, by: 0.1) {
            let back = BandSliderCore.value(atX: pos(v), width: width, inset: inset, range: range)
            #expect(abs(back - v) < 1e-9)
        }
    }

    @Test func mappingRoundTripsNonUnitRange() {
        let r = 0.25...1.0
        for v in stride(from: 0.25, through: 1.0, by: 0.05) {
            let x = BandSliderCore.position(v, width: width, inset: inset, range: r)
            let back = BandSliderCore.value(atX: x, width: width, inset: inset, range: r)
            #expect(abs(back - v) < 1e-9)
        }
    }

    @Test func valueClampsIntoRange() {
        #expect(BandSliderCore.value(atX: -50, width: width, inset: inset, range: range) == 0)
        #expect(BandSliderCore.value(atX: width + 50, width: width, inset: inset, range: range) == 1)
    }

    // MARK: - Hard band clamp

    @Test func clampToBandLimitsValue() {
        #expect(BandSliderCore.clampToBand(0.9, lower: 0.2, upper: 0.8) == 0.8)
        #expect(BandSliderCore.clampToBand(0.1, lower: 0.2, upper: 0.8) == 0.2)
        #expect(BandSliderCore.clampToBand(0.5, lower: 0.2, upper: 0.8) == 0.5)
    }

    @Test func clampToBandNormalizesInvertedBounds() {
        #expect(BandSliderCore.clampToBand(0.9, lower: 0.8, upper: 0.2) == 0.8)
        #expect(BandSliderCore.clampToBand(0.1, lower: 0.8, upper: 0.2) == 0.2)
    }

    // MARK: - Hit routing

    func hit(_ x: CGFloat, value: Double, lower: Double, upper: Double, showBand: Bool = true)
        -> BandSliderCore.Handle
    {
        BandSliderCore.hitHandle(atX: x, width: width, inset: inset, range: range,
                                 value: value, lower: lower, upper: upper, showBand: showBand)
    }

    @Test func noBandAlwaysHitsThumb() {
        #expect(hit(0, value: 0.5, lower: 0.2, upper: 0.8, showBand: false) == .value)
        #expect(hit(width, value: 0.5, lower: 0.2, upper: 0.8, showBand: false) == .value)
    }

    @Test func thumbGrabPreservesOffsetOnlyInsideItsCircle() {
        #expect(BandSliderCore.isOnThumb(dx: 6, dy: 6, radius: inset))
        #expect(!BandSliderCore.isOnThumb(dx: 8, dy: 8, radius: inset))
        #expect(!BandSliderCore.isOnThumb(dx: 4, dy: 12, radius: inset))
    }

    @Test func nearestHandleWins() {
        #expect(hit(pos(0.21), value: 0.5, lower: 0.2, upper: 0.8) == .lower)
        #expect(hit(pos(0.79), value: 0.5, lower: 0.2, upper: 0.8) == .upper)
        #expect(hit(pos(0.51), value: 0.5, lower: 0.2, upper: 0.8) == .value)
    }

    @Test func thumbStaysGrabbableWhenClampedOntoMarker() {
        // Thumb clamped exactly onto the upper bracket: grabbing at the shared position
        // must still select the thumb (it used to become permanently ungrabbable).
        #expect(hit(pos(0.8), value: 0.8, lower: 0.2, upper: 0.8) == .value)
        // …and just inside the band still means the thumb.
        #expect(hit(pos(0.78), value: 0.8, lower: 0.2, upper: 0.8) == .value)
    }

    @Test func markerGrabbableFromOutsideTheBand() {
        // Grabbing beyond the bracket picks the marker — the only handle that can move there.
        #expect(hit(pos(0.83), value: 0.8, lower: 0.2, upper: 0.8) == .upper)
        #expect(hit(pos(0.17), value: 0.2, lower: 0.2, upper: 0.8) == .lower)
    }

    @Test func tabAboveOrBelowAParkedThumbGrabsTheLimit() {
        // Thumb parked exactly on the upper limit: the body is the thumb, the tabs that
        // stick out above and below it are the limit.
        func hitY(_ x: CGFloat, _ dy: CGFloat) -> BandSliderCore.Handle {
            BandSliderCore.hitHandle(atX: x, dy: dy, width: width, inset: inset, range: range,
                                     value: 0.8, lower: 0.2, upper: 0.8, showBand: true)
        }
        #expect(hitY(pos(0.8), 0) == .value)
        #expect(hitY(pos(0.8), -11) == .upper)
        #expect(hitY(pos(0.8), 11) == .upper)
        // Top of the thumb but away from any tab is still the thumb.
        #expect(hitY(pos(0.8) - 8, -7) == .value)
    }

    @Test func distantTrackClickMovesValueInsteadOfBand() {
        #expect(hit(pos(0.1), value: 0.5, lower: 0.0, upper: 1.0) == .value)
        #expect(hit(pos(0.9), value: 0.5, lower: 0.0, upper: 1.0) == .value)
        #expect(hit(pos(0.1), value: 0.2, lower: 0.2, upper: 0.8) == .value)
        #expect(hit(pos(0.9), value: 0.8, lower: 0.2, upper: 0.8) == .value)
    }

    @Test func existingPinsMoveWithTheThumbAndWidenUsingEitherMarker() {
        for pin in [0.0, 0.5, 1.0] {
            #expect(hit(pos(pin), value: pin, lower: pin, upper: pin) == .value)
            #expect(hit(pos(pin) - 4, value: pin, lower: pin, upper: pin) == .value)
            #expect(hit(pos(pin) + 4, value: pin, lower: pin, upper: pin) == .value)
            #expect(BandSliderCore.editedValue(0.3, for: .value, range: range,
                lower: pin, upper: pin, showBand: true, minGap: 0.05) == 0.3)
            #expect(BandSliderCore.resolveStackedMarker(.lower, dx: 3, lower: pin, upper: pin) == .upper)
            #expect(BandSliderCore.resolveStackedMarker(.upper, dx: -3, lower: pin, upper: pin) == .lower)
        }
        #expect(BandSliderCore.editedValue(0.01, for: .upper, range: range,
            lower: 0, upper: 0, showBand: true, minGap: 0.05) == 0.05)
        #expect(BandSliderCore.editedValue(0.99, for: .lower, range: range,
            lower: 1, upper: 1, showBand: true, minGap: 0.05) == 0.95)
    }

    @Test func editingAnExistingNarrowBandNeverMovesTheMarkerOppositeTheRequestedDirection() {
        #expect(BandSliderCore.editedValue(0.53, for: .lower, range: range,
            lower: 0.5, upper: 0.52, showBand: true, minGap: 0.05) == 0.5)
        #expect(BandSliderCore.editedValue(0.49, for: .upper, range: range,
            lower: 0.5, upper: 0.52, showBand: true, minGap: 0.05) == 0.52)
        let expanded = BandSliderCore.editedValue(0.49, for: .lower, range: range,
            lower: 0.5, upper: 0.52, showBand: true, minGap: 0.05)
        #expect(abs(expanded - 0.47) < 1e-9)
    }

    @Test func hitTestingUsesTheVisibleBandClampedThumb() {
        // Location may still be resolving when Adaptive turns on, leaving the raw model
        // value outside the saved band. The rendered thumb at 0.8 must remain the thumb.
        #expect(hit(pos(0.8), value: 1.0, lower: 0.2, upper: 0.8) == .value)
    }
}

/// Routing of a press on the Ember pill at the size it has in the popover: 268 pt wide,
/// handles inset 7 pt, a 4 × 16 grabber and 2 × 8 notches in a 28 pt pill.
@Suite struct BandSliderPillHitTests {
    let width: CGFloat = 268
    let range = 0.0...1.0

    func pos(_ v: Double) -> CGFloat {
        BandSliderCore.position(v, width: width, inset: BandSliderFace.inset, range: range)
    }

    func hit(
        _ x: CGFloat, _ dy: CGFloat = 0, value: Double, lower: Double, upper: Double, band: Bool = true
    ) -> BandSliderCore.Handle {
        BandSliderFace.handle(atX: x, dy: dy, width: width, range: range,
                              value: value, lower: lower, upper: upper, showBand: band)
    }

    /// What the core says on its own, with the tab zone it defaults to.
    func coreHit(_ x: CGFloat, _ dy: CGFloat = 0, value: Double, lower: Double, upper: Double)
        -> BandSliderCore.Handle
    {
        BandSliderCore.hitHandle(atX: x, dy: dy, width: width, inset: BandSliderFace.inset, range: range,
                                 value: value, lower: lower, upper: upper, showBand: true)
    }

    /// Every half point of the drawn grabber, from its centre.
    var grabberPoints: [(dx: CGFloat, dy: CGFloat)] {
        let half = BandSliderFace.grabSize
        return stride(from: -half.width / 2, through: half.width / 2, by: 0.5).flatMap { dx in
            stride(from: -half.height / 2, through: half.height / 2, by: 0.5).map { (dx, $0) }
        }
    }

    @Test func geometryIsThePopovers() {
        #expect(width == EmberMetrics.width - 2 * EmberMetrics.padding)
        #expect(BandSliderFace.inset == 7)
        #expect(BandSliderFace.grabSize == CGSize(width: 4, height: 16))
        #expect(EmberMetrics.sliderHeight == 28)
        // The limit tabs begin past the grabber's tip and inside the visible tick.
        #expect(BandSliderFace.tabZone > BandSliderFace.grabSize.height / 2)
        #expect(BandSliderFace.tabZone < BandSliderFace.tickHeight / 2 - 3)
        #expect(BandSliderFace.tickHeight / 2 < EmberMetrics.sliderHeight / 2)
    }

    @Test func pressOnTheGrabberMovesTheValueWhenItRestsOnItsUpperLimit() {
        // Auto by day: the value sits on the upper limit, here and at the top of the range.
        for upper in [0.8, 1.0] {
            let x = pos(upper)
            for point in grabberPoints {
                #expect(hit(x + point.dx, point.dy, value: upper, lower: 0.2, upper: upper) == .value,
                        "upper \(upper) at \(point)")
            }
        }
        // The core's defaults are sized for the old tall markers: right of centre, or more
        // than 5 pt off the centre line, the same press took the limit and moved the band.
        let x = pos(0.8)
        #expect(coreHit(x + 1, value: 0.8, lower: 0.2, upper: 0.8) == .upper)
        #expect(coreHit(x, 7, value: 0.8, lower: 0.2, upper: 0.8) == .upper)
        #expect(coreHit(x, -6, value: 0.8, lower: 0.2, upper: 0.8) == .upper)
    }

    @Test func pressOnTheGrabberMovesTheValueWhenItRestsOnItsLowerLimit() {
        // Auto by night, here and at the bottom of the range.
        for lower in [0.2, 0.0] {
            let x = pos(lower)
            for point in grabberPoints {
                #expect(hit(x + point.dx, point.dy, value: lower, lower: lower, upper: 0.8) == .value,
                        "lower \(lower) at \(point)")
            }
        }
        #expect(coreHit(pos(0.2) - 1, value: 0.2, lower: 0.2, upper: 0.8) == .lower)
        #expect(coreHit(pos(0.2), 7, value: 0.2, lower: 0.2, upper: 0.8) == .lower)
    }

    @Test func pressOnTheGrabberMovesAPinnedBandWithIt() {
        for pin in [0.0, 0.6, 1.0] {
            let x = pos(pin)
            for point in grabberPoints {
                #expect(hit(x + point.dx, point.dy, value: pin, lower: pin, upper: pin) == .value,
                        "pin \(pin) at \(point)")
            }
        }
        // Its tips used to take a limit, which widened the band instead.
        #expect(coreHit(pos(0.6), 7, value: 0.6, lower: 0.6, upper: 0.6) != .value)
    }

    @Test func limitUnderTheGrabberIsTakenByItsTicks() {
        let x = pos(0.8)
        // The ticks show from 8 to 13 pt above and below the centre line, a point either
        // side of the limit's own x.
        for dy: CGFloat in [9, 10, 12, 13, 14, -9, -11, -13, -14] {
            for dx: CGFloat in [-2, -1, 0, 1, 2] {
                #expect(hit(x + dx, dy, value: 0.8, lower: 0.2, upper: 0.8) == .upper, "\(dx), \(dy)")
            }
        }
        let night = pos(0.2)
        #expect(hit(night, 10, value: 0.2, lower: 0.2, upper: 0.8) == .lower)
        #expect(hit(night - 1, -12, value: 0.2, lower: 0.2, upper: 0.8) == .lower)
        // A pinned band's ticks take a limit; which one is settled by the drag's direction.
        let pin = pos(0.6)
        let taken = hit(pin, 11, value: 0.6, lower: 0.6, upper: 0.6)
        #expect(taken != .value)
        #expect(BandSliderCore.resolveStackedMarker(taken, dx: 3, lower: 0.6, upper: 0.6) == .upper)
        #expect(BandSliderCore.resolveStackedMarker(taken, dx: -3, lower: 0.6, upper: 0.6) == .lower)
        // Away from any limit the pill's edge is plain track.
        #expect(hit(pos(0.5), 12, value: 0.8, lower: 0.2, upper: 0.8) == .value)
    }

    @Test func limitUnderTheGrabberIsTakenFromBesideItOutsideTheBand() {
        let x = pos(0.8)
        // The end of the band beyond the grabber, and a little of the track past it.
        for dx: CGFloat in [5, 7, 10, 12] {
            #expect(hit(x + dx, value: 0.8, lower: 0.2, upper: 0.8) == .upper, "\(dx)")
        }
        // Inside the band, and far along the track, a press moves the value.
        for dx: CGFloat in [-5, -9, -30, 13, 40] {
            #expect(hit(x + dx, value: 0.8, lower: 0.2, upper: 0.8) == .value, "\(dx)")
        }
        let night = pos(0.2)
        #expect(hit(night - 5, value: 0.2, lower: 0.2, upper: 0.8) == .lower)
        #expect(hit(night - 12, value: 0.2, lower: 0.2, upper: 0.8) == .lower)
        #expect(hit(night + 5, value: 0.2, lower: 0.2, upper: 0.8) == .value)
        #expect(hit(night - 13, value: 0.2, lower: 0.2, upper: 0.8) == .value)
    }

    @Test func grabberBesideALimitStillTakesTheValue() {
        // 1% above the lower limit: the grabber's left half is nearer the notch than its own
        // centre, and a press there is still a press on the grabber.
        let x = pos(0.21)
        #expect(pos(0.21) - pos(0.2) < 3)
        for point in grabberPoints {
            #expect(hit(x + point.dx, point.dy, value: 0.21, lower: 0.2, upper: 0.8) == .value, "\(point)")
        }
        #expect(coreHit(x - 2, value: 0.21, lower: 0.2, upper: 0.8) == .lower)
        // The notch is still there to take, just outside the grabber.
        #expect(hit(pos(0.2) - 3, value: 0.21, lower: 0.2, upper: 0.8) == .lower)
    }

    @Test func awayFromTheGrabberTheCoreDecidesAsBefore() {
        #expect(hit(pos(0.2), value: 0.5, lower: 0.2, upper: 0.8) == .lower)
        #expect(hit(pos(0.8), value: 0.5, lower: 0.2, upper: 0.8) == .upper)
        #expect(hit(pos(0.21), value: 0.5, lower: 0.2, upper: 0.8) == .lower)
        #expect(hit(pos(0.35), value: 0.5, lower: 0.2, upper: 0.8) == .value)
        #expect(hit(pos(0.65), 12, value: 0.5, lower: 0.2, upper: 0.8) == .value)
        // The drawn value is the one clamped into the band.
        #expect(hit(pos(0.8), value: 1.0, lower: 0.2, upper: 0.8) == .value)
        // Without a band there is only the value.
        for x: CGFloat in [0, 57.8, 134, 268] {
            #expect(hit(x, 12, value: 0.5, lower: 0.2, upper: 0.8, band: false) == .value)
        }
    }

    @Test func pressAnywhereOnTheGrabberKeepsItsGrabPoint() {
        // Everything drawn as the grabber, tips included, holds on without nudging the value.
        for point in grabberPoints {
            #expect(BandSliderFace.keepsGrabOffset(dx: point.dx, dy: point.dy), "\(point)")
            #expect(BandSliderFace.isOnGrabber(dx: point.dx, dy: point.dy), "\(point)")
        }
        // The old test was a 7 pt disc, which a 16 pt bar sticks out of.
        #expect(!BandSliderCore.isOnThumb(dx: 0, dy: 8, radius: BandSliderFace.inset))
        // The clear space beside the grabber counts too; the track and the tabs do not.
        #expect(BandSliderFace.keepsGrabOffset(dx: 7, dy: 0))
        #expect(BandSliderFace.keepsGrabOffset(dx: -7, dy: -8))
        #expect(!BandSliderFace.keepsGrabOffset(dx: 7.5, dy: 0))
        #expect(!BandSliderFace.keepsGrabOffset(dx: 0, dy: 9))
        #expect(!BandSliderFace.keepsGrabOffset(dx: 0, dy: -12))
        // The routing's own grabber is narrower than that: it must not swallow the limit
        // that is taken from just beside it.
        #expect(BandSliderFace.isOnGrabber(dx: 4, dy: 0))
        #expect(!BandSliderFace.isOnGrabber(dx: 4.5, dy: 0))
    }
}
