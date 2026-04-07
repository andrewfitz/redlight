import SwiftUI

@main
struct RedlightApp: App {
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
