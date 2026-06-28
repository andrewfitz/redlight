import SwiftUI

struct MenuBarView: View {
    @Bindable var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redlight")
                .font(.headline)

            Divider()

            ForEach(manager.displays) { display in
                HStack {
                    Toggle(display.name, isOn: Binding(
                        get: { display.isEnabled },
                        set: { _ in manager.toggle(display.id) }
                    ))
                    Spacer()
                    Toggle("Invert", isOn: Binding(
                        get: { display.isInverted },
                        set: { _ in manager.toggleInvert(display.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if manager.displays.isEmpty {
                Text("No displays detected")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Intensity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if manager.adaptiveEnabled {
                        Spacer()
                        Text("limit \(Int(manager.adaptiveMin * 100))–\(Int(manager.adaptiveMax * 100))%")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                BandSlider(
                    value: $manager.intensity,
                    lowerBound: $manager.adaptiveMin,
                    upperBound: $manager.adaptiveMax,
                    range: 0.0...1.0,
                    showBand: manager.adaptiveEnabled,
                    onPreview: { manager.previewIntensity($0) },
                    onPreviewEnd: { manager.endPreview() }
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Reduce White Point")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if manager.adaptiveEnabled {
                        Spacer()
                        Text("limit \(Int(manager.adaptiveWpMin * 100))–\(Int(manager.adaptiveWpMax * 100))%")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                BandSlider(
                    value: $manager.whitepoint,
                    lowerBound: $manager.adaptiveWpMin,
                    upperBound: $manager.adaptiveWpMax,
                    range: 0.25...1.0,
                    showBand: manager.adaptiveEnabled,
                    onPreview: { manager.previewWhitepoint($0) },
                    onPreviewEnd: { manager.endPreview() }
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

            // MARK: - Adaptive

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Adaptive", isOn: $manager.adaptiveEnabled)
                    .font(.subheadline)

                if manager.adaptiveEnabled && !manager.adaptiveStatusText.isEmpty {
                    if manager.adaptiveStatusText == "Location needed" {
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Location needed — open Settings", systemImage: "location.slash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(manager.adaptiveStatusText)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if manager.adaptiveEnabled, let coord = manager.coordinate {
                    TimelineView(.periodic(from: .now, by: 20)) { context in
                        let cycle = SunCycle(
                            now: context.date,
                            latitude: coord.latitude,
                            longitude: coord.longitude
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            if let event = cycle.nextEvent {
                                Text("\(event.label) in \(countdown(event.seconds))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            SunArcView(
                                cycle: cycle,
                                intensities: appliedIntensities(cycle, coord: coord),
                                intensityLimits: min(manager.adaptiveMin, manager.adaptiveMax)
                                    ... max(manager.adaptiveMin, manager.adaptiveMax)
                            )
                        }
                    }
                }
            }

            Divider()

            Button("Quit") {
                manager.restoreAllDisplays()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 300)
        .onDisappear { manager.endPreview() }   // cancel any band-marker preview left mid-drag
    }

    private func countdown(_ seconds: Double) -> String {
        let m = max(0, Int((seconds / 60).rounded()))
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    /// Applied adaptive intensity at each sample time — the same mapping the live filter uses.
    @MainActor
    private func appliedIntensities(_ cycle: SunCycle,
                                    coord: (latitude: Double, longitude: Double)) -> [Double] {
        let minElev = SolarCalculator.elevationAtSolarMidnight(
            at: Date(), latitude: coord.latitude, longitude: coord.longitude)
        return cycle.samples.map { sample in
            AdaptiveMapping.banded(
                elevation: sample.elevation, minElevation: minElev, presets: manager.presets,
                intensityMin: manager.adaptiveMin, intensityMax: manager.adaptiveMax,
                whitepointMin: manager.adaptiveWpMin, whitepointMax: manager.adaptiveWpMax
            ).intensity
        }
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
