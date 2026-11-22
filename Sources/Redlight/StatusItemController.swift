import AppKit
import Observation
import SwiftUI

/// A native popover anchored to the menu bar. Hosting the controls in a window lets the
/// location fields receive keyboard input and the contents resize as sections unfold.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let isActive: () -> Bool
    private let content: () -> AnyView
    private var popover: NSPopover?
    private var displayedActivity: Bool?

    init<Content: View>(isActive: @escaping () -> Bool,
                        @ViewBuilder content: @escaping () -> Content) {
        self.isActive = isActive
        self.content = { AnyView(content()) }
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel("Redlight")
            button.setAccessibilityHelp("Open Redlight controls")
        }
        trackIcon()
    }

    /// Re-arm the observation on each change, but update the button only if the status changed.
    private func trackIcon() {
        let active = withObservationTracking { isActive() } onChange: { [weak self] in
            Task { @MainActor in self?.trackIcon() }
        }
        guard active != displayedActivity else { return }
        displayedActivity = active
        statusItem.button?.image = active ? MenuBarIcon.activeImage() : MenuBarIcon.inactiveImage()
        statusItem.button?.setAccessibilityValue(active ? "Active" : "Inactive")
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        // Leave room for the popover's arrow and shadow above the content.
        let maximumHeight = sender.window?.screen.map { $0.visibleFrame.height - 30 } ?? .greatestFiniteMagnitude
        let popover = Self.makePopover(maximumHeight: maximumHeight, content: content())
        self.popover = popover
        popover.delegate = self
        NSApplication.shared.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    static func makePopover<Content: View>(maximumHeight: CGFloat = .greatestFiniteMagnitude,
                                           content: Content) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        let close = CloseRedlightPopoverAction { [weak popover] in popover?.performClose(nil) }
        let host = NSHostingController(rootView: content
            .environment(\.closeRedlightPopover, close)
            .onExitCommand { close() }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak popover, weak scroll] size in
                DispatchQueue.main.async { [weak popover, weak scroll] in
                    guard let popover, let scroll else { return }
                    resize(popover, scroll: scroll, contentSize: size, maximumHeight: maximumHeight)
                }
            })
        let size = host.view.fittingSize
        let container = NSViewController()
        container.view = scroll
        container.addChild(host)
        scroll.documentView = host.view
        popover.contentViewController = container
        resize(popover, scroll: scroll, contentSize: size, maximumHeight: maximumHeight)
        return popover
    }

    private static func resize(_ popover: NSPopover, scroll: NSScrollView,
                               contentSize: CGSize, maximumHeight: CGFloat) {
        guard contentSize.width > 0, contentSize.height > 0, let document = scroll.documentView else { return }
        let viewport = CGSize(width: contentSize.width, height: min(contentSize.height, max(1, maximumHeight)))
        let clip = scroll.contentView
        let oldTop = document.isFlipped ? 0 : max(0, document.frame.height - clip.bounds.height)
        let wasAtTop = clip.bounds.height == 0 || abs(clip.bounds.minY - oldTop) < 1
        if document.frame.size != contentSize { document.setFrameSize(contentSize) }
        let needsScroller = contentSize.height > viewport.height
        if scroll.hasVerticalScroller != needsScroller { scroll.hasVerticalScroller = needsScroller }
        if popover.contentSize != viewport { popover.contentSize = viewport }
        if wasAtTop, needsScroller, !document.isFlipped {
            clip.scroll(to: CGPoint(x: 0, y: contentSize.height - viewport.height))
            scroll.reflectScrolledClipView(clip)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        guard let popover, notification.object as? NSPopover === popover else { return }
        statusItem.button?.highlight(true)
        statusItem.button?.setAccessibilityExpanded(true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover, notification.object as? NSPopover === popover else { return }
        statusItem.button?.highlight(false)
        statusItem.button?.setAccessibilityExpanded(false)
        // The next presentation owns a fresh controller and SwiftUI state.
        self.popover = nil
    }
}

struct CloseRedlightPopoverAction {
    var action: @MainActor () -> Void = {}
    @MainActor func callAsFunction() { action() }
}

private struct CloseRedlightPopoverKey: EnvironmentKey {
    static let defaultValue = CloseRedlightPopoverAction()
}

extension EnvironmentValues {
    var closeRedlightPopover: CloseRedlightPopoverAction {
        get { self[CloseRedlightPopoverKey.self] }
        set { self[CloseRedlightPopoverKey.self] = newValue }
    }
}
