import AppKit
import QuartzCore

/// Physical displays use their calibrated gamma tables. Sidecar transmits the
/// composited desktop before those tables, so its filter must live in that desktop.
@MainActor
final class DisplayFilterController: @preconcurrency GammaControlling {
    private let gamma: GammaControlling
    private let sidecar: GammaControlling
    private let isSidecar: @MainActor (CGDirectDisplayID) -> Bool
    private var routes: [CGDirectDisplayID: Bool] = [:]

    init(
        gamma: GammaControlling = GammaController(),
        sidecar: GammaControlling = SidecarFilterController(),
        isSidecar: @escaping @MainActor (CGDirectDisplayID) -> Bool = {
            DisplayFilterController.isSidecarDisplay($0)
        }
    ) {
        self.gamma = gamma
        self.sidecar = sidecar
        self.isSidecar = isSidecar
    }

    func applyFilter(to id: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool) {
        let useSidecar: Bool
        if let cached = routes[id] {
            useSidecar = cached
        } else {
            useSidecar = isSidecar(id)
            routes[id] = useSidecar
            // Relinquish a previous backend once when discovering this route,
            // rather than performing cross-backend cleanup on every fade frame.
            if useSidecar { gamma.restore(id) }
            else { sidecar.restore(id) }
        }
        if useSidecar {
            sidecar.applyFilter(to: id, intensity: intensity, whitepoint: whitepoint, invert: invert)
        } else {
            gamma.applyFilter(to: id, intensity: intensity, whitepoint: whitepoint, invert: invert)
        }
    }

    func restore(_ id: CGDirectDisplayID) {
        routes.removeValue(forKey: id)
        sidecar.restore(id)
        gamma.restore(id)
    }

    func restoreAll() {
        routes.removeAll()
        sidecar.restoreAll()
        gamma.restoreAll()
    }

    func displaysDidChange() {
        routes.removeAll()
        sidecar.displaysDidChange()
        gamma.displaysDidChange()
    }

    static func isSidecarDisplay(_ id: CGDirectDisplayID) -> Bool {
        // Sidecar's model is 'iPad'. Also recognize its system-provided name on
        // older OS versions; neither test depends on a transient display ID.
        CGDisplayModelNumber(id) == 0x6950_6164
            || screen(for: id)?.localizedName.localizedCaseInsensitiveContains("Sidecar") == true
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
    }
}

/// Core Animation's four curve values are cubic Bernstein controls. Redlight's
/// highlight-reduction polynomial fits exactly, including inversion and RGB gains.
enum SidecarTransferCurve {
    static func controls(gain: Float, whitepoint: Float, invert: Bool) -> [Float] {
        let values: [Float] = [0, gain / 3, gain * 2 * whitepoint / 3, gain * whitepoint]
        return invert ? Array(values.reversed()) : values
    }
}

/// A WindowServer backdrop samples the windows beneath it and filters them before
/// Sidecar encodes the image. No screen capture, input monitoring, or iPad setup.
/// This uses guarded private Core Animation SPI, as the public gamma API has no
/// visible effect on Sidecar. Normal displays never enter this path.
@MainActor
protocol SidecarOverlay: AnyObject {
    func apply(screen: NSScreen, intensity: Float, whitepoint: Float, invert: Bool)
    func invalidateSurface()
    /// Draws `cursor` beneath the filter at a global location; nil removes it.
    func updatePointer(_ cursor: NSCursor?, at location: NSPoint)
    func close()
}

/// WindowServer composites the pointer after every window, so a backdrop cannot
/// sample it. While the pointer is over a filtered Sidecar display, Redlight hides
/// it and draws the current cursor image beneath the backdrop instead.
@MainActor
protocol SidecarPointerSystem: AnyObject {
    var location: NSPoint { get }
    var isVisible: Bool { get }
    /// Changes whenever the system cursor's image changes.
    var seed: Int { get }
    var cursor: NSCursor { get }
    func hide()
    func show()
    func startMonitoring(_ changed: @escaping @MainActor () -> Void)
    func stopMonitoring()
}

