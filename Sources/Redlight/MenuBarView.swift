import SwiftUI

/// The popover, in the Ember layout: displays on top, then Auto or Manual, then the bar.
///
/// Redraw isolation: `MenuBarView.body` reads only the page and `isTerminating`. Every
/// model value is read in the body of the small view that shows it, so a slider tick
/// re-evaluates the slider rows (and the views that paint with the accent), a pause minute
/// the header status, and the arc's timeline the arc.

/// Which page the popover shows. Settings and About are pushed in place of the controls.
enum MenuBarPage: Equatable, Sendable {
    case controls, settings, about
}

/// Presentation state that otherwise only a click can reach, so an offscreen render can
/// open the popover in any of its states. The live app uses the defaults.
struct MenuBarInitialState {
    var commandError: String? = nil
    var choosingSaveTarget = false
    var choosingPauseLength = false
    /// Pause for apps unfolded, on the Settings page.
    var choosingApps = false
    /// Coordinates selected on the Settings page before a manual location is saved.
    var editingLocation = false
    var latitudeText: String? = nil
    var longitudeText: String? = nil
    var locationError: String? = nil
    /// True shows the update dot and the "Update Available" button. Nil asks the updater.
    var updateAvailable: Bool? = nil
    /// True shows the Settings dot and the "Approval needed" row. Nil asks the login item.
    var loginRequiresApproval: Bool? = nil
}

/// The coordinates being typed on the Settings page. Held above the pages, so a visit to
/// About returns to the same fields instead of a fresh, empty card.
@MainActor
@Observable
final class LocationDraft {
    /// Coordinates is selected although no manual location is saved yet.
    var isEditing: Bool
    var latitudeText: String
    var longitudeText: String
    var error: String?

    init(isEditing: Bool = false, latitudeText: String = "", longitudeText: String = "", error: String? = nil) {
        self.isEditing = isEditing
        self.latitudeText = latitudeText
        self.longitudeText = longitudeText
        self.error = error
    }

    /// Settings opened from the controls: nothing is carried over from the last visit.
    func begin(editing: Bool) {
        isEditing = editing
        latitudeText = ""
        longitudeText = ""
        error = nil
    }
}

/// The time in the "Deepest by" field. It is kept in the defaults, so that switching the
/// bedtime off, leaving the page or closing the popover does not lose it.
///
/// It is read from the defaults once and written when it changes. `@AppStorage` would
/// evaluate the row again on every change to the defaults, and the manager saves to them
/// on every slider tick.
@MainActor
@Observable
final class BedtimeDraft {
    static let key = "redlight.adaptiveBedtimeDraft"

    private(set) var bedtime: Bedtime
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        bedtime = (defaults.object(forKey: Self.key) as? Int).flatMap { Bedtime(minuteOfDay: $0) }
            ?? BedtimeRow.suggested
    }

    func set(_ new: Bedtime) {
        guard new != bedtime else { return }
        bedtime = new
        defaults.set(new.minuteOfDay, forKey: Self.key)
    }
}

/// The command error is the one piece of state every section can change. Holding it in an
/// observable object means only the error line redraws when it does.
@MainActor
@Observable
final class PopoverSession {
    var commandError: String?

    init(commandError: String? = nil) {
        self.commandError = commandError
    }
}

/// Runs a popover action through the shared command layer and keeps a failure visible.
@MainActor
struct PopoverDispatch {
    let handler: CommandHandler?
    let session: PopoverSession

    @discardableResult
    func callAsFunction(_ action: PopoverAction) -> Bool {
        session.commandError = PopoverCommandDispatch(handler: handler).execute(action)
        return session.commandError == nil
    }
}

struct MenuBarView: View {
    let manager: DisplayManager
    var launchAtLogin: LaunchAtLogin?
    /// The live app always supplies the shared handler. Keeping it optional permits
    /// isolated renders without constructing services that change macOS settings.
    var handler: CommandHandler?
    var openShortcuts: (() -> Void)?
    var apps: AppSuspensionController?
    var initialState: MenuBarInitialState

    @State private var page: MenuBarPage
    @State private var session: PopoverSession
    @State private var locationDraft: LocationDraft
    @State private var bedtimeDraft: BedtimeDraft
    /// The header VoiceOver is sent to when one page replaces another.
    @AccessibilityFocusState private var focusedHeader: MenuBarPage?

