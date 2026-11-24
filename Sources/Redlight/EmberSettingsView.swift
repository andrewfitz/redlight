import AppKit
import SwiftUI

/// The Settings page, pushed inside the popover: the location Auto follows, the general
/// switches, then updates, About and Quit. Displays stay on the main page.
struct SettingsPage: View {
    let manager: DisplayManager
    let launchAtLogin: LaunchAtLogin?
    let openShortcuts: (() -> Void)?
    let apps: AppSuspensionController?
    let dispatch: PopoverDispatch
    let session: PopoverSession
    let initialState: MenuBarInitialState
    /// The coordinate entry, owned by the popover so it outlasts a visit to About.
    let locationDraft: LocationDraft
    let headerFocus: AccessibilityFocusState<MenuBarPage?>.Binding
    let back: () -> Void
    let showAbout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EmberMetrics.spacing) {
            EmberPageHeader(title: "Settings", titleFocus: (headerFocus, .settings), back: back)
            VStack(alignment: .leading, spacing: 6) {
                EmberGroupLabel("Location for Auto")
                LocationSettingsCard(manager: manager, dispatch: dispatch, draft: locationDraft)
            }
            if launchAtLogin != nil || apps != nil || openShortcuts != nil {
                VStack(alignment: .leading, spacing: 6) {
                    EmberGroupLabel("General")
                    EmberCard {
                        if let launchAtLogin {
                            LaunchAtLoginRows(launchAtLogin: launchAtLogin, dispatch: dispatch,
                                              requiresApproval: initialState.loginRequiresApproval)
                        }
                        if let apps {
                            PauseForAppsControl(apps: apps, dispatch: dispatch, divider: launchAtLogin != nil,
                                                startExpanded: initialState.choosingApps)
                        }
                        if let openShortcuts {
                            ShortcutsRow(divider: launchAtLogin != nil || apps != nil, open: openShortcuts)
                        }
                    }
                }
            }
            CommandErrorLine(session: session)
            SettingsBar(manager: manager, dispatch: dispatch, updateAvailable: initialState.updateAvailable,
                        showAbout: showAbout)
        }
    }
}

// MARK: - Location

/// Automatic, or coordinates the user enters. Coordinates apply only on submission, using
/// the same validation as the CLI.
private struct LocationSettingsCard: View {
    let manager: DisplayManager
    let dispatch: PopoverDispatch
    @Bindable var draft: LocationDraft

    private var usesCoordinates: Bool { manager.manualLocation != nil || draft.isEditing }

    var body: some View {
        EmberCard(verticalPadding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                EmberSegmented(label: "Location for Auto",
                               options: [(value: false, title: "Automatic"), (value: true, title: "Coordinates")],
                               selection: usesCoordinates, onCard: true,
                               help: "Use coordinates you enter instead of Location Services or the time zone.",
                               select: setUsesCoordinates)

                if usesCoordinates {
                    HStack(spacing: 6) {
                        EmberTextField(placeholder: "Latitude", text: $draft.latitudeText)
                            .accessibilityLabel("Latitude, -90 to 90")
                        EmberTextField(placeholder: "Longitude", text: $draft.longitudeText)
                            .accessibilityLabel("Longitude, -180 to 180")
                        EmberChipButton(title: "Set", isProminent: true, height: 24, cornerRadius: 7,
                                        action: setManualLocation)
                            .accessibilityLabel("Set manual location")
                    }
                    .onSubmit(setManualLocation)
                    .onAppear(perform: fillFields)

                    if let error = draft.error {
                        EmberErrorText(message: error)
                    }
                }
            }
        }
    }

    private func setUsesCoordinates(_ manual: Bool) {
        if manual {
            // Start from where Auto is now. The provider is asked, not the coordinate
            // Adaptive last resolved, which is stale or missing while the mode is Manual.
            draft.begin(editing: true)
            fill(from: manager.currentCoordinate)
        } else {
            draft.begin(editing: false)
            if manager.manualLocation != nil { dispatch(.location(.automatic)) }
        }
    }

    /// The fields are empty when Settings opens from the controls, and then show the saved
    /// coordinate or, after "Enter coordinates", wherever Auto is now. Typing that comes
    /// back from About is left alone.
    private func fillFields() {
        guard draft.latitudeText.isEmpty, draft.longitudeText.isEmpty else { return }
        fill(from: manager.manualLocation ?? manager.currentCoordinate)
    }

    private func fill(from coordinate: (latitude: Double, longitude: Double)?) {
        guard let coordinate else { return }
        draft.latitudeText = ManualLocation.text(coordinate.latitude)
        draft.longitudeText = ManualLocation.text(coordinate.longitude)
    }

    private func setManualLocation() {
        do {
            let coordinate = try ManualLocation.parse(latitude: draft.latitudeText, longitude: draft.longitudeText)
            draft.error = nil
            if dispatch(.location(.manual(latitude: coordinate.latitude, longitude: coordinate.longitude))) {
                draft.isEditing = false
            }
        } catch {
            draft.error = error.localizedDescription
        }
    }
}

