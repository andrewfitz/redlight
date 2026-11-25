import CoreGraphics
import Foundation
import Testing
@testable import Redlight

/// Auto's two limits are either the gap apart or on one value. These tests go through every
/// way a limit can be moved (dragged by its flag, stepped by a key) from every kind of place
/// (apart, at the gap, merged, on an end of the range, on either slider's range) and check
/// that the band is always a legal one and that nothing is ever stuck.
@Suite struct LimitMergeTests {
    static let ranges: [ClosedRange<Double>] = [0...1, 0.25...1]
    static let gap = SliderCore.limitGap
    static let width: CGFloat = EmberMetrics.width - 2 * EmberMetrics.padding
    static let tolerance = 1e-9

    struct Band: Equatable, CustomStringConvertible {
        var lower: Double
        var upper: Double
        var isPinned: Bool { lower == upper }
        var description: String { String(format: "%.4f…%.4f", lower, upper) }

        subscript(bound: SliderCore.Bound) -> Double {
            get { bound == .lower ? lower : upper }
            set { if bound == .lower { lower = newValue } else { upper = newValue } }
        }
    }

    /// A band a drag or a key can leave behind: in the range, in order, and its limits the
    /// gap apart or on one value. Never anything between.
    static func isLegal(_ band: Band, in range: ClosedRange<Double>) -> Bool {
        guard range.contains(band.lower), range.contains(band.upper), band.lower <= band.upper else { return false }
        return band.isPinned || band.upper - band.lower >= gap - tolerance
    }

    /// Every legal band on a 1 % grid, the pinned ones and those on the ends included.
    static func legalBands(in range: ClosedRange<Double>) -> [Band] {
        let steps = Int(((range.upperBound - range.lowerBound) * 100).rounded())
        let grid = (0...steps).map { range.lowerBound + Double($0) / 100 }
        var bands: [Band] = []
        for lower in grid {
            for upper in grid where upper >= lower {
                let band = Band(lower: lower, upper: upper)
                if isLegal(band, in: range) { bands.append(band) }
            }
        }
        return bands
    }

    // MARK: - The rule

    /// Collects what went wrong in a sweep of many thousands of cases, so that the sweep
    /// costs one expectation and still says where it failed.
    struct Failures {
        private(set) var first: [String] = []
        private(set) var count = 0
        mutating func check(_ condition: Bool, _ message: @autoclosure () -> String) {
            guard !condition else { return }
            count += 1
            if first.count < 8 { first.append(message()) }
        }
    }

    /// From every legal band, either limit taken to every place: the result is a legal band,
    /// the other limit has not moved, and the limit went the way it was taken or stayed.
    @Test func everyMoveFromEveryLegalBandLeavesALegalBand() {
        var failures = Failures()
        for range in Self.ranges {
            let span = range.upperBound - range.lowerBound
            let proposals = Array(stride(from: range.lowerBound - 0.1, through: range.upperBound + 0.1, by: span / 200))
            for band in Self.legalBands(in: range) {
                for bound in [SliderCore.Bound.lower, .upper] {
                    var last = -Double.infinity
                    for proposed in proposals {
                        let value = SliderCore.editedValue(proposed, for: bound, range: range,
                                                           lower: band.lower, upper: band.upper, minGap: Self.gap)
                        var after = band
                        after[bound] = value
                        failures.check(Self.isLegal(after, in: range), "\(band) \(bound) → \(proposed): \(after) is not legal")
                        // Never against the direction it was taken in.
                        failures.check(proposed < band[bound] || value >= band[bound],
                                       "\(band) \(bound) → \(proposed): went down to \(value)")
                        failures.check(proposed > band[bound] || value <= band[bound],
                                       "\(band) \(bound) → \(proposed): went up to \(value)")
                        // Taken further, it never comes back.
                        failures.check(value >= last, "\(band) \(bound) → \(proposed): \(value) after \(last)")
                        last = value
                        // Where it has been put, it rests: asked for that place again, it is there.
                        let again = SliderCore.editedValue(value, for: bound, range: range,
                                                           lower: after.lower, upper: after.upper, minGap: Self.gap)
                        failures.check(again == value, "\(band) \(bound) → \(proposed): \(value) then \(again)")
                    }
                }
            }
        }
        #expect(failures.count == 0, "\(failures.count) failures, the first: \(failures.first)")
    }

    /// Bands a drag never leaves but the CLI can: narrower than the gap without being pinned.
    static func narrowBands(in range: ClosedRange<Double>) -> [Band] {
        let lo = range.lowerBound, hi = range.upperBound
        return [
            Band(lower: lo + 0.51, upper: lo + 0.52), Band(lower: lo + 0.5, upper: lo + 0.52),
            Band(lower: lo + 0.48, upper: lo + 0.52), Band(lower: lo + 0.471, upper: lo + 0.52),
            Band(lower: lo, upper: lo + 0.02), Band(lower: lo + 0.01, upper: lo + 0.03),
            Band(lower: hi - 0.02, upper: hi), Band(lower: hi - 0.03, upper: hi - 0.01),
        ]
    }

