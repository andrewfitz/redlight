import Foundation
import Testing
@testable import Redlight

private func calendar(_ identifier: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Suite struct BedtimeTests {
    @Test func parsesStrictTwentyFourHourTimes() throws {
        let valid: [(String, Int, Int)] = [
            ("22:30", 22, 30), ("00:00", 0, 0), ("23:59", 23, 59), ("7:05", 7, 5), ("07:05", 7, 5),
        ]
        for (text, hour, minute) in valid {
            #expect(try Bedtime.parse(text) == Bedtime(hour: hour, minute: minute))
        }
        for text in ["24:00", "22:60", "22", "22:5", "-1:00", "+5:00", "22:+5", "22:30:00", "", ":30",
                     "22:", "ab:cd", "１２:３０", "122:30", "22.30", "2230", "off", "10:30pm"] {
            #expect(throws: CommandError.self) { try Bedtime.parse(text) }
        }
        do { _ = try Bedtime.parse("24:00") } catch let error as CommandError {
            #expect(error.code == .invalidInput)
            #expect(error.message.contains("23:59"))
        }
        #expect(Bedtime(hour: 24, minute: 0) == nil)
        #expect(Bedtime(hour: -1, minute: 0) == nil)
        #expect(Bedtime(hour: 22, minute: 60) == nil)
        #expect(Bedtime(hour: 7, minute: 5)?.text == "07:05")
        #expect(Bedtime(hour: 22, minute: 30)?.minuteOfDay == 1350)
        #expect(Bedtime(minuteOfDay: 1350) == Bedtime(hour: 22, minute: 30))
        #expect(Bedtime(minuteOfDay: 1440) == nil)
        #expect(Bedtime(minuteOfDay: -1) == nil)
    }

    @Test func rampsOverTwoHoursThenHoldsUntilSolarMidnight() {
        let bedtime = Bedtime(hour: 22, minute: 30)!
        let midnight = date("2025-06-21T01:00:00Z")
        func weights(_ text: String) -> BedtimeRamp.Weights {
            BedtimeRamp.weights(at: date(text), bedtime: bedtime, solarMidnight: midnight, calendar: calendar())
        }
        #expect(weights("2025-06-20T20:00:00Z") == .inactive)
        #expect(weights("2025-06-20T20:30:00Z").progress == 0)
        #expect(abs(weights("2025-06-20T21:00:00Z").progress - 0.15625) < 1e-12)   // smoothstep(¼)
        #expect(abs(weights("2025-06-20T21:30:00Z").progress - 0.5) < 1e-12)
        #expect(weights("2025-06-20T22:30:00Z").progress == 1)
        #expect(weights("2025-06-20T23:59:00Z") == BedtimeRamp.Weights(progress: 1, release: 0))
        // The last hour before solar midnight releases toward the sun's own midnight value.
        #expect(abs(weights("2025-06-21T00:30:00Z").release - 0.5) < 1e-12)
        #expect(weights("2025-06-21T00:30:00Z").progress == 1)
        // From solar midnight the sun is rising: the morning is the sun curve alone.
        #expect(weights("2025-06-21T01:00:00Z") == .inactive)
        #expect(weights("2025-06-21T06:00:00Z") == .inactive)
    }

    @Test func aRampCanStartBeforeLocalMidnight() {
        let midnight = date("2025-06-21T01:15:00Z")
        func progress(_ text: String, _ bedtime: Bedtime) -> Double {
            BedtimeRamp.weights(at: date(text), bedtime: bedtime, solarMidnight: midnight, calendar: calendar()).progress
        }
        let half = Bedtime(hour: 0, minute: 30)!
        #expect(progress("2025-06-20T22:30:00Z", half) == 0)
        #expect(abs(progress("2025-06-20T23:30:00Z", half) - 0.5) < 1e-12)
        #expect(progress("2025-06-21T00:30:00Z", half) == 1)
        // After local midnight but before solar midnight, an earlier bedtime still holds.
        #expect(progress("2025-06-21T00:15:00Z", Bedtime(hour: 23, minute: 30)!) == 1)
    }

    @Test func aBedtimeAfterSolarMidnightHasNoEffect() {
        let midnight = date("2025-06-21T01:15:00Z")
        let late = Bedtime(hour: 1, minute: 30)!
        for text in ["2025-06-20T23:45:00Z", "2025-06-21T00:45:00Z", "2025-06-21T01:10:00Z", "2025-06-21T01:30:00Z"] {
            #expect(BedtimeRamp.weights(at: date(text), bedtime: late, solarMidnight: midnight,
                                        calendar: calendar()) == .inactive)
        }
    }

    @Test func aLateBedtimeReachesTheDeepestTintBeforeStartingTheRelease() {
        let midnight = date("2025-06-21T01:00:00Z")
        let bedtime = Bedtime(hour: 0, minute: 30)!
        func weights(_ text: String) -> BedtimeRamp.Weights {
            BedtimeRamp.weights(at: date(text), bedtime: bedtime, solarMidnight: midnight, calendar: calendar())
        }
        let atBedtime = weights("2025-06-21T00:30:00Z")
        #expect(atBedtime == BedtimeRamp.Weights(progress: 1, release: 0))
        #expect(weights("2025-06-21T00:45:00Z") == BedtimeRamp.Weights(progress: 1, release: 0.5))

        let target = AdaptiveMapping.target(elevation: 3.5, minElevation: 3.4, presets: Preset.defaults,
                                             intensityMin: 0.2, intensityMax: 0.8,
                                             whitepointMin: 0.3, whitepointMax: 1, bedtime: atBedtime)
        #expect(target == AdaptiveMapping.Target(intensity: 0.2, whitepoint: 0.3, bedtime: true))
    }

    @Test func aBedtimeSoonAfterSolarNoonIsIgnoredSoNoonStaysContinuous() {
        // Solar noon 13:00, solar midnight 01:00. A ramp may not start before solar noon.
        let midnight = date("2025-06-21T01:00:00Z")
        func progress(_ text: String, _ bedtime: Bedtime) -> Double {
            BedtimeRamp.weights(at: date(text), bedtime: bedtime, solarMidnight: midnight, calendar: calendar()).progress
        }
        let early = Bedtime(hour: 14, minute: 0)!
        for text in ["2025-06-20T13:00:00Z", "2025-06-20T14:00:00Z", "2025-06-20T23:00:00Z"] {
            #expect(progress(text, early) == 0)
        }
        let earliest = Bedtime(hour: 15, minute: 0)!
        #expect(progress("2025-06-20T13:00:00Z", earliest) == 0)
        #expect(progress("2025-06-20T15:00:00Z", earliest) == 1)
    }

    @Test func springForwardRampsOverTwoElapsedHours() {
        // 2025-03-09 in New York: 02:00 EST jumps to 03:00 EDT. Solar midnight at 04:00 EDT.
        let newYork = calendar("America/New_York")
        let midnight = date("2025-03-09T08:00:00Z")
        func progress(_ text: String, _ bedtime: Bedtime) -> Double {
            BedtimeRamp.weights(at: date(text), bedtime: bedtime, solarMidnight: midnight, calendar: newYork).progress
        }
        let three = Bedtime(hour: 3, minute: 0)!
        #expect(progress("2025-03-09T05:00:00Z", three) == 0)                   // 00:00 EST
        #expect(abs(progress("2025-03-09T06:00:00Z", three) - 0.5) < 1e-12)    // 01:00 EST
        #expect(progress("2025-03-09T07:00:00Z", three) == 1)                   // 03:00 EDT
        // 02:30 does not exist that night; it lands on the next real time, 03:00 EDT.
        #expect(abs(progress("2025-03-09T06:00:00Z", Bedtime(hour: 2, minute: 30)!) - 0.5) < 1e-12)
    }

    @Test func fallBackUsesTheFirstOccurrenceOfARepeatedTime() {
        // 2025-11-02 in New York: 02:00 EDT falls back to 01:00 EST, so 01:30 happens twice.
        let newYork = calendar("America/New_York")
        let midnight = date("2025-11-02T06:45:00Z")                              // 01:45 EST
        let bedtime = Bedtime(hour: 1, minute: 30)!
        func progress(_ text: String) -> Double {
            BedtimeRamp.weights(at: date(text), bedtime: bedtime, solarMidnight: midnight, calendar: newYork).progress
        }
        #expect(progress("2025-11-02T03:30:00Z") == 0)
        #expect(abs(progress("2025-11-02T04:30:00Z") - 0.5) < 1e-12)
        #expect(progress("2025-11-02T05:30:00Z") == 1)                           // 01:30 EDT
        #expect(progress("2025-11-02T06:00:00Z") == 1)                           // 01:00 EST
    }

    @Test func solarMidnightComesFromTheSunAtTheLongitude() {
        let bedtime = Bedtime(hour: 22, minute: 30)!
        func weights(_ text: String, _ bedtime: Bedtime?, longitude: Double = 0,
                     calendar: Calendar = calendar()) -> BedtimeRamp.Weights {
            BedtimeRamp.weights(at: date(text), bedtime: bedtime, longitude: longitude, calendar: calendar)
        }
        // Greenwich at midsummer: solar midnight falls a few minutes after 00:00 UTC.
        #expect(weights("2025-06-21T22:30:00Z", bedtime).progress == 1)
        #expect(abs(weights("2025-06-21T21:30:00Z", bedtime).progress - 0.5) < 1e-12)
        #expect(weights("2025-06-22T03:00:00Z", bedtime) == .inactive)
        #expect(weights("2025-06-21T22:30:00Z", nil) == .inactive)
        // Los Angeles: the bedtime is local wall-clock time, solar midnight about 00:55 PDT.
        let losAngeles = calendar("America/Los_Angeles")
        #expect(abs(weights("2025-06-22T04:30:00Z", bedtime, longitude: -118.24,
                            calendar: losAngeles).progress - 0.5) < 1e-12)
        #expect(weights("2025-06-22T05:30:00Z", bedtime, longitude: -118.24, calendar: losAngeles).progress == 1)
        #expect(weights("2025-06-22T09:00:00Z", bedtime, longitude: -118.24, calendar: losAngeles) == .inactive)
    }

    @Test func solarMidnightEstimateAgreesAcrossTheEvening() {
        // The live tick re-derives solar midnight; it must not drift across hard cutoffs.
        for day in ["2025-02-11", "2025-05-14", "2025-07-26", "2025-11-03", "2025-12-24"] {
            for longitude in [0.0, -118.24, 139.69] {
                let noon = date("\(day)T12:00:00Z").addingTimeInterval(-longitude * 240)
                let early = SolarCalculator.nextSolarMidnight(after: noon.addingTimeInterval(600), longitude: longitude)
                let late = SolarCalculator.nextSolarMidnight(after: early.addingTimeInterval(-60), longitude: longitude)
                #expect(abs(early.timeIntervalSince(late)) < 1)
                #expect(early.timeIntervalSince(noon) > 11 * 3_600 && early.timeIntervalSince(noon) < 13 * 3_600)
            }
        }
    }

    @Test func fiveSecondTicksMoveTheRampAtMostAboutATenthOfAPercent() {
        // The existing 5 s adaptive tick is fine-grained enough; no extra timer is needed.
        let bedtime = Bedtime(hour: 22, minute: 30)!
        let midnight = date("2025-06-21T01:00:00Z")
        let start = date("2025-06-20T20:30:00Z")
        var previous = 0.0, largest = 0.0
        for second in stride(from: 0.0, through: BedtimeRamp.rampLength, by: 5) {
            let p = BedtimeRamp.weights(at: start.addingTimeInterval(second), bedtime: bedtime,
                                        solarMidnight: midnight, calendar: calendar()).progress
            largest = max(largest, abs(p - previous))
            previous = p
        }
        #expect(BedtimeRamp.rampLength == 7_200)
        #expect(previous == 1)
        #expect(largest <= 1.5 * 5 / 7_200 + 1e-12)
    }
}