// MARK: - General

private struct LaunchAtLoginRows: View {
    let launchAtLogin: LaunchAtLogin
    let dispatch: PopoverDispatch
    /// A render's stand-in for the login item's state; nil in the app.
    let requiresApproval: Bool?

    @Environment(\.emberPalette) private var palette
    @Environment(\.closeRedlightPopover) private var closePopover

    var body: some View {
        Group {
            EmberRow {
                // The switch carries the name for VoiceOver, as the display rows do.
                Text("Launch at login")
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                EmberSwitch("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { dispatch(.login($0)) }
                ))
            }
            if requiresApproval ?? launchAtLogin.requiresApproval {
                EmberRowButton(divider: true) {
                    closePopover()
                    launchAtLogin.openSystemSettings()
                } content: {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityHidden(true)
                    Text("Approval needed — open Login Items")
                        .font(.ember(12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    EmberChevron(direction: .right)
                }
                .foregroundStyle(palette.secondary)
                .help("Open Login Items in System Settings to approve Redlight")
                .accessibilityLabel("Approval needed, open Login Items")
            }
        }
        .onAppear { launchAtLogin.refresh() }
    }
}

private struct ShortcutsRow: View {
    let divider: Bool
    let open: () -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.closeRedlightPopover) private var closePopover

    var body: some View {
        EmberRowButton(divider: divider) {
            closePopover()
            open()
        } content: {
            Text("Keyboard shortcuts").foregroundStyle(palette.text)
            Spacer(minLength: 0)
            EmberChevron(direction: .right).foregroundStyle(palette.secondary)
        }
        .help("Keyboard Shortcuts")
        .accessibilityLabel("Keyboard Shortcuts")
    }
}

/// "Pause for apps": the row names the chosen apps and unfolds the list in place.
private struct PauseForAppsControl: View {
    let apps: AppSuspensionController
    let dispatch: PopoverDispatch
    let divider: Bool

    @State private var choosingApps: Bool
    @State private var runningApps: [RunningApp] = []
    @Environment(\.emberPalette) private var palette

    init(apps: AppSuspensionController, dispatch: PopoverDispatch, divider: Bool, startExpanded: Bool) {
        self.apps = apps
        self.dispatch = dispatch
        self.divider = divider
        _choosingApps = State(initialValue: startExpanded)
    }

    var body: some View {
        let chosen = apps.bundleIDs.map { (id: $0, name: apps.name(for: $0)) }
        Group {
            EmberRowButton(divider: divider) {
                // Captured once per unfolding rather than on every redraw.
                if !choosingApps { runningApps = apps.runningApps() }
                choosingApps.toggle()
            } content: {
                Text("Pause for apps")
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    Text(chosen.isEmpty ? "None" : chosen.map(\.name).joined(separator: ", "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    EmberChevron(direction: choosingApps ? .up : .down)
                }
                .foregroundStyle(palette.secondary)
                .layoutPriority(1)
            }
            .help("Suspend the tint while one of these apps is in front. Invert stays on.")
            .accessibilityLabel("Pause for apps")
            .accessibilityValue(choosingApps ? "Expanded" : "Collapsed")

            if choosingApps {
                PauseForAppsRow(chosen: chosen, running: runningApps, recent: apps.recentBundleID) {
                    dispatch(.apps($0))
                }
                .padding(.bottom, 6)
            }
        }
        .onAppear {
            if choosingApps, runningApps.isEmpty { runningApps = apps.runningApps() }
        }
    }
}

/// The chosen apps, each with a remove button, then running apps to add. The list has a
/// fixed height and scrolls, so it cannot stretch the popover.
struct PauseForAppsRow: View {
    static let rowHeight: CGFloat = 24
    static let visibleRows = 6
    /// How far a focused row's band reaches past the row on each side.
    static let focusReach: CGFloat = 6

    /// Bundle IDs with display names, in the order chosen.
    let chosen: [(id: String, name: String)]
    /// Running apps, captured when the row unfolds.
    let running: [RunningApp]
    let recent: String?
    let change: (CommandApps) -> Void

    @Environment(\.emberPalette) private var palette

    /// Running apps not yet chosen, once each, the app last in front first (most likely the
    /// one to add), then by name. Apps without a bundle identifier cannot be matched.
    static func candidates(running: [RunningApp], chosen: [String], recent: String?) -> [RunningApp] {
        var seen = Set(chosen.map { $0.folding(options: .caseInsensitive, locale: nil) })
        var recentApp: RunningApp?
        var others: [RunningApp] = []
        for app in running {
            guard let id = app.bundleID, (try? AppBundleID.validate(id)) != nil,
                  seen.insert(id.folding(options: .caseInsensitive, locale: nil)).inserted else { continue }
            if let recent, AppBundleID.matches(id, recent) {
                recentApp = app
            } else {
                others.append(app)
            }
        }
        others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let recentApp { others.insert(recentApp, at: 0) }
        return others
    }