    /// `defaults` is where the popover keeps what it remembers between openings: the same
    /// store the manager was given.
    init(manager: DisplayManager, defaults: UserDefaults = .standard,
         launchAtLogin: LaunchAtLogin? = nil, handler: CommandHandler? = nil,
         openShortcuts: (() -> Void)? = nil, apps: AppSuspensionController? = nil,
         initialState: MenuBarInitialState = MenuBarInitialState(),
         initialPage: MenuBarPage = .controls) {
        self.manager = manager
        self.launchAtLogin = launchAtLogin
        self.handler = handler
        self.openShortcuts = openShortcuts
        self.apps = apps
        self.initialState = initialState
        _page = State(initialValue: initialPage)
        _session = State(initialValue: PopoverSession(commandError: initialState.commandError))
        _locationDraft = State(initialValue: LocationDraft(
            isEditing: initialState.editingLocation,
            latitudeText: initialState.latitudeText ?? "",
            longitudeText: initialState.longitudeText ?? "",
            error: initialState.locationError))
        _bedtimeDraft = State(initialValue: BedtimeDraft(defaults: defaults))
    }

    var body: some View {
        let dispatch = PopoverDispatch(handler: handler, session: session)
        EmberSurface {
            // The accent follows the live colour temp. The closure is not called here or in
            // the scope: each view that paints with the accent calls it in its own body.
            EmberAccentScope(intensity: { manager.intensity }) {
                switch page {
                case .controls:
                    ControlsPage(manager: manager, launchAtLogin: launchAtLogin, dispatch: dispatch,
                                 session: session, initialState: initialState,
                                 bedtimeDraft: bedtimeDraft,
                                 headerFocus: $focusedHeader) { enterCoordinates in
                        locationDraft.begin(editing: enterCoordinates)
                        page = .settings
                    }
                case .settings:
                    SettingsPage(manager: manager, launchAtLogin: launchAtLogin,
                                 openShortcuts: openShortcuts, apps: apps, dispatch: dispatch,
                                 session: session, initialState: initialState,
                                 locationDraft: locationDraft, headerFocus: $focusedHeader,
                                 back: { page = .controls }, showAbout: { page = .about })
                case .about:
                    AboutView(headerFocus: $focusedHeader) { page = .settings }
                }
            }
        }
        .disabled(manager.isTerminating)
        .frame(width: EmberMetrics.width)
        .onChange(of: page) { _, shown in
            // The control that was activated has gone with its page. Hand VoiceOver to the
            // new page's header, on the next turn, once that page is in the tree.
            Task { @MainActor in focusedHeader = shown }
        }
    }
}

/// The panel: its own warm background, the rounded face and the text colour.
private struct EmberSurface<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.emberPalette) private var palette

    var body: some View {
        content
            .font(.ember(13))
            .fontDesign(.rounded)
            .foregroundStyle(palette.text)
            .padding(EmberMetrics.padding)
            .frame(width: EmberMetrics.width, alignment: .topLeading)
            .background(palette.background.color)
    }
}

// MARK: - Controls page

private struct ControlsPage: View {
    let manager: DisplayManager
    let launchAtLogin: LaunchAtLogin?
    let dispatch: PopoverDispatch
    let session: PopoverSession
    let initialState: MenuBarInitialState
    let bedtimeDraft: BedtimeDraft
    let headerFocus: AccessibilityFocusState<MenuBarPage?>.Binding
    /// True opens Settings on the coordinate fields.
    let openSettings: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EmberMetrics.spacing) {
            PopoverHeader(manager: manager, dispatch: dispatch, headerFocus: headerFocus,
                          choosingPauseLength: initialState.choosingPauseLength)
            DisplaysCard(manager: manager, dispatch: dispatch)
            ModeControl(manager: manager, dispatch: dispatch)
            ModeContent(manager: manager, dispatch: dispatch, session: session,
                        choosingSaveTarget: initialState.choosingSaveTarget, openSettings: openSettings)
            SettingsCard(manager: manager, launchAtLogin: launchAtLogin, dispatch: dispatch,
                         bedtimeDraft: bedtimeDraft, updateAvailable: initialState.updateAvailable,
                         loginRequiresApproval: initialState.loginRequiresApproval) { openSettings(false) }
            CommandErrorLine(session: session)
        }
        // A login item waiting for approval shows as the Settings dot, so ask on every
        // opening, not only once the Settings page is up.
        .onAppear { launchAtLogin?.refresh() }
    }
}

// MARK: - Header

/// The title, then Pause, the system appearance and the master switch. What the tint is
/// doing when it is not simply on reads on a line of its own beneath, and the other pause
/// lengths unfold below that.
private struct PopoverHeader: View {
    let manager: DisplayManager
    let dispatch: PopoverDispatch
    let headerFocus: AccessibilityFocusState<MenuBarPage?>.Binding

    @State private var choosingPauseLength: Bool
    @State private var sunriseAvailable = true
    /// Moves VoiceOver to Resume when a chosen length takes its row away.
    @AccessibilityFocusState private var pauseFocused: Bool

    init(manager: DisplayManager, dispatch: PopoverDispatch,
         headerFocus: AccessibilityFocusState<MenuBarPage?>.Binding, choosingPauseLength: Bool) {
        self.manager = manager
        self.dispatch = dispatch
        self.headerFocus = headerFocus
        _choosingPauseLength = State(initialValue: choosingPauseLength)
    }

