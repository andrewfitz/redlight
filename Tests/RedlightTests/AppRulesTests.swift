import CoreGraphics
import Foundation
import Testing
@testable import Redlight

/// Activations and wakes are delivered by hand.
@MainActor
final class FakeAppSource: AppActivationSource {
    var frontmostApp: RunningApp?
    var runningApps: [RunningApp] = []
    var names: [String: String] = [:]
    private var onActivate: ((RunningApp) -> Void)?
    private var onTerminate: ((RunningApp) -> Void)?
    private var onWake: (() -> Void)?

    init(frontmost: RunningApp? = nil) { frontmostApp = frontmost }

    func displayName(forBundleID bundleID: String) -> String? { names[bundleID] }

    func start(
        onActivate: @escaping @MainActor (RunningApp) -> Void,
        onTerminate: @escaping @MainActor (RunningApp) -> Void,
        onWake: @escaping @MainActor () -> Void
    ) {
        self.onActivate = onActivate
        self.onTerminate = onTerminate
        self.onWake = onWake
    }

    func activate(_ app: RunningApp) {
        frontmostApp = app
        onActivate?(app)
    }

    /// Leaves `frontmostApp` alone: the system may not have moved it yet, or at all.
    func terminate(_ app: RunningApp) { onTerminate?(app) }

    func wake() { onWake?() }
}

extension RunningApp {
    static let photoshop = RunningApp(bundleID: "com.adobe.Photoshop", name: "Photoshop", processID: 501)
    static let safari = RunningApp(bundleID: "com.apple.Safari", name: "Safari", processID: 502)
    static let script = RunningApp(bundleID: nil, name: "Script", processID: 503)
    static let preview = RunningApp(bundleID: "com.apple.Preview", name: "Preview", processID: 504)
    static let redlight = RunningApp(bundleID: "com.redlight.app", name: "Redlight", processID: 999)
}

extension ActiveApp {
    static func photoshop(_ rule: AppRule) -> ActiveApp {
        ActiveApp(bundleID: "com.adobe.Photoshop", processID: 501, name: "Photoshop", rule: rule)
    }
    static func preview(_ rule: AppRule) -> ActiveApp {
        ActiveApp(bundleID: "com.apple.Preview", processID: 504, name: "Preview", rule: rule)
    }
    static func photos(_ rule: AppRule) -> ActiveApp {
        ActiveApp(bundleID: "com.apple.Photos", processID: 505, name: "Photos", rule: rule)
    }
}

@MainActor
private final class Clock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    var uptime: TimeInterval = 100
}

/// A manager over a mock gamma controller, a controllable clock and its own defaults.
@MainActor
private struct Rig {
    let mock = MockGammaController()
    let defaultsRegistry = TestDefaultsRegistry()
    let clock = Clock()
    let location = FakeLocationProvider()

    func defaults() -> UserDefaults { defaultsRegistry.makeDefaults(prefix: "AppRulesTests") }

    func manager(
        defaults: UserDefaults? = nil, displayFade: TimeInterval = 0, adaptiveFade: TimeInterval = 0,
        ruleFade: TimeInterval = 0, activeApp: ActiveApp? = nil
    ) -> DisplayManager {
        let clock = clock
        return DisplayManager(
            gamma: mock,
            getDisplayIDs: { [1, 2] },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            getMainDisplayID: { 1 },
            defaults: defaults ?? self.defaults(),
            location: location,
            now: { clock.date },
            adaptiveTransitionDuration: adaptiveFade,
            displayTransitionDuration: displayFade,
            peekTransitionDuration: displayFade,
            appRuleTransitionDuration: ruleFade,
            transitionUptime: { clock.uptime },
            activeApp: activeApp
        )
    }

    func controller(source: FakeAppSource, defaults: UserDefaults? = nil) -> AppRulesController {
        AppRulesController(
            source: source, defaults: defaults ?? self.defaults(),
            ownBundleID: RunningApp.redlight.bundleID, ownProcessID: RunningApp.redlight.processID)
    }

    func handler(_ manager: DisplayManager, _ controller: AppRulesController? = nil) -> CommandHandler {
        var services = CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) }, setLogin: { _ in },
            update: {}, quit: {}, version: { "test" })
        if let controller {
            services.appRules = { controller.statusRules }
            services.changeApps = { try controller.apply($0) }
        }
        return CommandHandler(manager: manager, services: services)
    }

    /// What display 1 shows, from a fresh write of every display: (1, 1) is untinted.
    func frame(_ manager: DisplayManager, display: CGDirectDisplayID = 1) -> (intensity: Double, whitepoint: Double) {
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()
        manager.refreshDisplays()
        return lastFrame(display)
    }

    /// The last write to a display since the calls were last cleared.
    func lastFrame(_ display: CGDirectDisplayID = 1) -> (intensity: Double, whitepoint: Double) {
        guard let call = mock.applyCalls.last(where: { $0.displayID == display }) else { return (1, 1) }
        return (Double(call.intensity), Double(call.whitepoint))
    }

    func tinted(_ manager: DisplayManager) -> Bool { frame(manager).intensity < 1 }
}

private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-5) -> Bool { abs(a - b) < tolerance }

// MARK: - A Pause rule

/// A Pause rule hides the tint as Pause for apps did: the same fade level as a pause and a
/// peek, untimed, not saved and not off.
@MainActor @Suite struct AppPauseRuleTests {
    private let rig = Rig()

    private struct Reasons: CustomStringConvertible {
        var paused = false, peeking = false, pausedForApp = false
        var hidesTint: Bool { paused || peeking || pausedForApp }
        var description: String { "paused \(paused), peeking \(peeking), app \(pausedForApp)" }
    }

    private enum Step: CaseIterable { case pause, resume, peekOn, peekOff, enter, leave, expire }

    @Test func everyPausePeekAndAppCombinationSharesOneFadeTarget() {
        for start in 0..<8 {
            for step in Step.allCases {
                let manager = rig.manager()
                manager.intensity = 0.4
                manager.setEnabled(true, for: 1)
                var reasons = Reasons(paused: start & 1 != 0, peeking: start & 2 != 0, pausedForApp: start & 4 != 0)
                // A pause ends a peek, so pause first.
                if reasons.paused { manager.pause() }
                if reasons.peeking { manager.setPeeking(true) }
                if reasons.pausedForApp { manager.setActiveApp(.photoshop(.pause)) }
                #expect(rig.tinted(manager) == !reasons.hidesTint, "start: \(reasons)")

                switch step {
                case .pause: manager.pause(); reasons.paused = true; reasons.peeking = false
                case .resume: manager.resume(); reasons.paused = false
                case .peekOn: manager.setPeeking(true); reasons.peeking = true
                case .peekOff: manager.setPeeking(false); reasons.peeking = false
                case .enter: manager.setActiveApp(.photoshop(.pause)); reasons.pausedForApp = true
                case .leave: manager.setActiveApp(nil); reasons.pausedForApp = false
                case .expire:
                    rig.clock.date = rig.clock.date.addingTimeInterval(DisplayManager.Defaults.pauseDuration + 1)
                    manager.refreshPause()
                    reasons.paused = false
                }
                #expect(rig.tinted(manager) == !reasons.hidesTint, "\(step) leaves \(reasons)")
                #expect(manager.isOn)
                #expect(manager.isFiltering == !reasons.paused)
                #expect(manager.isPausedForApp == reasons.pausedForApp)
            }
        }
    }

