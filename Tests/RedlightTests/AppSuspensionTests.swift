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
    static let redlight = RunningApp(bundleID: "com.redlight.app", name: "Redlight", processID: 999)
}

@MainActor
private final class Clock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    var uptime: TimeInterval = 100
}

@MainActor @Suite struct AppSuspensionTests {
    let mock = MockGammaController()
    let defaultsRegistry = TestDefaultsRegistry()
    private let clock = Clock()

    func makeManager(
        defaults: UserDefaults? = nil, fadeDuration: TimeInterval = 0, suspendedForApp: String? = nil
    ) -> DisplayManager {
        let clock = clock
        return DisplayManager(
            gamma: mock,
            getDisplayIDs: { [1, 2] },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { String($0) },
            getMainDisplayID: { 1 },
            defaults: defaults ?? defaultsRegistry.makeDefaults(prefix: "AppSuspensionTests"),
            location: FakeLocationProvider(),
            now: { clock.date },
            adaptiveTransitionDuration: 0,
            displayTransitionDuration: fadeDuration,
            peekTransitionDuration: fadeDuration,
            transitionUptime: { clock.uptime },
            suspendedForApp: suspendedForApp
        )
    }

    func makeController(
        source: FakeAppSource, defaults: UserDefaults? = nil
    ) -> AppSuspensionController {
        AppSuspensionController(
            source: source, defaults: defaults ?? defaultsRegistry.makeDefaults(prefix: "AppSuspensionTests"),
            ownBundleID: RunningApp.redlight.bundleID, ownProcessID: RunningApp.redlight.processID)
    }

    /// Whether display 1 currently shows the tint, from a fresh write of every display.
    func tinted(_ manager: DisplayManager) -> Bool {
        mock.applyCalls.removeAll()
        mock.restoreCalls.removeAll()
        manager.refreshDisplays()
        return mock.applyCalls.contains { $0.displayID == 1 && $0.intensity < 1 }
    }

    // MARK: - Model

    private struct Reasons: CustomStringConvertible {
        var paused = false, peeking = false, suspended = false
        var hidesTint: Bool { paused || peeking || suspended }
        var description: String { "paused \(paused), peeking \(peeking), suspended \(suspended)" }
    }

    private enum Step: CaseIterable { case pause, resume, peekOn, peekOff, suspend, unsuspend, expire }

    @Test func everyPausePeekAndAppCombinationSharesOneFadeTarget() {
        for start in 0..<8 {
            for step in Step.allCases {
                let manager = makeManager()
                manager.intensity = 0.4
                manager.setEnabled(true, for: 1)
                var reasons = Reasons(paused: start & 1 != 0, peeking: start & 2 != 0, suspended: start & 4 != 0)
                // A pause ends a peek, so pause first.
                if reasons.paused { manager.pause() }
                if reasons.peeking { manager.setPeeking(true) }
                if reasons.suspended { manager.setSuspendedForApp("Photoshop") }
                #expect(tinted(manager) == !reasons.hidesTint, "start: \(reasons)")

                switch step {
                case .pause: manager.pause(); reasons.paused = true; reasons.peeking = false
                case .resume: manager.resume(); reasons.paused = false
                case .peekOn: manager.setPeeking(true); reasons.peeking = true
                case .peekOff: manager.setPeeking(false); reasons.peeking = false
                case .suspend: manager.setSuspendedForApp("Photoshop"); reasons.suspended = true
                case .unsuspend: manager.setSuspendedForApp(nil); reasons.suspended = false
                case .expire:
                    clock.date = clock.date.addingTimeInterval(DisplayManager.Defaults.pauseDuration + 1)
                    manager.refreshPause()
                    reasons.paused = false
                }
                #expect(tinted(manager) == !reasons.hidesTint, "\(step) leaves \(reasons)")
                #expect(manager.isOn)
                #expect(manager.isFiltering == !reasons.paused)
                #expect((manager.suspendedForApp != nil) == reasons.suspended)
            }
        }
    }

