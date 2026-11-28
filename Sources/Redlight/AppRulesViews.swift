import AppKit
import SwiftUI

// MARK: - Popover

/// The app the popover was opened over, and whether its sliders edit that app's rule.
///
/// Opening the popover activates Redlight; the rules keep judging the app that was in front
/// before (`AppRulesController.recentApp`), and this takes it once, at opening. While that
/// app has a Hold or Shift the sliders edit the rule, until "Edit Auto instead". If the app
/// quits, or another takes its place, the line goes and the sliders edit Auto or Manual.
@MainActor
@Observable
final class PopoverAppContext {
    struct Target: Equatable {
        var bundleID: String
        var name: String
        var rule: AppRule
    }

    @ObservationIgnored let apps: AppRulesController?
    @ObservationIgnored let app: RunningApp?
    /// "Edit Auto instead" was chosen.
    var editsGlobal = false

    init(apps: AppRulesController?) {
        self.apps = apps
        app = apps?.recentApp
    }

    /// The app opened over and its Hold or Shift, while it is still the app being judged.
    var target: Target? {
        guard let apps, let app, let bundleID = app.bundleID,
              apps.recentApp?.processID == app.processID,
              let rule = apps.rule(for: bundleID), rule.shapesOutput else { return nil }
        return Target(bundleID: bundleID, name: app.name, rule: rule)
    }

    /// The rule the sliders edit, or nil while they edit Auto or Manual.
    var editing: Target? { editsGlobal ? nil : target }

    /// A slider's drag while it edits the rule: the rule as it is now, so a drag that began
    /// before an edit from elsewhere does not put the other channel back.
    func set(_ manager: DisplayManager, showing value: Double, on channel: CommandChannel) {
        guard let apps, let target = editing else { return }
        try? apps.set(target.bundleID, manager.rule(target.rule, showing: value, on: channel))
    }

    /// Where a slider gesture's values go, taken once as it begins.
    private enum Route: Equatable {
        case global
        case rule(bundleID: String)
    }

    @ObservationIgnored private var route: Route?

    /// A slider's drag or step begins. One slot serves both sliders: a new gesture
    /// supersedes the one before.
    func beginInteraction() {
        route = editing.map { .rule(bundleID: $0.bundleID) } ?? .global
    }

    /// A value from the slider gesture under way: to the rule it began on, or through `global`
    /// to Auto or Manual. If that rule goes midway (the app quits, or the command line
    /// changes it to a Pause or removes it) the rest is dropped: it is not a global change.
    func write(_ manager: DisplayManager, showing value: Double, on channel: CommandChannel,
               global: () -> Void) {
        writeRule({ manager.rule($0, showing: value, on: channel) }, global: global)
    }

    func writeRule(_ transform: (AppRule) -> AppRule, global: () -> Void) {
        if route == nil { beginInteraction() }
        switch route {
        case .rule(let bundleID)?:
            guard let apps, let target = editing, AppBundleID.matches(target.bundleID, bundleID) else { return }
            try? apps.set(bundleID, transform(target.rule))
        case .global?, nil:
            global()
        }
    }
}

/// "Photoshop: Hold" above the sliders, with the way to edit Auto (or Manual) instead and
/// back again.
struct AppRuleLine: View {
    let context: PopoverAppContext
    let isAuto: Bool

    @Environment(\.emberPalette) private var palette

    static func title(_ target: PopoverAppContext.Target) -> String {
        "\(target.name): \(target.rule.kind.title)"
    }

    var body: some View {
        if let target = context.target {
            let editing = !context.editsGlobal
            let mode = isAuto ? "Auto" : "Manual"
            HStack(spacing: 8) {
                Text(Self.title(target))
                    .font(.ember(12, .semibold))
                    .foregroundStyle(editing ? palette.text : palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(editing ? "While \(target.name) is in front, the sliders set its \(target.rule.kind.title)"
                                  : "The sliders set \(mode); \(target.name) keeps its \(target.rule.kind.title)")
                    .accessibilityLabel(editing ? "The sliders set the \(target.rule.kind.title) for \(target.name)"
                                                : "\(target.name) has a \(target.rule.kind.title); the sliders set \(mode)")
                Spacer(minLength: 8)
                EmberLinkButton(editing ? "Edit \(mode) instead" : "Edit \(target.name)") {
                    context.editsGlobal.toggle()
                }
            }
            .frame(height: 18)
        }
    }
}

// MARK: - Settings

/// The dedicated per-app settings section in the main menu. It keeps the existing rule editor
/// and add/remove behavior, while giving each app enough room for its icon and controls.
struct AppsControl: View {
    static let title = "Per-App"