    @Test func aPauseRuleFadesLikeAPauseAndKeepsInvert() {
        let manager = rig.manager(displayFade: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setInverted(true, for: 2)
        manager.completeDisplayTransitions()

        manager.setActiveApp(.photoshop(.pause))
        #expect(manager.commandIsFading)
        manager.advancePauseTransition(toProgress: 0.5)
        let midway = rig.lastFrame()
        #expect(midway.intensity > 0.4 && midway.intensity < 1)
        manager.advancePauseTransition(toProgress: 1)
        #expect(!manager.commandIsFading)
        #expect(!rig.tinted(manager))
        let inverted = rig.mock.applyCalls.last { $0.displayID == 2 }
        #expect(inverted?.invert == true && inverted?.intensity == 1)

        // Another app that pauses taking over is not a new fade.
        manager.setActiveApp(.preview(.pause))
        #expect(manager.activeApp?.name == "Preview")
        #expect(!manager.commandIsFading)

        manager.setActiveApp(nil)
        manager.advancePauseTransition(toProgress: 1)
        #expect(rig.tinted(manager))
    }

    @Test func aPauseRuleIsNeitherOffNorSaved() {
        let defaults = rig.defaults()
        let manager = rig.manager(defaults: defaults)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        let saved = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("redlight.") }
        manager.setActiveApp(.photoshop(.pause))
        #expect(manager.isOn)
        #expect(manager.isFiltering)
        // The menu bar icon looks paused, while the published state stays on.
        #expect(!manager.isAnyActive)
        #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("redlight.") })
                    .isEqual(to: saved))