@Suite struct BedtimeMappingTests {
    let presets = Preset.defaults

    func target(_ elevation: Double, minElevation: Double = -70, rising: Bool = false,
                iMin: Double = 0.2, iMax: Double = 0.8, wMin: Double = 0.3, wMax: Double = 1,
                progress: Double = 0, release: Double = 0) -> AdaptiveMapping.Target {
        AdaptiveMapping.target(
            elevation: elevation, minElevation: minElevation, rising: rising, presets: presets,
            intensityMin: iMin, intensityMax: iMax, whitepointMin: wMin, whitepointMax: wMax,
            bedtime: BedtimeRamp.Weights(progress: progress, release: release))
    }

    func sun(_ elevation: Double, minElevation: Double = -70, rising: Bool = false)
        -> (intensity: Double, whitepoint: Double)
    {
        AdaptiveMapping.banded(
            elevation: elevation, minElevation: minElevation, rising: rising, presets: presets,
            intensityMin: 0.2, intensityMax: 0.8, whitepointMin: 0.3, whitepointMax: 1)
    }

    @Test func inactiveBedtimeIsTheSunCurveExactly() {
        for minElevation in [-70.0, -10, 3] {
            for rising in [false, true] {
                for elevation in stride(from: 20.0, through: -70, by: -2.5) {
                    let s = sun(elevation, minElevation: minElevation, rising: rising)
                    let t = target(elevation, minElevation: minElevation, rising: rising)
                    #expect(t.intensity == s.intensity && t.whitepoint == s.whitepoint && !t.bedtime)
                    let banded = AdaptiveMapping.banded(
                        elevation: elevation, minElevation: minElevation, rising: rising, presets: presets,
                        intensityMin: 0.2, intensityMax: 0.8, whitepointMin: 0.3, whitepointMax: 1,
                        bedtime: .inactive)
                    #expect(banded.intensity == s.intensity && banded.whitepoint == s.whitepoint)
                }
            }
        }
    }