    @Test func appSuspensionFadesLikeAPauseAndKeepsInvert() {
        let manager = makeManager(fadeDuration: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setInverted(true, for: 2)
        manager.completeDisplayTransitions()

        manager.setSuspendedForApp("Photoshop")
        #expect(manager.commandIsFading)
        manager.advancePauseTransition(toProgress: 0.5)
        let midway = try! #require(mock.applyCalls.last { $0.displayID == 1 })
        #expect(midway.intensity > 0.4 && midway.intensity < 1)
        manager.advancePauseTransition(toProgress: 1)
        #expect(!manager.commandIsFading)
        #expect(!tinted(manager))
        let inverted = mock.applyCalls.last { $0.displayID == 2 }
        #expect(inverted?.invert == true && inverted?.intensity == 1)

        // Another chosen app taking over is not a new fade.
        manager.setSuspendedForApp("Preview")
        #expect(manager.suspendedForApp == "Preview")
        #expect(!manager.commandIsFading)

        manager.setSuspendedForApp(nil)
        manager.advancePauseTransition(toProgress: 1)
        #expect(tinted(manager))
    }

    @Test func appSuspensionIsNeitherOffNorSaved() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "AppSuspensionTests")
        let manager = makeManager(defaults: defaults)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        let saved = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("redlight.") }
        manager.setSuspendedForApp("Photoshop")
        #expect(manager.isOn)
        #expect(manager.isFiltering)
        #expect(defaults.bool(forKey: "redlight.isOn"))
        // The menu bar icon looks paused, while the published state stays on.
        #expect(!manager.isAnyActive)
        #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("redlight.") })
                    .isEqual(to: saved))

        let relaunched = makeManager(defaults: defaults)
        #expect(relaunched.suspendedForApp == nil)
        #expect(tinted(relaunched))
    }

    @Test func pauseStaysAvailableAndIndependentWhileSuspended() {
        let manager = makeManager()
        manager.setEnabled(true, for: 1)
        manager.setSuspendedForApp("Photoshop")
        #expect(manager.pause())
        #expect(!manager.isFiltering)
        manager.setAll(on: true)   // "on" resumes the pause, not the app suspension
        #expect(!manager.isPaused)
        #expect(manager.suspendedForApp == "Photoshop")
        #expect(!tinted(manager))
    }

    @Test func turningOffAndOnWhileSuspendedNeverShowsTheTint() {
        let manager = makeManager(fadeDuration: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.setSuspendedForApp("Photoshop")
        manager.advancePauseTransition(toProgress: 1)
        mock.applyCalls.removeAll()

        manager.setAll(on: false)
        manager.completeDisplayTransitions()
        manager.setAll(on: true)
        manager.advanceDisplayTransitions(toProgress: 0.5)
        manager.completeDisplayTransitions()
        manager.advancePauseTransition(toProgress: 1)
        #expect(mock.applyCalls.allSatisfy { $0.intensity == 1 })
        #expect(manager.isOn)
        #expect(manager.suspendedForApp == "Photoshop")
        #expect(!tinted(manager))

        manager.setSuspendedForApp(nil)
        manager.advancePauseTransition(toProgress: 1)
        #expect(mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(0.4))
    }

    @Test func suspensionArrivingWhileOffHoldsWhenTurnedOn() {
        let manager = makeManager()
        manager.intensity = 0.4
        manager.setSuspendedForApp("Photoshop")
        manager.setAll(on: true)
        #expect(manager.isOn)
        #expect(!tinted(manager))
    }

    @Test func suspensionEdgesWhileOffDoNotFade() {
        let manager = makeManager(fadeDuration: 1)
        manager.intensity = 0.4
        manager.setSuspendedForApp("Photoshop")
        // Nothing is tinted, so there is nothing to fade: no icon flicker, no "fading".
        #expect(!manager.commandIsFading)
        #expect(!manager.isAnyActive)

        manager.setAll(on: true)
        manager.advanceDisplayTransitions(toProgress: 0.5)
        manager.completeDisplayTransitions()
        #expect(mock.applyCalls.allSatisfy { $0.intensity == 1 })

        manager.setAll(on: false)
        manager.completeDisplayTransitions()
        manager.setSuspendedForApp(nil)
        #expect(!manager.commandIsFading)
        #expect(!manager.isAnyActive)
    }

    @Test func leavingTheAppDuringTheTurnOffFadeNeverBringsTheTintBack() {
        let manager = makeManager(fadeDuration: 1)
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.completeDisplayTransitions()
        manager.setSuspendedForApp("Photoshop")
        manager.advancePauseTransition(toProgress: 1)

        manager.setAll(on: false)
        clock.uptime += 0.3
        manager.tickTransitions()
        mock.applyCalls.removeAll()
        // Cmd-Tab away while the (hidden) filter is still fading out.
        manager.setSuspendedForApp(nil)
        for _ in 0..<12 {
            clock.uptime += 0.1
            manager.tickTransitions()
        }
        #expect(mock.applyCalls.allSatisfy { $0.intensity == 1 })
        #expect(!manager.commandIsFading)
        #expect(!manager.isAnyActive)

        // The level is back at 1, so turning on shows the tint again.
        manager.setAll(on: true)
        manager.completeDisplayTransitions()
        #expect(tinted(manager))
    }

    @Test func settingsChangedWhileSuspendedShowWhenItEnds() {
        let manager = makeManager()
        manager.intensity = 0.4
        manager.setEnabled(true, for: 1)
        manager.setSuspendedForApp("Photoshop")
        manager.intensity = 0.6
        manager.applyPreset(CommandPreset.night.index)
        #expect(!tinted(manager))
        manager.setSuspendedForApp(nil)
        #expect(mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(manager.intensity))
        #expect(tinted(manager))
    }

    @Test func launchingWithAChosenAppInFrontNeverFlashesTheTint() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "AppSuspensionTests")
        defaults.set(0.4, forKey: "redlight.intensity")
        defaults.set(true, forKey: "redlight.display.1.enabled")
        defaults.set([RunningApp.photoshop.bundleID!], forKey: AppSuspensionController.defaultsKey)
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = makeController(source: source, defaults: defaults)
        #expect(controller.suspendedFor == "Photoshop")

        let manager = makeManager(defaults: defaults, fadeDuration: 1, suspendedForApp: controller.suspendedFor)
        controller.onChange = { manager.setSuspendedForApp($0) }
        manager.advanceDisplayTransitions(toProgress: 0.5)
        manager.completeDisplayTransitions()
        #expect(mock.applyCalls.allSatisfy { $0.intensity == 1 })
        #expect(manager.isFiltering)
        #expect(manager.suspendedForApp == "Photoshop")

        source.activate(.safari)
        #expect(manager.suspendedForApp == nil)
        manager.advancePauseTransition(toProgress: 1)
        #expect(mock.applyCalls.last { $0.displayID == 1 }?.intensity == Float(0.4))
    }

    // MARK: - Controller

    @Test func listIsSavedSanitisedAndDeduplicated() throws {
        let defaults = defaultsRegistry.makeDefaults(prefix: "AppSuspensionTests")
        defaults.set(["com.adobe.Photoshop", "COM.ADOBE.PHOTOSHOP", "", "has space", 42,
                      String(repeating: "a", count: 256), "com.apple.Safari"] as [Any],
                     forKey: AppSuspensionController.defaultsKey)
        let controller = makeController(source: FakeAppSource(), defaults: defaults)
        #expect(controller.bundleIDs == ["com.adobe.Photoshop", "com.apple.Safari"])
        #expect(controller.contains("com.ADOBE.photoshop"))

        try controller.add("com.apple.Photos")
        try controller.add("COM.APPLE.PHOTOS")   // already chosen: nothing to do
        #expect(controller.bundleIDs == ["com.adobe.Photoshop", "com.apple.Safari", "com.apple.Photos"])
        #expect(defaults.stringArray(forKey: AppSuspensionController.defaultsKey) == controller.bundleIDs)
        #expect(throws: CommandError.self) { try controller.add("not valid") }
        #expect(throws: CommandError.self) { try controller.add("") }
        try controller.remove("com.apple.SAFARI")
        #expect(controller.bundleIDs == ["com.adobe.Photoshop", "com.apple.Photos"])
        #expect(throws: CommandError.invalidInput("com.apple.Safari is not in the list; use redlight apps list.")) {
            try controller.remove("com.apple.Safari")
        }

        let reloaded = makeController(source: FakeAppSource(), defaults: defaults)
        #expect(reloaded.bundleIDs == ["com.adobe.Photoshop", "com.apple.Photos"])
        reloaded.clear()
        #expect(reloaded.bundleIDs.isEmpty)
        #expect(defaults.object(forKey: AppSuspensionController.defaultsKey) == nil)

        defaults.set("com.adobe.Photoshop", forKey: AppSuspensionController.defaultsKey)
        #expect(makeController(source: FakeAppSource(), defaults: defaults).bundleIDs.isEmpty)
    }

    @Test func sanitizingPreservesTheFirstSpellingOfEachBundleID() {
        let ids = ["test.Straße", "TEST.STRASSE", "org.Notes", "org.notes"]
        #expect(AppSuspensionController.sanitized(ids) == ["test.Straße", "org.Notes"])
    }

    @Test func identicalActivationsDoNotRepublishTheSuspension() throws {
        let source = FakeAppSource(frontmost: .safari)
        let controller = makeController(source: source)
        try controller.add("com.adobe.Photoshop")
        var decisions: [String?] = []
        controller.onChange = { decisions.append($0) }
        source.activate(.safari)
        source.activate(.photoshop)
        source.wake()
        source.activate(.redlight)
        source.activate(.safari)
        #expect(decisions == ["Photoshop", nil])
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

    @Test func activationsOfChosenAppsSuspendAndOthersResume() throws {
        let source = FakeAppSource(frontmost: .safari)
        let controller = makeController(source: source)
        var decisions: [String?] = []
        controller.onChange = { decisions.append($0) }
        try controller.add("com.adobe.Photoshop")
        #expect(controller.suspendedFor == nil)

        source.activate(.photoshop)
        #expect(controller.suspendedFor == "Photoshop")
        source.activate(.script)   // no bundle identifier never matches
        #expect(controller.suspendedFor == nil)
        source.activate(.photoshop)
        source.activate(.safari)
        #expect(controller.suspendedFor == nil)
        #expect(decisions.last == .some(nil))
        #expect(decisions.contains("Photoshop"))
    }

    @Test func redlightsOwnActivationKeepsTheDecision() throws {
        let source = FakeAppSource(frontmost: .safari)
        let controller = makeController(source: source)
        try controller.add("com.adobe.Photoshop")
        source.activate(.photoshop)
        // Opening the Shortcuts window activates Redlight; the popover may too.
        source.activate(.redlight)
        #expect(controller.suspendedFor == "Photoshop")
        source.activate(RunningApp(bundleID: nil, name: "Redlight", processID: RunningApp.redlight.processID))
        #expect(controller.suspendedFor == "Photoshop")

        // List changes while Redlight is in front judge the app that was in front before it.
        try controller.remove("com.adobe.Photoshop")
        #expect(controller.suspendedFor == nil)
        try controller.add("com.adobe.Photoshop")
        #expect(controller.suspendedFor == "Photoshop")
    }

    @Test func anotherRedlightProcessPreservesThePreviousAppRegardlessOfBundleIDCase() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = makeController(source: source)
        try controller.add("com.adobe.Photoshop")
        let otherCopy = RunningApp(bundleID: "COM.REDLIGHT.APP", name: "Redlight", processID: 1000)
        source.activate(otherCopy)
        #expect(controller.suspendedFor == "Photoshop")
        source.runningApps = [otherCopy, .photoshop]
        #expect(controller.runningApps() == [.photoshop])
    }

    @Test func quittingTheChosenAppInFrontEndsTheSuspension() throws {
        let source = FakeAppSource(frontmost: .safari)
        let controller = makeController(source: source)
        let manager = makeManager()
        controller.onChange = { manager.setSuspendedForApp($0) }
        manager.setEnabled(true, for: 1)
        try controller.add("com.adobe.Photoshop")

        // Redlight's own window takes over when the app quits, so no other app activates.
        source.activate(.photoshop)
        source.activate(.redlight)
        source.terminate(.photoshop)
        #expect(controller.suspendedFor == nil)
        #expect(manager.suspendedForApp == nil)

        // Nothing activates at all, and the system still names the quit app as in front.
        source.activate(.photoshop)
        source.terminate(.photoshop)
        #expect(manager.suspendedForApp == nil)

        // Another app quitting changes nothing.
        source.activate(.photoshop)
        source.terminate(.safari)
        #expect(manager.suspendedForApp == "Photoshop")

        // Another chosen app already in front keeps the tint hidden.
        try controller.add("com.apple.Safari")
        source.frontmostApp = .safari
        source.terminate(.photoshop)
        #expect(manager.suspendedForApp == "Safari")
    }

    @Test func listChangesApplyToTheAppInFrontAtOnce() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = makeController(source: source)
        let manager = makeManager()
        controller.onChange = { manager.setSuspendedForApp($0) }
        manager.setEnabled(true, for: 1)
        #expect(controller.suspendedFor == nil)

        try controller.apply(.add("com.adobe.photoshop"))
        #expect(manager.suspendedForApp == "Photoshop")
        try controller.apply(.remove("com.adobe.Photoshop"))
        #expect(manager.suspendedForApp == nil)
        try controller.apply(.add("com.adobe.Photoshop"))
        try controller.apply(.clear)
        #expect(manager.suspendedForApp == nil)
    }

    @Test func launchAndWakeJudgeTheAppInFront() throws {
        let defaults = defaultsRegistry.makeDefaults(prefix: "AppSuspensionTests")
        defaults.set(["com.adobe.Photoshop"], forKey: AppSuspensionController.defaultsKey)
        #expect(makeController(source: FakeAppSource(frontmost: .redlight), defaults: defaults).suspendedFor == nil)
        #expect(makeController(source: FakeAppSource(frontmost: nil), defaults: defaults).suspendedFor == nil)

        let source = FakeAppSource(frontmost: .safari)
        let controller = makeController(source: source, defaults: defaults)
        #expect(controller.suspendedFor == nil)
        // An activation missed during sleep.
        source.frontmostApp = .photoshop
        source.wake()
        #expect(controller.suspendedFor == "Photoshop")
        source.frontmostApp = nil
        source.wake()
        #expect(controller.suspendedFor == nil)
        #expect(controller.recentBundleID == nil)
    }

    @Test func namesAndRunningAppsForThePopover() throws {
        let source = FakeAppSource(frontmost: .safari)
        source.names = ["com.adobe.Photoshop": "Adobe Photoshop"]
        source.runningApps = [.safari, .redlight, .photoshop, .script]
        let controller = makeController(source: source)
        #expect(controller.name(for: "com.adobe.Photoshop") == "Adobe Photoshop")
        #expect(controller.name(for: "com.example.Missing") == "com.example.Missing")
        #expect(controller.runningApps() == [.safari, .photoshop, .script])
        #expect(controller.recentBundleID == "com.apple.Safari")

        let duplicateSafari = RunningApp(bundleID: "com.apple.Safari", name: "Safari", processID: 600)
        let notes = RunningApp(bundleID: "com.apple.Notes", name: "Notes", processID: 601)
        let candidates = PauseForAppsRow.candidates(
            running: [notes, .photoshop, .safari, .script, duplicateSafari,
                      RunningApp(bundleID: "invalid id", name: "Unavailable", processID: 602)],
            chosen: ["COM.ADOBE.PHOTOSHOP"], recent: "com.apple.Safari")
        #expect(candidates == [.safari, notes])
    }

    // MARK: - Commands

    private func makeHandler(manager: DisplayManager, controller: AppSuspensionController) -> CommandHandler {
        CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) }, setLogin: { _ in },
            update: {}, quit: {}, version: { "test" },
            apps: { controller.bundleIDs }, changeApps: { try controller.apply($0) }
        ))
    }

    @Test func appsCommandsChangeTheListAndReportTheSuspension() throws {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = makeController(source: source)
        let manager = makeManager()
        controller.onChange = { manager.setSuspendedForApp($0) }
        let handler = makeHandler(manager: manager, controller: controller)
        _ = try handler.execute(.master(.on))

        let before = try handler.execute(.status)
        #expect(before.apps.isEmpty && before.suspendedFor == nil)
        let added = try handler.execute(.apps(.add("com.adobe.Photoshop")))
        #expect(added.apps == ["com.adobe.Photoshop"])
        #expect(added.on)
        #expect(added.suspendedFor == "Photoshop")
        #expect(try handler.execute(.appsList).apps == ["com.adobe.Photoshop"])
        #expect(try handler.execute(.status).suspendedFor == "Photoshop")

        // Nothing is suspended while off, so nothing is reported.
        #expect(try handler.execute(.master(.off)).suspendedFor == nil)
        #expect(try handler.execute(.master(.on)).suspendedFor == "Photoshop")

        let token = manager.beginSliderInteraction()
        #expect(throws: CommandError.self) { try handler.execute(.apps(.add("has space"))) }
        #expect(throws: CommandError.self) { try handler.execute(.apps(.remove("com.apple.Safari"))) }
        _ = try handler.execute(.appsList)
        #expect(manager.isSliderInteractionCurrent(token))
        do { _ = try handler.execute(.apps(.add(""))) } catch let error as CommandError { #expect(error.exitCode == 1) }

        #expect(try handler.execute(.apps(.remove("COM.ADOBE.PHOTOSHOP"))).suspendedFor == nil)
        _ = try handler.execute(.apps(.add("com.apple.Safari")))
        _ = try handler.execute(.apps(.add("com.adobe.Photoshop")))
        let cleared = try handler.execute(.apps(.clear))
        #expect(cleared.apps.isEmpty && cleared.suspendedFor == nil)
    }

    @Test func appsCommandsNeedTheController() {
        let manager = makeManager()
        let handler = CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { Status.Login(enabled: false, requiresApproval: false) }, setLogin: { _ in },
            update: {}, quit: {}, version: { "test" }))
        #expect(throws: CommandError.self) { try handler.execute(.apps(.add("com.adobe.Photoshop"))) }
        #expect((try? handler.execute(.appsList))?.apps == [])
    }

    @Test func popoverAppActionsReachTheList() {
        let source = FakeAppSource(frontmost: .photoshop)
        let controller = makeController(source: source)
        let manager = makeManager()
        controller.onChange = { manager.setSuspendedForApp($0) }
        let dispatch = PopoverCommandDispatch(handler: makeHandler(manager: manager, controller: controller))
        #expect(dispatch.execute(.apps(.add("com.adobe.Photoshop"))) == nil)
        #expect(manager.suspendedForApp == "Photoshop")
        #expect(dispatch.execute(.apps(.remove("com.adobe.Photoshop"))) == nil)
        #expect(manager.suspendedForApp == nil)
        #expect(dispatch.execute(.apps(.remove("com.adobe.Photoshop")))?.contains("not in the list") == true)
    }
}

