import SwiftUI
import ServiceManagement
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? SMAppService.mainApp.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore all displays to their ColorSync profiles on any termination
        // (covers force-quit via Activity Monitor, system shutdown, etc.)
        CGDisplayRestoreColorSyncSettings()
    }
}

@main
struct RedlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var manager = DisplayManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
        } label: {
            Circle()
                .fill(manager.isAnyActive ? Color.red : Color.gray)
                .frame(width: 8, height: 8)
        }
        .menuBarExtraStyle(.window)
    }
}
