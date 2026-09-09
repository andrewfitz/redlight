import AppKit
import ColorSync
import Observation

@MainActor
@Observable
final class DisplayManager {
    struct DisplayInfo: Identifiable {
        let id: CGDirectDisplayID
        /// Stable ColorSync-UUID key used for UserDefaults; resolved once on connect.
        let persistenceKey: String
        var name: String
        var isEnabled: Bool
        var isInverted: Bool
    }

    struct OutputPair: Equatable {
        var intensity: Double
        var whitepoint: Double
    }

    private enum OutputChannel: Hashable {
        case intensity
        case whitepoint
    }

    private struct OutputTransition {
        var from: OutputPair
        var to: OutputPair
        var startedAt: TimeInterval
        var channels: Set<OutputChannel>
    }

    private struct DisplayTransition {
        var fromAmount: Double
        var toAmount: Double
        var currentAmount: Double
        var startedAt: TimeInterval
    }

    /// Factory settings. Single source of truth for both first launch and the reset buttons,
    /// so the two can't drift apart.
    ///
    /// Default means *no filter at all*, not "a bit of filter": `intensity` 1.0 is an
    /// untouched display (0.0 is pure red), and `whitepoint` 1.0 is no white-point reduction.
    /// Intensity defaults to its full range. White Point starts at the Deep Red preset's
    /// 0.30 anchor so factory adaptive values are not silently stretched down to 0.25;
    /// users can still drag that band marker to the slider's 0.25 floor.
    enum Defaults {
        static let intensity = 1.0
        static let intensityMin = 0.0
        static let intensityMax = 1.0
        static let whitepoint = 1.0
        static let whitepointMin = 0.3
        static let whitepointMax = 1.0
        static let adaptiveFadeDuration: TimeInterval = 2.0
        static let displayFadeDuration: TimeInterval = 0.7
    }