    /// A limit taken steadily one way, each answer becoming the band the next is asked of, as
    /// in a drag: it never turns back. From every legal band and from the narrow ones the CLI
    /// can leave, where a limit pulled away used to go out to the gap and then snap onto the
    /// other limit. Stopped anywhere on the way and asked again, it is where it was.
    @Test func aLimitTakenOneWayNeverTurnsBack() {
        var failures = Failures()
        for range in Self.ranges {
            let span = range.upperBound - range.lowerBound
            let up = Array(stride(from: range.lowerBound - 0.05, through: range.upperBound + 0.05, by: span / 600))
            let starts = Self.legalBands(in: range).enumerated().filter { $0.offset % 7 == 0 }.map(\.element)
                + Self.narrowBands(in: range)
            for start in starts {
                for bound in [SliderCore.Bound.lower, .upper] {
                    for rising in [true, false] {
                        // From where the limit is, onward in one direction.
                        let path = (rising ? up : up.reversed()).filter { rising ? $0 >= start[bound] : $0 <= start[bound] }
                        var band = start
                        for proposed in path {
                            let value = SliderCore.editedValue(proposed, for: bound, range: range,
                                                               lower: band.lower, upper: band.upper, minGap: Self.gap)
                            failures.check(rising ? value >= band[bound] : value <= band[bound],
                                           "\(start) \(bound) \(rising ? "up" : "down") at \(proposed): \(band[bound]) → \(value)")
                            band[bound] = value
                            failures.check(band.lower <= band.upper && range.contains(band.lower) && range.contains(band.upper),
                                           "\(start) \(bound) at \(proposed): \(band)")
                            // Held there: the same again.
                            let again = SliderCore.editedValue(proposed, for: bound, range: range,
                                                               lower: band.lower, upper: band.upper, minGap: Self.gap)
                            failures.check(again == value, "\(start) \(bound) held at \(proposed): \(value) then \(again)")
                        }
                        // Having left a narrow band, what is left is a legal one.
                        if path.count > 1, band != start {
                            failures.check(Self.isLegal(band, in: range) || Self.narrowBands(in: range).contains(start)
                                           && (band.lower == range.lowerBound || band.upper == range.upperBound),
                                           "\(start) \(bound) \(rising ? "up" : "down") ended on \(band)")
                        }
                    }
                }
            }
        }
        #expect(failures.count == 0, "\(failures.count) failures, the first: \(failures.first)")
    }

    /// The narrow bands again, by flag and by key. A flag pulled a few points away is still
    /// where it was, or the gap away: never on the other limit. A key always moves it.
    @Test func aBandNarrowerThanTheGapOpensOrMergesAndNeverFlickers() {
        for range in Self.ranges {
            let lo = range.lowerBound
            let narrow = Band(lower: lo + 0.51, upper: lo + 0.52)
            // The minimum's flag pulled left a point at a time, and held at each.
            var seen: [Double] = []
            for step in stride(from: 0.0, through: 0.06, by: 0.002) {
                let reached = Self.drag(.lower, of: narrow, in: range, through: [narrow.lower - step, narrow.lower - step],
                                        fromANarrowBand: true)
                #expect(reached[0] == reached[1], "\(range) held \(step) left: \(reached)")
                #expect(reached[1].upper == narrow.upper && reached[1].lower <= narrow.lower, "\(range) \(step): \(reached[1])")
                seen.append(reached[1].lower)
            }
            #expect(zip(seen, seen.dropFirst()).allSatisfy { $1 <= $0 + Self.tolerance }, "\(range): \(seen)")
            #expect(abs((seen.last ?? 0) - (narrow.lower - 0.06)) < 0.004)
            // Toward the maximum: held, then merged.
            let merged = Self.drag(.lower, of: narrow, in: range, through: [narrow.lower + 0.004, narrow.upper],
                                   fromANarrowBand: true)
            #expect(merged[0] == narrow && merged[1] == Band(lower: narrow.upper, upper: narrow.upper))

            // Keys: Left on the minimum opens to the gap, Right merges; mirrored on the maximum.
            #expect(abs(Self.press(.decrement, on: .lower, narrow, in: range).band.lower - (narrow.upper - Self.gap)) < Self.tolerance)
            #expect(Self.press(.increment, on: .lower, narrow, in: range).band.isPinned)
            #expect(abs(Self.press(.increment, on: .upper, narrow, in: range).band.upper - (narrow.lower + Self.gap)) < Self.tolerance)
            #expect(Self.press(.decrement, on: .upper, narrow, in: range).band.isPinned)
            for band in Self.narrowBands(in: range) {
                for stop in [SliderCore.Bound.lower, .upper] {
                    for key in [SliderKeyStep.decrement, .increment] {
                        let after = Self.press(key, on: stop, band, in: range).band
                        let atEnd = (stop == .lower && key == .decrement && band.lower == range.lowerBound)
                            || (stop == .upper && key == .increment && band.upper == range.upperBound)
                        #expect(atEnd || after != band, "\(band): \(key) on \(stop) did nothing")
                        #expect(after.lower <= after.upper && range.contains(after.lower) && range.contains(after.upper))
                    }
                }
            }
        }
    }

