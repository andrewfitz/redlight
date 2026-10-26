import AppKit
import CoreGraphics
import Testing
@testable import Redlight

@MainActor @Suite struct SidecarFilterTests {
    @MainActor private final class DisplayKind {
        var isSidecar = true
    }

    @MainActor private final class Overlay: SidecarOverlay {
        var applyCount = 0
        var invalidateCount = 0
        var closeCount = 0
        var pointer: (cursor: NSCursor?, location: NSPoint)?
        func apply(screen: NSScreen, intensity: Float, whitepoint: Float, invert: Bool) { applyCount += 1 }
        func invalidateSurface() { invalidateCount += 1 }
        func updatePointer(_ cursor: NSCursor?, at location: NSPoint) { pointer = (cursor, location) }
        func close() { closeCount += 1 }
    }

    @MainActor private final class Pointer: SidecarPointerSystem {
        var location = NSPoint(x: -1_000_000, y: -1_000_000)
        var isVisible = true
        var seed = 1
        var cursor: NSCursor
        var hideCount = 0
        var showCount = 0
        var changed: (@MainActor () -> Void)?
        var stopCount = 0
        init() {
            _ = NSApplication.shared // standard cursors are nil until AppKit is initialized
            cursor = .arrow
        }
        func hide() { hideCount += 1; isVisible = false }
        func show() { showCount += 1; isVisible = true }
        func startMonitoring(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }
        func stopMonitoring() { changed = nil; stopCount += 1 }
    }

    @Test func nativeBackdropCanInitializeOnMacOS27() throws {
        guard #available(macOS 27, *), let screen = NSScreen.screens.first else { return }
        _ = NSApplication.shared
        let window = try #require(SidecarFilterWindow(screen: screen))
        defer { window.close() }
        #expect(!window.isVisible)
        #expect(window.ignoresMouseEvents)
        #expect(!window.canBecomeKey)
    }

    @Test func sidecarUsesCompositorAndPhysicalDisplayUsesGamma() {
        let gamma = MockGammaController()
        let sidecar = MockGammaController()
        let controller = DisplayFilterController(gamma: gamma, sidecar: sidecar, isSidecar: { $0 == 7 })
        controller.applyFilter(to: 7, intensity: 0.3, whitepoint: 0.6, invert: true)
        controller.applyFilter(to: 2, intensity: 0.7, whitepoint: 0.9, invert: false)
        #expect(sidecar.applyCalls.count == 1)
        #expect(sidecar.applyCalls[0].displayID == 7)
        #expect(sidecar.applyCalls[0].intensity == 0.3)
        #expect(sidecar.applyCalls[0].whitepoint == 0.6)
        #expect(sidecar.applyCalls[0].invert)
        #expect(gamma.applyCalls.count == 1)
        #expect(gamma.applyCalls[0].displayID == 2)
        #expect(gamma.restoreCalls == [7])
        #expect(sidecar.restoreCalls == [2])
    }

    @Test func restoreCleansBothBackendsIncludingAReusedDisplayID() {
        let gamma = MockGammaController()
        let sidecar = MockGammaController()
        let kind = DisplayKind()
        let controller = DisplayFilterController(gamma: gamma, sidecar: sidecar, isSidecar: { _ in kind.isSidecar })
        controller.applyFilter(to: 7, intensity: 0, whitepoint: 0.5, invert: false)
        kind.isSidecar = false
        controller.displaysDidChange()
        controller.applyFilter(to: 7, intensity: 0.5, whitepoint: 0.5, invert: false)
        #expect(sidecar.restoreCalls == [7])
        controller.restore(7)
        controller.restoreAll()
        #expect(sidecar.restoreCalls == [7, 7])
        #expect(gamma.restoreCalls == [7, 7])
        #expect(sidecar.restoreAllCount == 1)
        #expect(gamma.restoreAllCount == 1)
    }

    @Test func routingIsCachedUntilDisplayRefreshOrRestore() {
        let gamma = MockGammaController()
        let sidecar = MockGammaController()
        var discoveries = 0
        let controller = DisplayFilterController(gamma: gamma, sidecar: sidecar, isSidecar: { id in
            discoveries += 1
            return id == 7
        })
        for _ in 0..<100 {
            controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
            controller.applyFilter(to: 2, intensity: 0.6, whitepoint: 1, invert: false)
        }
        #expect(discoveries == 2)
        #expect(gamma.applyCalls.count == 100) // physical LUTs must still be re-applied
        #expect(gamma.restoreCalls == [7])
        #expect(sidecar.restoreCalls == [2])
        controller.displaysDidChange()
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(discoveries == 3)
        controller.restore(7)
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(discoveries == 4)
        controller.restoreAll()
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(discoveries == 5)
    }

    @Test func screenRefreshKeepsOverlayAndInvalidatesItsSurface() throws {
        guard let screen = NSScreen.screens.first else { return }
        let overlay = Overlay()
        var screenReads = 0
        var creations = 0
        let controller = SidecarFilterController(getScreen: { _ in
            screenReads += 1
            return screen
        }, makeOverlay: { _ in
            creations += 1
            return overlay
        }, pointer: Pointer())
        for _ in 0..<100 {
            controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        }
        #expect(screenReads == 1)
        #expect(creations == 1)
        controller.displaysDidChange()
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(screenReads == 2)
        #expect(creations == 1)
        #expect(overlay.invalidateCount == 1)
        controller.restore(7)
        #expect(overlay.closeCount == 1)
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(creations == 2)
        controller.restoreAll()
        #expect(overlay.closeCount == 2)
    }

