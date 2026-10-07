import AppKit
import Observation
import SwiftUI

/// The menu bar item. Its menu holds the SwiftUI controls as a single custom-view item,
/// so the system draws the background, shape, shadow, and highlight exactly as it does
/// for every other menu bar menu. (SwiftUI's `MenuBarExtra(.window)` paints its own
/// opaque grey panel instead.)
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let contentItem = NSMenuItem()
    private let isActive: () -> Bool
    private let content: () -> AnyView

    init<Content: View>(isActive: @escaping () -> Bool,
                        @ViewBuilder content: @escaping () -> Content) {
        self.isActive = isActive
        self.content = { AnyView(content()) }
        super.init()
        menu.delegate = self
        menu.addItem(contentItem)
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("Redlight")
        trackIcon()
    }

    /// Filled sun = a filter is live, outline arc = idle. Re-armed on every change, since
    /// `withObservationTracking` only reports the first one.
    private func trackIcon() {
        let active = withObservationTracking { isActive() } onChange: { [weak self] in
            Task { @MainActor in self?.trackIcon() }
        }
        statusItem.button?.image = active ? MenuBarIcon.activeImage() : MenuBarIcon.inactiveImage()
    }

    // MARK: - NSMenuDelegate

    /// A fresh view per opening, so it starts on the controls with current state.
    func menuWillOpen(_ menu: NSMenu) {
        let view = NSHostingView(rootView: content()
            .environment(\.closeMenu, CloseMenuAction { [weak menu] in menu?.cancelTracking() }))
        view.frame.size = view.fittingSize
        contentItem.view = view
    }

    /// Removing the view fires SwiftUI's onDisappear (ends any slider preview). Deferred:
    /// the close may come from a button inside it, still mid-action.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in self?.contentItem.view = nil }
    }
}

/// Closes the menu bar menu hosting the view.
struct CloseMenuAction {
    var action: @MainActor () -> Void = {}
    @MainActor func callAsFunction() { action() }
}

private struct CloseMenuKey: EnvironmentKey {
    static let defaultValue = CloseMenuAction()
}

extension EnvironmentValues {
    var closeMenu: CloseMenuAction {
        get { self[CloseMenuKey.self] }
        set { self[CloseMenuKey.self] = newValue }
    }
}