@MainActor
final class SidecarFilterController: @preconcurrency GammaControlling {
    private var overlays: [CGDirectDisplayID: any SidecarOverlay] = [:]
    private var screens: [CGDirectDisplayID: NSScreen] = [:]
    private var unavailable: Set<CGDirectDisplayID> = []
    private let getScreen: @MainActor (CGDirectDisplayID) -> NSScreen?
    private let makeOverlay: @MainActor (NSScreen) -> (any SidecarOverlay)?
    private let pointer: (any SidecarPointerSystem)?
    private var isMonitoringPointer = false
    private var pointerHideCount = 0
    private var pointerCursor: (seed: Int, cursor: NSCursor)?

    init(
        getScreen: @escaping @MainActor (CGDirectDisplayID) -> NSScreen? = {
            DisplayFilterController.screen(for: $0)
        },
        makeOverlay: @escaping @MainActor (NSScreen) -> (any SidecarOverlay)? = {
            SidecarFilterWindow(screen: $0)
        },
        pointer: (any SidecarPointerSystem)? = SidecarSystemPointer()
    ) {
        self.getScreen = getScreen
        self.makeOverlay = makeOverlay
        self.pointer = pointer
    }

    func applyFilter(to id: CGDirectDisplayID, intensity: Float, whitepoint: Float, invert: Bool) {
        guard intensity != 1 || whitepoint != 1 || invert else { restore(id); return }
        guard !unavailable.contains(id) else { return }
        guard let screen = screens[id] ?? getScreen(id) else { restore(id); return }
        screens[id] = screen
        if overlays[id] == nil {
            guard let window = makeOverlay(screen) else {
                unavailable.insert(id)
                NSLog("Redlight: Sidecar compositor filter is unavailable for display %u", id)
                return
            }
            overlays[id] = window
        }
        overlays[id]?.apply(screen: screen, intensity: intensity, whitepoint: whitepoint, invert: invert)
        if !isMonitoringPointer { syncPointer() }
    }

    func restore(_ id: CGDirectDisplayID) {
        screens.removeValue(forKey: id)
        unavailable.remove(id)
        overlays.removeValue(forKey: id)?.close()
        syncPointer()
    }

    func restoreAll() {
        for window in overlays.values { window.close() }
        overlays.removeAll()
        screens.removeAll()
        unavailable.removeAll()
        syncPointer()
    }

    func displaysDidChange() {
        screens.removeAll()
        unavailable.removeAll()
        for overlay in overlays.values { overlay.invalidateSurface() }
        // Geometry is unknown until the next apply, which resumes the replica.
        syncPointer()
    }

    private func syncPointer() {
        guard let pointer else { return }
        if overlays.isEmpty {
            releasePointer()
            if isMonitoringPointer { pointer.stopMonitoring(); isMonitoringPointer = false }
            return
        }
        if !isMonitoringPointer {
            isMonitoringPointer = true
            pointer.startMonitoring { [weak self] in self?.syncPointer() }
        }
        let location = pointer.location
        let target = overlays.keys.first { id in
            screens[id].map { NSMouseInRect(location, $0.frame, false) } == true
        }
        var cursor: NSCursor?
        if target != nil {
            // App activation can unhide the pointer, so hide again whenever it
            // reappears and balance every hide when the pointer leaves.
            if pointer.isVisible {
                pointer.hide()
                pointerHideCount += 1
            }
            // Otherwise another app (such as a full-screen video) hid it first.
            if pointerHideCount > 0 {
                let seed = pointer.seed
                if pointerCursor?.seed != seed { pointerCursor = (seed, pointer.cursor) }
                cursor = pointerCursor?.cursor
            }
        } else {
            releasePointer()
        }
        for (id, overlay) in overlays {
            overlay.updatePointer(id == target ? cursor : nil, at: location)
        }
    }

    private func releasePointer() {
        guard let pointer else { return }
        while pointerHideCount > 0 {
            pointer.show()
            pointerHideCount -= 1
        }
    }
}