    /// An assistive app names a value for a limit. It gets the place a drag to that value
    /// would give, and the same place however many times it asks: no step across the gap.
    @Test func aValueNamedByAnAssistiveAppIsTheSameEachTimeItIsAsked() {
        for range in Self.ranges {
            let pin = range.lowerBound + 0.55
            for start in [Band(lower: pin, upper: pin), Band(lower: pin - 0.35, upper: pin), Band(lower: pin - Self.gap, upper: pin)] {
                for bound in [SliderCore.Bound.lower, .upper] {
                    for asked in stride(from: range.lowerBound, through: range.upperBound, by: 0.01) {
                        var band = start
                        var answers: [Double] = []
                        for _ in 0..<3 {
                            EmberSliderFlags.discreteEdit(
                                asked, for: bound, range: range, lower: band.lower, upper: band.upper, minGap: Self.gap,
                                isStep: false, onLimitChange: { band[$0] = $1 }, onPreviewEnd: nil,
                                onInteractionBegin: nil, isInteractionCurrent: nil)
                            answers.append(band[bound])
                        }
                        #expect(answers[0] == answers[1] && answers[1] == answers[2], "\(start) \(bound) asked \(asked): \(answers)")
                        #expect(Self.isLegal(band, in: range), "\(start) \(bound) asked \(asked): \(band)")
                    }
                }
            }
        }
    }

    /// The places a limit can be put, given where the other one is: the gap or more away, or
    /// on the other limit.
    static func canStand(_ bound: SliderCore.Bound, at value: Double, other: Double, in range: ClosedRange<Double>) -> Bool {
        guard range.contains(value), bound == .lower ? value <= other : value >= other else { return false }
        return value == other || abs(value - other) >= gap - tolerance
    }

    /// Every place a limit can stand is reached by taking it there, from every legal band:
    /// the other limit's own value among them.
    @Test func everyPlaceALimitCanStandIsReached() {
        var failures = Failures()
        for range in Self.ranges {
            let steps = Int(((range.upperBound - range.lowerBound) * 100).rounded())
            let grid = (0...steps).map { range.lowerBound + Double($0) / 100 }
            for band in Self.legalBands(in: range) {
                for bound in [SliderCore.Bound.lower, .upper] {
                    let other = bound == .lower ? band.upper : band.lower
                    for target in grid where Self.canStand(bound, at: target, other: other, in: range) {
                        let value = SliderCore.editedValue(target, for: bound, range: range,
                                                           lower: band.lower, upper: band.upper, minGap: Self.gap)
                        failures.check(abs(value - target) < Self.tolerance, "\(band) \(bound) → \(target): \(value)")
                    }
                }
            }
        }
        #expect(failures.count == 0, "\(failures.count) failures, the first: \(failures.first)")
    }

    /// The merge is at the halfway point of the gap from either side, so a flag does not
    /// flicker between two places as it is held there.
    @Test func theMergeHasOneThresholdFromBothSides() {
        for range in Self.ranges {
            let other = range.lowerBound + 0.4
            let apart = other - Self.gap, half = other - Self.gap / 2
            for current in [apart - 0.1, apart, other] {
                func lower(_ v: Double) -> Double {
                    SliderCore.editedValue(v, for: .lower, range: range, lower: current, upper: other, minGap: Self.gap)
                }
                #expect(abs(lower(half - 0.001) - apart) < Self.tolerance, "from \(current)")
                #expect(lower(half + 0.001) == other, "from \(current)")
            }
            let apartAbove = other + Self.gap, halfAbove = other + Self.gap / 2
            for current in [apartAbove + 0.1, apartAbove, other] {
                func upper(_ v: Double) -> Double {
                    SliderCore.editedValue(v, for: .upper, range: range, lower: other, upper: current, minGap: Self.gap)
                }
                #expect(abs(upper(halfAbove + 0.001) - apartAbove) < Self.tolerance, "from \(current)")
                #expect(upper(halfAbove - 0.001) == other, "from \(current)")
            }
        }
    }

