import AppKit
import SwiftUI

/// The Settings page, pushed inside the popover: Auto's two times and the location it follows,
/// the general switches, then updates, About and Quit. Displays stay on the main page.
struct SettingsPage: View {
    let manager: DisplayManager
    let launchAtLogin: LaunchAtLogin?
    let openShortcuts: (() -> Void)?
    let dispatch: PopoverDispatch
    let session: PopoverSession
    let initialState: MenuBarInitialState
    /// The coordinate entry, owned by the popover so it outlasts a visit to About.
    let locationDraft: LocationDraft
    /// The time in the "Deepest by" field, owned by the popover for the same reason.
    let bedtimeDraft: BedtimeDraft
    /// The time in the "Clear by" field, likewise.
    let wakeDraft: BedtimeDraft
    let headerFocus: AccessibilityFocusState<MenuBarPage?>.Binding
    let back: () -> Void
    let showAbout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EmberMetrics.spacing) {
            EmberPageHeader(title: "Settings", titleFocus: (headerFocus, .settings), back: back)
            VStack(alignment: .leading, spacing: 6) {
                EmberGroupLabel("Auto")
                BedtimeCard(manager: manager, dispatch: dispatch, draft: bedtimeDraft, wakeDraft: wakeDraft)
            }
            VStack(alignment: .leading, spacing: 6) {
                EmberGroupLabel("Location for Auto")
                LocationSettingsCard(manager: manager, dispatch: dispatch, draft: locationDraft)
            }
            VStack(alignment: .leading, spacing: 6) {
                EmberGroupLabel("Units")
                EmberCard { ColorTempUnitRow() }
            }
            // Only a built app has an updater; a render can stand in for it.
            let hasUpdates = initialState.updatesAutomatically != nil || Updater.shared.isAvailable
            let hasNightShift = initialState.keepsNightShiftOff != nil || NightShiftGuard.shared.isAvailable
            if launchAtLogin != nil || hasUpdates || hasNightShift || openShortcuts != nil {
                VStack(alignment: .leading, spacing: 6) {
                    EmberGroupLabel("General")
                    EmberCard {
                        if let launchAtLogin {
                            LaunchAtLoginRows(launchAtLogin: launchAtLogin, dispatch: dispatch,
                                              requiresApproval: initialState.loginRequiresApproval)
                        }
                        if hasUpdates {
                            AutomaticUpdatesRow(divider: launchAtLogin != nil, stand: initialState.updatesAutomatically)
                        }
                        if hasNightShift {
                            NightShiftRow(divider: launchAtLogin != nil || hasUpdates,
                                          stand: initialState.keepsNightShiftOff)
                        }
                        if let openShortcuts {
                            ShortcutsRow(divider: launchAtLogin != nil || hasUpdates || hasNightShift,
                                         open: openShortcuts)
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

// MARK: - Bedtime

/// "Deepest by" and "Clear by", at the top of Settings. Its own view, so that the two times
/// are read here and a change to either evaluates this card and not the page.
private struct BedtimeCard: View {
    let manager: DisplayManager
    let dispatch: PopoverDispatch
    let draft: BedtimeDraft
    let wakeDraft: BedtimeDraft

    var body: some View {
        EmberCard {
            BedtimeRow(bedtime: manager.bedtime, draft: draft) { dispatch(.bedtime($0)) }
            BedtimeRow(kind: .wake, divider: true, bedtime: manager.wakeTime, draft: wakeDraft) {
                dispatch(.wake($0))
            }
            LearningRows(manager: manager, dispatch: dispatch)
        }
    }
}

/// "Learn my adjustments", under Auto's two times: the switch, and while it is on what has
/// been learned, a sentence per slider, with the button that forgets it.
struct LearningRows: View {
    static let title = "Learn my adjustments"
    static let explanation = "Auto learns how you set each slider at each time of day and starts doing it for you, following the sun through the seasons. The limits move to where you leave them. A big one-off change is ignored unless you make it again the next day."
    static let nothingYet = "Nothing learned yet. Adjust the sliders in Auto and it learns how you like them."
    static let matchesAuto = "So far your settings match Auto's own."
    static let resetTitle = "Reset learning"
    static let confirmText = "Reset what was learned on both sliders? Your limits are kept, and it is saved: `redlight learn restore` brings it back."
    static let confirmTitle = "Reset both sliders"
    static let cancelTitle = "Cancel"

    let manager: DisplayManager
    let dispatch: PopoverDispatch

    /// Reset asks first: the button shows this question and its two answers in its place.
    @State private var confirmingReset = false
    @Environment(\.emberPalette) private var palette
    @Environment(\.emberDisclose) private var disclose

    var body: some View {
        let enabled = manager.learningEnabled
        EmberRow(divider: true) {
            // The switch carries the name for VoiceOver, as the rows above do.
            Text(Self.title)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            EmberSwitch(Self.title, isOn: Binding(
                get: { enabled },
                set: { on in disclose { _ = dispatch(.learn(on ? .on : .off)) } }
            ))
        }
        .help(Self.explanation)
        // A pending confirmation must not survive turning learning off and back on.
        // The detail view is removed while disabled, so its own `onChange` cannot observe
        // this transition.
        .onChange(of: enabled) { _, isEnabled in
            if !isEnabled { confirmingReset = false }
        }
        if enabled {
            let summary = manager.learningSummary
            let hasLearned = manager.learnedAnchorCount > 0
            VStack(alignment: .leading, spacing: 6) {
                if hasLearned {
                    // The learned day itself, a line per slider; the words go to VoiceOver.
                    ForEach([CommandChannel.color, .whitepoint], id: \.self) { channel in
                        if let shape = manager.learnedShape(channel) {
                            LearnedShapeChart(
                                name: channel.displayName, shape: shape,
                                description: summary.first { $0.hasPrefix(channel.displayName) }
                                    ?? Self.matchesAuto)
                        }
                    }
                } else {
                    Text(Self.nothingYet)
                        .font(.ember(11))
                        .foregroundStyle(palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hasLearned, confirmingReset {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.confirmText)
                            .font(.ember(11))
                            .foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            EmberChipButton(title: Self.cancelTitle) { disclose { confirmingReset = false } }
                            EmberChipButton(title: Self.confirmTitle, isProminent: true) {
                                disclose {
                                    confirmingReset = false
                                    _ = dispatch(.learn(.reset))
                                }
                            }
                        }
                    }
                    .emberRevealTransition()
                } else if hasLearned {
                    EmberChipButton(title: Self.resetTitle) { disclose { confirmingReset = true } }
                        .emberRevealTransition()
                        .help("Forget what was learned on both sliders, after asking. Your limits are kept, and `redlight learn restore` brings it back.")
                }
            }
            .padding(.bottom, 8)
            // A question left open is closed when learning goes off or there is nothing left to reset.
            .onChange(of: hasLearned) { _, learned in if !learned { confirmingReset = false } }
            .emberRevealTransition()
        }
    }
}

/// One slider's learned day: Auto's own curve as a faint line, what was learned as a solid
/// line through the twelve parts of the day, from late night on the left to late night on
/// the right. A filled dot is a part of the day learned from what was kept.
struct LearnedShapeChart: View {
    let name: String
    let shape: DisplayManager.LearnedShape
    /// What VoiceOver reads for the chart.
    let description: String

    static let height: CGFloat = 40

    @Environment(\.emberPalette) private var palette

    var body: some View {
        let palette = self.palette
        let ink = palette.secondary, faint = palette.tertiary.opacity(0.6)
        HStack(alignment: .center, spacing: 8) {
            Text(name)
                .font(.ember(11))
                .foregroundStyle(palette.tertiary)
                .frame(width: 70, alignment: .leading)
            Canvas { ctx, size in
                let count = shape.learned.count
                guard count > 1 else { return }
                let inset: CGFloat = 3
                func point(_ index: Int, _ value: Double) -> CGPoint {
                    CGPoint(x: inset + CGFloat(index) / CGFloat(count - 1) * (size.width - 2 * inset),
                            y: inset + CGFloat(1 - min(1, max(0, value))) * (size.height - 2 * inset))
                }
                func line(_ values: [Double]) -> Path {
                    var path = Path()
                    for (index, value) in values.enumerated() {
                        if index == 0 { path.move(to: point(index, value)) } else { path.addLine(to: point(index, value)) }
                    }
                    return path
                }
                ctx.stroke(line(shape.plain), with: .color(faint),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]))
                ctx.stroke(line(shape.learned), with: .color(ink),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                for (index, value) in shape.learned.enumerated() {
                    let centre = point(index, value)
                    let dot = Path(ellipseIn: CGRect(x: centre.x - 2, y: centre.y - 2, width: 4, height: 4))
                    if shape.known.indices.contains(index), shape.known[index] {
                        ctx.fill(dot, with: .color(ink))
                    } else {
                        ctx.stroke(dot, with: .color(faint), lineWidth: 1)
                    }
                }
            }
            .frame(height: Self.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) through the day")
        .accessibilityValue(description)
    }
}

// MARK: - Location

/// Automatic, or coordinates the user enters. Coordinates apply only on submission, using
/// the same validation as the CLI.
private struct LocationSettingsCard: View {
    let manager: DisplayManager
    let dispatch: PopoverDispatch
    @Bindable var draft: LocationDraft
    @Environment(\.emberDisclose) private var disclose

    private var usesCoordinates: Bool { manager.manualLocation != nil || draft.isEditing }

    var body: some View {
        EmberCard(verticalPadding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                LocationRow(manager: manager)
                EmberSegmented(label: "Location for Auto",
                               options: [(value: false, title: "Automatic"), (value: true, title: "Coordinates")],
                               selection: usesCoordinates, onCard: true,
                               help: "Use coordinates you enter instead of Location Services or the time zone.",
                               select: { manual in disclose { setUsesCoordinates(manual) } })

                if usesCoordinates {
                    VStack(alignment: .leading, spacing: 8) {
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
                        .onPaneShown(perform: fillFields)

                        if let error = draft.error {
                            EmberErrorText(message: error)
                                .emberRevealTransition()
                        }
                    }
                    .emberRevealTransition()
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
            let message = error.localizedDescription
            disclose { draft.error = message }
        }
    }
}

// MARK: - General

/// Sparkle's "automatically download and install updates", as a switch. With it on, a new
/// version is fetched in the background and installed when Redlight next quits; with it off,
/// Redlight says an update is available and waits to be told.
private struct AutomaticUpdatesRow: View {
    static let title = "Update automatically"

    let divider: Bool
    /// A render's stand-in for the updater's setting; nil in the app.
    let stand: Bool?

    var body: some View {
        let updater = Updater.shared
        EmberRow(divider: divider) {
            // The switch carries the name for VoiceOver, as the display rows do.
            Text(Self.title)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            EmberSwitch(Self.title, isOn: Binding(
                get: { stand ?? updater.updatesAutomatically },
                set: { updater.setUpdatesAutomatically($0) }
            ))
            .disabled(stand == nil && !updater.canUpdateAutomatically)
        }
        .help("Download new versions in the background and install them when Redlight next quits")
    }
}

/// "Keep Night Shift off". Like the updater's switch it is the system's setting to change,
/// not the display model's, so it goes to the guard and not through the command layer.
private struct NightShiftRow: View {
    static let title = "Keep Night Shift off"

    let divider: Bool
    /// A render's stand-in for the guard's setting; nil in the app.
    let stand: Bool?

    var body: some View {
        let nightShift = NightShiftGuard.shared
        EmberRow(divider: divider) {
            // The switch carries the name for VoiceOver, as the display rows do.
            Text(Self.title)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            EmberSwitch(Self.title, isOn: Binding(
                get: { stand ?? nightShift.keepsOff },
                set: { nightShift.setKeepsOff($0) }
            ))
        }
        .help("Night Shift adds its own tint on top of Redlight's. Redlight turns it off whenever it comes on, without changing its schedule.")
    }
}

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
        .onPaneShown { launchAtLogin.refresh() }
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