    /// Other lengths only make sense with a filter to pause and no pause running.
    private var canChoosePauseLength: Bool { manager.isOn && !manager.isPaused }

    var body: some View {
        let isDark = AppearanceController.shared.isDark
        let isPaused = manager.isPaused
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Redlight")
                    .font(.ember(14, .semibold))
                    .tracking(-0.14)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused(headerFocus, equals: .controls)
                Spacer(minLength: 0)
                PauseControl(
                    isPaused: isPaused,
                    isExpanded: choosingPauseLength && canChoosePauseLength,
                    focus: $pauseFocused,
                    showsTitle: false,
                    toggle: { dispatch(.pause(manager.isPaused ? .off : .on)) },
                    toggleLengths: {
                        if !choosingPauseLength { sunriseAvailable = manager.nextSunrise() != nil }
                        choosingPauseLength.toggle()
                    }
                )
                // Resume always works; Pause needs a filter to pause.
                .disabled(!isPaused && !manager.isOn)
                EmberIconButton(systemImage: isDark ? "moon.fill" : "sun.max") {
                    dispatch(.appearance(.toggle))
                }
                .help(isDark ? "Switch to Light Mode" : "Switch to Dark Mode")
                .accessibilityLabel("System appearance")
                .accessibilityValue(isDark ? "Dark" : "Light")
                EmberSwitch("Enable Redlight", isOn: Binding(
                    get: { manager.isOn },
                    set: { dispatch(.master($0 ? .on : .off)) }
                ))
                .padding(.leading, 2)
            }
            .frame(height: EmberMetrics.controlHeight)
            HeaderStatus(manager: manager)
            if choosingPauseLength && canChoosePauseLength {
                PauseLengthRow(sunriseAvailable: sunriseAvailable) { length in
                    guard dispatch(.pauseFor(length)) else { return }
                    choosingPauseLength = false
                    // The chip that was pressed goes with its row.
                    Task { @MainActor in pauseFocused = true }
                }
            }
        }
        .onChange(of: canChoosePauseLength) { _, available in
            if !available { choosingPauseLength = false }
        }
        .onAppear {
            if choosingPauseLength { sunriseAvailable = manager.nextSunrise() != nil }
        }
    }
}

/// What the tint is doing when it is not simply on: quitting, paused, or off for an app.
private struct HeaderStatus: View {
    let manager: DisplayManager
    @Environment(\.emberPalette) private var palette

    var body: some View {
        Group {
            if manager.isTerminating {
                Text("Quitting…")
            } else if let pausedUntil = manager.pausedUntil {
                // Ticks on the pause's own minute boundaries, from when it started. A
                // sunrise pause is not whole minutes, so round back to one.
                let start = pausedUntil.addingTimeInterval(-(manager.pauseLength / 60).rounded(.up) * 60)
                TimelineView(.periodic(from: start, by: 60)) { context in
                    Text("Paused, \(DisplayManager.pauseCountdownText(until: pausedUntil, now: context.date)) left")
                        .monospacedDigit()
                        .accessibilityLabel(DisplayManager.pauseCountdownAccessibilityText(
                            until: pausedUntil, now: context.date))
                }
            } else if manager.isOn, let app = manager.suspendedForApp {
                Text("Off for \(app)")
                    .help("Redlight is suspended while \(app) is in front")
                    .accessibilityLabel("Suspended while \(app) is in front")
            }
        }
        .font(.ember(12))
        .foregroundStyle(palette.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.85)
        .layoutPriority(1)
    }
}

// MARK: - Displays

private struct DisplaysCard: View {
    let manager: DisplayManager
    let dispatch: PopoverDispatch
    @Environment(\.emberPalette) private var palette

    var body: some View {
        EmberCard {
            if manager.displays.isEmpty {
                EmberRow {
                    Text("No displays detected")
                        .foregroundStyle(palette.secondary)
                }
            }
            ForEach(Array(manager.displays.enumerated()), id: \.element.id) { index, display in
                DisplayRow(display: display, divider: index > 0, dispatch: dispatch)
            }
        }
    }
}

/// The spaces of a display row.
///
/// "Built-in Retina Display" is the name of every MacBook's own screen, and it has to fit
/// between the glyph and the Invert chip at the popover's width: 131 pt of the row's 244.
/// At a card row's usual 8 pt between pieces and 8 pt of chip padding the name had 126.5 pt
/// and lost its last four letters. These leave it 134.5 pt.
enum DisplayRowMetrics {
    static let glyphWidth: CGFloat = 17
    /// Between the glyph, the name, the chip and the switch.
    static let spacing: CGFloat = 6
    /// Either side of "Invert" in its chip.
    static let chipPadding: CGFloat = 7
}