    var body: some View {
        let candidates = Self.candidates(running: running, chosen: chosen.map(\.id), recent: recent)
        let rows = max(1, chosen.count + candidates.count)
        Column(rows: rows) {
            ForEach(chosen, id: \.id) { app in
                row(app.name, help: app.id, symbol: "minus.circle.fill", color: palette.text,
                    accessibility: "Stop pausing for \(app.name)") { change(.remove(app.id)) }
            }
            ForEach(candidates, id: \.processID) { app in
                if let id = app.bundleID {
                    row(app.name, help: id, symbol: "plus.circle", color: palette.secondary,
                        accessibility: "Pause for \(app.name)") { change(.add(id)) }
                }
            }
            if chosen.isEmpty && candidates.isEmpty {
                Text("No other apps are running")
                    .font(.ember(12))
                    .foregroundStyle(palette.tertiary)
                    .frame(height: Self.rowHeight)
            }
        }
    }

    /// The scrolling column the lines sit in. It is wider than its lines by the focus
    /// band's reach on each side: a scroll view clips, and would cut the band's ends off.
    struct Column<Content: View>: View {
        let rows: Int
        @ViewBuilder let content: Content

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, PauseForAppsRow.focusReach)
            }
            .padding(.horizontal, -PauseForAppsRow.focusReach)
            .frame(height: CGFloat(min(rows, PauseForAppsRow.visibleRows)) * PauseForAppsRow.rowHeight)
        }
    }

    private func row(_ name: String, help: String, symbol: String, color: Color, accessibility: String,
                     action: @escaping () -> Void) -> some View {
        EmberButton(action: action) { state in
            RowFace(name: name, symbol: symbol, color: color, isFocused: state.isFocused)
        }
        .help(help)
        .accessibilityLabel(accessibility)
    }

    /// One app's line as drawn. The focus band runs `focusReach` into the card's inset on
    /// each side, clear of the name and the symbol.
    struct RowFace: View {
        let name: String
        let symbol: String
        let color: Color
        let isFocused: Bool

        var body: some View {
            HStack(spacing: 6) {
                Text(name).font(.ember(12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
            }
            .foregroundStyle(color)
            .frame(height: PauseForAppsRow.rowHeight)
            .contentShape(Rectangle())
            .background {
                Color.clear
                    .emberFocusHalo(RoundedRectangle(cornerRadius: 6, style: .continuous),
                                    isFocused: isFocused, spread: 0)
                    .padding(.horizontal, -PauseForAppsRow.focusReach)
            }
        }
    }
}

// MARK: - Bottom bar

struct SettingsBar: View {
    let manager: DisplayManager
    let dispatch: PopoverDispatch
    /// A render's stand-in for the updater's state; nil in the app.
    let updateAvailable: Bool?
    let showAbout: () -> Void

    @Environment(\.closeRedlightPopover) private var closePopover

    var body: some View {
        HStack(spacing: 6) {
            // "Quitting…" is wider than "Quit", and with the update button the row would
            // no longer fit the popover. Nothing can be pressed while quitting, so the
            // update button gives up its place.
            if !manager.isTerminating, updateAvailable != nil || Updater.shared.isAvailable {
                let pending = updateAvailable ?? Updater.shared.hasPendingUpdate
                EmberPillButton(title: pending ? "Update Available" : "Check for updates", isProminent: pending) {
                    if dispatch(.update) { closePopover() }
                }
                .disabled(updateAvailable == nil && !Updater.shared.canCheckForUpdates)
                .accessibilityLabel(pending ? "Update available" : "Check for Updates")
            }
            EmberPillButton(title: "About", action: showAbout)
                .accessibilityLabel("About Redlight")
            Spacer(minLength: 0)
            EmberPillButton(title: manager.isTerminating ? "Quitting…" : "Quit") { dispatch(.quit) }
                .accessibilityLabel("Quit Redlight")
        }
    }
}

// MARK: - About

/// Credit page that replaces Settings when About is tapped. Same 300-pt column as the rest
/// of the popover; the app icon is the only visual, everything else is quiet type.
struct AboutView: View {
    let headerFocus: AccessibilityFocusState<MenuBarPage?>.Binding
    var onDone: () -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 6) {
            EmberPageHeader(title: "About", titleFocus: (headerFocus, .about), back: onDone)

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .padding(.top, 14)
                .accessibilityHidden(true)

            Text(AboutInfo.name)
                .font(.ember(22, .semibold))
                .tracking(-0.22)

            Text("by \(AboutInfo.author)")
                .font(.ember(12))
                .foregroundStyle(palette.secondary)

            Text("Version \(AboutInfo.version())")
                .font(.ember(11))
                .monospacedDigit()
                .foregroundStyle(palette.tertiary)

            EmberLinkButton(AboutInfo.repositoryDisplay) { openURL(AboutInfo.repositoryURL) }
                .accessibilityLabel(AboutInfo.repositoryDisplay)
                .accessibilityAddTraits(.isLink)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}
