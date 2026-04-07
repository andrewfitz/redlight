import SwiftUI

@main
struct RedlightApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("Redlight is running")
                .padding()
        } label: {
            Image(systemName: "circle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
