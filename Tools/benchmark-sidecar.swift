import AppKit
import Foundation

/// CPU submission benchmark, not an end-to-end Sidecar frame-rate or GPU benchmark.
/// The overlay has zero opacity so benchmarking does not change the user's image.
@main
@MainActor
enum SidecarBenchmark {
    private final class Sink: GammaControlling {
        func applyFilter(to id: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool) {}
        func restore(_ id: CGDirectDisplayID) {}
        func restoreAll() {}
    }

    @MainActor private final class WindowSink: @preconcurrency GammaControlling {
        let window: SidecarFilterWindow
        let screen: NSScreen
        init(window: SidecarFilterWindow, screen: NSScreen) {
            self.window = window
            self.screen = screen
        }
        func applyFilter(to id: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool) {
            window.apply(screen: screen, intensity: intensity, whitepoint: whitepoint, invert: invert)
        }
        func restore(_ id: CGDirectDisplayID) {}
        func restoreAll() {}
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("Sidecar")
        }), let window = SidecarFilterWindow(screen: screen) else {
            print("Connect a Sidecar iPad to run this benchmark.")
            exit(1)
        }
        defer { window.close() }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let physicalID = CGMainDisplayID()
        window.alphaValue = 0
        window.apply(screen: screen, intensity: 0.6, whitepoint: 0.8, invert: false)
        let router = DisplayFilterController(gamma: Sink(), sidecar: Sink())
        let routedWindow = DisplayFilterController(gamma: Sink(), sidecar: WindowSink(window: window, screen: screen))

        func measure(_ name: String, run: () -> Void) {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<10_000 { autoreleasepool { run() } }
                samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            print("\(name): median \(samples.sorted()[2]) ms/10,000 calls; samples \(samples)")
        }
        measure("route-sidecar") { router.applyFilter(to: id, intensity: 0.6, whitepoint: 0.8, invert: false) }
        measure("route-physical") { router.applyFilter(to: physicalID, intensity: 0.6, whitepoint: 0.8, invert: false) }
        measure("repeat-window") { window.apply(screen: screen, intensity: 0.6, whitepoint: 0.8, invert: false) }
        var frame = 0
        measure("changing-window") {
            frame += 1
            window.apply(screen: screen, intensity: Float(frame % 1_000) / 1_000, whitepoint: 0.8, invert: false)
        }
        measure("changing-route-and-window") {
            frame += 1
            routedWindow.applyFilter(to: id, intensity: Float(frame % 1_000) / 1_000, whitepoint: 0.8, invert: false)
        }
    }
}
