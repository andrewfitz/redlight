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
        standAboveOtherWindows(popover)
        installSurface(in: popover)
        restFocus(in: popover)
    }

    /// The popover is a menu bar item's menu, so it stands where menus do: above every app's
    /// windows, floating panels and always-on-top windows included, and over a full-screen
    /// app. Left to itself it takes the level of the window it hangs from.
    static func standAboveOtherWindows(_ popover: NSPopover) {
        guard let window = popover.contentViewController?.view.window else { return }
        window.level = .popUpMenu
        window.collectionBehavior.insert(.fullScreenAuxiliary)
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
        let sizer = PopoverSizer(popover: popover, scroll: scroll, maximumHeight: maximumHeight)
        scroll.sizer = sizer
        let slides = PopoverSlideHost(popover: popover, scroll: scroll, sizer: sizer)
        scroll.slideHost = slides
        let host = NSHostingController(rootView: content
            .environment(\.closeRedlightPopover, close)
            .environment(\.popoverSlideHost, slides)
            .onExitCommand { close() }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak sizer] size in
                sizer?.request(size)
            }
            // Until the popover has followed a new height the content keeps its top edge:
            // centred, as a hosting view places it, everything would jump by half the
            // difference and back. The minimum makes the frame take the height it is given
            // when the content has outgrown it, so that is top-aligned too.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            // Where the pagers measure themselves from: the content's top left, as its
            // pictures are. The global space is the window's, which has a margin.
            .coordinateSpace(.named(PopoverSlideHost.space)))
        let size = host.view.fittingSize
        let container = NSViewController()
        container.view = scroll
        container.addChild(host)
        scroll.documentView = host.view
        popover.contentViewController = container
        resize(popover, scroll: scroll, contentSize: size, maximumHeight: maximumHeight)
        return popover
    }

    /// `viewportHeight`, during a slide, is the height the popover is at on its way to the
    /// content's: the content is laid out at its own height and shows from its top.
    fileprivate static func resize(_ popover: NSPopover, scroll: NSScrollView,
                                   contentSize measured: CGSize, maximumHeight: CGFloat,
                                   viewportHeight: CGFloat? = nil, fillsViewport: Bool = false) {
        guard measured.width > 0, measured.height > 0, let document = scroll.documentView else { return }
        // In whole points. The popover places its window in whole points, and a height with
        // a fraction rounds its origin and its size apart: the top edge, which is meant to
        // stay put under the menu bar, would step a point up and back as the height went by.
        // The content is top-aligned in its document, so the fraction is a sliver of the
        // panel's colour at the bottom.
        let contentSize = CGSize(width: measured.width, height: measured.height.rounded(.up))
        let fitting = min(contentSize.height, max(1, maximumHeight.rounded(.down)))
        let viewport = CGSize(width: contentSize.width,
                              height: viewportHeight.map { min(max(1, $0.rounded()), maximumHeight.rounded(.down)) } ?? fitting)
        let clip = scroll.contentView
        let oldTop = document.isFlipped ? 0 : max(0, document.frame.height - clip.bounds.height)
        let wasAtTop = clip.bounds.height == 0 || abs(clip.bounds.minY - oldTop) < 1
        // While something folds, the popover is taller than the content for a moment: the
        // document then fills it, and the content stays at its top instead of falling to the
        // bottom of the clip view. A slide covers that gap with its pictures, and measures the
        // document, so it keeps the content's own height.
        let documentSize = fillsViewport
            ? CGSize(width: contentSize.width, height: max(contentSize.height, viewport.height)) : contentSize
        if document.frame.size != documentSize { document.setFrameSize(documentSize) }
        let needsScroller = contentSize.height > fitting
        if scroll.hasVerticalScroller != needsScroller { scroll.hasVerticalScroller = needsScroller }
        if popover.contentSize != viewport {
            // At once: during a slide the popover's height is moved here frame by frame, and
            // the popover's own animation would trail behind. Anything else that unfolds is
            // simply there.
            let animates = popover.animates
            popover.animates = false
            popover.contentSize = viewport
            popover.animates = animates
        }
        if wasAtTop, documentSize.height > viewport.height, !document.isFlipped {
            clip.scroll(to: CGPoint(x: 0, y: documentSize.height - viewport.height))
            scroll.reflectScrolledClipView(clip)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        guard let popover, notification.object as? NSPopover === popover else { return }
        statusItem.button?.highlight(true)
        statusItem.button?.setAccessibilityExpanded(true)
        statusItem.button?.setAccessibilityHelp("Close Redlight controls")
        Self.standAboveOtherWindows(popover)
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

/// Work for a later pass of the main run loop. Unlike a block on the main queue or a task
/// on the main actor, it also runs while an event loop is nested inside one of those, as
/// the live tests' is.
@MainActor
enum MainRunLoop {
    static func perform(after delay: TimeInterval = 0, _ work: @escaping @MainActor () -> Void) {
        guard delay > 0 else {
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(work) }
            // A block does not wake a run loop that is about to sleep.
            CFRunLoopWakeUp(CFRunLoopGetMain())
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated(work) }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// The popover's root view, and what has the keyboard when the popover opens.
///
/// The popover's window starts with its content view as first responder, or, when that
/// declines, with the first view Tab would stop at. That is the colour temp slider, so an
/// arrow key pressed on a popover that had just opened would move the colour temp.
/// On a page with no Tab stop it was the window itself, and Escape, which SwiftUI only
/// hears from inside its own views, did not close the popover.
///
/// So this view accepts the keyboard and does nothing with it but close on Escape and
/// pass Tab on. It is no Tab stop: the first Tab goes to the first control, and none comes
/// back here. Any other key ends here, quietly: there is nothing to type into, and the
/// window would only answer with the alert sound.
final class PopoverScrollView: NSScrollView {
    var onCancel: (() -> Void)?
    /// Follows the content's height with the popover's.
    var sizer: PopoverSizer?
    /// Slides the pager panes in this popover.
    var slideHost: PopoverSlideHost?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }

    /// A scroll view offers the keyboard to its document view and declines it when that
    /// does. This one keeps it.
    override func becomeFirstResponder() -> Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// A scroll view lays out its own parts and leaves any other subview at the size it had:
    /// a slide's pictures cover the whole of it as it grows and shrinks.
    override func tile() {
        super.tile()
        for case let overlay as PopoverSlideOverlay in subviews where overlay.frame != bounds {
            overlay.frame = bounds
        }
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

/// Gives the popover the content's size, once for each frame the display shows.
///
/// While a height animates (a slide between panes) the content reports a new size on every
/// layout, and a resize lays the window out again, which samples the animation anew and
/// reports another: followed as they came, the popover was resized several times between
/// two frames on screen, each with a full layout of the content. Here the latest size is
/// kept and applied on the display's next refresh, so the window and the content it holds
/// change together, once a frame (at most 60 a second).
@MainActor final class PopoverSizer: NSObject {
    private weak var popover: NSPopover?
    private weak var scroll: NSScrollView?
    private let maximumHeight: CGFloat
    private var pending: CGSize?
    /// The content's size as last reported.
    private var latest: CGSize?
    /// While set, the popover stays at this height whatever the content's.
    private var held: CGFloat?
    /// The popover's height on its way from one height to the content's, during a slide.
    private var glide: Glide?
    /// Set for a disclosure's hold and glide: see `StatusItemController.resize`.
    private var fillsViewport = false
    private struct Glide {
        let from: CGFloat
        let start: CFTimeInterval
        let duration: TimeInterval
        let completion: () -> Void
    }
    /// Unsafe only to let `deinit` reach it, which runs on the main thread like the rest.
    nonisolated(unsafe) private var link: CADisplayLink?

    init(popover: NSPopover, scroll: NSScrollView, maximumHeight: CGFloat) {
        self.popover = popover
        self.scroll = scroll
        self.maximumHeight = maximumHeight
        super.init()
        // A closed popover's window is off the screen, and its display stops calling: told
        // here, whoever closes it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(popoverDidClose(_:)), name: NSPopover.didCloseNotification, object: popover)
    }

    @objc private func popoverDidClose(_ notification: Notification) {
        stop()
    }

    /// Gone with the popover's views: a link that a closed popover's display stopped calling
    /// would otherwise stay with the run loop.
    deinit { link?.invalidate() }

    func request(_ size: CGSize) {
        pending = size
        latest = size
        startFollowing()
    }

    /// Keeps the popover at the height it has, while the content takes another under a
    /// picture of what was there.
    func hold(fillingViewport: Bool = false) {
        glide = nil
        fillsViewport = fillingViewport
        held = popover?.contentSize.height
    }

    /// Takes the popover from where it is held to the content's height, on the slide's curve,
    /// once a frame.
    func glide(duration: TimeInterval, completion: @escaping () -> Void) {
        guard let from = held ?? popover?.contentSize.height else {
            completion()
            return
        }
        held = nil
        glide = Glide(from: from, start: CACurrentMediaTime(), duration: duration, completion: completion)
        pending = pending ?? latest
        startFollowing()
    }

    /// Lays the content out at its latest size now, instead of on the next refresh: for a
    /// picture of it.
    func settleContent() {
        guard pending != nil else { return }
        apply()
    }

    /// Ends a hold or a glide: the popover takes the content's height at once.
    func release() {
        guard held != nil || glide != nil else { return }
        held = nil
        glide = nil
        fillsViewport = false
        pending = pending ?? latest
        apply()
    }

    private func startFollowing() {
        guard link == nil else { return }
        guard popover?.isShown == true, let window = scroll?.window, window.isVisible, window.screen != nil,
              let scroll else {
            // Not shown on a screen, or closing, so there is no display to wait for.
            MainRunLoop.perform { [weak self] in self?.apply() }
            return
        }
        // Made for a burst of changes and let go after it, so nothing outlives the popover.
        // The link keeps its target: a weak one, so the popover's views can go.
        let link = scroll.displayLink(target: SizerLinkTarget(self), selector: #selector(SizerLinkTarget.refresh(_:)))
        // At most 60 a second: each resize lays the window out again, and on a fast display
        // twice that is work for a height change too small to see between two frames.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func refresh(_ link: CADisplayLink) {
        // Let go once nothing is waiting, or once the popover is gone or closed.
        guard pending != nil || glide != nil, popover?.isShown == true, scroll != nil else {
            stop()
            return
        }
        apply()
    }

    /// Whether it is waiting on the display: while a height changes, and not after.
    var isWaitingForDisplay: Bool { link != nil }

    /// Drops whatever is waiting and lets the display go. A glide ends where it was going.
    private func stop() {
        pending = nil
        held = nil
        fillsViewport = false
        let finished = glide
        glide = nil
        link?.invalidate()
        link = nil
        finished?.completion()
    }

    private func apply() {
        let size = pending ?? latest
        pending = nil
        guard let size, let popover, let scroll else { return }
        var height = held
        var arrived: Glide?
        if let glide {
            let progress = min(1, max(0, (CACurrentMediaTime() - glide.start) / glide.duration))
            if progress >= 1 {
                arrived = glide
                self.glide = nil
                fillsViewport = false
            } else {
                let target = min(size.height.rounded(.up), maximumHeight.rounded(.down))
                height = glide.from + (target - glide.from) * EmberMotion.modeSwitchProgress(progress)
            }
        }
        StatusItemController.resize(popover, scroll: scroll, contentSize: size, maximumHeight: maximumHeight,
                                    viewportHeight: height, fillsViewport: fillsViewport)
        arrived?.completion()
    }
}

/// What a display link calls for a `PopoverSizer`, without keeping it.
@MainActor private final class SizerLinkTarget: NSObject {
    private weak var sizer: PopoverSizer?

    init(_ sizer: PopoverSizer) { self.sizer = sizer }

    /// On the main run loop, where the link is added.
    @objc func refresh(_ link: CADisplayLink) {
        if let sizer { sizer.refresh(link) } else { link.invalidate() }
    }
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

/// Slides an `EmberPager`'s panes past each other as pictures, with Core Animation.
///
/// A slide in SwiftUI laid out and drew the popover again on every frame. Here, a pass after
/// the change, when the screen still shows the old pane, a picture is taken of the popover's
/// content and laid over it from the pager down. The pager then shows the new pane at once,
/// under the picture, and the popover is held at its height. A pass later a second picture is
/// taken, and the old pane's part of the first slides out on one side while the new pane's
/// part of the second slides in from the other; what follows the pager moves to its new place,
/// and the popover's height follows on the display's clock. Then the pictures go, leaving the
/// content, which has been the new one all along: VoiceOver and the keyboard meet it at once.
///
/// A change during a slide ends the slide where it was going, and the next starts from what is
/// then on screen. Content taller than the screen, which scrolls, is swapped without a slide.
@MainActor final class PopoverSlideHost {
    /// The coordinate space of the popover's content, from its top left.
    nonisolated static let space = "redlight.popover.content"

    private weak var popover: NSPopover?
    private weak var scroll: NSScrollView?
    private let sizer: PopoverSizer
    private var request: Request?
    private var overlay: PopoverSlideOverlay?
    /// Counts slides, so the end of one that was cut short does nothing.
    private var generation = 0

    private struct Request {
        let forward: Bool
        let region: () -> CGRect
        let swap: () -> Void
    }

    init(popover: NSPopover, scroll: NSScrollView, sizer: PopoverSizer) {
        self.popover = popover
        self.scroll = scroll
        self.sizer = sizer
    }

    /// Whether a slide is on screen.
    var isSliding: Bool { overlay != nil }

    /// `forward` slides the new pane in from the right. `region` is where the pager is, in the
    /// content's coordinates from its top left; `swap` shows the new pane, at once.
    func slide(forward: Bool, region: @escaping () -> CGRect, swap: @escaping () -> Void) {
        let isFirst = request == nil
        request = Request(forward: forward, region: region, swap: swap)
        // A pass later, once what is on screen is what was there before the change.
        if isFirst { MainRunLoop.perform { [weak self] in self?.begin() } }
    }

    private func begin() {
        guard let request else { return }
        self.request = nil
        finish()
        guard let popover, popover.isShown, let scroll, let document = scroll.documentView,
              let window = scroll.window, window.isVisible, !scroll.hasVerticalScroller,
              let before = Self.picture(of: document) else {
            request.swap()
            return
        }
        let from = request.region()
        let contentBefore = document.frame.height
        let overlay = PopoverSlideOverlay(frame: scroll.bounds, top: from.minY,
                                          background: Self.panel(in: window))
        overlay.autoresizingMask = [.width, .height]
        overlay.cover(with: before, scale: Self.scale(of: before, in: document))
        scroll.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
        generation += 1
        let slide = generation
        sizer.hold()
        request.swap()
        MainRunLoop.perform { [weak self] in
            guard let self, self.generation == slide, let overlay = self.overlay else { return }
            // The new pane's size reaches the content view on the next refresh; the picture is
            // taken of the whole of it, so it goes there now.
            document.layoutSubtreeIfNeeded()
            self.sizer.settleContent()
            document.layoutSubtreeIfNeeded()
            guard let after = Self.picture(of: document) else {
                self.finish()
                return
            }
            // Only the pager's height changes with its pane, so its new height is the old one
            // and the content's change: SwiftUI's own report of it may not have come yet.
            var to = from
            to.size.height = max(0, from.height + document.frame.height - contentBefore)
            let duration = EmberMotion.modeSwitchDuration
            overlay.slide(from: before, regionBefore: from, to: after, regionAfter: to,
                          scale: Self.scale(of: after, in: document), forward: request.forward,
                          duration: duration)
            self.sizer.glide(duration: duration) { [weak self] in
                guard let self, self.generation == slide else { return }
                self.finish()
            }
        }
    }

    /// Unfolds or folds something in place: `change` animates on `EmberMotion.disclosure`
    /// while the popover's height goes from where it is to the content's on the same curve,
    /// the content held to its top. Use it through `EmberDisclose`. With a slide on its way or
    /// on screen, or the popover not up, the change is simply made.
    func disclose(_ change: () -> Void) {
        guard request == nil, overlay == nil, let popover, popover.isShown,
              scroll?.window?.isVisible == true else {
            change()
            return
        }
        sizer.hold(fillingViewport: true)
        withAnimation(EmberMotion.disclosure) { change() }
        sizer.glide(duration: EmberMotion.disclosureDuration) {}
    }

    /// Takes the pictures away and lets the popover have the content's height.
    func finish() {
        generation += 1
        overlay?.removeFromSuperview()
        overlay = nil
        sizer.release()
    }

    /// The content as it is drawn now.
    private static func picture(of view: NSView) -> CGImage? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private static func scale(of image: CGImage, in view: NSView) -> CGFloat {
        CGFloat(image.width) / max(1, view.bounds.width)
    }

    private static func panel(in window: NSWindow) -> CGColor {
        var color = PopoverSurfaceView.color.cgColor
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = PopoverSurfaceView.color.cgColor
        }
        return color
    }
}

/// The pictures of a slide, over the popover's content from the pager down. It takes the
/// clicks there while it is up; the controls above it stay live.
final class PopoverSlideOverlay: NSView {
    private let top: CGFloat
    /// The part from the pager down, which the pictures are clipped to. Measured from its top,
    /// as the pictures are.
    private let stage = FlippedView()
    private var pictures: [NSView] = []

    init(frame: NSRect, top: CGFloat, background: CGColor) {
        self.top = top
        super.init(frame: frame)
        wantsLayer = true
        stage.wantsLayer = true
        stage.layer?.backgroundColor = background
        stage.layer?.masksToBounds = true
        stage.frame = CGRect(x: 0, y: top, width: frame.width, height: max(0, frame.height - top))
        stage.autoresizingMask = [.width, .height]
        addSubview(stage)
    }

    /// Never unarchived.
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return local.y >= top ? self : nil
    }

    /// What the popover shows now, from the pager down, so the content can change under it.
    func cover(with image: CGImage, scale: CGFloat) {
        let height = CGFloat(image.height) / scale - top
        place(image, crop: CGRect(x: 0, y: top, width: bounds.width, height: height), at: 0, scale: scale)
    }

    func slide(from before: CGImage, regionBefore: CGRect, to after: CGImage, regionAfter: CGRect,
               scale: CGFloat, forward: Bool, duration: TimeInterval) {
        pictures.forEach { $0.removeFromSuperview() }
        pictures = []
        let width = bounds.width
        let afterHeight = CGFloat(after.height) / scale
        // The two panes slide inside a window as tall as the pager, which goes from the old
        // pane's height to the new one's: a taller pane is uncovered as it grows, and a shorter
        // one's foot is where the window's is. What follows the pager stays under that foot.
        let window = FlippedView(frame: CGRect(x: 0, y: regionBefore.minY - top, width: width,
                                               height: regionBefore.height))
        window.wantsLayer = true
        window.layer?.masksToBounds = true
        stage.addSubview(window)
        pictures.append(window)
        let leaving = place(before, crop: CGRect(x: 0, y: regionBefore.minY, width: width, height: regionBefore.height),
                            at: 0, scale: scale, in: window)
        let arriving = place(after, crop: CGRect(x: 0, y: regionAfter.minY, width: width, height: regionAfter.height),
                             at: 0, scale: scale, in: window)
        arriving.frame.origin.x = forward ? width : -width
        let rest = place(after, crop: CGRect(x: 0, y: regionAfter.maxY, width: width,
                                             height: max(0, afterHeight - regionAfter.maxY)),
                         at: regionBefore.maxY - top, scale: scale)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = EmberMotion.modeSwitchTiming
            context.allowsImplicitAnimation = true
            leaving.animator().setFrameOrigin(CGPoint(x: forward ? -width : width, y: 0))
            arriving.animator().setFrameOrigin(CGPoint(x: 0, y: 0))
            window.animator().setFrameSize(CGSize(width: width, height: regionAfter.height))
            rest.animator().setFrameOrigin(CGPoint(x: 0, y: regionAfter.maxY - top))
        }
    }

    /// A part of a picture, at `y` in the stage, in front of what is there.
    @discardableResult
    private func place(_ image: CGImage, crop: CGRect, at y: CGFloat, scale: CGFloat, in parent: NSView? = nil) -> NSView {
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale,
                            width: crop.width * scale, height: crop.height * scale).integral
        let view = PictureView(frame: CGRect(x: 0, y: y, width: crop.width, height: crop.height))
        view.layer?.contents = image.cropping(to: pixels)
        view.layer?.contentsScale = scale
        (parent ?? stage).addSubview(view)
        if parent == nil { pictures.append(view) }
        return view
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class PictureView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            layer?.contentsGravity = .resize
        }

        /// Never unarchived.
        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {}
    }
}