private struct DisplayRow: View {
    let display: DisplayManager.DisplayInfo
    let divider: Bool
    let dispatch: PopoverDispatch
    @Environment(\.emberPalette) private var palette

    var body: some View {
        let key = display.persistenceKey
        EmberRow(divider: divider, spacing: DisplayRowMetrics.spacing) {
            Group {
                Image(systemName: CGDisplayIsBuiltin(display.id) != 0 ? "laptopcomputer" : "display")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: DisplayRowMetrics.glyphWidth)
                    .accessibilityHidden(true)
                Text(display.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The name takes the room up to the Invert chip and truncates only there.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(display.name)
                    .accessibilityHidden(true)
            }
            // An off display steps down in brightness; its controls stay live.
            .foregroundStyle(display.isEnabled ? palette.text : palette.tertiary)
            EmberChipToggle(title: "Invert", isOn: Binding(
                get: { display.isInverted },
                set: { dispatch(.invert(.key(key), $0 ? .on : .off)) }
            ), horizontalPadding: DisplayRowMetrics.chipPadding)
            .accessibilityLabel("Invert colors on \(display.name)")
            EmberSwitch(display.name, isOn: Binding(
                get: { display.isEnabled },
                set: { dispatch(.display(.key(key), $0 ? .on : .off)) }
            ))
        }
    }
}

// MARK: - Auto / Manual

/// The mode is the model's `adaptiveEnabled`, not local state: the CLI can flip it while
/// the popover is open.
private struct ModeControl: View {
    let manager: DisplayManager
    let dispatch: PopoverDispatch

    var body: some View {
        EmberSegmented(
            label: "Mode", options: [(value: true, title: "Auto"), (value: false, title: "Manual")],
            selection: manager.adaptiveEnabled,
            help: "Auto follows real solar elevation. You can still adjust either slider while Auto stays on."
        ) { dispatch(.adaptive($0 ? .on : .off)) }
    }
}

/// Everything between the mode control and the bar. The two sliders are shared by both
/// modes, so a drag survives a mode change made from the CLI.
private struct ModeContent: View {
    let manager: DisplayManager
    let dispatch: PopoverDispatch
    let session: PopoverSession
    let openSettings: (Bool) -> Void

    @State private var choosingSaveTarget: Bool

    init(manager: DisplayManager, dispatch: PopoverDispatch, session: PopoverSession,
         choosingSaveTarget: Bool, openSettings: @escaping (Bool) -> Void) {
        self.manager = manager
        self.dispatch = dispatch
        self.session = session
        self.openSettings = openSettings
        _choosingSaveTarget = State(initialValue: choosingSaveTarget)
    }

    var body: some View {
        let auto = manager.adaptiveEnabled
        VStack(alignment: .leading, spacing: EmberMetrics.spacing) {
            if auto {
                AutoHeadline(manager: manager) { openSettings(true) }
                SunArcSection(manager: manager)
            } else {
                PresetSwatches(manager: manager, isSaveTarget: choosingSaveTarget, choose: choosePreset)
            }
            SliderRow(manager: manager, channel: .color, dispatch: dispatch)
            SliderRow(manager: manager, channel: .whitepoint, dispatch: dispatch)
            if !auto {
                SaveToPreset(isChoosing: $choosingSaveTarget)
            }
        }
        .onChange(of: auto) { _, _ in choosingSaveTarget = false }
    }