    @Test func fullProgressHoldsTheDeepestEndOfTheBand() {
        let t = target(-18, progress: 1)
        #expect(t.intensity == 0.2)
        #expect(t.whitepoint == 0.3)
        #expect(t.bedtime)
    }

    @Test func partialProgressLerpsFromTheDayEndOfTheBand() {
        let t = target(30, progress: 0.5)
        #expect(abs(t.intensity - 0.5) < 1e-12)
        #expect(abs(t.whitepoint - 0.65) < 1e-12)
        #expect(t.bedtime)
    }

    @Test func bedtimeNeverMakesTheCurveLessRed() {
        for progress in [0.1, 0.5, 1] {
            for elevation in stride(from: 20.0, through: -70, by: -2.5) {
                let s = sun(elevation), t = target(elevation, progress: progress)
                #expect(t.intensity <= s.intensity && t.whitepoint <= s.whitepoint)
                #expect(t.bedtime == (t.intensity < s.intensity || t.whitepoint < s.whitepoint))
            }
        }
        // Already at Late: the floor is not the one in effect.
        let deep = target(-70, progress: 0.3)
        #expect(deep.intensity == sun(-70).intensity && deep.whitepoint == sun(-70).whitepoint)
        #expect(!deep.bedtime)
    }

    @Test func pinnedChannelsIgnoreTheFloor() {
        let colorPinned = target(-18, iMin: 0.6, iMax: 0.6, progress: 1)
        #expect(colorPinned.intensity == 0.6)
        #expect(colorPinned.whitepoint == 0.3)
        #expect(colorPinned.bedtime)
        let bothPinned = target(-18, iMin: 0.6, iMax: 0.6, wMin: 0.7, wMax: 0.7, progress: 1)
        #expect(bothPinned.intensity == 0.6 && bothPinned.whitepoint == 0.7)
        #expect(!bothPinned.bedtime)
    }