    /// A band pinned nearer an end of the range than the gap cannot open toward that end: a
    /// 2 % band is not a band. It opens the other way, whichever way the flag is dragged or
    /// the key points, and the pin itself is moved by the value's own slider.
    @Test func aPinNearAnEndOpensOnlyAwayFromIt() {
        for range in Self.ranges {
            let top = range.upperBound, bottom = range.lowerBound
            for pin in [top, top - 0.02, top - 0.049] {
                let pinned = Band(lower: pin, upper: pin)
                #expect(!SliderCore.canOpen(.upper, from: pin, range: range, minGap: Self.gap))
                // Dragged right, to the end and past it: still the one flag.
                var reached = Self.drag(nil, of: pinned, in: range, through: [pin + 0.01, top, top + 0.3])
                #expect(reached.allSatisfy { $0 == pinned }, "\(pin): \(reached)")
                // Dragged right and then left without letting go: the minimum leaves.
                reached = Self.drag(nil, of: pinned, in: range, through: [top + 0.1, pin - 0.03, pin - 0.2])
                #expect(Self.isClose(reached[1], pin - 0.05, pin) && Self.isClose(reached[2], pin - 0.2, pin), "\(pin): \(reached)")
                for stop in [SliderCore.Bound.lower, .upper] {
                    #expect(Self.press(.increment, on: stop, pinned, in: range).band == pinned)
                    #expect(Self.press(.toMaximum, on: stop, pinned, in: range).band == pinned)
                    let down = Self.press(.decrement, on: stop, pinned, in: range)
                    #expect(down.bound == .lower && abs(down.band.lower - (pin - Self.gap)) < Self.tolerance)
                }
            }
            for pin in [bottom, bottom + 0.02, bottom + 0.049] {
                let pinned = Band(lower: pin, upper: pin)
                #expect(!SliderCore.canOpen(.lower, from: pin, range: range, minGap: Self.gap))
                var reached = Self.drag(nil, of: pinned, in: range, through: [pin - 0.01, bottom, bottom - 0.3])
                #expect(reached.allSatisfy { $0 == pinned }, "\(pin): \(reached)")
                reached = Self.drag(nil, of: pinned, in: range, through: [bottom - 0.1, pin + 0.03, pin + 0.2])
                #expect(Self.isClose(reached[1], pin, pin + 0.05) && Self.isClose(reached[2], pin, pin + 0.2), "\(pin): \(reached)")
                for stop in [SliderCore.Bound.lower, .upper] {
                    #expect(Self.press(.decrement, on: stop, pinned, in: range).band == pinned)
                    let up = Self.press(.increment, on: stop, pinned, in: range)
                    #expect(up.bound == .upper && abs(up.band.upper - (pin + Self.gap)) < Self.tolerance)
                }
            }
            // Exactly the gap from an end there is room, rounding included: 30 % on the white point.
            #expect(SliderCore.canOpen(.lower, from: bottom + Self.gap, range: range, minGap: Self.gap))
            #expect(SliderCore.canOpen(.upper, from: top - Self.gap, range: range, minGap: Self.gap))
            let opened = Self.drag(nil, of: Band(lower: bottom + Self.gap, upper: bottom + Self.gap), in: range,
                                   through: [bottom + 0.01])
            #expect(opened[0] == Band(lower: bottom, upper: bottom + Self.gap), "\(opened)")
        }
    }

    // MARK: - Keys

    /// One key press on a flag's stop, as `EmberSliderFlags` makes it: the key's direction
    /// picks the limit on a pinned band, and the step goes on across the gap.
    static func press(_ step: SliderKeyStep, on stop: SliderCore.Bound, _ band: Band,
                      in range: ClosedRange<Double>, large: Bool = false,
                      gap: Double = LimitMergeTests.gap) -> (bound: SliderCore.Bound, band: Band) {
        let proposed = step.value(from: band[stop], in: range, large: large)
        let bound = SliderCore.keyBound(stop, proposed: proposed, lower: band.lower, upper: band.upper)
        var after = band
        after[bound] = SliderCore.steppedValue(proposed, for: bound, range: range,
                                               lower: band.lower, upper: band.upper, minGap: gap)
        return (bound, after)
    }

    /// From every legal band, every key on either stop leaves a legal band. A key that has
    /// somewhere to go in its direction always moves something.
    @Test func noKeyIsEverDeadWhileThereIsSomewhereToGo() {
        let keys: [(SliderKeyStep, up: Bool)] = [
            (.decrement, false), (.increment, true), (.pageDown, false), (.pageUp, true),
            (.toMinimum, false), (.toMaximum, true),
        ]
        var failures = Failures()
        for range in Self.ranges {
            for band in Self.legalBands(in: range) {
                for stop in [SliderCore.Bound.lower, .upper] {
                    for (key, up) in keys {
                        for large in [false, true] {
                            let (bound, after) = Self.press(key, on: stop, band, in: range, large: large)
                            failures.check(Self.isLegal(after, in: range), "\(band) \(key) on \(stop): \(after) is not legal")
                            // Only the one limit moved, and the way the key points.
                            let other: SliderCore.Bound = bound == .lower ? .upper : .lower
                            failures.check(after[other] == band[other], "\(band) \(key) on \(stop): moved both, \(after)")
                            failures.check(up ? after[bound] >= band[bound] : after[bound] <= band[bound],
                                           "\(band) \(key) on \(stop): the wrong way, \(after)")
                            // Somewhere to go: the stop's own limit can move that way, or the
                            // band is pinned and either limit can.
                            let canGo: Bool
                            if band.isPinned {
                                // A pinned band opens only where the gap fits.
                                canGo = up ? band.upper + Self.gap <= range.upperBound + Self.tolerance
                                    : band.lower - Self.gap >= range.lowerBound - Self.tolerance
                            } else if stop == .lower {
                                canGo = up ? true : band.lower > range.lowerBound
                            } else {
                                canGo = up ? band.upper < range.upperBound : true
                            }
                            failures.check(!canGo || after != band, "\(band): \(key) on \(stop) did nothing")
                        }
                    }
                }
            }
        }
        #expect(failures.count == 0, "\(failures.count) failures, the first: \(failures.first)")
    }