/// Not main-actor isolated: the CLI runs its client off the main actor.
@Suite struct AppSuspensionCLITests {
    @Test func cliPrintsTheListOneBundleIDPerLine() async throws {
        let client = CommandClient(hasPort: { true }, send: { _ in
            Status(on: true, version: "1.5", apps: ["com.adobe.Photoshop", "com.apple.Photos"])
        })
        var output: [String] = []
        #expect(await RedlightCLI.run(arguments: ["apps", "list"], client: client, writeOutput: { output.append($0) }) == 0)
        #expect(output == ["com.adobe.Photoshop\ncom.apple.Photos"])
        output.removeAll()
        #expect(await RedlightCLI.run(arguments: ["apps", "list", "--json"], client: client, writeOutput: { output.append($0) }) == 0)
        let json = try #require(output.first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["apps"] as? [String] == ["com.adobe.Photoshop", "com.apple.Photos"])
        output.removeAll()
        #expect(await RedlightCLI.run(arguments: ["apps", "add", "com.apple.Notes"], client: client, writeOutput: { output.append($0) }) == 0)
        #expect(output.isEmpty)

        let empty = CommandClient(hasPort: { true }, send: { _ in Status(on: true) })
        #expect(await RedlightCLI.run(arguments: ["apps", "list"], client: empty, writeOutput: { output.append($0) }) == 0)
        #expect(output.isEmpty)
    }

    @Test func statusMentionsTheSuspensionOnlyWhenThereIsOne() async {
        func firstLine(_ status: Status) async -> String {
            var output = ""
            _ = await RedlightCLI.run(arguments: ["status"], client: CommandClient(hasPort: { true }, send: { _ in status }),
                                      writeOutput: { output = $0 })
            return String(output.split(separator: "\n", omittingEmptySubsequences: false)[0])
        }
        #expect(await firstLine(Status(on: true, version: "1.5")) == "Redlight 1.5: on")
        #expect(await firstLine(Status(on: true, version: "1.5", suspendedFor: "Photoshop"))
                == "Redlight 1.5: on; suspended for Photoshop")
        #expect(redlightStatusText(Status(on: true, version: "1.5", suspendedFor: "Photoshop"))
                    .hasPrefix("Redlight on (suspended for Photoshop)\n"))
        #expect(redlightStatusText(Status(on: true, version: "1.5")).hasPrefix("Redlight on\n"))
    }
}
