import AppKit
import Foundation

/// CPU submission benchmark, not an end-to-end Sidecar frame-rate or GPU benchmark.
/// The overlay has zero opacity so benchmarking does not change the user's image.
@main
@MainActor
enum SidecarBenchmark {
    private final class Sink: GammaControlling {
        private(set) var calls = 0
        func applyFilter(to id: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool) { calls += 1 }
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

    @discardableResult
    private static func measure(_ name: String, run: () -> Void) -> Int {
        let warmups = 100
        let iterations = 10_000
        // Warm each operation before timing, including initial route discovery.
        for _ in 0..<warmups { autoreleasepool { run() } }
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<iterations { autoreleasepool { run() } }
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        }
        print("\(name): median \(samples.sorted()[2]) ms/\(iterations) calls; samples \(samples)")
        return warmups + samples.count * iterations
    }

    static func main() {
        if CommandLine.arguments.dropFirst().first == "--synthetic" {
            let physical = Sink()
            let sidecar = Sink()
            let router = DisplayFilterController(gamma: physical, sidecar: sidecar, isSidecar: { $0 == 2 })
            let calls = measure("synthetic-cached-sidecar-route") {
                router.applyFilter(to: 2, intensity: 0.6, whitepoint: 0.8, invert: false)
            }
            precondition(sidecar.calls == calls && physical.calls == 0)
            let physicalCalls = measure("synthetic-cached-physical-route") {
                router.applyFilter(to: 1, intensity: 0.6, whitepoint: 0.8, invert: false)
            }
            precondition(physical.calls == physicalCalls && sidecar.calls == calls)
            return
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        let displays = NSScreen.screens.compactMap { screen -> (NSScreen, CGDirectDisplayID)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return (screen, id)
        }
        guard let (screen, id) = displays.first(where: { DisplayFilterController.isSidecarDisplay($0.1) }) else {
            print("Connect a Sidecar iPad to run this benchmark.")
            exit(1)
        }
        guard let window = SidecarFilterWindow(screen: screen) else {
            print("The Sidecar filter window is unavailable on this Mac.")
            exit(1)
        }
        defer { window.close() }
        window.alphaValue = 0
        window.apply(screen: screen, intensity: 0.6, whitepoint: 0.8, invert: false)
        let router = DisplayFilterController(gamma: Sink(), sidecar: Sink())
        let routedWindow = DisplayFilterController(gamma: Sink(), sidecar: WindowSink(window: window, screen: screen))

        measure("route-sidecar") { router.applyFilter(to: id, intensity: 0.6, whitepoint: 0.8, invert: false) }
        if let (_, physicalID) = displays.first(where: { !DisplayFilterController.isSidecarDisplay($0.1) }) {
            measure("route-physical") { router.applyFilter(to: physicalID, intensity: 0.6, whitepoint: 0.8, invert: false) }
        }
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