    let apps: AppRulesController
    let manager: DisplayManager
    let dispatch: PopoverDispatch
    let divider: Bool

    @State private var isExpanded: Bool
    @State private var runningApps: [RunningApp] = []
    @Environment(\.emberPalette) private var palette
    @Environment(\.emberDisclose) private var disclose

    init(apps: AppRulesController, manager: DisplayManager, dispatch: PopoverDispatch, divider: Bool,
         startExpanded: Bool) {
        self.apps = apps
        self.manager = manager
        self.dispatch = dispatch
        self.divider = divider
        _isExpanded = State(initialValue: startExpanded)
    }

    var body: some View {
        let chosen = apps.rules.map { (entry: $0, name: apps.name(for: $0.bundleID)) }
        // A card like Settings under it: a row of the same size and type, and the apps in
        // rows of their own below it when open.
        EmberCard {
            EmberRowButton(action: {
                // Captured once per unfolding rather than on every redraw.
                if !isExpanded { runningApps = apps.runningApps() }
                disclose { isExpanded.toggle() }
            }) {
                Text(Self.title).foregroundStyle(palette.text)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if !isExpanded {
                        Group {
                            if chosen.isEmpty {
                                Text("None")
                            } else {
                                AppIconStack(bundleIDs: chosen.map(\.entry.bundleID))
                            }
                        }
                        .transition(.opacity)
                    }
                    EmberChevron(direction: isExpanded ? .up : .down)
                }
                .foregroundStyle(palette.secondary)
            }
            .help("While one of these apps is in front: Pause hides the tint, Hold shows set values, Shift moves what Auto or Manual shows.")
            .accessibilityLabel(Self.title)
            .accessibilityValue(Self.accessibilityValue(
                chosen: chosen.map { (name: $0.name, rule: $0.entry.rule) }, isExpanded: isExpanded))

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(chosen, id: \.entry.bundleID) { app in
                        AppRuleEditor(entry: app.entry, name: app.name, manager: manager, dispatch: dispatch)
                    }
                    AppCandidates(chosen: apps.rules.map(\.bundleID), running: runningApps,
                                  recent: apps.recentBundleID, hasChosen: !chosen.isEmpty) { bundleID in
                        disclose { _ = dispatch(.apps(.set(bundleID, .pause))) }
                    }
                    .padding(.bottom, 4)
                }
                .emberRevealTransition()
            }
        }
        .accessibilityElement(children: .contain)
        .onPaneShown {
            if isExpanded, runningApps.isEmpty { runningApps = apps.runningApps() }
        }
    }

    /// What VoiceOver adds after "Apps": each app with its rule, then whether the list is
    /// open. "Safari: Pause, Preview: Hold, collapsed".
    static func accessibilityValue(chosen: [(name: String, rule: AppRule)], isExpanded: Bool) -> String {
        let apps = chosen.isEmpty ? "None" : chosen.map { "\($0.name): \($0.rule.kind.title)" }.joined(separator: ", ")
        return "\(apps), \(isExpanded ? "expanded" : "collapsed")"
    }
}

/// One app with a rule: its name, the rule, the button that removes it, and for a Hold or
/// Shift the slider amounts, each with a step down and up.
struct AppRuleEditor: View {
    /// One press of a step button, in slider percent.
    static let step = 5
    /// An app's icon in a row: about the height of the row's text with its line.
    static let iconSize: CGFloat = 18

    let entry: AppRuleEntry
    let name: String
    let manager: DisplayManager
    let dispatch: PopoverDispatch

    @Environment(\.emberPalette) private var palette
    @Environment(\.emberDisclose) private var disclose