    /// The Right arrow held on the minimum's stop, a press at a time: 1 % steps up to the gap,
    /// one press across it onto the maximum, and then, as with a drag, it is the maximum that
    /// goes on: by the gap, then 1 % steps. The keyboard follows the limit that moved. The
    /// Left arrow from there is the same in reverse, down through the pin and out below it.
    @Test func arrowKeysWalkALimitThroughTheOtherAsADragDoes() {
        for range in Self.ranges {
            // In the slider's own percent: a key is one hundredth of its range, and the
            // gap the flags keep is five of those, on either slider.
            let u = (range.upperBound - range.lowerBound) / 100
            let gap = SliderCore.limitGap(in: range)
            #expect(abs(gap - 5 * u) < Self.tolerance)
            let m = range.lowerBound + 40 * u
            var band = Band(lower: m - 8 * u, upper: m)
            var stop = SliderCore.Bound.lower
            var seen: [Band] = []
            func hold(_ key: SliderKeyStep, times: Int) {
                for _ in 0..<times {
                    let pressed = Self.press(key, on: stop, band, in: range, gap: gap)
                    // The limit that moved is the one the next key moves.
                    if pressed.band != band { stop = pressed.bound }
                    band = pressed.band
                    seen.append(band)
                }
            }
            hold(.increment, times: 7)
            var expected: [(Double, Double)] = [
                (m - 7 * u, m), (m - 6 * u, m), (m - 5 * u, m), (m, m), (m, m + 5 * u), (m, m + 6 * u), (m, m + 7 * u),
            ]
            #expect(seen.count == expected.count)
            for (index, (got, want)) in zip(seen, expected).enumerated() {
                #expect(abs(got.lower - want.0) < Self.tolerance && abs(got.upper - want.1) < Self.tolerance,
                        "\(range) Right press \(index + 1): \(got)")
            }
            #expect(seen[3].isPinned && stop == .upper)

            seen = []
            hold(.decrement, times: 7)
            expected = [
                (m, m + 6 * u), (m, m + 5 * u), (m, m), (m - 5 * u, m), (m - 6 * u, m), (m - 7 * u, m), (m - 8 * u, m),
            ]
            for (index, (got, want)) in zip(seen, expected).enumerated() {
                #expect(abs(got.lower - want.0) < Self.tolerance && abs(got.upper - want.1) < Self.tolerance,
                        "\(range) Left press \(index + 1): \(got)")
            }
            #expect(seen[2].isPinned && stop == .lower)
        }
    }

    /// Home and End take a limit as far as it goes: to its own end of the range, or onto
    /// the other limit. So End on the minimum under a maximum of 100 % is "Fixed 100%".
    @Test func homeAndEndReachTheEndsAndTheOtherLimit() {
        for range in Self.ranges {
            let top = range.upperBound, bottom = range.lowerBound
            let band = Band(lower: bottom + 0.1, upper: top)
            #expect(Self.press(.toMaximum, on: .lower, band, in: range).band == Band(lower: top, upper: top))
            #expect(Self.press(.toMinimum, on: .lower, band, in: range).band == Band(lower: bottom, upper: top))
            let low = Band(lower: bottom, upper: bottom + 0.3)
            #expect(Self.press(.toMinimum, on: .upper, low, in: range).band == Band(lower: bottom, upper: bottom))
            #expect(Self.press(.toMaximum, on: .upper, low, in: range).band == Band(lower: bottom, upper: top))
            // Pinned on the top: only the minimum can leave, from either stop.
            let pinned = Band(lower: top, upper: top)
            for stop in [SliderCore.Bound.lower, .upper] {
                let down = Self.press(.decrement, on: stop, pinned, in: range)
                #expect(down.bound == .lower && abs(down.band.lower - (top - Self.gap)) < Self.tolerance)
                #expect(Self.press(.increment, on: stop, pinned, in: range).band == pinned)
            }
        }
    }

    // MARK: - Drags

    static func x(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        EmberSliderFace.x(for: value, width: width, range: range)
    }

    /// One press on a flag and the pointer taken through `stops` (values, as places on the
    /// track) a point at a time. The press is on the limit's own place, so the handle is the
    /// pointer. Returns the band after each stop; every band on the way is checked.
    static func drag(
        _ bound: SliderCore.Bound?, of start: Band, in range: ClosedRange<Double>, through stops: [Double],
        fromANarrowBand: Bool = false
    ) -> [Band] {
        let face = EmberFlagFace(lower: start.lower, upper: start.upper, range: range, width: width,
                                 textWidth: { CGFloat($0.count) * 6 })
        let chip = face.chips.first { $0.bound == bound } ?? face.chips[0]
        var drag = EmberFlagDrag(start: CGPoint(x: chip.tipX, y: 12), chip: chip)
        var band = start, pointer = chip.tipX, reached: [Band] = []
        for stop in stops {
            let target = x(stop, in: range)
            let count = max(1, Int(abs(target - pointer).rounded(.up)))
            let from = pointer
            for index in 1...count {
                pointer = from + (target - from) * CGFloat(index) / CGFloat(count)
                guard let proposal = drag.proposal(pointerX: pointer, width: width, range: range,
                                                   lower: band.lower, upper: band.upper, minGap: gap) else { continue }
                let other: SliderCore.Bound = proposal.bound == .lower ? .upper : .lower
                let before = band
                band[proposal.bound] = proposal.value
                #expect(band[other] == before[other], "a drag moved the other limit: \(before) → \(band)")
                // A band the CLI left narrower than the gap stays so until its limit is moved.
                #expect(isLegal(band, in: range) || fromANarrowBand && band == start,
                        "\(before) → \(band) with the pointer at \(pointer)")
            }
            reached.append(band)
        }
        return reached
    }

    static func isClose(_ band: Band, _ lower: Double, _ upper: Double) -> Bool {
        abs(band.lower - lower) < 0.004 && abs(band.upper - upper) < 0.004
    }

    /// The minimum's flag dragged right, all the way through the maximum's: it follows, holds
    /// at the gap, merges, and then it is the maximum that goes on, to the end of the range.
    /// The limit left behind stays where they met. Dragged back, the same in reverse.
    @Test func aFlagDraggedThroughTheOtherMergesAndCarriesItOn() {
        for range in Self.ranges {
            let lo = range.lowerBound + 0.1, hi = range.lowerBound + 0.5, top = range.upperBound
            let stops = [hi - 0.10, hi - 0.03, hi - 0.02, hi, hi + 0.02, hi + 0.03, hi + 0.2, top + 0.2,
                         hi + 0.03, hi + 0.02, hi - 0.02, hi - 0.03, hi - 0.2, range.lowerBound - 0.2]
            let reached = Self.drag(.lower, of: Band(lower: lo, upper: hi), in: range, through: stops)
            let expected: [(Double, Double)] = [
                (hi - 0.10, hi),           // follows
                (hi - 0.05, hi),           // held at the gap
                (hi, hi),                  // more than halfway across: merged
                (hi, hi), (hi, hi),        // still merged, a little past the pin
                (hi, hi + 0.05),           // more than halfway out the far side: the maximum leaves
                (hi, hi + 0.2), (hi, top), // and follows, to the end
                (hi, hi + 0.05),           // back: held at the gap
                (hi, hi),                  // merged again
                (hi, hi),
                (hi - 0.05, hi),           // out the near side: the minimum leaves
                (hi - 0.2, hi), (range.lowerBound, hi),
            ]
            for (index, (band, want)) in zip(reached, expected).enumerated() {
                #expect(Self.isClose(band, want.0, want.1), "\(range) stop \(index) (\(stops[index])): \(band)")
            }
            #expect(reached.last?.lower == range.lowerBound && reached[7].upper == top, "the ends are exact")
        }
    }

    /// The maximum's flag dragged left through the minimum's: the mirror of the same.
    @Test func theMaximumDraggedThroughTheMinimumIsTheMirror() {
        for range in Self.ranges {
            let lo = range.lowerBound + 0.3, hi = range.lowerBound + 0.6, bottom = range.lowerBound
            let stops = [lo + 0.03, lo + 0.02, lo - 0.02, lo - 0.03, bottom - 0.2, lo + 0.02, lo + 0.03, lo + 0.2]
            let reached = Self.drag(.upper, of: Band(lower: lo, upper: hi), in: range, through: stops)
            let expected: [(Double, Double)] = [
                (lo, lo + 0.05), (lo, lo), (lo, lo), (lo - 0.05, lo), (bottom, lo),
                (lo, lo), (lo, lo + 0.05), (lo, lo + 0.2),
            ]
            for (index, (band, want)) in zip(reached, expected).enumerated() {
                #expect(Self.isClose(band, want.0, want.1), "\(range) stop \(index) (\(stops[index])): \(band)")
            }
        }
    }

    /// With the maximum on the top of the range, the minimum's flag reaches the top: "Fixed
    /// 100%". Past it there is nowhere for either limit to go, and back it is the minimum that
    /// leaves. The same on the bottom of the range with the maximum's flag.
    @Test func aFlagReachesTheEndOfTheRangeByMergingThere() {
        for range in Self.ranges {
            let top = range.upperBound, bottom = range.lowerBound
            var reached = Self.drag(.lower, of: Band(lower: bottom + 0.2, upper: top), in: range,
                                    through: [top - 0.03, top - 0.02, top, top + 0.3, top - 0.02, top - 0.03, top - 0.3])
            var expected: [(Double, Double)] = [
                (top - 0.05, top), (top, top), (top, top), (top, top), (top, top), (top - 0.05, top), (top - 0.3, top),
            ]
            for (index, (band, want)) in zip(reached, expected).enumerated() {
                #expect(Self.isClose(band, want.0, want.1), "\(range) top, stop \(index): \(band)")
            }
            #expect(reached[2] == Band(lower: top, upper: top), "merged exactly on the end")

            reached = Self.drag(.upper, of: Band(lower: bottom, upper: bottom + 0.4), in: range,
                                through: [bottom + 0.03, bottom + 0.02, bottom, bottom - 0.3,
                                          bottom + 0.02, bottom + 0.03, bottom + 0.3])
            expected = [
                (bottom, bottom + 0.05), (bottom, bottom), (bottom, bottom), (bottom, bottom),
                (bottom, bottom), (bottom, bottom + 0.05), (bottom, bottom + 0.3),
            ]
            for (index, (band, want)) in zip(reached, expected).enumerated() {
                #expect(Self.isClose(band, want.0, want.1), "\(range) bottom, stop \(index): \(band)")
            }
            #expect(reached[2] == Band(lower: bottom, upper: bottom), "merged exactly on the end")
        }
    }

    /// A press on the one flag of a pinned band: nothing until it is taken more than halfway
    /// across the gap, then the limit on that side stands the gap apart and follows. A drag
    /// that starts one way and turns before anything has left takes the other limit.
    @Test func aMergedFlagOpensTowardTheSideItIsDraggedTo() {
        for range in Self.ranges {
            let pin = range.lowerBound + 0.4
            let pinned = Band(lower: pin, upper: pin)
            var reached = Self.drag(nil, of: pinned, in: range, through: [pin - 0.02, pin - 0.03, pin - 0.1])
            #expect(reached[0] == pinned && Self.isClose(reached[1], pin - 0.05, pin) && Self.isClose(reached[2], pin - 0.1, pin))
            reached = Self.drag(nil, of: pinned, in: range, through: [pin + 0.02, pin + 0.03, pin + 0.1])
            #expect(reached[0] == pinned && Self.isClose(reached[1], pin, pin + 0.05) && Self.isClose(reached[2], pin, pin + 0.1))
            // Left first, still merged, then right: the maximum, not a dead drag.
            reached = Self.drag(nil, of: pinned, in: range, through: [pin - 0.02, pin + 0.03, pin + 0.1])
            #expect(reached[0] == pinned && Self.isClose(reached[1], pin, pin + 0.05) && Self.isClose(reached[2], pin, pin + 0.1))
            // Back onto the pin after opening: merged again, wherever it was opened to.
            reached = Self.drag(nil, of: pinned, in: range, through: [pin + 0.2, pin + 0.01, pin - 0.01])
            #expect(reached[1] == pinned && reached[2] == pinned)
        }
    }

    /// The pointer wandering anywhere, from every kind of start: the band is legal at every
    /// point of every drag (checked inside `drag`), and a drag that ends where it began on a
    /// band that was apart leaves the band as it was.
    @Test func noDragLeavesAnIllegalBandWhereverThePointerGoes() {
        for range in Self.ranges {
            let lo = range.lowerBound, hi = range.upperBound, span = hi - lo
            let starts = [
                Band(lower: lo + 0.2 * span, upper: lo + 0.7 * span), Band(lower: lo, upper: hi),
                Band(lower: lo, upper: lo + Self.gap), Band(lower: hi - Self.gap, upper: hi),
                Band(lower: lo + 0.4, upper: lo + 0.4), Band(lower: lo, upper: lo), Band(lower: hi, upper: hi),
            ]
            let wander = [hi + 0.3, lo - 0.3, lo + 0.5 * span, hi, lo, lo + 0.31 * span, lo + 0.29 * span, hi + 0.1]
            for start in starts {
                let bounds: [SliderCore.Bound?] = start.isPinned ? [nil] : [.lower, .upper]
                for bound in bounds {
                    _ = Self.drag(bound, of: start, in: range, through: wander)
                    if let bound {
                        let back = Self.drag(bound, of: start, in: range, through: wander + [start[bound]])
                        #expect(Self.isClose(back[back.count - 1], start.lower, start.upper),
                                "\(start) \(bound): ended on \(back[back.count - 1])")
                    }
                }
            }
        }
    }

    // MARK: - The flags as drawn

    /// At the gap there are two flags that do not overlap; merged there is one, on the pin,
    /// and it says so. That holds at both ends of both ranges.
    @Test func twoFlagsAtTheGapAndOneWhenMerged() {
        for range in Self.ranges {
            for other in [range.lowerBound + Self.gap, range.lowerBound + 0.4, range.upperBound] {
                let apart = EmberFlagFace(lower: other - Self.gap, upper: other, range: range, width: Self.width)
                #expect(apart.chips.map(\.bound) == [.lower, .upper])
                #expect(apart.chips[0].frame.maxX <= apart.chips[1].frame.minX)
                #expect(apart.chips.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= Self.width })

                let merged = EmberFlagFace(lower: other, upper: other, range: range, width: Self.width)
                #expect(merged.chips.count == 1 && merged.chips[0].bound == nil)
                #expect(merged.chips[0].text == EmberFlagFace.pinnedText(other, in: range))
                #expect(merged.chips[0].tipX == Self.x(other, in: range))
                #expect(merged.chips[0].frame.minX >= 0 && merged.chips[0].frame.maxX <= Self.width)
                // A press where either flag was takes the merged one.
                #expect(merged.chip(at: CGPoint(x: merged.chips[0].centerX, y: 12)) != nil)
            }
        }
    }
}

