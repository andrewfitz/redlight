import SwiftUI

/// Reuses the same day's sampled solar curve between timeline ticks and keeps the color
/// mapping tied to the exact snapshot. The cache does not publish changes to the view.
private final class SunArcCache {
    struct CycleKey: Equatable {
        var date: Date, lat: Double, lon: Double
        var calendar: Calendar
    }

    struct IntensityKey: Equatable {
        var cycle: CycleKey
        var presets: [Preset]
        var iMin: Double, iMax: Double
        var intensityAdjustment: Double
        var bedtime: Bedtime?
    }

    private var cycleKey: CycleKey?
    private var cycleValue: SunCycle?
    private(set) var minElevation: Double = 0
    private var intensityKey: IntensityKey?
    private var intensityValue: [Double] = []

    static let refreshInterval: TimeInterval = 20

    func cycle(for key: CycleKey) -> SunCycle {
        if let cycleValue, cycleKey == key { return cycleValue }
        let fresh = SunCycle(now: key.date, latitude: key.lat, longitude: key.lon,
                             calendar: key.calendar, reusing: cycleValue)
        minElevation = SolarCalculator.elevationAtSolarMidnight(
            at: key.date, latitude: key.lat, longitude: key.lon)
        cycleKey = key
        cycleValue = fresh
        return fresh
    }

    func intensities(key: IntensityKey, compute: () -> [Double]) -> [Double] {
        if intensityKey == key { return intensityValue }
        intensityValue = compute()
        intensityKey = key
        return intensityValue
    }
}

struct MenuBarView: View {
    @Bindable var manager: DisplayManager
    var launchAtLogin: LaunchAtLogin? = nil
    var handler: CommandHandler? = nil
    var openShortcuts: (() -> Void)? = nil
    var apps: AppSuspensionController? = nil

