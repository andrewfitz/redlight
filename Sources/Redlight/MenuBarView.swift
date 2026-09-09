import SwiftUI

/// Memoizes the expensive `SunCycle` construction (73 solar elevation evaluations plus a
/// bisected forward scan) and the per-sample applied-intensity mapping, so they run once
/// per timeline tick / input change instead of on every SwiftUI body evaluation. A plain
/// reference type: mutating it inside `body` is safe because the result is deterministic
/// for a given key and never feeds back into view identity.
private final class SunArcCache {
    struct IntensityKey: Equatable {
        var date: Date, lat: Double, lon: Double
        var presets: [Preset]
        var iMin: Double, iMax: Double, wMin: Double, wMax: Double
        var intensityAdjustment: Double

        /// Same as `==` except the date only has to fall within one timeline tick.
        func matches(_ other: IntensityKey) -> Bool {
            abs(date.timeIntervalSince(other.date)) < SunArcCache.tickTolerance
                && lat == other.lat && lon == other.lon && presets == other.presets
                && iMin == other.iMin && iMax == other.iMax
                && wMin == other.wMin && wMax == other.wMax
                && intensityAdjustment == other.intensityAdjustment
        }
    }

    private var cycleKey: (date: Date, lat: Double, lon: Double)?
    private var cycleValue: SunCycle?
    private(set) var minElevation: Double = 0
    private var intensityKey: IntensityKey?
    private var intensityValue: [Double] = []

    /// The graphic is rebuilt on a 20 s timeline. Treat any date within that window as the
    /// same tick, so a body re-evaluation that happens to restart the timeline (a slider
    /// drag) does not throw the memo away. The sun moves ~0.08° in 20 s — invisible here.
    static let tickTolerance: TimeInterval = 20

    func cycle(now: Date, latitude: Double, longitude: Double) -> SunCycle {
        if let cycleValue, let k = cycleKey,
           abs(k.date.timeIntervalSince(now)) < Self.tickTolerance,
           k.lat == latitude, k.lon == longitude {
            return cycleValue
        }
        let fresh = SunCycle(now: now, latitude: latitude, longitude: longitude)
        minElevation = SolarCalculator.elevationAtSolarMidnight(
            at: now, latitude: latitude, longitude: longitude)
        cycleKey = (now, latitude, longitude)
        cycleValue = fresh
        return fresh
    }

    func intensities(key: IntensityKey, compute: () -> [Double]) -> [Double] {
        if let k = intensityKey, k.matches(key) { return intensityValue }
        intensityValue = compute()
        intensityKey = key
        return intensityValue
    }
}

struct MenuBarView: View {
    @Bindable var manager: DisplayManager
    var launchAtLogin: LaunchAtLogin? = nil

    @State private var sunCache = SunArcCache()
    @State private var appearance = AppearanceController.shared
    @State private var showingAbout = false
    // Fixed anchor: `.periodic(from: .now, …)` would build a new schedule on every body
    // evaluation and restart the timeline (and its date) on each slider tick.
    @State private var sunArcScheduleStart = Date()