    private(set) var displays: [DisplayInfo] = []
    var intensity: Double = 0.5 {
        didSet {
            // Internal (adaptive/preset) writes apply + save once at their call site.
            guard isInitialized, !internalUpdate else { return }
            cancelOutputTransition(.intensity)
            if adaptiveEnabled {
                // While adaptive: the band is a hard limit on a manual nudge…
                let clamped = clamp(intensity, to: intensityBand)
                if clamped != intensity { setInternal { intensity = clamped } }
                // …and the nudge becomes a baseline offset the curve keeps riding — but
                // only against a real curve value. Before the location resolves there is
                // no baseline, and deriving an offset from the placeholder would later
                // clobber the display with garbage.
                if let curve = lastCurveIntensity {
                    adaptiveIntensityOffset = clamped - curve
                    pendingAdaptiveIntensity = nil
                } else {
                    pendingAdaptiveIntensity = clamped
                }
            } else {
                activePresetIndex = nil
                pendingAdaptiveIntensity = nil
            }
            applyToActiveDisplays()
            save()
        }
    }
    var whitepoint: Double = 1.0 {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            cancelOutputTransition(.whitepoint)
            if adaptiveEnabled {
                let clamped = clamp(whitepoint, to: whitepointBand)
                if clamped != whitepoint { setInternal { whitepoint = clamped } }
                if let curve = lastCurveWhitepoint {
                    adaptiveWhitepointOffset = clamped - curve
                    pendingAdaptiveWhitepoint = nil
                } else {
                    pendingAdaptiveWhitepoint = clamped
                }
            } else {
                activePresetIndex = nil
                pendingAdaptiveWhitepoint = nil
            }
            applyToActiveDisplays()
            save()
        }
    }

    var isAnyActive: Bool {
        !fadingDisplayIDs.isEmpty || displays.contains { $0.isEnabled || $0.isInverted }
    }

    // MARK: - Presets

    var presets: [Preset] = Preset.defaults
    var activePresetIndex: Int? = nil

    // MARK: - Adaptive

    var adaptiveEnabled: Bool = false {
        didSet {
            guard isInitialized, !internalUpdate, adaptiveEnabled != oldValue else { return }
            let rendered = currentRenderedOutput()
            cancelOutputTransition()
            if adaptiveEnabled {
                activePresetIndex = nil
                animateNextAdaptiveTarget = true
                requestLocationIfNeeded(at: now(), force: true)
                // Keep the exact current manual output while location resolves. Once a
                // target exists, `applyAdaptive` fades smoothly from this held pair.
                transitionIntensityValue = rendered.intensity
                transitionWhitepointValue = rendered.whitepoint
                applyAdaptive(transitionFrom: rendered)
                startAdaptiveTimer()
            } else {
                animateNextAdaptiveTarget = false
                stopAdaptiveTracking()
                // Adaptive-off is a hold, not a mode switch back to an older snapshot.
                // Commit the exact frame the user was seeing (including a partially
                // completed two-channel fade) so both sliders, persistence, and gamma stay
                // in lockstep with no toggle-edge jump.
                setInternal {
                    intensity = rendered.intensity
                    whitepoint = rendered.whitepoint
                    activePresetIndex = nil
                }
                applyToActiveDisplays()
            }
            save()
        }
    }
    /// Adaptive intensity is remapped into this band: Day → max, deepest night → min.
    /// Defaults 0…1 = no constraint. The model keeps `adaptiveMin <= adaptiveMax`.
    var adaptiveMin: Double = 0.0 {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            let v = clamp(adaptiveMin, to: 0...1)
            if v != adaptiveMin { setInternal { adaptiveMin = v } }
            if v > adaptiveMax { setInternal { adaptiveMax = v } }
            scheduleBandRefresh(.intensity)
        }
    }
    var adaptiveMax: Double = 1.0 {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            let v = clamp(adaptiveMax, to: 0...1)
            if v != adaptiveMax { setInternal { adaptiveMax = v } }
            if v < adaptiveMin { setInternal { adaptiveMin = v } }
            scheduleBandRefresh(.intensity)
        }
    }
    /// White Point band. Defaults 0.3…1.0 = the unbanded preset curve (non-breaking).
    var adaptiveWpMin: Double = 0.3 {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            let v = clamp(adaptiveWpMin, to: 0.25...1)
            if v != adaptiveWpMin { setInternal { adaptiveWpMin = v } }
            if v > adaptiveWpMax { setInternal { adaptiveWpMax = v } }
            scheduleBandRefresh(.whitepoint)
        }
    }
    var adaptiveWpMax: Double = 1.0 {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            let v = clamp(adaptiveWpMax, to: 0.25...1)
            if v != adaptiveWpMax { setInternal { adaptiveWpMax = v } }
            if v < adaptiveWpMin { setInternal { adaptiveWpMin = v } }
            scheduleBandRefresh(.whitepoint)
        }
    }
    private(set) var adaptiveStatusText: String = ""
    /// Last known location, set while adaptive resolves it — drives the sun-arc graphic.
    private(set) var coordinate: (latitude: Double, longitude: Double)?

    /// The band as hard limits, lo/hi order normalized.
    var intensityBand: ClosedRange<Double> {
        min(adaptiveMin, adaptiveMax)...max(adaptiveMin, adaptiveMax)
    }
    var whitepointBand: ClosedRange<Double> {
        min(adaptiveWpMin, adaptiveWpMax)...max(adaptiveWpMin, adaptiveWpMax)
    }
    var adaptiveIntensityAdjustment: Double { adaptiveIntensityOffset }

    /// Applied sample used by the sun arc. Keeping the offset and hard-band clamp here makes
    /// the graphic follow the exact same adjusted curve as the real display.
    func adaptiveIntensity(at elevation: Double, minElevation: Double) -> Double {
        let banded = AdaptiveMapping.banded(
            elevation: elevation, minElevation: minElevation, presets: presets,
            intensityMin: adaptiveMin, intensityMax: adaptiveMax,
            whitepointMin: adaptiveWpMin, whitepointMax: adaptiveWpMax
        )
        return clamp(banded.intensity + adaptiveIntensityOffset, to: intensityBand)
    }

    func applyAdaptive() {
        applyAdaptive(transitionFrom: nil)
    }

    private func applyAdaptive(transitionFrom explicitStart: OutputPair?) {
        guard adaptiveEnabled else { return }
        let hadPendingAdjustment = pendingAdaptiveIntensity != nil
            || pendingAdaptiveWhitepoint != nil
        guard let target = resolveAdaptiveTarget() else { return }
        let rendered = explicitStart ?? currentRenderedOutput()
        // @Observable fires on every write, equal or not. On the 5 s tick the target
        // usually hasn't moved; skip the write so the open popover doesn't re-render.
        setInternal {
            if intensity != target.intensity { intensity = target.intensity }
            if whitepoint != target.whitepoint { whitepoint = target.whitepoint }
        }

        let transitionChannels: Set<OutputChannel>
        if animateNextAdaptiveTarget || explicitStart != nil {
            transitionChannels = [.intensity, .whitepoint]
        } else {
            transitionChannels = outputTransition?.channels ?? []
        }

        if !transitionChannels.isEmpty {
            animateNextAdaptiveTarget = false
            startOutputTransition(from: rendered, to: target, channels: transitionChannels)
        } else {
            cancelOutputTransition()
            applyToActiveDisplays()
        }
        if hadPendingAdjustment { save() }
    }

    /// Resolve the current curve and update descriptive state without touching gamma. This
    /// separation lets a user toggle animate toward the target instead of briefly applying
    /// the endpoint first.
    private func resolveAdaptiveTarget() -> OutputPair? {
        let date = now()
        requestLocationIfNeeded(at: date)
        // A denied prompt is not fatal: the time-zone city (or the last precise fix) still
        // gives the curve a solar position. Only a total absence of any coordinate blocks.
        guard let coord = location.coordinate else {
            coordinate = nil
            adaptiveStatusText = location.authorization == .denied ? "Location needed" : "Locating…"
            return nil
        }
        if coordinate == nil || coordinate! != coord { coordinate = coord }   // avoid spurious invalidation

        let elev = SolarCalculator.elevation(at: date, latitude: coord.latitude, longitude: coord.longitude)
        let minElev = SolarCalculator.elevationAtSolarMidnight(at: date, latitude: coord.latitude, longitude: coord.longitude)
        let banded = AdaptiveMapping.banded(
            elevation: elev, minElevation: minElev, presets: presets,
            intensityMin: adaptiveMin, intensityMax: adaptiveMax,
            whitepointMin: adaptiveWpMin, whitepointMax: adaptiveWpMax
        )

        // If the user moved a slider while Core Location was still resolving, preserve the
        // requested value and derive its curve-relative offset only now that a real baseline
        // exists. Using the temporary held output as a baseline would make the later target
        // jump or silently discard the edit.
        if let pendingAdaptiveIntensity {
            adaptiveIntensityOffset = clamp(pendingAdaptiveIntensity, to: intensityBand)
                - banded.intensity
            self.pendingAdaptiveIntensity = nil
        }
        if let pendingAdaptiveWhitepoint {
            adaptiveWhitepointOffset = clamp(pendingAdaptiveWhitepoint, to: whitepointBand)
                - banded.whitepoint
            self.pendingAdaptiveWhitepoint = nil
        }
        lastCurveIntensity = banded.intensity
        lastCurveWhitepoint = banded.whitepoint

        // The band is a HARD limit: curve + manual offset can never leave it. Because the
        // offset is always (band-clamped nudge − curve), reapplying is idempotent — no windup.
        let target = OutputPair(
            intensity: clamp(banded.intensity + adaptiveIntensityOffset, to: intensityBand),
            whitepoint: clamp(banded.whitepoint + adaptiveWhitepointOffset, to: whitepointBand))

        let elevationText = Self.formatElevation(elev)
        let adjusted = (adaptiveIntensityOffset != 0 || adaptiveWhitepointOffset != 0)
            ? " · adjusted" : ""
        let source = location.isApproximate ? " · time zone"
            : location.authorization == .denied ? " · last known" : ""
        let status = "Following the sun · \(elevationText)\(adjusted)\(source)"
        if status != adaptiveStatusText { adaptiveStatusText = status }   // avoid 5 s-tick invalidation
        return target
    }

    private static func formatElevation(_ elevation: Double) -> String {
        let rounded = (elevation * 10).rounded() / 10
        let sign = rounded > 0 ? "+" : rounded < 0 ? "−" : ""
        return "\(sign)\(String(format: "%.1f", abs(rounded)))°"
    }

    private func startAdaptiveTimer() {
        adaptiveTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAdaptive() }
        }
        // The sun moves ~0.004°/s; a second of slack lets the kernel coalesce this wake-up
        // with others instead of firing on its own, which matters for a resident app.
        timer.tolerance = 1
        // Common mode keeps the status line and curve moving while the popover tracks a
        // control, matching the fade timer.
        RunLoop.main.add(timer, forMode: .common)
        adaptiveTimer = timer
    }

    /// Stop solar tracking without discarding any user-authored offsets or limits. Those
    /// settings survive an off/on round-trip; only an explicit reset changes them.
    private func stopAdaptiveTracking() {
        adaptiveTimer?.invalidate()
        adaptiveTimer = nil
        location.cancelRequest()
        lastCurveIntensity = nil
        lastCurveWhitepoint = nil
        lastLocationRequest = nil
        adaptiveStatusText = ""
    }

    // MARK: - Reset

    /// Whether a row still has anything to reset. Under adaptive the live value is the
    /// curve's to set, not the user's, so only the band and the manual offset count.
    var intensityIsDefault: Bool {
        guard adaptiveMin == Defaults.intensityMin, adaptiveMax == Defaults.intensityMax else { return false }
        return adaptiveEnabled
            ? adaptiveIntensityOffset == 0 && pendingAdaptiveIntensity == nil
            : intensity == Defaults.intensity
    }

    var whitepointIsDefault: Bool {
        guard adaptiveWpMin == Defaults.whitepointMin, adaptiveWpMax == Defaults.whitepointMax else { return false }
        return adaptiveEnabled
            ? adaptiveWhitepointOffset == 0 && pendingAdaptiveWhitepoint == nil
            : whitepoint == Defaults.whitepoint
    }

    /// Restore Intensity to factory settings: the band back to its full default range, any
    /// manual adaptive nudge discarded, and the value itself back to default. Under adaptive
    /// the value isn't the user's to set, so we drop the offset and let the curve reclaim it.
    func resetIntensity() {
        cancelOutputTransition(.intensity)
        setInternal {
            adaptiveMin = Defaults.intensityMin
            adaptiveMax = Defaults.intensityMax
            adaptiveIntensityOffset = 0
            pendingAdaptiveIntensity = nil
            intensity = Defaults.intensity
        }
        finishReset()
    }

    /// Same for Reduce White Point. `whitepoint` is a *reduction*, so its default (1.0) means
    /// no reduction at all.
    func resetWhitepoint() {
        cancelOutputTransition(.whitepoint)
        setInternal {
            adaptiveWpMin = Defaults.whitepointMin
            adaptiveWpMax = Defaults.whitepointMax
            adaptiveWhitepointOffset = 0
            pendingAdaptiveWhitepoint = nil
            whitepoint = Defaults.whitepoint
        }
        finishReset()
    }

    /// Both resets bypass the property didSets (via `setInternal`), so drive the side effects
    /// once, here. Under adaptive the curve immediately overwrites the value we just set —
    /// that's intended: default means "whatever the sun says, unconstrained".
    private func finishReset() {
        activePresetIndex = nil
        if adaptiveEnabled {
            // No solar target yet: still render the value we just set, as init/wake do,
            // so model and gamma cannot disagree.
            if location.coordinate == nil { applyToActiveDisplays() }
            applyAdaptive()
        } else {
            applyToActiveDisplays()
        }
        save()
    }

    // MARK: - Private

    private let gamma: GammaControlling
    private let getDisplayIDs: () -> [CGDirectDisplayID]
    private let getDisplayName: (CGDirectDisplayID) -> String
    private let getDisplayPersistenceKey: (CGDirectDisplayID) -> String
    private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let location: LocationProviding
    // nonisolated(unsafe): mutated only on the main actor; read in deinit for cleanup.
    @ObservationIgnored nonisolated(unsafe) private var adaptiveTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var bandRefreshTimer: Timer?
    @ObservationIgnored private var pendingBandRefreshChannels: Set<OutputChannel> = []
    // Adaptive and per-display fades share one render clock. When both move at once this
    // keeps the gamma table to one coherent write per frame instead of two staggered writes.
    @ObservationIgnored nonisolated(unsafe) private var transitionTimer: Timer?
    @ObservationIgnored private var displayTransitions: [CGDirectDisplayID: DisplayTransition] = [:]
    // Observable only at transition boundaries so the tray icon remains active throughout a
    // fade-out without invalidating SwiftUI on every 60 Hz gamma frame.
    private var fadingDisplayIDs: Set<CGDirectDisplayID> = []
    @ObservationIgnored nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var adaptiveIntensityOffset: Double = 0
    @ObservationIgnored private var adaptiveWhitepointOffset: Double = 0
    // An adaptive slider can be moved before a location-backed solar curve exists. Keep that
    // desired value until the curve resolves, then convert it to the usual persistent offset.
    @ObservationIgnored private var pendingAdaptiveIntensity: Double?
    @ObservationIgnored private var pendingAdaptiveWhitepoint: Double?
    // Transient live-preview overrides while a band marker is being dragged.
    @ObservationIgnored private var previewIntensityValue: Double?
    @ObservationIgnored private var previewWhitepointValue: Double?
    // Transient rendered-output overrides used only by the Adaptive toggle crossfade.
    @ObservationIgnored private var transitionIntensityValue: Double?
    @ObservationIgnored private var transitionWhitepointValue: Double?
    @ObservationIgnored private var outputTransition: OutputTransition?
    @ObservationIgnored private var shutdownOutput: OutputPair?
    @ObservationIgnored private var shutdownDisplayAmounts: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var shutdownCompletion: (() -> Void)?
    private(set) var isTerminating = false
    @ObservationIgnored private var animateNextAdaptiveTarget = false
    // Last banded curve values — nil until `applyAdaptive()` has actually resolved one,
    // so a slider nudge can't derive an offset from a fake baseline.
    @ObservationIgnored private var lastCurveIntensity: Double?
    @ObservationIgnored private var lastCurveWhitepoint: Double?
    @ObservationIgnored private var lastLocationRequest: Date?
    @ObservationIgnored private var hasActivatedForLocationPrompt = false
    // Presets rarely change; skip re-encoding them on every slider-driven save.
    @ObservationIgnored private var lastSavedPresets: [Preset]?
    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored private var internalUpdate = false
    @ObservationIgnored private let adaptiveTransitionDuration: TimeInterval
    @ObservationIgnored private let displayTransitionDuration: TimeInterval
    @ObservationIgnored private let transitionUptime: () -> TimeInterval

    init(
        gamma: GammaControlling = GammaController(),
        getDisplayIDs: @escaping () -> [CGDirectDisplayID] = { DisplayManager.systemDisplayIDs() },
        getDisplayName: @escaping (CGDirectDisplayID) -> String = { DisplayManager.systemDisplayName(for: $0) },
        getDisplayPersistenceKey: @escaping (CGDirectDisplayID) -> String = {
            DisplayManager.systemDisplayPersistenceKey(for: $0)
        },
        defaults: UserDefaults = .standard,
        location: LocationProviding = LocationProvider(),
        now: @escaping () -> Date = { Date() },
        adaptiveTransitionDuration: TimeInterval = Defaults.adaptiveFadeDuration,
        displayTransitionDuration: TimeInterval = Defaults.displayFadeDuration,
        transitionUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.gamma = gamma
        self.getDisplayIDs = getDisplayIDs
        self.getDisplayName = getDisplayName
        self.getDisplayPersistenceKey = getDisplayPersistenceKey
        self.defaults = defaults
        self.location = location
        self.now = now
        self.adaptiveTransitionDuration = max(0, adaptiveTransitionDuration)
        self.displayTransitionDuration = max(0, displayTransitionDuration)
        self.transitionUptime = transitionUptime
        // Clamp on load: a hand-edited or corrupt plist must not put the thumb off the
        // track or send >1 into the gamma composer. (Bands are normalized below.)
        self.intensity = Self.loadClamped(
            defaults, "redlight.intensity", default: Defaults.intensity, range: 0...1)
        self.whitepoint = Self.loadClamped(
            defaults, "redlight.whitepoint", default: Defaults.whitepoint, range: 0.25...1)
        self.adaptiveEnabled = defaults.bool(forKey: "redlight.adaptiveEnabled")
        self.adaptiveIntensityOffset = defaults.object(forKey: "redlight.adaptiveOffsetIntensity") as? Double ?? 0
        self.adaptiveWhitepointOffset = defaults.object(forKey: "redlight.adaptiveOffsetWhitepoint") as? Double ?? 0
        self.pendingAdaptiveIntensity = defaults.object(
            forKey: "redlight.pendingAdaptiveIntensity") as? Double
        self.pendingAdaptiveWhitepoint = defaults.object(
            forKey: "redlight.pendingAdaptiveWhitepoint") as? Double
        self.adaptiveMin = defaults.object(forKey: "redlight.adaptiveMin") as? Double ?? Defaults.intensityMin
        self.adaptiveMax = defaults.object(forKey: "redlight.adaptiveMax") as? Double ?? Defaults.intensityMax
        self.adaptiveWpMin = defaults.object(forKey: "redlight.adaptiveWpMin") as? Double ?? Defaults.whitepointMin
        self.adaptiveWpMax = defaults.object(forKey: "redlight.adaptiveWpMax") as? Double ?? Defaults.whitepointMax
        normalizeBands()
        loadPresets()
        if adaptiveEnabled { activePresetIndex = nil }
        refreshDisplays(apply: false)
        startListening()
        location.onChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.adaptiveEnabled else { return }
                // A better fix (time-zone city → precise, or a move while asleep) can
                // shift the target several degrees. Fade there rather than step.
                self.animateNextAdaptiveTarget = true
                self.applyAdaptive()
            }
        }
        isInitialized = true
        prepareStartupDisplayTransitions()
        if adaptiveEnabled {
            requestLocationIfNeeded(at: now(), force: true)
            // With a cached coordinate, calculate first so a persisted value from hours ago
            // is never flashed onto the display during launch. Without one, use the saved
            // value as a temporary fallback until Core Location responds.
            if location.coordinate == nil {
                applyToActiveDisplays()
            }
            applyAdaptive()
            startAdaptiveTimer()
        } else {
            applyToActiveDisplays()
        }
        startPreparedStartupDisplayTransitions()
    }

    deinit {
        adaptiveTimer?.invalidate()
        bandRefreshTimer?.invalidate()
        transitionTimer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Enforce band invariants on persisted values (didSets don't run during init).
    private func normalizeBands() {
        adaptiveMin = clamp(adaptiveMin, to: 0...1)
        adaptiveMax = clamp(adaptiveMax, to: 0...1)
        if adaptiveMin > adaptiveMax { swap(&adaptiveMin, &adaptiveMax) }
        adaptiveWpMin = clamp(adaptiveWpMin, to: 0.25...1)
        adaptiveWpMax = clamp(adaptiveWpMax, to: 0.25...1)
        if adaptiveWpMin > adaptiveWpMax { swap(&adaptiveWpMin, &adaptiveWpMax) }
    }

    private func clamp(_ v: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, v))
    }

    /// Write properties without re-triggering their didSet side effects. Nesting-safe: an
    /// inner call restores the outer state instead of re-enabling didSets mid-body.
    private func setInternal(_ body: () -> Void) {
        let previous = internalUpdate
        internalUpdate = true
        defer { internalUpdate = previous }
        body()
    }

    private static func loadClamped(
        _ defaults: UserDefaults, _ key: String, default fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard let value = defaults.object(forKey: key) as? Double, value.isFinite else {
            return fallback
        }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// Refresh the one-shot kilometer-accuracy location occasionally while Adaptive stays
    /// enabled. This keeps a traveling Mac on the right solar cycle without continuous GPS.
    private func requestLocationIfNeeded(at date: Date, force: Bool = false) {
        guard location.authorization != .denied else { return }
        let elapsed = lastLocationRequest.map { date.timeIntervalSince($0) }
        let refreshInterval: TimeInterval =
            (location.coordinate == nil || location.isApproximate) ? 60 : 3_600
        if !force, let elapsed, elapsed >= 0, elapsed < refreshInterval { return }
        lastLocationRequest = date
        // LSUIElement menu-bar apps otherwise often never surface the permission dialog.
        // Once per process: the 60 s retry loop must not keep yanking focus from whatever
        // the user is doing while the prompt sits unanswered.
        if location.authorization == .notDetermined, !hasActivatedForLocationPrompt {
            hasActivatedForLocationPrompt = true
            NSApplication.shared.activate()
        }
        location.requestWhenInUse()
    }

    // MARK: - Displays

    func refreshDisplays(apply: Bool = true) {
        // Dedupe defensively — a duplicate ID from the system would otherwise both trap
        // the uniquing dictionary and confuse SwiftUI's Identifiable ForEach.
        var seen = Set<CGDirectDisplayID>()
        let ids = getDisplayIDs().filter { seen.insert($0).inserted }
        let currentIDs = Set(ids)
        let previousIDs = Set(displays.map(\.id))
        // The screen-parameters notification also fires for Dock show/hide, resolution
        // changes and window minimize. Only a real add/remove can reset the GPU LUT and
        // ColorSync profile (a panel power-cycle removes and re-adds its display), so only
        // then ColorSync-restore everything, drop captures, and recapture on the re-apply
        // below — the same path Quit uses. Anywhere else this would be a visible flicker.
        let topologyChanged = previousIDs != currentIDs
        if apply, !isTerminating, topologyChanged {
            gamma.restoreAll()
        } else {
            // Forget a disconnected display's captured gamma table. If the same CoreGraphics
            // ID is reused when it reconnects, GammaController must snapshot its fresh
            // calibration.
            for display in displays where !currentIDs.contains(display.id)
                && (display.isEnabled || display.isInverted || displayTransitions[display.id] != nil)
            {
                gamma.restore(display.id)
            }
        }
        for id in Array(displayTransitions.keys) where !currentIDs.contains(id) {
            cancelDisplayTransition(id)
        }
        if topologyChanged {
            let prevEnabled = Dictionary(displays.map { ($0.id, $0.isEnabled) }, uniquingKeysWith: { a, _ in a })
            let prevInverted = Dictionary(displays.map { ($0.id, $0.isInverted) }, uniquingKeysWith: { a, _ in a })
            let prevKey = Dictionary(displays.map { ($0.id, $0.persistenceKey) }, uniquingKeysWith: { a, _ in a })
            displays = ids.map { id in
                // The ColorSync UUID lookup is a CoreGraphics call; resolve it once per
                // connect instead of on every save().
                let key = prevKey[id] ?? getDisplayPersistenceKey(id)
                let enabled = prevEnabled[id]
                    ?? persistedDisplayFlag(id, persistenceKey: key, suffix: "enabled")
                let inverted = prevInverted[id]
                    ?? persistedDisplayFlag(id, persistenceKey: key, suffix: "inverted")
                return DisplayInfo(
                    id: id, persistenceKey: key, name: getDisplayName(id),
                    isEnabled: enabled, isInverted: inverted)
            }
        } else {
            // Same displays: refresh names in place (a monitor can be renamed in System
            // Settings) without replacing the array and invalidating every row's identity.
            for i in displays.indices {
                let name = getDisplayName(displays[i].id)
                if displays[i].name != name { displays[i].name = name }
            }
        }
        if apply {
            synchronizeTransitionState(at: transitionUptime())
            // Always re-write: a resolution or refresh-rate change can reset the LUT without
            // changing the display set. Writing an identical table is invisible, so this
            // costs nothing on the Dock/minimize notifications.
            applyToActiveDisplays()
        }
        finishTerminationIfReady()
    }

    func toggle(_ displayID: CGDirectDisplayID) {
        guard !isTerminating else { return }
        guard let i = displays.firstIndex(where: { $0.id == displayID }) else { return }
        let wasEnabled = displays[i].isEnabled
        let fromAmount = currentDisplayAmount(
            for: displayID, fallback: wasEnabled ? 1 : 0)
        displays[i].isEnabled = !wasEnabled
        startDisplayTransition(
            displayID,
            from: fromAmount,
            to: displays[i].isEnabled ? 1 : 0)
        save()
    }

    func toggleInvert(_ displayID: CGDirectDisplayID) {
        guard !isTerminating else { return }
        guard let i = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[i].isInverted.toggle()
        applyToDisplay(displays[i])
        save()
    }

    func restoreAllDisplays() {
        stopRuntimeUpdates()
        shutdownCompletion = nil
        shutdownOutput = nil
        shutdownDisplayAmounts.removeAll()
        cancelOutputTransition()
        cancelAllDisplayTransitions()
        gamma.restoreAll()
    }

    /// Fade every currently rendered monitor back to its calibrated ColorSync state without
    /// changing the persisted checkboxes. Normal app termination waits for this completion.
    func beginTerminationFade(completion: @escaping () -> Void) {
        guard !isTerminating else { return }

        // A band-marker drag saves on a 250 ms trailing edge. Drain it before shutdown so
        // quitting immediately after a drag cannot discard the final bounds.
        flushBandRefresh()

        // Freeze the cached values that produced the last gamma write. Do not analytically
        // catch transitions up here: after a delayed run loop that would jump to a frame the
        // user never saw before beginning the fade-out.
        let rendered = currentRenderedOutput()
        let currentAmounts = Dictionary(uniqueKeysWithValues: displays.map { display in
            (display.id, displayTransitions[display.id]?.currentAmount
                ?? (display.isEnabled ? 1 : 0))
        })

        stopRuntimeUpdates()
        previewIntensityValue = nil
        previewWhitepointValue = nil
        cancelOutputTransition()
        cancelAllDisplayTransitions()

        shutdownOutput = rendered
        shutdownCompletion = completion
        isTerminating = true
        let hasTint = rendered.intensity < 0.999_999 || rendered.whitepoint < 0.999_999
        let startedAt = transitionUptime()

        for display in displays {
            let amount = clamp(currentAmounts[display.id] ?? 0, to: 0...1)
            shutdownDisplayAmounts[display.id] = amount
            guard displayTransitionDuration > 0, hasTint, amount > 0 else {
                shutdownDisplayAmounts[display.id] = 0
                continue
            }
            displayTransitions[display.id] = DisplayTransition(
                fromAmount: amount,
                toAmount: 0,
                currentAmount: amount,
                startedAt: startedAt)
            fadingDisplayIDs.insert(display.id)
        }

        // Re-render the frozen frame once after replacing any in-flight transitions. It is
        // mathematically identical to the prior frame, so quit begins without a jump.
        applyToActiveDisplays()
        if displayTransitions.isEmpty {
            finishTerminationIfReady()
        } else {
            startTransitionTimerIfNeeded()
        }
    }

    private func stopRuntimeUpdates() {
        adaptiveTimer?.invalidate()
        adaptiveTimer = nil
        bandRefreshTimer?.invalidate()
        bandRefreshTimer = nil
        pendingBandRefreshChannels.removeAll()
        location.onChange = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    // MARK: - Presets

    func applyPreset(_ index: Int) {
        guard presets.indices.contains(index) else { return }
        let rendered = currentRenderedOutput()
        let shouldFade = adaptiveEnabled
        cancelOutputTransition()
        if shouldFade {
            setInternal { adaptiveEnabled = false }   // didSet skipped; cleanup + single save below
            animateNextAdaptiveTarget = false
            stopAdaptiveTracking()
        }
        let preset = presets[index]
        setInternal {
            intensity = preset.intensity
            whitepoint = preset.whitepoint
        }
        activePresetIndex = index
        if shouldFade {
            startOutputTransition(
                from: rendered,
                to: OutputPair(intensity: preset.intensity, whitepoint: preset.whitepoint))
        } else {
            applyToActiveDisplays()
        }
        save()
    }

    func saveToPreset(_ index: Int) {
        guard presets.indices.contains(index) else { return }
        let desiredIntensity = intensity
        let desiredWhitepoint = whitepoint
        presets[index].intensity = desiredIntensity
        presets[index].whitepoint = desiredWhitepoint
        if adaptiveEnabled {
            // Bake the live values into the preset, then rebase the manual offsets against
            // the newly shaped curve. Reusing the old offsets would apply the same nudge a
            // second time and make the display jump immediately after Save.
            if let coord = location.coordinate {
                let date = now()
                let elev = SolarCalculator.elevation(
                    at: date, latitude: coord.latitude, longitude: coord.longitude)
                let minElev = SolarCalculator.elevationAtSolarMidnight(
                    at: date, latitude: coord.latitude, longitude: coord.longitude)
                let curve = AdaptiveMapping.banded(
                    elevation: elev, minElevation: minElev, presets: presets,
                    intensityMin: adaptiveMin, intensityMax: adaptiveMax,
                    whitepointMin: adaptiveWpMin, whitepointMax: adaptiveWpMax
                )
                adaptiveIntensityOffset = desiredIntensity - curve.intensity
                adaptiveWhitepointOffset = desiredWhitepoint - curve.whitepoint
            }
            applyAdaptive()
        } else {
            activePresetIndex = index
        }
        save()
    }

    // MARK: - System Events

    private func startListening() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWake()
            }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
    }

    /// Reapply gamma after wake and force a fresh one-shot location request: the laptop may
    /// have traveled while asleep. ColorSync-restore first so a GPU LUT reset during sleep
    /// cannot be snapshotted as the "original" calibration. Kept internal so the
    /// no-double-apply behavior is testable.
    func handleWake() {
        synchronizeTransitionState(at: transitionUptime())
        if !isTerminating { gamma.restoreAll() }
        guard adaptiveEnabled else { applyToActiveDisplays(); return }
        requestLocationIfNeeded(at: now(), force: true)
        if location.coordinate == nil { applyToActiveDisplays() }
        applyAdaptive()
    }

    // MARK: - Output transition

    private func currentRenderedOutput() -> OutputPair {
        if let shutdownOutput { return shutdownOutput }
        return OutputPair(
            intensity: previewIntensityValue ?? transitionIntensityValue ?? intensity,
            whitepoint: previewWhitepointValue ?? transitionWhitepointValue ?? whitepoint)
    }

    private func cancelOutputTransition() {
        outputTransition = nil
        transitionIntensityValue = nil
        transitionWhitepointValue = nil
        stopTransitionTimerIfIdle()
    }

    /// Stop only the channel the user took over. The other channel keeps its current rendered
    /// value and completes its fade instead of snapping straight to the destination.
    private func cancelOutputTransition(_ channel: OutputChannel) {
        switch channel {
        case .intensity: transitionIntensityValue = nil
        case .whitepoint: transitionWhitepointValue = nil
        }
        guard var transition = outputTransition else { return }
        transition.channels.remove(channel)
        guard !transition.channels.isEmpty else {
            outputTransition = nil
            stopTransitionTimerIfIdle()
            return
        }
        outputTransition = transition
    }

    private func startOutputTransition(
        from: OutputPair,
        to: OutputPair,
        channels requestedChannels: Set<OutputChannel> = [.intensity, .whitepoint]
    ) {
        cancelOutputTransition()
        let channels = requestedChannels.filter { channel in
            switch channel {
            case .intensity: from.intensity != to.intensity
            case .whitepoint: from.whitepoint != to.whitepoint
            }
        }
        guard adaptiveTransitionDuration > 0, !channels.isEmpty else {
            applyToActiveDisplays()
            return
        }

        outputTransition = OutputTransition(
            from: from, to: to, startedAt: transitionUptime(), channels: channels)
        if channels.contains(.intensity) { transitionIntensityValue = from.intensity }
        if channels.contains(.whitepoint) { transitionWhitepointValue = from.whitepoint }
        applyToActiveDisplays()
        startTransitionTimerIfNeeded()
    }

    func tickOutputTransition() {
        guard let transition = outputTransition else { return }
        let elapsed = max(0, transitionUptime() - transition.startedAt)
        advanceOutputTransition(toProgress: elapsed / adaptiveTransitionDuration)
    }

    /// Deterministic test hook and the single implementation used by the timer. Smoothstep
    /// gives zero velocity at both ends, avoiding a perceptible kick on either toggle edge.
    func advanceOutputTransition(toProgress rawProgress: Double) {
        guard updateOutputTransition(toProgress: rawProgress) else { return }
        applyToActiveDisplays()
        stopTransitionTimerIfIdle()
    }

    /// Update only transient output state. The shared production ticker applies gamma after
    /// every active transition has advanced, so overlapping fades render one coherent frame.
    @discardableResult
    private func updateOutputTransition(toProgress rawProgress: Double) -> Bool {
        guard let transition = outputTransition else { return false }
        let progress = min(1, max(0, rawProgress))
        let eased = Self.smoothstep(progress)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * eased }
        // Intermediates obey only the sliders' global domains. The saved manual value may
        // legitimately sit outside the narrower Adaptive band.
        if transition.channels.contains(.intensity) {
            transitionIntensityValue = clamp(
                mix(transition.from.intensity, transition.to.intensity), to: 0...1)
        }
        if transition.channels.contains(.whitepoint) {
            transitionWhitepointValue = clamp(
                mix(transition.from.whitepoint, transition.to.whitepoint), to: 0.25...1)
        }

        if progress >= 1 {
            outputTransition = nil
            transitionIntensityValue = nil
            transitionWhitepointValue = nil
        }
        return true
    }

    func completeOutputTransition() {
        advanceOutputTransition(toProgress: 1)
    }

    // MARK: - Per-display transition

    /// Persisted display checkboxes stay logically enabled across launches, but their gamma
    /// effect starts at neutral and eases back in. All displays share one launch timestamp.
    private func prepareStartupDisplayTransitions() {
        guard displayTransitionDuration > 0 else { return }
        for display in displays where display.isEnabled {
            displayTransitions[display.id] = DisplayTransition(
                fromAmount: 0,
                toAmount: 1,
                currentAmount: 0,
                startedAt: 0)
            fadingDisplayIDs.insert(display.id)
        }
    }

    /// Anchor the launch animation only after Adaptive/location initialization has finished,
    /// guaranteeing the user sees the complete 0.7-second fade even if setup takes time.
    private func startPreparedStartupDisplayTransitions() {
        let timestamp = transitionUptime()
        for (displayID, var transition) in Array(displayTransitions)
            where transition.fromAmount == 0 && transition.toAmount == 1
                && transition.currentAmount == 0
        {
            transition.startedAt = timestamp
            displayTransitions[displayID] = transition
        }
        startTransitionTimerIfNeeded()
    }

    /// A display checkbox controls only how much of the current red/white-point output is
    /// mixed in. This lets its 0.7-second fade compose naturally with Adaptive's independent
    /// two-second movement: amount 0 is the untouched display; amount 1 is the live target.
    private func startDisplayTransition(
        _ displayID: CGDirectDisplayID,
        from rawFrom: Double,
        to rawTo: Double
    ) {
        cancelDisplayTransition(displayID)
        let from = clamp(rawFrom, to: 0...1)
        let to = clamp(rawTo, to: 0...1)
        guard displayTransitionDuration > 0, from != to else {
            if let display = displays.first(where: { $0.id == displayID }) {
                applyToDisplay(display)
            }
            return
        }

        displayTransitions[displayID] = DisplayTransition(
            fromAmount: from,
            toAmount: to,
            currentAmount: from,
            startedAt: transitionUptime())
        fadingDisplayIDs.insert(displayID)
        if let display = displays.first(where: { $0.id == displayID }) {
            applyToDisplay(display)
        }
        startTransitionTimerIfNeeded()
    }

    private func currentDisplayAmount(
        for displayID: CGDirectDisplayID,
        fallback: Double
    ) -> Double {
        guard let transition = displayTransitions[displayID], displayTransitionDuration > 0
        else { return fallback }
        let elapsed = max(0, transitionUptime() - transition.startedAt)
        let progress = min(1, elapsed / displayTransitionDuration)
        let eased = Self.smoothstep(progress)
        return transition.fromAmount
            + (transition.toAmount - transition.fromAmount) * eased
    }

    func tickDisplayTransitions() {
        let changedIDs = updateDisplayTransitions(at: transitionUptime())
        applyDisplayTransitionFrame(changedIDs)
        stopTransitionTimerIfIdle()
        finishTerminationIfReady()
    }

    /// Deterministic test hook. Production uses each display transition's own monotonic start
    /// time; tests can advance every active display to the same normalized point directly.
    func advanceDisplayTransitions(toProgress rawProgress: Double) {
        var changedIDs = Set<CGDirectDisplayID>()
        for (displayID, transition) in Array(displayTransitions) {
            if updateDisplayTransition(
                displayID, transition: transition, toProgress: rawProgress)
            {
                changedIDs.insert(displayID)
            }
        }
        applyDisplayTransitionFrame(changedIDs)
        stopTransitionTimerIfIdle()
        finishTerminationIfReady()
    }

    @discardableResult
    private func updateDisplayTransition(
        _ displayID: CGDirectDisplayID,
        transition: DisplayTransition,
        toProgress rawProgress: Double
    ) -> Bool {
        guard displayTransitions[displayID] != nil else { return false }
        let progress = min(1, max(0, rawProgress))
        let eased = Self.smoothstep(progress)
        var next = transition
        next.currentAmount = transition.fromAmount
            + (transition.toAmount - transition.fromAmount) * eased
        if isTerminating {
            shutdownDisplayAmounts[displayID] = next.currentAmount
        }

        if progress >= 1 {
            displayTransitions.removeValue(forKey: displayID)
            fadingDisplayIDs.remove(displayID)
        } else {
            displayTransitions[displayID] = next
        }
        return true
    }

    private func updateDisplayTransitions(
        at timestamp: TimeInterval
    ) -> Set<CGDirectDisplayID> {
        var changedIDs = Set<CGDirectDisplayID>()
        for (displayID, transition) in Array(displayTransitions) {
            let elapsed = max(0, timestamp - transition.startedAt)
            if updateDisplayTransition(
                displayID,
                transition: transition,
                toProgress: elapsed / displayTransitionDuration)
            {
                changedIDs.insert(displayID)
            }
        }
        return changedIDs
    }

    private func applyDisplayTransitionFrame(_ displayIDs: Set<CGDirectDisplayID>) {
        for display in displays where displayIDs.contains(display.id) {
            applyToDisplay(display)
        }
    }

    func completeDisplayTransitions() {
        advanceDisplayTransitions(toProgress: 1)
    }

    private func cancelDisplayTransition(_ displayID: CGDirectDisplayID) {
        displayTransitions.removeValue(forKey: displayID)
        fadingDisplayIDs.remove(displayID)
        stopTransitionTimerIfIdle()
    }

    private func cancelAllDisplayTransitions() {
        displayTransitions.removeAll()
        fadingDisplayIDs.removeAll()
        stopTransitionTimerIfIdle()
    }

    private func startTransitionTimerIfNeeded() {
        guard transitionTimer == nil,
              outputTransition != nil || !displayTransitions.isEmpty
        else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTransitions() }
        }
        transitionTimer = timer
        // Common mode keeps both fades moving while the menu popover tracks a control.
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Advance every active fade from one monotonic timestamp, then write one gamma frame.
    func tickTransitions() {
        let timestamp = transitionUptime()
        var outputChanged = false
        if let transition = outputTransition {
            let elapsed = max(0, timestamp - transition.startedAt)
            outputChanged = updateOutputTransition(
                toProgress: elapsed / adaptiveTransitionDuration)
        }
        let changedDisplayIDs = updateDisplayTransitions(at: timestamp)

        if outputChanged {
            applyToActiveDisplays()
        } else {
            applyDisplayTransitionFrame(changedDisplayIDs)
        }
        stopTransitionTimerIfIdle()
        finishTerminationIfReady()
    }

    /// Catch state up before an out-of-band render such as wake or display reconfiguration.
    /// A delayed run loop can otherwise replay the last cached partial frame once.
    private func synchronizeTransitionState(at timestamp: TimeInterval) {
        if let transition = outputTransition {
            let elapsed = max(0, timestamp - transition.startedAt)
            updateOutputTransition(toProgress: elapsed / adaptiveTransitionDuration)
        }
        _ = updateDisplayTransitions(at: timestamp)
        stopTransitionTimerIfIdle()
    }

    private func stopTransitionTimerIfIdle() {
        guard outputTransition == nil, displayTransitions.isEmpty else { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
    }

    private func finishTerminationIfReady() {
        guard isTerminating, displayTransitions.isEmpty,
              let completion = shutdownCompletion
        else { return }
        shutdownCompletion = nil
        transitionTimer?.invalidate()
        transitionTimer = nil
        gamma.restoreAll()
        completion()
    }

    private static func smoothstep(_ progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return p * p * (3 - 2 * p)
    }

    // MARK: - Apply

    private func applyToActiveDisplays() {
        for display in displays { applyToDisplay(display) }
    }

    private func applyToDisplay(_ display: DisplayInfo) {
        let rendered = currentRenderedOutput()
        let amount = shutdownDisplayAmounts[display.id]
            ?? displayTransitions[display.id]?.currentAmount
            ?? (display.isEnabled ? 1 : 0)
        let i = Float(1 + (rendered.intensity - 1) * amount)
        let w = Float(1 + (rendered.whitepoint - 1) * amount)
        if !display.isInverted && i == 1 && w == 1 {
            // A neutral enabled filter must leave the ColorSync calibration untouched.
            gamma.restore(display.id)
        } else {
            gamma.applyFilter(to: display.id, intensity: i, whitepoint: w,
                              invert: display.isInverted)
        }
    }

    // MARK: - Band marker live preview

    /// Temporarily drive the live filter to `v` (a dragged intensity-band marker) without
    /// touching stored state, so the user sees that intensity in real time.
    func previewIntensity(_ v: Double) {
        cancelOutputTransition(.intensity)
        previewIntensityValue = min(1, max(0, v))
        applyToActiveDisplays()
    }

    func previewWhitepoint(_ v: Double) {
        cancelOutputTransition(.whitepoint)
        previewWhitepointValue = min(1, max(0.25, v))
        applyToActiveDisplays()
    }

    /// End any marker preview: flush the coalesced band work so the adaptive value lands
    /// in the (possibly moved) band immediately, then revert the filter to it.
    func endPreview() {
        previewIntensityValue = nil
        previewWhitepointValue = nil
        flushBandRefresh()
        applyToActiveDisplays()
    }

    // MARK: - Band change coalescing

    /// A marker drag writes `adaptiveMin/Max` dozens of times per second; recomputing the
    /// solar curve and rewriting UserDefaults on each tick is wasteful, and the marker's
    /// `previewIntensity` already drives the visible filter during the drag. Coalesce to
    /// a trailing edge; `endPreview()` (drag release) flushes immediately.
    private func scheduleBandRefresh(_ channel: OutputChannel) {
        pendingBandRefreshChannels.insert(channel)
        bandRefreshTimer?.invalidate()
        bandRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushBandRefresh() }
        }
    }

    /// Apply any pending band change now: re-clamp the adaptive value into the new band
    /// and persist. Also a test hook for deterministic assertions around the coalescing.
    func flushBandRefresh() {
        guard bandRefreshTimer != nil else { return }
        bandRefreshTimer?.invalidate()
        bandRefreshTimer = nil
        let changedChannels = pendingBandRefreshChannels
        pendingBandRefreshChannels.removeAll()
        if adaptiveEnabled {
            if location.coordinate == nil {
                // There is no solar baseline to recalculate yet, but a hard limit still has
                // to take effect immediately. Preserve a pending manual nudge, clamped into
                // the new band, so it lands at that same bounded value once location resolves.
                for channel in changedChannels {
                    cancelOutputTransition(channel)
                    switch channel {
                    case .intensity:
                        if let pendingAdaptiveIntensity {
                            self.pendingAdaptiveIntensity = clamp(
                                pendingAdaptiveIntensity, to: intensityBand)
                        }
                        setInternal { intensity = clamp(intensity, to: intensityBand) }
                    case .whitepoint:
                        if let pendingAdaptiveWhitepoint {
                            self.pendingAdaptiveWhitepoint = clamp(
                                pendingAdaptiveWhitepoint, to: whitepointBand)
                        }
                        setInternal { whitepoint = clamp(whitepoint, to: whitepointBand) }
                    }
                }
                applyToActiveDisplays()
            } else {
                applyAdaptive()
            }
        }
        save()
    }

    // MARK: - Persistence

    private func save() {
        defaults.set(intensity, forKey: "redlight.intensity")
        defaults.set(whitepoint, forKey: "redlight.whitepoint")
        for display in displays {
            let prefix = displayDefaultsPrefix(display.persistenceKey)
            defaults.set(display.isEnabled, forKey: "\(prefix).enabled")
            defaults.set(display.isInverted, forKey: "\(prefix).inverted")
        }
        if lastSavedPresets != presets, let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: "redlight.presets")
            lastSavedPresets = presets
        }
        defaults.set(activePresetIndex ?? -1, forKey: "redlight.activePresetIndex")
        defaults.set(adaptiveEnabled, forKey: "redlight.adaptiveEnabled")
        defaults.set(adaptiveIntensityOffset, forKey: "redlight.adaptiveOffsetIntensity")
        defaults.set(adaptiveWhitepointOffset, forKey: "redlight.adaptiveOffsetWhitepoint")
        if let pendingAdaptiveIntensity {
            defaults.set(pendingAdaptiveIntensity, forKey: "redlight.pendingAdaptiveIntensity")
        } else {
            defaults.removeObject(forKey: "redlight.pendingAdaptiveIntensity")
        }
        if let pendingAdaptiveWhitepoint {
            defaults.set(pendingAdaptiveWhitepoint, forKey: "redlight.pendingAdaptiveWhitepoint")
        } else {
            defaults.removeObject(forKey: "redlight.pendingAdaptiveWhitepoint")
        }
        defaults.set(adaptiveMin, forKey: "redlight.adaptiveMin")
        defaults.set(adaptiveMax, forKey: "redlight.adaptiveMax")
        defaults.set(adaptiveWpMin, forKey: "redlight.adaptiveWpMin")
        defaults.set(adaptiveWpMax, forKey: "redlight.adaptiveWpMax")
    }

    private func loadPresets() {
        if let data = defaults.data(forKey: "redlight.presets"),
           let saved = try? JSONDecoder().decode([Preset].self, from: data),
           saved.count == 5 {
            presets = saved
            lastSavedPresets = saved
        }
        if defaults.object(forKey: "redlight.activePresetIndex") != nil {
            let idx = defaults.integer(forKey: "redlight.activePresetIndex")
            activePresetIndex = idx >= 0 && idx < 5 ? idx : nil
        }
    }

    private func displayDefaultsPrefix(_ persistenceKey: String) -> String {
        "redlight.display.\(persistenceKey)"
    }

    /// Migrate the old transient-CGDisplayID key on first read. CoreGraphics IDs can change
    /// across reboot; the ColorSync UUID remains tied to the physical display.
    private func persistedDisplayFlag(
        _ id: CGDirectDisplayID, persistenceKey: String, suffix: String
    ) -> Bool {
        let stableKey = "\(displayDefaultsPrefix(persistenceKey)).\(suffix)"
        if defaults.object(forKey: stableKey) != nil { return defaults.bool(forKey: stableKey) }

        let legacyKey = "redlight.display.\(id).\(suffix)"
        guard defaults.object(forKey: legacyKey) != nil else { return false }
        let value = defaults.bool(forKey: legacyKey)
        defaults.set(value, forKey: stableKey)
        return value
    }

    // MARK: - System Helpers

    nonisolated static func systemDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids
    }

    nonisolated static func systemDisplayName(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenID == id {
                return screen.localizedName
            }
        }
        return "Display \(id)"
    }

    nonisolated static func systemDisplayPersistenceKey(for id: CGDirectDisplayID) -> String {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return String(id) }
        let uuid = unmanaged.takeRetainedValue()
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }
}