    @Test func theMidnightSunStillReachesTheDeepestEndSoNothingIsReleased() {
        // About 70°N in late June the sun's lowest point is +3.4°. The curve slides up so
        // solar midnight is still Late, and the floor meets it there without a release.
        let atMidnight = sun(3.4, minElevation: 3.4)
        #expect(abs(atMidnight.intensity - 0.2) < 1e-12)
        #expect(abs(atMidnight.whitepoint - 0.3) < 1e-12)
        for release in [0.0, 0.5, 1] {
            let t = target(3.5, minElevation: 3.4, progress: 1, release: release)
            #expect(abs(t.intensity - 0.2) < 1e-12)
            #expect(abs(t.whitepoint - 0.3) < 1e-12)
        }
    }

    @Test func releaseIsANoOpOnNightsThatReachLate() {
        // Every night is stretched or slid so solar midnight is already Late.
        for minElevation in [11.4, -2.6, -6.6, -30, -70] {
            for release in [0.0, 0.5, 1] {
                let t = target(minElevation + 0.5, minElevation: minElevation, progress: 1, release: release)
                #expect(abs(t.intensity - 0.2) < 1e-12)
                #expect(abs(t.whitepoint - 0.3) < 1e-12)
            }
        }
    }
}

final class BedtimeTestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor @Suite struct BedtimeDisplayManagerTests {
    let defaultsRegistry = TestDefaultsRegistry()
    let gamma = MockGammaController()
    let bedtime = Bedtime(hour: 22, minute: 30)!

    func makeManager(latitude: Double = 60, longitude: Double = 0, clock: BedtimeTestClock,
                     defaults: UserDefaults? = nil, fade: TimeInterval = 0) -> DisplayManager {
        let location = FakeLocationProvider()
        location.coordinate = (latitude, longitude)
        return DisplayManager(
            gamma: gamma, getDisplayIDs: { [1] }, getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            defaults: defaults ?? defaultsRegistry.makeDefaults(prefix: "BedtimeTests"),
            location: location, now: { clock.date }, calendar: calendar(),
            adaptiveTransitionDuration: fade, displayTransitionDuration: 0)
    }

    @Test func unsetBedtimeLeavesTheCurveAndStatusUntouched() {
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let plain = makeManager(clock: clock)
        let cleared = makeManager(clock: clock)
        plain.adaptiveEnabled = true
        cleared.adaptiveEnabled = true
        cleared.setBedtime(bedtime)
        cleared.setBedtime(nil)
        #expect(cleared.bedtime == nil)
        for text in ["2025-06-21T20:00:00Z", "2025-06-21T22:30:00Z", "2025-06-21T23:50:00Z", "2025-06-22T03:00:00Z"] {
            clock.date = date(text)
            plain.applyAdaptive()
            cleared.applyAdaptive()
            #expect(cleared.intensity == plain.intensity && cleared.whitepoint == plain.whitepoint)
            #expect(cleared.adaptiveStatusText == plain.adaptiveStatusText)
            #expect(!plain.adaptiveStatusText.contains("bedtime"))
        }
    }

    @Test func floorDrivesTheLiveTargetAndTheStatusLine() {
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let manager = makeManager(clock: clock)
        manager.adaptiveEnabled = true
        let sunOnly = manager.intensity
        #expect(sunOnly > 0.05)                                 // the short night is still far from red
        #expect(!manager.adaptiveStatusText.contains("bedtime"))

        manager.setBedtime(bedtime)

        #expect(manager.bedtime == bedtime)
        #expect(manager.intensity == 0)
        // The deepest end of the default limits.
        #expect(manager.whitepoint == DisplayManager.Defaults.whitepointMin)
        #expect(manager.adaptiveStatusText.hasPrefix("Following the sun · "))
        #expect(manager.adaptiveStatusText.hasSuffix(" · bedtime"))

        // Before the ramp starts, the curve is the sun's alone.
        let plain = makeManager(clock: clock)
        plain.adaptiveEnabled = true
        clock.date = date("2025-06-21T20:00:00Z")
        manager.applyAdaptive()
        plain.applyAdaptive()
        #expect(manager.intensity == plain.intensity && manager.whitepoint == plain.whitepoint)
        #expect(manager.adaptiveStatusText == plain.adaptiveStatusText)
    }

    @Test func changingTheBedtimeRetargetsWithTheAdaptiveFade() {
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let manager = makeManager(clock: clock, fade: 2)
        manager.toggle(1)
        manager.adaptiveEnabled = true
        manager.completeOutputTransition()
        manager.completeDisplayTransitions()
        #expect(!manager.commandIsFading)

        manager.setBedtime(bedtime)

        #expect(manager.commandIsFading)
        #expect(manager.intensity == 0)                         // the model holds the endpoint
        manager.advanceOutputTransition(toProgress: 0.5)
        let mid = gamma.applyCalls.last?.intensity ?? 0
        #expect(mid > 0 && mid < 1)
        manager.completeOutputTransition()
        #expect(!manager.commandIsFading)
        #expect(gamma.applyCalls.last?.intensity == 0)
    }

    @Test func bedtimeWithAdaptiveOffIsOnlySaved() {
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let defaults = defaultsRegistry.makeDefaults(prefix: "BedtimeTests")
        let manager = makeManager(clock: clock, defaults: defaults)
        manager.intensity = 0.7
        manager.setBedtime(bedtime)
        #expect(manager.intensity == 0.7)
        #expect(!manager.commandIsFading)
        #expect(defaults.integer(forKey: "redlight.adaptiveBedtime") == 1350)
    }

