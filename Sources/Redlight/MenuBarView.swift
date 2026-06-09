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
                    in: 0.0...1.0
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Reduce White Point")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(
                    value: $manager.whitepoint,
                    in: 0.25...1.0
                )
            }

            Divider()

            // MARK: - Presets

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(manager.presets.enumerated()), id: \.offset) { index, preset in
                        PresetButton(
                            name: preset.name,
                            isActive: manager.activePresetIndex == index
                        ) {
                            manager.applyPreset(index)
                        }
                    }
                }

                Menu {
                    ForEach(Array(manager.presets.enumerated()), id: \.offset) { index, preset in
                        Button("Save to \"\(preset.name)\"") {
                            manager.saveToPreset(index)
                        }
                    }
                } label: {
                    Text("Save to Preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Divider()

            Button("Quit") {
                manager.restoreAllDisplays()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Preset Button

struct PresetButton: View {
    let name: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.caption2)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? Color.red.opacity(0.25) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isActive ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
