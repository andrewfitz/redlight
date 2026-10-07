import Foundation
import Testing
@testable import Redlight

@MainActor @Suite struct SliderInteractionTests {
    let defaultsRegistry = TestDefaultsRegistry()

    private func makeManager(gamma: MockGammaController = MockGammaController()) -> DisplayManager {
        DisplayManager(
            gamma: gamma, getDisplayIDs: { [1] },
            getDisplayName: { _ in "Display" }, getDisplayPersistenceKey: { _ in "monitor" },
            defaults: defaultsRegistry.makeDefaults(prefix: "SliderInteractionTests"),
            location: FakeLocationProvider(),
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0
        )
    }

    private func makeHandler(_ manager: DisplayManager) -> CommandHandler {
        CommandHandler(manager: manager, services: CommandServices(
            appearance: { false }, setAppearance: { _ in },
            login: { .init(enabled: false, requiresApproval: false) }, setLogin: { _ in },
            update: {}, quit: {}, version: { "test" }, deferAction: { _ in }
        ))
    }

    @Test func commandCancelsTheGestureUntilReleaseAndAFreshGestureWorks() throws {
        let manager = makeManager()
        let handler = makeHandler(manager)
        var gate = SliderInteractionGate()
        let token = manager.beginSliderInteraction()
        let acceptedInitial = gate.permitsMutation(token: token, isCurrent: { manager.isSliderInteractionCurrent($0) })
        #expect(acceptedInitial)
        _ = try handler.execute(.color(75))
        let acceptedAfterCommand = gate.permitsMutation(token: token, isCurrent: { manager.isSliderInteractionCurrent($0) })
        #expect(!acceptedAfterCommand)
        #expect(gate.isInterrupted)
        // A redraw must not revive the old gesture, even if its callback is replaced.
        let acceptedAfterCallbackUpdate = gate.permitsMutation(token: token, isCurrent: { _ in true })
        #expect(!acceptedAfterCallbackUpdate)
        #expect(manager.intensity == 0.75)
        let nextToken = manager.beginSliderInteraction()
        // A different token alone cannot revive the cancelled gate before release.
        let acceptedWithNewTokenBeforeRelease = gate.permitsMutation(token: nextToken, isCurrent: { manager.isSliderInteractionCurrent($0) })
        #expect(!acceptedWithNewTokenBeforeRelease)
        gate = SliderInteractionGate()
        let acceptedNewGesture = gate.permitsMutation(token: nextToken, isCurrent: { manager.isSliderInteractionCurrent($0) })
        #expect(acceptedNewGesture)
    }

    @Test func readOnlyAndRejectedCommandsKeepTheGestureLive() throws {
        let manager = makeManager()
        let handler = makeHandler(manager)
        var gate = SliderInteractionGate()
        let token = manager.beginSliderInteraction()
        _ = try handler.execute(.status)
        _ = try handler.execute(.displayList)
        let acceptedAfterReads = gate.permitsMutation(token: token, isCurrent: { manager.isSliderInteractionCurrent($0) })
        #expect(acceptedAfterReads)
        #expect(throws: CommandError.self) { _ = try handler.execute(.color(101)) }
        let acceptedAfterRejection = gate.permitsMutation(token: token, isCurrent: { manager.isSliderInteractionCurrent($0) })
        #expect(acceptedAfterRejection)
        #expect(!gate.isInterrupted)
    }

    @Test func interruptionImmediatelyBeforeReleaseRejectsThePreviewEndCallback() throws {
        let manager = makeManager()
        let handler = makeHandler(manager)
        var gate = SliderInteractionGate()
        let token = manager.beginSliderInteraction()
        let acceptedWhileDragging = gate.permitsMutation(token: token, isCurrent: { manager.isSliderInteractionCurrent($0) })
        #expect(acceptedWhileDragging)
        // No further onChanged event is needed: onEnded consults the same gate and token.
        _ = try handler.execute(.limits(.color, min: 20, max: 80))
        let acceptedOnRelease = gate.permitsMutation(token: token, isCurrent: { manager.isSliderInteractionCurrent($0) })
        #expect(!acceptedOnRelease)
        #expect(manager.intensityBand == 0.2...0.8)
    }

    @Test func currentMarkerCleanupRestoresTheActualFilter() {
        let gamma = MockGammaController()
        let manager = makeManager(gamma: gamma)
        manager.intensity = 0.6
        manager.setEnabled(true, for: 1)
        let token = manager.beginSliderInteraction()
        manager.previewIntensity(0.2)
        #expect(gamma.applyCalls.last?.intensity == Float(0.2))
        var gate = SliderInteractionGate()
        var endCount = 0
        gate.endPreviewIfCurrent(
            token: token, isCurrent: { manager.isSliderInteractionCurrent($0) },
            isPreviewing: true, onPreviewEnd: {
                endCount += 1
                manager.endPreview()
            }
        )
        #expect(endCount == 1)
        #expect(gamma.applyCalls.last?.intensity == Float(0.6))
    }

    @Test func interruptedMarkerCleanupLeavesANewerPreviewApplied() throws {
        let gamma = MockGammaController()
        let manager = makeManager(gamma: gamma)
        manager.setEnabled(true, for: 1)
        let handler = makeHandler(manager)
        let staleToken = manager.beginSliderInteraction()
        manager.previewIntensity(0.2)
        _ = try handler.execute(.color(75))
        let currentToken = manager.beginSliderInteraction()
        manager.previewIntensity(0.3)
        var staleGate = SliderInteractionGate()
        var endCount = 0
        staleGate.endPreviewIfCurrent(
            token: staleToken, isCurrent: { manager.isSliderInteractionCurrent($0) },
            isPreviewing: true, onPreviewEnd: {
                endCount += 1
                manager.endPreview()
            }
        )
        #expect(endCount == 0)
        #expect(manager.isSliderInteractionCurrent(currentToken))
        #expect(gamma.applyCalls.last?.intensity == Float(0.3))
        manager.endPreview()
    }

    @Test func standaloneSliderWithoutInteractionCallbacksStillAcceptsEdits() {
        var gate = SliderInteractionGate()
        let accepted = gate.permitsMutation(token: nil, isCurrent: nil)
        #expect(accepted)
        #expect(!gate.isInterrupted)
    }
}
