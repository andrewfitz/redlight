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

    init(defaults: UserDefaults, location: LocationProviding? = nil, fadeDuration: TimeInterval = 0) {
        let gamma = MockGammaController()
        let state = CommandServiceState()
        let manager = DisplayManager(
            gamma: gamma, getDisplayIDs: { [10, 20, 30] },
            getDisplayName: { $0 == 10 ? "Built-in Retina" : $0 == 20 ? "Studio Display Left" : "Studio Display Right" },
            getDisplayPersistenceKey: { "stable-\($0)" },
            defaults: defaults, location: location ?? FakeLocationProvider(),
            now: { Date(timeIntervalSince1970: 1_780_000_000) },
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
        ))
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

    @Test func percentagesResetLimitsAndPersistence() throws {
        let f = makeFixture()
        _ = try f.handler.execute(.color(42))
        _ = try f.handler.execute(.whitepoint(67))
        #expect(f.manager.intensity == 0.42)
        #expect(f.manager.whitepoint == 0.67)
        #expect(f.defaults.double(forKey: "redlight.intensity") == 0.42)
        _ = try f.handler.execute(.limits(.color, min: 20, max: 70))
        _ = try f.handler.execute(.limits(.whitepoint, min: 40, max: 80))
        #expect(f.manager.intensityBand == 0.2...0.7)
        #expect(f.manager.whitepointBand == 0.4...0.8)
        #expect(f.defaults.double(forKey: "redlight.adaptiveMin") == 0.2)
        #expect(f.defaults.double(forKey: "redlight.adaptiveWpMax") == 0.8)
        _ = try f.handler.execute(.reset(.color))
        _ = try f.handler.execute(.reset(.whitepoint))
        #expect(f.manager.intensityIsDefault)
        #expect(f.manager.whitepointIsDefault)
    }

    @Test func rejectsAllInvalidRangesBeforeInterruptingOrPersisting() {
        let f = makeFixture()
        let commands: [RedlightCommand] = [
            .color(-1), .color(101), .color(.nan), .color(.infinity),
            .whitepoint(24.9), .whitepoint(101), .whitepoint(-.infinity),
            .limits(.color, min: 20, max: 20), .limits(.color, min: 80, max: 10),
            .limits(.color, min: -.infinity, max: 100),
            .limits(.whitepoint, min: 24, max: 100), .limits(.whitepoint, min: 25, max: .nan)
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
        #expect(f.manager.whitepoint == 0.4)
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
            #expect(f.manager.presets[preset.index].whitepoint == 0.58)
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
        let status = try f.handler.execute(.preset(.deepRed))
        #expect(status.fading)
        #expect(status.color.target == 0)
        #expect(status.whitepoint.target == 30)
        #expect(status.elevation != nil)
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
