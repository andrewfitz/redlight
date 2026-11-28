import Foundation
import Testing
import CoreGraphics
import Observation
import SwiftUI
@testable import Redlight

@MainActor
final class FakePresence: PresenceMonitoring {
    var isAway = false {
        didSet {
            if isAway, !oldValue { onAway?() }
            if !isAway, oldValue { onReturn?() }
        }
    }
    var idle: TimeInterval = 0
    func idleSeconds() -> TimeInterval { idle }
    var isLocked = false
    var areScreensAsleep = false
    var isVideoKeepingDisplayAwake = false
    var onAway: (@MainActor () -> Void)?
    var onReturn: (@MainActor () -> Void)?
}

final class LearningClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

/// Counts what is written under each key.
final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String: Int] = [:]
    override func set(_ value: Any?, forKey defaultName: String) {
        writes[defaultName, default: 0] += 1
        super.set(value, forKey: defaultName)
    }
}

/// A manager in Auto with learning on, at 35° N on the meridian, on a clock the test steps.
@MainActor
final class LearningRig {
    static let latitude = 35.0, longitude = 0.0
    /// 2026-03-16 04:00 UTC: the first learning day of the reference's runs.
    static let start = Date(timeIntervalSince1970: 1_773_633_600)

    let clock: LearningClock
    let presence = FakePresence()
    let gamma = MockGammaController()
    let location = FakeLocationProvider()
    let defaults: UserDefaults
    var manager: DisplayManager

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// `fade` is Auto's fade, in seconds of a clock that stands still: a fade started stays running.
    /// `uptime` stands in for the real time that passes, which decides how often dwell is saved.
    init(
        defaults: UserDefaults, at date: Date = LearningRig.start, learning: Bool = true, located: Bool = true,
        fade: TimeInterval = 0, uptime: (() -> TimeInterval)? = nil
    ) {
        self.defaults = defaults
        clock = LearningClock(date)
        if located { location.coordinate = (Self.latitude, Self.longitude) }
        defaults.set(true, forKey: "redlight.display.1.enabled")
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(learning, forKey: "redlight.learningEnabled")
        manager = LearningRig.make(
            defaults: defaults, clock: clock, presence: presence, gamma: gamma, location: location, fade: fade,
            uptime: uptime)
    }

    static func make(
        defaults: UserDefaults, clock: LearningClock, presence: FakePresence, gamma: MockGammaController,
        location: FakeLocationProvider, fade: TimeInterval = 0, uptime: (() -> TimeInterval)? = nil
    ) -> DisplayManager {
        DisplayManager(
            gamma: gamma, getDisplayIDs: { [1] }, getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) }, defaults: defaults, location: location,
            now: { clock.date }, calendar: calendar, adaptiveTransitionDuration: fade,
            displayTransitionDuration: 0,
            transitionUptime: fade > 0 ? { 0 } : { ProcessInfo.processInfo.systemUptime }, presence: presence,
            uptime: uptime ?? { ProcessInfo.processInfo.systemUptime })
    }

    /// The same defaults, as the app would find them at its next launch.
    func relaunch() {
        manager.flushLearning()
        manager = LearningRig.make(defaults: defaults, clock: clock, presence: presence, gamma: gamma, location: location)
    }

    /// Move the clock and run one Auto tick, with someone at the screen or not.
    func tick(to date: Date, step: TimeInterval, attended: Bool = true) {
        clock.date = date
        if presence.isAway == attended { presence.isAway = !attended }
        manager.applyAdaptive()
        manager.learningTick(elapsed: step)
    }

    func at(day: Int = 0, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let midnight = Self.start.addingTimeInterval(-4 * 3600 + Double(day) * 86_400)
        return midnight.addingTimeInterval(Double(hour * 3600 + minute * 60 + second))
    }

    /// Sit at the screen from one time to another, in steps.
    func sit(from: Date, to: Date, step: TimeInterval = 60) {
        var date = from
        while date < to {
            tick(to: date, step: step)
            date = date.addingTimeInterval(step)
        }
    }

    /// Walk away and let the clock reach `date`: a learning day that has ended closes.
    func leave(until date: Date) {
        presence.isAway = true
        clock.date = date
        manager.learningTick(elapsed: 0)
        presence.isAway = false
        manager.applyAdaptive()
    }

    /// Auto's own curve in the default limits at the clock's time, with nothing learned.
    func plain() -> (intensity: Double, whitepoint: Double) {
        let date = clock.date
        let (elevation, rising) = SolarCalculator.position(at: date, latitude: Self.latitude, longitude: Self.longitude)
        let target = AdaptiveMapping.target(
            elevation: elevation,
            minElevation: SolarCalculator.elevationAtSolarMidnight(at: date, latitude: Self.latitude, longitude: Self.longitude),
            maxElevation: SolarCalculator.elevationAtSolarNoon(at: date, latitude: Self.latitude, longitude: Self.longitude),
            rising: rising, presets: Preset.defaults,
            intensityMin: 0, intensityMax: 1, whitepointMin: 0.625, whitepointMax: 1)
        return (target.intensity, target.whitepoint)
    }

    var color: HabitModel.Channel { manager.learnedModel!.color }
    var white: HabitModel.Channel { manager.learnedModel!.whitepoint }
}

@MainActor @Suite struct LearnedAutoTests {
    let defaultsRegistry = TestDefaultsRegistry()
    private let day = SolarCurve.Anchor.day.rawValue
    private let late = SolarCurve.Anchor.late.rawValue

    private func rig(at date: Date = LearningRig.start, learning: Bool = true, located: Bool = true) -> LearningRig {
        LearningRig(defaults: defaultsRegistry.makeDefaults(prefix: "LearnedAuto"), at: date, learning: learning, located: located)
    }

    // MARK: Off is today

    @Test func withNothingLearnedAutoShowsWhatItDoesWithoutLearning() {
        let on = rig(), off = rig(learning: false)
        #expect(on.manager.learningEnabled && !off.manager.learningEnabled)
        for r in [on, off] {
            r.tick(to: r.at(11), step: 5)
            r.manager.intensity = 0.8                       // a flat nudge, as the command line makes it
            r.manager.adaptiveWpMin = 0.7
            r.manager.flushBandRefresh()
        }
        var date = on.at(11)
        while date < on.at(day: 1, 3) {
            on.tick(to: date, step: 0)
            off.tick(to: date, step: 0)
            #expect(abs(on.manager.intensity - off.manager.intensity) < 1e-12, "\(date)")
            #expect(abs(on.manager.whitepoint - off.manager.whitepoint) < 1e-12, "\(date)")
            date = date.addingTimeInterval(600)
        }
        #expect(on.manager.adaptiveStatusText == off.manager.adaptiveStatusText)
        #expect(on.manager.adaptiveStatusText.contains(" · adjusted"))
    }

    @Test func switchingOnForTheFirstTimeChangesNothing() {
        let r = rig(learning: false)
        r.tick(to: r.at(17), step: 5)
        r.manager.intensity = 0.6
        let before = (r.manager.intensity, r.manager.whitepoint, r.manager.adaptiveMin, r.manager.adaptiveMax)
        r.manager.setLearning(true)
        #expect(r.manager.learningEnabled)
        #expect(abs(r.manager.intensity - before.0) < 1e-12 && abs(r.manager.whitepoint - before.1) < 1e-12)
        #expect(r.manager.adaptiveMin == before.2 && r.manager.adaptiveMax == before.3)
        #expect(r.color.knownAnchors == 0)
        #expect(r.defaults.bool(forKey: "redlight.learningEnabled"))
    }

    // MARK: Nudges