    @Test func bedtimePersistsAndIsSanitizedOnLoad() {
        let clock = BedtimeTestClock(date("2025-06-21T12:00:00Z"))
        let defaults = defaultsRegistry.makeDefaults(prefix: "BedtimeTests")
        #expect(makeManager(clock: clock, defaults: defaults).bedtime == nil)
        makeManager(clock: clock, defaults: defaults).setBedtime(Bedtime(hour: 7, minute: 5))
        #expect(defaults.object(forKey: "redlight.adaptiveBedtime") as? Int == 425)
        #expect(makeManager(clock: clock, defaults: defaults).bedtime == Bedtime(hour: 7, minute: 5))
        makeManager(clock: clock, defaults: defaults).setBedtime(nil)
        #expect(defaults.object(forKey: "redlight.adaptiveBedtime") == nil)

        let corrupt: [Any] = [-1, 1440, 99_999, "22:30", 1350.5, Double.nan]
        for value in corrupt {
            defaults.set(value, forKey: "redlight.adaptiveBedtime")
            #expect(makeManager(clock: clock, defaults: defaults).bedtime == nil)
        }
    }

    @Test func manualOffsetShiftsTheCombinedCurveAndStaysInTheBand() {
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let manager = makeManager(clock: clock)
        // Without Learn my adjustments: a nudge is one offset for the whole curve.
        manager.setLearning(false)
        manager.adaptiveEnabled = true
        manager.adaptiveMin = 0.1
        manager.adaptiveMax = 0.9
        manager.flushBandRefresh()
        manager.setBedtime(bedtime)
        #expect(abs(manager.intensity - 0.1) < 1e-12)

        manager.intensity = 0.3                                 // nudge: +0.2 over the floor
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.3) < 1e-12)
        #expect(manager.adaptiveStatusText.hasSuffix(" · bedtime · adjusted"))
        clock.date = date("2025-06-21T23:00:00Z")
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.3) < 1e-12)

        manager.intensity = 0                                   // the band still clamps
        #expect(abs(manager.intensity - 0.1) < 1e-12)
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.1) < 1e-12)
    }

    @Test func pinnedChannelIgnoresTheBedtime() {
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let manager = makeManager(clock: clock)
        manager.adaptiveEnabled = true
        manager.adaptiveMin = 0.6
        manager.adaptiveMax = 0.6
        manager.flushBandRefresh()
        manager.setBedtime(bedtime)
        #expect(manager.intensity == 0.6)
        #expect(manager.whitepoint == DisplayManager.Defaults.whitepointMin)
    }

    @Test func savingAPresetUnderTheFloorDoesNotJump() {
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let manager = makeManager(clock: clock)
        manager.adaptiveEnabled = true
        manager.setBedtime(bedtime)
        manager.intensity = 0.15
        // Inside Auto's default limits, which stop at 0.625.
        manager.whitepoint = 0.7

        manager.saveToPreset(2)

        #expect(abs(manager.intensity - 0.15) < 1e-9)
        #expect(abs(manager.whitepoint - 0.7) < 1e-9)
        manager.applyAdaptive()
        #expect(abs(manager.intensity - 0.15) < 1e-9)
        #expect(abs(manager.whitepoint - 0.7) < 1e-9)
    }

    @Test func sunArcSamplesDrawTheSameFlooredCurve() throws {
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let manager = makeManager(clock: clock)
        manager.adaptiveEnabled = true
        manager.setBedtime(bedtime)
        let now = clock.date
        let elevation = SolarCalculator.elevation(at: now, latitude: 60, longitude: 0)
        let minimum = SolarCalculator.elevationAtSolarMidnight(at: now, latitude: 60, longitude: 0)
        let maximum = SolarCalculator.elevationAtSolarNoon(at: now, latitude: 60, longitude: 0)
        let rising = SolarCalculator.isRising(at: now, longitude: 0)

        let sample = manager.adaptiveIntensity(
            at: elevation, minElevation: minimum, maxElevation: maximum, rising: rising,
            time: (date: now, longitude: 0))
        #expect(abs(sample - manager.intensity) < 1e-12)
        #expect(manager.adaptiveIntensity(
            at: elevation, minElevation: minimum, maxElevation: maximum, rising: rising) > sample)

        let cycle = SunCycle(now: now, latitude: 60, longitude: 0, calendar: calendar())
        let start = calendar().startOfDay(for: now)
        #expect(cycle.samples.first?.date == start)
        #expect(cycle.samples.last?.date == start.addingTimeInterval(86_400))
        let late = try #require(cycle.samples.first { $0.date >= date("2025-06-21T22:40:00Z") })
        #expect(manager.adaptiveIntensity(
            at: late.elevation, minElevation: minimum, maxElevation: maximum, rising: late.rising,
            time: (date: late.date, longitude: 0)) < 1e-9)
    }

    @Test func holdsTheDeepestEndUntilSolarMidnightThenTheSunTakesOver() {
        // About 60°N at midsummer: a short night, stretched so solar midnight is Late.
        let clock = BedtimeTestClock(date("2025-06-21T22:30:00Z"))
        let floored = makeManager(clock: clock)
        let plain = makeManager(clock: clock)
        floored.adaptiveEnabled = true
        plain.adaptiveEnabled = true
        floored.setBedtime(bedtime)
        var sawMorning = false
        while clock.date < date("2025-06-22T03:00:00Z") {
            floored.applyAdaptive()
            plain.applyAdaptive()
            if SolarCalculator.isRising(at: clock.date, longitude: 0) {
                sawMorning = true
                #expect(floored.intensity == plain.intensity && floored.whitepoint == plain.whitepoint)
            } else {
                #expect(floored.intensity < 1e-9)
                #expect(abs(floored.whitepoint - DisplayManager.Defaults.whitepointMin) < 1e-9)
            }
            clock.date.addTimeInterval(60)
        }
        #expect(sawMorning)
    }

    @Test func midnightSunEasesOutInsteadOfSnapping() {
        // About 70°N at midsummer the sun never sets, so the sun curve at solar midnight is
        // far from Late. The floor eases to it over the last hour instead of snapping.
        let clock = BedtimeTestClock(date("2025-06-21T22:00:00Z"))
        let floored = makeManager(latitude: 70, clock: clock)
        let plain = makeManager(latitude: 70, clock: clock)
        floored.adaptiveEnabled = true
        plain.adaptiveEnabled = true
        floored.setBedtime(bedtime)
        var previous: (floored: Double, plain: Double, rising: Bool)?
        var largestEveningStep = 0.0
        var crossedMidnight = false
        while clock.date < date("2025-06-22T00:30:00Z") {
            floored.applyAdaptive()
            plain.applyAdaptive()
            let rising = SolarCalculator.isRising(at: clock.date, longitude: 0)
            if clock.date >= date("2025-06-21T22:30:00Z"), clock.date <= date("2025-06-21T23:00:00Z") {
                #expect(floored.intensity == 0)                 // held at the deepest end
            }
            if let previous {
                if previous.rising != rising {
                    // Across solar midnight the step is only the sun curve's own morning
                    // switch, which already happens (and fades) without a bedtime.
                    crossedMidnight = true
                    let flooredJump = floored.intensity - previous.floored
                    let plainJump = plain.intensity - previous.plain
                    #expect(abs(flooredJump - plainJump) < 0.005)
                } else if !rising {
                    largestEveningStep = max(largestEveningStep, abs(floored.intensity - previous.floored))
                }
            }
            previous = (floored.intensity, plain.intensity, rising)
            clock.date.addTimeInterval(5)
        }
        #expect(crossedMidnight)
        #expect(largestEveningStep < 0.004)
    }

    // MARK: - Wake time

    @Test func aWakeTimeHoldsTheBedtimeThroughTheNightThenClearsBeforeSunriseWouldHave() {
        // About 60°N at midsummer. Without a wake time the tint lifts from solar midnight.
        let clock = BedtimeTestClock(date("2025-06-21T20:00:00Z"))
        let scheduled = makeManager(clock: clock)
        let plain = makeManager(clock: clock)
        for manager in [scheduled, plain] {
            manager.adaptiveEnabled = true
            manager.setBedtime(bedtime)
        }
        scheduled.setWakeTime(Bedtime(hour: 6, minute: 0))
        #expect(scheduled.effectiveWakeTime == Bedtime(hour: 6, minute: 0))
        var previous = scheduled.intensity
        var largestStep = 0.0
        var sawPlainLighten = false, sawWakeStatus = false
        while clock.date < date("2025-06-22T14:00:00Z") {
            clock.date.addTimeInterval(60)
            scheduled.applyAdaptive()
            plain.applyAdaptive()
            largestStep = max(largestStep, abs(scheduled.intensity - previous))
            previous = scheduled.intensity
            if clock.date >= date("2025-06-21T22:30:00Z"), clock.date <= date("2025-06-22T05:00:00Z") {
                #expect(scheduled.intensity < 1e-9)                 // held, past solar midnight
                if plain.intensity > 0.2 { sawPlainLighten = true }
            }
            if clock.date > date("2025-06-22T05:00:00Z"), clock.date < date("2025-06-22T06:00:00Z") {
                #expect(scheduled.intensity > 0 && scheduled.intensity < 1)
                if scheduled.adaptiveStatusText.contains("wake time") { sawWakeStatus = true }
            }
            if clock.date >= date("2025-06-22T06:00:00Z"), clock.date <= date("2025-06-22T11:30:00Z") {
                #expect(scheduled.intensity == 1)
            }
            if clock.date >= date("2025-06-22T12:30:00Z") {
                // From solar noon the evening is the sun (and the bedtime) alone again.
                #expect(scheduled.intensity == plain.intensity)
            }
        }
        #expect(sawPlainLighten && sawWakeStatus)
        #expect(largestStep < 0.04)
    }

    @Test func aWakeTimeClearsADarkWinterMorningAndHandsBackToTheSunAtNoonWithoutAStep() {
        for latitude in [60.0, 70] {   // a late sunrise, and no sunrise at all
            let clock = BedtimeTestClock(date("2025-12-21T03:00:00Z"))
            let woken = makeManager(latitude: latitude, clock: clock)
            let plain = makeManager(latitude: latitude, clock: clock)
            woken.adaptiveEnabled = true
            plain.adaptiveEnabled = true
            woken.setWakeTime(Bedtime(hour: 7, minute: 0))
            var previous = woken.intensity
            var largestStep = 0.0
            while clock.date < date("2025-12-21T15:00:00Z") {
                clock.date.addTimeInterval(30)
                woken.applyAdaptive()
                plain.applyAdaptive()
                largestStep = max(largestStep, abs(woken.intensity - previous))
                previous = woken.intensity
                #expect(woken.intensity >= plain.intensity)             // never redder
                if clock.date < date("2025-12-21T06:00:00Z") || !SolarCalculator.isRising(at: clock.date, longitude: 0) {
                    #expect(woken.intensity == plain.intensity)
                } else if clock.date >= date("2025-12-21T07:00:00Z") {
                    // The lift ends within seconds of solar noon, where the sun is at Day too.
                    #expect(woken.intensity > 0.999)
                }
                if clock.date == date("2025-12-21T08:00:00Z") { #expect(plain.intensity < 0.6) }
            }
            #expect(largestStep < 0.02, "\(latitude)°")
        }
    }

    @Test func aWakeTimeLetsABedtimeAfterSolarMidnightCount() {
        let clock = BedtimeTestClock(date("2025-06-21T18:00:00Z"))
        let manager = makeManager(clock: clock)
        manager.adaptiveEnabled = true
        let late = Bedtime(hour: 1, minute: 30)!
        manager.setBedtime(late)
        #expect(manager.effectiveBedtime == nil)                        // after solar midnight
        manager.setWakeTime(Bedtime(hour: 7, minute: 0))
        #expect(manager.effectiveBedtime == late)
        clock.date = date("2025-06-22T02:30:00Z")
        manager.applyAdaptive()
        #expect(manager.intensity < 1e-9)
        #expect(manager.adaptiveStatusText.contains("bedtime"))
        // A wake time the night has no room for changes nothing.
        manager.setWakeTime(Bedtime(hour: 15, minute: 0))
        #expect(manager.effectiveWakeTime == nil && manager.effectiveBedtime == nil)
    }

    @Test func wakeTimePersistsAndIsSanitizedOnLoad() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "WakeTimeTests")
        let clock = BedtimeTestClock(date("2025-06-21T12:00:00Z"))
        let manager = makeManager(clock: clock, defaults: defaults)
        #expect(manager.wakeTime == nil)
        manager.setWakeTime(Bedtime(hour: 6, minute: 45))
        #expect(defaults.integer(forKey: "redlight.adaptiveWakeTime") == 405)
        #expect(makeManager(clock: clock, defaults: defaults).wakeTime == Bedtime(hour: 6, minute: 45))
        defaults.set(5_000, forKey: "redlight.adaptiveWakeTime")
        #expect(makeManager(clock: clock, defaults: defaults).wakeTime == nil)
        manager.setWakeTime(nil)
        #expect(defaults.object(forKey: "redlight.adaptiveWakeTime") == nil)
    }
}