    private func choosePreset(_ index: Int) {
        guard CommandPreset.allCases.indices.contains(index) else {
            session.commandError = "This preset is unavailable."
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

// MARK: - Auto

/// The headline of Auto: the next solar event, or what stands in the way of one.
struct AutoHeadline: View {
    let manager: DisplayManager
    let enterCoordinates: () -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.closeRedlightPopover) private var closePopover

    var body: some View {
        if manager.coordinate == nil {
            if manager.adaptiveStatusText == "Location needed" {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        headline("Auto needs your location")
                        Text("It stays on this Mac. Holding the current setting until then.")
                            .font(.ember(12))
                            .foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        EmberPillButton(title: "Open Settings", isProminent: true) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                closePopover()
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .help("Open Location Services in System Settings")
                        .accessibilityLabel("Open Location Services settings")
                        EmberPillButton(title: "Enter coordinates", action: enterCoordinates)
                            .accessibilityLabel("Enter coordinates")
                    }
                }
            } else {
                headline(manager.adaptiveStatusText.isEmpty ? "Locating…" : manager.adaptiveStatusText)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                headline(manager.nextSolarEventText ?? "Following the sun")
                if let subline {
                    Text(subline)
                        .font(.ember(12))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The bedtime only while the curve will use it tonight; otherwise the status line, which
    /// also says where the location comes from and whether a slider was adjusted.
    private var subline: String? {
        if let bedtime = manager.effectiveBedtime {
            return "Deepest red by \(BedtimeRow.clockText(bedtime))"
        }
        return manager.adaptiveStatusText.isEmpty ? nil : manager.adaptiveStatusText
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.ember(22, .semibold))
            .tracking(-0.22)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Self.spokenText(text))
    }

    /// A headline as VoiceOver should say it: "Sunset in 1 h 12 m" becomes "Sunset in 1 hour
    /// 12 minutes". The letters would otherwise be read as letters. Made from the visible
    /// text, so the two cannot disagree; text without a count and a unit comes back as it is.
    static func spokenText(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in words.indices.dropFirst() {
            guard let count = Int(words[index - 1]) else { continue }
            switch words[index] {
            case "h": words[index] = count == 1 ? "hour" : "hours"
            case "m": words[index] = count == 1 ? "minute" : "minutes"
            default: break
            }
        }
        return words.joined(separator: " ")
    }
}

/// Reuses the same day's sampled solar curve between timeline ticks. The cache does not
/// publish changes to the view.
private final class SunArcCache {
    struct CycleKey: Equatable {
        var date: Date, lat: Double, lon: Double
        var calendar: Calendar
    }

    private var cycleKey: CycleKey?
    private var cycleValue: SunCycle?

    static let refreshInterval: TimeInterval = 20

    func cycle(for key: CycleKey) -> SunCycle {
        if let cycleValue, cycleKey == key { return cycleValue }
        let fresh = SunCycle(now: key.date, latitude: key.lat, longitude: key.lon,
                             calendar: key.calendar, reusing: cycleValue)
        cycleKey = key
        cycleValue = fresh
        return fresh
    }
}

/// The sun arc, on its own timeline. Nothing is drawn until there is a location.
private struct SunArcSection: View {
    let manager: DisplayManager

    @State private var cache = SunArcCache()
    // Fixed anchor: `.periodic(from: .now, …)` would build a new schedule on every body
    // evaluation and restart the timeline (and its date).
    @State private var scheduleStart = Date()
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    var body: some View {
        if let coord = manager.coordinate {
            // Read here, so a new bedtime redraws the arc at once. Whether tonight's curve
            // uses it is asked again on every tick: the moon is only drawn when it does.
            let hasBedtime = manager.bedtime != nil
            TimelineView(.periodic(from: scheduleStart, by: SunArcCache.refreshInterval)) { context in
                let key = SunArcCache.CycleKey(date: context.date, lat: coord.latitude,
                                               lon: coord.longitude, calendar: calendar)
                let cycle = cache.cycle(for: key)
                // The times and the bedtime mark are worked out here, once per timeline
                // tick. The arc itself is evaluated on every colour-temp tick as well.
                SunArcView(cycle: cycle, marks: SunArcView.marks(
                    for: cycle, bedtime: hasBedtime ? manager.effectiveBedtime : nil,
                    calendar: calendar, locale: locale))
            }
        }
    }
}

/// The foot of the controls: "Deepest by" in Auto, then the row that opens Settings, with a
/// dot when an update or a login item is waiting.
private struct SettingsCard: View {
    let manager: DisplayManager
    let launchAtLogin: LaunchAtLogin?
    let dispatch: PopoverDispatch
    let bedtimeDraft: BedtimeDraft
    let updateAvailable: Bool?
    /// A render's stand-in for the login item's state; nil in the app.
    let loginRequiresApproval: Bool?
    let openSettings: () -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent

    var body: some View {
        let auto = manager.adaptiveEnabled
        let notice = SettingsNotice(
            hasUpdate: updateAvailable ?? Updater.shared.hasPendingUpdate,
            loginRequiresApproval: loginRequiresApproval ?? launchAtLogin?.requiresApproval ?? false)
        EmberCard {
            if auto {
                BedtimeRow(bedtime: manager.bedtime, draft: bedtimeDraft) { dispatch(.bedtime($0)) }
            }
            EmberRowButton(divider: auto, action: openSettings) {
                Text("Settings").foregroundStyle(palette.text)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if !notice.isEmpty {
                        Circle().fill(palette.arcDot(accent: accent)).frame(width: 7, height: 7)
                    }
                    EmberChevron(direction: .right)
                }
                .foregroundStyle(palette.secondary)
            }
            .help(notice.help)
            .accessibilityLabel("Settings")
            .accessibilityValue(notice.accessibilityValue)
        }
    }
}

/// Where Auto's location really comes from, on the Settings page. Its own view, because the
/// source is read with the status line and that changes as the sun moves.
struct LocationRow: View {
    let manager: DisplayManager
    @Environment(\.emberPalette) private var palette