    var body: some View {
        // One card row: the app, its rule and a way to remove it. The bundle ID is the name's
        // tooltip. Hold and Shift add a row per slider for their amounts.
        VStack(alignment: .leading, spacing: 0) {
            EmberRow(divider: true) {
                AppIcon(bundleID: entry.bundleID, size: Self.iconSize)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(entry.bundleID)
                    .accessibilityHidden(true)
                AppRuleMenu(name: name, selection: entry.rule.kind) { kind in
                    // Hold and Shift unfold their amounts; Pause folds them.
                    disclose { _ = dispatch(.apps(.set(entry.bundleID, manager.rule(kind, replacing: entry.rule)))) }
                }
                EmberIconButton(systemImage: "minus.circle.fill", size: 18, symbolSize: 12, isQuiet: true) {
                    disclose { _ = dispatch(.apps(.remove(entry.bundleID))) }
                }
                .help("Remove \(name)")
                .accessibilityLabel("Remove the rule for \(name)")
            }
            if entry.rule.shapesOutput {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([CommandChannel.color, .whitepoint], id: \.self) { channel in
                        amountRow(channel.displayName, amount: entry.rule.amount(channel) ?? 0, isShift: entry.rule.kind == .shift) {
                            entry.rule.with(channel, $0)
                        }
                    }
                    amountRow("Saturation", amount: manager.appSaturationPercent(entry.rule), isShift: false,
                              help: "Set below 100% to adjust saturation for this app. At 100%, use global saturation.") {
                        manager.rule(entry.rule, showingSaturation: SliderPercent.unit($0))
                    }
                }
                .emberRevealTransition()
            }
        }
    }

    private func amountRow(_ title: String, amount: Int, isShift: Bool, help: String? = nil,
                           update: @escaping (Int) -> AppRule) -> some View {
        let text = isShift ? AppRule.signed(amount) : AppRule.percent(amount)
        let range = isShift ? -100...100 : 0...100
        let label = "\(name) \(title.lowercased()) \(entry.rule.kind.title.lowercased())"
        func change(by delta: Int) {
            let next = min(range.upperBound, max(range.lowerBound, amount + delta))
            guard next != amount else { return }
            dispatch(.apps(.set(entry.bundleID, update(next))))
        }
        return HStack(spacing: 6) {
            Text(title)
                .font(.ember(12))
                .foregroundStyle(palette.secondary)
                // Under the app's name, past its icon.
                .padding(.leading, Self.iconSize + 8)
            Spacer(minLength: 4)
            EmberIconButton(systemImage: "minus", size: 18, symbolSize: 9, isQuiet: true) { change(by: -Self.step) }
                .disabled(amount <= range.lowerBound)
                .accessibilityHidden(true)
            Text(text)
                .font(.ember(12, .semibold))
                .monospacedDigit()
                .frame(minWidth: 38)
            EmberIconButton(systemImage: "plus", size: 18, symbolSize: 9, isQuiet: true) { change(by: Self.step) }
                .disabled(amount >= range.upperBound)
                .accessibilityHidden(true)
        }
        .frame(height: 24)
        .help(help ?? (isShift ? "Added to \(title.lowercased()) while \(name) is in front, in steps of 5%"
                      : "\(title) while \(name) is in front, in steps of 5%"))
        // One adjustable element: VoiceOver's swipe up and down steps it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(by: Self.step)
            case .decrement: change(by: -Self.step)
            @unknown default: break
            }
        }
    }
}

/// A compact rule picker that keeps the app row readable at the menu bar popover width.
private struct AppRuleMenu: View {
    let name: String
    let selection: AppRule.Kind
    let select: (AppRule.Kind) -> Void

    @Environment(\.emberPalette) private var palette

