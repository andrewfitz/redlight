import AppKit
import ColorSync
import Observation

@MainActor
@Observable
final class DisplayManager {
    struct DisplayInfo: Identifiable {
        let id: CGDirectDisplayID
        /// Stable ColorSync-UUID key used for UserDefaults; resolved when refreshing the display list.
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

    /// The next named solar event for one coordinate, as an absolute date so the countdown
    /// can tick without rescanning. A nil event means the scan found nothing ahead.
    private struct SolarEventCache {
        var latitude: Double
        var longitude: Double
        var scannedAt: Date
        var event: (label: String, date: Date)?
        var validUntil: Date
    }

    private struct PauseTransition {
        var from: Double
        var to: Double
        var startedAt: TimeInterval
        var duration: TimeInterval
    }

    /// Factory settings. Single source of truth for both first launch and the reset buttons,
    /// so the two can't drift apart.
    ///
    /// Default means *no filter at all*, not "a bit of filter": `intensity` 1.0 is an
    /// untouched display (0.0 is pure red), and `whitepoint` 1.0 is no white-point reduction.
    /// Intensity defaults to its full range. White Point starts at the Late preset's
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
        static let peekFadeDuration: TimeInterval = 0.15
        static let pauseDuration: TimeInterval = 30 * 60
        static let pauseLengthRange: ClosedRange<TimeInterval> = 60...86_400
    }