    /// The value shown for a source, and what hovering the row explains.
    static func text(for source: DisplayManager.LocationSource) -> (title: String, help: String) {
        switch source {
        case .automatic:
            ("Automatic", "Auto is following your location from Location Services")
        case .timeZone:
            ("Time zone", "Auto is following your time zone's city, because it has no location")
        case .lastKnown:
            ("Last known", "Auto is following the last location it found, because Location Services is off")
        case .manual:
            ("Manual", "Auto is following the coordinates you entered")
        }
    }

    var body: some View {
        let source = Self.text(for: manager.locationSource)
        HStack(spacing: 8) {
            Text("Now using").foregroundStyle(palette.secondary)
            Spacer(minLength: 8)
            Text(source.title).foregroundStyle(palette.text)
        }
        .font(.ember(12))
        .help(source.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Location")
        .accessibilityValue(source.title)
    }
}

// MARK: - Sliders

/// A slider with its header row. The bindings are made here, so a drag re-evaluates this
/// row and nothing above it.
struct SliderRow: View {
    enum Channel { case color, whitepoint }

    @Bindable var manager: DisplayManager
    let channel: Channel
    let dispatch: PopoverDispatch

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SliderHeader(manager: manager, channel: channel, dispatch: dispatch)
            switch channel {
            case .color:
                BandSlider(
                    value: $manager.intensity,
                    lowerBound: $manager.adaptiveMin,
                    upperBound: $manager.adaptiveMax,
                    range: 0.0...1.0,
                    showBand: manager.adaptiveEnabled,
                    label: "Color Temp",
                    tone: .accent,
                    onPreview: { manager.previewIntensity($0) },
                    onPreviewEnd: { manager.endPreview() },
                    onInteractionBegin: { manager.beginSliderInteraction() },
                    isInteractionCurrent: { manager.isSliderInteractionCurrent($0) }
                )
            case .whitepoint:
                BandSlider(
                    value: $manager.whitepoint,
                    lowerBound: $manager.adaptiveWpMin,
                    upperBound: $manager.adaptiveWpMax,
                    range: 0.25...1.0,
                    showBand: manager.adaptiveEnabled,
                    label: "White Point",
                    tone: .soft,
                    onPreview: { manager.previewWhitepoint($0) },
                    onPreviewEnd: { manager.endPreview() },
                    onInteractionBegin: { manager.beginSliderInteraction() },
                    isInteractionCurrent: { manager.isSliderInteractionCurrent($0) }
                )
            }
        }
    }
}

/// Label on the left; on the right Reset, when there is something to reset, and the value.
struct SliderHeader: View {
    let manager: DisplayManager
    let channel: SliderRow.Channel
    let dispatch: PopoverDispatch
    @Environment(\.emberPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text(channel == .color ? "Color temp" : "White point")
                .font(.ember(12))
                .foregroundStyle(palette.secondary)
            Spacer(minLength: 0)
            if showsReset {
                let help = channel == .color ? "Reset color temp and its limits to default"
                    : "Reset white point and its limits to default"
                EmberChipButton(title: "Reset", height: 18, onCard: false) {
                    dispatch(.reset(channel == .color ? .color : .whitepoint))
                }
                .help(help)
                .accessibilityLabel(help)
            }
            Text("\(Int((value * 100).rounded()))%")
                .font(.ember(12, .semibold))
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        // Fixed, so the row does not move when Reset comes and goes.
        .frame(height: 16)
    }

    /// Reset restores the value, its Auto limits and any Auto adjustment. In Manual a chosen
    /// preset is already a deliberate value, so Reset would only be noise there, unless
    /// limits or an adjustment made in Auto are waiting behind it: Manual does not show
    /// those, and Reset is the only way to clear them from here.
    private var showsReset: Bool {
        Self.showsReset(
            isDefault: channel == .color ? manager.intensityIsDefault : manager.whitepointIsDefault,
            isAuto: manager.adaptiveEnabled, hasPreset: manager.activePresetIndex != nil,
            autoSettingsAreDefault: channel == .color
                ? manager.intensityAutoSettingsAreDefault : manager.whitepointAutoSettingsAreDefault)
    }

    static func showsReset(isDefault: Bool, isAuto: Bool, hasPreset: Bool, autoSettingsAreDefault: Bool) -> Bool {
        guard !isDefault else { return false }
        return isAuto || !hasPreset || !autoSettingsAreDefault
    }

    /// The value the slider shows: under Auto it is held inside the band.
    private var value: Double {
        let raw = channel == .color ? manager.intensity : manager.whitepoint
        guard manager.adaptiveEnabled else { return raw }
        return channel == .color
            ? BandSliderCore.clampToBand(raw, lower: manager.adaptiveMin, upper: manager.adaptiveMax)
            : BandSliderCore.clampToBand(raw, lower: manager.adaptiveWpMin, upper: manager.adaptiveWpMax)
    }
}

// MARK: - Manual