    var body: some View {
        let ink = selection == .pause ? palette.warning : palette.text
        // A plain button's menu draws its label as written; a picker's menu lays the title
        // out itself and ran it into the chevron.
        Menu {
            ForEach(AppRule.Kind.allCases, id: \.self) { kind in
                Button {
                    if kind != selection { select(kind) }
                } label: {
                    if kind == selection { Label(kind.title, systemImage: "checkmark") } else { Text(kind.title) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.title)
                    .font(.ember(12, .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(width: 72, height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.fillStrong))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pause hides the tint. Hold shows set values. Shift adds them to what Auto or Manual shows.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rule for \(name)")
        .accessibilityValue(selection.title)
    }

    private func icon(for kind: AppRule.Kind) -> String {
        switch kind {
        case .pause: "exclamationmark.triangle"
        case .hold: "lock"
        case .shift: "arrow.left.arrow.right"
        }
    }
}

/// Running apps without a rule, to add with a Pause. The list has a fixed height and
/// scrolls, so it cannot stretch the popover.
struct AppCandidates: View {
    static let rowHeight: CGFloat = 28
    static let visibleRows = 4
    /// How far a focused row's band reaches past the row on each side.
    static let focusReach: CGFloat = 6

    /// Bundle IDs with a rule.
    let chosen: [String]
    /// Running apps, captured when the list unfolds.
    let running: [RunningApp]
    let recent: String?
    let hasChosen: Bool
    let add: (String) -> Void

    @Environment(\.emberPalette) private var palette

    /// Running apps without a rule, once each, the app last in front first (most likely the
    /// one to add), then by name. An app without a bundle identifier can have no rule, so it
    /// is not offered.
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
        let candidates = Self.candidates(running: running, chosen: chosen, recent: recent)
        VStack(alignment: .leading, spacing: 0) {
            Text("Add an app")
                .font(.ember(11))
                .foregroundStyle(palette.tertiary)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(palette.fill).frame(height: 1) }
                .accessibilityAddTraits(.isHeader)
            Column(rows: max(1, candidates.count)) {
                ForEach(candidates, id: \.processID) { app in
                    if let id = app.bundleID {
                        EmberButton { add(id) } label: { state in
                            RowFace(name: app.name, symbol: "plus.circle", color: palette.secondary,
                                    bundleID: id,
                                    isFocused: state.isFocused)
                        }
                        .help(id)
                        .accessibilityLabel("Add \(app.name), paused")
                    }
                }
                if candidates.isEmpty {
                    Text("No other apps are running")
                        .font(.ember(12))
                        .foregroundStyle(palette.tertiary)
                        .frame(height: Self.rowHeight)
                }
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
                    .padding(.horizontal, AppCandidates.focusReach)
            }
            .padding(.horizontal, -AppCandidates.focusReach)
            .frame(height: CGFloat(min(rows, AppCandidates.visibleRows)) * AppCandidates.rowHeight)
        }
    }

    /// One app's line as drawn. The focus band runs `focusReach` into the card's inset on
    /// each side, clear of the name and the symbol.
    struct RowFace: View {
        let name: String
        let symbol: String
        let color: Color
        var bundleID: String? = nil
        let isFocused: Bool

        var body: some View {
            HStack(spacing: 8) {
                if let bundleID {
                    AppIcon(bundleID: bundleID, size: AppRuleEditor.iconSize)
                }
                Text(name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
            }
            .foregroundStyle(color)
            .frame(height: AppCandidates.rowHeight)
            .contentShape(Rectangle())
            .background {
                Color.clear
                    .emberFocusHalo(RoundedRectangle(cornerRadius: 6, style: .continuous),
                                    isFocused: isFocused, spread: 0)
                    .padding(.horizontal, -AppCandidates.focusReach)
            }
        }
    }
}

/// The installed app icon, with a neutral SF Symbol fallback for apps that are not installed.
struct AppIcon: View {
    let bundleID: String
    let size: CGFloat

    @State private var image: NSImage?
    @Environment(\.emberPalette) private var palette

    init(bundleID: String, size: CGFloat = 34) {
        self.bundleID = bundleID
        self.size = size
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.43, weight: .medium))
                    .foregroundStyle(palette.secondary)
                    .frame(width: size, height: size)
                    .background(palette.fillStrong)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        image = NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// The apps with a rule, as their icons in a row: what the folded Per-App row shows in place
/// of a count. Flat and apart while they fit beside "Per-App"; with more than fit, they slide
/// under each other, the first on top, and past `limit` the rest are a count. VoiceOver hears
/// the apps from the row's value instead.
struct AppIconStack: View {
    let bundleIDs: [String]

    /// The most icons shown overlapping: as many as fit beside "Per-App" with room for a count.
    static let limit = 12
    static let iconSize: CGFloat = 18
    /// The gap between icons while they lie apart.
    static let gap: CGFloat = 4
    /// How far each icon slides under the one before it, once they overlap.
    static let overlap: CGFloat = 7

    @Environment(\.emberPalette) private var palette

    var body: some View {
        // The first that fits: every icon apart, else overlapping.
        ViewThatFits(in: .horizontal) {
            apart
            overlapping
        }
        .accessibilityHidden(true)
    }

    private var apart: some View {
        HStack(spacing: Self.gap) {
            ForEach(bundleIDs, id: \.self) { AppIcon(bundleID: $0, size: Self.iconSize) }
        }
        .fixedSize()
    }

    private var overlapping: some View {
        // With more than `limit`, one icon makes way for the count.
        let shown = Array(bundleIDs.prefix(bundleIDs.count > Self.limit ? Self.limit - 1 : Self.limit))
        return HStack(spacing: 4) {
            HStack(spacing: -Self.overlap) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, bundleID in
                    AppIcon(bundleID: bundleID, size: Self.iconSize)
                        // A soft edge where it lies over the next, so each reads as its own.
                        .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.22), radius: 1.5, x: 1)
                        .zIndex(Double(shown.count - index))
                }
            }
            if shown.count < bundleIDs.count {
                Text("+\(bundleIDs.count - shown.count)")
                    .font(.ember(12))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .fixedSize()
    }
}