/// Uses guarded private SkyLight calls to hide the pointer while another app is
/// active and to detect cursor image changes. Without them the pointer is
/// simply left unfiltered.
@MainActor
final class SidecarSystemPointer: SidecarPointerSystem {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias IntFn = @convention(c) () -> Int32

    private let connection: Int32
    private let setProperty: SetPropertyFn
    private let isVisibleFn: IntFn
    private let seedFn: IntFn
    private var hidesInBackground = false
    private var monitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var timer: Timer?

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let setProperty = dlsym(handle, "SLSSetConnectionProperty"),
              let isVisible = dlsym(handle, "SLCursorIsVisible"),
              let seed = dlsym(handle, "SLSCurrentCursorSeed")
        else { return nil }
        self.connection = unsafeBitCast(connection, to: ConnectionFn.self)()
        self.setProperty = unsafeBitCast(setProperty, to: SetPropertyFn.self)
        isVisibleFn = unsafeBitCast(isVisible, to: IntFn.self)
        seedFn = unsafeBitCast(seed, to: IntFn.self)
    }

    var location: NSPoint { NSEvent.mouseLocation }
    var isVisible: Bool { isVisibleFn() != 0 }
    var seed: Int { Int(seedFn()) }
    var cursor: NSCursor { NSCursor.currentSystem ?? .arrow }
    func hide() {
        // Deferred until needed, so Macs without Sidecar never change this property.
        if !hidesInBackground {
            hidesInBackground = setProperty(
                connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
        }
        CGDisplayHideCursor(kCGNullDirectDisplay)
    }
    func show() { CGDisplayShowCursor(kCGNullDirectDisplay) }

    func startMonitoring(_ changed: @escaping @MainActor () -> Void) {
        stopMonitoring()
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        ]
        // Global monitors miss Redlight's own windows, such as its popover.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in
            MainActor.assumeIsolated { changed() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            changed()
            return event
        }) { monitors.append(local) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { changed() }
        }
        // Catches cursor changes and unhiding that arrive without pointer events.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { changed() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class SidecarFilterWindow: NSWindow, SidecarOverlay {
    private struct Output: Equatable {
        let intensity: Float
        let whitepoint: Float
        let invert: Bool
    }

    private let backdrop: CALayer
    private let pointer = CALayer()
    private weak var pointerCursor: NSCursor?
    private let curve: NSObject
    private var lastOutput: Output?
    private var lastBackingScale: CGFloat
    private var needsSurfaceRebuild = false
    private var spaceObservation: SidecarNotificationObservation?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init?(screen: NSScreen) {
        guard let backdropType = NSClassFromString("CABackdropLayer") as? NSObject.Type,
              backdropType.responds(to: NSSelectorFromString("layer")),
              let backdrop = backdropType.perform(NSSelectorFromString("layer"))?.takeUnretainedValue() as? CALayer,
              let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
              filterType.responds(to: NSSelectorFromString("filterWithType:")),
              let curve = filterType.perform(NSSelectorFromString("filterWithType:"), with: "curves")?
                .takeUnretainedValue() as? NSObject,
              curve.responds(to: NSSelectorFromString("inputKeys")),
              let keys = curve.perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String],
              Set(["inputRedValues", "inputGreenValues", "inputBlueValues"]).isSubset(of: Set(keys)),
              backdrop.responds(to: NSSelectorFromString("setWindowServerAware:")),
              backdrop.responds(to: NSSelectorFromString("setAllowsInPlaceFiltering:")),
              backdrop.responds(to: NSSelectorFromString("setScale:")),
              backdrop.responds(to: NSSelectorFromString("setBleedAmount:"))
        else { return nil }
        self.backdrop = backdrop
        self.curve = curve
        self.lastBackingScale = screen.backingScaleFactor
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)

        // shouldAutoFlattenLayerTree is a KVC-only AppKit setting on macOS 27;
        // it deliberately has no Objective-C setter to check with responds(to:).
        guard responds(to: NSSelectorFromString("setCanHostLayersInWindowServer:")) else { return nil }
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = NSColor.white.withAlphaComponent(0.001)
        hasShadow = false
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        contentView = view
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(false, forKey: "allowsInPlaceFiltering")
        backdrop.setValue(1, forKey: "scale")
        backdrop.setValue(0, forKey: "bleedAmount")
        backdrop.frame = view.bounds
        backdrop.contentsScale = screen.backingScaleFactor
        pointer.isHidden = true
        pointer.contentsScale = screen.backingScaleFactor
        // Beneath the backdrop, so the replica pointer is filtered with the desktop.
        view.layer?.addSublayer(pointer)
        view.layer?.addSublayer(backdrop)
        rebuildLayerSurface()

        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildLayerSurface() }
        }
        spaceObservation = SidecarNotificationObservation(center: center, observer: observer)
    }

    func apply(screen: NSScreen, intensity: Float, whitepoint: Float, invert: Bool) {
        let output = Output(intensity: intensity, whitepoint: whitepoint, invert: invert)
        let screenFrame = screen.frame
        let backingScale = screen.backingScaleFactor
        let geometryChanged = frame != screenFrame || lastBackingScale != backingScale
        guard output != lastOutput || geometryChanged || needsSurfaceRebuild else {
            if !isVisible { orderFrontRegardless() }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // CAFilter is a value in the render tree. Mutating an already attached
        // instance leaves WindowServer using its old values (notably the first,
        // nearly neutral frame of a startup fade). Submit a new snapshot each time.
        if output != lastOutput {
            guard let filter = curve.copy() as? NSObject else { return }
            let gains: [Float] = [1, intensity, max(0, intensity * 2 - 1)]
            for (key, gain) in zip(["inputRedValues", "inputGreenValues", "inputBlueValues"], gains) {
                filter.setValue(SidecarTransferCurve.controls(gain: gain, whitepoint: whitepoint, invert: invert), forKey: key)
            }
            backdrop.filters = [filter]
            lastOutput = output
        }
        if geometryChanged || needsSurfaceRebuild {
            setFrame(screenFrame, display: false)
            backdrop.frame = contentView?.bounds ?? .zero
            backdrop.contentsScale = backingScale
            pointer.contentsScale = backingScale
            lastBackingScale = backingScale
            rebuildLayerSurface()
        }
        if !isVisible { orderFrontRegardless() }
    }

    func invalidateSurface() {
        needsSurfaceRebuild = true
    }

    func updatePointer(_ cursor: NSCursor?, at location: NSPoint) {
        guard cursor != nil || !pointer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let cursor else { pointer.isHidden = true; return }
        if cursor !== pointerCursor {
            let size = cursor.image.size
            pointer.contents = cursor.image
            pointer.bounds = CGRect(origin: .zero, size: size)
            // hotSpot is measured from the image's top-left corner.
            pointer.anchorPoint = size.width > 0 && size.height > 0
                ? CGPoint(x: cursor.hotSpot.x / size.width, y: 1 - cursor.hotSpot.y / size.height)
                : .zero
            pointerCursor = cursor
        }
        pointer.position = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        pointer.isHidden = false
    }

    private func rebuildLayerSurface() {
        // AppKit otherwise flattens the backdrop into an inert window image,
        // including after a Spaces transition. Recreate its WindowServer surface.
        setValue(false, forKey: "shouldAutoFlattenLayerTree")
        setValue(false, forKey: "canHostLayersInWindowServer")
        setValue(true, forKey: "canHostLayersInWindowServer")
        needsSurfaceRebuild = false
    }

    override func close() {
        spaceObservation = nil
        super.close()
    }
}

/// Cancellation also runs if an unopened window is released without close().
private final class SidecarNotificationObservation {
    private let center: NotificationCenter
    private let observer: NSObjectProtocol

    init(center: NotificationCenter, observer: NSObjectProtocol) {
        self.center = center
        self.observer = observer
    }

    deinit { center.removeObserver(observer) }
}