/// The merge as the model takes it: the popover's flags write Auto's limits straight to the
/// manager, as `SliderRow` wires them.
@MainActor @Suite struct LimitMergeManagerTests {
    private let registry = TestDefaultsRegistry()

    private func makeManager() -> DisplayManager {
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(0.2, forKey: "redlight.adaptiveMin")
        defaults.set(0.8, forKey: "redlight.adaptiveMax")
        defaults.set(0.45, forKey: "redlight.adaptiveWpMin")
        defaults.set(1.0, forKey: "redlight.adaptiveWpMax")
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        return DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [1] }, getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) }, defaults: defaults, location: location,
            now: { Date(timeIntervalSince1970: 1_774_050_000) })
    }

    @Test func mergingTheColourTempFlagsPinsTheValueAndOpeningThemFreesIt() {
        let manager = makeManager()
        #expect(!manager.isIntensityPinned)
        // The minimum's flag dragged onto the maximum's.
        manager.adaptiveMin = manager.adaptiveMax
        manager.endPreview()
        #expect(manager.isIntensityPinned)
        #expect(manager.intensityBand == 0.8...0.8)
        #expect(manager.intensity == 0.8, "a pinned band holds the value on the pin")
        // The value's own slider moves the pin, both limits with it.
        manager.setIntensityPushingBand(0.6)
        #expect(manager.adaptiveMin == 0.6 && manager.adaptiveMax == 0.6 && manager.intensity == 0.6)
        // Opened again by the gap: a band, and Auto follows the sun inside it.
        manager.adaptiveMax = 0.65
        manager.endPreview()
        #expect(!manager.isIntensityPinned)
        #expect(manager.intensityBand == 0.6...0.65)
        #expect(manager.intensityBand.contains(manager.intensity))
    }

    @Test func theWhitePointMergesOnTheTopOfItsRange() {
        let manager = makeManager()
        // The minimum's flag dragged to the end, under a maximum of 100 %: "Fixed 100%".
        manager.adaptiveWpMin = 1.0
        manager.endPreview()
        #expect(manager.isWhitepointPinned)
        #expect(manager.whitepointBand == 1.0...1.0)
        #expect(manager.whitepoint == 1.0)
        // And back out: the minimum leaves by the gap.
        manager.adaptiveWpMin = 0.95
        manager.endPreview()
        #expect(!manager.isWhitepointPinned && manager.whitepointBand == 0.95...1.0)
        #expect(manager.whitepointBand.contains(manager.whitepoint))
    }

    /// A whole drag through the real model, as the popover makes it: each proposal is written
    /// to the manager's limit and the next is asked of the band the manager then has. The
    /// manager moves the value with a limit, and must never move the other limit.
    @Test func aFlagDraggedThroughTheOtherOnTheModelMovesOneLimitAtATime() {
        let manager = makeManager()
        let range = 0.0...1.0, width = LimitMergeTests.width
        func x(_ value: Double) -> CGFloat { EmberSliderFace.x(for: value, width: width, range: range) }
        let face = EmberFlagFace(lower: 0.2, upper: 0.8, range: range, width: width, textWidth: { CGFloat($0.count) * 6 })
        var drag = EmberFlagDrag(start: CGPoint(x: face.chips[0].tipX, y: 12), chip: face.chips[0])
        var pointer = face.chips[0].tipX
        var bands: [ClosedRange<Double>] = []
        for stop in [0.77, 0.8, 0.84, 1.2, 0.84, 0.76, 0.3] {
            let target = x(stop)
            while pointer != target {
                pointer += max(-1, min(1, target - pointer))
                let lower = manager.adaptiveMin, upper = manager.adaptiveMax
                guard let proposal = drag.proposal(pointerX: pointer, width: width, range: range,
                                                   lower: lower, upper: upper, minGap: SliderCore.limitGap) else { continue }
                if proposal.bound == .lower { manager.adaptiveMin = proposal.value } else { manager.adaptiveMax = proposal.value }
                manager.previewIntensity(proposal.value)
                // Only the limit that was written moved.
                #expect(proposal.bound == .lower ? manager.adaptiveMax == upper : manager.adaptiveMin == lower,
                        "the model moved the other limit: \(lower)…\(upper) → \(manager.adaptiveMin)…\(manager.adaptiveMax)")
                #expect(manager.adaptiveMin <= manager.adaptiveMax)
            }
            bands.append(manager.intensityBand)
        }
        manager.endPreview()
        func isClose(_ band: ClosedRange<Double>, _ lower: Double, _ upper: Double) -> Bool {
            abs(band.lowerBound - lower) < 0.004 && abs(band.upperBound - upper) < 0.004
        }
        // Held at the gap, merged, the maximum carried on to the end, back to the gap,
        // merged again, the minimum out below.
        #expect(isClose(bands[0], 0.75, 0.8) && isClose(bands[1], 0.8, 0.8) && isClose(bands[2], 0.8, 0.85))
        #expect(isClose(bands[3], 0.8, 1) && isClose(bands[4], 0.8, 0.85) && isClose(bands[5], 0.75, 0.8))
        #expect(isClose(bands[6], 0.3, 0.8), "\(bands)")
        #expect(manager.intensityBand.contains(manager.intensity))
    }

    /// The merged band survives a relaunch as it was left.
    @Test func aMergedBandIsSavedAndLoaded() {
        let defaults = registry.makeDefaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        func make() -> DisplayManager {
            DisplayManager(gamma: MockGammaController(), getDisplayIDs: { [1] }, getDisplayName: { "Display \($0)" },
                           getDisplayPersistenceKey: { String($0) }, defaults: defaults, location: FakeLocationProvider())
        }
        let first = make()
        first.adaptiveMin = 0.7
        first.adaptiveMax = 0.7
        first.endPreview()
        let second = make()
        #expect(second.isIntensityPinned && second.adaptiveMin == 0.7 && second.adaptiveMax == 0.7)
    }
}
