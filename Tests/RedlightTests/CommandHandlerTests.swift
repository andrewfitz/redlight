import Foundation
import Testing
@testable import Redlight

@MainActor
private final class CommandServiceState {
    var dark = false
    var login = Status.Login(enabled: false, requiresApproval: false)
    var ignoreAppearance = false
    var ignoreLogin = false
    var canUpdate = true
    var failure: CommandError?
    var updateCount = 0
    var quitCount = 0
    var pending: [@MainActor @Sendable () -> Void] = []
}

@MainActor
private struct CommandFixture {
    let manager: DisplayManager
    let gamma: MockGammaController
    let state: CommandServiceState
    let handler: CommandHandler
    let defaults: UserDefaults

    init(defaults: UserDefaults, location: LocationProviding? = nil, fadeDuration: TimeInterval = 0,
         now: Date = Date(timeIntervalSince1970: 1_780_000_000),
         peekNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        let gamma = MockGammaController()
        let state = CommandServiceState()
        let manager = DisplayManager(
            gamma: gamma, getDisplayIDs: { [10, 20, 30] },
            getDisplayName: { $0 == 10 ? "Built-in Retina" : $0 == 20 ? "Studio Display Left" : "Studio Display Right" },
            getDisplayPersistenceKey: { "stable-\($0)" },
            defaults: defaults, location: location ?? FakeLocationProvider(),
            now: { now },
            adaptiveTransitionDuration: fadeDuration, displayTransitionDuration: 0
        )
        self.defaults = defaults
        self.gamma = gamma
        self.manager = manager
        self.state = state
        self.handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { state.dark },
            setAppearance: {
                if let failure = state.failure { throw failure }
                if !state.ignoreAppearance { state.dark = $0 }
            },
            login: { state.login },
            setLogin: {
                if let failure = state.failure { throw failure }
                if !state.ignoreLogin { state.login.enabled = $0 }
            },
            update: { state.updateCount += 1 }, quit: { state.quitCount += 1 },
            version: { "1.2.3-test" }, deferAction: { state.pending.append($0) },
            canUpdate: { state.canUpdate }
        ), peekNow: peekNow)
    }
}

@MainActor
@Suite struct CommandHandlerTests {
    let defaultsRegistry = TestDefaultsRegistry()

    private func makeFixture(location: LocationProviding? = nil, fadeDuration: TimeInterval = 0) -> CommandFixture {
        CommandFixture(defaults: defaultsRegistry.makeDefaults(prefix: "CommandHandlerTests"),
                       location: location, fadeDuration: fadeDuration)
    }
    private func expectError(_ code: CommandError.Code, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected \(code) error")
        } catch let error as CommandError {
            #expect(error.code == code)
            #expect(!error.message.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func stepsStartFromTheTargetAndPauseReadsAsOff() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.color(40))
        var status = try f.handler.execute(.step(.color, 5))
        #expect(status.color.set == 45)
        status = try f.handler.execute(.step(.color, 100))
        #expect(status.color.set == 100)
        status = try f.handler.execute(.step(.whitepoint, -100))
        // The bottom of the white point's scale: 0 %, which the displays take as 0.25.
        #expect(status.whitepoint.set == 0)
        #expect(f.manager.whitepoint == 0.25)
        expectError(.invalidInput) { _ = try f.handler.execute(.step(.color, 0)) }
        expectError(.invalidInput) { _ = try f.handler.execute(.step(.color, .nan)) }
        expectError(.invalidInput) { _ = try f.handler.execute(.pause(.on)) } // nothing to pause

        _ = try f.handler.execute(.master(.on))
        status = try f.handler.execute(.pause(.toggle))
        #expect(!status.on)
        #expect(status.pausedUntil != nil)
        #expect(f.defaults.bool(forKey: "redlight.isOn") == false) // Control Center sees off
        status = try f.handler.execute(.master(.toggle))
        #expect(status.on)
        #expect(status.pausedUntil == nil)
        #expect(f.defaults.bool(forKey: "redlight.isOn"))
    }

    @Test func olderSettingsMigrateToIntegerPercentagesAndRoundTrip() throws {
        let defaults = defaultsRegistry.makeDefaults(prefix: "WholeSliderValues")
        defaults.set(0.374, forKey: "redlight.intensity")
        defaults.set(0.53125, forKey: "redlight.whitepoint") // 37.5% of the white point scale
        defaults.set(0.995, forKey: "redlight.saturation")
        let f = CommandFixture(defaults: defaults, location: nil, fadeDuration: 0)
        #expect(f.manager.colorPercent == 37 && f.manager.whitepointPercent == 38)
        #expect(f.manager.saturationPercent == 100 && f.manager.saturationEnabled)
        _ = try f.handler.execute(.color(20.5))
        _ = try f.handler.execute(.whitepoint(61.4))
        _ = try f.handler.execute(.saturation(19.8))
        let restored = CommandFixture(defaults: defaults, location: nil, fadeDuration: 0)
        #expect(restored.manager.colorPercent == 21 && restored.manager.whitepointPercent == 61)
        #expect(restored.manager.saturationPercent == 20)
        #expect(defaults.integer(forKey: "redlight.colorPercent") == 21)
        #expect(defaults.integer(forKey: "redlight.whitepointPercent") == 61)
        #expect(defaults.integer(forKey: "redlight.saturationPercent") == 20)
    }