@Suite struct WakeTimeTests {
    let presets = Preset.defaults
    let midnight = date("2025-06-21T01:00:00Z")   // solar noons at 13:00 on the 20th and the 21st

    func weights(_ text: String, bedtime: Bedtime? = nil, wake: Bedtime?) -> BedtimeRamp.Weights {
        BedtimeRamp.weights(at: date(text), bedtime: bedtime, wake: wake, solarMidnight: midnight, calendar: calendar())
    }

    @Test func liftsOverTheHourBeforeTheWakeTimeThenHoldsUntilSolarNoon() {
        let wake = Bedtime(hour: 7, minute: 0)!
        #expect(weights("2025-06-20T22:00:00Z", wake: wake) == .inactive)
        #expect(weights("2025-06-21T01:00:00Z", wake: wake) == .inactive)
        #expect(weights("2025-06-21T06:00:00Z", wake: wake).lift == 0)
        #expect(abs(weights("2025-06-21T06:15:00Z", wake: wake).lift - 0.15625) < 1e-12)   // smoothstep(¼)
        #expect(abs(weights("2025-06-21T06:30:00Z", wake: wake).lift - 0.5) < 1e-12)
        #expect(weights("2025-06-21T07:00:00Z", wake: wake) == BedtimeRamp.Weights(progress: 0, release: 0, lift: 1))
        #expect(weights("2025-06-21T12:59:00Z", wake: wake).lift == 1)
        // From solar noon it is the next night's evening.
        #expect(weights("2025-06-21T13:00:00Z", wake: wake) == .inactive)
    }