    @Test func aNudgeLandsOnTheValueAndTheFirstOneMovesTheWholeCurve() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        #expect(r.manager.intensity == 1)
        r.manager.setIntensityPushingBand(0.9)
        #expect(r.manager.intensity == 0.9)
        #expect(r.color.isKnown(day) && r.color.knownAnchors == 1)
        #expect(abs(r.color.flat + 0.1) < 1e-12)
        // Open anchors follow: the evening is 10 % lower too.
        r.tick(to: r.at(18), step: 0)
        #expect(abs(r.manager.intensity - (r.plain().intensity - 0.1)) < 1e-9)
        #expect(r.manager.adaptiveStatusText.contains(" · adjusted"))
        r.tick(to: r.at(day: 1, 11), step: 0)
        #expect(r.manager.adaptiveStatusText.contains(" · learned"))
    }

    @Test func whitePointLearnsInSliderUnitsAndShowsInItsOwn() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setWhitepointPushingBand(WhitepointScale.output(0.8))
        #expect(abs(r.manager.whitepoint - WhitepointScale.output(0.8)) < 1e-12)
        #expect(abs(r.white.flat + 0.2) < 1e-9)                         // 20 % of the slider
        #expect(r.white.isKnown(day))
        r.tick(to: r.at(11, 1), step: 0)
        #expect(abs(r.manager.whitepoint - WhitepointScale.output(0.8)) < 1e-9)
    }

    @Test func aDragIsOneNudgeAndAnOvershootDoesNotLeaveTheFlagLifted() throws {
        let r = rig()
        // Teach a max of 90 %: one nudge at midday, then four days of sitting through it.
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        for d in 0..<5 {
            r.sit(from: r.at(day: d, 11, 5), to: r.at(day: d, 11, 30))
            r.leave(until: r.at(day: d + 1, 4, 5))
        }
        #expect(abs(r.manager.adaptiveMax - 0.9) < 1e-9, "the max flag is learned")
        #expect(r.color.hasLearnedFlags && r.color.handBand == 0...1)

        // A drag up past the flag and back: a stream of writes seconds apart.
        r.tick(to: r.at(day: 5, 11), step: 5)
        for (offset, value) in [(0.0, 0.95), (1, 1.0), (2, 0.97), (3, 0.92)] {
            r.clock.date = r.at(day: 5, 11).addingTimeInterval(offset)
            r.manager.setIntensityPushingBand(value)
        }
        #expect(abs(r.manager.intensity - 0.92) < 1e-9)
        #expect(abs(r.manager.adaptiveMax - 0.92) < 1e-9, "the flag ends where the last value needs it")
        #expect(r.color.handBand == 0...1, "a lift does not rescale the curve")

        // The command line and hotkeys stay inside the flags.
        r.clock.date = r.at(day: 5, 11, 10)
        r.manager.intensity = 0.99
        #expect(abs(r.manager.intensity - 0.92) < 1e-9)
    }

    @Test func aHotkeyRightAfterASliderPushDoesNotUndoThePush() {
        for (key, expected) in [(1.0, 0.95), (0.9, 0.9)] {
            let r = rig()
            r.tick(to: r.at(11), step: 5)
            r.manager.adaptiveMax = 0.8
            r.manager.flushBandRefresh()
            r.manager.setIntensityPushingBand(0.95)          // past the hand band: a hand move
            #expect(r.color.handBand.upperBound == 0.95)
            r.clock.date = r.at(11, 1)                      // Cooler or Warmer, a minute on
            r.manager.intensity = key
            #expect(abs(r.manager.intensity - expected) < 1e-9, "key \(key)")
            #expect(r.color.handBand.upperBound == 0.95 && r.manager.adaptiveMax == 0.95, "key \(key)")
        }
    }

    @Test func savingAPresetRightAfterASliderPushDoesNotUndoThePush() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.adaptiveMax = 0.8
        r.manager.flushBandRefresh()
        r.manager.setIntensityPushingBand(1.0)
        r.clock.date = r.at(11, 1)
        r.manager.saveToPreset(0)                           // Day is 100 % already: no reshape
        #expect(r.manager.intensity == 1)
        #expect(r.color.handBand.upperBound == 1 && r.manager.adaptiveMax == 1)
    }

    @Test func aDragIsOneNudgeForAsLongAsEachWriteFollowsTheLastWithinTwoMinutes() {
        let r = rig()
        learnMaxFlagOfNinety(r)
        // Past the learned flag and back, writes 100 s apart: 200 s from the first, one nudge.
        for (offset, value) in [(0.0, 1.0), (100, 0.97), (200, 0.92)] {
            r.clock.date = r.at(day: 5, 11).addingTimeInterval(offset)
            r.manager.applyAdaptive()
            r.manager.setIntensityPushingBand(value)
        }
        #expect(abs(r.manager.adaptiveMax - 0.92) < 1e-9, "the flag ends where the last value needs it")
        r.clock.date = r.at(day: 5, 11, 10)
        r.manager.intensity = 0.99
        #expect(abs(r.manager.intensity - 0.92) < 1e-9)
    }

    @Test func aLimitSetDuringADragIsNotUndoneByTheDragsNextWrite() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.clock.date = r.at(11, 0, 30)
        r.manager.adaptiveMin = 0.3                         // `redlight limits`, or a flag dragged
        r.manager.flushBandRefresh()
        r.clock.date = r.at(11, 1)
        r.manager.setIntensityPushingBand(0.85)             // within two minutes of the first write
        #expect(abs(r.color.handBand.lowerBound - 0.3) < 1e-12, "the limit stands")
        #expect(r.color.votes(at: late) == HabitModel.Channel.standing)
        #expect(abs(r.manager.intensity - 0.85) < 1e-9)
    }

    @Test func aValueSetBeforeThereIsACurveBecomesANudgeWhenThereIsOne() {
        let r = rig(at: LearningRig.start.addingTimeInterval(7 * 3600), located: false)
        r.manager.applyAdaptive()
        r.manager.intensity = 0.85
        #expect(r.manager.intensity == 0.85)
        #expect(r.color.knownAnchors == 0)
        r.location.coordinate = (LearningRig.latitude, LearningRig.longitude)
        r.manager.applyAdaptive()
        #expect(abs(r.manager.intensity - 0.85) < 1e-9)
        #expect(r.color.isKnown(day))
        #expect(abs(r.color.flat + 0.15) < 1e-9)
    }

    // MARK: Limits

    @Test func aFlagMovedByHandScalesTheCurveAndStandsLikeFourDays() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.adaptiveMax = 0.8
        r.manager.flushBandRefresh()
        #expect(r.color.handBand == 0...0.8 && r.color.flags == 0...0.8)
        #expect(r.color.votes(at: day).count == 4 && r.color.offset(of: day) == 0)
        #expect(abs(r.manager.intensity - 0.8) < 1e-12)
        r.tick(to: r.at(18), step: 0)
        #expect(abs(r.manager.intensity - 0.8 * r.plain().intensity) < 1e-9, "the curve is scaled, as without learning")
    }

    @Test func limitsFromTheCommandLineAreAHandMoveAtBothEnds() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.adaptiveMin = 0.3
        r.manager.adaptiveMax = 0.9
        r.manager.flushBandRefresh()
        #expect(abs(r.color.handBand.lowerBound - 0.3) < 1e-12 && abs(r.color.handBand.upperBound - 0.9) < 1e-12)
        #expect(r.color.votes(at: day).count == 4 && r.color.votes(at: late).count == 4)
        // Later, one end alone: the other keeps what the day has of it.
        r.sit(from: r.at(11, 1), to: r.at(11, 30))
        let dwell = r.color.state.buckets[day].dwell
        #expect(!dwell.isEmpty)
        r.manager.adaptiveMin = 0.2
        r.manager.flushBandRefresh()
        #expect(r.color.state.buckets[day].dwell == dwell, "the max was not set again")
        #expect(abs(r.color.handBand.lowerBound - 0.2) < 1e-12 && abs(r.color.handBand.upperBound - 0.9) < 1e-12)
        r.tick(to: r.at(18), step: 0)
        #expect(abs(r.manager.intensity - (0.2 + 0.7 * r.plain().intensity)) < 1e-9)
    }

    /// One nudge to 90 % at midday, then four more days of sitting through it: the max flag
    /// follows to 90 %, inside a hand band of 0…1.
    private func learnMaxFlagOfNinety(_ r: LearningRig) {
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        for d in 0..<5 {
            r.sit(from: r.at(day: d, 11, 5), to: r.at(day: d, 11, 30))
            r.leave(until: r.at(day: d + 1, 4, 5))
        }
    }

    @Test func aLimitSetByHandOnItsLearnedFlagStands() {
        let r = rig()
        learnMaxFlagOfNinety(r)
        #expect(abs(r.manager.adaptiveMax - 0.9) < 1e-9 && r.color.handBand.upperBound == 1)
        let lateVotes = r.color.votes(at: late)
        r.tick(to: r.at(day: 5, 11), step: 0)
        // `redlight limits 0 90`: both ends restated where they are.
        r.manager.adaptiveMin = r.manager.adaptiveMin
        r.manager.adaptiveMax = r.manager.adaptiveMax
        r.manager.flushBandRefresh()
        #expect(abs(r.color.handBand.upperBound - 0.9) < 1e-9, "the learned flag is the user's now")
        #expect(!r.color.hasLearnedFlags)
        #expect(r.color.votes(at: day) == Array(repeating: HabitModel.Vote(value: 0, weight: 1), count: 4))
        #expect(r.color.votes(at: late) == lateVotes, "an end that was not learned keeps its history")
        #expect(abs(r.manager.intensity - 0.9) < 1e-9, "nothing moves on screen")
    }

    @Test func limitsThatMoveOneEndStillStandTheOtherOnItsLearnedFlag() {
        let r = rig()
        learnMaxFlagOfNinety(r)
        r.tick(to: r.at(day: 5, 11), step: 0)
        // `redlight limits 10 90`: the min moves first, which folds the learned max.
        r.manager.adaptiveMin = 0.1
        r.manager.adaptiveMax = r.manager.adaptiveMax
        r.manager.flushBandRefresh()
        #expect(abs(r.color.handBand.upperBound - 0.9) < 1e-9 && abs(r.color.handBand.lowerBound - 0.1) < 1e-12)
        #expect(r.color.votes(at: day) == Array(repeating: HabitModel.Vote(value: 0, weight: 1), count: 4))
        #expect(r.color.votes(at: late) == Array(repeating: HabitModel.Vote(value: 0, weight: 1), count: 4))

        // A drag of the min alone, later: the max is not set again.
        let dayVotes = r.color.votes(at: day)
        r.sit(from: r.at(day: 5, 11, 5), to: r.at(day: 5, 11, 30))
        r.leave(until: r.at(day: 6, 4, 5))
        r.tick(to: r.at(day: 6, 11), step: 0)
        r.manager.adaptiveMin = 0.15
        r.manager.flushBandRefresh()
        #expect(r.color.votes(at: day).count >= dayVotes.count, "the max keeps its history")
        #expect(r.color.votes(at: day) != Array(repeating: HabitModel.Vote(value: 0, weight: 1), count: 4))
    }

    @Test func aLimitSetByHandWinsOverTheSameDaysNudge() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.95)
        r.sit(from: r.at(11, 3), to: r.at(11, 30))
        r.manager.adaptiveMax = 0.97
        r.manager.flushBandRefresh()
        r.leave(until: r.at(day: 1, 4, 5))
        #expect(r.manager.adaptiveMax == 0.97, "the close does not move the flag past where it was set")
        #expect(r.color.offset(of: day) == 0)
    }

    @Test func aFoldMovesTheDaysEvidenceWithTheAnchors() {
        let r = rig()
        learnMaxFlagOfNinety(r)
        r.sit(from: r.at(day: 5, 11, 5), to: r.at(day: 5, 11, 30))
        r.manager.adaptiveMin = 0.1                         // folds the learned max into the hand band
        r.manager.flushBandRefresh()
        let own = r.color.offset(of: day)
        #expect(r.color.state.buckets[day].dwell.map(\.value) == [HabitModel.Channel.rounded(own)])
        #expect(abs(r.color.state.start[day] - own) < 1e-12)
    }

    @Test func aFixedChannelTakesNoNudgesAndNoDwell() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setWhitepointPushingBand(WhitepointScale.output(0.8))
        r.manager.adaptiveMin = 0.7
        r.manager.adaptiveMax = 0.7
        r.manager.flushBandRefresh()
        #expect(r.manager.isIntensityPinned)
        r.manager.intensity = 0.6                           // moves the pin
        #expect(r.manager.adaptiveMin == 0.6 && r.manager.adaptiveMax == 0.6)
        #expect(r.color.flags == 0.6...0.6 && r.color.flat == 0)
        r.sit(from: r.at(11, 5), to: r.at(11, 40))
        #expect(r.color.state.buckets.allSatisfy { $0.dwell.isEmpty })
        #expect(!r.white.state.buckets[day].dwell.isEmpty, "the other channel still learns")
    }

    // MARK: Resets and the switch

    @Test func resetBesideASliderForgetsThatChannelAndResetLearningKeepsTheOffset() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.manager.setWhitepointPushingBand(WhitepointScale.output(0.8))
        #expect(!r.manager.intensityIsDefault)
        r.manager.resetIntensity()
        #expect(r.color.knownAnchors == 0 && r.color.flat == 0 && r.manager.intensity == 1)
        #expect(r.manager.intensityIsDefault)
        #expect(r.white.isKnown(day), "the other channel is untouched")

        r.manager.resetLearning()
        #expect(r.white.knownAnchors == 0)
        #expect(abs(r.white.flat + 0.2) < 1e-9, "Auto's own offset is kept")
        #expect(abs(r.manager.whitepoint - WhitepointScale.output(0.8)) < 1e-9)
    }

    @Test func switchingOffHoldsTheScreenAndSwitchingOnBringsTheLearningBack() {
        let r = rig()
        // Evening only: the sunset anchor is known 15 % lower, midday stays open at the flat offset.
        r.tick(to: r.at(18, 10), step: 5)
        r.manager.setIntensityPushingBand(r.manager.intensity - 0.15)
        r.sit(from: r.at(18, 13), to: r.at(18, 40))
        r.leave(until: r.at(day: 1, 4, 5))
        #expect(r.color.knownAnchors >= 1 && !r.color.isKnown(day))
        r.tick(to: r.at(day: 1, 18, 10), step: 0)
        let showing = r.manager.intensity
        let model = r.manager.learnedModel!

        r.manager.setLearning(false)
        #expect(!r.manager.learningEnabled)
        #expect(abs(r.manager.intensity - showing) < 1e-9, "off holds the screen")
        r.tick(to: r.at(day: 1, 18, 11), step: 0)
        #expect(abs(r.manager.intensity - showing) < 0.02)
        #expect(r.manager.adaptiveStatusText.contains(" · adjusted"))

        r.manager.setLearning(true)
        #expect(r.manager.learnedModel!.color.state.own == model.color.state.own, "the anchors come back")
        #expect(abs(r.color.flat - model.color.flat) < 1e-9, "and so does the flat offset, untouched meanwhile")
    }

    @Test func switchingOffKeepsLearnedFlagsAsLimitsAndOnTakesOnlyAnOffsetChangedMeanwhile() {
        let r = rig()
        learnMaxFlagOfNinety(r)
        r.tick(to: r.at(day: 5, 18, 10), step: 0)
        let showing = r.manager.intensity
        r.manager.setLearning(false)
        // The learned flag is an ordinary limit now: folded into the hand band, the screen held.
        #expect(abs(r.manager.adaptiveMax - 0.9) < 1e-9)
        #expect(abs(r.color.handBand.upperBound - 0.9) < 1e-9 && !r.color.hasLearnedFlags)
        #expect(abs(r.manager.intensity - showing) < 1e-9)
        let flat = r.color.flat, held = r.manager.adaptiveIntensityAdjustment
        #expect(abs(flat - held) > 0.01, "what holds the screen is not the model's own offset")

        // Nothing changed meanwhile: the model's own flat offset comes back, not the one that
        // held the screen.
        r.manager.setLearning(true)
        #expect(abs(r.color.flat - flat) < 1e-12)

        // Auto's offset changed while learning was off: that is the flat offset now.
        r.manager.setLearning(false)
        r.tick(to: r.at(day: 5, 18, 11), step: 0)
        r.manager.intensity = r.manager.intensity - 0.1
        let changed = r.manager.adaptiveIntensityAdjustment
        r.manager.setLearning(true)
        #expect(abs(r.color.flat - changed) < 1e-12)
    }

    @Test func savingAPresetInAutoKeepsTheScreenAndWhatWasLearned() {
        let r = rig()
        r.tick(to: r.at(18, 10), step: 0)
        r.manager.setIntensityPushingBand(r.manager.intensity - 0.15)
        r.sit(from: r.at(18, 13), to: r.at(18, 40))
        r.leave(until: r.at(day: 1, 4, 5))
        r.tick(to: r.at(day: 1, 18, 10), step: 0)
        let showing = r.manager.intensity
        let known = r.color.knownAnchors
        #expect(known >= 1)
        let base = r.color.state.base

        r.manager.saveToPreset(2)                              // Sunset takes what is showing
        #expect(abs(r.manager.intensity - showing) < 1e-9, "the screen stays where it was saved")
        #expect(r.color.state.base != base, "the curve under the anchors was reshaped")
        #expect(r.color.knownAnchors >= known)
        r.tick(to: r.at(day: 1, 18, 11), step: 0)
        #expect(abs(r.manager.intensity - showing) < 0.02)

        // With learning off the stored model still follows a preset, for when it is back on.
        r.manager.setLearning(false)
        let stored = r.manager.learnedModel!.color.state.base
        r.manager.saveToPreset(1)
        #expect(r.manager.learnedModel!.color.state.base != stored)
    }

    /// The anchor that leads the curve at a time, at the rig's place.
    private func leadAnchor(at date: Date) -> Int {
        let (lat, lon) = (LearningRig.latitude, LearningRig.longitude)
        let (elevation, rising) = SolarCalculator.position(at: date, latitude: lat, longitude: lon)
        return SolarCurve.phase(
            elevation: elevation,
            minElevation: SolarCalculator.elevationAtSolarMidnight(at: date, latitude: lat, longitude: lon),
            maxElevation: SolarCalculator.elevationAtSolarNoon(at: date, latitude: lat, longitude: lon),
            rising: rising).lead.rawValue
    }

    @Test func aNudgeMadeTheDayAPresetIsSavedStillCountsAtTheClose() {
        let r = rig()
        // Sunset learned 10 % lower, one day.
        r.tick(to: r.at(18, 10), step: 0)
        r.manager.setIntensityPushingBand(r.manager.intensity - 0.10)
        r.sit(from: r.at(18, 13), to: r.at(18, 40))
        r.leave(until: r.at(day: 1, 4, 5))
        // The next day: 5 % lower still, then Save to Sunset. Saved out of Auto, so that no
        // hold write after the save marks the nudge again.
        r.tick(to: r.at(day: 1, 17, 55), step: 0)
        let lead = leadAnchor(at: r.at(day: 1, 17, 55))
        #expect(r.color.isKnown(lead) && !r.color.votes(at: lead).isEmpty)
        r.manager.setIntensityPushingBand(r.manager.intensity - 0.05)
        r.manager.adaptiveEnabled = false
        let base = r.color.state.base
        r.manager.saveToPreset(2)
        #expect(r.color.state.base != base)
        r.manager.adaptiveEnabled = true
        let picture = r.color.shown(at: lead)
        r.sit(from: r.at(day: 1, 17, 58), to: r.at(day: 1, 19))
        #expect(r.color.state.buckets[lead].total >= 600, "sat through long enough for a vote")
        r.leave(until: r.at(day: 2, 4, 5))
        // The vote is the dwell's value, which is rounded to four places.
        #expect(abs(r.color.shown(at: lead) - picture) < 1e-3, "the nudge is kept, not voted back")
    }

    @Test func savingAPresetKeepsEveryKnownPartOfTheDayAndDropsTheTimeSatThrough() {
        for learning in [true, false] {
            let r = rig()
            // Midday and the evening learned apart; the next day, time sat through and a nudge.
            r.tick(to: r.at(11), step: 0)
            r.manager.setIntensityPushingBand(0.9)
            r.sit(from: r.at(11, 3), to: r.at(11, 30))
            r.tick(to: r.at(18, 10), step: 0)
            r.manager.setIntensityPushingBand(r.manager.intensity - 0.15)
            r.sit(from: r.at(18, 13), to: r.at(18, 40))
            r.leave(until: r.at(day: 1, 4, 5))
            r.sit(from: r.at(day: 1, 11), to: r.at(day: 1, 11, 30))
            r.tick(to: r.at(day: 1, 18, 10), step: 0)
            r.manager.setIntensityPushingBand(r.manager.intensity - 0.05)
            r.sit(from: r.at(day: 1, 18, 13), to: r.at(day: 1, 18, 40))
            if !learning { r.manager.setLearning(false) }
            let before = r.manager.learnedModel!.color
            let known = (0..<12).filter(before.isKnown)
            // Switched off, the day is dropped already.
            #expect(known.count >= 3 && before.state.buckets.contains { !$0.dwell.isEmpty } == learning)
            // Out of Auto, so that only the reshape acts: in Auto a hold write follows.
            r.manager.adaptiveEnabled = false
            r.manager.saveToPreset(2)
            let after = r.manager.learnedModel!.color
            #expect(after.state.base != before.state.base, "learning \(learning): the curve was reshaped")
            for anchor in known {
                #expect(abs(after.shown(at: anchor) - before.shown(at: anchor)) < 1e-12,
                        "learning \(learning): anchor \(anchor) keeps its picture")
            }
            #expect(after.state.buckets.allSatisfy { $0.dwell.isEmpty }, "learning \(learning): the day's time is dropped")
            #expect(after.state.written == before.state.written, "learning \(learning): the day's nudges stand")
        }
    }

    @Test func savingAPresetLeavesThePartsOfTheDayItDoesNotTouch() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setIntensityPushingBand(0.9)
        r.tick(to: r.at(18, 10), step: 0)
        r.manager.setIntensityPushingBand(r.manager.intensity - 0.15)
        let flat = r.color.flat, offset = r.manager.adaptiveIntensityAdjustment
        #expect(r.color.knownAnchors >= 2)
        // Out of Auto, so that only the reshape acts: in Auto a hold write follows.
        r.manager.adaptiveEnabled = false
        let base = r.color.state.base
        r.manager.saveToPreset(2)
        #expect(r.color.state.base != base)
        #expect(abs(r.color.flat - flat) < 1e-12, "open parts of the day keep their offset")
        #expect(abs(r.manager.adaptiveIntensityAdjustment - offset) < 1e-12)
    }

    @Test func aSavedModelWithALiftedFlagOrAWideOffsetIsStillRead() throws {
        let base = LearnedAutoFixtures.baseline(Preset.defaults.map(\.intensity), 0...1)
        let model = HabitModel(color: HabitModel.Channel(band: 0...0.9, base: base),
                               whitepoint: HabitModel.Channel(band: 0.5...1, base: base))
        func decoded(_ change: (inout [String: Any]) -> Void) throws -> HabitModel? {
            let data = try #require(model.encoded())
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var color = try #require(object["color"] as? [String: Any])
            var state = try #require(color["state"] as? [String: Any])
            change(&state)
            color["state"] = state
            object["color"] = color
            return HabitModel.decode(try JSONSerialization.data(withJSONObject: object))
        }
        #expect(try decoded { _ in } == model)
        // An offset can pass the slider's range where a known anchor stands far from the open ones.
        #expect(try decoded { $0["flat"] = -1.5 } != nil)
        // A lifted flag may sit a rounding error outside the hand band.
        #expect(try decoded { $0["upper"] = 0.9 + 1e-10 } != nil)
        #expect(try decoded { $0["upper"] = 0.95 } == nil)
        #expect(try decoded { $0["flat"] = 9.0 } == nil)
        #expect(try decoded { $0["own"] = [0.1] } == nil)
    }

    // MARK: Evidence and the close

    @Test func dwellCountsOnlyWhileSomeoneIsAtATintedScreenThatAutoDrives() {
        let r = rig()
        func dwell() -> Double { r.color.state.buckets[day].total }
        // At 100 % with nothing learned the screen is on its limit, where nothing counts.
        // A nudge off the limit makes midday known; dwell counts from two minutes after it.
        r.tick(to: r.at(10, 50), step: 0)
        r.manager.setIntensityPushingBand(0.9)
        r.tick(to: r.at(10, 51), step: 60)
        #expect(dwell() == 0, "the nudge has not settled")
        r.tick(to: r.at(11), step: 0)
        r.tick(to: r.at(11, 1), step: 60)
        #expect(dwell() == 60)

        r.presence.idle = 601
        r.tick(to: r.at(11, 2), step: 60)
        #expect(dwell() == 60, "no input for ten minutes")
        r.presence.idle = 0

        r.tick(to: r.at(11, 3), step: 60, attended: false)
        #expect(dwell() == 60, "screens asleep or locked")

        #expect(r.manager.pause(for: 600))
        r.tick(to: r.at(11, 4), step: 60)
        #expect(dwell() == 60, "paused")
        r.manager.resume()

        r.manager.setActiveApp(.photos(.pause))
        r.tick(to: r.at(11, 5), step: 60)
        #expect(dwell() == 60, "in an app with a Pause")
        r.manager.setActiveApp(.photos(.hold(color: 30, whitepoint: 80)))
        r.tick(to: r.at(11, 5, 30), step: 30)
        #expect(dwell() == 60, "in an app with a Hold, Auto is not what is seen")
        r.manager.setActiveApp(nil)

        r.manager.toggle(1)
        r.tick(to: r.at(11, 6), step: 60)
        #expect(dwell() == 60, "no display filtering")
        r.manager.toggle(1)

        r.tick(to: r.at(11, 7), step: 60)
        #expect(dwell() == 120)
    }

    /// Time in an app with a Shift is evidence for the general day, measured without the
    /// shift: it learns exactly what the same time without the app would, and the screen
    /// shows the shift on top. Editing the rule there is no nudge.
    @Test func timeInAShiftAppCountsWithoutTheShift() {
        let shifted = rig(), plain = rig()
        for r in [shifted, plain] {
            r.tick(to: r.at(10, 50), step: 0)
            r.manager.setIntensityPushingBand(0.9)
            r.tick(to: r.at(11), step: 0)
        }
        shifted.manager.setActiveApp(.photos(.shift(color: -20, whitepoint: 10)))
        for r in [shifted, plain] { r.sit(from: r.at(11, 1), to: r.at(12)) }
        shifted.manager.setActiveApp(.photos(.shift(color: -30, whitepoint: 0)))
        for r in [shifted, plain] { r.sit(from: r.at(12), to: r.at(12, 30)) }
        #expect(shifted.manager.learnedModel == plain.manager.learnedModel)
        #expect(shifted.manager.learningRevision == plain.manager.learningRevision)
        #expect(shifted.manager.intensity == plain.manager.intensity)
        #expect(abs(shifted.manager.effectiveTarget.intensity - (plain.manager.intensity - 0.3)) < 1e-9)
    }

    @Test func aLongGapBetweenTicksCountsAsAMinuteAndAnAbsenceAsNothing() {
        let r = rig()
        func tick(_ date: Date) {
            r.clock.date = date
            r.manager.applyAdaptive()
            r.manager.learningTick()
        }
        r.tick(to: r.at(10, 50), step: 0)
        r.manager.setIntensityPushingBand(0.9)
        r.tick(to: r.at(11), step: 0)
        tick(r.at(11, 0, 5))
        #expect(r.color.state.buckets[day].total == 5)
        // A timer held back while someone is there (App Nap, coalescing): a minute at most.
        tick(r.at(11, 30))
        #expect(r.color.state.buckets[day].total == 65)
        // Away and back in between: none of it counts.
        r.presence.isAway = true
        r.clock.date = r.at(12)
        r.presence.isAway = false
        tick(r.at(12, 30))
        #expect(r.color.state.buckets[day].total == 65)
    }

    @Test func theDayClosesOnlyOnceNobodyIsAtTheScreen() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        #expect(r.color.votes(at: day).isEmpty)

        // Still at the screen when 04:00 passes: nothing closes in front of them.
        r.tick(to: r.at(day: 1, 4, 1), step: 60)
        #expect(r.color.votes(at: day).isEmpty)
        #expect(r.manager.learnedModel!.dayStart == LearningRig.start)

        // The screen locks: the day closes.
        r.presence.isAway = true
        #expect(r.color.votes(at: day).count == 1)
        #expect(r.manager.learnedModel!.dayStart == LearningRig.start.addingTimeInterval(86_400))
    }

    @Test func aDesktopThatNeverSleepsClosesAfterHalfAnHourIdle() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        // Ten idle minutes stop the evidence, but someone reading may still be there.
        r.presence.idle = 700
        r.tick(to: r.at(day: 1, 4, 1), step: 60)
        #expect(r.color.votes(at: day).isEmpty)
        r.presence.idle = 1800
        r.tick(to: r.at(day: 1, 4, 2), step: 60)
        #expect(r.color.votes(at: day).count == 1)
    }

    @Test func aVideoPlayingKeepsTheDayOpenAsIfSomeoneWereThere() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        r.presence.idle = 3600
        r.presence.isVideoKeepingDisplayAwake = true
        r.tick(to: r.at(day: 1, 4, 1), step: 60)
        #expect(r.color.votes(at: day).isEmpty, "a film across 04:00")
        r.presence.isVideoKeepingDisplayAwake = false
        r.tick(to: r.at(day: 1, 4, 2), step: 60)
        #expect(r.color.votes(at: day).count == 1)
    }

    @Test func aLockedScreenIsNobodyThereWhateverTheNotificationsSaid() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        r.presence.isLocked = true
        let dwell = r.color.state.buckets[day].total
        r.tick(to: r.at(11, 31), step: 60)
        #expect(r.color.state.buckets[day].total == dwell, "no evidence while locked")
        r.tick(to: r.at(day: 1, 4, 1), step: 60)
        #expect(r.color.votes(at: day).count == 1)
    }

    @Test func someoneThereForTwelveHoursPastTheEndStillGetsAClose() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        r.presence.isVideoKeepingDisplayAwake = true          // and input all along: a kiosk or a jiggler
        r.tick(to: r.at(day: 1, 15, 59), step: 60)
        #expect(r.color.votes(at: day).isEmpty)
        r.tick(to: r.at(day: 1, 16), step: 60)
        #expect(r.color.votes(at: day).count == 1)
        #expect(r.manager.learnedModel!.dayStart == r.at(day: 1, 4))
    }

    @Test func theSystemCanBeAskedWhetherAnyoneIsThere() {
        // What the system says depends on the machine; asking must not fail.
        let presence = SystemPresence()
        _ = presence.isLocked
        #expect(!presence.areScreensAsleep, "no sleep notification has arrived")
        _ = presence.isVideoKeepingDisplayAwake
        #expect(presence.idleSeconds() >= 0)
    }

    @Test func screensThatWakeCloseTheDayBeforeAnyoneSeesIt() {
        let r = LearningRig(defaults: defaultsRegistry.makeDefaults(prefix: "LearnedAuto"), fade: 2)
        // Midday and sunset known apart: the close moves the morning's offset.
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        r.tick(to: r.at(18, 10), step: 0)
        r.manager.setIntensityPushingBand(r.manager.intensity - 0.15)
        r.manager.completeOutputTransition()
        let flat = r.color.flat
        // The screens sleep before 04:00, and the timer that would close the day is held back.
        r.presence.areScreensAsleep = true
        r.presence.isAway = true
        r.clock.date = r.at(day: 1, 9)
        r.presence.areScreensAsleep = false
        r.presence.isAway = false
        #expect(r.color.votes(at: day).isEmpty)
        r.manager.handleDisplayWake()
        #expect(r.color.votes(at: day).count == 1)
        #expect(abs(r.color.flat - flat) > 0.01, "the close changes what the morning shows")
        #expect(!r.manager.commandIsFading, "the close is in place as the screens light")
    }

    @Test func aCloseFadesOnlyWhereSomeoneCouldSeeIt() {
        for asleep in [true, false] {
            let r = LearningRig(defaults: defaultsRegistry.makeDefaults(prefix: "LearnedAuto"), fade: 2)
            // Midday and sunset known apart: the close sets the night between them.
            r.tick(to: r.at(11), step: 5)
            r.manager.setIntensityPushingBand(0.9)
            r.sit(from: r.at(11, 5), to: r.at(11, 30))
            r.tick(to: r.at(18, 10), step: 0)
            r.manager.setIntensityPushingBand(r.manager.intensity - 0.15)
            r.tick(to: r.at(day: 1, 4, 1), step: 60)
            r.manager.completeOutputTransition()
            let night = r.manager.intensity
            // Asleep, or locked with the screens on.
            r.presence.areScreensAsleep = asleep
            r.presence.isAway = true
            #expect(r.color.votes(at: day).count == 1)
            #expect(abs(r.manager.intensity - night) > 0.01, "the close changes the night")
            #expect(r.manager.commandIsFading == !asleep, "asleep: \(asleep)")
        }
    }

    @Test func aSleepOfSeveralDaysClosesOnceOnWake() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        r.presence.isAway = true
        r.clock.date = r.at(day: 3, 9)
        r.manager.handleWake()
        r.presence.isAway = false
        #expect(r.color.votes(at: day).count == 1)
        #expect(r.manager.learnedModel!.dayStart == r.at(day: 3, 4))
        #expect(abs(r.manager.intensity - (r.plain().intensity - 0.1)) < 1e-9)
    }

    @Test func aPauseOrAnAppsRuleDoesNotCloseTheDayInFrontOfSomeone() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        // Past 04:00 and still there, with the tint paused, then in an app with a Pause and
        // one with a Hold, then a flag held.
        #expect(r.manager.pause(for: 600))
        r.tick(to: r.at(day: 1, 4, 1), step: 60)
        r.manager.resume()
        r.manager.setActiveApp(.photos(.pause))
        r.tick(to: r.at(day: 1, 4, 2), step: 60)
        r.manager.setActiveApp(.photos(.hold(color: 30, whitepoint: 80)))
        r.tick(to: r.at(day: 1, 4, 2, 30), step: 30)
        r.manager.setActiveApp(nil)
        r.manager.previewIntensity(0.5)
        r.tick(to: r.at(day: 1, 4, 3), step: 60)
        r.manager.endPreview()
        #expect(r.color.votes(at: day).isEmpty, "none of these is nobody at the screen")
        #expect(r.manager.learnedModel!.dayStart == LearningRig.start)
        // Coming back from a lock does not close it either; the next time away does.
        r.presence.idle = 1800
        r.tick(to: r.at(day: 1, 4, 4), step: 60)
        #expect(r.color.votes(at: day).count == 1)
    }

    @Test func comingBackDoesNotCloseTheDayInFrontOfWhoeverReturned() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        r.presence.isAway = true                                // locked before 04:00, no tick since
        r.clock.date = r.at(day: 1, 8)
        r.presence.isAway = false
        #expect(r.color.votes(at: day).isEmpty)
        r.tick(to: r.at(day: 1, 8, 1), step: 60)
        #expect(r.color.votes(at: day).isEmpty, "still there: the close waits")
        r.presence.isAway = true
        #expect(r.color.votes(at: day).count == 1)
    }

    @Test func aBandNarrowerThanTheGapNextToAnEndStaysInRangeAndIsReadBack() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.adaptiveMin = 0.97
        r.manager.adaptiveMax = 0.99
        r.manager.flushBandRefresh()
        r.manager.setIntensityPushingBand(1.0)
        #expect(r.manager.adaptiveMax == 1 && r.color.handBand.upperBound == 1)
        #expect(r.color.isSane)
        r.relaunch()
        #expect(r.color.handBand == 0.97...1)
    }

    /// One nudge of White point to 80 % at midday, then four more days of sitting through it:
    /// its max flag follows to 80 %, inside a hand band of 50…100 %. 80 % of the white point's
    /// scale does not survive its round trip to the last bit.
    private func learnWhiteMaxFlagOfEighty(_ r: LearningRig) {
        r.tick(to: r.at(11), step: 5)
        r.manager.setWhitepointPushingBand(WhitepointScale.output(0.8))
        for d in 0..<5 {
            r.sit(from: r.at(day: d, 11, 5), to: r.at(day: d, 11, 30))
            r.leave(until: r.at(day: d + 1, 4, 5))
        }
    }

    @Test func aLearnedWhitePointLimitKeepsItsHistoryWhenTheOtherEndMoves() {
        for throughTheSwitch in [false, true] {
            let r = rig()
            learnWhiteMaxFlagOfEighty(r)
            #expect(abs(r.white.flags.upperBound - 0.8) < 1e-9 && r.white.handBand.upperBound == 1)
            let votes = r.white.votes(at: day)
            #expect(votes.count == 5 && votes != HabitModel.Channel.standing)
            r.tick(to: r.at(day: 5, 11), step: 0)
            // The min moved by hand, with learning on or while it is off.
            if throughTheSwitch { r.manager.setLearning(false) }
            r.manager.adaptiveWpMin = WhitepointScale.output(0.6)
            r.manager.flushBandRefresh()
            if throughTheSwitch { r.manager.setLearning(true) }
            let label = "through the switch: \(throughTheSwitch)"
            #expect(abs(r.white.handBand.lowerBound - 0.6) < 1e-9, "\(label)")
            #expect(abs(r.white.handBand.upperBound - 0.8) < 1e-9, "\(label): the learned max is folded in")
            #expect(r.white.votes(at: late) == HabitModel.Channel.standing, "\(label): the end that moved stands")
            // Its votes are restated against the curve folded into the new band: what each
            // stood for on screen is what it stands for now.
            let kept = r.white.votes(at: day)
            #expect(kept.map(\.weight) == votes.map(\.weight), "\(label): the max keeps its history")
            #expect(zip(kept, votes).allSatisfy { abs(($0.value - $1.value) - 0.2) < 1e-9 }, "\(label)")
        }
    }

    @Test func resettingLearningWhileItIsOffTakesAutosOffsetWhenItIsBackOn() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setIntensityPushingBand(0.9)                  // flat −10 %, midday known
        r.manager.setLearning(false)
        r.manager.intensity = 0.8                               // Auto's own offset, with learning off
        r.manager.resetLearning()
        r.manager.setLearning(true)
        #expect(r.color.knownAnchors == 0)
        #expect(abs(r.color.flat + 0.2) < 1e-9)
        #expect(abs(r.manager.intensity - 0.8) < 1e-9)
    }

    // MARK: Persistence

    @Test func whatIsLearnedSurvivesARelaunchIncludingTheDaysEvidence() throws {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        let before = try #require(r.manager.learnedModel)
        r.relaunch()
        let after = try #require(r.manager.learnedModel)
        #expect(r.manager.learningEnabled)
        #expect(after.color.state.own == before.color.state.own)
        #expect(after.color.state.buckets[day].dwell == before.color.state.buckets[day].dwell)
        #expect(after.dayStart == before.dayStart)
        r.tick(to: r.at(11, 31), step: 0)
        #expect(abs(r.manager.intensity - 0.9) < 1e-9)
    }

    @Test func everyChangeIsSavedWithoutBeingAskedTo() async throws {
        let r = rig()
        let key = "redlight.learning.model"
        func saved(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(r.defaults.data(forKey: key) == r.manager.learnedModel?.encoded(), "\(what)",
                    sourceLocation: sourceLocation)
        }
        r.tick(to: r.at(11), step: 5)
        // A drag writes many times a second: it is saved a moment after it stops.
        r.manager.setIntensityPushingBand(0.9)
        #expect(r.defaults.data(forKey: key) != r.manager.learnedModel?.encoded())
        // The save waits 2 s on the main run loop, which other suites can keep busy: poll.
        let deadline = Date().addingTimeInterval(10)
        while r.defaults.data(forKey: key) != r.manager.learnedModel?.encoded(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        saved("a nudge")
        r.sit(from: r.at(11, 3), to: r.at(11, 30))
        r.presence.isAway = true
        saved("going away")
        r.presence.isAway = false
        r.manager.adaptiveMax = 0.95
        r.manager.flushBandRefresh()
        saved("a limit")
        r.leave(until: r.at(day: 1, 4, 5))
        saved("a close")
        r.manager.resetLearning()
        saved("a reset")
        r.manager.setIntensityPushingBand(0.85)
        r.manager.setLearning(false)
        saved("the switch")
    }

    @Test func dwellAloneIsSavedAtMostEveryTenMinutesOfRealTime() {
        let key = "redlight.learning.model"
        let defaults = CountingDefaults(suiteName: defaultsRegistry.makeDomain().name)!
        var uptime: TimeInterval = 0
        let r = LearningRig(defaults: defaults, uptime: { uptime })
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.tick(to: r.at(11, 1), step: 60)
        let first = defaults.writes[key, default: 0]
        #expect(first >= 1, "the first dwell is saved")
        // Eleven hours of minute ticks on the test's clock, in no real time at all.
        r.sit(from: r.at(11, 2), to: r.at(22))
        #expect(defaults.writes[key, default: 0] == first)
        uptime += 599
        r.tick(to: r.at(22, 1), step: 60)
        #expect(defaults.writes[key, default: 0] == first)
        uptime += 1
        r.tick(to: r.at(22, 2), step: 60)
        #expect(defaults.writes[key, default: 0] == first + 1, "ten minutes on, the dwell is saved")
    }

    @Test func aDamagedSaveStartsWithNothingLearnedAndTheLimitsAsTheyAre() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.manager.adaptiveMax = 0.95
        r.manager.flushBandRefresh()
        r.manager.flushLearning()
        r.defaults.set(Data("{\"version\":1,\"color\":3}".utf8), forKey: "redlight.learning.model")
        r.manager = LearningRig.make(defaults: r.defaults, clock: r.clock, presence: r.presence, gamma: r.gamma, location: r.location)
        #expect(r.manager.learningEnabled)
        #expect(r.color.knownAnchors == 0)
        #expect(r.color.flags == 0...0.95 && r.manager.adaptiveMax == 0.95)
    }

    @Test func limitsAndAnOffsetChangedWhileTheAppWasNotRunningStand() {
        let r = rig()
        r.tick(to: r.at(17, 30), step: 0)
        r.manager.adaptiveMax = 0.8
        r.manager.flushBandRefresh()
        r.sit(from: r.at(17, 31), to: r.at(17, 50))
        let evening = r.color.state.buckets.enumerated().filter { $0.offset != day }.map(\.element.dwell)
        #expect(evening.contains { !$0.isEmpty })
        r.manager.flushLearning()
        // An older version, or `defaults write`, changes the plain keys and not the model.
        r.defaults.set(0.6, forKey: "redlight.adaptiveMax")
        r.defaults.set(-0.2, forKey: "redlight.adaptiveOffsetIntensity")
        r.manager = LearningRig.make(defaults: r.defaults, clock: r.clock, presence: r.presence, gamma: r.gamma, location: r.location)
        #expect(r.manager.adaptiveMax == 0.6 && abs(r.color.handBand.upperBound - 0.6) < 1e-12)
        #expect(abs(r.color.flat + 0.2) < 1e-12 && abs(r.manager.adaptiveIntensityAdjustment + 0.2) < 1e-12)
        #expect(r.color.state.buckets.enumerated().filter { $0.offset != day }.map(\.element.dwell) == evening,
                "the day's evidence is kept")

        // Unchanged keys change nothing.
        r.manager.flushLearning()
        let model = r.manager.learnedModel
        r.manager = LearningRig.make(defaults: r.defaults, clock: r.clock, presence: r.presence, gamma: r.gamma, location: r.location)
        #expect(r.manager.learnedModel == model)
    }

    @Test func aSaveFromANewerVersionIsNeverOverwritten() {
        let r = rig()
        let newer = Data("{\"version\":\(HabitModel.currentVersion + 1),\"future\":true}".utf8)
        r.defaults.set(newer, forKey: "redlight.learning.model")
        r.manager = LearningRig.make(defaults: r.defaults, clock: r.clock, presence: r.presence, gamma: r.gamma, location: r.location)
        #expect(r.manager.learningEnabled && r.color.knownAnchors == 0, "learning runs, from nothing")
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.manager.resetLearning()
        r.manager.setIntensityPushingBand(0.85)
        r.leave(until: r.at(day: 1, 4, 5))
        r.manager.flushLearning()
        #expect(r.defaults.data(forKey: "redlight.learning.model") == newer)
    }

    @Test func aDayThatEndedWhileTheAppWasNotRunningClosesAtLaunch() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        r.clock.date = r.at(day: 2, 10)
        r.relaunch()
        #expect(r.color.votes(at: day).count == 1)
        #expect(r.manager.learnedModel!.dayStart == r.at(day: 2, 4))
    }

    // MARK: The sun arc

    @Test func theDaysTintFollowsTheFlagsAndWhatWasLearned() throws {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        let cycle = SunCycle(now: r.clock.date, latitude: LearningRig.latitude, longitude: LearningRig.longitude,
                             calendar: LearningRig.calendar)
        let plain = try #require(r.manager.autoTintTrack(for: cycle.samples)).map(\.intensity)
        #expect(plain.count == cycle.samples.count)
        #expect(plain.max() == 1 && plain.min()! < 0.05)
        let before = r.manager.autoTintInputs

        // Learn the evening 15 % lower. Nothing else is known, so the rest of the day follows.
        r.tick(to: r.at(18, 10), step: 0)
        let beforeNudge = r.manager.intensity
        r.manager.setIntensityPushingBand(beforeNudge - 0.15)
        let delta = r.manager.intensity - beforeNudge
        r.sit(from: r.at(18, 13), to: r.at(18, 40))
        r.leave(until: r.at(day: 1, 4, 5))
        #expect(r.manager.autoTintInputs != before)
        let learned = try #require(r.manager.autoTintTrack(for: cycle.samples)).map(\.intensity)
        let evening = try #require(cycle.samples.firstIndex { !$0.rising && abs($0.elevation) < 3 })
        let noon = try #require(cycle.samples.indices.max { cycle.samples[$0].elevation < cycle.samples[$1].elevation })
        #expect(abs(learned[evening] - (plain[evening] + delta)) < 1e-6)
        #expect(abs(learned[noon] - (1 + delta)) < 1e-6)

        r.manager.adaptiveMax = 0.8
        r.manager.flushBandRefresh()
        #expect(try #require(r.manager.autoTintTrack(for: cycle.samples)).map(\.intensity).max()! <= 0.8 + 1e-12)
        r.manager.adaptiveEnabled = false
        #expect(r.manager.autoTintTrack(for: cycle.samples) == nil)
    }

    /// Auto's plain curve, both channels, at each sample of a cycle at the rig's place.
    private func plainCurve(
        _ cycle: SunCycle, intensity: ClosedRange<Double> = 0...1, whitepoint: ClosedRange<Double> = 0.625...1
    ) -> [AdaptiveMapping.Target] {
        let (lat, lon) = (LearningRig.latitude, LearningRig.longitude)
        return cycle.samples.map { sample in
            AdaptiveMapping.target(
                elevation: sample.elevation,
                minElevation: SolarCalculator.elevationAtSolarMidnight(at: sample.date, latitude: lat, longitude: lon),
                maxElevation: SolarCalculator.elevationAtSolarNoon(at: sample.date, latitude: lat, longitude: lon),
                rising: sample.rising, presets: Preset.defaults,
                intensityMin: intensity.lowerBound, intensityMax: intensity.upperBound,
                whitepointMin: whitepoint.lowerBound, whitepointMax: whitepoint.upperBound)
        }
    }

    @Test func withLearningOffTheDaysTrackIsThePlainCurvePlusTheOffsetInTheLimits() throws {
        let r = rig(learning: false)
        r.tick(to: r.at(18, 10), step: 0)
        r.manager.adaptiveMin = 0.1
        r.manager.adaptiveWpMax = 0.9
        r.manager.flushBandRefresh()
        r.manager.intensity = r.manager.intensity - 0.2              // Auto's own offsets
        r.manager.whitepoint = r.manager.whitepoint - 0.1
        let cycle = SunCycle(now: r.clock.date, latitude: LearningRig.latitude, longitude: LearningRig.longitude,
                             calendar: LearningRig.calendar)
        let track = try #require(r.manager.autoTintTrack(for: cycle.samples))
        let curve = plainCurve(cycle, intensity: 0.1...1, whitepoint: 0.625...0.9)
        let offsets = (intensity: r.manager.adaptiveIntensityAdjustment, whitepoint: r.manager.adaptiveWhitepointAdjustment)
        #expect(offsets.intensity < -0.1 && offsets.whitepoint < -0.05)
        let misses = track.indices.map { index in max(
            abs(track[index].intensity - min(1, max(0.1, curve[index].intensity + offsets.intensity))),
            abs(track[index].whitepoint - min(0.9, max(0.625, curve[index].whitepoint + offsets.whitepoint))))
        }
        #expect(misses.max()! < 1e-12)
        #expect(Set(track.map(\.whitepoint)).count > 2, "the white point moves through the day")
    }

    @Test func theDaysTrackFollowsWhatWasLearnedOnWhitePoint() throws {
        let r = rig()
        let cycle = SunCycle(now: r.at(11), latitude: LearningRig.latitude, longitude: LearningRig.longitude,
                             calendar: LearningRig.calendar)
        r.tick(to: r.at(11), step: 5)
        let before = r.manager.autoTintInputs
        r.manager.setWhitepointPushingBand(WhitepointScale.output(0.8))
        #expect(r.manager.autoTintInputs != before, "a nudge is a new track")
        let track = try #require(r.manager.autoTintTrack(for: cycle.samples))
        let noon = try #require(cycle.samples.indices.max { cycle.samples[$0].elevation < cycle.samples[$1].elevation })
        #expect(abs(track[noon].whitepoint - WhitepointScale.output(0.8)) < 1e-9)
        // Learning off keeps it as Auto's own offset: the same track.
        r.manager.setLearning(false)
        let off = try #require(r.manager.autoTintTrack(for: cycle.samples))
        #expect(abs(off[noon].whitepoint - WhitepointScale.output(0.8)) < 1e-9)
    }

    @Test func theArcsLineDimsWithWhitePointAndStaysVisible() {
        for palette in [EmberPalette.dark, .darkIncreased, .light, .lightIncreased] {
            let scheme: ColorScheme = palette.isDark ? .dark : .light
            let night = palette.wash.mixed(palette.nightAlpha, over: palette.background)
            for intensity in stride(from: 0.0, through: 1.0, by: 0.05) {
                let tint = EmberTint.rgb(intensity: intensity, scheme: scheme)
                func line(_ level: Double) -> EmberRGB {
                    palette.arcLineRGB(dimmed: palette.sliderFillRGB(.level(level), accent: tint), tint: tint)
                }
                // At the top of White point the line is the tint itself, where the tint shows.
                // In light the palest tints are as pale as the panel: there it is deepened.
                let tintShows = [palette.background, night].allSatisfy {
                    EmberContrast.wcag(tint, $0) >= EmberPalette.arcLineContrast
                }
                if tintShows || palette.isDark {
                    #expect(line(1) == tint, "at the top of White point the line is the tint itself")
                } else {
                    #expect(line(1) != tint && EmberContrast.wcag(line(1), palette.background) >= EmberPalette.arcLineContrast - 1e-9)
                }
                for level in stride(from: 0.0, through: 1.0, by: 0.1) {
                    for surface in [palette.background, night] {
                        let floor = min(EmberPalette.arcLineContrast, EmberContrast.wcag(tint, surface))
                        #expect(EmberContrast.wcag(line(level), surface) >= floor - 1e-9,
                                "\(palette.isDark) \(intensity) \(level)")
                    }
                    #expect(EmberContrast.luminance(line(level)) <= EmberContrast.luminance(tint) + 1e-9 || !palette.isDark,
                            "dimmed, never brighter")
                }
            }
            // A tint that stands well clear of the floor shows the dimming.
            let mid = EmberTint.rgb(intensity: 0.7, scheme: scheme)
            let dimmed = palette.arcLineRGB(dimmed: palette.sliderFillRGB(.level(0.3), accent: mid), tint: mid)
            #expect(dimmed != mid, "\(palette.isDark)")
        }
    }

    @Test func theArcTakesAColourForEachSampleOrNone() {
        let cycle = SunCycle(now: LearningRig.start, latitude: 35, longitude: 0, calendar: LearningRig.calendar)
        let palette = EmberPalette.dark
        #expect(SunArcView.tintGradients(nil, samples: cycle.samples, palette: palette) == nil)
        #expect(SunArcView.tintGradients([.init(intensity: 1, whitepoint: 1), .init(intensity: 0.5, whitepoint: 1)],
                                         samples: cycle.samples, palette: palette) == nil)
        let track = cycle.samples.map {
            DisplayManager.AutoTint(intensity: $0.elevation > 0 ? 1.0 : 0.0, whitepoint: $0.elevation > 0 ? 1 : 0.625)
        }
        let gradients = SunArcView.tintGradients(track, samples: cycle.samples, palette: palette)
        #expect(gradients?.line.stops.count == cycle.samples.count)
        #expect(gradients?.area.stops.count == cycle.samples.count)
        let locations = gradients?.line.stops.map(\.location) ?? []
        #expect(locations == locations.sorted() && locations.first == 0 && locations.last == 1)
        // By day the line is the tint itself; at night, White point's half dims it.
        let day = try! #require(cycle.samples.firstIndex { $0.elevation > 30 })
        let night = try! #require(cycle.samples.firstIndex { $0.elevation < -30 })
        let white = EmberTint.rgb(intensity: 1, scheme: .dark), red = EmberTint.rgb(intensity: 0, scheme: .dark)
        #expect(gradients?.line.stops[day].color == white.color)
        let dimmedRed = palette.arcLineRGB(dimmed: palette.sliderFillRGB(.level(0.5), accent: red), tint: red)
        #expect(gradients?.line.stops[night].color == dimmedRed.color)
        #expect(gradients?.area.stops[night].color == palette.dayArea(accent: palette.sliderFillRGB(.level(0.5), accent: red)))
        // Light with Increase Contrast keeps its ink line; only the area takes the tint and dims.
        let ink = EmberPalette.lightIncreased
        let inked = SunArcView.tintGradients(track, samples: cycle.samples, palette: ink)
        let lightRed = EmberTint.rgb(intensity: 0, scheme: .light)
        #expect(inked?.line.stops.allSatisfy { $0.color == ink.arcLine(accent: lightRed) } == true)
        #expect(inked?.area.stops[night].color == ink.dayArea(accent: ink.sliderFillRGB(.level(0.5), accent: lightRed)))
        #expect(inked?.area.stops[night].color != ink.dayArea(accent: lightRed))
    }

    @Test func theArcIsWorkedOutOnlyWhenWhatItShowsChanges() {
        let cycle = SunCycle(now: LearningRig.start, latitude: 35, longitude: 0, calendar: LearningRig.calendar)
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        let cache = SunArcCache()
        var tracks = 0
        func gradients(_ palette: EmberPalette) -> SunArcView.TintGradients? {
            cache.gradients(for: cycle, inputs: r.manager.autoTintInputs, palette: palette) {
                tracks += 1
                return r.manager.autoTintTrack(for: cycle.samples)
            }
        }
        let first = gradients(.dark)
        #expect(first != nil && tracks == 1)
        // A colour temp tick or a fade: nothing the arc shows has changed.
        r.tick(to: r.at(11, 1), step: 0)
        #expect(gradients(.dark) == first && tracks == 1)
        // Another appearance: new colours for the same track.
        #expect(gradients(.light) != first && tracks == 1)
        // White point's limit: a new track.
        r.manager.adaptiveWpMin = 0.5
        r.manager.flushBandRefresh()
        _ = gradients(.light)
        #expect(tracks == 2)
    }


    // MARK: Reset keeps a backup

    @Test func aResetKeepsWhatItForgetsAndRestoreBringsItBack() throws {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setIntensityPushingBand(0.9)
        r.manager.setWhitepointPushingBand(WhitepointScale.output(0.8))
        let before = try #require(r.manager.learnedModel)
        #expect(r.manager.learningBackupCount == 0)

        r.manager.resetLearning()
        #expect(r.color.knownAnchors == 0 && r.white.knownAnchors == 0, "both sliders together")
        #expect(r.manager.learningBackupCount == 1)

        #expect(r.manager.restoreLearning())
        #expect(r.color.state.own == before.color.state.own)
        #expect(r.white.state.own == before.whitepoint.state.own)
        r.tick(to: r.at(11, 1), step: 0)
        #expect(abs(r.manager.intensity - 0.9) < 1e-9)
        // Nothing was learned since the reset, so nothing new was kept: the backup is used up.
        #expect(r.manager.learningBackupCount == 0)
        #expect(!r.manager.restoreLearning())
    }

    @Test func restoringOverNewLearningKeepsTheNewLearningToo() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setIntensityPushingBand(0.9)
        r.manager.resetLearning()
        r.clock.date = r.at(11, 10)
        r.manager.setIntensityPushingBand(0.7)                  // learned again after the reset
        #expect(r.manager.restoreLearning())
        #expect(abs(r.color.offset(of: day) + 0.1) < 1e-9)
        #expect(r.manager.learningBackupCount == 1)
        #expect(r.manager.restoreLearning(), "running it again undoes it")
        #expect(abs(r.color.offset(of: day) + 0.3) < 1e-9)
    }

    @Test func onlyTheLastFiveResetsAreKeptAndTheySurviveARelaunch() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        for index in 0..<7 {
            r.clock.date = r.at(11, index * 5)
            r.manager.setIntensityPushingBand(0.9 - Double(index) * 0.05)
            r.manager.resetLearning()
        }
        #expect(r.manager.learningBackupCount == DisplayManager.learningBackupLimit)
        r.relaunch()
        #expect(r.manager.learningBackupCount == DisplayManager.learningBackupLimit)
        #expect(r.manager.restoreLearning())
        #expect(abs(r.color.offset(of: day) + 0.4) < 1e-9, "the newest comes back first")
    }

    @Test func resetBesideASliderKeepsABackupToo() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setIntensityPushingBand(0.9)
        r.manager.resetIntensity()
        #expect(r.manager.learningBackupCount == 1)
        #expect(r.manager.restoreLearning())
        #expect(r.color.isKnown(day))
    }

    // MARK: After the fix review

    @Test func savingAPresetInAutoChangesOnlyItsOwnPartOfTheDay() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.intensity = 0.9                               // Auto's offset −10 %, midday known
        r.manager.resetLearning()                               // nothing known, flat −10 % kept
        #expect(abs(r.color.flat + 0.1) < 1e-9 && r.color.knownAnchors == 0)
        r.tick(to: r.at(18, 10), step: 0)
        let showing = r.manager.intensity
        r.manager.saveToPreset(2)
        #expect(abs(r.manager.intensity - showing) < 1e-9, "the screen stays where it was saved")
        #expect(abs(r.color.flat + 0.1) < 1e-9, "the rest of the day keeps its offset")
        r.tick(to: r.at(day: 1, 11), step: 0)
        #expect(abs(r.manager.intensity - 0.9) < 1e-9, "midday is untouched by a Sunset preset")
    }

    @Test func aPushPastAFlagIsSavedWithTheFlagsAtOnce() throws {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.adaptiveMax = 0.8
        r.manager.flushBandRefresh()
        r.clock.date = r.at(11, 5)
        r.manager.setIntensityPushingBand(0.95)                 // past the hand band: a hand move
        let data = try #require(r.defaults.data(forKey: "redlight.learning.model"))
        let saved = try #require(HabitModel.decode(data))
        #expect(abs(saved.color.flags.upperBound - 0.95) < 1e-12, "not left for a timer to write")
    }

    @Test func aClockChangeKeepsTheHalfHourThatCanStillBeTakenBack() {
        let base = LearnedAutoFixtures.baseline(Preset.defaults.map(\.intensity), 0...1)
        var channel = HabitModel.Channel(band: 0...1, base: base)
        let noon = SolarCurve.Phase(from: .day, to: .day, fraction: 0)
        let warm = SolarCurve.Phase(from: .day, to: .eveningWarm, fraction: 0.5)
        channel.write(0.9, slider: true, phase: noon, at: 0, curve: { _ in 1 }, anchors: { _ in base })
        for time in stride(from: 1_000.0, to: 1_600, by: 100) {
            channel.record(phase: warm, seconds: 100, at: time, curve: 0.9)
        }
        let warmIndex = SolarCurve.Anchor.eveningWarm.rawValue
        #expect(channel.state.buckets[warmIndex].total == 300)          // half of each tick
        channel.clockWasSet(at: 1_450)                                  // a small sync, back by 50 s
        #expect(channel.state.buckets[warmIndex].recent.count == 5, "only the sample after the new time is let go")
        #expect(channel.state.buckets[warmIndex].total == 300, "and it stays counted")
    }

    // MARK: In words

    @Test func theSummarySaysWhereTheFlagsWentAndWhatDiffersMost() {
        let base = LearnedAutoFixtures.baseline(Preset.defaults.map(\.intensity), 0...1)
        var color = HabitModel.Channel(band: 0...1, base: base)
        let sunset = SolarCurve.Phase(from: .eveningSunset, to: .eveningSunset, fraction: 0)
        color.write(0.38, slider: true, phase: sunset, at: 0, curve: { _ in 0.5 }, anchors: { _ in base })
        let model = HabitModel(color: color, whitepoint: HabitModel.Channel(band: 0.5...1, base: base))
        #expect(model.sentences() == ["Color temp is about 12% redder around sunset."])
        #expect(HabitModel(color: HabitModel.Channel(band: 0...1, base: base),
                           whitepoint: HabitModel.Channel(band: 0.5...1, base: base)).sentences().isEmpty)
    }

    /// A channel with its state set directly, as a save could hold it.
    private func channel(
        band: ClosedRange<Double>, _ change: (inout HabitModel.Channel.State) -> Void
    ) throws -> HabitModel.Channel {
        let base = LearnedAutoFixtures.baseline(Preset.defaults.map(\.intensity), band)
        var state = HabitModel.Channel(band: band, base: base).state
        change(&state)
        return try JSONDecoder().decode(HabitModel.Channel.self, from: JSONEncoder().encode(["state": state]))
    }

    // MARK: The rules at their edges

    @Test func eachRuleHoldsAtItsEdge() throws {
        #expect(HabitModel.Rules.gap == SliderCore.limitGap, "a learned flag keeps the gap a dragged one does")
        let noon = SolarCurve.Phase(from: .day, to: .day, fraction: 0)
        let night = SolarCurve.Anchor.eveningNight.rawValue
        func sat(_ value: Double, _ seconds: Double, hand: Bool = false) -> HabitModel.Bucket {
            var bucket = HabitModel.Bucket()
            bucket.dwell = [.init(value: value, seconds: seconds)]
            bucket.hand = hand
            return bucket
        }
        func closed(
            band: ClosedRange<Double> = 0...1, offer: Double = .infinity,
            _ change: (inout HabitModel.Channel.State) -> Void
        ) throws -> HabitModel.Channel {
            var channel = try channel(band: band, change)
            channel.close(offer: Array(repeating: offer, count: HabitModel.Channel.anchorCount))
            return channel
        }
        let accepted = HabitModel.Vote(value: 0, weight: 1)

        // A vote within 2 % of the morning is acceptance of it; past that, a correction.
        var c = try closed { $0.own[day] = 0; $0.buckets[day] = sat(-0.02, 600, hand: true) }
        #expect(c.offset(of: day) == 0 && c.votes(at: day) == [accepted])
        c = try closed { $0.own[day] = 0; $0.buckets[day] = sat(-0.0205, 600, hand: true) }
        #expect(c.offset(of: day) == -0.0205 && c.votes(at: day) == [.init(value: -0.0205, weight: 3)])

        // Where there is history, a correction of up to 8 % is taken at once; more, a vote.
        c = try closed { $0.own[day] = 0; $0.rings[day] = HabitModel.Channel.standing; $0.buckets[day] = sat(-0.08, 600, hand: true) }
        #expect(c.offset(of: day) == -0.08 && c.votes(at: day).allSatisfy { $0.value == -0.08 })
        c = try closed { $0.own[day] = 0; $0.rings[day] = HabitModel.Channel.standing; $0.buckets[day] = sat(-0.0805, 600, hand: true) }
        #expect(c.offset(of: day) == 0 && c.votes(at: day).count == 5, "four days at 0 outweigh one correction")

        // Enough time for a vote: ten minutes, or half of what the stretch offered.
        for (seconds, offer, votes) in [(599.9, Double.infinity, false), (600, .infinity, true), (499.9, 1000, false), (500, 1000, true)] {
            c = try closed(offer: offer) { $0.flat = -0.1; $0.start = Array(repeating: -0.1, count: 12); $0.buckets[day] = sat(-0.1, seconds) }
            #expect(c.isKnown(day) == votes, "\(seconds) s of \(offer)")
        }

        // Pinned at a learned flag, beyond which any offset looks the same: an open anchor
        // learns nothing there, though the hand band is wider.
        for (flat, pinned) in [(-0.05, true), (-0.15, false)] {
            var channel = try channel(band: 0...1) { $0.upper = 0.9; $0.flat = flat }
            channel.record(phase: noon, seconds: 60, at: 0, curve: 1)
            #expect((channel.state.buckets[day].total == 0) == pinned, "flat \(flat)")
        }

        // A flag follows its anchor only past 0.5 %.
        for (own, follows) in [(-0.0055, true), (-0.0045, false)] {
            c = try closed { $0.own[day] = own; $0.rings[day] = Array(repeating: .init(value: own, weight: 1), count: 4) }
            #expect((c.flags.upperBound < 1) == follows, "Day at \(own)")
        }
        // Nor where it would clip a known anchor by more than 1 %, on either side.
        for (below, follows) in [(-0.0605, false), (-0.0595, true)] {
            c = try closed {
                $0.own[late] = 0.2
                $0.rings[late] = Array(repeating: .init(value: 0.2, weight: 1), count: 4)
                $0.own[night] = below
            }
            #expect((c.flags.lowerBound == 0.2) == follows, "evening night at \(below)")
        }
        // Nor closer than the gap to the other flag.
        for (own, follows) in [(-0.0245, true), (-0.0255, false)] {
            c = try closed(band: 0.4...0.5) {
                $0.own[day] = own
                $0.rings[day] = Array(repeating: .init(value: own, weight: 1), count: 4)
                $0.own[late] = 0.025
                $0.rings[late] = Array(repeating: .init(value: 0.025, weight: 1), count: 4)
            }
            #expect(c.hasLearnedFlags == follows, "Day at \(own)")
        }
    }

    @Test func eachSliderSaysWhatItLearnedInOneSentenceAndWhitePointIsNeverLeftOut() throws {
        let sunset = SolarCurve.Anchor.eveningSunset.rawValue, night = SolarCurve.Anchor.eveningNight.rawValue
        let color = try channel(band: 0...1) { $0.lower = 0.2; $0.own[sunset] = -0.12 }
        let white = try channel(band: 0.5...1) { $0.lower = 0.6; $0.own[night] = -0.1 }
        #expect(HabitModel(color: color, whitepoint: white).sentences() == [
            "Color temp runs from 20% to 100% and is about 12% redder around sunset.",
            "White point runs from 60% to 100% and is about 10% dimmer after dark.",
        ])
        // Either half alone.
        let flags = try channel(band: 0...1) { $0.upper = 0.9 }
        let brighter = try channel(band: 0.5...1) { $0.own[night] = 0.05 }
        #expect(HabitModel(color: flags, whitepoint: brighter).sentences() == [
            "Color temp runs from 0% to 90%.", "White point is about 5% brighter after dark.",
        ])
        // Less than 3 % is not worth a sentence.
        let small = try channel(band: 0...1) { $0.own[sunset] = -0.0299 }
        let just = try channel(band: 0.5...1) { $0.own[night] = -0.0301 }
        #expect(HabitModel(color: small, whitepoint: just).sentences() == ["White point is about 3% dimmer after dark."])
    }

    @Test func aFixedSliderSaysNothingAndIsNotCounted() throws {
        let sunset = SolarCurve.Anchor.eveningSunset.rawValue
        let fixed = try channel(band: 0.7...0.7) { $0.own[sunset] = -0.12 }
        #expect(HabitModel(color: fixed, whitepoint: try channel(band: 0.5...1) { _ in }).sentences().isEmpty)

        let r = rig()
        r.tick(to: r.at(18, 10), step: 0)
        r.manager.setIntensityPushingBand(r.manager.intensity - 0.15)
        #expect(r.manager.learnedAnchorCount > 0)
        r.manager.adaptiveMin = 0.7
        r.manager.adaptiveMax = 0.7
        r.manager.flushBandRefresh()
        #expect(r.color.knownAnchors > 0, "kept for when the slider is not Fixed")
        #expect(r.manager.learnedAnchorCount == 0 && r.manager.learningSummary.isEmpty)
    }

    @Test func aLimitSetByHandIsNotSomethingLearned() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.adaptiveMax = 0.8
        r.manager.flushBandRefresh()
        #expect(r.color.isKnown(day), "the limit stands at its anchor")
        #expect(r.manager.learnedAnchorCount == 0 && r.manager.learningSummary.isEmpty)
        // Dragged back: the slider is at its defaults again, with nothing to reset.
        r.manager.adaptiveMax = 1
        r.manager.flushBandRefresh()
        #expect(r.manager.intensityIsDefault)
        // Sat through for a day, it is: Auto now knows that part of the day.
        r.sit(from: r.at(11, 5), to: r.at(11, 30))
        r.leave(until: r.at(day: 1, 4, 5))
        #expect(r.manager.learnedAnchorCount == 1)
    }

    @Test func theDayAndLateAreDescribedUntilTheirFlagFollows() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        #expect(r.manager.learningSummary == ["Color temp is about 10% redder in the day."])
        let s = rig()
        learnMaxFlagOfNinety(s)
        #expect(s.manager.learningSummary == ["Color temp runs from 0% to 90%."], "the flag says it now")
    }

    @Test func theStatusSaysLearnedAndAdjustedWhenBothApply() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        // White point: a nudge, then Reset learning: Auto's own offset alone, nothing learned.
        r.manager.setWhitepointPushingBand(WhitepointScale.output(0.8))
        r.manager.resetLearning()
        // Colour temp: learned at midday.
        r.manager.setIntensityPushingBand(0.9)
        r.tick(to: r.at(11, 1), step: 0)
        #expect(r.manager.adaptiveStatusText.contains(" · learned · adjusted"), "\(r.manager.adaptiveStatusText)")
    }

    @Test func theSlidersResetFollowsWhatWasLearned() {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.clock.date = r.at(11, 5)
        r.manager.setIntensityPushingBand(1)                 // a second nudge, back to the curve
        #expect(r.color.isKnown(day) && r.color.flat == 0 && !r.manager.intensityIsDefault)
        final class Flag: @unchecked Sendable { var raised = false }
        let changed = Flag()
        withObservationTracking { _ = r.manager.intensityIsDefault } onChange: { changed.raised = true }
        // Nothing on screen moves, and nothing the row reads but what was learned.
        r.manager.resetLearning()
        #expect(r.manager.intensityIsDefault)
        #expect(changed.raised, "the row is told")
    }

    @Test func statusAndShortcutsSayWhatWasLearnedOnBothSliders() throws {
        let r = rig()
        r.tick(to: r.at(11), step: 5)
        r.manager.setIntensityPushingBand(0.9)
        r.manager.setWhitepointPushingBand(WhitepointScale.output(0.8))
        let handler = CommandHandler(manager: r.manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) },
            setLogin: { _ in }, update: {}, quit: {}, version: { "Test" }))
        let learning = try #require(handler.snapshot().learning)
        #expect(learning.summary == ["Color temp is about 10% redder in the day.",
                                     "White point is about 20% dimmer in the day."])
        #expect(learning.colorAnchors == 1 && learning.whitepointAnchors == 1 && learning.anchors == 2)
        let status = handler.snapshot()
        for text in [RedlightCLI.describe(status), redlightStatusText(status)] {
            #expect(text.contains("Learned: Color temp is about 10% redder in the day. White point is about 20% dimmer in the day."), "\(text)")
        }
    }

    @Test func aClockSetBackEndsTheGesture() {
        let base = LearnedAutoFixtures.baseline(Preset.defaults.map(\.intensity), 0...1)
        var channel = HabitModel.Channel(band: 0...1, base: base)
        let noon = SolarCurve.Phase(from: .day, to: .day, fraction: 0)
        func write(_ value: Double, at time: TimeInterval) {
            channel.write(value, slider: true, phase: noon, at: time, curve: { _ in 1 }, anchors: { _ in base })
        }
        write(0.9, at: 10_000)
        channel.record(phase: noon, seconds: 600, at: 10_200, curve: 1)
        #expect(channel.state.buckets[0].total == 600)
        write(0.8, at: 4_000)                                   // an hour and a half "earlier"
        #expect(channel.state.buckets[0].total == 0, "a new nudge, which restarts the count")
        #expect(abs(channel.flat + 0.2) < 1e-12)
        write(0.85, at: 4_060)                                  // and its own gesture goes on from there
        #expect(abs(channel.flat + 0.15) < 1e-12)
    }

    @Test func aClockSetBackDoesNotHoldBackDwellOrTakeBackTooMuch() {
        let r = rig()
        r.tick(to: r.at(11), step: 0)
        r.manager.setIntensityPushingBand(0.9)              // midday known; the rest follows
        r.sit(from: r.at(18), to: r.at(18, 30))             // the evening sat through
        let evening = r.color.state.buckets.map(\.total)
        #expect(evening.enumerated().contains { $0.offset != day && $0.element > 0 })
        r.tick(to: r.at(18, 31), step: 0)
        r.manager.setIntensityPushingBand(r.manager.intensity - 0.05)
        let lead = leadAnchor(at: r.at(18, 31))
        let afterNudge = r.color.state.buckets.map(\.total)

        // The clock goes back to 12:00. The evening is now "in the future": a nudge at midday
        // must not take it back as if it were the half hour before.
        r.clock.date = r.at(12)
        r.manager.handleClockChange()
        r.tick(to: r.at(12), step: 0)
        r.manager.setIntensityPushingBand(0.85)
        for index in afterNudge.indices where index != day && index != lead {
            #expect(r.color.state.buckets[index].total == afterNudge[index], "anchor \(index)")
        }

        // Back to 10:00: the midday nudge's settle, at 12:02, does not hold back dwell.
        r.clock.date = r.at(10)
        r.manager.handleClockChange()
        r.tick(to: r.at(10), step: 0)
        r.tick(to: r.at(10, 3), step: 0)
        r.tick(to: r.at(10, 4), step: 60)
        #expect(r.color.state.buckets[day].total == 60)
    }

    @Test func theLearningDayRunsFromFourToFourOnTheLocalClock() {
        let calendar = LearningRig.calendar
        let start = LearningRig.start
        #expect(HabitDay.start(containing: start, calendar: calendar) == start)
        #expect(HabitDay.start(containing: start.addingTimeInterval(-1), calendar: calendar) == start.addingTimeInterval(-86_400))
        #expect(HabitDay.start(containing: start.addingTimeInterval(86_399), calendar: calendar) == start)
        #expect(HabitDay.end(of: start, calendar: calendar) == start.addingTimeInterval(86_400))
        // A day begun on New York's clock and ended on Los Angeles's runs to the 04:00 after
        // the one three hours on; eastward the day is 21 hours and stands.
        func zoned(_ identifier: String) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: identifier)!
            return calendar
        }
        let newYork = HabitDay.start(containing: start, calendar: zoned("America/New_York"))
        #expect(HabitDay.end(of: newYork, calendar: zoned("America/Los_Angeles")).timeIntervalSince(newYork) == 27 * 3600)
        let losAngeles = HabitDay.start(containing: start, calendar: zoned("America/Los_Angeles"))
        #expect(HabitDay.end(of: losAngeles, calendar: zoned("America/New_York")).timeIntervalSince(losAngeles) == 21 * 3600)
        #expect(HabitDay.start(containing: start.addingTimeInterval(-0.5), calendar: calendar) == start.addingTimeInterval(-86_400))
        let offer = HabitDay.offer(from: start, to: start.addingTimeInterval(86_400), latitude: 35, longitude: 0)
        #expect(abs(offer.reduce(0, +) - 86_400) < 1e-6)
        #expect(offer.allSatisfy { $0 > 0 })
    }

    @Test func aMoveEastShortensTheDayAndNeverMakesItTwo() {
        func zoned(_ identifier: String) -> Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: identifier)!
            return calendar
        }
        // 04:00 in New York is 08:00 UTC; the next 04:00 in Paris is 03:00 UTC the day after.
        let newYork = HabitDay.start(containing: LearningRig.start, calendar: zoned("America/New_York"))
        #expect(HabitDay.end(of: newYork, calendar: zoned("Europe/Paris")).timeIntervalSince(newYork) == 19 * 3600)
        // Every move, east or west, gives a day of 12 to 36 hours.
        let zones = ["Pacific/Honolulu", "America/Los_Angeles", "America/New_York", "Europe/London",
                     "Europe/Paris", "Asia/Kolkata", "Asia/Tokyo", "Australia/Sydney", "Pacific/Auckland"]
        for from in zones {
            let start = HabitDay.start(containing: LearningRig.start, calendar: zoned(from))
            for to in zones {
                let length = HabitDay.end(of: start, calendar: zoned(to)).timeIntervalSince(start)
                #expect(length >= 12 * 3600 && length <= 36 * 3600, "\(from) to \(to): \(length / 3600) h")
            }
        }
    }
}