    var body: some View {
        Group {
            if showingAbout {
                AboutView { showingAbout = false }
            } else {
                controls
            }
        }
        .disabled(manager.isTerminating)
        .padding()
        .frame(width: 300)
        .onDisappear {
            if !manager.isTerminating { manager.endPreview() }
            // Reopening the popover should land on the controls, not a stale About page.
            showingAbout = false
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Redlight").font(.headline)
                Spacer()
                AppearanceSwitch(isDark: appearance.isDark) { appearance.toggle() }
            }

            Divider()

            ForEach(manager.displays) { display in
                HStack {
                    Toggle(display.name, isOn: Binding(
                        get: { display.isEnabled },
                        set: { _ in manager.toggle(display.id) }
                    ))
                    .accessibilityLabel(display.name)
                    Spacer()
                    Toggle("Invert", isOn: Binding(
                        get: { display.isInverted },
                        set: { _ in manager.toggleInvert(display.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Invert colors on \(display.name)")
                }
            }

            if manager.displays.isEmpty {
                Text("No displays detected")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Color")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    BandSlider(
                        value: $manager.intensity,
                        lowerBound: $manager.adaptiveMin,
                        upperBound: $manager.adaptiveMax,
                        range: 0.0...1.0,
                        showBand: manager.adaptiveEnabled,
                        label: "Color",
                        onPreview: { manager.previewIntensity($0) },
                        onPreviewEnd: { manager.endPreview() }
                    )
                    ResetButton(
                        help: "Reset color and its limits to default",
                        isDefault: manager.intensityIsDefault
                    ) { manager.resetIntensity() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("White Point")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    BandSlider(
                        value: $manager.whitepoint,
                        lowerBound: $manager.adaptiveWpMin,
                        upperBound: $manager.adaptiveWpMax,
                        range: 0.25...1.0,
                        showBand: manager.adaptiveEnabled,
                        label: "White Point",
                        onPreview: { manager.previewWhitepoint($0) },
                        onPreviewEnd: { manager.endPreview() }
                    )
                    ResetButton(
                        help: "Reset white point and its limits to default",
                        isDefault: manager.whitepointIsDefault
                    ) { manager.resetWhitepoint() }
                }
            }

            Divider()

            // MARK: - Presets

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 3) {
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
                    .help("Follow real solar elevation. You can still adjust either slider while Adaptive stays on.")
                    .accessibilityLabel("Adaptive solar mode")

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
                    TimelineView(.periodic(from: sunArcScheduleStart, by: SunArcCache.tickTolerance)) { context in
                        let cycle = sunCache.cycle(
                            now: context.date,
                            latitude: coord.latitude,
                            longitude: coord.longitude
                        )
                        SunArcView(
                            cycle: cycle,
                            intensities: appliedIntensities(cycle, at: context.date, coord: coord),
                            intensityLimits: manager.intensityBand
                        )
                    }
                }
            }

            Divider()

            if let launchAtLogin {
                @Bindable var launchAtLogin = launchAtLogin
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at Login", isOn: $launchAtLogin.isEnabled)
                        .font(.subheadline)
                        .accessibilityLabel("Launch Redlight at login")
                    if launchAtLogin.requiresApproval {
                        Button {
                            launchAtLogin.openSystemSettings()
                        } label: {
                            Label("Approval needed — open Login Items",
                                  systemImage: "exclamationmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .onAppear { launchAtLogin.refresh() }
            }

            HStack {
                Button("About") { showingAbout = true }
                    .accessibilityLabel("About Redlight")
                Spacer()
                Button(manager.isTerminating ? "Quitting…" : "Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .accessibilityLabel("Quit Redlight")
            }
        }
    }

    /// Applied adaptive intensity at each sample time — the same mapping the live filter
    /// uses. Memoized: recomputed only when the timeline ticks or the band/presets change.
    @MainActor
    private func appliedIntensities(_ cycle: SunCycle, at date: Date,
                                    coord: (latitude: Double, longitude: Double)) -> [Double] {
        let key = SunArcCache.IntensityKey(
            date: date, lat: coord.latitude, lon: coord.longitude,
            presets: manager.presets,
            iMin: manager.adaptiveMin, iMax: manager.adaptiveMax,
            wMin: manager.adaptiveWpMin, wMax: manager.adaptiveWpMax,
            intensityAdjustment: manager.adaptiveIntensityAdjustment
        )
        let minElev = sunCache.minElevation
        return sunCache.intensities(key: key) {
            cycle.samples.map { sample in
                manager.adaptiveIntensity(at: sample.elevation, minElevation: minElev)
            }
        }
    }
}

// MARK: - About

/// Credit page that replaces the controls when About is tapped. Same 300-pt column as the
/// rest of the popover; the app icon is the only visual, everything else is quiet type.
struct AboutView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .padding(.top, 8)

            Text(AboutInfo.name)
                .font(.headline)

            Text("by \(AboutInfo.author)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Version \(AboutInfo.version())")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Link(AboutInfo.repositoryDisplay, destination: AboutInfo.repositoryURL)
                .font(.caption)
                .padding(.top, 4)

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .accessibilityLabel("Close About")
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

// MARK: - Reset Button


/// Sits at the trailing edge of a slider and restores that control — value *and* adaptive
/// band — to factory settings. Dimmed and inert once there's nothing left to reset, so it
/// doubles as an at-a-glance "this row is untouched" indicator.
struct ResetButton: View {
    let help: String
    let isDefault: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isDefault ? Color.secondary.opacity(0.35) : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDefault)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Appearance Switch

/// Two-segment sun/moon pill that flips the *system* light/dark appearance. Sized to sit
/// flush with the header's `.headline` baseline without stretching the popover.
struct AppearanceSwitch: View {
    let isDark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                segment("sun.max.fill", selected: !isDark)
                segment("moon.fill", selected: isDark)
            }
            .background(
                Capsule().fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(isDark ? "Switch to Light Mode" : "Switch to Dark Mode")
        .accessibilityLabel("System appearance")
        .accessibilityValue(isDark ? "Dark" : "Light")
    }

    private func segment(_ symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(selected ? Color.primary : Color.secondary.opacity(0.5))
            .frame(width: 26, height: 20)
            .background(
                Capsule()
                    .fill(selected ? Color.primary.opacity(0.12) : .clear)
                    .padding(1)
            )
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
                .font(.system(size: 10))
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 2)
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
        .help(name)
        .accessibilityLabel(name)
    }
}