    @Test func aBedtimeHoldsUntilTheWakeTimeWithNoRelease() {
        let bedtime = Bedtime(hour: 22, minute: 30)!, wake = Bedtime(hour: 7, minute: 0)!
        #expect(abs(weights("2025-06-20T21:30:00Z", bedtime: bedtime, wake: wake).progress - 0.5) < 1e-12)
        for text in ["2025-06-20T22:30:00Z", "2025-06-21T00:30:00Z", "2025-06-21T01:00:00Z", "2025-06-21T05:59:00Z"] {
            #expect(weights(text, bedtime: bedtime, wake: wake) == BedtimeRamp.Weights(progress: 1, release: 0))
        }
        #expect(weights("2025-06-21T06:30:00Z", bedtime: bedtime, wake: wake)
                == BedtimeRamp.Weights(progress: 1, release: 0, lift: 0.5))
        #expect(weights("2025-06-21T07:00:00Z", bedtime: bedtime, wake: wake)
                == BedtimeRamp.Weights(progress: 0, release: 0, lift: 1))
        // Without the wake time: the release before solar midnight, and nothing after it.
        #expect(weights("2025-06-21T00:30:00Z", bedtime: bedtime, wake: nil).release == 0.5)
        #expect(weights("2025-06-21T03:00:00Z", bedtime: bedtime, wake: nil) == .inactive)
    }

    @Test func theScheduleSaysWhichTimesTheNightHasRoomFor() {
        func schedule(_ bedtime: Bedtime?, _ wake: Bedtime?) -> BedtimeRamp.Schedule {
            BedtimeRamp.schedule(bedtime: bedtime, wake: wake, solarMidnight: midnight, calendar: calendar())
        }
        func time(_ hour: Int, _ minute: Int = 0) -> Bedtime { Bedtime(hour: hour, minute: minute)! }
        #expect(schedule(time(22, 30), time(7)) == BedtimeRamp.Schedule(
            bedtime: date("2025-06-20T22:30:00Z"), wake: date("2025-06-21T07:00:00Z")))
        // A bedtime after solar midnight counts only when a wake time holds the night open.
        #expect(schedule(time(1, 30), nil).bedtime == nil)
        #expect(schedule(time(1, 30), time(7)).bedtime == date("2025-06-21T01:30:00Z"))
        // It must leave room for the lift: 06:00 is the latest for a 07:00 wake time.
        #expect(schedule(time(6), time(7)).bedtime == date("2025-06-21T06:00:00Z"))
        #expect(schedule(time(6, 1), time(7)) == BedtimeRamp.Schedule(bedtime: nil, wake: date("2025-06-21T07:00:00Z")))
        // A lift never starts before solar midnight, and a wake time after solar noon is none.
        #expect(schedule(nil, time(2)).wake == date("2025-06-21T02:00:00Z"))
        #expect(schedule(nil, time(1, 59)).wake == nil)
        #expect(schedule(nil, time(13)).wake == date("2025-06-21T13:00:00Z"))
        #expect(schedule(nil, time(13, 1)).wake == nil)
        #expect(schedule(time(22, 30), time(13, 1)) == BedtimeRamp.Schedule(bedtime: date("2025-06-20T22:30:00Z"), wake: nil))
        #expect(schedule(nil, nil) == BedtimeRamp.Schedule())
    }

    @Test func theMorningBelongsToTheNightThatBeganIt() {
        // Solar midnight at 0° is a little after 00:00 UTC; 06:30 is on its morning side.
        let wake = Bedtime(hour: 7, minute: 0)!
        let morning = BedtimeRamp.weights(at: date("2025-06-21T06:30:00Z"), bedtime: nil, wake: wake,
                                          longitude: 0, calendar: calendar())
        #expect(abs(morning.lift - 0.5) < 1e-12)
        #expect(BedtimeRamp.weights(at: date("2025-06-21T06:30:00Z"), bedtime: Bedtime(hour: 22, minute: 30),
                                    longitude: 0, calendar: calendar()) == .inactive)
        #expect(BedtimeRamp.weights(at: date("2025-06-21T06:30:00Z"), bedtime: nil, wake: nil,
                                    longitude: 0, calendar: calendar()) == .inactive)
        let evening = BedtimeRamp.weights(at: date("2025-06-21T20:00:00Z"), bedtime: nil, wake: wake,
                                          longitude: 0, calendar: calendar())
        #expect(evening == .inactive)
    }

    func target(_ elevation: Double, rising: Bool = true, iMin: Double = 0.2, iMax: Double = 0.8,
                progress: Double = 0, lift: Double) -> AdaptiveMapping.Target {
        AdaptiveMapping.target(
            elevation: elevation, minElevation: -70, rising: rising, presets: presets,
            intensityMin: iMin, intensityMax: iMax, whitepointMin: 0.3, whitepointMax: 1,
            bedtime: BedtimeRamp.Weights(progress: progress, release: 0, lift: lift))
    }

    @Test func theLiftEasesFromTheDeepestEndToTheDayEndAndNeverMakesTheCurveRedder() {
        // Deep night, held at the deepest end by the bedtime.
        #expect(target(-40, progress: 1, lift: 0) == AdaptiveMapping.Target(intensity: 0.2, whitepoint: 0.3, bedtime: true))
        let half = target(-40, progress: 1, lift: 0.5)
        #expect(abs(half.intensity - 0.5) < 1e-12 && abs(half.whitepoint - 0.65) < 1e-12)
        #expect(half.wake && !half.bedtime)
        #expect(target(-40, progress: 1, lift: 1) == AdaptiveMapping.Target(intensity: 0.8, whitepoint: 1, bedtime: false, wake: true))
        #expect(target(-40, lift: 1) == AdaptiveMapping.Target(intensity: 0.8, whitepoint: 1, bedtime: false, wake: true))
        for lift in [0.1, 0.5, 1] {
            for elevation in stride(from: 20.0, through: -70, by: -2.5) {
                let sun = target(elevation, lift: 0), lifted = target(elevation, lift: lift)
                #expect(lifted.intensity >= sun.intensity && lifted.whitepoint >= sun.whitepoint)
                #expect(lifted.wake == (lifted.intensity > sun.intensity || lifted.whitepoint > sun.whitepoint))
                #expect(!lifted.bedtime)
            }
        }
        // The sun already at Day: the lift is not the one in effect.
        #expect(target(30, lift: 0.4) == AdaptiveMapping.Target(intensity: 0.8, whitepoint: 1, bedtime: false))
    }

    @Test func pinnedChannelsIgnoreTheLift() {
        let pinned = target(-40, iMin: 0.6, iMax: 0.6, lift: 1)
        #expect(pinned.intensity == 0.6 && pinned.whitepoint == 1 && pinned.wake)
    }
}