    private(set) var displays: [DisplayInfo] = []
    var intensity: Double = 0.5 {
        didSet {
            // Internal (adaptive/preset) writes apply + save once at their call site.
            guard isInitialized, !internalUpdate else { return }
            cancelOutputTransition(.intensity)
            if adaptiveEnabled, isIntensityPinned {
                // A pinned band is a fixed value, so a manual change moves the pin. It
                // replaces any earlier nudge, which would otherwise return on un-pinning.
                let pin = clamp(intensity, to: 0...1)
                setInternal {
                    adaptiveMin = pin
                    adaptiveMax = pin
                    if intensity != pin { intensity = pin }
                }
                adaptiveIntensityOffset = 0
                pendingAdaptiveIntensity = nil
            } else if adaptiveEnabled {
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
            if adaptiveEnabled, isWhitepointPinned {
                let pin = clamp(whitepoint, to: 0.25...1)
                setInternal {
                    adaptiveWpMin = pin
                    adaptiveWpMax = pin
                    if whitepoint != pin { whitepoint = pin }
                }
                adaptiveWhitepointOffset = 0
                pendingAdaptiveWhitepoint = nil
            } else if adaptiveEnabled {
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
        !fadingDisplayIDs.isEmpty || isPauseFading
            || displays.contains { ($0.isEnabled && !isPaused && suspendedForApp == nil) || $0.isInverted }
    }

    /// Logical master state follows connected filter checkboxes, independently of inversion.
    var isOn: Bool { displays.contains { $0.isEnabled } }
    /// A pause keeps the checkboxes but shows no tint, so commands and Control Center see off.
    var isFiltering: Bool { isOn && !isPaused }
    var commandIsFading: Bool {
        outputTransition != nil || !fadingDisplayIDs.isEmpty || pauseTransition != nil
    }
    /// Commands report endpoints; the render clock and marker previews are transient frames.
    var commandTargetOutput: OutputPair {
        OutputPair(intensity: intensity, whitepoint: whitepoint)
    }
    var commandElevation: Double? {
        guard let coordinate = location.coordinate else { return nil }
        return SolarCalculator.elevation(
            at: now(), latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private(set) var sliderInteractionGeneration: UInt64 = 0

    @discardableResult
    func beginSliderInteraction() -> UInt64 {
        // A superseded gesture can no longer run its release callback. Finish its preview here.
        interruptSliderInteraction()
        return sliderInteractionGeneration
    }

    func isSliderInteractionCurrent(_ token: UInt64) -> Bool {
        !isTerminating && token == sliderInteractionGeneration
    }

    func interruptSliderInteraction() {
        guard !isTerminating else { return }
        sliderInteractionGeneration &+= 1
        endPreview()
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
                solarEventCache = nil
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
    private(set) var nextSolarEventText: String?
    /// Last known location, set while adaptive resolves it — drives the sun-arc graphic.
    private(set) var coordinate: (latitude: Double, longitude: Double)?
    /// The provider's manual coordinate, mirrored so the popover can observe it.
    private(set) var manualLocation: (latitude: Double, longitude: Double)?
    var isLocationApproximate: Bool { location.isApproximate }
    var hasLocation: Bool { location.coordinate != nil }
    /// The coordinate the provider holds now: the user's, a fix, or the time-zone city.
    /// `coordinate` is only kept current while Adaptive runs; this one is read on demand.
    var currentCoordinate: (latitude: Double, longitude: Double)? { location.coordinate }

    /// Where the coordinate Adaptive follows comes from.
    enum LocationSource: Equatable, Sendable {
        /// A Core Location fix, or no coordinate yet.
        case automatic
        /// The time-zone city, because there has never been a fix.
        case timeZone
        /// The last fix, kept after Location Services was turned off.
        case lastKnown
        /// Coordinates the user entered.
        case manual
    }

    /// In the same order as the suffix of `adaptiveStatusText`.
    var locationSource: LocationSource {
        // The provider is not observable. A change of source reaches a view through these
        // two, which Adaptive rewrites when the provider reports one.
        _ = manualLocation
        _ = adaptiveStatusText
        if location.manualCoordinate != nil { return .manual }
        guard location.coordinate != nil else { return .automatic }
        if location.isApproximate { return .timeZone }
        return location.authorization == .denied ? .lastKnown : .automatic
    }

    /// The band as hard limits, lo/hi order normalized.
    var intensityBand: ClosedRange<Double> {
        min(adaptiveMin, adaptiveMax)...max(adaptiveMin, adaptiveMax)
    }
    var whitepointBand: ClosedRange<Double> {
        min(adaptiveWpMin, adaptiveWpMax)...max(adaptiveWpMin, adaptiveWpMax)
    }
    /// Equal limits pin a channel to one value: adaptive leaves it alone, and a manual
    /// change moves the pin instead of nudging against the curve.
    var isIntensityPinned: Bool { adaptiveMin == adaptiveMax }
    var isWhitepointPinned: Bool { adaptiveWpMin == adaptiveWpMax }

    var adaptiveIntensityAdjustment: Double { adaptiveIntensityOffset }

    /// "Deepest by": Adaptive reaches the deepest end of its band by this local time. Nil is off.
    private(set) var bedtime: Bedtime?

    /// The bedtime, when it will change the curve on the evening that is running or comes
    /// next. `BedtimeRamp` ignores one that falls after solar midnight or less than one ramp
    /// after solar noon, and nothing can follow the sun without a coordinate.
    var effectiveBedtime: Bedtime? {
        guard let bedtime, let coordinate = location.coordinate else { return nil }
        let solarMidnight = SolarCalculator.nextSolarMidnight(after: now(), longitude: coordinate.longitude)
        // A bedtime the ramp accepts has started by the last second of its evening.
        let last = BedtimeRamp.weights(at: solarMidnight.addingTimeInterval(-1), bedtime: bedtime,
                                       solarMidnight: solarMidnight, calendar: calendar)
        return last.progress > 0 ? bedtime : nil
    }

    /// Set or clear the bedtime. An active curve fades to the new target over the usual
    /// Adaptive fade; the 5 s tick then advances the ramp, so no timer of its own is needed.
    func setBedtime(_ bedtime: Bedtime?) {
        guard !isTerminating, bedtime != self.bedtime else { return }
        self.bedtime = bedtime
        if adaptiveEnabled {
            animateNextAdaptiveTarget = true
            applyAdaptive()
        }
        save()
    }

    /// Applied sample used by the sun arc. Keeping the offset and hard-band clamp here makes
    /// the graphic follow the exact same adjusted curve as the real display. Pass the sample's
    /// time to include the bedtime floor.
    func adaptiveIntensity(
        at elevation: Double, minElevation: Double, rising: Bool = false,
        time: (date: Date, longitude: Double)? = nil
    ) -> Double {
        let curve = adaptiveCurve(
            elevation: elevation, minElevation: minElevation, rising: rising, time: time)
        return clamp(curve.intensity + adaptiveIntensityOffset, to: intensityBand)
    }

    /// The one banded curve, bedtime floor included, behind the live target, the sun arc and
    /// the Save to Preset rebase.
    private func adaptiveCurve(
        elevation: Double, minElevation: Double, rising: Bool, time: (date: Date, longitude: Double)?
    ) -> AdaptiveMapping.Target {
        let weights = time.map {
            BedtimeRamp.weights(at: $0.date, bedtime: bedtime, longitude: $0.longitude, calendar: calendar)
        } ?? .inactive
        return AdaptiveMapping.target(
            elevation: elevation, minElevation: minElevation, rising: rising, presets: presets,
            intensityMin: adaptiveMin, intensityMax: adaptiveMax,
            whitepointMin: adaptiveWpMin, whitepointMax: adaptiveWpMax, bedtime: weights
        )
    }

    func applyAdaptive() {
        applyAdaptive(transitionFrom: nil)
    }

    private func applyAdaptive(transitionFrom explicitStart: OutputPair?) {
        guard adaptiveEnabled, !isTerminating else { return }
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
            // Equal writes still invalidate observers; without a location this runs on
            // every 5 s tick with nothing changed.
            if coordinate != nil { coordinate = nil }
            lastCurveIntensity = nil
            lastCurveWhitepoint = nil
            let status = location.authorization == .denied ? "Location needed" : "Locating…"
            if adaptiveStatusText != status { adaptiveStatusText = status }
            if nextSolarEventText != nil { nextSolarEventText = nil }
            return nil
        }
        if coordinate == nil || coordinate! != coord { coordinate = coord }   // avoid spurious invalidation

        let (elev, rising) = SolarCalculator.position(
            at: date, latitude: coord.latitude, longitude: coord.longitude)
        let minElev = SolarCalculator.elevationAtSolarMidnight(at: date, latitude: coord.latitude, longitude: coord.longitude)
        // Morning and evening curves differ above the horizon. Where the sun stays below the
        // Day anchor at noon (high-latitude winter) the switch is a step, so fade across it.
        if let lastAdaptiveRising, lastAdaptiveRising != rising { animateNextAdaptiveTarget = true }
        lastAdaptiveRising = rising
        let banded = adaptiveCurve(
            elevation: elev, minElevation: minElev, rising: rising,
            time: (date: date, longitude: coord.longitude))

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
        // The floor, not the sun, set the curve (before the manual offset).
        let floored = banded.bedtime ? " · bedtime" : ""
        let adjusted = (adaptiveIntensityOffset != 0 || adaptiveWhitepointOffset != 0)
            ? " · adjusted" : ""
        let source = location.manualCoordinate != nil ? " · manual"
            : location.isApproximate ? " · time zone"
            : location.authorization == .denied ? " · last known" : ""
        let status = "Following the sun · \(elevationText)\(floored)\(adjusted)\(source)"
        if status != adaptiveStatusText { adaptiveStatusText = status }   // avoid 5 s-tick invalidation
        updateNextSolarEvent(at: date, coordinate: coord)
        return target
    }

    /// Keep the popover countdown current from the cached event. The scan behind it is ~720
    /// elevation evaluations, so it reruns only once the event has passed, the coordinate
    /// moves, the clock is set back, or Adaptive turns on (which clears the cache).
    private func updateNextSolarEvent(
        at date: Date, coordinate coord: (latitude: Double, longitude: Double)
    ) {
        let cache: SolarEventCache
        if let cached = solarEventCache, cached.latitude == coord.latitude,
           cached.longitude == coord.longitude, date >= cached.scannedAt, date < cached.validUntil {
            cache = cached
        } else {
            let event = nextSolarEvent(date, coord.latitude, coord.longitude)
                .map { (label: $0.label, date: date.addingTimeInterval($0.seconds)) }
            cache = SolarEventCache(
                latitude: coord.latitude, longitude: coord.longitude, scannedAt: date,
                event: event,
                // Nothing crosses within the scan's 24 h horizon (polar day or night).
                validUntil: event?.date ?? date.addingTimeInterval(86_400))
            solarEventCache = cache
        }
        let text = cache.event.map {
            Self.describeNextSolarEvent($0.label, in: $0.date.timeIntervalSince(date))
        }
        if text != nextSolarEventText { nextSolarEventText = text }   // minute granularity
    }

    /// Popover countdown such as "Sunset in 1 h 12 m". Whole minutes, rounded down; the
    /// final minute reads "under a minute".
    nonisolated static func describeNextSolarEvent(_ label: String, in seconds: TimeInterval) -> String {
        let name = label.prefix(1).uppercased() + label.dropFirst()
        let minutes = seconds.isFinite ? Int(min(max(0, seconds), 7 * 86_400) / 60) : 0
        let duration = switch minutes {
        case 0: "under a minute"
        case ..<60: "\(minutes) m"
        default: hoursText(minutes)
        }
        return "\(name) in \(duration)"
    }

    /// "1 h 12 m" or "2 h". Callers word anything under an hour themselves.
    nonisolated private static func hoursText(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) m"
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
        lastAdaptiveRising = nil
        adaptiveStatusText = ""
        solarEventCache = nil
        if nextSolarEventText != nil { nextSolarEventText = nil }
    }

    /// Follow the user's coordinate, or nil to return to automatic location. The provider
    /// reports the change, so an active curve fades to the new target as for a better fix.
    func setManualLocation(_ coordinate: (latitude: Double, longitude: Double)?) {
        guard !isTerminating else { return }
        // Back to automatic: the curve update the provider triggers asks for a fresh fix
        // now instead of waiting out the hourly retry.
        if coordinate == nil { lastLocationRequest = nil }
        location.setManualCoordinate(coordinate)
        manualLocation = location.manualCoordinate
        if coordinate == nil, adaptiveEnabled, lastLocationRequest == nil {
            requestLocationIfNeeded(at: now(), force: true)
        }
    }

    // MARK: - Reset

    /// Whether a row still has anything to reset. Under adaptive the live value is the
    /// curve's to set, not the user's, so only the band and the manual offset count. With
    /// Adaptive off the offset still counts: it comes back the next time Adaptive is on.
    var intensityIsDefault: Bool {
        guard adaptiveMin == Defaults.intensityMin, adaptiveMax == Defaults.intensityMax,
              adaptiveIntensityOffset == 0, pendingAdaptiveIntensity == nil else { return false }
        return adaptiveEnabled || intensity == Defaults.intensity
    }

    var whitepointIsDefault: Bool {
        guard adaptiveWpMin == Defaults.whitepointMin, adaptiveWpMax == Defaults.whitepointMax,
              adaptiveWhitepointOffset == 0, pendingAdaptiveWhitepoint == nil else { return false }
        return adaptiveEnabled || whitepoint == Defaults.whitepoint
    }

    /// The Auto half of `intensityIsDefault`: the limits and the nudge. Manual does not show
    /// them, and they return with Auto.
    var intensityAutoSettingsAreDefault: Bool {
        adaptiveMin == Defaults.intensityMin && adaptiveMax == Defaults.intensityMax
            && adaptiveIntensityOffset == 0 && pendingAdaptiveIntensity == nil
    }

    var whitepointAutoSettingsAreDefault: Bool {
        adaptiveWpMin == Defaults.whitepointMin && adaptiveWpMax == Defaults.whitepointMax
            && adaptiveWhitepointOffset == 0 && pendingAdaptiveWhitepoint == nil
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
    private let getDisplayIDs: () -> [CGDirectDisplayID]?
    private let getDisplayName: (CGDirectDisplayID) -> String
    private let getDisplayPersistenceKey: (CGDirectDisplayID) -> String
    private let getMainDisplayID: () -> CGDirectDisplayID
    private let defaults: UserDefaults
    @ObservationIgnored private let controlDefaults: UserDefaults
    @ObservationIgnored private var lastPublishedControlState: Bool?
    @ObservationIgnored private let onMasterStateChange: (Bool) -> Void
    @ObservationIgnored private let locationPromptActivation: () -> Void
    @ObservationIgnored private let now: () -> Date
    /// Reads the bedtime as local wall-clock time; autoupdating follows time-zone changes.
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let nextSolarEvent: (Date, Double, Double) -> SunCycle.Event?
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
    @ObservationIgnored nonisolated(unsafe) private var displayWakeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var displayRecoveryTimer: Timer?
    @ObservationIgnored private var displayReconfigurationObserver: DisplayReconfigurationObserver?
    @ObservationIgnored nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var clockObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var pauseTimer: Timer?
    /// Fraction of the tint shown: 1 normally, 0 while paused, peeking or suspended for an app.
    /// Invert is not scaled.
    @ObservationIgnored private var pauseLevel: Double = 1
    @ObservationIgnored private var pauseTransition: PauseTransition?
    @ObservationIgnored private var isPeeking = false
    // Observable only at fade boundaries, like `fadingDisplayIDs`, for the tray icon.
    private var isPauseFading = false
    @ObservationIgnored private var adaptiveIntensityOffset: Double = 0
    @ObservationIgnored private var adaptiveWhitepointOffset: Double = 0
    // An adaptive slider can be moved before a location-backed solar curve exists. Keep that
    // desired value until the curve resolves, then convert it to the usual persistent offset.
    @ObservationIgnored private var pendingAdaptiveIntensity: Double?
    @ObservationIgnored private var pendingAdaptiveWhitepoint: Double?
    // Transient live-preview overrides while a band marker is being dragged.
    @ObservationIgnored private var previewIntensityValue: Double?
    @ObservationIgnored private var previewWhitepointValue: Double?
    // Transient rendered-output overrides used by the Adaptive and preset crossfades.
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
    @ObservationIgnored private var lastAdaptiveRising: Bool?
    @ObservationIgnored private var solarEventCache: SolarEventCache?
    @ObservationIgnored private var hasActivatedForLocationPrompt = false
    // Presets rarely change; skip re-encoding them on every slider-driven save.
    @ObservationIgnored private var lastSavedPresets: [Preset]?
    @ObservationIgnored private var lastSavedValues: [String: AnyHashable?] = [:]
    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored private var internalUpdate = false
    @ObservationIgnored private let adaptiveTransitionDuration: TimeInterval
    @ObservationIgnored private let displayTransitionDuration: TimeInterval
    @ObservationIgnored private let peekTransitionDuration: TimeInterval
    @ObservationIgnored private let transitionUptime: () -> TimeInterval

    init(
        gamma: GammaControlling = DisplayFilterController(),
        getDisplayIDs: @escaping () -> [CGDirectDisplayID]? = { DisplayManager.systemDisplayIDs() },
        getDisplayName: @escaping (CGDirectDisplayID) -> String = { DisplayManager.systemDisplayName(for: $0) },
        getDisplayPersistenceKey: @escaping (CGDirectDisplayID) -> String = {
            DisplayManager.systemDisplayPersistenceKey(for: $0)
        },
        getMainDisplayID: @escaping () -> CGDirectDisplayID = { CGMainDisplayID() },
        defaults: UserDefaults = .standard,
        location: LocationProviding = LocationProvider(),
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .autoupdatingCurrent,
        nextSolarEvent: @escaping (Date, Double, Double) -> SunCycle.Event? = {
            SunCycle.findNextEvent(
                now: $0, latitude: $1, longitude: $2, thresholds: SunCycle.twilightThresholds)
        },
        adaptiveTransitionDuration: TimeInterval = Defaults.adaptiveFadeDuration,
        displayTransitionDuration: TimeInterval = Defaults.displayFadeDuration,
        peekTransitionDuration: TimeInterval = Defaults.peekFadeDuration,
        transitionUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        suspendedForApp: String? = nil,
        locationPromptActivation: @escaping () -> Void = { NSApplication.shared.activate() },
        controlDefaults: UserDefaults? = nil,
        onMasterStateChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.gamma = gamma
        self.getDisplayIDs = getDisplayIDs
        self.getDisplayName = getDisplayName
        self.getDisplayPersistenceKey = getDisplayPersistenceKey
        self.getMainDisplayID = getMainDisplayID
        self.defaults = defaults
        let controlDefaults = controlDefaults ?? defaults
        self.controlDefaults = controlDefaults
        self.lastPublishedControlState = controlDefaults.object(forKey: RedlightControlPreferences.stateKey) as? Bool
        self.onMasterStateChange = onMasterStateChange
        self.locationPromptActivation = locationPromptActivation
        self.location = location
        self.manualLocation = location.manualCoordinate
        self.now = now
        self.calendar = calendar
        self.nextSolarEvent = nextSolarEvent
        self.adaptiveTransitionDuration = max(0, adaptiveTransitionDuration)
        self.displayTransitionDuration = max(0, displayTransitionDuration)
        self.peekTransitionDuration = max(0, peekTransitionDuration)
        self.transitionUptime = transitionUptime
        // Clamp on load: a hand-edited or corrupt plist must not put the thumb off the
        // track or send >1 into the gamma composer. (Bands are normalized below.)
        self.intensity = Self.loadClamped(
            defaults, "redlight.intensity", default: Defaults.intensity, range: 0...1)
        self.whitepoint = Self.loadClamped(
            defaults, "redlight.whitepoint", default: Defaults.whitepoint, range: 0.25...1)
        self.adaptiveEnabled = defaults.bool(forKey: "redlight.adaptiveEnabled")
        // Offsets span at most the full slider range; a NaN would poison every target.
        self.adaptiveIntensityOffset = Self.loadClamped(
            defaults, "redlight.adaptiveOffsetIntensity", default: 0, range: -1...1)
        self.adaptiveWhitepointOffset = Self.loadClamped(
            defaults, "redlight.adaptiveOffsetWhitepoint", default: 0, range: -0.75...0.75)
        self.pendingAdaptiveIntensity = Self.loadOptionalClamped(
            defaults, "redlight.pendingAdaptiveIntensity", range: 0...1)
        self.pendingAdaptiveWhitepoint = Self.loadOptionalClamped(
            defaults, "redlight.pendingAdaptiveWhitepoint", range: 0.25...1)
        self.adaptiveMin = Self.loadClamped(
            defaults, "redlight.adaptiveMin", default: Defaults.intensityMin, range: 0...1)
        self.adaptiveMax = Self.loadClamped(
            defaults, "redlight.adaptiveMax", default: Defaults.intensityMax, range: 0...1)
        self.adaptiveWpMin = Self.loadClamped(
            defaults, "redlight.adaptiveWpMin", default: Defaults.whitepointMin, range: 0.25...1)
        self.adaptiveWpMax = Self.loadClamped(
            defaults, "redlight.adaptiveWpMax", default: Defaults.whitepointMax, range: 0.25...1)
        if adaptiveMin > adaptiveMax { swap(&adaptiveMin, &adaptiveMax) }
        if adaptiveWpMin > adaptiveWpMax { swap(&adaptiveWpMin, &adaptiveWpMax) }
        // Minutes after midnight; anything else (wrong type, out of range) reads as off.
        self.bedtime = (defaults.object(forKey: "redlight.adaptiveBedtime") as? Int)
            .flatMap { Bedtime(minuteOfDay: $0) }
        loadPresets()
        if adaptiveEnabled { activePresetIndex = nil }
        refreshDisplays(apply: false)
        loadPause()
        // The app in front at launch is known before the first frame, so a chosen one starts
        // hidden like a saved pause instead of fading in and straight back out.
        if let suspendedForApp {
            self.suspendedForApp = suspendedForApp
            pauseLevel = 0
        }
        startListening()
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
        // Subscribe only after the launch target is on screen. Core Location can hand back
        // its last known fix from inside the request above; fading to it would start from
        // the persisted pair, which may be hours old, during the launch fade-in. The
        // target just applied already used that fix.
        location.onChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.adaptiveEnabled else { return }
                // A better fix (time-zone city → precise, or a move while asleep) can
                // shift the target several degrees. Fade there rather than step.
                self.animateNextAdaptiveTarget = true
                self.applyAdaptive()
            }
        }
        startPreparedStartupDisplayTransitions()
        schedulePauseTimer()
        publishMasterState()
    }

    deinit {
        adaptiveTimer?.invalidate()
        bandRefreshTimer?.invalidate()
        transitionTimer?.invalidate()
        pauseTimer?.invalidate()
        displayRecoveryTimer?.invalidate()
        if let displayWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayWakeObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
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

    private static func loadOptionalClamped(
        _ defaults: UserDefaults, _ key: String, range: ClosedRange<Double>
    ) -> Double? {
        guard let value = defaults.object(forKey: key) as? Double, value.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    /// Refresh the one-shot kilometer-accuracy location occasionally while Adaptive stays
    /// enabled. This keeps a traveling Mac on the right solar cycle without continuous GPS.
    private func requestLocationIfNeeded(at date: Date, force: Bool = false) {
        // A manual coordinate needs neither a fix nor the permission prompt.
        guard location.manualCoordinate == nil, location.authorization != .denied else { return }
        let elapsed = lastLocationRequest.map { date.timeIntervalSince($0) }
        // Hourly even without a precise fix: a Mac that cannot get one (ethernet-only
        // desktop) would otherwise wake the location hardware every minute, forever.
        // Launch, wake and turning Adaptive on still ask immediately.
        let refreshInterval: TimeInterval = 3_600
        if !force, let elapsed, elapsed >= 0, elapsed < refreshInterval { return }
        lastLocationRequest = date
        // Allow the launch context to decide whether surfacing the permission dialog should
        // activate the app. Background command launches inject a no-op. Invoke once so the
        // retry loop never repeatedly interrupts the user while consent remains unanswered.
        if location.authorization == .notDetermined, !hasActivatedForLocationPrompt {
            hasActivatedForLocationPrompt = true
            locationPromptActivation()
        }
        location.requestWhenInUse()
    }

    // MARK: - Displays

    func refreshDisplays() {
        refreshDisplays(apply: true)
    }

    private func refreshDisplays(apply: Bool, resetCalibration: Bool = false) {
        // A failed WindowServer query gives no evidence that a display disconnected.
        guard let discoveredIDs = getDisplayIDs() else { return }
        if resetCalibration { gamma.resetForDisplayRecovery() }
        // Invalidate cached routing and compositor surfaces even when IDs remain
        // unchanged (for example, a resolution or backing-scale change).
        if apply { gamma.displaysDidChange() }
        // Dedupe defensively — a duplicate ID from the system would otherwise both trap
        // the uniquing dictionary and confuse SwiftUI's Identifiable ForEach.
        var names: [CGDirectDisplayID: String] = [:]
        let ids = discoveredIDs.filter { id in
            guard names[id] == nil else { return false }
            let name = getDisplayName(id)
            names[id] = name
            return !name.localizedCaseInsensitiveContains("backstage")
        }
        let currentIDs = Set(ids)
        let previous = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let keys = Dictionary(uniqueKeysWithValues: ids.map { id in
            let key = getDisplayPersistenceKey(id)
            // A temporary UUID lookup failure is not evidence of a monitor swap.
            return (id, key == String(id) ? previous[id]?.persistenceKey ?? key : key)
        })
        let replaced = Set(ids.filter { id in
            previous[id].map { $0.persistenceKey != keys[id] } ?? false
        })
        // Screen-parameter notifications also include harmless desktop changes. Hardware
        // mode changes and display-only wake have their own recovery triggers below.
        let topologyChanged = Set(previous.keys) != currentIDs || !replaced.isEmpty
        if topologyChanged, !resetCalibration {
            if apply, !isTerminating {
                gamma.resetForDisplayRecovery()
                scheduleDisplayRecovery()
            } else {
                // Release a disconnected display during shutdown without resetting others mid-fade.
                for display in displays where !currentIDs.contains(display.id)
                    && (display.isEnabled || display.isInverted || displayTransitions[display.id] != nil)
                {
                    gamma.restore(display.id)
                }
            }
        }
        if isTerminating, topologyChanged {
            shutdownDisplayAmounts = shutdownDisplayAmounts.filter { currentIDs.contains($0.key) && !replaced.contains($0.key) }
        }
        for id in Array(displayTransitions.keys) where !currentIDs.contains(id) || replaced.contains(id) {
            cancelDisplayTransition(id)
        }
        if topologyChanged {
            displays = ids.map { id in
                let key = keys[id]!
                let retained = replaced.contains(id) ? nil : previous[id]
                let enabled = retained?.isEnabled
                    ?? persistedDisplayFlag(id, persistenceKey: key, suffix: "enabled")
                let inverted = retained?.isInverted
                    ?? persistedDisplayFlag(id, persistenceKey: key, suffix: "inverted")
                return DisplayInfo(
                    id: id, persistenceKey: key, name: names[id]!,
                    isEnabled: enabled, isInverted: inverted)
            }
        } else {
            // Same displays: refresh names in place (a monitor can be renamed in System
            // Settings) without replacing the array and invalidating every row's identity.
            for i in displays.indices {
                let name = names[displays[i].id]!
                if displays[i].name != name { displays[i].name = name }
            }
        }
        if apply {
            synchronizeTransitionState(at: transitionUptime())
            // A resolution or refresh-rate change can reset the LUT without changing display IDs.
            applyToActiveDisplays()
        }
        finishTerminationIfReady()
        if isInitialized { publishMasterState() }
    }

    func toggle(_ displayID: CGDirectDisplayID) {
        guard !isTerminating else { return }
        guard let i = displays.firstIndex(where: { $0.id == displayID }) else { return }
        setEnabled(!displays[i].isEnabled, for: displayID)
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) {
        guard !isTerminating,
              let i = displays.firstIndex(where: { $0.id == displayID }),
              displays[i].isEnabled != enabled else { return }
        let wasEnabled = displays[i].isEnabled
        // Reverse from the frame on screen, not a wall-clock projection: after a stalled run
        // loop the projection is ahead of what the user saw and the fade would jump.
        let fromAmount = displayTransitions[displayID]?.currentAmount ?? (wasEnabled ? 1 : 0)
        displays[i].isEnabled = enabled
        startDisplayTransition(
            displayID,
            from: fromAmount,
            to: displays[i].isEnabled ? 1 : 0)
        if !isOn { endPauseIntoFadeOut() }
        save()
    }

    func toggleInvert(_ displayID: CGDirectDisplayID) {
        guard !isTerminating else { return }
        guard let i = displays.firstIndex(where: { $0.id == displayID }) else { return }
        setInverted(!displays[i].isInverted, for: displayID)
    }

    func setInverted(_ inverted: Bool, for displayID: CGDirectDisplayID) {
        guard !isTerminating,
              let i = displays.firstIndex(where: { $0.id == displayID }),
              displays[i].isInverted != inverted else { return }
        displays[i].isInverted = inverted
        applyToDisplay(displays[i])
        save()
    }

    func setAll(on: Bool) {
        guard !isTerminating else { return }
        if on {
            if isPaused {
                resume()
                // A pause can outlive its displays (the only enabled monitor was
                // unplugged). Resuming alone would leave Redlight off, so carry on.
                if isOn { return }
            }
            guard !isOn else { return }
            let remembered = Set(defaults.stringArray(forKey: "redlight.masterEnabledDisplays") ?? [])
            let restored = displays.filter { remembered.contains($0.persistenceKey) }.map(\.id)
            let fallback = displays.first { $0.id == getMainDisplayID() } ?? displays.first
            let targets = restored.isEmpty ? fallback.map { [$0.id] } ?? [] : restored
            for id in targets { setEnabled(true, for: id) }
        } else {
            if isOn {
                persist(displays.filter(\.isEnabled).map(\.persistenceKey), "redlight.masterEnabledDisplays")
            }
            // Clear every stable and legacy enabled flag, including disconnected monitors.
            // Use persist so its write cache cannot later restore an obsolete true value.
            for key in defaults.dictionaryRepresentation().keys
                where key.hasPrefix("redlight.display.") && key.hasSuffix(".enabled") {
                persist(false, key)
            }
            for id in displays.map(\.id) { setEnabled(false, for: id) }
            if isPaused || isPeeking { endPauseIntoFadeOut() }
        }
        save()
    }

    func publishMasterState() {
        guard !isTerminating else { return }
        publishMasterState(isFiltering)
    }

    /// Called after restoring gamma on quit; saved checkbox flags remain available at launch.
    func publishStoppedState() {
        publishMasterState(false)
    }

    private func publishMasterState(_ value: Bool) {
        // The display owner is the sole writer. Slider saves need no preference reads.
        guard lastPublishedControlState != value else { return }
        controlDefaults.set(value, forKey: RedlightControlPreferences.stateKey)
        guard controlDefaults.synchronize() else {
            lastPublishedControlState = nil
            return
        }
        lastPublishedControlState = value
        onMasterStateChange(value)
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
        // Freeze a pause fade where it is; the saved pause still applies at next launch.
        pauseTransition = nil
        isPauseFading = false

        shutdownOutput = rendered
        shutdownCompletion = completion
        isTerminating = true
        sliderInteractionGeneration &+= 1
        let hasTint = pauseLevel > 0
            && (rendered.intensity < 0.999_999 || rendered.whitepoint < 0.999_999)
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
        displayRecoveryTimer?.invalidate()
        displayRecoveryTimer = nil
        displayReconfigurationObserver = nil
        if let displayWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayWakeObserver)
            self.displayWakeObserver = nil
        }
        adaptiveTimer?.invalidate()
        adaptiveTimer = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        if let clockObserver {
            NotificationCenter.default.removeObserver(clockObserver)
            self.clockObserver = nil
        }
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
        guard !isTerminating, presets.indices.contains(index) else { return }
        // Fade from the frame on screen, including one caught mid-fade. The model lands on
        // the preset at once; only the render clock eases there, as with Adaptive.
        let rendered = currentRenderedOutput()
        if adaptiveEnabled {
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
        startOutputTransition(
            from: rendered,
            to: OutputPair(intensity: preset.intensity, whitepoint: preset.whitepoint))
        save()
    }

    func saveToPreset(_ index: Int) {
        guard !isTerminating, presets.indices.contains(index) else { return }
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
                let (elev, rising) = SolarCalculator.position(
                    at: date, latitude: coord.latitude, longitude: coord.longitude)
                let minElev = SolarCalculator.elevationAtSolarMidnight(
                    at: date, latitude: coord.latitude, longitude: coord.longitude)
                let curve = adaptiveCurve(
                    elevation: elev, minElevation: minElev, rising: rising,
                    time: (date: date, longitude: coord.longitude))
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
        displayReconfigurationObserver = DisplayReconfigurationObserver { [weak self] flags in
            self?.handleDisplayReconfiguration(flags)
        }
        displayWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDisplayWake() }
        }

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

        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPause() }
        }
    }

