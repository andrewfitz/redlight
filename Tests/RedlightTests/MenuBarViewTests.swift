import AppKit
import SwiftUI
import Testing
@testable import Redlight

@MainActor @Suite struct MenuBarViewTests {
    @Test func hostedPopoverRendersAndScrollsWhenAdaptiveExpands() async throws {
        _ = NSApplication.shared
        let defaultsRegistry = TestDefaultsRegistry()
        let defaults = defaultsRegistry.makeDefaults()
        let location = FakeLocationProvider()
        location.coordinate = (41.88, -87.63)
        let manager = DisplayManager(
            gamma: MockGammaController(), getDisplayIDs: { [1, 2] },
            getDisplayName: { "Display \($0)" }, getDisplayPersistenceKey: { String($0) },
            getMainDisplayID: { 1 }, defaults: defaults, location: location,
            adaptiveTransitionDuration: 0, displayTransitionDuration: 0)
        let view = MenuBarView(manager: manager).defaultAppStorage(defaults)
        let ordinary = StatusItemController.makePopover(content: view)
        let originalSize = ordinary.contentSize
        #expect(originalSize.width == 300)
        #expect(originalSize.height > 200)

        let maximumHeight = originalSize.height + 40
        let expanded = StatusItemController.makePopover(maximumHeight: maximumHeight, content: view)
        let controller = try #require(expanded.contentViewController)
        let scroll = try #require(controller.view as? NSScrollView)
        let document = try #require(scroll.documentView)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: originalSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        document.layoutSubtreeIfNeeded()
        #expect(!scroll.hasVerticalScroller)

        manager.adaptiveEnabled = true
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            document.layoutSubtreeIfNeeded()
        }
        #expect(expanded.contentSize == CGSize(width: 300, height: maximumHeight))
        #expect(scroll.hasVerticalScroller)
        #expect(document.frame.height > maximumHeight)
        let bitmap = try #require(document.bitmapImageRepForCachingDisplay(in: document.bounds))
        document.cacheDisplay(in: document.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 300)
        #expect(bitmap.pixelsHigh > Int(maximumHeight))
        let bytes = try #require(bitmap.bitmapData)
        #expect(UnsafeBufferPointer(start: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            .contains { $0 != 0 })
    }

    @Test func sunArcAccessibilityReportsCurrentElevationWithoutPhaseJargon() {
        let summary = SunArcView.accessibilitySummary(currentElevation: 0.8)
        #expect(summary.contains("Solar elevation +1°"))
        #expect(!summary.lowercased().contains("marker"))
        #expect(!summary.lowercased().contains("civil"))
        #expect(!summary.lowercased().contains("nautical"))
        #expect(!summary.lowercased().contains("astronomical"))
    }

    @Test func inlinePauseLengthsAreLabelledAndDispatchTheirLength() {
        #expect(PauseLengthRow.options.map(\.title) == ["30 m", "1 h", "2 h", "Until sunrise"])
        #expect(PauseLengthRow.options.map(\.accessibility) == [
            "Pause for 30 minutes", "Pause for 1 hour", "Pause for 2 hours", "Pause until sunrise",
        ])
        #expect(PauseLengthRow.options.map(\.length) == [
            .minutes(30), .minutes(60), .minutes(120), .untilSunrise,
        ])
    }

    @Test func bedtimeRowRoundTripsThroughItsTimeField() {
        #expect(BedtimeRow.suggested == Bedtime(hour: 22, minute: 30))
        for zone in ["UTC", "America/New_York", "Australia/Lord_Howe", "Asia/Kathmandu"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            for minute in stride(from: 0, to: 1440, by: 7) {
                let bedtime = Bedtime(minuteOfDay: minute)!
                #expect(BedtimeRow.bedtime(from: BedtimeRow.date(for: bedtime, calendar: calendar),
                                           calendar: calendar) == bedtime)
            }
        }
    }
}