private struct PresetSwatches: View {
    let manager: DisplayManager
    let isSaveTarget: Bool
    let choose: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(Array(manager.presets.enumerated()), id: \.offset) { index, preset in
                PresetButton(
                    name: preset.name,
                    intensity: preset.intensity,
                    isSaveTarget: isSaveTarget,
                    isActive: !isSaveTarget && manager.activePresetIndex == index
                ) { choose(index) }
            }
        }
    }
}

/// A preset as a flat swatch of its colour temp, with its name beneath. The active one
/// carries a check and a bold name; in save mode every swatch is an overwrite target.
struct PresetButton: View {
    let name: String
    let intensity: Double
    var isSaveTarget = false
    let isActive: Bool
    let action: () -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        // The swatch is the preset's own colour, not the live accent.
        let swatch = EmberTint.rgb(intensity: intensity, scheme: scheme)
        EmberButton(action: action) { state in
            VStack(spacing: 5) {
                shape
                    .fill(swatch.color)
                    .frame(height: 38)
                    .overlay {
                        if isActive || isSaveTarget {
                            Image(systemName: isActive ? "checkmark" : "arrow.down.to.line")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(palette.check(on: swatch))
                        }
                    }
                    .emberFocusHalo(shape, isFocused: state.isFocused)
                Text(name)
                    .font(.ember(10.5, isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? palette.text : palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .help(isSaveTarget ? "Overwrite \(name) preset" : name)
        .accessibilityLabel(isSaveTarget ? "Overwrite \(name) preset" : name)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Opening the save-target picker and cancelling it only change presentation state; the
/// chosen swatch dispatches `savePreset`.
private struct SaveToPreset: View {
    @Binding var isChoosing: Bool
    @Environment(\.emberPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                EmberLinkButton(isChoosing ? "Cancel" : "Save to a preset…") { isChoosing.toggle() }
                    .accessibilityLabel(isChoosing ? "Cancel saving to a preset" : "Save to a preset")
                if isChoosing {
                    Text("Pick a preset to overwrite")
                        .font(.ember(12))
                        .foregroundStyle(palette.tertiary)
                        .lineLimit(1)
                }
            }
            Text("Presets are also the stops Auto moves through.")
                .font(.ember(11))
                .foregroundStyle(palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Error line

/// A failed action stays visible until the next one succeeds.
struct CommandErrorLine: View {
    let session: PopoverSession

    var body: some View {
        if let commandError = session.commandError {
            EmberErrorText(message: commandError, isBoxed: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Command failed: \(commandError)")
        }
    }
}

// MARK: - Settings notice

/// What the dot on the Settings button stands for.
struct SettingsNotice: Equatable {
    var hasUpdate: Bool
    var loginRequiresApproval: Bool

    var isEmpty: Bool { !hasUpdate && !loginRequiresApproval }

    private var reasons: [String] {
        [hasUpdate ? "update available" : nil,
         loginRequiresApproval ? "login item needs approval" : nil].compactMap { $0 }
    }

    /// The tooltip: "Settings, update available".
    var help: String { (["Settings"] + reasons).joined(separator: ", ") }

    /// What VoiceOver adds after "Settings": "Update available, login item needs approval".
    var accessibilityValue: String {
        let text = reasons.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Pause and Resume are one button whose glyph changes, so keyboard and VoiceOver focus stay
/// on it when a pause starts or ends. It is the leading part of a split pill whose chevron
/// unfolds the other lengths. The pill keeps its size and fill in both states, so nothing
/// beside it moves: paused, the pause glyph becomes a play glyph in the accent, and the
/// chevron dims because there are no other lengths to choose.
private struct PauseControl: View {
    let isPaused: Bool
    let isExpanded: Bool
    let focus: AccessibilityFocusState<Bool>.Binding
    /// False draws only the glyphs, for the header; the names stay for assistive apps.
    var showsTitle = true
    /// Pauses, or resumes when paused.
    let toggle: () -> Void
    let toggleLengths: () -> Void

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberAccent) private var accent

    var body: some View {
        // Only the play glyph is drawn in the accent, so only a paused control follows the
        // colour temp.
        let glyph = isPaused ? accent.rgb(for: palette).color : palette.text
        let height = EmberMetrics.controlHeight
        HStack(spacing: 0) {
            // Never inside an `if`: this button's identity is what keeps the focus.
            EmberButton(action: toggle) { state in
                HStack(spacing: 6) {
                    // Both glyphs in one fixed frame, so the pill's width never changes.
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: showsTitle ? 9 : 10.5, weight: .bold))
                        .foregroundStyle(glyph)
                        .frame(width: showsTitle ? 10 : 12)
                    if showsTitle {
                        Text(isPaused ? "Resume" : "Pause").lineLimit(1).fixedSize()
                            .foregroundStyle(palette.text)
                    }
                }
                .font(.ember(12.5, .medium))
                .padding(.leading, showsTitle ? 11 : 10)
                .padding(.trailing, showsTitle ? 5 : 2)
                .frame(height: height)
                .contentShape(Rectangle())
                .emberFocusHalo(PauseControlShape.leading, isFocused: state.isFocused, spread: 0)
            }
            .help(isPaused ? "Resume Redlight" : "Pause Redlight for 30 minutes")
            .accessibilityLabel(isPaused ? "Resume Redlight" : "Pause Redlight for 30 minutes")
            .accessibilityFocused(focus)
            EmberButton(action: toggleLengths) { state in
                EmberChevron(direction: isExpanded ? .up : .down)
                    .foregroundStyle(palette.tertiary)
                    .padding(.leading, showsTitle ? 6 : 3)
                    .padding(.trailing, showsTitle ? 11 : 9)
                    .frame(height: height)
                    .contentShape(Rectangle())
                    .emberFocusHalo(PauseControlShape.trailing, isFocused: state.isFocused, spread: 0)
            }
            // While paused there is no other length to choose; the chevron stays, dimmed,
            // so the pill does not change shape.
            .disabled(isPaused)
            .help(isPaused ? "Resume first to pause for another length" : "Pause for another length")
            .accessibilityLabel("Pause lengths")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
        .background { Capsule().fill(palette.fill) }
    }
}

/// The two halves of the split pause pill, as their focus bands follow them: the pill's
/// round end on the outside, a small corner where the halves meet.
enum PauseControlShape {
    private static let end = EmberMetrics.controlHeight / 2
    private static let joint: CGFloat = 4

    static let leading = UnevenRoundedRectangle(
        topLeadingRadius: end, bottomLeadingRadius: end,
        bottomTrailingRadius: joint, topTrailingRadius: joint, style: .circular)
    static let trailing = UnevenRoundedRectangle(
        topLeadingRadius: joint, bottomLeadingRadius: joint,
        bottomTrailingRadius: end, topTrailingRadius: end, style: .circular)
}

/// The other pause lengths. "Until sunrise" is disabled when there is no sunrise to find;
/// the command would only report an error.
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

    @Environment(\.emberPalette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            Text("Pause for")
                .font(.ember(11.5))
                .foregroundStyle(palette.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.trailing, 1)
            ForEach(Self.options, id: \.title) { option in
                let disabled = option.length == .untilSunrise && !sunriseAvailable
                EmberChipButton(title: option.title, height: 22, onCard: false) { choose(option.length) }
                    .disabled(disabled)
                    .help(disabled ? "Sunrise is unavailable for the current location" : option.accessibility)
                    .accessibilityLabel(option.accessibility)
            }
        }
    }
}

// MARK: - Bedtime Row

/// "Deepest by" for Auto: a time field that remembers its draft, and a switch.
struct BedtimeRow: View {
    static let suggested = Bedtime(hour: 22, minute: 30)!

    let bedtime: Bedtime?
    /// The time in the field, kept across menu openings so switching off does not lose it.
    let draft: BedtimeDraft
    let choose: (CommandBedtime) -> Void

    @Environment(\.emberPalette) private var palette

    static let title = "Deepest by"
    static let explanation = "Reach the deepest end of both bands by this time, even if the sun is still up. "
        + "Mornings still follow the sun."

    var body: some View {
        EmberRow {
            // The switch carries the name for VoiceOver, as the display rows do.
            Text(Self.title)
                .lineLimit(1)
                .fixedSize()
                .help(Self.explanation)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            // Editing only moves the draft: the field reports every digit and arrow key,
            // and each applied time restarts the fade and saves.
            EmberTimeField(date: Binding(
                get: { Self.date(for: draft.bedtime) },
                set: { draft.set(Self.bedtime(from: $0)) }
            ), label: "Bedtime")
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.fill))
            // After the field it applies, so Tab and VoiceOver reach it once the time is typed.
            if let bedtime, bedtime != draft.bedtime {
                EmberChipButton(title: "Set", isProminent: true) {
                    choose(.at(hour: draft.bedtime.hour, minute: draft.bedtime.minute))
                }
                .accessibilityLabel("Set bedtime to \(draft.bedtime.text)")
            }
            EmberSwitch(Self.title, isOn: Binding(
                get: { bedtime != nil },
                set: { on in
                    choose(on ? .at(hour: draft.bedtime.hour, minute: draft.bedtime.minute) : .off)
                }
            ))
            .help(Self.explanation)
        }
        .onAppear { if let bedtime { draft.set(bedtime) } }
        .onChange(of: bedtime) { _, new in if let new { draft.set(new) } }
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

    /// The bedtime as the user's clock writes it: "10:30 PM" or "22:30".
    static func clockText(_ bedtime: Bedtime) -> String {
        date(for: bedtime).formatted(date: .omitted, time: .shortened)
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