    @State private var sunCache = SunArcCache()
    @State private var appearance = AppearanceController.shared
    @State private var showingAbout = false
    @State private var choosingSaveTarget = false
    @State private var commandError: String?
    @State private var choosingPauseLength = false
    @State private var sunriseAvailable = true
    @State private var editingLocation = false
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var locationError: String?
    @State private var choosingApps = false
    @State private var runningApps: [RunningApp] = []
    @Environment(\.closeRedlightPopover) private var closePopover
    @Environment(\.calendar) private var calendar
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
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Redlight")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let pausedUntil = manager.pausedUntil {
                    // Ticks on the pause's own minute boundaries, from when it started. A
                    // sunrise pause is not whole minutes, so round back to one.
                    let start = pausedUntil.addingTimeInterval(-(manager.pauseLength / 60).rounded(.up) * 60)
                    TimelineView(.periodic(from: start, by: 60)) { context in
                        Text(DisplayManager.pauseCountdownText(until: pausedUntil, now: context.date))
                            .font(.caption)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(DisplayManager.pauseCountdownAccessibilityText(
                                until: pausedUntil, now: context.date))
                    }
                } else if manager.isOn, let app = manager.suspendedForApp {
                    Text("Suspended for \(app)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help("Redlight is suspended while \(app) is in front")
                        .accessibilityLabel("Suspended while \(app) is in front")
                }
                Spacer()
                PauseButton(isPaused: manager.isPaused) {
                    dispatch(.pause(manager.isPaused ? .off : .on))
                }
                .disabled(!manager.isOn && !manager.isPaused)
                // Other lengths unfold below the header.
                Button {
                    if !choosingPauseLength { sunriseAvailable = manager.nextSunrise() != nil }
                    choosingPauseLength.toggle()
                } label: {
                    Image(systemName: choosingPauseLength && canChoosePauseLength ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canChoosePauseLength)
                .help("Pause for another length")
                .accessibilityLabel("Pause lengths")
                .accessibilityValue(choosingPauseLength ? "Expanded" : "Collapsed")
                Toggle("Enable Redlight", isOn: Binding(
                    get: { manager.isOn },
                    set: { dispatch(.master($0 ? .on : .off)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enable Redlight")
                AppearanceSwitch(isDark: appearance.isDark) { dispatch(.appearance(.toggle)) }
            }
            .onChange(of: canChoosePauseLength) { _, available in
                if !available { choosingPauseLength = false }
            }

            if choosingPauseLength && canChoosePauseLength {
                PauseLengthRow(sunriseAvailable: sunriseAvailable) { length in
                    if dispatch(.pauseFor(length)) { choosingPauseLength = false }
                }
            }

            Divider()

            ForEach(manager.displays) { display in
                HStack {
                    Toggle(display.name, isOn: Binding(
                        get: { display.isEnabled },
                        set: { dispatch(.display(.key(display.persistenceKey), $0 ? .on : .off)) }
                    ))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(display.name)
                    Spacer()
                    Toggle("Invert", isOn: Binding(
                        get: { display.isInverted },
                        set: { dispatch(.invert(.key(display.persistenceKey), $0 ? .on : .off)) }
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
                Text("Color Temp")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    BandSlider(
                        value: $manager.intensity,
                        lowerBound: $manager.adaptiveMin,
                        upperBound: $manager.adaptiveMax,
                        range: 0.0...1.0,
                        showBand: manager.adaptiveEnabled,
                        label: "Color Temp",
                        onPreview: { manager.previewIntensity($0) },
                        onPreviewEnd: { manager.endPreview() },
                        onInteractionBegin: { manager.beginSliderInteraction() },
                        isInteractionCurrent: { manager.isSliderInteractionCurrent($0) }
                    )
                    ResetButton(
                        help: "Reset color temp and its limits to default",
                        isDefault: manager.intensityIsDefault
                    ) { dispatch(.reset(.color)) }
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
                        onPreviewEnd: { manager.endPreview() },
                        onInteractionBegin: { manager.beginSliderInteraction() },
                        isInteractionCurrent: { manager.isSliderInteractionCurrent($0) }
                    )
                    ResetButton(
                        help: "Reset white point and its limits to default",
                        isDefault: manager.whitepointIsDefault
                    ) { dispatch(.reset(.whitepoint)) }
                }
            }

            Divider()

            // MARK: - Presets

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(Array(manager.presets.enumerated()), id: \.offset) { index, preset in
                        PresetButton(
                            name: preset.name,
                            isActive: !choosingSaveTarget && manager.activePresetIndex == index
                        ) {
                            guard CommandPreset.allCases.indices.contains(index) else {
                                commandError = "This preset is unavailable."
                                return
                            }
                            let target = CommandPreset.allCases[index]
                            if choosingSaveTarget {
                                if dispatch(.savePreset(target)) { choosingSaveTarget = false }
                            } else {
                                dispatch(.preset(target))
                            }
                        }
                    }
                }

                // The preset row itself becomes the list of save targets.
                HStack(spacing: 6) {
                    Button(choosingSaveTarget ? "Cancel" : "Save to Preset…") {
                        choosingSaveTarget.toggle()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    if choosingSaveTarget {
                        Text("Pick a preset to overwrite")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }

            Divider()

            // MARK: - Adaptive

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Adaptive", isOn: Binding(
                    get: { manager.adaptiveEnabled },
                    set: { dispatch(.adaptive($0 ? .on : .off)) }
                ))
                    .font(.subheadline)
                    .help("Follow real solar elevation. You can still adjust either slider while Adaptive stays on.")
                    .accessibilityLabel("Adaptive solar mode")

                if manager.adaptiveEnabled && !manager.adaptiveStatusText.isEmpty {
                    if manager.adaptiveStatusText == "Location needed" {
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                closePopover()
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

                if manager.adaptiveEnabled, let nextEvent = manager.nextSolarEventText {
                    Text(nextEvent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if manager.adaptiveEnabled {
                    BedtimeRow(bedtime: manager.bedtime) { dispatch(.bedtime($0)) }
                    manualLocationControl
                }

                if manager.adaptiveEnabled, let coord = manager.coordinate {
                    TimelineView(.periodic(from: sunArcScheduleStart, by: SunArcCache.refreshInterval)) { context in
                        let key = SunArcCache.CycleKey(date: context.date, lat: coord.latitude,
                                                       lon: coord.longitude, calendar: calendar)
                        let cycle = sunCache.cycle(for: key)
                        SunArcView(
                            cycle: cycle,
                            intensities: appliedIntensities(cycle, key: key)
                        )
                    }
                }
            }

            Divider()

            if let apps {
                pauseForAppsControl(apps)
            }

            if let launchAtLogin {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { dispatch(.login($0)) }
                    ))
                        .font(.subheadline)
                        .accessibilityLabel("Launch Redlight at login")
                    if launchAtLogin.requiresApproval {
                        Button {
                            closePopover()
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

            if let commandError {
                Text(commandError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Command failed: \(commandError)")
            }

            HStack {
                Button("About") { showingAbout = true }
                    .accessibilityLabel("About Redlight")
                if Updater.shared.isAvailable {
                    Button(Updater.shared.hasPendingUpdate ? "Update Available" : "Updates…") {
                        if dispatch(.update) { closePopover() }
                    }
                    .disabled(!Updater.shared.canCheckForUpdates)
                    .accessibilityLabel(Updater.shared.hasPendingUpdate
                                        ? "Update available" : "Check for Updates")
                }
                Spacer()
                if let openShortcuts {
                    Button {
                        closePopover()
                        openShortcuts()
                    } label: {
                        Image(systemName: "keyboard")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Keyboard Shortcuts")
                }
                Button(manager.isTerminating ? "Quitting…" : "Quit") {
                    dispatch(.quit)
                }
                .accessibilityLabel("Quit Redlight")
            }
        }
    }

    private func pauseForAppsControl(_ apps: AppSuspensionController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                // Captured once per unfolding rather than on every redraw.
                if !choosingApps { runningApps = apps.runningApps() }
                choosingApps.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("Pause for apps")
                    if !apps.bundleIDs.isEmpty {
                        Text("\(apps.bundleIDs.count)")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    Image(systemName: choosingApps ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .help("Suspend the tint while one of these apps is in front. Invert stays on.")
            .accessibilityLabel("Pause for apps")
            .accessibilityValue(choosingApps ? "Expanded" : "Collapsed")

            if choosingApps {
                PauseForAppsRow(
                    chosen: apps.bundleIDs.map { (id: $0, name: apps.name(for: $0)) },
                    running: runningApps,
                    recent: apps.recentBundleID
                ) { dispatch(.apps($0)) }
            }
        }
    }

    /// Other lengths only make sense with a filter to pause and no pause running.
    private var canChoosePauseLength: Bool { manager.isOn && !manager.isPaused }

    /// Coordinates apply only on submission, using the same validation as the CLI.
    private var manualLocationControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Manual location", isOn: Binding(
                get: { manager.manualLocation != nil || editingLocation },
                set: { manual in
                    locationError = nil
                    if manual {
                        let start = manager.manualLocation ?? manager.coordinate
                        latitudeText = start.map { ManualLocation.text($0.latitude) } ?? ""
                        longitudeText = start.map { ManualLocation.text($0.longitude) } ?? ""
                        editingLocation = true
                    } else {
                        editingLocation = false
                        if manager.manualLocation != nil { dispatch(.location(.automatic)) }
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .help("Use coordinates you enter instead of Location Services or the time zone.")
            .accessibilityLabel("Use a manual location for Adaptive")

            if manager.manualLocation != nil || editingLocation {
                HStack(spacing: 6) {
                    TextField("Latitude", text: $latitudeText)
                        .accessibilityLabel("Latitude, -90 to 90")
                    TextField("Longitude", text: $longitudeText)
                        .accessibilityLabel("Longitude, -180 to 180")
                    Button("Set", action: setManualLocation)
                        .accessibilityLabel("Set manual location")
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(setManualLocation)
                .onAppear {
                    // Reopening the menu shows the saved coordinate, not stale typing.
                    if !editingLocation, let manual = manager.manualLocation {
                        latitudeText = ManualLocation.text(manual.latitude)
                        longitudeText = ManualLocation.text(manual.longitude)
                    }
                }

                if let locationError {
                    Text(locationError)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func setManualLocation() {
        do {
            let coordinate = try ManualLocation.parse(latitude: latitudeText, longitude: longitudeText)
            locationError = nil
            if dispatch(.location(.manual(latitude: coordinate.latitude, longitude: coordinate.longitude))) {
                editingLocation = false
            }
        } catch {
            locationError = error.localizedDescription
        }
    }

    /// The live app always supplies the shared handler. Keeping it optional permits
    /// isolated view previews without constructing services that change macOS settings.
    @discardableResult
    private func dispatch(_ action: PopoverAction) -> Bool {
        commandError = PopoverCommandDispatch(handler: handler).execute(action)
        return commandError == nil
    }

    /// Applied adaptive intensity at each sample time — the same mapping the live filter
    /// uses. Memoized: recomputed only when the timeline ticks or the band/presets change.
    @MainActor
    private func appliedIntensities(_ cycle: SunCycle, key cycleKey: SunArcCache.CycleKey) -> [Double] {
        let key = SunArcCache.IntensityKey(
            cycle: cycleKey,
            presets: manager.presets,
            iMin: manager.adaptiveMin, iMax: manager.adaptiveMax,
            intensityAdjustment: manager.adaptiveIntensityAdjustment,
            bedtime: manager.bedtime
        )
        let minElev = sunCache.minElevation
        return sunCache.intensities(key: key) {
            cycle.samples.map { sample in
                manager.adaptiveIntensity(
                    at: sample.elevation, minElevation: minElev, rising: sample.rising,
                    time: (date: sample.date, longitude: cycleKey.lon))
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

// MARK: - Pause Button

/// Pauses the tint for 30 minutes; shows play while paused so a click resumes.
struct PauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isPaused ? Color.red : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "Resume Redlight" : "Pause Redlight for 30 minutes")
    }
}

/// The header's other pause lengths, styled like the Save to Preset row. "Until sunrise"
/// is disabled when there is no sunrise to find; the command would only report an error.
struct PauseLengthRow: View {
    struct Option {
        let title: String
        let accessibility: String
        let length: CommandPauseLength
    }

    static let options = [
        Option(title: "30 m", accessibility: "Pause for 30 minutes", length: .minutes(30)),
        Option(title: "1 h", accessibility: "Pause for 1 hour", length: .minutes(60)),
        Option(title: "2 h", accessibility: "Pause for 2 hours", length: .minutes(120)),
        Option(title: "Until sunrise", accessibility: "Pause until sunrise", length: .untilSunrise),
    ]

    let sunriseAvailable: Bool
    let choose: (CommandPauseLength) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Pause for")
                .foregroundStyle(.tertiary)
            ForEach(Self.options, id: \.title) { option in
                let disabled = option.length == .untilSunrise && !sunriseAvailable
                Button(option.title) { choose(option.length) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(disabled)
                    .help(disabled ? "Sunrise is unavailable for the current location" : option.accessibility)
                    .accessibilityLabel(option.accessibility)
            }
        }
        .font(.caption)
    }
}

// MARK: - Pause for Apps

/// "Pause for apps": the chosen apps, each with a remove button, then running apps to add.
/// The list has a fixed height and scrolls, so it cannot stretch the popover.
struct PauseForAppsRow: View {
    static let rowHeight: CGFloat = 20
    static let visibleRows = 6

    /// Bundle IDs with display names, in the order chosen.
    let chosen: [(id: String, name: String)]
    /// Running apps, captured when the row unfolds.
    let running: [RunningApp]
    let recent: String?
    let change: (CommandApps) -> Void

    /// Running apps not yet chosen, once each, the app last in front first (most likely the
    /// one to add), then by name. Apps without a bundle identifier cannot be matched.
    static func candidates(running: [RunningApp], chosen: [String], recent: String?) -> [RunningApp] {
        var seen: [String] = []
        let apps = running.filter { app in
            guard let id = app.bundleID, !chosen.contains(where: { AppBundleID.matches($0, id) }),
                  !seen.contains(where: { AppBundleID.matches($0, id) }) else { return false }
            seen.append(id)
            return true
        }
        return apps.sorted { a, b in
            let aRecent = recent.map { id in a.bundleID.map { AppBundleID.matches($0, id) } ?? false } ?? false
            let bRecent = recent.map { id in b.bundleID.map { AppBundleID.matches($0, id) } ?? false } ?? false
            if aRecent != bRecent { return aRecent }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        let candidates = Self.candidates(running: running, chosen: chosen.map(\.id), recent: recent)
        let rows = max(1, chosen.count + candidates.count)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(chosen, id: \.id) { app in
                    row(app.name, help: app.id, symbol: "minus.circle.fill",
                        accessibility: "Stop pausing for \(app.name)") { change(.remove(app.id)) }
                }
                ForEach(candidates, id: \.processID) { app in
                    if let id = app.bundleID {
                        row(app.name, help: id, symbol: "plus.circle",
                            accessibility: "Pause for \(app.name)") { change(.add(id)) }
                            .foregroundStyle(.secondary)
                    }
                }
                if chosen.isEmpty && candidates.isEmpty {
                    Text("No other apps are running")
                        .foregroundStyle(.tertiary)
                        .frame(height: Self.rowHeight)
                }
            }
        }
        .frame(height: CGFloat(min(rows, Self.visibleRows)) * Self.rowHeight)
        .font(.caption)
    }

    private func row(_ name: String, help: String, symbol: String, accessibility: String,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(name).lineLimit(1).truncationMode(.tail).help(help)
            Spacer(minLength: 4)
            Button(action: action) {
                Image(systemName: symbol)
                    .frame(width: 16, height: Self.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibility)
        }
        .frame(height: Self.rowHeight)
        .padding(.trailing, 4)
    }
}

// MARK: - Bedtime Row

/// "Deepest by" for Adaptive: a checkbox and a time field that remembers its draft.
struct BedtimeRow: View {
    static let suggested = Bedtime(hour: 22, minute: 30)!

    let bedtime: Bedtime?
    let choose: (CommandBedtime) -> Void
    /// The time in the field, kept across menu openings so unchecking does not lose it.
    @AppStorage("redlight.adaptiveBedtimeDraft") private var draftMinute = BedtimeRow.suggested.minuteOfDay

    private var draft: Bedtime { Bedtime(minuteOfDay: draftMinute) ?? Self.suggested }

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Deepest by", isOn: Binding(
                get: { bedtime != nil },
                set: { on in
                    choose(on ? .at(hour: draft.hour, minute: draft.minute) : .off)
                }
            ))
            .toggleStyle(.checkbox)
            .help("Reach the deepest end of both bands by this time, even if the sun is still up. Mornings still follow the sun.")
            .accessibilityLabel("Reach the deepest setting by a bedtime")

            // Editing only moves the draft: the field reports every digit and arrow click,
            // and each applied time restarts the fade and saves.
            DatePicker("Bedtime", selection: Binding(
                get: { Self.date(for: draft) },
                set: { draftMinute = Self.bedtime(from: $0).minuteOfDay }
            ), displayedComponents: .hourAndMinute)
            .datePickerStyle(.stepperField)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Bedtime")

            if let bedtime, bedtime != draft {
                Button("Set") { choose(.at(hour: draft.hour, minute: draft.minute)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Set bedtime to \(draft.text)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .onAppear { if let bedtime { draftMinute = bedtime.minuteOfDay } }
        .onChange(of: bedtime) { _, new in if let new { draftMinute = new.minuteOfDay } }
    }

    /// The time field edits a full date; pin it to a reference day with no DST change in any
    /// time zone so every hour and minute exists exactly once.
    static func date(for bedtime: Bedtime, calendar: Calendar = .current) -> Date {
        let day = DateComponents(year: 2001, month: 1, day: 15, hour: bedtime.hour, minute: bedtime.minute)
        return calendar.date(from: day) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    static func bedtime(from date: Date, calendar: Calendar = .current) -> Bedtime {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Bedtime(hour: parts.hour ?? 0, minute: parts.minute ?? 0) ?? suggested
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
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Shared by the popover and its tests: failed actions stay visible to the user.
@MainActor
struct PopoverCommandDispatch {
    var handler: CommandHandler?

    func execute(_ action: PopoverAction) -> String? {
        guard let handler else { return "Redlight controls are unavailable. Reopen the app to try again." }
        do {
            _ = try handler.execute(action.command)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
