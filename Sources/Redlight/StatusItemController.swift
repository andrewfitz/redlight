import AppKit
import Observation
import SwiftUI

/// A native popover anchored to the menu bar. Hosting the controls in a window lets the
/// location fields receive keyboard input and the contents resize as sections unfold.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let iconLevel: () -> MenuBarIcon.Level
    private let content: () -> AnyView
    private var popover: NSPopover?
    private var displayedLevel: MenuBarIcon.Level?

    init<Content: View>(iconLevel: @escaping () -> MenuBarIcon.Level,
                        @ViewBuilder content: @escaping () -> Content) {
        self.iconLevel = iconLevel
        self.content = { AnyView(content()) }
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel("Redlight")
            button.setAccessibilityExpanded(false)
            button.setAccessibilityHelp("Open Redlight controls")
        }
        trackIcon()
    }

    /// Re-arm the observation on each change, but update the button only if the level changed.
    /// The level reads the live color temp, so this runs on every slider step; the guard keeps
    /// the button untouched until a step crosses into another level.
    private func trackIcon() {
        let level = withObservationTracking { iconLevel() } onChange: { [weak self] in
            Task { @MainActor in self?.trackIcon() }
        }
        guard level != displayedLevel else { return }
        displayedLevel = level
        statusItem.button?.image = MenuBarIcon.image(for: level)
        statusItem.button?.setAccessibilityValue(level.accessibilityValue)
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
        Self.prepareShown(popover)
    }

    /// What a popover needs as soon as `show` returns and its window exists: the surface, so
    /// the arrow is painted before the first frame, and the keyboard on the root view.
    static func prepareShown(_ popover: NSPopover) {
        installSurface(in: popover)
        restFocus(in: popover)
    }

    /// Takes the keyboard off whichever control the window chose for itself and gives it to
    /// the popover's root view. See `PopoverScrollView`.
    @discardableResult
    static func restFocus(in popover: NSPopover) -> Bool {
        guard let root = popover.contentViewController?.view as? PopoverScrollView,
              let window = root.window else { return false }
        return window.makeFirstResponder(root)
    }

    /// Gives the popover's frame, arrow included, the Ember background.
    ///
    /// `NSPopover` draws its own material behind the content and in the arrow, so painting
    /// only the SwiftUI content would leave the arrow another colour. The frame view (the
    /// superview of the popover window's content view) clips its subviews to the popover's
    /// outline, so a plain view placed directly beneath the content fills that outline. Its
    /// colour is dynamic and follows light and dark live. If the hierarchy is not what is
    /// expected, nothing is installed and the popover keeps the system material.
    @discardableResult
    static func installSurface(in popover: NSPopover) -> Bool {
        guard let contentView = popover.contentViewController?.view.window?.contentView,
              let frameView = contentView.superview else { return false }
        if frameView.subviews.contains(where: { $0 is PopoverSurfaceView }) { return true }
        let surface = PopoverSurfaceView(frame: frameView.bounds)
        surface.autoresizingMask = [.width, .height]
        frameView.addSubview(surface, positioned: .below, relativeTo: contentView)
        return true
    }

    static func makePopover<Content: View>(maximumHeight: CGFloat = .greatestFiniteMagnitude,
                                           content: Content) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        let scroll = PopoverScrollView()
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        let close = CloseRedlightPopoverAction { [weak popover] in popover?.performClose(nil) }
        scroll.onCancel = { close() }
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
        statusItem.button?.setAccessibilityHelp("Close Redlight controls")
        Self.installSurface(in: popover)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover, notification.object as? NSPopover === popover else { return }
        statusItem.button?.highlight(false)
        statusItem.button?.setAccessibilityExpanded(false)
        statusItem.button?.setAccessibilityHelp("Open Redlight controls")
        // The next presentation owns a fresh controller and SwiftUI state.
        self.popover = nil
    }
}

/// The popover's root view, and what has the keyboard when the popover opens.
///
/// The popover's window starts with its content view as first responder, or, when that
/// declines, with the first view Tab would stop at. In Auto that was the colour temp's
/// lower limit, so an arrow key pressed on a popover that had just opened moved a limit.
/// On a page with no Tab stop it was the window itself, and Escape, which SwiftUI only
/// hears from inside its own views, did not close the popover.
///
/// So this view accepts the keyboard and does nothing with it but close on Escape and
/// pass Tab on. It is no Tab stop: the first Tab goes to the first control, and none comes
/// back here. Any other key ends here, quietly: there is nothing to type into, and the
/// window would only answer with the alert sound.
final class PopoverScrollView: NSScrollView {
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    /// A scroll view offers the keyboard to its document view and declines it when that
    /// does. This one keeps it.
    override func becomeFirstResponder() -> Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Self.escapeKeyCode: onCancel?()
        case Self.tabKeyCode: super.keyDown(with: event)
        default: break
        }
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let tabKeyCode: UInt16 = 48
}

/// The Ember panel colour behind the popover's content and in its arrow.
///
/// One flat colour, so it is the layer's background colour and the view has no backing
/// store to draw into and keep.
final class PopoverSurfaceView: NSView {
    static let color = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rgb = (isDark ? EmberPalette.dark : EmberPalette.light).background
        return NSColor(srgbRed: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255, alpha: 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// Never unarchived.
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    /// A `CGColor` is one fixed colour, so the dynamic one is resolved again here: AppKit
    /// calls this for the first display and after every change of appearance.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Never takes a click meant for the content or the frame.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
