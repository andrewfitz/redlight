import SwiftUI

struct MenuBarView: View {
    @Bindable var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redlight")
                .font(.headline)

            Divider()

            ForEach(manager.displays) { display in
                Toggle(display.name, isOn: Binding(
                    get: { display.isEnabled },
                    set: { _ in manager.toggle(display.id) }
                ))
            }

            if manager.displays.isEmpty {
                Text("No displays detected")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Intensity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(
                    value: $manager.intensity,
                    in: 0.1...1.0
                )
            }

            Divider()

            Button("Quit") {
                manager.restoreAllDisplays()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