// MARK: - The reference's users, through the app

/// The reference's scripted users driven through a real `DisplayManager`: the slider writes,
/// the 5 s tick's dwell and the deferred close, on the app's own sun and curve. After every
/// close the learned state must be the reference's, and the user must have made the same
/// number of corrections. This is what checks the glue: units, the flags' mirror, the hand
/// band and the split of one write across the slider setter and `didSet`.
/// Serialized for the same reason as the pause between days: several of these at once would
/// keep the main queue busy without a gap.
@MainActor @Suite(.serialized) struct LearnedAutoUserTests {
    let defaultsRegistry = TestDefaultsRegistry()
    private static let step: TimeInterval = 300
    /// The app's sun and the reference's differ in the ninth place.
    private static let tolerance = 1e-6

    private struct Reference {
        /// Corrections made each day.
        var writes: [Int] = []
        var states: [[String: Any]] = []
    }

    private func reference(_ name: String) throws -> Reference {
        let traces = try #require(try LearnedAutoFixtures.json("traces") as? [[String: Any]])
        let trace = try #require(traces.first { $0["name"] as? String == name }, "no trace \(name)")
        var reference = Reference()
        var today = 0
        for event in try #require(trace["events"] as? [[Any]]) {
            if event[0] as? String == "w" { today += 1 }
            if event[0] as? String == "c", let state = event[2] as? [String: Any] {
                reference.states.append(state)
                reference.writes.append(today)
                today = 0
            }
        }
        return reference
    }

    private enum Channel { case color, white }

    /// A limit set by hand before the day's first tick, in slider fractions.
    private enum Drag { case min(Double), max(Double) }

    /// `want` is what the owner wants shown, in slider fractions, given Auto's plain value
    /// (also a slider fraction). `guest` sets midday on the days it names and stays. `drag`
    /// sets a limit by hand at 04:00 of the days it names, as the reference does before the
    /// day's first tick. The app clears the day's evidence at the end that is set, which
    /// the reference does not; at 04:00 the day has none yet, so the two agree.
    private func run(
        _ name: String, _ channel: Channel, guest: [Int: Double] = [:], drag: [Int: Drag] = [:],
        want: (Double) -> Double
    ) async throws {
        let reference = try reference(name)
        let r = LearningRig(defaults: defaultsRegistry.makeDefaults(prefix: "LearnedAutoUsers"))
        let n = LearnedAutoFixtures.number
        func shown() -> Double {
            channel == .color ? r.manager.intensity : WhitepointScale.shown(r.manager.whitepoint)
        }
        func set(_ value: Double) {
            if channel == .color { r.manager.setIntensityPushingBand(value) }
            else { r.manager.setWhitepointPushingBand(WhitepointScale.output(value)) }
        }
        let untouched = channel == .color ? r.white : r.color
        var writes = 0
        for day in 0..<reference.states.count {
            if let drag = drag[day] {
                r.clock.date = LearningRig.start.addingTimeInterval(Double(day) * 86_400)
                switch (channel, drag) {
                case (.color, .min(let value)): r.manager.adaptiveMin = value
                case (.color, .max(let value)): r.manager.adaptiveMax = value
                case (.white, .min(let value)): r.manager.adaptiveWpMin = WhitepointScale.output(value)
                case (.white, .max(let value)): r.manager.adaptiveWpMax = WhitepointScale.output(value)
                }
                r.manager.flushBandRefresh()
            }
            var today = 0
            // Weeks of ticks in one go would hold the main queue for seconds, and tests that
            // wait on a main run-loop timer would miss their deadlines. A yield is not enough:
            // the queue has to empty for the run loop to fire its timers, so stop for a moment.
            try await Task.sleep(for: .milliseconds(2))
            var wrong: TimeInterval = 0
            var guestOn = false
            for index in 0..<Int(86_400 / Self.step) {
                let date = LearningRig.start.addingTimeInterval(Double(day) * 86_400 + Double(index) * Self.step)
                let minute = (4 * 60 + index * Int(Self.step) / 60) % 1440
                let attending = (9 * 60..<12 * 60).contains(minute) || (15 * 60..<22 * 60).contains(minute)
                guard attending else {
                    wrong = 0
                    r.tick(to: date, step: Self.step, attended: false)
                    continue
                }
                r.clock.date = date
                if r.presence.isAway { r.presence.isAway = false }
                r.manager.applyAdaptive()
                if let value = guest[day], minute >= 10 * 60 {
                    if !guestOn { set(value); guestOn = true; today += 1 }
                    r.manager.learningTick(elapsed: Self.step)
                    continue
                }
                let plain = r.plain()
                let wanted = want(channel == .color ? plain.intensity : WhitepointScale.shown(plain.whitepoint))
                if abs(shown() - wanted) > 0.03 + 1e-10 { wrong += Self.step } else { wrong = 0 }
                if wrong >= 600 {
                    set(wanted)
                    today += 1
                    wrong = 0
                }
                r.manager.learningTick(elapsed: Self.step)
            }
            writes += today
            // 04:00 of the next day, with nobody there: the day closes.
            r.tick(to: LearningRig.start.addingTimeInterval(Double(day + 1) * 86_400), step: Self.step, attended: false)
            let learned = channel == .color ? r.color : r.white
            let state = reference.states[day]
            let label = "\(name) close \(day)"
            // The flags, the hand band and the day's corrections: what the user lives with.
            #expect(abs(learned.flags.lowerBound - n(state["lo"])) < Self.tolerance, "\(label): min flag")
            #expect(abs(learned.flags.upperBound - n(state["hi"])) < Self.tolerance, "\(label): max flag")
            let hand = try #require(state["ref"] as? [NSNumber]).map(\.doubleValue)
            #expect(abs(learned.handBand.lowerBound - hand[0]) < Self.tolerance
                    && abs(learned.handBand.upperBound - hand[1]) < Self.tolerance, "\(label): hand band")
            #expect(today == reference.writes[day], "\(label): corrections that day")
            // The flags the rest of the app reads are the model's.
            let flags = channel == .color
                ? r.manager.adaptiveMin...r.manager.adaptiveMax
                : WhitepointScale.shown(r.manager.adaptiveWpMin)...WhitepointScale.shown(r.manager.adaptiveWpMax)
            #expect(abs(flags.lowerBound - learned.flags.lowerBound) < 1e-9 && abs(flags.upperBound - learned.flags.upperBound) < 1e-9)
            // The other slider, sat through as Auto has it, learns only that: Auto's own curve.
            let other = channel == .color ? r.white : r.color
            #expect(other.state.own.allSatisfy { $0 == nil || $0 == 0 } && other.flat == 0, "\(label): the other slider")
            #expect(other.flags == untouched.flags && other.handBand == untouched.handBand, "\(label): the other slider")
            // Everything learned.
            for (anchor, value) in try #require(state["own"] as? [Any]).enumerated() {
                #expect(learned.isKnown(anchor) == !(value is NSNull), "\(label): anchor \(anchor) known")
                if !(value is NSNull) {
                    #expect(abs(learned.offset(of: anchor) - n(value)) < Self.tolerance, "\(label): anchor \(anchor)")
                }
            }
            #expect(abs(learned.flat - n(state["flat"])) < Self.tolerance, "\(label): flat")
            let counts = try #require(state["n"] as? [NSNumber]).map(\.intValue)
            #expect((0..<12).map { learned.votes(at: $0).count } == counts, "\(label): votes")
            if let rings = state["rings"] as? [[[NSNumber]]] {
                for (anchor, ring) in rings.enumerated() where learned.votes(at: anchor).count == ring.count {
                    for (vote, want) in zip(learned.votes(at: anchor), ring) {
                        #expect(abs(vote.value - want[0].doubleValue) < Self.tolerance && vote.weight == want[1].doubleValue,
                                "\(label): a vote at \(anchor)")
                    }
                }
            }
        }
        #expect(writes == reference.writes.reduce(0, +), "\(name): corrections")
    }

    @Test func aFlatPreferenceTakesOneNudge() async throws {
        try await run("smallguest/plain95", .color, guest: [21: 0.95, 35: 0.95]) { $0 }
    }

    @Test func autoScaledToNinetyMovesTheMaxFlag() async throws {
        try await run("band/scale90", .color) { 0.9 * $0 }
    }

    @Test func autoScaledIntoThirtyToNinetyMovesBothFlags() async throws {
        try await run("band/band", .color) { 0.3 + 0.6 * $0 }
    }

    @Test func aGuestWhoPushesPastTheLearnedFlagIsGoneAtTheNextClose() async throws {
        try await run("band/guest_push", .color, guest: [21: 1.0, 35: 1.0]) { 0.9 * $0 }
    }

    @Test func aSmallGuestIsKeptUntilTheOwnerCorrects() async throws {
        try await run("smallguest/s90down85", .color, guest: [21: 0.85, 35: 0.85]) { 0.9 * $0 }
    }

    @Test func whitePointWantedBrighterMovesItsMinFlag() async throws {
        try await run("white/bright", .white) { 0.8 + 0.2 * ($0 - 0.5) / 0.5 }
    }

    @Test func whitePointWantedDarkerThanTheDefaultFloorPushesTheHandBand() async throws {
        try await run("white/dark", .white) { 0.3 + 0.7 * ($0 - 0.5) / 0.5 }
    }

    @Test func aMaxFlagDraggedByHandStandsAndTheCurveScales() async throws {
        try await run("band/flagdrag", .color, drag: [10: .max(0.9)]) { 0.9 * $0 }
    }

    @Test func whitePointFlagsDraggedByHandAtBothEnds() async throws {
        try await run("white/flagdrag", .white, drag: [6: .min(0.6), 20: .max(0.9)]) { 0.6 + 0.4 * ($0 - 0.5) / 0.5 }
    }
}