        let relaunched = rig.manager(defaults: defaults)
        #expect(relaunched.activeApp == nil)
        #expect(rig.tinted(relaunched))
    }

    @Test func pauseStaysAvailableAndIndependentInAnAppThatPauses() {
        let manager = rig.manager()
        manager.setEnabled(true, for: 1)
        manager.setActiveApp(.photoshop(.pause))
        #expect(manager.pause())
        #expect(!manager.isFiltering)
        manager.setAll(on: true)   // "on" resumes the pause, not the app's rule
        #expect(!manager.isPaused)
        #expect(manager.isPausedForApp)
        #expect(!rig.tinted(manager))
    }

    @Test func turningOffAndOnInAnAppThatPausesNeverShowsTheTint() {
        let manager = rig.manager(displayFade: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.setActiveApp(.photoshop(.pause))
        manager.advancePauseTransition(toProgress: 1)
        rig.mock.applyCalls.removeAll()

        manager.setAll(on: false)
        manager.completeDisplayTransitions()
        manager.setAll(on: true)
        manager.advanceDisplayTransitions(toProgress: 0.5)
        manager.completeDisplayTransitions()
        manager.advancePauseTransition(toProgress: 1)
        #expect(rig.mock.applyCalls.allSatisfy { $0.intensity == 1 })
        #expect(manager.isOn)
        #expect(manager.isPausedForApp)
        #expect(!rig.tinted(manager))

        manager.setActiveApp(nil)
        manager.advancePauseTransition(toProgress: 1)
        #expect(rig.mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(0.4))
    }

    @Test func aPauseRuleArrivingWhileOffHoldsWhenTurnedOn() {
        let manager = rig.manager()
        manager.intensity = 0.4
        manager.setActiveApp(.photoshop(.pause))
        manager.setAll(on: true)
        #expect(manager.isOn)
        #expect(!rig.tinted(manager))
    }

    @Test func pauseRuleEdgesWhileOffDoNotFade() {
        let manager = rig.manager(displayFade: 1)
        manager.intensity = 0.4
        manager.setActiveApp(.photoshop(.pause))
        // Nothing is tinted, so there is nothing to fade: no icon flicker, no "fading".
        #expect(!manager.commandIsFading)
        #expect(!manager.isAnyActive)

        manager.setAll(on: true)
        manager.advanceDisplayTransitions(toProgress: 0.5)
        manager.completeDisplayTransitions()
        #expect(rig.mock.applyCalls.allSatisfy { $0.intensity == 1 })

        manager.setAll(on: false)
        manager.completeDisplayTransitions()
        manager.setActiveApp(nil)
        #expect(!manager.commandIsFading)
        #expect(!manager.isAnyActive)
    }

    @Test func leavingTheAppDuringTheTurnOffFadeNeverBringsTheTintBack() {
        let manager = rig.manager(displayFade: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.setActiveApp(.photoshop(.pause))
        manager.advancePauseTransition(toProgress: 1)

        manager.setAll(on: false)
        rig.clock.uptime += 0.3
        manager.tickTransitions()
        rig.mock.applyCalls.removeAll()
        // Cmd-Tab away while the (hidden) filter is still fading out.
        manager.setActiveApp(nil)
        for _ in 0..<12 {
            rig.clock.uptime += 0.1
            manager.tickTransitions()
        }
        #expect(rig.mock.applyCalls.allSatisfy { $0.intensity == 1 })
        #expect(!manager.commandIsFading)
        #expect(!manager.isAnyActive)

        // The level is back at 1, so turning on shows the tint again.
        manager.setAll(on: true)
        manager.completeDisplayTransitions()
        #expect(rig.tinted(manager))
    }

    @Test func settingsChangedInAnAppThatPausesShowWhenItEnds() {
        let manager = rig.manager()
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setActiveApp(.photoshop(.pause))
        manager.intensity = 0.6
        manager.applyPreset(CommandPreset.night.index)
        #expect(!rig.tinted(manager))
        manager.setActiveApp(nil)
        #expect(rig.mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(manager.intensity))
        #expect(rig.tinted(manager))
    }

    @Test func launchingWithAnAppThatPausesInFrontNeverFlashesTheTint() throws {
        let defaults = rig.defaults()
        defaults.set(0.4, forKey: "redlight.intensity")
        defaults.set(true, forKey: "redlight.display.1.enabled")
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = rig.controller(source: source, defaults: defaults)
        try controller.set("com.adobe.Photoshop", .pause)
        #expect(controller.activeApp == .photoshop(.pause))

        let manager = rig.manager(defaults: defaults, displayFade: 1, activeApp: controller.activeApp)
        controller.onChange = { manager.setActiveApp($0) }
        manager.advanceDisplayTransitions(toProgress: 0.5)
        manager.completeDisplayTransitions()
        #expect(rig.mock.applyCalls.allSatisfy { $0.intensity == 1 })
        #expect(manager.isFiltering)
        #expect(manager.isPausedForApp)

        source.activate(.safari)
        #expect(manager.activeApp == nil)
        manager.advancePauseTransition(toProgress: 1)
        #expect(rig.mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(0.4))
    }
}

// MARK: - Hold and Shift

@MainActor @Suite struct AppRuleOutputTests {
    private let rig = Rig()

    @Test func legacyRuleFractionsRoundOnDecode() throws {
        let hold = Data(#"{"hold":{"color":12.5,"whitepoint":84.49,"saturation":99.5}}"#.utf8)
        let shift = Data(#"{"shift":{"color":-2.5,"whitepoint":3.4,"saturation":-0.9}}"#.utf8)
        #expect(try JSONDecoder().decode(AppRule.self, from: hold) == .hold(color: 13, whitepoint: 84))
        #expect(try JSONDecoder().decode(AppRule.self, from: shift) == .shift(color: -3, whitepoint: 3, saturation: -1))
    }

    @Test func saturationControlUsesFullScaleToFollowGlobal() throws {
        let manager = rig.manager()
        manager.saturation = 0.4
        for enabled in [false, true] {
            manager.saturationEnabled = enabled
            for base in [AppRule.hold(color: 35, whitepoint: 65), .shift(color: -5, whitepoint: 5)] {
                #expect(manager.appSaturationPercent(base) == 100)
                for level in [0.0, 0.35, 0.95] {
                    let adjusted = manager.rule(base, showingSaturation: level)
                    #expect(adjusted.saturation != nil)
                    #expect(manager.appSaturationPercent(adjusted) == Int((level * 100).rounded()))
                    #expect(close(manager.shownOutput(editing: adjusted).saturation, level))
                    let inherited = manager.rule(adjusted, showingSaturation: 1)
                    #expect(inherited == base)
                    #expect(manager.appSaturationPercent(inherited) == 100)
                    #expect(manager.shownOutput(editing: inherited).saturation == (enabled ? 0.4 : 1))
                }
            }
        }
        #expect(try AppRule.hold(color: 35, whitepoint: 65, saturation: 100).validated()
                == .hold(color: 35, whitepoint: 65))
    }

    @Test(arguments: [false, true]) func appSaturationFadesAndRestoresTheGlobalLevel(auto: Bool) throws {
        let manager = rig.manager(ruleFade: 0.4)
        manager.adaptiveEnabled = auto
        manager.setEnabled(true, for: 1)
        manager.saturation = 0.4
        let hold = AppRule.hold(color: 70, whitepoint: 85, saturation: 0)
        manager.setActiveApp(.photoshop(hold))
        manager.advanceOutputTransition(toProgress: 0.5)
        #expect(rig.mock.saturationCalls.last { $0.displayID == 1 }?.saturation == 0.5)
        manager.completeOutputTransition()
        #expect(rig.mock.saturationCalls.last { $0.displayID == 1 }?.saturation == 0)
        #expect(rig.handler(manager).snapshot().saturation == Status.Level(set: 40, target: 0))

        let shift = AppRule.shift(color: 0, whitepoint: 0, saturation: -25)
        manager.setActiveApp(.preview(shift))
        manager.completeOutputTransition()
        #expect(manager.effectiveTarget.saturation == 0.75)
        manager.saturationEnabled = true
        #expect(close(manager.effectiveTarget.saturation, 0.15))
        manager.setActiveApp(.preview(shift.withSaturation(-100)))
        #expect(manager.effectiveTarget.saturation == 0)
        manager.setActiveApp(nil)
        manager.completeOutputTransition()
        #expect(rig.mock.saturationCalls.last { $0.displayID == 1 }?.saturation == 0.4)
        #expect(manager.saturation == 0.4 && manager.saturationEnabled)
        manager.saturationEnabled = false
        manager.setActiveApp(.photoshop(hold.withSaturation(nil)))
        manager.completeOutputTransition()
        #expect(rig.mock.saturationCalls.last { $0.displayID == 1 }?.saturation == 1)
    }

    /// The resolver's table: each rule, in Manual and in Auto, with and without a Fixed
    /// channel, and under a pause and a peek, on the displays and in the status.
    @Test func theResolverTable() {
        let rules: [AppRule?] = [nil, .pause, .hold(color: 40, whitepoint: 70),
                                 .shift(color: -20, whitepoint: 10), .shift(color: 50, whitepoint: -50)]
        for auto in [false, true] {
            for fixed in [false, true] {
                for rule in rules {
                    let defaults = rig.defaults()
                    rig.location.coordinate = (41.88, -87.63)
                    defaults.set(auto, forKey: "redlight.adaptiveEnabled")
                    defaults.set(0.6, forKey: "redlight.intensity")
                    defaults.set(0.9, forKey: "redlight.whitepoint")
                    defaults.set(fixed ? 0.5 : 0.3, forKey: "redlight.adaptiveMin")
                    defaults.set(fixed ? 0.5 : 0.8, forKey: "redlight.adaptiveMax")
                    defaults.set(fixed ? 0.8 : 0.7, forKey: "redlight.adaptiveWpMin")
                    defaults.set(fixed ? 0.8 : 0.95, forKey: "redlight.adaptiveWpMax")
                    let manager = rig.manager(defaults: defaults)
                    let handler = rig.handler(manager)
                    manager.setEnabled(true, for: 1)
                    manager.setActiveApp(rule.map { .photoshop($0) })
                    let model = (intensity: manager.intensity, whitepoint: manager.whitepoint)
                    let context = "auto \(auto), fixed \(fixed), \(rule.map { "\($0)" } ?? "no rule")"

                    func shifted(_ value: Double, _ percent: Double, band: ClosedRange<Double>,
                                 range: ClosedRange<Double>, scale: (Double) -> Double, unscale: (Double) -> Double) -> Double {
                        if auto, band.lowerBound == band.upperBound { return value }
                        let moved = min(range.upperBound, max(range.lowerBound, unscale(scale(value) + percent / 100)))
                        guard auto else { return moved }
                        return min(max(band.upperBound, value), max(min(band.lowerBound, value), moved))
                    }
                    let expected: (intensity: Double, whitepoint: Double)
                    switch rule {
                    case nil, .pause?:
                        expected = model
                    case .hold(let color, let white, _)?:
                        expected = (SliderPercent.unit(color), WhitepointScale.output(percent: Double(white)))
                    case .shift(let color, let white, _)?:
                        expected = (
                            shifted(model.intensity, Double(color), band: manager.intensityBand, range: 0...1,
                                    scale: { $0 }, unscale: { $0 }),
                            shifted(model.whitepoint, Double(white), band: manager.whitepointBand, range: 0.25...1,
                                    scale: { WhitepointScale.shown($0) }, unscale: { WhitepointScale.output($0) }))
                    }
                    #expect(close(manager.effectiveTarget.intensity, expected.intensity), "\(context)")
                    #expect(close(manager.effectiveTarget.whitepoint, expected.whitepoint), "\(context)")

                    // The status: `set` is the global target, `target` what the displays get.
                    let status = handler.snapshot()
                    #expect(close(Double(status.color.set), (model.intensity * 100).rounded()), "\(context)")
                    #expect(close(Double(status.color.target), (expected.intensity * 100).rounded()), "\(context)")
                    #expect(close(Double(status.whitepoint.target), WhitepointScale.percent(expected.whitepoint).rounded()), "\(context)")

                    // On the displays; a Pause rule, a pause and a peek show the untinted screen.
                    let shown = rig.frame(manager)
                    if rule == .pause {
                        #expect(shown == (1, 1), "\(context)")
                    } else {
                        #expect(close(shown.intensity, expected.intensity), "\(context)")
                        #expect(close(shown.whitepoint, expected.whitepoint), "\(context)")
                    }
                    manager.setPeeking(true)
                    #expect(rig.frame(manager) == (1, 1), "a peek in \(context)")
                    manager.setPeeking(false)
                    #expect(manager.pause())
                    #expect(rig.frame(manager) == (1, 1), "a pause in \(context)")
                    manager.resume()
                    if rule != .pause { #expect(close(rig.frame(manager).intensity, expected.intensity), "\(context)") }
                    // A rule never changes the model.
                    #expect(manager.intensity == model.intensity && manager.whitepoint == model.whitepoint)
                    manager.restoreAllDisplays()
                }
            }
        }
    }

    /// Scope: the displays a pause covers. A display that is off stays untouched, and one
    /// that is only inverted keeps its inversion untinted.
    @Test func aRuleReachesOnlyTheDisplaysThatAreTinted() {
        let manager = rig.manager()
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setInverted(true, for: 2)
        manager.setActiveApp(.photoshop(.hold(color: 80, whitepoint: 50)))
        #expect(close(rig.frame(manager).intensity, 0.8))
        let other = rig.mock.applyCalls.last { $0.displayID == 2 }
        #expect(other?.invert == true && other?.intensity == 1 && other?.whitepoint == 1)
    }

    /// A→B→C in quick succession: each switch starts from the frame on screen, so nothing
    /// jumps, and each takes the short fade.
    @Test func eachSwitchFadesFromTheFrameOnScreen() {
        let manager = rig.manager(adaptiveFade: 2, ruleFade: 0.4)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        var frames: [Double] = []
        func tick(_ seconds: TimeInterval) {
            rig.clock.uptime += seconds
            manager.tickTransitions()
            frames.append(rig.lastFrame().intensity)
        }
        func switchTo(_ app: ActiveApp?) {
            rig.mock.applyCalls.removeAll()
            manager.setActiveApp(app)
            frames.append(rig.lastFrame().intensity)
        }

        switchTo(.photoshop(.hold(color: 80, whitepoint: 100)))
        #expect(manager.commandIsFading)
        #expect(close(frames.last!, 0.4), "the switch starts where the screen is")
        tick(0.2)
        let midA = frames.last!
        #expect(close(midA, 0.6), "halfway to the Hold")

        switchTo(.preview(.hold(color: 20, whitepoint: 100)))
        #expect(close(frames.last!, midA), "B starts from A's frame")
        tick(0.1)
        let midB = frames.last!
        #expect(midB < midA && midB > 0.2)

        switchTo(nil)
        #expect(close(frames.last!, midB), "C starts from B's frame")
        tick(0.2)
        tick(0.2)
        #expect(!manager.commandIsFading, "a switch is the short fade, not Auto's")
        #expect(close(frames.last!, 0.4))
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(abs(a - b) < 0.25, "a jump from \(a) to \(b)")
        }
    }

    @Test func aSwitchDuringAPresetFadeCarriesOnFromWhatIsVisible() {
        let manager = rig.manager(adaptiveFade: 2, ruleFade: 0.4)
        manager.intensity = 0.9
        manager.setEnabled(true, for: 1)
        manager.applyPreset(CommandPreset.night.index)
        let preset = manager.presets[CommandPreset.night.index].intensity
        rig.clock.uptime += 1
        manager.tickTransitions()
        let mid = rig.lastFrame().intensity
        #expect(mid < 0.9 && mid > preset)

        rig.mock.applyCalls.removeAll()
        manager.setActiveApp(.photoshop(.hold(color: 100, whitepoint: 100)))
        #expect(close(rig.lastFrame().intensity, mid))
        rig.clock.uptime += 0.4
        manager.tickTransitions()
        #expect(!manager.commandIsFading)
        #expect(close(rig.frame(manager).intensity, 1))

        // Leaving fades to the preset the model landed on at once.
        manager.setActiveApp(nil)
        rig.clock.uptime += 0.4
        manager.tickTransitions()
        #expect(close(rig.frame(manager).intensity, preset))
    }

    /// Auto's 5 s tick retargets a fade that is running, at that fade's own pace.
    @Test func autosTickKeepsASwitchShort() {
        let defaults = rig.defaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        rig.location.coordinate = (41.88, -87.63)
        let manager = rig.manager(defaults: defaults, adaptiveFade: 2, ruleFade: 0.4)
        manager.setEnabled(true, for: 1)
        manager.setActiveApp(.photoshop(.hold(color: 50, whitepoint: 50)))
        rig.clock.uptime += 0.2
        manager.tickTransitions()
        #expect(manager.commandIsFading)
        manager.applyAdaptive()
        rig.clock.uptime += 0.4
        manager.tickTransitions()
        #expect(!manager.commandIsFading)
    }

    /// A new amount for the rule in front is an edit, and shows at once as a slider does.
    /// Another kind of rule for the same app is a switch.
    @Test func anEditShowsAtOnceAndAnotherKindFades() {
        let manager = rig.manager(ruleFade: 0.4)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setActiveApp(.photoshop(.hold(color: 80, whitepoint: 100)))
        rig.clock.uptime += 1
        manager.tickTransitions()
        manager.setActiveApp(.photoshop(.hold(color: 60, whitepoint: 100)))
        #expect(!manager.commandIsFading)
        #expect(close(rig.frame(manager).intensity, 0.6))
        manager.setActiveApp(.photoshop(.shift(color: 10, whitepoint: 0)))
        #expect(manager.commandIsFading)
    }

    /// An edit shows the amount that changed at once and leaves the other channel's fade
    /// running.
    @Test func anEditCancelsOnlyTheFadeOfTheAmountThatChanged() {
        let manager = rig.manager(ruleFade: 0.4)
        manager.intensity = 0.4
        manager.whitepoint = WhitepointScale.output(percent: 50)
        manager.setEnabled(true, for: 1)
        manager.setActiveApp(.photoshop(.hold(color: 80, whitepoint: 100)))
        rig.clock.uptime += 0.2
        manager.tickTransitions()
        let mid = rig.lastFrame()
        #expect(close(mid.intensity, 0.6))
        #expect(mid.whitepoint > WhitepointScale.output(percent: 50) + 0.01 && mid.whitepoint < 0.99)

        rig.mock.applyCalls.removeAll()
        manager.setActiveApp(.photoshop(.hold(color: 70, whitepoint: 100)))
        let edited = rig.lastFrame()
        #expect(close(edited.intensity, 0.7), "the edited amount shows at once")
        #expect(close(edited.whitepoint, mid.whitepoint), "the other fade carries on from where it was")
        #expect(manager.commandIsFading)
        rig.clock.uptime += 0.2
        manager.tickTransitions()
        #expect(!manager.commandIsFading)
        let end = rig.frame(manager)
        #expect(close(end.intensity, 0.7) && close(end.whitepoint, 1))
    }

    /// From a Hold into an app that pauses, the tint fades out as it was shown: the output
    /// behind it does not fade to the global value on the way, so no frame is redder than
    /// both ends. Leaving again fades in from the frame the hold kept.
    @Test func intoAnAppThatPausesTheTintFadesOutAsItWas() {
        let manager = rig.manager(displayFade: 0.7, ruleFade: 0.4)
        manager.intensity = 0.1
        manager.whitepoint = WhitepointScale.output(percent: 0)
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.setActiveApp(.photoshop(.hold(color: 80, whitepoint: 100)))
        rig.clock.uptime += 1
        manager.tickTransitions()
        #expect(close(rig.frame(manager).intensity, 0.8))

        rig.mock.applyCalls.removeAll()
        manager.setActiveApp(.preview(.pause))
        for _ in 0..<20 {
            rig.clock.uptime += 0.05
            manager.tickTransitions()
        }
        let frames = rig.mock.applyCalls.filter { $0.displayID == 1 }
        #expect(frames.contains { $0.intensity < 0.9 }, "the tint fades rather than snapping off")
        for frame in frames {
            #expect(Double(frame.intensity) >= 0.8 - 1e-6, "colour temp \(frame.intensity)")
            #expect(Double(frame.whitepoint) >= 1 - 1e-6, "white point \(frame.whitepoint)")
        }
        #expect(!manager.commandIsFading)
        #expect(!rig.tinted(manager))

        // Back to the Hold: revealed as it was, from nothing.
        rig.mock.applyCalls.removeAll()
        manager.setActiveApp(.photoshop(.hold(color: 80, whitepoint: 100)))
        for _ in 0..<20 {
            rig.clock.uptime += 0.05
            manager.tickTransitions()
        }
        for frame in rig.mock.applyCalls.filter({ $0.displayID == 1 }) {
            #expect(Double(frame.intensity) >= 0.8 - 1e-6 && Double(frame.whitepoint) >= 1 - 1e-6)
        }
        #expect(close(rig.frame(manager).intensity, 0.8))
    }

    /// Another app that pauses keeps the held frame; leaving for an app without a rule
    /// before the tint is gone fades on from it, without a jump.
    @Test func aSwitchDuringThatFadeCarriesOnFromTheHeldFrame() {
        let manager = rig.manager(displayFade: 0.7, ruleFade: 0.4)
        manager.intensity = 0.1
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.setActiveApp(.photoshop(.hold(color: 80, whitepoint: 100)))
        rig.clock.uptime += 1
        manager.tickTransitions()

        rig.mock.applyCalls.removeAll()
        manager.setActiveApp(.preview(.pause))
        rig.clock.uptime += 0.1
        manager.tickTransitions()
        manager.setActiveApp(.photos(.pause))
        rig.clock.uptime += 0.1
        manager.tickTransitions()
        #expect(rig.mock.applyCalls.allSatisfy { $0.intensity >= 0.8 - 1e-6 })
        let before = rig.lastFrame()

        rig.mock.applyCalls.removeAll()
        manager.setActiveApp(nil)
        #expect(manager.commandIsFading)
        rig.clock.uptime += 0.02
        manager.tickTransitions()
        #expect(abs(rig.lastFrame().intensity - before.intensity) < 0.05, "no jump to the global value")
        rig.clock.uptime += 1
        manager.tickTransitions()
        #expect(close(rig.frame(manager).intensity, 0.1))
    }

    /// Out of an app that pauses, the output switches at once behind the hidden tint,
    /// and the pause level's own fade reveals it: every frame is the new output, faded.
    @Test func fromAPauseToAHoldTheHoldIsRevealed() {
        let manager = rig.manager(displayFade: 0.7, ruleFade: 0.4)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.setActiveApp(.photoshop(.pause))
        manager.advancePauseTransition(toProgress: 1)
        rig.mock.applyCalls.removeAll()
        manager.setActiveApp(.preview(.hold(color: 80, whitepoint: 50)))
        for _ in 0..<10 {
            rig.clock.uptime += 0.1
            manager.tickTransitions()
        }
        let hold = (intensity: 0.8, whitepoint: WhitepointScale.output(percent: 50))
        let frames = rig.mock.applyCalls.filter { $0.displayID == 1 }
        #expect(!frames.isEmpty)
        for frame in frames {
            // Both channels at the same fraction of the Hold: the pair itself never moved.
            let level = (1 - Double(frame.intensity)) / (1 - hold.intensity)
            #expect(close(1 - level * (1 - hold.whitepoint), Double(frame.whitepoint), 1e-4))
        }
        #expect(close(rig.frame(manager).intensity, 0.8))
    }

    /// Auto off holds the frame on screen; under a rule that frame is the rule's, so the model
    /// keeps its own target instead of taking the rule in.
    @Test func autoOffInAnAppWithAShiftLeavesTheModelAlone() {
        let defaults = rig.defaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        rig.location.coordinate = (41.88, -87.63)
        let manager = rig.manager(defaults: defaults)
        manager.setEnabled(true, for: 1)
        manager.setActiveApp(.photoshop(.shift(color: -20, whitepoint: 0)))
        let model = SliderPercent.unit(manager.colorPercent)
        manager.adaptiveEnabled = false
        #expect(manager.intensity == model)
        #expect(close(manager.effectiveTarget.intensity, max(0, model - 0.2)))
        #expect(close(rig.frame(manager).intensity, max(0, model - 0.2)))
    }

    @Test func launchingWithAHoldInFrontShowsTheHoldFirst() throws {
        let defaults = rig.defaults()
        defaults.set(0.4, forKey: "redlight.intensity")
        defaults.set(true, forKey: "redlight.display.1.enabled")
        let manager = rig.manager(defaults: defaults, displayFade: 1,
                                  activeApp: .photoshop(.hold(color: 80, whitepoint: 100)))
        manager.advanceDisplayTransitions(toProgress: 0.5)
        manager.completeDisplayTransitions()
        #expect(rig.mock.applyCalls.allSatisfy { $0.intensity >= 0.8 - 1e-6 }, "never the 0.4 behind the Hold")
        #expect(close(rig.frame(manager).intensity, 0.8))
    }

    @Test func wakeRecoveryReappliesTheRule() {
        let manager = rig.manager()
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setActiveApp(.photoshop(.hold(color: 70, whitepoint: 100)))
        rig.mock.applyCalls.removeAll()
        manager.handleWake()
        #expect(close(rig.lastFrame().intensity, 0.7))
        manager.completeDisplayRecovery()
        #expect(close(rig.frame(manager).intensity, 0.7))
    }

    /// The sliders show what they edit: the rule's result, or the model's own value.
    @Test func slidersShowTheRuleTheyEditAndWriteOnlyIt() {
        let defaults = rig.defaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(0.3, forKey: "redlight.adaptiveMin")
        defaults.set(0.8, forKey: "redlight.adaptiveMax")
        rig.location.coordinate = (41.88, -87.63)
        let manager = rig.manager(defaults: defaults)
        let model = manager.intensity
        let shift = AppRule.shift(color: -10, whitepoint: 0)
        #expect(close(manager.shownOutput(editing: nil).intensity, model))
        #expect(close(manager.shownOutput(editing: shift).intensity, max(0.3, model - 0.1)))

        // A Shift takes the amount that puts the value where the slider is, inside the flags.
        let moved = manager.rule(shift, showing: 0.5, on: .color)
        #expect(close(Double(moved.amount(.color)!), 50 - (model * 100).rounded()))
        let pastFlag = manager.rule(shift, showing: 0.1, on: .color)
        #expect(close(Double(pastFlag.amount(.color)!), (min(0.3, model) * 100).rounded() - (model * 100).rounded()))
        // A Hold takes the value, in slider percent, white point on its own scale.
        #expect(manager.rule(.hold(color: 10, whitepoint: 10), showing: 0.625, on: .whitepoint)
                == .hold(color: 10, whitepoint: 50))
        // A step moves what is shown, and stops at the end of the slider.
        #expect(manager.rule(.hold(color: 40, whitepoint: 50), steppedBy: -5, on: .color) == .hold(color: 35, whitepoint: 50))
        #expect(manager.rule(.hold(color: 100, whitepoint: 50), steppedBy: 5, on: .color) == .hold(color: 100, whitepoint: 50))
        #expect(manager.intensity == model)

        // A Fixed channel takes no Shift in Auto.
        manager.adaptiveMin = 0.5
        manager.adaptiveMax = 0.5
        manager.flushBandRefresh()
        #expect(manager.rule(shift, showing: 0.9, on: .color) == shift)
    }

    /// Choosing another kind of rule in Settings starts it where the screen is in that app,
    /// so the choice alone changes nothing.
    @Test func anotherKindStartsAtWhatIsShowing() {
        let manager = rig.manager()
        manager.intensity = 0.4
        manager.whitepoint = WhitepointScale.output(percent: 90)
        let hold = AppRule.hold(color: 73, whitepoint: 40)
        let shift = AppRule.shift(color: -13, whitepoint: -7)
        for (from, kind) in [(hold, AppRule.Kind.shift), (shift, .hold), (.pause, .hold), (.pause, .shift)] {
            let next = manager.rule(kind, replacing: from)
            #expect(next.kind == kind, "\(from) to \(kind)")
            let before = manager.shownOutput(editing: from), after = manager.shownOutput(editing: next)
            #expect(close(after.intensity, before.intensity, 1e-9), "\(from) to \(kind)")
            #expect(close(after.whitepoint, before.whitepoint, 1e-9), "\(from) to \(kind)")
        }
        #expect(manager.rule(.pause, replacing: hold) == .pause)
        #expect(manager.rule(.shift, replacing: hold) == .shift(color: 33, whitepoint: -50))
        #expect(manager.rule(.hold, replacing: shift) == .hold(color: 27, whitepoint: 83))
    }

    /// A Shift held at a limit keeps its saved amount: a step or a tap that leaves the screen
    /// as it is must not rewrite it to the part that shows.
    @Test func aShiftAtALimitKeepsItsAmount() {
        let manager = rig.manager()
        manager.intensity = 0.8
        manager.whitepoint = WhitepointScale.output(percent: 90)
        // Manual: +50 over 0.8 shows the end of the slider.
        let past = AppRule.shift(color: 50, whitepoint: 30)
        #expect(manager.rule(past, steppedBy: 5, on: .color) == past)
        #expect(manager.rule(past, showing: 1, on: .color) == past)
        #expect(manager.rule(past, steppedBy: 5, on: .whitepoint) == past)
        #expect(manager.rule(past, showing: manager.shownOutput(editing: past).whitepoint, on: .whitepoint) == past)
        // A step back moves from what shows.
        #expect(manager.rule(past, steppedBy: -5, on: .color) == .shift(color: 15, whitepoint: 30))
        // A Hold tapped where it is stays as it is.
        let hold = AppRule.hold(color: 40, whitepoint: 70)
        #expect(manager.rule(hold, showing: manager.shownOutput(editing: hold).whitepoint, on: .whitepoint) == hold)

        // Auto: a Shift past the upper flag.
        let defaults = rig.defaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(0.3, forKey: "redlight.adaptiveMin")
        defaults.set(0.8, forKey: "redlight.adaptiveMax")
        rig.location.coordinate = (41.88, -87.63)
        let auto = rig.manager(defaults: defaults)
        let flagged = AppRule.shift(color: 100, whitepoint: 0)
        #expect(close(auto.shownOutput(editing: flagged).intensity, max(0.8, auto.intensity)))
        #expect(auto.rule(flagged, steppedBy: 5, on: .color) == flagged)
        #expect(auto.rule(flagged, showing: 0.9, on: .color) == flagged)
    }
}

// MARK: - The controller

@MainActor @Suite struct AppRulesControllerTests {
    private let rig = Rig()

    @Test func rulesAreSavedReadBackAndSanitised() throws {
        let defaults = rig.defaults()
        let controller = rig.controller(source: FakeAppSource(), defaults: defaults)
        try controller.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        try controller.set("com.apple.Safari", .pause)
        try controller.set("COM.ADOBE.PHOTOSHOP", .shift(color: -10, whitepoint: 5))
        #expect(controller.rules == [
            AppRuleEntry(bundleID: "com.adobe.Photoshop", rule: .shift(color: -10, whitepoint: 5)),
            AppRuleEntry(bundleID: "com.apple.Safari", rule: .pause),
        ], "a chosen app keeps its place and spelling")
        #expect(throws: CommandError.self) { try controller.set("not valid", .pause) }
        #expect(throws: CommandError.self) { try controller.set("com.apple.Notes", .hold(color: 101, whitepoint: 0)) }
        #expect(throws: CommandError.self) { try controller.set("com.apple.Notes", .shift(color: -101, whitepoint: 0)) }

        let reloaded = rig.controller(source: FakeAppSource(), defaults: defaults)
        #expect(reloaded.rules == controller.rules)
        try reloaded.remove("com.apple.SAFARI")
        #expect(throws: CommandError.invalidInput("com.apple.Safari has no rule; use redlight apps list.")) {
            try reloaded.remove("com.apple.Safari")
        }
        reloaded.clear()
        #expect(reloaded.rules.isEmpty)
        #expect(defaults.object(forKey: AppRulesController.defaultsKey) == nil)
    }

    @Test func aDamagedOrNewerSaveLosesOnlyWhatCannotBeRead() {
        let stored = #"""
        {"version":1,"rules":[
          {"bundleID":"com.adobe.Photoshop","rule":{"hold":{"color":40,"whitepoint":70}}},
          {"bundleID":"COM.ADOBE.PHOTOSHOP","rule":{"pause":{}}},
          {"bundleID":"has space","rule":{"pause":{}}},
          {"bundleID":"com.apple.Notes","rule":{"hold":{"color":400,"whitepoint":70}}},
          {"bundleID":"com.apple.Safari","rule":{"glow":{}}},
          42,
          {"bundleID":"com.apple.Preview","rule":{"shift":{"color":-10,"whitepoint":5}}}
        ]}
        """#
        #expect(AppRulesController.decode(Data(stored.utf8)) == [
            AppRuleEntry(bundleID: "com.adobe.Photoshop", rule: .hold(color: 40, whitepoint: 70)),
            AppRuleEntry(bundleID: "com.apple.Preview", rule: .shift(color: -10, whitepoint: 5)),
        ])
        #expect(AppRulesController.decode(Data(#"{"version":2,"rules":[]}"#.utf8)).isEmpty)
        #expect(AppRulesController.decode(Data("junk".utf8)).isEmpty)
        #expect(AppRulesController.decode(nil).isEmpty)
    }

    @Test func theAppInFrontIsEmittedWithItsIdentityAndRule() throws {
        let source = FakeAppSource(frontmost: .safari)
        let controller = rig.controller(source: source)
        var decisions: [ActiveApp?] = []
        controller.onChange = { decisions.append($0) }
        try controller.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        #expect(controller.activeApp == nil)

        source.activate(.photoshop)
        #expect(controller.activeApp == .photoshop(.hold(color: 40, whitepoint: 70)))
        source.activate(.script)   // no bundle identifier never matches
        #expect(controller.activeApp == nil)
        source.activate(.photoshop)
        source.activate(.photoshop)
        source.wake()
        source.activate(.safari)
        #expect(decisions == [.photoshop(.hold(color: 40, whitepoint: 70)), nil,
                              .photoshop(.hold(color: 40, whitepoint: 70)), nil], "repeats are not emitted")
    }

    @Test func bundleIDValidationIsLoose() throws {
        for valid in ["com.adobe.Photoshop", "org.mozilla.firefox", "Photoshop", String(repeating: "a", count: 255)] {
            #expect(try AppBundleID.validate(valid) == valid)
        }
        for invalid in ["", " ", "com.adobe Photoshop", " com.adobe.Photoshop", "com.adobe.Photoshop\n",
                        "tab\there", String(repeating: "a", count: 256)] {
            #expect(throws: CommandError.self) { try AppBundleID.validate(invalid) }
        }
    }

    @Test func redlightsOwnActivationKeepsTheDecision() throws {
        let source = FakeAppSource(frontmost: .safari)
        let controller = rig.controller(source: source)
        try controller.set("com.adobe.Photoshop", .pause)
        source.activate(.photoshop)
        // Opening the popover or the Shortcuts window activates Redlight.
        source.activate(.redlight)
        #expect(controller.activeApp?.name == "Photoshop")
        #expect(controller.recentApp == .photoshop)
        source.activate(RunningApp(bundleID: nil, name: "Redlight", processID: RunningApp.redlight.processID))
        #expect(controller.activeApp?.name == "Photoshop")

        // Rule changes while Redlight is in front judge the app that was in front before it.
        try controller.remove("com.adobe.Photoshop")
        #expect(controller.activeApp == nil)
        try controller.set("com.adobe.Photoshop", .shift(color: 5, whitepoint: 0))
        #expect(controller.activeApp == .photoshop(.shift(color: 5, whitepoint: 0)))
    }

    @Test func anotherRedlightProcessPreservesThePreviousAppRegardlessOfBundleIDCase() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = rig.controller(source: source)
        try controller.set("com.adobe.Photoshop", .pause)
        let otherCopy = RunningApp(bundleID: "COM.REDLIGHT.APP", name: "Redlight", processID: 1000)
        source.activate(otherCopy)
        #expect(controller.activeApp?.name == "Photoshop")
        source.runningApps = [otherCopy, .photoshop]
        #expect(controller.runningApps() == [.photoshop])
    }

    @Test func quittingTheAppInFrontEndsItsRule() throws {
        let source = FakeAppSource(frontmost: .safari)
        let controller = rig.controller(source: source)
        let manager = rig.manager()
        controller.onChange = { manager.setActiveApp($0) }
        manager.setEnabled(true, for: 1)
        try controller.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))

        // Redlight's own window takes over when the app quits, so no other app activates.
        source.activate(.photoshop)
        source.activate(.redlight)
        source.terminate(.photoshop)
        #expect(controller.activeApp == nil)
        #expect(manager.activeApp == nil)

        // Nothing activates at all, and the system still names the quit app as in front.
        source.activate(.photoshop)
        source.terminate(.photoshop)
        #expect(manager.activeApp == nil)

        // Another app quitting changes nothing.
        source.activate(.photoshop)
        source.terminate(.safari)
        #expect(manager.activeApp?.name == "Photoshop")

        // Another app with a rule already in front takes over.
        try controller.set("com.apple.Safari", .pause)
        source.frontmostApp = .safari
        source.terminate(.photoshop)
        #expect(manager.activeApp?.name == "Safari")
        #expect(manager.isPausedForApp)
    }

    @Test func ruleChangesApplyToTheAppInFrontAtOnce() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = rig.controller(source: source)
        let manager = rig.manager()
        controller.onChange = { manager.setActiveApp($0) }
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)

        try controller.apply(.set("com.adobe.photoshop", .hold(color: 70, whitepoint: 100)))
        #expect(close(rig.frame(manager).intensity, 0.7))
        try controller.apply(.set("com.adobe.Photoshop", .pause))
        #expect(manager.isPausedForApp)
        try controller.apply(.remove("com.adobe.Photoshop"))
        #expect(manager.activeApp == nil)
        try controller.apply(.set("com.adobe.Photoshop", .pause))
        try controller.apply(.clear)
        #expect(manager.activeApp == nil)
        #expect(close(rig.frame(manager).intensity, 0.4))
    }

    @Test func launchWakeAndSessionActivationJudgeTheAppInFront() throws {
        let defaults = rig.defaults()
        let seed = rig.controller(source: FakeAppSource(), defaults: defaults)
        try seed.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        #expect(rig.controller(source: FakeAppSource(frontmost: .redlight), defaults: defaults).activeApp == nil)
        #expect(rig.controller(source: FakeAppSource(frontmost: nil), defaults: defaults).activeApp == nil)
        #expect(rig.controller(source: FakeAppSource(frontmost: .photoshop), defaults: defaults).activeApp != nil)

        let source = FakeAppSource(frontmost: .safari)
        let controller = rig.controller(source: source, defaults: defaults)
        #expect(controller.activeApp == nil)
        // An activation missed during sleep, or in another login session.
        source.frontmostApp = .photoshop
        source.wake()
        #expect(controller.activeApp?.name == "Photoshop")
        source.frontmostApp = nil
        source.wake()
        #expect(controller.activeApp == nil)
        #expect(controller.recentBundleID == nil)
    }

    @Test func namesAndCandidatesForSettings() throws {
        let source = FakeAppSource(frontmost: .safari)
        source.names = ["com.adobe.Photoshop": "Adobe Photoshop"]
        source.runningApps = [.safari, .redlight, .photoshop, .script]
        let controller = rig.controller(source: source)
        #expect(controller.name(for: "com.adobe.Photoshop") == "Adobe Photoshop")
        #expect(controller.name(for: "com.example.Missing") == "com.example.Missing")
        #expect(controller.runningApps() == [.safari, .photoshop, .script])
        #expect(controller.recentBundleID == "com.apple.Safari")
        try controller.set("com.adobe.Photoshop", .pause)
        #expect(controller.statusRules == [Status.App(bundleID: "com.adobe.Photoshop", name: "Adobe Photoshop", rule: .pause)])

        // An app without a bundle ID can have no rule, so it is not offered.
        let duplicateSafari = RunningApp(bundleID: "com.apple.Safari", name: "Safari", processID: 600)
        let notes = RunningApp(bundleID: "com.apple.Notes", name: "Notes", processID: 601)
        let candidates = AppCandidates.candidates(
            running: [notes, .photoshop, .safari, .script, duplicateSafari,
                      RunningApp(bundleID: "invalid id", name: "Unavailable", processID: 602)],
            chosen: ["COM.ADOBE.PHOTOSHOP"], recent: "com.apple.Safari")
        #expect(candidates == [.safari, notes])
    }

    @Test func ruleAmountsAndWords() {
        #expect(AppRule.hold(color: 40, whitepoint: 70).text == "hold color temp 40%, white point 70%")
        #expect(AppRule.shift(color: -10, whitepoint: 3).text == "shift color temp −10%, white point +3%")
        #expect(AppRule.shift(color: 0, whitepoint: 0).text == "shift color temp 0%, white point 0%")
        #expect(AppRule.pause.text == "pause")
        #expect(AppRule.hold(color: 40, whitepoint: 70).with(.color, 140) == .hold(color: 100, whitepoint: 70))
        #expect(AppRule.shift(color: 0, whitepoint: 0).with(.whitepoint, -140) == .shift(color: 0, whitepoint: -100))
        #expect(AppRule.pause.with(.color, 10) == .pause)
    }
}

// MARK: - Commands

@MainActor @Suite struct AppRuleCommandTests {
    private let rig = Rig()

    @Test func appsCommandsSetRulesAndReportTheAppInFront() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = rig.controller(source: source)
        let manager = rig.manager()
        controller.onChange = { manager.setActiveApp($0) }
        let handler = rig.handler(manager, controller)
        _ = try handler.execute(.master(.on))
        _ = try handler.execute(.color(40))

        let before = try handler.execute(.status)
        #expect(before.appRules.isEmpty && before.activeApp == nil)
        let held = try handler.execute(.apps(.set("com.adobe.Photoshop", .hold(color: 70, whitepoint: 100))))
        #expect(held.appRules == [Status.App(bundleID: "com.adobe.Photoshop", name: "com.adobe.Photoshop",
                                             rule: .hold(color: 70, whitepoint: 100))])
        #expect(held.activeApp == Status.App(bundleID: "com.adobe.Photoshop", name: "Photoshop",
                                             rule: .hold(color: 70, whitepoint: 100)))
        #expect(close(Double(held.color.set), 40) && close(Double(held.color.target), 70))
        #expect(held.statusLine == "Photoshop: hold")
        #expect(try handler.execute(.appsList).appRules.count == 1)

        // Off, no rule is shaping the tint, so none is reported.
        #expect(try handler.execute(.master(.off)).activeApp == nil)
        #expect(try handler.execute(.master(.on)).activeApp != nil)

        // The command line's colour and steps stay global under a Hold.
        let stepped = try handler.execute(.step(.color, -10))
        #expect(close(Double(stepped.color.set), 30) && close(Double(stepped.color.target), 70))
        #expect(controller.rule(for: "com.adobe.Photoshop") == .hold(color: 70, whitepoint: 100))

        let token = manager.beginSliderInteraction()
        #expect(throws: CommandError.self) { try handler.execute(.apps(.set("has space", .pause))) }
        #expect(throws: CommandError.self) { try handler.execute(.apps(.set("com.apple.Notes", .shift(color: 101, whitepoint: 0)))) }
        #expect(throws: CommandError.self) { try handler.execute(.apps(.remove("com.apple.Safari"))) }
        _ = try handler.execute(.appsList)
        #expect(manager.isSliderInteractionCurrent(token), "a refused command interrupts nothing")
        do { _ = try handler.execute(.apps(.set("", .pause))) } catch let error as CommandError { #expect(error.exitCode == 1) }

        #expect(try handler.execute(.apps(.remove("COM.ADOBE.PHOTOSHOP"))).activeApp == nil)
        _ = try handler.execute(.apps(.set("com.apple.Safari", .pause)))
        _ = try handler.execute(.apps(.set("com.adobe.Photoshop", .shift(color: -5, whitepoint: 5))))
        let cleared = try handler.execute(.apps(.clear))
        #expect(cleared.appRules.isEmpty && cleared.activeApp == nil)
    }

    @Test func appsCommandsNeedTheController() {
        let handler = rig.handler(rig.manager())
        #expect(throws: CommandError.self) { try handler.execute(.apps(.set("com.adobe.Photoshop", .pause))) }
        #expect((try? handler.execute(.appsList))?.appRules == [])
    }

    @Test func popoverAppActionsReachTheRules() {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = rig.controller(source: source)
        let manager = rig.manager()
        controller.onChange = { manager.setActiveApp($0) }
        let dispatch = PopoverCommandDispatch(handler: rig.handler(manager, controller))
        #expect(dispatch.execute(.apps(.set("com.adobe.Photoshop", .pause))) == nil)
        #expect(manager.isPausedForApp)
        #expect(dispatch.execute(.apps(.remove("com.adobe.Photoshop"))) == nil)
        #expect(manager.activeApp == nil)
        #expect(dispatch.execute(.apps(.remove("com.adobe.Photoshop")))?.contains("has no rule") == true)
    }
}

// MARK: - The popover

/// The popover takes the app it was opened over once; its sliders edit that app's Hold or
/// Shift until "Edit Auto instead", or until the app quits.
@MainActor @Suite struct PopoverAppContextTests {
    private let rig = Rig()

    @Test func theContextIsTakenAtOpeningAndEndsWhenTheAppQuits() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = rig.controller(source: source)
        try controller.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        source.activate(.redlight)   // the popover opening
        let context = PopoverAppContext(apps: controller)
        let target = PopoverAppContext.Target(bundleID: "com.adobe.Photoshop", name: "Photoshop",
                                              rule: .hold(color: 40, whitepoint: 70))
        #expect(context.target == target)
        #expect(context.editing == target)
        #expect(AppRuleLine.title(target) == "Photoshop: Hold")

        context.editsGlobal = true
        #expect(context.editing == nil && context.target == target)
        context.editsGlobal = false

        // A Pause has nothing for the sliders to set.
        try controller.set("com.adobe.Photoshop", .pause)
        #expect(context.target == nil)
        try controller.set("com.adobe.Photoshop", .shift(color: 5, whitepoint: 0))
        #expect(context.editing?.rule == .shift(color: 5, whitepoint: 0))

        source.terminate(.photoshop)
        #expect(context.target == nil && context.editing == nil)
    }

    @Test func anAppOpenedOverWithoutARuleLeavesTheSlidersOnAuto() throws {
        let source = FakeAppSource(frontmost: .safari)
        let controller = rig.controller(source: source)
        try controller.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        let context = PopoverAppContext(apps: controller)
        #expect(context.target == nil)
        // Another app coming to the front does not move a popover that is open.
        source.activate(.photoshop)
        #expect(context.target == nil)
        #expect(PopoverAppContext(apps: nil).target == nil)
    }

    /// A slider gesture decides once, as it begins, what it sets. One that loses its rule
    /// midway drops the rest rather than moving Auto or Manual; one that began on Auto or
    /// Manual stays there when a rule arrives.
    @Test func aDragKeepsTheTargetItBeganWith() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = rig.controller(source: source)
        let manager = rig.manager()
        controller.onChange = { manager.setActiveApp($0) }
        manager.intensity = 0.6
        try controller.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        let context = PopoverAppContext(apps: controller)
        func drag(to value: Double) {
            context.write(manager, showing: value, on: .color) { manager.setIntensityPushingBand(value) }
        }

        context.beginInteraction()
        drag(to: 0.5)
        #expect(controller.rule(for: "com.adobe.Photoshop") == .hold(color: 50, whitepoint: 70))
        // The command line removes the rule mid-drag.
        try controller.remove("com.adobe.Photoshop")
        drag(to: 0.3)
        #expect(manager.intensity == 0.6, "the rest of the drag is dropped")
        // The next gesture sets Manual, and a rule arriving midway does not take it over.
        context.beginInteraction()
        drag(to: 0.55)
        #expect(close(manager.intensity, 0.55))
        try controller.set("com.adobe.Photoshop", .hold(color: 40, whitepoint: 70))
        drag(to: 0.5)
        #expect(close(manager.intensity, 0.5))
        #expect(controller.rule(for: "com.adobe.Photoshop") == .hold(color: 40, whitepoint: 70))

        // The app quitting mid-drag drops the rest too.
        context.beginInteraction()
        drag(to: 0.3)
        #expect(controller.rule(for: "com.adobe.Photoshop") == .hold(color: 30, whitepoint: 70))
        source.terminate(.photoshop)
        drag(to: 0.2)
        #expect(close(manager.intensity, 0.5))
    }

    /// A drag that edits a rule writes the rule, never the model, and is no learning nudge.
    @Test func aRuleDragLeavesTheModelAndLearningAlone() throws {
        let defaults = rig.defaults()
        defaults.set(true, forKey: "redlight.adaptiveEnabled")
        defaults.set(true, forKey: "redlight.learningEnabled")
        rig.location.coordinate = (41.88, -87.63)
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = rig.controller(source: source, defaults: defaults)
        let manager = rig.manager(defaults: defaults)
        controller.onChange = { manager.setActiveApp($0) }
        manager.setEnabled(true, for: 1)
        try controller.set("com.adobe.Photoshop", .shift(color: 0, whitepoint: 0))
        let context = PopoverAppContext(apps: controller)
        let model = (manager.intensity, manager.whitepoint)
        let learned = manager.learnedModel
        let revision = manager.learningRevision

        context.set(manager, showing: max(manager.intensityBand.lowerBound, model.0 - 0.1), on: .color)
        context.set(manager, showing: 0.9, on: .whitepoint)
        #expect(controller.rule(for: "com.adobe.Photoshop") != .shift(color: 0, whitepoint: 0))
        #expect(manager.intensity == model.0 && manager.whitepoint == model.1)
        #expect(manager.learnedModel == learned)
        #expect(manager.learningRevision == revision)
        #expect(close(manager.effectiveTarget.intensity, max(manager.intensityBand.lowerBound, model.0 - 0.1)))

        context.editsGlobal = true
        context.set(manager, showing: 0.2, on: .color)
        #expect(manager.intensity == model.0, "editing Auto is the sliders' own path, not this one")
    }
}

/// Not main-actor isolated: the CLI runs its client off the main actor.
@Suite struct AppRulesCLITests {
    @Test func cliPrintsOneRulePerLineBundleIDFirst() async throws {
        let rules = [
            Status.App(bundleID: "com.adobe.Photoshop", name: "Photoshop", rule: .hold(color: 40, whitepoint: 70)),
            Status.App(bundleID: "com.example.Gone", name: "com.example.Gone", rule: .shift(color: -10, whitepoint: 5)),
            Status.App(bundleID: "com.apple.Photos", name: "Photos", rule: .pause),
        ]
        let client = CommandClient(hasPort: { true }, send: { _ in Status(on: true, version: "1.7", appRules: rules) })
        var output: [String] = []
        #expect(await RedlightCLI.run(arguments: ["apps", "list"], client: client, writeOutput: { output.append($0) }) == 0)
        #expect(output == ["""
            com.adobe.Photoshop (Photoshop): hold color temp 40%, white point 70%
            com.example.Gone: shift color temp −10%, white point +5%
            com.apple.Photos (Photos): pause
            """])
        output.removeAll()
        #expect(await RedlightCLI.run(arguments: ["apps", "list", "--json"], client: client, writeOutput: { output.append($0) }) == 0)
        let json = try #require(output.first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let first = try #require((object["appRules"] as? [[String: Any]])?.first)
        #expect(first["bundleID"] as? String == "com.adobe.Photoshop")
        #expect((first["rule"] as? [String: Any])?["hold"] != nil)
        output.removeAll()
        #expect(await RedlightCLI.run(arguments: ["apps", "set", "com.apple.Notes", "pause"], client: client,
                                      writeOutput: { output.append($0) }) == 0)
        #expect(output.isEmpty)

        let empty = CommandClient(hasPort: { true }, send: { _ in Status(on: true) })
        #expect(await RedlightCLI.run(arguments: ["apps", "list"], client: empty, writeOutput: { output.append($0) }) == 0)
        #expect(output.isEmpty)
    }

    /// The status line ends with the app in front and its rule; in Manual, where Auto's part
    /// is empty, the app's part stands alone.
    @Test func theStatusLineNamesTheAppInFrontAndItsRule() async {
        let photoshop = Status.App(bundleID: "com.adobe.Photoshop", name: "Photoshop", rule: .hold(color: 40, whitepoint: 70))
        #expect(CommandHandler.statusLine("Following the sun · +4.2°", activeApp: photoshop)
                == "Following the sun · +4.2° · Photoshop: hold")
        #expect(CommandHandler.statusLine("", activeApp: photoshop) == "Photoshop: hold")
        #expect(CommandHandler.statusLine("Following the sun · +4.2°", activeApp: nil) == "Following the sun · +4.2°")

        let held = Status(on: true, statusLine: "Following the sun · +4.2° · Photoshop: hold", version: "1.7",
                          activeApp: photoshop)
        var output = ""
        _ = await RedlightCLI.run(arguments: ["status"], client: CommandClient(hasPort: { true }, send: { _ in held }),
                                  writeOutput: { output = $0 })
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "Redlight 1.7: on")
        #expect(lines.contains("Following the sun · +4.2° · Photoshop: hold"))
        #expect(redlightStatusText(held).contains("\nFollowing the sun · +4.2° · Photoshop: hold"))
    }
}