    /// Reapply gamma after wake and force a fresh one-shot location request: the laptop may
    /// have traveled while asleep. ColorSync-restore first so a GPU LUT reset during sleep
    /// cannot be snapshotted as the "original" calibration. Kept internal so the
    /// no-double-apply behavior is testable.
    func handleWake() {
        guard !isTerminating else { return }
        scheduleDisplayRecovery()
        // A pause that ended during sleep must resume before the filter is reapplied.
        refreshPause()
        synchronizeTransitionState(at: transitionUptime())
        guard !isTerminating else { return }
        gamma.resetForDisplayRecovery()
        guard adaptiveEnabled else { applyToActiveDisplays(); return }
        requestLocationIfNeeded(at: now(), force: true)
        if location.coordinate == nil { applyToActiveDisplays() }
        applyAdaptive()
    }

    /// A panel can wake or retrain its link without changing its Core Graphics ID.
    func handleDisplayWake() {
        guard !isTerminating else { return }
        refreshPause()
        refreshDisplays(apply: true, resetCalibration: true)
        scheduleDisplayRecovery()
    }

    func handleDisplayReconfiguration(_ flags: CGDisplayChangeSummaryFlags) {
        guard !isTerminating, DisplayReconfigurationObserver.isHardwareChange(flags) else { return }
        scheduleDisplayRecovery()
    }