    @Test func unsupportedCompositorDoesNotRetryEveryFrame() {
        guard let screen = NSScreen.screens.first else { return }
        var attempts = 0
        let controller = SidecarFilterController(getScreen: { _ in screen }, makeOverlay: { _ in
            attempts += 1
            return nil
        }, pointer: Pointer())
        for _ in 0..<100 {
            controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        }
        #expect(attempts == 1)
        controller.displaysDidChange()
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(attempts == 2)
        controller.restoreAll()
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(attempts == 3)
    }

    @Test func nativeRepeatedUpdatePreservesSnapshotButChangedOutputReplacesIt() throws {
        guard #available(macOS 27, *), let screen = NSScreen.screens.first else { return }
        _ = NSApplication.shared
        let window = try #require(SidecarFilterWindow(screen: screen))
        window.alphaValue = 0 // exercise the real render tree without tinting the desktop
        defer { window.close() }
        func filter() throws -> NSObject {
            try #require(window.contentView?.layer?.sublayers?.last?.filters?.first as? NSObject)
        }
        window.apply(screen: screen, intensity: 0.6, whitepoint: 0.8, invert: false)
        let first = try filter()
        let oldGreen = try #require(first.value(forKey: "inputGreenValues") as? [Float])
        window.apply(screen: screen, intensity: 0.6, whitepoint: 0.8, invert: false)
        #expect(try filter() === first)
        window.apply(screen: screen, intensity: 0.3, whitepoint: 0.5, invert: true)
        let second = try filter()
        #expect(second !== first)
        #expect(first.value(forKey: "inputGreenValues") as? [Float] == oldGreen)
        #expect(second.value(forKey: "inputGreenValues") as? [Float] ==
                SidecarTransferCurve.controls(gain: 0.3, whitepoint: 0.5, invert: true))
        window.setFrame(CGRect(x: 0, y: 0, width: 100, height: 100), display: false)
        window.invalidateSurface()
        window.apply(screen: screen, intensity: 0.3, whitepoint: 0.5, invert: true)
        #expect(window.frame == screen.frame)
        #expect(window.contentView?.layer?.sublayers?.last?.frame == window.contentView?.bounds)
        #expect(try filter() === second) // resizing must not change the color transfer
    }

    @Test func pointerOverSidecarIsHiddenAndDrawnBeneathTheFilter() throws {
        let screen = try #require(NSScreen.screens.first)
        let overlay = Overlay()
        let pointer = Pointer()
        let controller = SidecarFilterController(getScreen: { _ in screen }, makeOverlay: { _ in overlay },
                                                 pointer: pointer)
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        let changed = try #require(pointer.changed)
        #expect(pointer.hideCount == 0)
        #expect(overlay.pointer?.cursor == nil)

        pointer.location = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        changed()
        #expect(pointer.hideCount == 1)
        let drawn = overlay.pointer?.cursor ?? nil
        #expect(drawn != nil && drawn === pointer.cursor)
        #expect(overlay.pointer?.location == pointer.location)

        // Another app's activation unhides the pointer; it is hidden again.
        pointer.isVisible = true
        changed()
        #expect(pointer.hideCount == 2)
        changed()
        #expect(pointer.hideCount == 2)

        pointer.seed = 2
        pointer.cursor = .iBeam
        changed()
        let iBeam = overlay.pointer?.cursor ?? nil
        #expect(iBeam != nil && iBeam === NSCursor.iBeam)

        pointer.location = NSPoint(x: screen.frame.maxX + 10, y: screen.frame.midY)
        changed()
        #expect(pointer.showCount == 2)
        #expect(overlay.pointer?.cursor == nil)

        // A pointer another app has hidden stays hidden, without a replica.
        pointer.isVisible = false
        pointer.location = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        changed()
        #expect(pointer.hideCount == 2)
        #expect(overlay.pointer?.cursor == nil)
    }

    @Test func turningTheFilterOffReleasesThePointer() throws {
        let screen = try #require(NSScreen.screens.first)
        let overlay = Overlay()
        let pointer = Pointer()
        pointer.location = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let controller = SidecarFilterController(getScreen: { _ in screen }, makeOverlay: { _ in overlay },
                                                 pointer: pointer)
        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(pointer.hideCount == 1)
        controller.applyFilter(to: 7, intensity: 1, whitepoint: 1, invert: false)
        #expect(pointer.showCount == 1)
        #expect(pointer.changed == nil)

        controller.applyFilter(to: 7, intensity: 0.6, whitepoint: 1, invert: false)
        #expect(pointer.hideCount == 2)
        controller.displaysDidChange() // geometry unknown until the next apply
        #expect(pointer.showCount == 2)
        #expect(pointer.changed != nil)
        controller.restoreAll()
        #expect(pointer.stopCount == 2)
    }

    @Test func compositorCurveMatchesExistingTransferFunction() {
        for intensity: Float in [0, 0.3, 0.5, 0.7, 1] {
            for whitepoint: Float in [0.25, 0.6, 1] {
                for invert in [false, true] {
                    let table = GammaTableComposer.compose(
                        original: nil, intensity: intensity, whitepoint: whitepoint, invert: invert)
                    for (gain, channel) in zip([1, intensity, max(0, intensity * 2 - 1)], [table.r, table.g, table.b]) {
                        let c = SidecarTransferCurve.controls(gain: gain, whitepoint: whitepoint, invert: invert)
                        for i in channel.indices {
                            let x = Float(i) / Float(channel.count - 1)
                            let u = 1 - x
                            let value = u*u*u*c[0] + 3*u*u*x*c[1] + 3*u*x*x*c[2] + x*x*x*c[3]
                            #expect(abs(value - channel[i]) < 0.000_001)
                        }
                    }
                }
            }
        }
    }
}
