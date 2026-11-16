import Foundation
import Testing
@testable import Redlight

@MainActor
private final class PopoverServicesState {
    var dark = false
    var login = Status.Login(enabled: false, requiresApproval: false)
    var appearanceFailure: CommandError?
    var pending: [@MainActor @Sendable () -> Void] = []
    var updateCount = 0
    var quitCount = 0

    var services: CommandServices {
        CommandServices(
            appearance: { self.dark },
            setAppearance: {
                if let failure = self.appearanceFailure { throw failure }
                self.dark = $0
            },
            login: { self.login }, setLogin: { self.login.enabled = $0 },
            update: { self.updateCount += 1 }, quit: { self.quitCount += 1 },
            version: { "test" }, deferAction: { self.pending.append($0) }
        )
    }
}

@MainActor @Suite struct CommandPopoverTests {
    let defaultsRegistry = TestDefaultsRegistry()

    private func makeManager() -> DisplayManager {
        DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [41, 92] },
            getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { "stable-\($0)" }, getMainDisplayID: { 41 },
            defaults: defaultsRegistry.makeDefaults(prefix: "CommandPopoverTests"),
            location: FakeLocationProvider(),
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0
        )
    }

    @Test func masterAndDisplayActionsUseSharedStateAndStableDisplayKey() {
        let manager = makeManager()
        let state = PopoverServicesState()
        let dispatch = PopoverCommandDispatch(handler: CommandHandler(manager: manager, services: state.services))
        #expect(dispatch.execute(.master(.on)) == nil)
        #expect(manager.isOn)
        #expect(manager.displays.first { $0.id == 41 }?.isEnabled == true)
        #expect(dispatch.execute(.display(.key("stable-41"), .off)) == nil)
        #expect(!manager.isOn)
        #expect(dispatch.execute(.display(.key("stable-92"), .on)) == nil)
        #expect(manager.isOn)
        #expect(manager.displays.first { $0.id == 92 }?.isEnabled == true)
        #expect(dispatch.execute(.invert(.key("stable-92"), .on)) == nil)
        #expect(manager.displays.first { $0.id == 92 }?.isInverted == true)
        #expect(dispatch.execute(.master(.off)) == nil)
        #expect(!manager.isOn)
        #expect(manager.displays.first { $0.id == 92 }?.isInverted == true)
    }

    @Test func disconnectedDisplayErrorPreservesActiveGestureAndIsVisible() {
        let manager = makeManager()
        let state = PopoverServicesState()
        let dispatch = PopoverCommandDispatch(handler: CommandHandler(manager: manager, services: state.services))
        let token = manager.beginSliderInteraction()
        let error = dispatch.execute(.display(.key("disconnected-monitor"), .on))
        #expect(error?.isEmpty == false)
        #expect(manager.isSliderInteractionCurrent(token))
        #expect(!manager.isOn)
    }

    @Test func systemServiceErrorsAreReturnedAndClearOnTheNextSuccessfulAction() {
        let manager = makeManager()
        let state = PopoverServicesState()
        state.appearanceFailure = .system("System appearance could not be changed.")
        let dispatch = PopoverCommandDispatch(handler: CommandHandler(manager: manager, services: state.services))
        #expect(dispatch.execute(.appearance(.dark)) == "System appearance could not be changed.")
        #expect(!state.dark)
        state.appearanceFailure = nil
        #expect(dispatch.execute(.appearance(.dark)) == nil)
        #expect(state.dark)
    }

    @Test func updateAndQuitUseDeferredHandlerServices() {
        let manager = makeManager()
        let state = PopoverServicesState()
        let dispatch = PopoverCommandDispatch(handler: CommandHandler(manager: manager, services: state.services))
        #expect(dispatch.execute(.update) == nil)
        #expect(dispatch.execute(.quit) == nil)
        #expect(state.updateCount == 0)
        #expect(state.quitCount == 0)
        #expect(state.pending.count == 2)
        for action in state.pending { action() }
        #expect(state.updateCount == 1)
        #expect(state.quitCount == 1)
    }

    @Test func pauseLengthAndLocationActionsReachTheModel() {
        let location = FakeLocationProvider()   // no coordinate yet: no sunrise to find
        let manager = DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [41] }, getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { "stable-\($0)" }, getMainDisplayID: { 41 },
            defaults: defaultsRegistry.makeDefaults(prefix: "CommandPopoverTests"),
            location: location, adaptiveTransitionDuration: 0, displayTransitionDuration: 0
        )
        let dispatch = PopoverCommandDispatch(handler: CommandHandler(manager: manager, services: PopoverServicesState().services))
        #expect(dispatch.execute(.master(.on)) == nil)
        #expect(dispatch.execute(.pauseFor(.untilSunrise))?.isEmpty == false)
        #expect(!manager.isPaused)
        #expect(dispatch.execute(.pauseFor(.minutes(120))) == nil)
        #expect(manager.pauseLength == 120 * 60)

        #expect(dispatch.execute(.location(.manual(latitude: 91, longitude: 0)))?.contains("Latitude") == true)
        #expect(location.manualCoordinate == nil)
        #expect(dispatch.execute(.location(.manual(latitude: 51.5, longitude: -0.13))) == nil)
        #expect(location.manualCoordinate?.latitude == 51.5)
        #expect(manager.manualLocation?.longitude == -0.13)
        #expect(dispatch.execute(.location(.automatic)) == nil)
        #expect(location.manualCoordinate == nil)
        #expect(manager.manualLocation == nil)
    }

    @Test func bedtimeActionsReachTheModel() {
        let manager = makeManager()
        let dispatch = PopoverCommandDispatch(handler: CommandHandler(manager: manager, services: PopoverServicesState().services))
        #expect(dispatch.execute(.adaptive(.on)) == nil)
        #expect(dispatch.execute(.bedtime(.at(hour: 22, minute: 30))) == nil)
        #expect(manager.bedtime == Bedtime(hour: 22, minute: 30))
        #expect(dispatch.execute(.bedtime(.at(hour: 24, minute: 0)))?.contains("23:59") == true)
        #expect(manager.bedtime == Bedtime(hour: 22, minute: 30))
        #expect(dispatch.execute(.bedtime(.off)) == nil)
        #expect(manager.bedtime == nil)
    }

    @Test func previewsWithoutAHandlerShowAnActionableError() {
        let dispatch = PopoverCommandDispatch(handler: nil)
        #expect(dispatch.execute(.master(.on))?.contains("Reopen the app") == true)
    }
}