    @Test func fractionalInputsRoundToWholePercentages() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.color(40.0004))
        let increased = try f.handler.execute(.step(.color, 0.00005))
        #expect(increased.color.set == 40)
        let decreased = try f.handler.execute(.step(.color, -0.00005))
        #expect(decreased.color.set == 40)
    }

    @Test func timedAndSunrisePausesUseTheirOwnLength() throws {
        let location = FakeLocationProvider()
        location.coordinate = (latitude: 41.88, longitude: -87.63)
        let f = makeFixture(location: location)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        expectError(.invalidInput) { _ = try f.handler.execute(.pauseFor(.minutes(90))) } // nothing to pause
        expectError(.invalidInput) { _ = try f.handler.execute(.pauseFor(.untilSunrise)) }
        #expect(!f.manager.isPaused)

        _ = try f.handler.execute(.master(.on))
        var status = try f.handler.execute(.pauseFor(.minutes(90)))
        #expect(!status.on)
        #expect(status.pausedUntil == now.addingTimeInterval(90 * 60))
        // A plain pause keeps the running one; choosing a length replaces it.
        status = try f.handler.execute(.pause(.on))
        #expect(status.pausedUntil == now.addingTimeInterval(90 * 60))
        status = try f.handler.execute(.pauseFor(.minutes(1)))
        #expect(status.pausedUntil == now.addingTimeInterval(60))

        let sunrise = try #require(SunCycle.nextSunrise(after: now, latitude: 41.88, longitude: -87.63))
        status = try f.handler.execute(.pauseFor(.untilSunrise))
        let until = try #require(status.pausedUntil)
        #expect(abs(until.timeIntervalSince(sunrise)) < 1)
        #expect(abs(f.manager.pauseLength - until.timeIntervalSince(now)) < 0.001)
        status = try f.handler.execute(.pause(.off))
        #expect(status.on)
        #expect(status.pausedUntil == nil)
    }

    @Test func commandPeekPreservesPauseAndTapOrdering() throws {
        let f = makeFixture()
        expectError(.invalidInput) { _ = try f.handler.execute(.peek(.on)) }

        _ = try f.handler.execute(.master(.on))
        var status = try f.handler.execute(.peek(.on))
        #expect(status.peeking == true)
        #expect(!f.manager.isPaused)
        status = try f.handler.execute(.peek(.off))
        #expect(status.peeking == false)
        #expect(!f.manager.isPaused)

        status = try f.handler.execute(.peek(.on))
        #expect(status.peeking == true)
        status = try f.handler.execute(.peek(.tap))
        #expect(status.pausedUntil != nil)
        #expect(status.peeking == false)

        status = try f.handler.execute(.pause(.on))
        #expect(status.pausedUntil != nil)
        status = try f.handler.execute(.peek(.on))
        #expect(status.peeking == true)
        status = try f.handler.execute(.peek(.tap))
        #expect(status.pausedUntil == nil)
        #expect(status.peeking == false)
        #expect(status.on)
    }

    @Test func commandAndShortcutPeekSourcesDoNotReleaseEachOther() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.master(.on))
        f.manager.setPeeking(true)
        _ = try f.handler.execute(.peek(.on))
        #expect(f.manager.isPeeking(source: .shortcut))
        #expect(f.manager.isPeeking(source: .command))
        _ = try f.handler.execute(.peek(.off))
        #expect(f.manager.isPeeking(source: .shortcut))
        f.manager.setPeeking(false)
        #expect(!f.manager.isPeeking(source: .shortcut))
        #expect(!f.manager.isPeeking(source: .command))
    }

    @Test func commandPeekRenewalExtendsTheLeaseAndKeepsTheOriginalPauseState() throws {
        var now = ContinuousClock().now
        let f = CommandFixture(defaults: defaultsRegistry.makeDefaults(prefix: "CommandHandlerTests"),
                               peekNow: { now })
        _ = try f.handler.execute(.master(.on))
        _ = try f.handler.execute(.pause(.on))
        _ = try f.handler.execute(.peek(.on))

        now = now.advanced(by: .seconds(3))
        f.manager.resume()
        #expect(try f.handler.execute(.peek(.renew)).peeking == true)
        now = now.advanced(by: .seconds(2))
        #expect(f.handler.snapshot().peeking == true)
        let status = try f.handler.execute(.peek(.tap))
        #expect(status.peeking == false)
        #expect(status.pausedUntil == nil)
    }

    @Test func commandPeekRenewalCannotReacquireAfterCancellationOrExpiry() throws {
        var now = ContinuousClock().now
        let f = CommandFixture(defaults: defaultsRegistry.makeDefaults(prefix: "CommandHandlerTests"),
                               peekNow: { now })
        _ = try f.handler.execute(.master(.on))
        #expect(try f.handler.execute(.peek(.renew)).peeking == false)
        _ = try f.handler.execute(.peek(.on))
        _ = f.manager.pause()
        f.manager.resume()
        for _ in 0..<2 {
            #expect(try f.handler.execute(.peek(.renew)).peeking == false)
        }

        #expect(try f.handler.execute(.peek(.on)).peeking == true)
        f.manager.setPeeking(true, source: .shortcut)
        now = now.advanced(by: .seconds(4))
        #expect(try f.handler.execute(.peek(.renew)).peeking == true)
        #expect(!f.manager.isPeeking(source: .command))
        #expect(f.manager.isPeeking(source: .shortcut))
        #expect(try f.handler.execute(.peek(.tap)).pausedUntil == nil)
        f.manager.setPeeking(false, source: .shortcut)
        #expect(f.handler.snapshot().peeking == false)
    }

    @Test func commandPeekLeaseExpiresWithoutAnotherCommand() async throws {
        let f = makeFixture()
        _ = try f.handler.execute(.master(.on))
        #expect(try f.handler.execute(.peek(.on)).peeking == true)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while f.manager.isPeeking(source: .command), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(50))
        }
        #expect(!f.manager.isPeeking(source: .command))
        #expect(f.handler.snapshot().peeking == false)
    }

    @Test func commandPeekOnlyInterruptsSliderInteractionWhenTapped() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.master(.on))
        let token = f.manager.beginSliderInteraction()
        for action: CommandPeek in [.on, .renew, .off, .tap, .on] {
            _ = try f.handler.execute(.peek(action))
            #expect(f.manager.isSliderInteractionCurrent(token))
        }
        _ = try f.handler.execute(.peek(.tap))
        #expect(!f.manager.isSliderInteractionCurrent(token))
    }

    @Test func untilSunriseWithoutASunriseOrLocationIsAClearErrorAndDoesNotPause() throws {
        let location = FakeLocationProvider()
        location.coordinate = (latitude: 89.9, longitude: 0)   // late May: the sun never sets
        let f = makeFixture(location: location)
        _ = try f.handler.execute(.master(.on))
        func message() -> String {
            do {
                _ = try f.handler.execute(.pauseFor(.untilSunrise))
                Issue.record("Paused without a sunrise")
            } catch let error as CommandError {
                #expect(error.code == .invalidInput)
                return error.message
            } catch { Issue.record("Unexpected error: \(error)") }
            return ""
        }
        #expect(message().contains("25 hours"))
        #expect(!f.manager.isPaused)
        location.coordinate = nil
        #expect(message().contains("location"))
        #expect(!f.manager.isPaused)
    }

    @Test(arguments: [-30.0, 5.0]) func sunrisePauseKeepsDeadlinesOutsideTimedPauseLimits(offset: TimeInterval) throws {
        let location = FakeLocationProvider()
        let latitude = 41.88, longitude = -87.63
        location.coordinate = (latitude: latitude, longitude: longitude)
        let septemberMorning = Date(timeIntervalSince1970: 1_789_430_400) // September 15, 2026, 00:00 UTC
        let firstSunrise = try #require(SunCycle.nextSunrise(after: septemberMorning, latitude: latitude, longitude: longitude))
        let now = firstSunrise.addingTimeInterval(offset)
        let expected = try #require(SunCycle.nextSunrise(after: now, latitude: latitude, longitude: longitude))
        let seconds = expected.timeIntervalSince(now)
        #expect(offset < 0 ? seconds < 60 : seconds > 86_400)

        let fixture = CommandFixture(defaults: defaultsRegistry.makeDefaults(prefix: "CommandHandlerTests"),
                                     location: location, now: now)
        _ = try fixture.handler.execute(.master(.on))
        let status = try fixture.handler.execute(.pauseFor(.untilSunrise))
        #expect(status.pausedUntil == expected)
        #expect(fixture.manager.pauseLength == seconds)
    }

    @Test func locationCommandsSetManualAndReportTheSource() throws {
        let location = FakeLocationProvider()
        location.coordinate = (latitude: 41.88, longitude: -87.63)
        location.isApproximate = true
        let f = makeFixture(location: location)
        #expect(f.handler.snapshot().locationSource == .timeZone)

        var status = try f.handler.execute(.location(.manual(latitude: 51.5, longitude: -0.13)))
        #expect(status.locationSource == .manual)
        #expect(location.manualCoordinate?.latitude == 51.5)
        #expect(f.manager.manualLocation?.longitude == -0.13)
        _ = try f.handler.execute(.adaptive(.on))
        status = try f.handler.execute(.status)
        #expect(status.statusLine.hasSuffix(" · manual"))
        #expect(!status.statusLine.contains("51.5"))

        status = try f.handler.execute(.location(.automatic))
        #expect(status.locationSource == .timeZone)
        #expect(location.manualCoordinate == nil)
        location.isApproximate = false
        #expect(f.handler.snapshot().locationSource == .auto)
    }

    @Test func invalidLocationsAndPauseLengthsAreRejectedBeforeInterrupting() throws {
        let location = FakeLocationProvider()   // no coordinate, so no sunrise to find
        let f = makeFixture(location: location)
        _ = try f.handler.execute(.master(.on))
        let commands: [RedlightCommand] = [
            .location(.manual(latitude: 91, longitude: 0)), .location(.manual(latitude: -90.01, longitude: 0)),
            .location(.manual(latitude: 0, longitude: 180.01)), .location(.manual(latitude: .nan, longitude: 0)),
            .location(.manual(latitude: 0, longitude: .infinity)),
            .pauseFor(.minutes(0)), .pauseFor(.minutes(-5)), .pauseFor(.minutes(1441)), .pauseFor(.untilSunrise),
        ]
        let token = f.manager.beginSliderInteraction()
        f.manager.previewIntensity(0.15)
        let original = f.handler.snapshot()
        for command in commands {
            expectError(.invalidInput) { _ = try f.handler.execute(command) }
            #expect(f.manager.isSliderInteractionCurrent(token))
            #expect(f.handler.snapshot() == original)
            #expect(location.manualCoordinate == nil)
        }
    }

    @Test func bedtimeCommandsSetAndClearTheAdaptiveBedtime() throws {
        let f = makeFixture()
        #expect(f.handler.snapshot().bedtime == nil)
        var status = try f.handler.execute(.bedtime(.at(hour: 22, minute: 30)))
        #expect(status.bedtime == "22:30")
        #expect(f.manager.bedtime == Bedtime(hour: 22, minute: 30))
        #expect(f.defaults.integer(forKey: "redlight.adaptiveBedtime") == 1350)
        status = try f.handler.execute(.bedtime(.at(hour: 7, minute: 5)))
        #expect(status.bedtime == "07:05")
        #expect(!status.adaptive)                               // saved for when Adaptive is on
        status = try f.handler.execute(.bedtime(.off))
        #expect(status.bedtime == nil)
        #expect(f.manager.bedtime == nil)
        #expect(f.defaults.object(forKey: "redlight.adaptiveBedtime") == nil)
    }

    @Test func wakeCommandsSetAndClearTheAdaptiveWakeTime() throws {
        let f = makeFixture()
        #expect(f.handler.snapshot().wake == nil)
        var status = try f.handler.execute(.wake(.at(hour: 7, minute: 5)))
        #expect(status.wake == "07:05")
        #expect(status.bedtime == nil)
        #expect(f.manager.wakeTime == Bedtime(hour: 7, minute: 5))
        #expect(f.defaults.integer(forKey: "redlight.adaptiveWakeTime") == 425)
        #expect(!status.adaptive)                               // saved for when Adaptive is on
        do {
            _ = try f.handler.execute(.wake(.at(hour: 24, minute: 0)))
            Issue.record("Accepted wake time 24:00")
        } catch let error as CommandError {
            #expect(error.code == .invalidInput)
            #expect(error.message == Bedtime.invalidWakeMessage)
        }
        #expect(f.manager.wakeTime == Bedtime(hour: 7, minute: 5))
        status = try f.handler.execute(.wake(.off))
        #expect(status.wake == nil)
        #expect(f.manager.wakeTime == nil)
        #expect(f.defaults.object(forKey: "redlight.adaptiveWakeTime") == nil)
    }

    @Test func learnCommandsSwitchLearningAndResetIt() throws {
        let location = FakeLocationProvider()
        location.coordinate = (latitude: 41.88, longitude: -87.63)
        let f = makeFixture(location: location)
        // On until switched off.
        #expect(f.handler.snapshot().learning == Status.Learning(enabled: true, colorAnchors: 0, whitepointAnchors: 0, backups: 0))
        var status = try f.handler.execute(.learn(.off))
        #expect(status.learning?.enabled == false && !f.manager.learningEnabled)
        #expect(f.defaults.object(forKey: "redlight.learningEnabled") as? Bool == false)
        status = try f.handler.execute(.learn(.on))
        #expect(status.learning?.enabled == true && status.learning?.anchors == 0)
        #expect(f.manager.learningEnabled)
        #expect(f.defaults.bool(forKey: "redlight.learningEnabled"))
        status = try f.handler.execute(.learn(.toggle))
        #expect(status.learning?.enabled == false && !f.manager.learningEnabled)
        status = try f.handler.execute(.learn(.toggle))
        #expect(status.learning?.enabled == true)
        // A nudge in Auto is something learned, on that slider.
        _ = try f.handler.execute(.adaptive(.on))
        status = try f.handler.execute(.step(.color, -10))
        #expect(status.learning?.anchors == 1 && status.learning?.colorAnchors == 1)
        #expect(status.learning?.whitepointAnchors == 0 && status.learning?.summary.count == 1)
        status = try f.handler.execute(.learn(.reset))
        #expect(status.learning?.enabled == true, "a reset forgets; it does not switch off")
        #expect(status.learning?.anchors == 0 && status.learning?.summary == [])
        status = try f.handler.execute(.learn(.off))
        #expect(status.learning?.enabled == false)
        #expect(!f.defaults.bool(forKey: "redlight.learningEnabled"))
    }

    @Test func learnRestoreBringsBackWhatAResetKeptAndRefusesWhenThereIsNone() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.learn(.on))
        do {
            _ = try f.handler.execute(.learn(.restore))
            Issue.record("Restored with nothing kept")
        } catch let error as CommandError {
            #expect(error.code == .invalidInput)
            #expect(error.message.contains("no earlier learning"))
        }
        // A reset with nothing learned keeps nothing, so there is still nothing to restore.
        let status = try f.handler.execute(.learn(.reset))
        #expect(status.learning?.backups == 0)
        #expect(throws: CommandError.self) { _ = try f.handler.execute(.learn(.restore)) }
        // What a restore brings back is tested through the manager in LearnedAutoTests.
    }

    @Test func invalidBedtimesAreRejectedBeforeInterrupting() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.bedtime(.at(hour: 21, minute: 0)))
        let token = f.manager.beginSliderInteraction()
        f.manager.previewIntensity(0.15)
        let original = f.handler.snapshot()
        for (hour, minute) in [(24, 0), (-1, 0), (22, 60), (22, -1), (99, 99)] {
            do {
                _ = try f.handler.execute(.bedtime(.at(hour: hour, minute: minute)))
                Issue.record("Accepted bedtime \(hour):\(minute)")
            } catch let error as CommandError {
                #expect(error.code == .invalidInput)
                #expect(error.message.contains("23:59"))
            }
            #expect(f.manager.isSliderInteractionCurrent(token))
            #expect(f.handler.snapshot() == original)
            #expect(f.manager.bedtime == Bedtime(hour: 21, minute: 0))
        }
    }

    @Test func percentagesResetLimitsAndPersistence() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.color(42))
        _ = try f.handler.execute(.whitepoint(67))
        #expect(f.manager.intensity == 0.42)
        #expect(f.manager.whitepoint == WhitepointScale.output(percent: 67))
        #expect(abs(f.manager.whitepoint - 0.7525) < 1e-12)
        #expect(f.defaults.integer(forKey: "redlight.colorPercent") == 42)
        _ = try f.handler.execute(.limits(.color, min: 20, max: 70))
        _ = try f.handler.execute(.limits(.whitepoint, min: 40, max: 80))
        #expect(f.manager.intensityBand == 0.2...0.7)
        #expect(f.manager.whitepointBand == WhitepointScale.output(percent: 40)...WhitepointScale.output(percent: 80))
        #expect(f.defaults.double(forKey: "redlight.adaptiveMin") == 0.2)
        #expect(f.defaults.double(forKey: "redlight.adaptiveWpMax") == WhitepointScale.output(percent: 80))
        _ = try f.handler.execute(.reset(.color))
        _ = try f.handler.execute(.reset(.whitepoint))
        #expect(f.manager.intensityIsDefault)
        #expect(f.manager.whitepointIsDefault)
    }

    @Test func theWhitePointIsSetAndReadInPercentOfItsOwnScale() throws {
        let f = makeFixture()
        #expect(WhitepointScale.output == 0.25...1)
        #expect(WhitepointScale.output(percent: 0) == 0.25 && WhitepointScale.output(percent: 100) == 1)
        #expect(WhitepointScale.percent(0.25) == 0 && WhitepointScale.percent(1) == 100)
        #expect(WhitepointScale.percent(.nan) == 100 && WhitepointScale.output(.nan) == 1)
        #expect(WhitepointScale.percent(0.1) == 0 && WhitepointScale.output(percent: 250) == 1)
        // Every whole percent that is set reads back as itself, to the last digit, and the
        // displays take its place between 0.25 and 1.
        var last = -1.0
        for percent in 0...100 {
            let status = try f.handler.execute(.whitepoint(Double(percent)))
            #expect(status.whitepoint.set == percent, "\(percent) reads \(status.whitepoint.set)")
            #expect(abs(f.manager.whitepoint - (0.25 + 0.0075 * Double(percent))) < 1e-12)
            #expect(f.manager.whitepoint > last)
            last = f.manager.whitepoint
        }
        // Limits the same, and equal ones still pin.
        for (low, high) in [(0.0, 100.0), (7, 93), (33, 34), (50, 50)] {
            _ = try f.handler.execute(.limits(.whitepoint, min: low, max: high))
            let limits = f.handler.snapshot().limits.whitepoint
            #expect(limits == Status.Band(min: low, max: high), "\(low)–\(high) reads \(limits)")
        }
        _ = try f.handler.execute(.reset(.whitepoint))
        // Reset: Auto's white point stops halfway down its scale, and goes to the top.
        #expect(f.manager.adaptiveWpMin == 0.625 && f.manager.adaptiveWpMax == 1)
        #expect(f.handler.snapshot().limits == Status.Limits.factory)
        #expect(Status.Limits.factory.whitepoint.min == 50)
        // Status text writes one decimal, whatever is behind it.
        #expect(Status.Limits.factory.whitepoint.text == "50.0–100.0%")
        #expect(Status.Band(min: 100.0 / 15, max: 100).text == "6.7–100.0%")
        #expect(Status.Level(set: 27, target: 7).text == "27% (target 7%)")
        #expect(Status.Band(min: 50, max: 50).text == "fixed at 50.0%")
    }

    @Test func whitePointStepsAreSoManyPercentOfTheScaleAndComeBackTheSameWay() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.whitepoint(100))
        var seen: [Int] = [100]
        // Down in fives to the floor: each step lands five lower, and the floor holds.
        for _ in 0..<22 {
            let status = try f.handler.execute(.step(.whitepoint, -5))
            seen.append(status.whitepoint.set)
        }
        for (index, value) in seen.prefix(21).enumerated() {
            #expect(value == 100 - 5 * index, "step \(index): \(value)")
        }
        #expect(seen.suffix(3) == [0, 0, 0])
        #expect(f.manager.whitepoint == 0.25)
        // And up again through the same values.
        var back: [Int] = [0]
        for _ in 0..<20 { back.append(try f.handler.execute(.step(.whitepoint, 5)).whitepoint.set) }
        for (down, up) in zip(seen.prefix(21).reversed(), back) { #expect(down == up) }
        #expect(f.manager.whitepoint == 1)
        // A fractional step never moves the wrong way.
        for step in [0.3, 1.5, 7.25] {
            let before = f.handler.snapshot().whitepoint.set
            let lower = try f.handler.execute(.step(.whitepoint, -step)).whitepoint.set
            #expect(lower == before - Int(step.rounded()))
            #expect(try f.handler.execute(.step(.whitepoint, step)).whitepoint.set == before)
        }
    }

    @Test func presetsAndSavedSettingsReachTheDisplaysAsBefore() throws {
        // The scale is how the white point is shown and set, never what a preset or a saved
        // value means: each default preset still sends its own white point to the displays.
        let f = makeFixture()
        _ = try f.handler.execute(.display(.all, .on))
        for preset in CommandPreset.allCases {
            let status = try f.handler.execute(.preset(preset))
            let wanted = Preset.defaults[preset.index]
            #expect(f.manager.whitepoint == wanted.whitepoint)
            #expect(f.manager.intensity == wanted.intensity)
            #expect(status.whitepoint.set == wanted.whitepointPercent)
        }
        #expect(Preset.defaults.map(\.whitepointPercent) == [100, 80, 53, 27, 7])
        // A white point saved by an earlier version loads as the output value it was.
        let defaults = defaultsRegistry.makeDefaults(prefix: "CommandHandlerTests")
        defaults.set(0.45, forKey: "redlight.whitepoint")
        defaults.set(0.4, forKey: "redlight.adaptiveWpMin")
        let loaded = CommandFixture(defaults: defaults, location: nil, fadeDuration: 0)
        #expect(loaded.manager.whitepointPercent == 27 && loaded.manager.adaptiveWpMin == 0.4)
        #expect(loaded.handler.snapshot().whitepoint.set == 27)
        #expect(abs(loaded.handler.snapshot().limits.whitepoint.min - 20) < 1e-8)
        // The minimum an earlier version started with, 0.3, is kept as a limit someone has:
        // only Reset, which now shows for it, takes it to the new default.
        let earlier = defaultsRegistry.makeDefaults(prefix: "CommandHandlerTests")
        earlier.set(0.3, forKey: "redlight.adaptiveWpMin")
        let kept = CommandFixture(defaults: earlier, location: nil, fadeDuration: 0)
        #expect(kept.manager.adaptiveWpMin == 0.3)
        #expect(!kept.manager.whitepointAutoSettingsAreDefault)
        _ = try kept.handler.execute(.reset(.whitepoint))
        #expect(kept.manager.adaptiveWpMin == 0.625 && kept.manager.whitepointAutoSettingsAreDefault)
        #expect(kept.handler.snapshot().limits.whitepoint.min == 50)
    }

    @Test func equalLimitsPinAChannelAndStepsMoveThePin() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.adaptive(.on))
        _ = try f.handler.execute(.limits(.whitepoint, min: 100, max: 100))
        #expect(f.manager.isWhitepointPinned)
        #expect(f.handler.snapshot().limits.whitepoint.text == "fixed at 100.0%")
        _ = try f.handler.execute(.step(.whitepoint, -5))
        let stepped = WhitepointScale.output(percent: 95)
        #expect(f.manager.whitepointBand == stepped...stepped)
        #expect(f.manager.whitepoint == stepped)
        #expect(f.handler.snapshot().limits.whitepoint.text == "fixed at 95.0%")
        _ = try f.handler.execute(.whitepoint(60))
        let set = WhitepointScale.output(percent: 60)
        #expect(f.manager.whitepointBand == set...set)
        #expect(f.defaults.double(forKey: "redlight.adaptiveWpMax") == set)
    }

    @Test func rejectsAllInvalidRangesBeforeInterruptingOrPersisting() {
        let f = makeFixture()
        let commands: [RedlightCommand] = [
            .color(-1), .color(101), .color(.nan), .color(.infinity),
            .whitepoint(-0.1), .whitepoint(101), .whitepoint(-.infinity),
            .limits(.color, min: 80, max: 10),
            .limits(.color, min: -.infinity, max: 100),
            .limits(.whitepoint, min: -1, max: 100), .limits(.whitepoint, min: 25, max: .nan)
        ]
        let token = f.manager.beginSliderInteraction()
        f.manager.previewIntensity(0.15)
        let original = f.handler.snapshot()
        for command in commands {
            expectError(.invalidInput) { _ = try f.handler.execute(command) }
            #expect(f.manager.isSliderInteractionCurrent(token))
            #expect(f.handler.snapshot() == original)
        }
    }

    @Test func resolvesNumberUniqueSubstringAndStableKey() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.display(.number(2), .on))
        _ = try f.handler.execute(.display(.name("RETINA"), .on))
        _ = try f.handler.execute(.invert(.key("stable-30"), .on))
        #expect(f.manager.displays.map(\.isEnabled) == [true, true, false])
        #expect(f.manager.displays.map(\.isInverted) == [false, false, true])
        let snapshot = try f.handler.execute(.displayList)
        #expect(snapshot.displays.map(\.number) == [1, 2, 3])
        #expect(snapshot.displays.map(\.key) == ["stable-10", "stable-20", "stable-30"])
    }

    @Test func rejectedSelectorsPreserveDragAndAllDisplays() {
        let f = makeFixture()
        let token = f.manager.beginSliderInteraction()
        for selector: CommandDisplaySelector in [.number(0), .number(4), .name("studio"), .name(" "), .name("missing"), .key("missing")] {
            expectError(.invalidInput) { _ = try f.handler.execute(.display(selector, .on)) }
            expectError(.invalidInput) { _ = try f.handler.execute(.invert(selector, .on)) }
            #expect(f.manager.isSliderInteractionCurrent(token))
            #expect(f.manager.displays.allSatisfy { !$0.isEnabled && !$0.isInverted })
        }
    }

    @Test func allToggleUsesAnyEnabledAndAnyInverted() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.display(.number(1), .on))
        _ = try f.handler.execute(.display(.all, .toggle))
        #expect(f.manager.displays.allSatisfy { !$0.isEnabled })
        _ = try f.handler.execute(.display(.all, .toggle))
        #expect(f.manager.displays.allSatisfy { $0.isEnabled })
        _ = try f.handler.execute(.display(.all, .off))
        _ = try f.handler.execute(.invert(.number(2), .on))
        _ = try f.handler.execute(.invert(.all, .toggle))
        #expect(f.manager.displays.allSatisfy { !$0.isInverted })
        _ = try f.handler.execute(.invert(.all, .toggle))
        #expect(f.manager.displays.allSatisfy { $0.isInverted })
        _ = try f.handler.execute(.invert(.all, .off))
        #expect(f.manager.displays.allSatisfy { !$0.isInverted })
    }

    @Test func masterRestoresSelectionAndLeavesInversionAlone() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.display(.number(2), .on))
        _ = try f.handler.execute(.invert(.number(3), .on))
        #expect(try f.handler.execute(.master(.off)).on == false)
        _ = try f.handler.execute(.master(.off))
        #expect(try f.handler.execute(.master(.on)).on)
        #expect(f.manager.displays.map(\.isEnabled) == [false, true, false])
        _ = try f.handler.execute(.master(.toggle))
        #expect(!f.manager.isOn)
        _ = try f.handler.execute(.master(.toggle))
        #expect(f.manager.isOn)
        #expect(f.manager.displays[2].isInverted)
    }

    @Test func adaptiveNudgesClampAndPresetsDisableAdaptive() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.limits(.color, min: 20, max: 70))
        _ = try f.handler.execute(.limits(.whitepoint, min: 40, max: 80))
        _ = try f.handler.execute(.adaptive(.on))
        _ = try f.handler.execute(.color(95))
        _ = try f.handler.execute(.whitepoint(25))
        #expect(f.manager.intensity == 0.7)
        #expect(f.manager.whitepoint == WhitepointScale.output(percent: 40))
        for preset in CommandPreset.allCases {
            _ = try f.handler.execute(.adaptive(.on))
            let status = try f.handler.execute(.preset(preset))
            #expect(!status.adaptive)
            #expect(status.activePreset == preset)
            #expect(f.manager.intensity == Preset.defaults[preset.index].intensity)
        }
        _ = try f.handler.execute(.adaptive(.toggle))
        #expect(f.manager.adaptiveEnabled)
        _ = try f.handler.execute(.adaptive(.off))
        #expect(!f.manager.adaptiveEnabled)
    }

    @Test func saveEveryPresetOverwritesRequestedSlot() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.color(36))
        _ = try f.handler.execute(.whitepoint(58))
        for preset in CommandPreset.allCases {
            _ = try f.handler.execute(.savePreset(preset))
            #expect(f.manager.presets[preset.index].intensity == 0.36)
            #expect(f.manager.presets[preset.index].whitepoint == WhitepointScale.output(percent: 58))
        }
        #expect(f.defaults.data(forKey: "redlight.presets") != nil)
    }

    @Test func appearanceAndLoginReadBackFailuresBecomeSystemErrors() throws {
        let f = makeFixture()
        #expect(try f.handler.execute(.appearance(.dark)).appearance == .dark)
        #expect(try f.handler.execute(.appearance(.toggle)).appearance == .light)
        _ = try f.handler.execute(.appearance(.light))
        f.state.ignoreAppearance = true
        expectError(.system) { _ = try f.handler.execute(.appearance(.dark)) }
        #expect(try f.handler.execute(.login(true)).login.enabled)
        #expect(try f.handler.execute(.login(false)).login.enabled == false)
        f.state.ignoreLogin = true
        expectError(.system) { _ = try f.handler.execute(.login(true)) }
        f.state.login.requiresApproval = true
        expectError(.system) { _ = try f.handler.execute(.login(true)) }
        f.state.failure = .system("Injected registration failure")
        expectError(.system) { _ = try f.handler.execute(.login(false)) }
    }

    @Test func updateAndQuitReplyBeforeDeferredActions() throws {
        let f = makeFixture()
        #expect(try f.handler.execute(.update).running)
        #expect(try f.handler.execute(.quit).running)
        #expect(f.state.updateCount == 0)
        #expect(f.state.quitCount == 0)
        #expect(f.state.pending.count == 2)
        for action in f.state.pending { action() }
        #expect(f.state.updateCount == 1)
        #expect(f.state.quitCount == 1)
    }

    @Test func unavailableUpdaterPreservesDragAndDoesNotScheduleAction() {
        let f = makeFixture()
        f.state.canUpdate = false
        let token = f.manager.beginSliderInteraction()
        f.manager.previewIntensity(0.1)
        expectError(.system) { _ = try f.handler.execute(.update) }
        #expect(f.manager.isSliderInteractionCurrent(token))
        #expect(f.state.pending.isEmpty)
    }

    @Test func statusAndDisplayListNeverInterruptActivePreview() throws {
        let f = makeFixture()
        let token = f.manager.beginSliderInteraction()
        f.manager.previewIntensity(0.1)
        let status = try f.handler.execute(.status)
        _ = try f.handler.execute(.displayList)
        #expect(f.manager.isSliderInteractionCurrent(token))
        #expect(status.color.set == 100)
        #expect(status.color.target == 100)
        #expect(status.version == "1.2.3-test")
    }

    @Test func levelAndLimitsCommandsEndPreviewBeforeReturning() throws {
        for command: RedlightCommand in [.color(63), .whitepoint(58), .limits(.color, min: 10, max: 60), .limits(.whitepoint, min: 40, max: 70)] {
            let f = makeFixture()
            _ = try f.handler.execute(.display(.all, .on))
            f.manager.intensity = 0.7
            f.manager.whitepoint = 0.8
            let token = f.manager.beginSliderInteraction()
            f.manager.previewIntensity(0.1)
            f.manager.previewWhitepoint(0.25)
            _ = try f.handler.execute(command)
            #expect(!f.manager.isSliderInteractionCurrent(token))
            let last = try #require(f.gamma.applyCalls.last)
            #expect(last.intensity == Float(f.manager.intensity))
            #expect(last.whitepoint == Float(f.manager.whitepoint))
            let fresh = f.manager.beginSliderInteraction()
            #expect(f.manager.isSliderInteractionCurrent(fresh))
            #expect(fresh != token)
        }
    }

    @Test func snapshotReportsFadeTargetRatherThanPartialFrame() throws {
        let location = FakeLocationProvider()
        location.coordinate = (latitude: 41.88, longitude: -87.63)
        let f = makeFixture(location: location, fadeDuration: 2)
        _ = try f.handler.execute(.adaptive(.on))
        let status = try f.handler.execute(.preset(.late))
        #expect(status.fading)
        #expect(status.color.target == 0)
        // Late's white point, 0.3 on the displays, is a fifteenth of the way up its scale.
        #expect(status.whitepoint.target == 7)
        #expect(status.elevation != nil)
        f.manager.completeOutputTransition()
        #expect(!f.handler.snapshot().fading)
    }

    @Test func presetWithAdaptiveOffReportsItsFadeUntilItLands() throws {
        let f = makeFixture(fadeDuration: 2)
        _ = try f.handler.execute(.display(.all, .on))
        let status = try f.handler.execute(.preset(.night))
        #expect(status.fading)
        #expect(!status.adaptive)
        #expect(status.activePreset == .night)
        #expect(status.color.target == 25)
        // Night's 0.45 on the displays.
        #expect(status.whitepoint.target == 27)
        f.manager.completeOutputTransition()
        #expect(!f.handler.snapshot().fading)
        // Re-applying the preset already on screen has nothing to fade.
        #expect(try !f.handler.execute(.preset(.night)).fading)
        // A level command mid-fade takes that channel over and reports the new target.
        _ = try f.handler.execute(.preset(.day))
        let level = try f.handler.execute(.color(60))
        #expect(level.activePreset == nil)
        #expect(level.color.target == 60)
        #expect(level.fading)
        f.manager.completeOutputTransition()
        #expect(!f.handler.snapshot().fading)
    }

    @Test func terminatingAppRejectsMutationsButAllowsReads() throws {
        let f = makeFixture()
        f.manager.beginTerminationFade {}
        let generation = f.manager.sliderInteractionGeneration
        let before = f.handler.snapshot()
        for command: RedlightCommand in [.color(12), .master(.on), .adaptive(.on), .login(true), .update, .quit] {
            expectError(.system) { _ = try f.handler.execute(command) }
            #expect(f.manager.sliderInteractionGeneration == generation)
            #expect(f.handler.snapshot() == before)
        }
        #expect(try f.handler.execute(.status).running)
        #expect(try f.handler.execute(.displayList).displays.count == 3)
        #expect(f.state.pending.isEmpty)
    }
}
