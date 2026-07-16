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

    @Test func distantTrackClickMovesValueInsteadOfBand() {
        #expect(hit(pos(0.1), value: 0.5, lower: 0.0, upper: 1.0) == .value)
        #expect(hit(pos(0.9), value: 0.5, lower: 0.0, upper: 1.0) == .value)
    }

    @Test func hitTestingUsesTheVisibleBandClampedThumb() {
        // Location may still be resolving when Adaptive turns on, leaving the raw model
        // value outside the saved band. The rendered thumb at 0.8 must remain the thumb.
        #expect(hit(pos(0.8), value: 1.0, lower: 0.2, upper: 0.8) == .value)
    }
}