    private func scheduleDisplayRecovery() {
        guard !isTerminating else { return }
        // Coalesce link-training events. Reset ColorSync again after the connection
        // settles, before capturing calibration, instead of layering onto a stale LUT.
        if let displayRecoveryTimer {
            displayRecoveryTimer.fireDate = Date(timeIntervalSinceNow: 2)
            return
        }
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.completeDisplayRecovery() }
        }
        displayRecoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Internal hook lets regression tests finish recovery without sleeping.
    func completeDisplayRecovery() {
        guard displayRecoveryTimer != nil else { return }
        displayRecoveryTimer?.invalidate()
        displayRecoveryTimer = nil
        guard !isTerminating else { return }
        refreshDisplays(apply: true, resetCalibration: true)
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

    func tickDisplayTransitions() {
        applyDisplayTransitionFrame(at: transitionUptime())
        stopTransitionTimerIfIdle()
        finishTerminationIfReady()
    }

    /// Deterministic test hook. Production uses each display transition's own monotonic start
    /// time; tests can advance every active display to the same normalized point directly.
    func advanceDisplayTransitions(toProgress rawProgress: Double) {
        applyDisplayTransitionFrame(at: 0, progress: rawProgress)
        stopTransitionTimerIfIdle()
        finishTerminationIfReady()
    }

    @discardableResult
    private func updateDisplayTransition(
        _ displayID: CGDirectDisplayID,
        at timestamp: TimeInterval,
        progress explicitProgress: Double? = nil
    ) -> Bool {
        guard var transition = displayTransitions[displayID] else { return false }
        let rawProgress = explicitProgress ?? (timestamp - transition.startedAt) / displayTransitionDuration
        let progress = min(1, max(0, rawProgress))
        let eased = Self.smoothstep(progress)
        transition.currentAmount = transition.fromAmount
            + (transition.toAmount - transition.fromAmount) * eased
        if isTerminating {
            shutdownDisplayAmounts[displayID] = transition.currentAmount
        }

        if progress >= 1 {
            displayTransitions.removeValue(forKey: displayID)
            fadingDisplayIDs.remove(displayID)
        } else {
            displayTransitions[displayID] = transition
        }
        return true
    }

    private func applyDisplayTransitionFrame(
        at timestamp: TimeInterval, progress: Double? = nil, applyAll: Bool = false
    ) {
        guard !displayTransitions.isEmpty else {
            if applyAll { applyToActiveDisplays() }
            return
        }
        let rendered = currentRenderedOutput()
        for display in displays {
            let advanced = updateDisplayTransition(display.id, at: timestamp, progress: progress)
            if advanced || applyAll { applyToDisplay(display, rendered: rendered) }
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
              outputTransition != nil || !displayTransitions.isEmpty || pauseTransition != nil
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
        if updatePauseTransition(at: timestamp) { outputChanged = true }
        applyDisplayTransitionFrame(at: timestamp, applyAll: outputChanged)
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
        if !displayTransitions.isEmpty {
            for display in displays { updateDisplayTransition(display.id, at: timestamp) }
        }
        updatePauseTransition(at: timestamp)
        stopTransitionTimerIfIdle()
    }

    private func stopTransitionTimerIfIdle() {
        guard outputTransition == nil, displayTransitions.isEmpty, pauseTransition == nil else { return }
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
        shutdownDisplayAmounts.removeAll()
        gamma.restoreAll()
        completion()
    }

    private static func smoothstep(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)
    }

    // MARK: - Apply

    private func applyToActiveDisplays() {
        let rendered = currentRenderedOutput()
        for display in displays { applyToDisplay(display, rendered: rendered) }
    }

    private func applyToDisplay(_ display: DisplayInfo, rendered: OutputPair? = nil) {
        // A display that joined after shutdown started never participated in this fade.
        if isTerminating, shutdownDisplayAmounts[display.id] == nil { return }
        let rendered = rendered ?? currentRenderedOutput()
        let amount = pauseLevel * (shutdownDisplayAmounts[display.id]
            ?? displayTransitions[display.id]?.currentAmount
            ?? (display.isEnabled ? 1 : 0))
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

    // MARK: - Pause

    /// When an active pause ends; persisted so a relaunch or update stays paused.
    private(set) var pausedUntil: Date?
    var isPaused: Bool { pausedUntil != nil }
    /// The current pause's total length, persisted beside `pausedUntil`. It anchors the
    /// countdown and caps duration-based pauses after a backward clock change.
    private(set) var pauseLength: TimeInterval = Defaults.pauseDuration
    @ObservationIgnored private var pauseUsesDeadline = false

    /// Whole minutes left, rounded up so the countdown reads 1 until the pause ends.
    /// The CLI and Siri status say "N min left" at any length, so scripts parse one form.
    nonisolated static func pauseMinutesLeft(until: Date, now: Date) -> Int {
        let minutes = until.timeIntervalSince(now) / 60
        guard minutes > 1 else { return 1 }
        return Int(exactly: minutes.rounded(.up)) ?? Int.max
    }

    /// Popover countdown: "30 min" under an hour, then "1 h 12 m", from the same rounded-up
    /// minutes as `pauseMinutesLeft`.
    nonisolated static func pauseCountdownText(until: Date, now: Date) -> String {
        durationText(minutes: pauseMinutesLeft(until: until, now: now))
    }

    /// The countdown spelled out for VoiceOver, which would read "h" and "m" as letters.
    nonisolated static func pauseCountdownAccessibilityText(until: Date, now: Date) -> String {
        let minutes = pauseMinutesLeft(until: until, now: now)
        func count(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }
        let parts = [minutes / 60 > 0 ? count(minutes / 60, "hour") : nil,
                     minutes % 60 > 0 ? count(minutes % 60, "minute") : nil].compactMap { $0 }
        return "Paused, \(parts.joined(separator: " ")) left"
    }

    /// A pause length in the same words, such as "30 min" or "2 h".
    nonisolated static func pauseLengthText(_ seconds: TimeInterval) -> String {
        let minutes = (seconds / 60).rounded()
        return durationText(minutes: minutes.isFinite && minutes > 1 ? Int(exactly: minutes) ?? Int.max : 1)
    }

    nonisolated private static func durationText(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : hoursText(minutes)
    }

    /// The next sunrise at the current coordinate (manual, fix or time zone).
    func nextSunrise() -> Date? {
        guard let coord = location.coordinate else { return nil }
        return SunCycle.nextSunrise(after: now(), latitude: coord.latitude, longitude: coord.longitude)
    }

    /// Suspend the tint (not Invert) for `duration`, clamped to one minute through one day.
    /// Replaces a pause already running. Requires a filter to pause.
    @discardableResult
    func pause(for duration: TimeInterval = Defaults.pauseDuration) -> Bool {
        let length = duration.isFinite ? clamp(duration, to: Defaults.pauseLengthRange) : Defaults.pauseDuration
        return startPause(until: now().addingTimeInterval(length), length: length, usesDeadline: false)
    }

    /// Pause to an absolute event time, which may be nearer or farther than a fixed duration allows.
    @discardableResult
    func pause(until deadline: Date) -> Bool {
        let length = deadline.timeIntervalSince(now())
        guard length.isFinite, length > 0 else { return false }
        return startPause(until: deadline, length: length, usesDeadline: true)
    }

    private func startPause(until deadline: Date, length: TimeInterval, usesDeadline: Bool) -> Bool {
        guard !isTerminating, isOn else { return false }
        isPeeking = false
        pauseLength = length
        pauseUsesDeadline = usesDeadline
        pausedUntil = deadline
        persistPause()
        startPauseTransition(to: pauseTarget, duration: displayTransitionDuration)
        publishMasterState()
        return true
    }

    func resume() {
        guard !isTerminating, isPaused else { return }
        pausedUntil = nil
        persistPause()
        startPauseTransition(to: pauseTarget, duration: displayTransitionDuration)
        publishMasterState()
    }

    /// The name of the chosen app in front, which hides the tint (not Invert) like a pause.
    /// Unlike a pause it is untimed, not saved, and not off: `isOn`, `isFiltering` and the
    /// published master state ignore it, and turning the master off and on keeps it.
    private(set) var suspendedForApp: String?

    /// The level every pause, peek and app suspension edge fades to: 0 while any of them
    /// hides the tint, so ending one never shows the filter while another still applies.
    private var pauseTarget: Double {
        isPaused || isPeeking || suspendedForApp != nil ? 0 : 1
    }

    /// Needs no filter: a suspension that starts while off still applies when turned on.
    func setSuspendedForApp(_ name: String?) {
        guard !isTerminating, suspendedForApp != name else { return }
        let target = pauseTarget
        suspendedForApp = name
        // Switching between two chosen apps, or a pause or peek already hiding the tint,
        // leaves the level (and any fade in progress) alone.
        guard pauseTarget != target else { return }
        // Ending it while off, perhaps mid fade-out: fold the hidden level into that fade-out,
        // as `endPauseIntoFadeOut` does, so the tint cannot come back on its way out.
        if !isOn, pauseTarget == 1 {
            let level = pauseLevel
            let shown = displayTransitions.map { ($0.key, level * $0.value.currentAmount) }
            pauseTransition = nil
            if isPauseFading { isPauseFading = false }
            pauseLevel = 1
            for (id, amount) in shown { startDisplayTransition(id, from: amount, to: 0) }
            applyToActiveDisplays()
            stopTransitionTimerIfIdle()
            return
        }
        // While off nothing is tinted, so snap: a fade would flicker the menu bar icon and
        // could leave a falling level to meet a turn-on's rising one.
        let tinted = isOn || !fadingDisplayIDs.isEmpty
        startPauseTransition(to: pauseTarget, duration: tinted ? displayTransitionDuration : 0)
    }

    /// Show the unfiltered screen only while a shortcut is held. Does nothing while paused
    /// or suspended for an app.
    func setPeeking(_ peeking: Bool) {
        guard !isTerminating, isPeeking != peeking, !peeking || isOn else { return }
        let target = pauseTarget
        isPeeking = peeking
        guard pauseTarget != target else { return }
        startPauseTransition(to: pauseTarget, duration: peekTransitionDuration)
    }

    /// End an expired pause, and cap one that a clock change pushed further out.
    func refreshPause() {
        guard let pausedUntil, !isTerminating else { return }
        let current = now()
        if pausedUntil <= current { resume(); return }
        if !pauseUsesDeadline, pausedUntil.timeIntervalSince(current) > pauseLength {
            self.pausedUntil = current.addingTimeInterval(pauseLength)
            persistPause()
        } else {
            schedulePauseTimer()
        }
    }

    private func loadPause() {
        guard let raw = defaults.object(forKey: "redlight.pausedUntil") as? Double, raw.isFinite
        else { return }
        let current = now()
        let until = Date(timeIntervalSince1970: raw)
        if until > current, isOn {
            pauseUsesDeadline = defaults.bool(forKey: "redlight.pauseUsesDeadline")
            if pauseUsesDeadline {
                let length = defaults.object(forKey: "redlight.pauseLength") as? Double
                pauseLength = length.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                    ?? until.timeIntervalSince(current)
                pausedUntil = until
            } else {
                pauseLength = Self.loadPauseLength(defaults)
                pausedUntil = min(until, current.addingTimeInterval(pauseLength))
            }
            pauseLevel = 0
        }
        persistPause()
    }

    /// A pause saved before lengths were stored was always the default, so a missing (or
    /// corrupt) length keeps the 30-minute cap.
    private static func loadPauseLength(_ defaults: UserDefaults) -> TimeInterval {
        guard let value = defaults.object(forKey: "redlight.pauseLength") as? Double, value.isFinite,
              Defaults.pauseLengthRange.contains(value) else { return Defaults.pauseDuration }
        return value
    }

    private func persistPause() {
        persist(pausedUntil?.timeIntervalSince1970, "redlight.pausedUntil")
        persist(pausedUntil == nil ? nil : pauseLength, "redlight.pauseLength")
        persist(pausedUntil != nil && pauseUsesDeadline ? true : nil, "redlight.pauseUsesDeadline")
        schedulePauseTimer()
    }

    private func schedulePauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard let pausedUntil, !isTerminating else { return }
        // Timers do not run during sleep; `handleWake` covers a pause that ended meanwhile.
        let timer = Timer(fire: pausedUntil, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPause() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    /// Turning the last display off ends a pause. Carry the pause level into each display's
    /// fade-out so a paused filter does not briefly reappear on its way out. An app
    /// suspension outlives off, so its level stays at (or keeps fading to) 0 and scales the
    /// fade-out as usual; turning on again while the app is in front then stays untinted.
    private func endPauseIntoFadeOut() {
        guard isPaused || isPeeking || pauseLevel < 1 || pauseTransition != nil else { return }
        if suspendedForApp != nil {
            pausedUntil = nil
            isPeeking = false
            persistPause()
            publishMasterState()
            return
        }
        let level = pauseLevel
        let shown = displays.map { display in
            (display.id, level * (displayTransitions[display.id]?.currentAmount
                ?? (display.isEnabled ? 1 : 0)))
        }
        pausedUntil = nil
        isPeeking = false
        pauseTransition = nil
        isPauseFading = false
        pauseLevel = 1
        persistPause()
        for (id, amount) in shown { startDisplayTransition(id, from: amount, to: 0) }
        publishMasterState()
    }

    private func startPauseTransition(to target: Double, duration: TimeInterval) {
        if pauseTransition?.to == target { return }
        pauseTransition = nil
        guard duration > 0, pauseLevel != target else {
            pauseLevel = target
            if isPauseFading { isPauseFading = false }
            applyToActiveDisplays()
            stopTransitionTimerIfIdle()
            return
        }
        pauseTransition = PauseTransition(
            from: pauseLevel, to: target, startedAt: transitionUptime(), duration: duration)
        if !isPauseFading { isPauseFading = true }
        startTransitionTimerIfNeeded()
    }

    @discardableResult
    private func updatePauseTransition(at timestamp: TimeInterval) -> Bool {
        guard let transition = pauseTransition else { return false }
        return updatePauseTransition(
            toProgress: max(0, timestamp - transition.startedAt) / transition.duration)
    }

    private func updatePauseTransition(toProgress rawProgress: Double) -> Bool {
        guard let transition = pauseTransition else { return false }
        let progress = min(1, max(0, rawProgress))
        pauseLevel = transition.from + (transition.to - transition.from) * Self.smoothstep(progress)
        if progress >= 1 {
            pauseTransition = nil
            isPauseFading = false
        }
        return true
    }

    /// Deterministic test hook for the pause and peek fades.
    func advancePauseTransition(toProgress progress: Double) {
        guard updatePauseTransition(toProgress: progress) else { return }
        applyToActiveDisplays()
        stopTransitionTimerIfIdle()
    }

    // MARK: - Band marker live preview

    /// Temporarily drive the live filter to `v` (a dragged intensity-band marker) without
    /// touching stored state, so the user sees that intensity in real time.
    func previewIntensity(_ v: Double) {
        guard !isTerminating else { return }
        cancelOutputTransition(.intensity)
        previewIntensityValue = min(1, max(0, v))
        applyToActiveDisplays()
    }

    func previewWhitepoint(_ v: Double) {
        guard !isTerminating else { return }
        cancelOutputTransition(.whitepoint)
        previewWhitepointValue = min(1, max(0.25, v))
        applyToActiveDisplays()
    }

    /// End any marker preview: flush the coalesced band work so the adaptive value lands
    /// in the (possibly moved) band immediately, then revert the filter to it.
    func endPreview() {
        guard !isTerminating else { return }
        // Every command and every popover close ends up here. With no preview showing the
        // rendered output is unchanged, so skip the gamma write; a pending band change
        // still applies itself in the flush.
        let wasPreviewing = previewIntensityValue != nil || previewWhitepointValue != nil
        previewIntensityValue = nil
        previewWhitepointValue = nil
        flushBandRefresh()
        if wasPreviewing { applyToActiveDisplays() }
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
        persist(intensity, "redlight.intensity")
        persist(whitepoint, "redlight.whitepoint")
        for display in displays {
            let prefix = displayDefaultsPrefix(display.persistenceKey)
            persist(display.isEnabled, "\(prefix).enabled")
            persist(display.isInverted, "\(prefix).inverted")
        }
        if lastSavedPresets != presets, let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: "redlight.presets")
            lastSavedPresets = presets
        }
        persist(activePresetIndex ?? -1, "redlight.activePresetIndex")
        persist(adaptiveEnabled, "redlight.adaptiveEnabled")
        persist(adaptiveIntensityOffset, "redlight.adaptiveOffsetIntensity")
        persist(adaptiveWhitepointOffset, "redlight.adaptiveOffsetWhitepoint")
        persist(pendingAdaptiveIntensity, "redlight.pendingAdaptiveIntensity")
        persist(pendingAdaptiveWhitepoint, "redlight.pendingAdaptiveWhitepoint")
        persist(adaptiveMin, "redlight.adaptiveMin")
        persist(adaptiveMax, "redlight.adaptiveMax")
        persist(adaptiveWpMin, "redlight.adaptiveWpMin")
        persist(adaptiveWpMax, "redlight.adaptiveWpMax")
        persist(bedtime?.minuteOfDay, "redlight.adaptiveBedtime")
        publishMasterState()
    }

    /// A slider drag calls `save()` on every event; write only the keys whose value moved
    /// instead of pushing ~20 unchanged keys to cfprefsd each time. `nil` removes the key.
    private func persist<T: Hashable>(_ value: T?, _ key: String) {
        let boxed: AnyHashable? = if let value { AnyHashable(value) } else { nil }
        if let last = lastSavedValues[key], last == boxed { return }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        lastSavedValues[key] = boxed
    }

    private func loadPresets() {
        if let data = defaults.data(forKey: "redlight.presets"),
           let saved = try? JSONDecoder().decode([Preset].self, from: data),
           saved.count == Preset.defaults.count {
            // Presets feed `intensity`/`whitepoint` through internal writes that skip the
            // didSet clamp, so clamp them here; a non-finite value falls back to the default.
            presets = zip(saved, Preset.defaults).map { preset, fallback in
                var p = preset
                p.intensity = p.intensity.isFinite ? clamp(p.intensity, to: 0...1) : fallback.intensity
                p.whitepoint = p.whitepoint.isFinite
                    ? clamp(p.whitepoint, to: 0.25...1) : fallback.whitepoint
                return p
            }
            lastSavedPresets = saved
            // Saved presets keep their stored name, so the renamed default is migrated here.
            // Write it now: nothing else saves until the user next changes a setting.
            if let last = presets.indices.last, presets[last].name == Preset.legacyLastName {
                presets[last].name = Preset.defaults[last].name
                if let data = try? JSONEncoder().encode(presets) {
                    defaults.set(data, forKey: "redlight.presets")
                    lastSavedPresets = presets
                }
            }
        }
        if let index = defaults.object(forKey: "redlight.activePresetIndex") as? Int,
           presets.indices.contains(index),
           presets[index].intensity == intensity, presets[index].whitepoint == whitepoint {
            activePresetIndex = index
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
        let legacyKey = "redlight.display.\(id).\(suffix)"
        // Without a UUID the numeric key remains the active storage location.
        guard stableKey != legacyKey else { return defaults.bool(forKey: stableKey) }
        if defaults.object(forKey: legacyKey) != nil {
            if defaults.object(forKey: stableKey) == nil {
                defaults.set(defaults.bool(forKey: legacyKey), forKey: stableKey)
            }
            // The same transient ID may next belong to a different monitor.
            defaults.removeObject(forKey: legacyKey)
        }
        return defaults.bool(forKey: stableKey)
    }

    // MARK: - System Helpers

    nonisolated static func systemDisplayIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        // A display removed between the two calls leaves zeroed slots; drop them rather
        // than list a phantom display 0.
        return Array(ids.prefix(Int(count)))
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
