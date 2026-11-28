import AppKit
import ColorSync
import Observation
import os

enum PeekSource: Hashable, Sendable {
    case shortcut
    case command
}

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
        var saturation: Double = 1
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
        /// Auto's fade, or the shorter one of a switch between apps' rules.
        var duration: TimeInterval
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
    /// Intensity defaults to its full range. Auto's white point stops halfway down its
    /// scale, 50 % as the slider shows it (`WhitepointScale`): a night at the old minimum, the
    /// Late preset's 0.30, was darker than most people want without having asked for it.
    /// The flag can still be taken to the floor.
    enum Defaults {
        /// Learn my adjustments.
        static let learningEnabled = true
        static let intensity = 1.0
        static let intensityMin = 0.0
        static let intensityMax = 1.0
        static let saturation = 0.0
        static let saturationEnabled = false
        static let whitepoint = 1.0
        static let whitepointMin = 0.625
        static let whitepointMax = 1.0
        static let adaptiveFadeDuration: TimeInterval = 2.0
        static let displayFadeDuration: TimeInterval = 0.7
        static let peekFadeDuration: TimeInterval = 0.15
        /// Switching to or from an app with a Hold or Shift.
        static let appRuleFadeDuration: TimeInterval = 0.4
        static let pauseDuration: TimeInterval = 30 * 60
        static let pauseLengthRange: ClosedRange<TimeInterval> = 60...86_400
    }

    private(set) var displays: [DisplayInfo] = []
    // Auto can render a point between slider stops. User edits replace that output
    // with a whole-percent setting, and the next Auto tick can resume interpolation.
    private var manualColorPercent = 100
    private var manualWhitepointPercent = 100
    private var autoIntensity: Double?
    private var autoWhitepoint: Double?

    var colorPercent: Int { autoIntensity.map { SliderPercent.whole($0 * 100) } ?? manualColorPercent }
    var whitepointPercent: Int {
        autoWhitepoint.map { SliderPercent.whole(WhitepointScale.percent($0)) } ?? manualWhitepointPercent
    }

    var intensity: Double {
        get { autoIntensity ?? SliderPercent.unit(manualColorPercent) }
        set {
            if adaptiveEnabled && internalUpdate {
                autoIntensity = newValue
            } else {
                manualColorPercent = SliderPercent.whole(newValue * 100)
                autoIntensity = nil
            }
            // Internal (adaptive/preset) writes apply + save once at their call site.
            guard isInitialized, !internalUpdate else { return }
            cancelOutputTransition(.intensity)
            if adaptiveEnabled, isIntensityPinned {
                // A pinned band is a fixed value, so a manual change moves the pin. It
                // replaces any earlier nudge, which would otherwise return on un-pinning.
                let pin = intensity
                setInternal {
                    adaptiveMin = pin
                    adaptiveMax = pin
                }
                adaptiveIntensityOffset = 0
                pendingAdaptiveIntensity = nil
                learningLimitsMovedByHand(.intensity, pinMoved: true)
            } else if adaptiveEnabled, learningEnabled, habit != nil {
                learnedNudge(.intensity)
            } else if adaptiveEnabled {
                // While adaptive: the band is a hard limit on a manual nudge…
                let clamped = clamp(intensity, to: intensityBand)
                if clamped != intensity { autoIntensity = clamped }
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
    var whitepoint: Double {
        get { autoWhitepoint ?? WhitepointScale.output(percent: Double(manualWhitepointPercent)) }
        set {
            if adaptiveEnabled && internalUpdate {
                autoWhitepoint = newValue
            } else {
                manualWhitepointPercent = SliderPercent.whole(WhitepointScale.percent(newValue))
                autoWhitepoint = nil
            }
            guard isInitialized, !internalUpdate else { return }
            cancelOutputTransition(.whitepoint)
            if adaptiveEnabled, isWhitepointPinned {
                let pin = whitepoint
                setInternal {
                    adaptiveWpMin = pin
                    adaptiveWpMax = pin
                }
                adaptiveWhitepointOffset = 0
                pendingAdaptiveWhitepoint = nil
                learningLimitsMovedByHand(.whitepoint, pinMoved: true)
            } else if adaptiveEnabled, learningEnabled, habit != nil {
                learnedNudge(.whitepoint)
            } else if adaptiveEnabled {
                let clamped = clamp(whitepoint, to: whitepointBand)
                if clamped != whitepoint { autoWhitepoint = clamped }
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

    /// Color retained after the grayscale pass. 1 is full color and 0 is grayscale.
    var saturation: Double {
        get { SliderPercent.unit(saturationPercent) }
        set { saturationPercent = SliderPercent.whole(newValue * 100) }
    }

    private(set) var saturationPercent = 0 {
        didSet {
            guard isInitialized, !internalUpdate, oldValue != saturationPercent else { return }
            if saturationEnabled || isPreviewingSaturation {
                cancelSaturationTransition()
                applyToActiveDisplays()
            }
            save()
        }
    }

    /// Whether the grayscale/color saturation pass is active. The stored slider value is
    /// retained while this is off so the switch can temporarily reveal full color.
    var saturationEnabled: Bool = Defaults.saturationEnabled {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            isPreviewingSaturation = false
            cancelSaturationTransition()
            applyToActiveDisplays()
            save()
        }
    }

    /// True while a tint reaches a display: one is switched on and the tint is neither paused
    /// nor hidden by an app's Pause rule, or a fade is still running.
    var isTintShowing: Bool {
        !fadingDisplayIDs.isEmpty || isPauseFading
            || (!isPaused && !isPausedForApp && displays.contains { $0.isEnabled })
    }

    /// A tint or an inversion is showing.
    var isAnyActive: Bool {
        isTintShowing || displays.contains { $0.isInverted }
    }

    /// Logical master state follows connected filter checkboxes, independently of inversion.
    var isOn: Bool { displays.contains { $0.isEnabled } }
    /// A pause keeps the checkboxes but shows no tint, so commands and Control Center see off.
    var isFiltering: Bool { isOn && !isPaused }
    var commandIsFading: Bool {
        outputTransition != nil || !fadingDisplayIDs.isEmpty || pauseTransition != nil
    }
    /// Commands report endpoints; the render clock and marker previews are transient frames.
    /// The endpoint is what the displays are heading for, an app's Hold or Shift included.
    var commandTargetOutput: OutputPair { effectiveTarget }
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
                if activeAppRule != nil {
                    // A Hold or Shift is shaping the frame on screen, which is not the model's
                    // to keep: the model stays on its own target, and the screen eases to the
                    // rule over Manual, whose limits differ from Auto's.
                    setInternal {
                        intensity = SliderPercent.unit(colorPercent)
                        whitepoint = WhitepointScale.output(percent: Double(whitepointPercent))
                        activePresetIndex = nil
                    }
                    startOutputTransition(from: rendered, to: effectiveTarget)
                } else {
                    // Hold the visible frame at the nearest manual slider stops,
                    // including when Auto was partway through a fade.
                    setInternal {
                        intensity = rendered.intensity
                        whitepoint = rendered.whitepoint
                        activePresetIndex = nil
                    }
                    applyToActiveDisplays()
                }
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
            learningLimitsMovedByHand(.intensity, end: .lower)
            scheduleBandRefresh(.intensity)
        }
    }
    var adaptiveMax: Double = 1.0 {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            let v = clamp(adaptiveMax, to: 0...1)
            if v != adaptiveMax { setInternal { adaptiveMax = v } }
            if v < adaptiveMin { setInternal { adaptiveMin = v } }
            learningLimitsMovedByHand(.intensity, end: .upper)
            scheduleBandRefresh(.intensity)
        }
    }
    /// White Point band. See `Defaults.whitepointMin`.
    var adaptiveWpMin: Double = Defaults.whitepointMin {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            let v = clamp(adaptiveWpMin, to: 0.25...1)
            if v != adaptiveWpMin { setInternal { adaptiveWpMin = v } }
            if v > adaptiveWpMax { setInternal { adaptiveWpMax = v } }
            learningLimitsMovedByHand(.whitepoint, end: .lower)
            scheduleBandRefresh(.whitepoint)
        }
    }
    var adaptiveWpMax: Double = 1.0 {
        didSet {
            guard isInitialized, !internalUpdate else { return }
            let v = clamp(adaptiveWpMax, to: 0.25...1)
            if v != adaptiveWpMax { setInternal { adaptiveWpMax = v } }
            if v < adaptiveWpMin { setInternal { adaptiveWpMin = v } }
            learningLimitsMovedByHand(.whitepoint, end: .upper)
            scheduleBandRefresh(.whitepoint)
        }
    }
    /// "Learn my adjustments": Auto keeps what the user keeps, where in the sun's day they
    /// set it, and moves the limit flags to where they stay. Off, Auto is exactly as it was.
    private(set) var learningEnabled = false
    /// Counts up whenever what has been learned may have changed, for the views that say so.
    private(set) var learningRevision = 0
    /// How many earlier states of the learning are kept, newest last: a reset saves one first,
    /// and `redlight learn restore` brings the newest back.
    private(set) var learningBackupCount = 0
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
    /// The same for the white point, in its output units.
    var adaptiveWhitepointAdjustment: Double { adaptiveWhitepointOffset }

    // MARK: - Slider writes

    /// What the popover's colour temp slider writes: any value from 0 to 1, in Auto too.
    ///
    /// In Auto a value outside the band first moves the nearer limit out to it, so the band
    /// does not clamp the value back. The curve is then worked out again for the wider band
    /// before the value is written, so the offset the value leaves behind is measured against
    /// the curve the next tick uses: the screen stays where the slider put it. A pinned band
    /// is left to `intensity`'s own rule, which moves the pin with the value.
    func setIntensityPushingBand(_ value: Double) {
        guard value.isFinite else { return }
        let v = SliderPercent.unit(SliderPercent.whole(value * 100))
        if adaptiveEnabled, learningEnabled, habit != nil, !isIntensityPinned {
            // Learning decides what a push past a flag does, after it has put back the
            // state from before the gesture: see `learnedNudge`.
            sliderWriteInFlight = true
            defer { sliderWriteInFlight = false }
            intensity = v
            return
        }
        if adaptiveEnabled, !isIntensityPinned, !intensityBand.contains(v) {
            setInternal {
                if v > adaptiveMax { adaptiveMax = v } else { adaptiveMin = v }
            }
            rebaseAdaptiveCurve()
        }
        intensity = v
    }

    /// The same for the white point slider, over 0.25…1.
    func setWhitepointPushingBand(_ value: Double) {
        guard value.isFinite else { return }
        let v = WhitepointScale.output(percent: Double(SliderPercent.whole(WhitepointScale.percent(value))))
        if adaptiveEnabled, learningEnabled, habit != nil, !isWhitepointPinned {
            sliderWriteInFlight = true
            defer { sliderWriteInFlight = false }
            whitepoint = v
            return
        }
        if adaptiveEnabled, !isWhitepointPinned, !whitepointBand.contains(v) {
            setInternal {
                if v > adaptiveWpMax { adaptiveWpMax = v } else { adaptiveWpMin = v }
            }
            rebaseAdaptiveCurve()
        }
        whitepoint = v
    }

    /// Refreshes the curve values an Auto nudge is measured against, after a limit moved,
    /// without touching the outputs or the displays. Without a location there is no curve,
    /// and the nudge waits as a pending value, as it does for any slider write.
    private func rebaseAdaptiveCurve() {
        guard adaptiveEnabled else { return }
        _ = resolveAdaptiveTarget()
    }

    /// "Deepest by": Adaptive reaches the deepest end of its band by this local time. Nil is off.
    private(set) var bedtime: Bedtime?
    /// "Clear by": Adaptive is back at the Day end of its band by this local time, and a
    /// bedtime holds through the night until then. Nil is off.
    private(set) var wakeTime: Bedtime?

    /// The bedtime, when it will change the curve on the evening that is running or comes
    /// next. `BedtimeRamp` ignores one that falls less than one ramp after solar noon, or
    /// after solar midnight unless a wake time holds the night open for it, and nothing can
    /// follow the sun without a coordinate.
    var effectiveBedtime: Bedtime? {
        nightSchedule?.bedtime != nil ? bedtime : nil
    }

    /// The wake time, when it will change the curve on the morning that comes next:
    /// `BedtimeRamp` ignores one that is not between solar midnight and solar noon.
    var effectiveWakeTime: Bedtime? {
        nightSchedule?.wake != nil ? wakeTime : nil
    }

    private var nightSchedule: BedtimeRamp.Schedule? {
        guard bedtime != nil || wakeTime != nil, let coordinate = location.coordinate else { return nil }
        return BedtimeRamp.schedule(
            bedtime: bedtime, wake: wakeTime,
            solarMidnight: SolarCalculator.nextSolarMidnight(after: now(), longitude: coordinate.longitude),
            calendar: calendar)
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

    /// Set or clear the wake time, as `setBedtime` does the bedtime.
    func setWakeTime(_ wakeTime: Bedtime?) {
        guard !isTerminating, wakeTime != self.wakeTime else { return }
        self.wakeTime = wakeTime
        if adaptiveEnabled {
            animateNextAdaptiveTarget = true
            applyAdaptive()
        }
        save()
    }

    /// The applied value for a sun elevation: the curve with the offset and the hard-band
    /// clamp, exactly as the display gets it. Pass the sample's
    /// time to include the bedtime floor and the wake-time lift.
    func adaptiveIntensity(
        at elevation: Double, minElevation: Double, maxElevation: Double, rising: Bool = false,
        time: (date: Date, longitude: Double)? = nil
    ) -> Double {
        let curve = adaptiveCurve(
            elevation: elevation, minElevation: minElevation, maxElevation: maxElevation,
            rising: rising, time: time)
        return clamp(curve.intensity + adaptiveIntensityOffset, to: intensityBand)
    }

    /// Everything the day's tint depends on besides the sun. Equal inputs give an equal
    /// `autoTintTrack`, so the sun arc works one out only when these change.
    struct AutoTintInputs: Equatable {
        var enabled: Bool
        var intensityMin: Double
        var intensityMax: Double
        var offset: Double
        var whitepointMin: Double
        var whitepointMax: Double
        var whitepointOffset: Double
        var bedtime: Bedtime?
        var wakeTime: Bedtime?
        var presets: [Preset]
        var learning: Bool
        var learningRevision: Int
        var latitude: Double?
        var longitude: Double?
    }

    var autoTintInputs: AutoTintInputs {
        AutoTintInputs(
            enabled: adaptiveEnabled, intensityMin: adaptiveMin, intensityMax: adaptiveMax,
            offset: adaptiveIntensityOffset, whitepointMin: adaptiveWpMin, whitepointMax: adaptiveWpMax,
            whitepointOffset: adaptiveWhitepointOffset, bedtime: bedtime, wakeTime: wakeTime, presets: presets,
            learning: learningEnabled, learningRevision: learningRevision,
            latitude: coordinate?.latitude, longitude: coordinate?.longitude)
    }

    /// What Auto will show at one sample of the day: the colour temp, 0…1, and the white point
    /// in its output units, 0.25…1.
    struct AutoTint: Equatable {
        var intensity: Double
        var whitepoint: Double
    }

    /// What Auto will show at each sample of a day: the curve with the bedtime floor and the
    /// wake-time lift, the user's offset or what was learned around that part of the day, and
    /// the flags, for both sliders. Nil when Auto is off or has no location.
    func autoTintTrack(for samples: [SunCycle.Sample]) -> [AutoTint]? {
        guard adaptiveEnabled, let first = samples.first, let coord = location.coordinate else { return nil }
        // The sun's part is worked out once for a day and place: a slider drag asks for a new
        // track on every event, and only the limits and offsets have changed.
        let key = TintFrameKey(
            first: first.date, count: samples.count, latitude: coord.latitude, longitude: coord.longitude,
            bedtime: bedtime, wakeTime: wakeTime)
        let moments: [SolarMoment]
        if let tintFrame, tintFrame.key == key {
            moments = tintFrame.moments
        } else {
            moments = samples.map { sample in
                let minElevation = SolarCalculator.elevationAtSolarMidnight(
                    at: sample.date, latitude: coord.latitude, longitude: coord.longitude)
                let maxElevation = SolarCalculator.elevationAtSolarNoon(
                    at: sample.date, latitude: coord.latitude, longitude: coord.longitude)
                return SolarMoment(
                    elevation: sample.elevation, minElevation: minElevation, maxElevation: maxElevation,
                    rising: sample.rising,
                    weights: BedtimeRamp.weights(at: sample.date, bedtime: bedtime, wake: wakeTime,
                                                 longitude: coord.longitude, calendar: calendar),
                    phase: SolarCurve.phase(elevation: sample.elevation, minElevation: minElevation,
                                            maxElevation: maxElevation, rising: sample.rising))
            }
            tintFrame = (key, moments)
        }
        let color = learningEnabled ? habit?.color : nil
        let white = learningEnabled ? habit?.whitepoint : nil
        let colorScale = scalingBand(.intensity), whiteScale = scalingBand(.whitepoint)
        return moments.map { moment in
            let curve = AdaptiveMapping.target(
                elevation: moment.elevation, minElevation: moment.minElevation,
                maxElevation: moment.maxElevation, rising: moment.rising, presets: presets,
                intensityMin: colorScale.lowerBound, intensityMax: colorScale.upperBound,
                whitepointMin: whiteScale.lowerBound, whitepointMax: whiteScale.upperBound, bedtime: moment.weights)
            // As `resolveAdaptiveTarget` and `resolveLearnedTarget` work out the live target.
            let intensity = color.map { clamp($0.output(curve: curve.intensity, phase: moment.phase), to: 0...1) }
                ?? clamp(curve.intensity + adaptiveIntensityOffset, to: intensityBand)
            let whitepoint = white.map {
                clamp(toOutput($0.output(curve: toModel(curve.whitepoint, .whitepoint), phase: moment.phase), .whitepoint),
                      to: 0.25...1)
            } ?? clamp(curve.whitepoint + adaptiveWhitepointOffset, to: whitepointBand)
            return AutoTint(intensity: intensity, whitepoint: whitepoint)
        }
    }

    /// The one banded curve, bedtime floor and wake-time lift included, behind the live
    /// target, the sun arc and the Save to Preset rebase.
    private func adaptiveCurve(
        elevation: Double, minElevation: Double, maxElevation: Double, rising: Bool,
        time: (date: Date, longitude: Double)?
    ) -> AdaptiveMapping.Target {
        let weights = time.map {
            BedtimeRamp.weights(at: $0.date, bedtime: bedtime, wake: wakeTime,
                                longitude: $0.longitude, calendar: calendar)
        } ?? .inactive
        // With learning on the curve is scaled into the limits as last set by hand; the
        // flags, which learning may have moved inside them, only clamp what is shown.
        let intensityScale = scalingBand(.intensity), whitepointScale = scalingBand(.whitepoint)
        return AdaptiveMapping.target(
            elevation: elevation, minElevation: minElevation, maxElevation: maxElevation,
            rising: rising, presets: presets,
            intensityMin: intensityScale.lowerBound, intensityMax: intensityScale.upperBound,
            whitepointMin: whitepointScale.lowerBound, whitepointMax: whitepointScale.upperBound,
            bedtime: weights
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
        let duration: TimeInterval
        if animateNextAdaptiveTarget || explicitStart != nil {
            transitionChannels = [.intensity, .whitepoint]
            duration = adaptiveTransitionDuration
        } else {
            // A fade already running is retargeted at its own pace: a switch between apps
            // stays a short one.
            transitionChannels = outputTransition?.channels ?? []
            duration = outputTransition?.duration ?? adaptiveTransitionDuration
        }

        if !transitionChannels.isEmpty || transitionSaturationValue != nil {
            animateNextAdaptiveTarget = false
            startOutputTransition(from: rendered, to: effectiveTarget, channels: transitionChannels, duration: duration)
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

        let solar = SolarCalculator.positionAndBounds(
            at: date, latitude: coord.latitude, longitude: coord.longitude)
        let elev = solar.elevation
        let rising = solar.rising
        let minElev = solar.minElevation
        let maxElev = solar.maxElevation
        // Morning and evening curves differ above the horizon. They meet at solar noon and
        // midnight everywhere but within a few degrees of the poles; fade across the switch
        // so that what is left of a step there is never a jump.
        if let lastAdaptiveRising, lastAdaptiveRising != rising { animateNextAdaptiveTarget = true }
        lastAdaptiveRising = rising
        let banded = adaptiveCurve(
            elevation: elev, minElevation: minElev, maxElevation: maxElev, rising: rising,
            time: (date: date, longitude: coord.longitude))
        if learningEnabled, habit != nil {
            let moment = SolarMoment(
                elevation: elev, minElevation: minElev, maxElevation: maxElev, rising: rising,
                weights: BedtimeRamp.weights(at: date, bedtime: bedtime, wake: wakeTime,
                                             longitude: coord.longitude, calendar: calendar),
                phase: SolarCurve.phase(elevation: elev, minElevation: minElev, maxElevation: maxElev, rising: rising))
            lastSolarMoment = moment
            return resolveLearnedTarget(banded: banded, moment: moment, elevation: elev, date: date, coordinate: coord)
        }

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

        let adjusted = (adaptiveIntensityOffset != 0 || adaptiveWhitepointOffset != 0)
            ? " · adjusted" : ""
        describeAdaptive(elevation: elev, banded: banded, adjusted: adjusted, date: date, coordinate: coord)
        return target
    }

    /// The status line and the countdown for a resolved target. `adjusted` is the suffix that
    /// says the user's own changes are part of it.
    private func describeAdaptive(
        elevation: Double, banded: AdaptiveMapping.Target, adjusted: String, date: Date,
        coordinate coord: (latitude: Double, longitude: Double)
    ) {
        let elevationText = Self.formatElevation(elevation)
        // The floor, not the sun, set the curve (before the manual offset).
        let floored = banded.wake ? " · wake time" : banded.bedtime ? " · bedtime" : ""
        let source = location.manualCoordinate != nil ? " · manual"
            : location.isApproximate ? " · time zone"
            : location.authorization == .denied ? " · last known" : ""
        let status = "Following the sun · \(elevationText)\(floored)\(adjusted)\(source)"
        if status != adaptiveStatusText { adaptiveStatusText = status }   // avoid 5 s-tick invalidation
        updateNextSolarEvent(at: date, coordinate: coord)
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
            MainActor.assumeIsolated {
                self?.applyAdaptive()
                self?.learningTick()
            }
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
        lastSolarMoment = nil
        lastLearningTick = nil
        habit?.color.dropGesture()
        habit?.whitepoint.dropGesture()
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
              adaptiveIntensityOffset == 0, pendingAdaptiveIntensity == nil,
              !hasLearned(.intensity) else { return false }
        return adaptiveEnabled || intensity == Defaults.intensity
    }

    var whitepointIsDefault: Bool {
        guard adaptiveWpMin == Defaults.whitepointMin, adaptiveWpMax == Defaults.whitepointMax,
              adaptiveWhitepointOffset == 0, pendingAdaptiveWhitepoint == nil,
              !hasLearned(.whitepoint) else { return false }
        return adaptiveEnabled || whitepoint == Defaults.whitepoint
    }

    /// The Auto half of `intensityIsDefault`: the limits and the nudge. Manual does not show
    /// them, and they return with Auto.
    var intensityAutoSettingsAreDefault: Bool {
        adaptiveMin == Defaults.intensityMin && adaptiveMax == Defaults.intensityMax
            && adaptiveIntensityOffset == 0 && pendingAdaptiveIntensity == nil
            && !hasLearned(.intensity)
    }

    var whitepointAutoSettingsAreDefault: Bool {
        adaptiveWpMin == Defaults.whitepointMin && adaptiveWpMax == Defaults.whitepointMax
            && adaptiveWhitepointOffset == 0 && pendingAdaptiveWhitepoint == nil
            && !hasLearned(.whitepoint)
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
        forgetLearning(.intensity)
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
        forgetLearning(.whitepoint)
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
    /// True for a display that agents' tools create to run apps out of sight.
    private let isAgentDisplay: (CGDirectDisplayID) -> Bool
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
    /// Fraction of the tint shown: 1 normally, 0 while paused, peeking or in an app with a
    /// Pause rule. Invert is not scaled.
    @ObservationIgnored private var pauseLevel: Double = 1
    @ObservationIgnored private var pauseTransition: PauseTransition?
    /// The frame on screen when an app's Pause rule started hiding it, kept until the pause
    /// level's fade is over: the tint fades out as it was rather than through the output
    /// behind it.
    @ObservationIgnored private var heldOutput: OutputPair?
    // Observed so the popover's pause button can show the peek; it changes only as a peek
    // starts or ends.
    private var peekSources: Set<PeekSource> = []
    var isPeeking: Bool { !peekSources.isEmpty }
    // Observable only at fade boundaries, like `fadingDisplayIDs`, for the tray icon.
    private var isPauseFading = false
    @ObservationIgnored private var adaptiveIntensityOffset: Double = 0
    @ObservationIgnored private var adaptiveWhitepointOffset: Double = 0
    // An adaptive slider can be moved before a location-backed solar curve exists. Keep that
    // desired value until the curve resolves, then convert it to the usual persistent offset.
    @ObservationIgnored private var pendingAdaptiveIntensity: Double?
    @ObservationIgnored private var pendingAdaptiveWhitepoint: Double?
    // Transient live-preview overrides while an Auto range limit is being dragged. Observed,
    // through `shownIntensity` and `shownWhitepoint`, so they are written only on a change.
    private var previewIntensityValue: Double?
    private var previewWhitepointValue: Double?
    @ObservationIgnored private var isPreviewingSaturation = false
    // Transient rendered-output overrides used by the Adaptive and preset crossfades.
    @ObservationIgnored private var transitionIntensityValue: Double?
    @ObservationIgnored private var transitionWhitepointValue: Double?
    @ObservationIgnored private var transitionSaturationValue: Double?
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
    /// What has been learned. Kept while the switch is off, for the next time it is on.
    @ObservationIgnored private var habit: HabitModel?
    @ObservationIgnored private let presence: PresenceMonitoring
    /// The sun as the last resolved target saw it: what a nudge is measured against.
    @ObservationIgnored private var lastSolarMoment: SolarMoment?
    /// The sun at each sample of the day the arc last drew, for `autoTintTrack`.
    @ObservationIgnored private var tintFrame: (key: TintFrameKey, moments: [SolarMoment])?
    @ObservationIgnored private var lastLearningTick: Date?
    /// True while the popover's slider is writing: only it may push a flag.
    @ObservationIgnored private var sliderWriteInFlight = false
    /// Whether each channel's last nudge came from the popover's slider.
    @ObservationIgnored private var lastNudgeFromSlider: [OutputChannel: Bool] = [:]
    /// Ends whose learned flag a limit change just folded into the hand band, until the band
    /// change is flushed: setting one of them in the same change still sets a learned flag.
    @ObservationIgnored private var foldedLearnedEnds: [OutputChannel: Set<HabitModel.End>] = [:]
    @ObservationIgnored private var lastSavedHabit: Data?
    /// `uptime` at the last save.
    @ObservationIgnored private var lastHabitSave: TimeInterval?
    /// The saved learning is from a newer version: it is never written this session.
    @ObservationIgnored private var keepsNewerHabit = false
    @ObservationIgnored nonisolated(unsafe) private var habitSaveTimer: Timer?
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
    @ObservationIgnored private let appRuleTransitionDuration: TimeInterval
    @ObservationIgnored private let transitionUptime: () -> TimeInterval
    /// Real time, which a test's clock does not move: how often dwell alone is saved.
    @ObservationIgnored private let uptime: () -> TimeInterval

    init(
        gamma: GammaControlling = DisplayFilterController(),
        getDisplayIDs: @escaping () -> [CGDirectDisplayID]? = { DisplayManager.systemDisplayIDs() },
        getDisplayName: @escaping (CGDirectDisplayID) -> String = { DisplayManager.systemDisplayName(for: $0) },
        isAgentDisplay: @escaping (CGDirectDisplayID) -> Bool = { DisplayManager.hasAgentDisplayIdentity($0) },
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
        appRuleTransitionDuration: TimeInterval = Defaults.appRuleFadeDuration,
        transitionUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        activeApp: ActiveApp? = nil,
        presence: PresenceMonitoring? = nil,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        locationPromptActivation: @escaping () -> Void = { NSApplication.shared.activate() },
        controlDefaults: UserDefaults? = nil,
        onMasterStateChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.gamma = gamma
        self.getDisplayIDs = getDisplayIDs
        self.getDisplayName = getDisplayName
        self.isAgentDisplay = isAgentDisplay
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
        self.presence = presence ?? SystemPresence()
        self.now = now
        self.calendar = calendar
        self.nextSolarEvent = nextSolarEvent
        self.adaptiveTransitionDuration = max(0, adaptiveTransitionDuration)
        self.displayTransitionDuration = max(0, displayTransitionDuration)
        self.peekTransitionDuration = max(0, peekTransitionDuration)
        self.appRuleTransitionDuration = max(0, appRuleTransitionDuration)
        self.transitionUptime = transitionUptime
        self.uptime = uptime
        // Clamp on load: a hand-edited or corrupt plist must not put the thumb off the
        // track or send >1 into the gamma composer. (Bands are normalized below.)
        func savedPercent(_ key: String, legacy: String, whitepoint: Bool = false) -> Int? {
            if let value = Self.loadOptionalClamped(defaults, key, range: 0...100) {
                return SliderPercent.whole(value)
            }
            let range = whitepoint ? WhitepointScale.output : 0...1
            guard let old = Self.loadOptionalClamped(defaults, legacy, range: range) else { return nil }
            let percent = SliderPercent.whole(whitepoint ? WhitepointScale.percent(old) : old * 100)
            defaults.set(percent, forKey: key)
            return percent
        }
        manualColorPercent = savedPercent("redlight.colorPercent", legacy: "redlight.intensity") ?? 100
        manualWhitepointPercent = savedPercent("redlight.whitepointPercent", legacy: "redlight.whitepoint", whitepoint: true) ?? 100
        let legacySaturation = Self.loadOptionalClamped(defaults, "redlight.saturation", range: 0...1)
        saturationPercent = savedPercent("redlight.saturationPercent", legacy: "redlight.saturation") ?? 0
        saturationEnabled = defaults.object(forKey: "redlight.saturationEnabled") as? Bool
            ?? (legacySaturation.map { $0 < 1 } ?? false)
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
        self.wakeTime = (defaults.object(forKey: "redlight.adaptiveWakeTime") as? Int)
            .flatMap { Bedtime(minuteOfDay: $0) }
        loadPresets()
        loadLearning()
        if adaptiveEnabled { activePresetIndex = nil }
        refreshDisplays(apply: false)
        loadPause()
        // The app in front at launch is known before the first frame, so its rule applies
        // from the start: a Pause starts hidden like a saved pause instead of fading in and
        // straight back out, and a Hold or Shift is the first thing shown.
        if let activeApp {
            self.activeApp = activeApp
            if activeApp.rule == .pause { pauseLevel = 0 }
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
            // A day that ended while the app was not running closes before the first frame.
            closeLearningDayIfDue()
            applyAdaptive()
            startAdaptiveTimer()
        } else {
            applyToActiveDisplays()
        }
        self.presence.onAway = { [weak self] in self?.presenceWentAway() }
        self.presence.onReturn = { [weak self] in self?.presenceReturned() }
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
        habitSaveTimer?.invalidate()
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
            guard !isIgnored(id, name: name) else {
                ignoredDisplayIDs.insert(id)
                return false
            }
            // An ID can come back as another display: this one is real, whatever it was.
            ignoredDisplayIDs.remove(id)
            return true
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
        clearPreview()
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
        flushLearning()
        presence.onAway = nil
        presence.onReturn = nil
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
        startOutputTransition(from: rendered, to: effectiveTarget)
        save()
    }

    func saveToPreset(_ index: Int) {
        guard !isTerminating, presets.indices.contains(index) else { return }
        let desiredIntensity = intensity
        let desiredWhitepoint = whitepoint
        presets[index].intensity = desiredIntensity
        presets[index].whitepoint = desiredWhitepoint
        // The presets are the curve's anchors: what was learned keeps its picture on the new curve.
        rebaseLearningToPresets()
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
                let maxElev = SolarCalculator.elevationAtSolarNoon(
                    at: date, latitude: coord.latitude, longitude: coord.longitude)
                let curve = adaptiveCurve(
                    elevation: elev, minElevation: minElev, maxElevation: maxElev, rising: rising,
                    time: (date: date, longitude: coord.longitude))
                if learningEnabled, habit != nil {
                    holdLearnedOutput(OutputPair(intensity: desiredIntensity, whitepoint: desiredWhitepoint))
                } else {
                    adaptiveIntensityOffset = desiredIntensity - curve.intensity
                    adaptiveWhitepointOffset = desiredWhitepoint - curve.whitepoint
                }
            }
            applyAdaptive()
        } else {
            activePresetIndex = index
        }
        save()
    }

    // MARK: - System Events

    private func startListening() {
        displayReconfigurationObserver = DisplayReconfigurationObserver { [weak self] display, flags in
            self?.handleDisplayReconfiguration(flags, display: display)
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
            MainActor.assumeIsolated { self?.handleClockChange() }
        }
    }

    /// The system clock was set. Kept internal so tests can call it without posting the
    /// notification to every manager.
    func handleClockChange() {
        refreshPause()
        guard learningEnabled, habit != nil else { return }
        let time = now().timeIntervalSinceReferenceDate
        habit?.color.clockWasSet(at: time)
        habit?.whitepoint.clockWasSet(at: time)
        lastLearningTick = nil
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
        // Nobody has seen the screen since it slept: a learning day that ended meanwhile
        // closes before the first frame, not in front of whoever woke it.
        lastLearningTick = nil
        closeLearningDayIfDue()
        applyAdaptive()
    }

    /// A panel can wake or retrain its link without changing its Core Graphics ID.
    func handleDisplayWake() {
        guard !isTerminating else { return }
        refreshPause()
        refreshDisplays(apply: true, resetCalibration: true)
        // Nobody has seen the screens since they slept: a learning day that ended meanwhile,
        // with no tick to close it, closes now, without a fade, as on a wake of the Mac.
        if learningEnabled, adaptiveEnabled {
            lastLearningTick = nil
            if closeLearningDayIfDue() {
                // The sun turning from evening to morning meanwhile is no reason to fade either.
                lastAdaptiveRising = nil
                animateNextAdaptiveTarget = false
                applyAdaptive()
            }
        }
        scheduleDisplayRecovery()
    }

    func handleDisplayReconfiguration(_ flags: CGDisplayChangeSummaryFlags, display: CGDirectDisplayID? = nil) {
        guard !isTerminating, DisplayReconfigurationObserver.isHardwareChange(flags) else { return }
        // A display Redlight never tints, such as an agent's hidden virtual display, comes
        // and goes without touching the real ones. Recovering would reset every display's
        // ColorSync table and flash the screens unfiltered for a moment.
        if let display, isIgnoredDisplay(display) {
            Self.displayLog.notice("Ignored change 0x\(flags.rawValue, format: .hex, privacy: .public) on agent display \(display, privacy: .public)")
            return
        }
        Self.displayLog.notice("Display \(display.map(String.init) ?? "?", privacy: .public) changed (0x\(flags.rawValue, format: .hex, privacy: .public)); recovering in 2 s")
        scheduleDisplayRecovery()
    }

    private static let displayLog = Logger(subsystem: "com.redlight.app", category: "displays")

    /// Displays left out of the list. Remembered by ID, because a display that has just been
    /// removed can no longer be asked what it is. An ID stops being remembered once a display
    /// with it is listed: that one is real, and its changes recover like any other's.
    @ObservationIgnored private var ignoredDisplayIDs = Set<CGDirectDisplayID>()

    static func isIgnoredDisplayName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("backstage")
    }

    /// Backstage's documented identity for its hidden displays: vendor 0xB57A, model 0x0001.
    /// Sturdier than the name, which is kept as a fallback.
    nonisolated static func hasAgentDisplayIdentity(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0xB57A && CGDisplayModelNumber(id) == 0x0001
    }

    private func isIgnored(_ id: CGDirectDisplayID, name: String) -> Bool {
        isAgentDisplay(id) || Self.isIgnoredDisplayName(name)
    }

    private func isIgnoredDisplay(_ id: CGDirectDisplayID) -> Bool {
        // A listed display is a real one, whatever its ID belonged to before.
        guard !displays.contains(where: { $0.id == id }) else {
            ignoredDisplayIDs.remove(id)
            return false
        }
        if ignoredDisplayIDs.contains(id) { return true }
        guard isIgnored(id, name: getDisplayName(id)) else { return false }
        ignoredDisplayIDs.insert(id)
        return true
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
        Self.displayLog.notice("Display recovery: resetting ColorSync tables and reapplying")
        refreshDisplays(apply: true, resetCalibration: true)
    }

    // MARK: - Output transition

    private func currentRenderedOutput() -> OutputPair {
        if let shutdownOutput { return shutdownOutput }
        if let heldOutput { return heldOutput }
        let target = effectiveTarget
        return OutputPair(
            intensity: previewIntensityValue ?? transitionIntensityValue ?? target.intensity,
            whitepoint: previewWhitepointValue ?? transitionWhitepointValue ?? target.whitepoint,
            saturation: isPreviewingSaturation && activeAppRule?.saturation == nil
                ? saturation : transitionSaturationValue ?? target.saturation)
    }

    private func cancelOutputTransition() {
        outputTransition = nil
        transitionIntensityValue = nil
        transitionWhitepointValue = nil
        transitionSaturationValue = nil
        stopTransitionTimerIfIdle()
    }

    private func cancelSaturationTransition() {
        transitionSaturationValue = nil
        if outputTransition?.channels.isEmpty == true {
            outputTransition = nil
            stopTransitionTimerIfIdle()
        }
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
        guard !transition.channels.isEmpty || transitionSaturationValue != nil else {
            outputTransition = nil
            stopTransitionTimerIfIdle()
            return
        }
        outputTransition = transition
    }

    /// `to` is a resolved target (`effectiveTarget`), and `from` the frame on screen.
    private func startOutputTransition(
        from: OutputPair,
        to: OutputPair,
        channels requestedChannels: Set<OutputChannel> = [.intensity, .whitepoint],
        duration requestedDuration: TimeInterval? = nil
    ) {
        cancelOutputTransition()
        let duration = requestedDuration ?? adaptiveTransitionDuration
        let channels = requestedChannels.filter { channel in
            switch channel {
            case .intensity: from.intensity != to.intensity
            case .whitepoint: from.whitepoint != to.whitepoint
            }
        }
        let fadesSaturation = from.saturation != to.saturation
        guard duration > 0, !channels.isEmpty || fadesSaturation else {
            applyToActiveDisplays()
            return
        }

        outputTransition = OutputTransition(
            from: from, to: to, startedAt: transitionUptime(), channels: channels, duration: duration)
        if fadesSaturation { transitionSaturationValue = from.saturation }
        if channels.contains(.intensity) { transitionIntensityValue = from.intensity }
        if channels.contains(.whitepoint) { transitionWhitepointValue = from.whitepoint }
        applyToActiveDisplays()
        startTransitionTimerIfNeeded()
    }

    func tickOutputTransition() {
        guard let transition = outputTransition else { return }
        let elapsed = max(0, transitionUptime() - transition.startedAt)
        advanceOutputTransition(toProgress: elapsed / transition.duration)
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

        if transitionSaturationValue != nil {
            transitionSaturationValue = mix(transition.from.saturation, transition.to.saturation)
        }

        if progress >= 1 {
            transitionSaturationValue = nil
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
            outputChanged = updateOutputTransition(toProgress: elapsed / transition.duration)
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
            updateOutputTransition(toProgress: elapsed / transition.duration)
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

    // MARK: - Effective output

    /// The one place that decides what the displays show for the model's target, in this
    /// order:
    ///
    /// 1. The global target: Auto (the curve, learning) or Manual. A rule never changes it.
    /// 2. The app rule: a Hold replaces both channels; a Shift adds slider percent.
    /// 3. Limits: in Auto a Shift stays inside Auto's flags, and a Fixed channel takes none;
    ///    a Hold is held only to each channel's own range.
    ///
    /// Tint visibility comes last and is not here: a pause, a peek and an app's Pause rule
    /// scale whatever this gives down to nothing (`pauseLevel`), so a peek always shows the
    /// untinted screen. Every display write, the status target, the sliders and wake
    /// recovery read it, through `effectiveTarget` and `currentRenderedOutput`.
    func resolvedOutput(_ target: OutputPair, rule: AppRule?) -> OutputPair {
        switch rule {
        case nil, .pause?:
            return target
        case .hold(let color, let whitepoint, let level)?:
            return OutputPair(intensity: SliderPercent.unit(color),
                              whitepoint: WhitepointScale.output(percent: Double(whitepoint)),
                              saturation: level.map(SliderPercent.unit) ?? target.saturation)
        case .shift(let color, let whitepoint, let delta)?:
            return OutputPair(intensity: shifted(target.intensity, by: Double(color), .intensity),
                              whitepoint: shifted(target.whitepoint, by: Double(whitepoint), .whitepoint),
                              saturation: clamp(target.saturation + SliderPercent.unit(delta ?? 0), to: 0...1))
        }
    }

    private var globalOutput: OutputPair {
        OutputPair(intensity: intensity, whitepoint: whitepoint, saturation: saturationEnabled ? saturation : 1)
    }

    /// The per-app control parks at 100% while the rule follows global saturation.
    func appSaturationPercent(_ rule: AppRule) -> Int {
        rule.saturation == nil ? 100 : SliderPercent.whole(shownOutput(editing: rule).saturation * 100)
    }

    func rule(_ rule: AppRule, showingSaturation level: Double) -> AppRule {
        guard level.isFinite else { return rule }
        let percent = SliderPercent.whole(level * 100)
        if percent == 100 { return rule.withSaturation(nil) }
        let base = saturationEnabled ? saturationPercent : 100
        return rule.withSaturation(rule.kind == .shift ? percent - base : percent)
    }

    /// What the displays are heading for: the model's target under the app in front's rule.
    var effectiveTarget: OutputPair {
        resolvedOutput(globalOutput, rule: activeAppRule)
    }

    /// The sliders' values while they edit `rule`, or the model's own for none.
    func shownOutput(editing rule: AppRule?) -> OutputPair {
        resolvedOutput(globalOutput, rule: Self.outputRule(rule))
    }

    /// `rule` changed so that `channel` shows `value`, in output units: a slider dragged while
    /// it edits the rule. A Hold takes the value. A Shift takes the amount that puts the value
    /// there, inside Auto's flags in Auto, and stays as it is on a Fixed channel.
    ///
    /// A rule that would show what `rule` already shows is `rule` itself: a Shift held at a
    /// limit keeps its saved amount through a step or a tap at the limit.
    func rule(_ rule: AppRule, showing value: Double, on channel: CommandChannel) -> AppRule {
        guard value.isFinite else { return rule }
        let output: OutputChannel = channel == .color ? .intensity : .whitepoint
        let range: ClosedRange<Double> = output == .intensity ? 0...1 : 0.25...1
        let next: AppRule
        switch rule {
        case .pause:
            return rule
        case .hold:
            next = rule.with(channel, SliderPercent.whole(toModel(clamp(value, to: range), output) * 100))
        case .shift:
            if adaptiveEnabled, isPinned(output) { return rule }
            let model = output == .intensity ? intensity : whitepoint
            let shown = clamp(value, to: adaptiveEnabled ? shiftBand(output, around: model) : range)
            let current = shownOutput(editing: rule)
            let currentValue = output == .intensity ? current.intensity : current.whitepoint
            let percent = SliderPercent.whole(toModel(shown, output) * 100)
            if percent == SliderPercent.whole(toModel(currentValue, output) * 100) { return rule }
            next = rule.with(channel, percent - SliderPercent.whole(toModel(model, output) * 100))
        }
        func shown(_ rule: AppRule) -> Double {
            let pair = shownOutput(editing: rule)
            return output == .intensity ? pair.intensity : pair.whitepoint
        }
        // The white point's round trip through slider percent is not bit-exact.
        return abs(shown(next) - shown(rule)) < 1e-9 ? rule : next
    }

    /// `rule` as a rule of `kind` that shows what `rule` shows now, so choosing a kind changes
    /// the closest whole-percent setting until the user changes an amount.
    /// In Auto a Shift can only come as near as the flags allow, and on a Fixed channel
    /// takes nothing.
    func rule(_ kind: AppRule.Kind, replacing rule: AppRule) -> AppRule {
        guard kind != rule.kind else { return rule }
        let start: AppRule
        switch kind {
        case .pause: return .pause
        case .hold: start = .hold(color: 0, whitepoint: 0)
        case .shift: start = .shift(color: 0, whitepoint: 0)
        }
        let shown = shownOutput(editing: rule)
        let color = self.rule(start, showing: shown.intensity, on: .color)
        let converted = self.rule(color, showing: shown.whitepoint, on: .whitepoint)
        return rule.saturation == nil ? converted : self.rule(converted, showingSaturation: shown.saturation)
    }

    /// `rule` stepped so that `channel` shows `percent` more of its slider, or less: a hotkey
    /// pressed in the app with the rule. Unchanged at a limit.
    func rule(_ rule: AppRule, steppedBy percent: Double, on channel: CommandChannel) -> AppRule {
        let output: OutputChannel = channel == .color ? .intensity : .whitepoint
        let shown = shownOutput(editing: rule)
        let current = toModel(output == .intensity ? shown.intensity : shown.whitepoint, output) * 100
        let next = min(100, max(0, current + percent))
        return self.rule(rule, showing: toOutput(next / 100, output), on: channel)
    }

    /// A Shift's amount in slider percent added to `value`, in output units.
    private func shifted(_ value: Double, by percent: Double, _ channel: OutputChannel) -> Double {
        // A Fixed channel is a value the user set; a shift would move it off.
        if adaptiveEnabled, isPinned(channel) { return value }
        let range: ClosedRange<Double> = channel == .intensity ? 0...1 : 0.25...1
        let moved = clamp(toOutput(toModel(value, channel) + percent / 100, channel), to: range)
        return adaptiveEnabled ? clamp(moved, to: shiftBand(channel, around: value)) : moved
    }

    /// Auto's flags, as they hold a Shift: a target already past one (a learned value can be)
    /// keeps its place rather than being pulled back by a shift the other way.
    private func shiftBand(_ channel: OutputChannel, around value: Double) -> ClosedRange<Double> {
        let band = flagBand(channel)
        return min(band.lowerBound, value)...max(band.upperBound, value)
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
        let s = Float(1 + (rendered.saturation - 1) * amount)
        if !display.isInverted && i == 1 && w == 1 && s == 1 {
            // A neutral enabled filter must leave the ColorSync calibration untouched.
            gamma.restore(display.id)
        } else {
            gamma.applyFilter(
                to: display.id, intensity: i, whitepoint: w,
                invert: display.isInverted, saturation: s)
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
        peekSources.removeAll()
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

    /// The app in front with a rule, from `AppRulesController`. A Pause rule hides the tint
    /// (not Invert) like a pause; unlike one it is untimed, not saved, and not off: `isOn`,
    /// `isFiltering` and the published master state ignore it, and turning the master off
    /// and on keeps it. A Hold or Shift changes what is shown (`effectiveTarget`), never
    /// the model.
    private(set) var activeApp: ActiveApp?

    /// True while the app in front has a Pause rule.
    var isPausedForApp: Bool { activeApp?.rule == .pause }

    /// The app in front's Hold or Shift, which shapes the output; nil for none or a Pause.
    var activeAppRule: AppRule? { Self.outputRule(activeApp?.rule) }

    private static func outputRule(_ rule: AppRule?) -> AppRule? {
        rule?.shapesOutput == true ? rule : nil
    }

    /// The level every pause, peek and Pause rule edge fades to: 0 while any of them hides
    /// the tint, so ending one never shows the filter while another still applies.
    private var pauseTarget: Double {
        isPaused || isPeeking || isPausedForApp ? 0 : 1
    }

    /// Needs no filter: a rule that starts while off still applies when turned on.
    ///
    /// Another app's Hold or Shift, or another kind of rule, fades in over
    /// `appRuleTransitionDuration` from the frame on screen, through the one output
    /// transition, so a switch in the middle of any fade, or a second switch, carries on
    /// from what is visible. A new amount for the same app's rule is an edit, and shows at
    /// once as a slider's does. A switch into an app that pauses keeps the frame on screen
    /// (`heldOutput`) while the tint fades out.
    func setActiveApp(_ app: ActiveApp?) {
        guard !isTerminating, activeApp != app else { return }
        let rendered = currentRenderedOutput()
        let target = pauseTarget
        let previous = activeApp
        let wasHeld = heldOutput != nil
        activeApp = app
        heldOutput = nil
        // Nothing to fade where nothing is tinted: the pause level's own fade reveals it.
        let isVisible = pauseLevel > 0 && (isOn || !fadingDisplayIDs.isEmpty)
        let oldRule = Self.outputRule(previous?.rule), newRule = Self.outputRule(app?.rule)
        if isVisible, pauseTarget == 0, target == 1 || wasHeld {
            // The tint is going. Fading the output too would pass through the global value on
            // the way out, a colour neither end shows, so the frame stays as it is until the
            // pause level's fade has taken it out.
            cancelOutputTransition()
            heldOutput = rendered
        } else if wasHeld || oldRule != newRule {
            // Out of a held frame is always a switch: the output behind it is another one.
            let isEdit = !wasHeld && previous?.processID == app?.processID && previous?.bundleID == app?.bundleID
                && oldRule?.kind == newRule?.kind
            if isEdit {
                // Only the amounts that changed show at once; a fade of the other carries on.
                if oldRule?.saturation != newRule?.saturation { cancelSaturationTransition() }
                if oldRule?.amount(.color) != newRule?.amount(.color) { cancelOutputTransition(.intensity) }
                if oldRule?.amount(.whitepoint) != newRule?.amount(.whitepoint) {
                    cancelOutputTransition(.whitepoint)
                }
                applyToActiveDisplays()
            } else {
                startOutputTransition(from: rendered, to: effectiveTarget,
                                      duration: isVisible ? appRuleTransitionDuration : 0)
            }
        }
        updatePauseLevelForApp(previousTarget: target)
    }

    private func updatePauseLevelForApp(previousTarget target: Double) {
        // Switching between two apps that pause, or a pause or peek already hiding the
        // tint, leaves the level (and any fade in progress) alone.
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

    /// Show the unfiltered screen only while a source is held, whatever the app in front's
    /// rule. Does nothing visible while paused or in an app with a Pause rule.
    func setPeeking(_ peeking: Bool) {
        setPeeking(peeking, source: .shortcut)
    }

    func setPeeking(_ peeking: Bool, source: PeekSource) {
        guard !isTerminating, !peeking || isOn else { return }
        let wasPeeking = isPeeking
        let target = pauseTarget
        if peeking { peekSources.insert(source) } else { peekSources.remove(source) }
        guard wasPeeking != isPeeking else { return }
        guard pauseTarget != target else { return }
        startPauseTransition(to: pauseTarget, duration: peekTransitionDuration)
    }

    func isPeeking(source: PeekSource) -> Bool {
        peekSources.contains(source)
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
    /// fade-out so a paused filter does not briefly reappear on its way out. An app's Pause
    /// rule outlives off, so its level stays at (or keeps fading to) 0 and scales the
    /// fade-out as usual; turning on again while the app is in front then stays untinted.
    private func endPauseIntoFadeOut() {
        guard isPaused || isPeeking || pauseLevel < 1 || pauseTransition != nil else { return }
        if isPausedForApp {
            pausedUntil = nil
            peekSources.removeAll()
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
        peekSources.removeAll()
        pauseTransition = nil
        heldOutput = nil
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
            heldOutput = nil
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
            heldOutput = nil
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

    // MARK: - Range limit live preview

    /// Temporarily drive the live filter to `v` (an Auto range limit being dragged) without
    /// touching stored state, so the user sees that intensity in real time.
    func previewIntensity(_ v: Double) {
        guard !isTerminating else { return }
        cancelOutputTransition(.intensity)
        let value = min(1, max(0, v))
        if previewIntensityValue != value { previewIntensityValue = value }
        applyToActiveDisplays()
    }

    func previewWhitepoint(_ v: Double) {
        guard !isTerminating else { return }
        cancelOutputTransition(.whitepoint)
        let value = min(1, max(0.25, v))
        if previewWhitepointValue != value { previewWhitepointValue = value }
        applyToActiveDisplays()
    }

    /// Bypass the off switch only for the lifetime of a pointer drag.
    func setSaturationPreview(_ active: Bool) {
        guard !isTerminating, !saturationEnabled, isPreviewingSaturation != active else { return }
        isPreviewingSaturation = active
        cancelSaturationTransition()
        applyToActiveDisplays()
    }

    /// End any marker preview: flush the coalesced band work so the adaptive value lands
    /// in the (possibly moved) band immediately, then revert the filter to it.
    func endPreview() {
        guard !isTerminating else { return }
        // Every command and every popover close ends up here. With no preview showing the
        // rendered output is unchanged, so skip the gamma write; a pending band change
        // still applies itself in the flush.
        let wasPreviewing = clearPreview()
        flushBandRefresh()
        if wasPreviewing { applyToActiveDisplays() }
    }

    /// Drops the preview values; true when there was one. With none it writes nothing, so
    /// the views that follow `shownIntensity` are not told of a change that did not happen.
    @discardableResult
    private func clearPreview() -> Bool {
        let wasPreviewing = previewIntensityValue != nil || previewWhitepointValue != nil || isPreviewingSaturation
        isPreviewingSaturation = false
        if previewIntensityValue != nil { previewIntensityValue = nil }
        if previewWhitepointValue != nil { previewWhitepointValue = nil }
        return wasPreviewing
    }

    /// The colour temp the popover paints with: a limit's value while its flag is dragged,
    /// as the displays show it, and otherwise the value the displays are heading for, the
    /// app in front's rule included. A crossfade in progress is left out: the popover shows
    /// where the value is going.
    var shownIntensity: Double { previewIntensityValue ?? effectiveTarget.intensity }
    /// The same for the white point.
    var shownWhitepoint: Double { previewWhitepointValue ?? effectiveTarget.whitepoint }

    // MARK: - Band change coalescing

    /// A limit drag writes `adaptiveMin/Max` dozens of times per second; recomputing the
    /// solar curve and rewriting UserDefaults on each tick is wasteful, and the flag's
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
        foldedLearnedEnds = [:]
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
        // The limits live in the model while learning is on: saved together with their keys.
        if learningEnabled { flushLearning() }
    }

    // MARK: - Learning

    /// The sun as one resolved target saw it. A nudge is measured against the curve at this
    /// moment, as the flat offset always was against `lastCurveIntensity`.
    private struct SolarMoment {
        var elevation: Double
        var minElevation: Double
        var maxElevation: Double
        var rising: Bool
        var weights: BedtimeRamp.Weights
        var phase: SolarCurve.Phase
    }

    private struct TintFrameKey: Equatable {
        var first: Date
        var count: Int
        var latitude: Double
        var longitude: Double
        var bedtime: Bedtime?
        var wakeTime: Bedtime?
    }

    private static let habitKey = "redlight.learning.model"
    private static let learningLog = Logger(subsystem: "com.redlight.app", category: "learning")
    /// No input for this long and the time no longer counts as evidence.
    private static let idleLimit: TimeInterval = 600
    /// No input for this long, and no video holding the displays awake, and nobody is taken
    /// to be there: a day may close. Longer than `idleLimit`, as someone reading is still there.
    private static let closeIdleLimit: TimeInterval = 1800
    /// A day this far past its end closes even in front of someone, so that days never merge.
    private static let longestOverrun: TimeInterval = 12 * 3600
    /// A gap between ticks counts for no more than this.
    private static let longestTick: TimeInterval = 60
    /// Dwell alone is written out this often; everything else is written when it changes.
    private static let dwellSaveInterval: TimeInterval = 600

    // The model works in slider fractions, 0…1. Colour temp is stored that way already; the
    // white point is stored as its output value, 0.25…1.
    private func toModel(_ output: Double, _ channel: OutputChannel) -> Double {
        channel == .intensity ? output : (output - 0.25) / 0.75
    }
    private func toOutput(_ model: Double, _ channel: OutputChannel) -> Double {
        channel == .intensity ? model : 0.25 + model * 0.75
    }
    private func toOutputDelta(_ model: Double, _ channel: OutputChannel) -> Double {
        channel == .intensity ? model : model * 0.75
    }
    private func toModel(_ band: ClosedRange<Double>, _ channel: OutputChannel) -> ClosedRange<Double> {
        toModel(band.lowerBound, channel)...toModel(band.upperBound, channel)
    }

    private func habitChannel(_ channel: OutputChannel) -> HabitModel.Channel? {
        channel == .intensity ? habit?.color : habit?.whitepoint
    }
    private func setHabitChannel(_ channel: OutputChannel, _ value: HabitModel.Channel) {
        if channel == .intensity { habit?.color = value } else { habit?.whitepoint = value }
    }
    private func flagBand(_ channel: OutputChannel) -> ClosedRange<Double> {
        channel == .intensity ? intensityBand : whitepointBand
    }
    private func isPinned(_ channel: OutputChannel) -> Bool {
        channel == .intensity ? isIntensityPinned : isWhitepointPinned
    }
    private func lastCurve(_ channel: OutputChannel) -> Double? {
        channel == .intensity ? lastCurveIntensity : lastCurveWhitepoint
    }

    /// The band the sun curve is scaled into: the limits as last set by hand while learning
    /// is on, and the flags themselves otherwise.
    private func scalingBand(_ channel: OutputChannel) -> ClosedRange<Double> {
        guard learningEnabled, let learned = habitChannel(channel) else { return flagBand(channel) }
        let hand = learned.handBand
        return toOutput(hand.lowerBound, channel)...toOutput(hand.upperBound, channel)
    }

    /// The sun curve's value at each anchor for one channel, in model units, when that
    /// channel's hand band is `band` (model units).
    private func habitAnchors(_ channel: OutputChannel, _ band: ClosedRange<Double>) -> [Double] {
        let lower = toOutput(band.lowerBound, channel), upper = toOutput(band.upperBound, channel)
        let targets = AdaptiveMapping.anchorTargets(
            presets: presets,
            intensityMin: channel == .intensity ? lower : 0, intensityMax: channel == .intensity ? upper : 1,
            whitepointMin: channel == .whitepoint ? lower : 0.25, whitepointMax: channel == .whitepoint ? upper : 1)
        return channel == .intensity ? targets.intensity : targets.whitepoint.map { toModel($0, .whitepoint) }
    }

    /// The sun curve at `moment` for one channel, floor and lift included, in model units,
    /// when that channel's hand band is `band` (model units).
    private func habitCurve(_ channel: OutputChannel, _ band: ClosedRange<Double>, at moment: SolarMoment) -> Double {
        let lower = toOutput(band.lowerBound, channel), upper = toOutput(band.upperBound, channel)
        let target = AdaptiveMapping.target(
            elevation: moment.elevation, minElevation: moment.minElevation,
            maxElevation: moment.maxElevation, rising: moment.rising, presets: presets,
            intensityMin: channel == .intensity ? lower : 0, intensityMax: channel == .intensity ? upper : 1,
            whitepointMin: channel == .whitepoint ? lower : 0.25, whitepointMax: channel == .whitepoint ? upper : 1,
            bedtime: moment.weights)
        return channel == .intensity ? target.intensity : toModel(target.whitepoint, .whitepoint)
    }

    /// While learning is on the model holds the flags and the flat offset. This writes them
    /// to the properties the rest of the app reads, and saves under their usual keys.
    private func syncFromHabit(_ channel: OutputChannel) {
        guard let learned = habitChannel(channel) else { return }
        let range: ClosedRange<Double> = channel == .intensity ? 0...1 : 0.25...1
        let lower = clamp(toOutput(learned.flags.lowerBound, channel), to: range)
        let upper = clamp(toOutput(learned.flags.upperBound, channel), to: range)
        // Written only on a real change: these are observed, and a round trip through the
        // white point's scale can differ in the last bit.
        setInternal {
            switch channel {
            case .intensity:
                if abs(adaptiveMin - lower) > 1e-12 { adaptiveMin = lower }
                if abs(adaptiveMax - upper) > 1e-12 { adaptiveMax = upper }
            case .whitepoint:
                if abs(adaptiveWpMin - lower) > 1e-12 { adaptiveWpMin = lower }
                if abs(adaptiveWpMax - upper) > 1e-12 { adaptiveWpMax = upper }
            }
        }
        switch channel {
        case .intensity: adaptiveIntensityOffset = clamp(learned.flat, to: -1...1)
        case .whitepoint: adaptiveWhitepointOffset = clamp(toOutputDelta(learned.flat, channel), to: -0.75...0.75)
        }
    }

    /// True when Reset beside a slider has learning of that channel to forget. A limit set by
    /// hand alone is not learning: the limits say it.
    private func hasLearned(_ channel: OutputChannel) -> Bool {
        // The model is not observed; the revision is, so the row hears of a close or a reset.
        _ = learningRevision
        return learningEnabled && (habitChannel(channel)?.learnedAnchors ?? 0) > 0
    }

    private func freshHabit() -> HabitModel {
        func fresh(_ channel: OutputChannel, offset: Double) -> HabitModel.Channel {
            let band = toModel(flagBand(channel), channel)
            return HabitModel.Channel(band: band, flat: offset, base: habitAnchors(channel, band))
        }
        return HabitModel(
            color: fresh(.intensity, offset: adaptiveIntensityOffset),
            whitepoint: fresh(.whitepoint, offset: adaptiveWhitepointOffset / 0.75),
            dayStart: HabitDay.start(containing: now(), calendar: calendar))
    }

    // MARK: Learning: nudges and limits

    /// A value set by hand in Auto while learning is on: the popover's slider, the command
    /// line, a hotkey or a Shortcut. The model places it on the anchors around the sun; the
    /// screen lands on the value, inside the flags.
    private func learnedNudge(_ channel: OutputChannel) {
        let requested = channel == .intensity ? intensity : whitepoint
        let slider = sliderWriteInFlight
        guard let moment = lastSolarMoment, lastCurve(channel) != nil,
              var learned = habitChannel(channel) else {
            // No curve yet, as before a first location. A slider past a flag moves the flag
            // by hand, as it does without learning, and the value waits for the curve.
            if slider, !flagBand(channel).contains(requested) {
                setInternal {
                    switch channel {
                    case .intensity: if requested > adaptiveMax { adaptiveMax = requested } else { adaptiveMin = requested }
                    case .whitepoint: if requested > adaptiveWpMax { adaptiveWpMax = requested } else { adaptiveWpMin = requested }
                    }
                }
                learningLimitsMovedByHand(channel)
            }
            let held = clamp(requested, to: flagBand(channel))
            setInternal {
                switch channel {
                case .intensity:
                    if intensity != held { intensity = held }
                    pendingAdaptiveIntensity = held
                case .whitepoint:
                    if whitepoint != held { whitepoint = held }
                    pendingAdaptiveWhitepoint = held
                }
            }
            return
        }
        noteNudgeSource(channel, slider: slider, in: &learned)
        let flagsBefore = learned.flags
        learned.write(
            toModel(requested, channel), slider: slider, phase: moment.phase,
            at: now().timeIntervalSinceReferenceDate,
            curve: { self.habitCurve(channel, $0, at: moment) },
            anchors: { self.habitAnchors(channel, $0) })
        setHabitChannel(channel, learned)
        syncFromHabit(channel)
        // A push may have changed the hand band, and with it the curve the next tick uses.
        let curve = habitCurve(channel, learned.handBand, at: moment)
        let shown = toOutput(learned.output(curve: curve, phase: moment.phase), channel)
        setInternal {
            switch channel {
            case .intensity:
                lastCurveIntensity = toOutput(curve, channel)
                // The model lands on the value to the last bit or so; keep the value as written.
                if abs(intensity - shown) > 1e-9 { intensity = shown }
                pendingAdaptiveIntensity = nil
            case .whitepoint:
                lastCurveWhitepoint = toOutput(curve, channel)
                if abs(whitepoint - shown) > 1e-9 { whitepoint = shown }
                pendingAdaptiveWhitepoint = nil
            }
        }
        learningRevision += 1
        // A push moved a flag, and `save()` has already written the flags' keys: save the model
        // with them, or a crash in between would read the push as a limit set by hand.
        if learned.flags != flagsBefore { flushLearning() } else { scheduleLearningSave() }
    }

    /// Writes from one source within the gesture window are one nudge. Only the slider may
    /// push a flag, so a write from anywhere else would put back the state from before a
    /// push: it starts a nudge of its own.
    private func noteNudgeSource(_ channel: OutputChannel, slider: Bool, in learned: inout HabitModel.Channel) {
        if lastNudgeFromSlider[channel] != slider { learned.dropGesture() }
        lastNudgeFromSlider[channel] = slider
    }

    /// A flag dragged, `redlight limits`, or a Fixed value moved: the limits are the user's
    /// again. Learned flags fold into the hand band, the curve scales into the new limits as
    /// it does without learning, and the end that moved stands like four accepted days.
    ///
    /// `pinMoved` is a Fixed value changed by its slider, which drops Auto's offset for the
    /// channel as it does without learning.
    ///
    /// `end` is the limit that was set, when one was. Set where its learned flag already is,
    /// it is still a hand move: the user has chosen that limit.
    private func learningLimitsMovedByHand(
        _ channel: OutputChannel, end: HabitModel.End? = nil, pinMoved: Bool = false
    ) {
        guard learningEnabled, var learned = habitChannel(channel) else { return }
        let flags = learned.flags
        let band = bandForModel(channel, keeping: flags)
        // `redlight limits` sets one end after the other, and the first folds every learned
        // flag into the hand band: the second end was on a learned flag all the same.
        let setAtFlag = end.flatMap {
            learned.hasLearnedFlag($0) || foldedLearnedEnds[channel, default: []].contains($0) ? $0 : nil
        }
        if band != flags || setAtFlag != nil {
            // Only a named end is half of `redlight limits`; a push before there is a curve is not.
            for other in [HabitModel.End.lower, .upper]
            where end != nil && other != end && learned.hasLearnedFlag(other) {
                foldedLearnedEnds[channel, default: []].insert(other)
            }
            if let setAtFlag { foldedLearnedEnds[channel]?.remove(setAtFlag) }
            learned.setHandBand(band, setAt: setAtFlag, anchors: { self.habitAnchors(channel, $0) })
        }
        if pinMoved { learned.setFlat(0) }
        learned.dropGesture()
        setHabitChannel(channel, learned)
        syncFromHabit(channel)
        learningRevision += 1
        scheduleLearningSave()
    }

    /// The flags as they are now, in model units. An end that has not moved from `flags`
    /// keeps that exact value: the white point's scale does not always round-trip to the
    /// last bit, and an end that looks moved would lose its anchor's history.
    private func bandForModel(_ channel: OutputChannel, keeping flags: ClosedRange<Double>) -> ClosedRange<Double> {
        let band = toModel(flagBand(channel), channel)
        let lower = abs(band.lowerBound - flags.lowerBound) < 1e-9 ? flags.lowerBound : band.lowerBound
        let upper = abs(band.upperBound - flags.upperBound) < 1e-9 ? flags.upperBound : band.upperBound
        return min(lower, upper)...max(lower, upper)
    }

    /// The learned half of `resolveAdaptiveTarget`: the curve in the hand band, plus the
    /// offsets of the anchors around the sun, inside the flags.
    private func resolveLearnedTarget(
        banded: AdaptiveMapping.Target, moment: SolarMoment, elevation: Double, date: Date,
        coordinate coord: (latitude: Double, longitude: Double)
    ) -> OutputPair {
        lastCurveIntensity = banded.intensity
        lastCurveWhitepoint = banded.whitepoint
        // A value set before there was a curve becomes a nudge now that there is one.
        for channel in [OutputChannel.intensity, .whitepoint] {
            let pending = channel == .intensity ? pendingAdaptiveIntensity : pendingAdaptiveWhitepoint
            guard let pending else { continue }
            if channel == .intensity { pendingAdaptiveIntensity = nil } else { pendingAdaptiveWhitepoint = nil }
            guard !isPinned(channel), var learned = habitChannel(channel) else { continue }
            noteNudgeSource(channel, slider: false, in: &learned)
            learned.write(
                toModel(clamp(pending, to: flagBand(channel)), channel), slider: false, phase: moment.phase,
                at: date.timeIntervalSinceReferenceDate,
                curve: { self.habitCurve(channel, $0, at: moment) },
                anchors: { self.habitAnchors(channel, $0) })
            setHabitChannel(channel, learned)
            syncFromHabit(channel)
            learningRevision += 1
            scheduleLearningSave()
        }
        var learnedHere = false, adjustedHere = false
        func shown(_ channel: OutputChannel, curve: Double) -> Double {
            guard let learned = habitChannel(channel) else { return curve }
            if !isPinned(channel) {
                if learned.isLearned(at: moment.phase) {
                    learnedHere = true
                } else if learned.offset(at: moment.phase) != 0 {
                    adjustedHere = true
                }
            }
            return toOutput(learned.output(curve: toModel(curve, channel), phase: moment.phase), channel)
        }
        let target = OutputPair(
            intensity: clamp(shown(.intensity, curve: banded.intensity), to: 0...1),
            whitepoint: clamp(shown(.whitepoint, curve: banded.whitepoint), to: 0.25...1))
        // One slider can be learned here while the other has only Auto's own offset.
        describeAdaptive(
            elevation: elevation, banded: banded,
            adjusted: (learnedHere ? " · learned" : "") + (adjustedHere ? " · adjusted" : ""),
            date: date, coordinate: coord)
        return target
    }

    /// Reset beside a slider also forgets what was learned on that channel.
    private func forgetLearning(_ channel: OutputChannel) {
        guard habit != nil else { return }
        archiveLearning()
        let band = toModel(flagBand(channel), channel)
        setHabitChannel(channel, HabitModel.Channel(band: band, base: habitAnchors(channel, band)))
        if channel == .intensity { habit?.heldColor = nil } else { habit?.heldWhitepoint = nil }
        if learningEnabled { learningRevision += 1 }
        flushLearning()
    }

    /// A preset was saved, which reshapes the curve. Known anchors keep the picture they had:
    /// each gives up what the curve moved by under it. In any mode, and with learning off
    /// too, so that what is stored stays true to the curve it will come back to.
    private func rebaseLearningToPresets() {
        guard habit != nil else { return }
        for channel in [OutputChannel.intensity, .whitepoint] {
            guard var learned = habitChannel(channel) else { continue }
            learned.reshape(to: habitAnchors(channel, learned.handBand))
            setHabitChannel(channel, learned)
            if learningEnabled { syncFromHabit(channel) }
        }
        if learningEnabled { learningRevision += 1 }
        flushLearning()
    }

    /// After a preset was saved in Auto: the screen stays on the pair that was just saved,
    /// as a nudge to it on the reshaped curve.
    private func holdLearnedOutput(_ desired: OutputPair) {
        _ = resolveAdaptiveTarget()
        guard let moment = lastSolarMoment else { return }
        for channel in [OutputChannel.intensity, .whitepoint] where !isPinned(channel) {
            guard var learned = habitChannel(channel) else { continue }
            let value = channel == .intensity ? desired.intensity : desired.whitepoint
            // Not part of a nudge in progress, which it would otherwise put back.
            learned.dropGesture()
            let flat = learned.flat
            learned.write(
                toModel(clamp(value, to: flagBand(channel)), channel), slider: false, phase: moment.phase,
                at: now().timeIntervalSinceReferenceDate,
                curve: { self.habitCurve(channel, $0, at: moment) },
                anchors: { self.habitAnchors(channel, $0) })
            // A preset changes its own part of the day; the rest keeps its offset.
            learned.keepOpenAnchors(at: moment.phase, flat: flat)
            learned.dropGesture()
            setHabitChannel(channel, learned)
            syncFromHabit(channel)
        }
        learningRevision += 1
        flushLearning()
    }

    // MARK: Learning: the switch

    /// Switch "Learn my adjustments".
    ///
    /// On for the first time changes nothing on screen: every anchor is open and the offset
    /// Auto already has is the flat one. On again after a time off brings back what was
    /// learned, and the screen fades to it. Off holds the screen: the flags stay where they
    /// are as ordinary limits, and what is showing becomes Auto's offset.
    func setLearning(_ on: Bool) {
        guard !isTerminating, on != learningEnabled else { return }
        let date = now()
        if on {
            if var model = habit {
                for channel in [OutputChannel.intensity, .whitepoint] {
                    var learned = channel == .intensity ? model.color : model.whitepoint
                    // A preset or a limit may have changed while learning was off.
                    learned.reshape(to: habitAnchors(channel, learned.handBand))
                    let band = bandForModel(channel, keeping: learned.flags)
                    if band != learned.flags {
                        learned.setHandBand(band, anchors: { self.habitAnchors(channel, $0) })
                    }
                    // The offset was changed while learning was off: it is the flat one now.
                    let offset = channel == .intensity ? adaptiveIntensityOffset : adaptiveWhitepointOffset / 0.75
                    let held = channel == .intensity ? model.heldColor : model.heldWhitepoint
                    if held.map({ abs($0 - offset) > 1e-9 }) ?? true { learned.setFlat(offset) }
                    learned.discardDay()
                    if channel == .intensity { model.color = learned } else { model.whitepoint = learned }
                }
                model.heldColor = nil
                model.heldWhitepoint = nil
                model.dayStart = HabitDay.start(containing: date, calendar: calendar)
                habit = model
            } else {
                habit = freshHabit()
            }
            learningEnabled = true
            syncFromHabit(.intensity)
            syncFromHabit(.whitepoint)
        } else {
            let showing = OutputPair(intensity: intensity, whitepoint: whitepoint)
            for channel in [OutputChannel.intensity, .whitepoint] {
                guard var learned = habitChannel(channel) else { continue }
                learned.fold(anchors: { self.habitAnchors(channel, $0) })
                learned.discardDay()
                setHabitChannel(channel, learned)
                syncFromHabit(channel)
            }
            learningEnabled = false
            if adaptiveEnabled {
                // Measure what is showing against the plain curve in the flags, as a nudge is.
                _ = resolveAdaptiveTarget()
                if let curve = lastCurveIntensity, !isIntensityPinned {
                    adaptiveIntensityOffset = clamp(showing.intensity - curve, to: -1...1)
                }
                if let curve = lastCurveWhitepoint, !isWhitepointPinned {
                    adaptiveWhitepointOffset = clamp(showing.whitepoint - curve, to: -0.75...0.75)
                }
            }
            habit?.heldColor = adaptiveIntensityOffset
            habit?.heldWhitepoint = adaptiveWhitepointOffset / 0.75
        }
        learningRevision += 1
        lastLearningTick = nil
        if adaptiveEnabled {
            animateNextAdaptiveTarget = true
            applyAdaptive()
        }
        save()
        flushLearning()
    }

    /// Reset learning: every part of the day open again on both channels and the flags back
    /// where they were last set by hand. Auto's own offset is kept.
    func resetLearning() {
        guard !isTerminating, var model = habit else { return }
        archiveLearning()
        model.color.openAll()
        model.whitepoint.openAll()
        model.dayStart = HabitDay.start(containing: now(), calendar: calendar)
        // Off, nothing is left for the stored flat offsets to belong to: the next switch-on
        // takes Auto's own.
        if !learningEnabled {
            model.heldColor = nil
            model.heldWhitepoint = nil
        }
        habit = model
        if learningEnabled {
            syncFromHabit(.intensity)
            syncFromHabit(.whitepoint)
            if adaptiveEnabled {
                animateNextAdaptiveTarget = true
                applyAdaptive()
            }
        }
        learningRevision += 1
        lastLearningTick = nil
        save()
        flushLearning()
    }

    /// Brings back the learning as it was before the last reset. What is learned now is kept
    /// as a backup in turn, so running it again undoes it. False when there is nothing to
    /// bring back.
    @discardableResult
    func restoreLearning() -> Bool {
        guard !isTerminating else { return false }
        var backups = loadLearningBackups()
        guard let last = backups.popLast(), var model = HabitModel.decode(last.model) else { return false }
        if let current = habit, Self.hasSomethingLearned(current), let data = current.encoded() {
            backups.append(LearningBackup(date: now(), model: data))
        }
        storeLearningBackups(backups)
        // The day's evidence belongs to the day it was saved on; the presets may have changed since.
        model.color.discardDay()
        model.whitepoint.discardDay()
        model.dayStart = HabitDay.start(containing: now(), calendar: calendar)
        habit = model
        for channel in [OutputChannel.intensity, .whitepoint] {
            guard var learned = habitChannel(channel) else { continue }
            learned.reshape(to: habitAnchors(channel, learned.handBand))
            setHabitChannel(channel, learned)
            if learningEnabled { syncFromHabit(channel) }
        }
        if learningEnabled, adaptiveEnabled {
            animateNextAdaptiveTarget = true
            applyAdaptive()
        }
        learningRevision += 1
        lastLearningTick = nil
        save()
        flushLearning()
        return true
    }

    private struct LearningBackup: Codable {
        var date: Date
        var model: Data
    }

    private static let backupsKey = "redlight.learning.backups"
    /// Resets kept for `redlight learn restore`.
    static let learningBackupLimit = 5

    private static func hasSomethingLearned(_ model: HabitModel) -> Bool {
        model.color.knownAnchors + model.whitepoint.knownAnchors > 0
            || model.color.hasLearnedFlags || model.whitepoint.hasLearnedFlags
    }

    /// Keeps what is learned now, before a reset forgets it. Nothing learned, nothing kept.
    private func archiveLearning() {
        guard let habit, Self.hasSomethingLearned(habit), let data = habit.encoded() else { return }
        var backups = loadLearningBackups()
        backups.append(LearningBackup(date: now(), model: data))
        storeLearningBackups(Array(backups.suffix(Self.learningBackupLimit)))
    }

    private func loadLearningBackups() -> [LearningBackup] {
        guard let data = defaults.data(forKey: Self.backupsKey),
              let backups = try? JSONDecoder().decode([LearningBackup].self, from: data) else { return [] }
        return backups
    }

    private func storeLearningBackups(_ backups: [LearningBackup]) {
        if backups.isEmpty {
            defaults.removeObject(forKey: Self.backupsKey)
        } else if let data = try? JSONEncoder().encode(backups) {
            defaults.set(data, forKey: Self.backupsKey)
        }
        if learningBackupCount != backups.count { learningBackupCount = backups.count }
    }

    /// The model itself, for tests.
    var learnedModel: HabitModel? { habit }

    /// How many parts of the day have something learned, over both channels.
    var learnedAnchorCount: Int {
        let counts = learnedAnchorCounts
        return counts.color + counts.whitepoint
    }

    /// How many parts of the day have something learned on each slider. A Fixed slider shows
    /// none of it, so it counts none.
    var learnedAnchorCounts: (color: Int, whitepoint: Int) {
        _ = learningRevision
        guard learningEnabled, let habit else { return (0, 0) }
        func count(_ channel: HabitModel.Channel) -> Int { channel.isFixed ? 0 : channel.learnedAnchors }
        return (count(habit.color), count(habit.whitepoint))
    }

    /// One slider's learned day, as Settings draws it: what Auto shows at each part of the
    /// day, and what it would show with nothing learned. Values are 0…1 of the slider.
    struct LearnedShape: Equatable {
        /// The parts of the day in the order they come, from late night through the morning,
        /// midday and the evening back to late night: Late appears at both ends.
        static let order: [SolarCurve.Anchor] = [
            .late, .morningNight, .morningNautical, .morningCivil, .morningSunset, .morningWarm, .day,
            .eveningWarm, .eveningSunset, .eveningCivil, .eveningNautical, .eveningNight, .late,
        ]
        var learned: [Double]
        var plain: [Double]
        /// True where that part of the day has been learned from what the user kept.
        var known: [Bool]
    }

    /// Nil while learning is off, and for a slider that is Fixed.
    func learnedShape(_ channel: CommandChannel) -> LearnedShape? {
        _ = learningRevision
        guard learningEnabled, let habit else { return nil }
        let learned = channel == .color ? habit.color : habit.whitepoint
        guard !learned.isFixed else { return nil }
        let order = LearnedShape.order.map(\.rawValue)
        return LearnedShape(
            learned: order.map { learned.shown(at: $0) },
            plain: order.map { learned.state.base[$0] },
            known: order.map { learned.isLearnedAnchor($0) })
    }

    /// What has been learned, a sentence per slider. Empty while there is nothing to say.
    var learningSummary: [String] {
        _ = learningRevision
        guard learningEnabled, let habit else { return [] }
        return habit.sentences()
    }

    // MARK: Learning: time at the screen, and the day's close

    /// Somebody may be at the screen: it is awake and unlocked, and there has been input in
    /// the last ten minutes.
    private var isSomeonePresent: Bool {
        !presence.isAway && !presence.isLocked && presence.idleSeconds() < Self.idleLimit
    }

    /// Nobody is there to see a change: away, locked, or idle for half an hour with nothing
    /// playing. A learning day closes only when this is true, or once it has run far over.
    private var isNobodyThere: Bool {
        presence.isAway || presence.isLocked
            || (presence.idleSeconds() >= Self.closeIdleLimit && !presence.isVideoKeepingDisplayAwake)
    }

    private enum LearningClose { case notDue, due, overrun }

    /// Whether the learning day can close now, and whether it has run so far over that it
    /// closes in front of someone.
    private func learningClose(at date: Date) -> LearningClose {
        // No day, or the clock was set back past its start: the close opens one.
        guard let start = habit?.dayStart, date >= start else { return .due }
        let end = HabitDay.end(of: start, calendar: calendar)
        if date >= end.addingTimeInterval(Self.longestOverrun) { return .overrun }
        return date >= end ? .due : .notDue
    }

    /// Somebody can be looking at a tinted screen that Auto is driving: time that counts as
    /// evidence. Narrower than `isSomeonePresent`: a pause, a peek, an app with a Pause or a
    /// Hold or a flag being dragged stop the evidence, not the person. Time in an app with a
    /// Shift counts: the model holds Auto's own day, without the shift, and so does a tick.
    private var isAttended: Bool {
        adaptiveEnabled && isOn && !isPaused && !isPeeking
            && activeApp.map({ $0.rule.kind == .shift }) ?? true
            && previewIntensityValue == nil && previewWhitepointValue == nil
            && isSomeonePresent
    }

    /// Runs after each 5 s Auto tick: time at the screen counts as evidence for the offsets
    /// showing, and a learning day that has ended closes once nobody is there to see it.
    /// `elapsed` stands in for the time since the last tick, for tests that step a clock.
    func learningTick(elapsed override: TimeInterval? = nil) {
        guard learningEnabled, adaptiveEnabled, habit != nil, !isTerminating else {
            lastLearningTick = nil
            return
        }
        let date = now()
        switch learningClose(at: date) {
        case .notDue: break
        case .due: if isNobodyThere { closeLearningDayAndApply() }
        case .overrun: closeLearningDayAndApply()
        }
        guard isAttended else {
            lastLearningTick = nil
            return
        }
        defer { lastLearningTick = date }
        // Going away, a wake and a return start the count again, so a longer gap here is a
        // timer held back while someone stayed (App Nap, coalescing): it counts as one long
        // tick at most. A test's own step is taken as given.
        let measured = lastLearningTick.map { date.timeIntervalSince($0) } ?? 0
        let elapsed = override ?? min(max(0, measured), Self.longestTick)
        guard elapsed > 0, let moment = lastSolarMoment else { return }
        let time = date.timeIntervalSinceReferenceDate
        for channel in [OutputChannel.intensity, .whitepoint] where !isPinned(channel) {
            guard var learned = habitChannel(channel), let curve = lastCurve(channel) else { continue }
            learned.record(phase: moment.phase, seconds: elapsed, at: time, curve: toModel(curve, channel))
            setHabitChannel(channel, learned)
        }
        // Measured in real time: a test that steps its clock through days would otherwise
        // write the model on every tenth of its ticks.
        if lastHabitSave.map({ uptime() - $0 >= Self.dwellSaveInterval }) ?? true {
            flushLearning()
        }
    }

    /// Ends the learning day once 04:00 has passed. Call only when nobody is at the screen,
    /// or once the day has run far over: a close moves what is learned, and with it what
    /// shows. However many days went by,
    /// one close runs: a day with no evidence casts no votes.
    @discardableResult
    func closeLearningDayIfDue() -> Bool {
        guard learningEnabled, var model = habit, !isTerminating else { return false }
        let date = now()
        guard let start = model.dayStart, date >= start else {
            // No day yet, or the clock was set back past its start: open one here.
            model.color.discardDay()
            model.whitepoint.discardDay()
            model.dayStart = HabitDay.start(containing: date, calendar: calendar)
            habit = model
            return false
        }
        let end = HabitDay.end(of: start, calendar: calendar)
        guard date >= end else { return false }
        let offer = location.coordinate.map {
            HabitDay.offer(from: start, to: end, latitude: $0.latitude, longitude: $0.longitude)
        } ?? Array(repeating: .infinity, count: HabitModel.Channel.anchorCount)
        model.color.close(offer: offer)
        model.whitepoint.close(offer: offer)
        model.dayStart = HabitDay.start(containing: date, calendar: calendar)
        habit = model
        syncFromHabit(.intensity)
        syncFromHabit(.whitepoint)
        learningRevision += 1
        lastLearningTick = nil
        save()
        flushLearning()
        return true
    }

    private func closeLearningDayAndApply() {
        guard closeLearningDayIfDue(), adaptiveEnabled else { return }
        // Nobody sees a fade on screens that are asleep; it would only still be running as
        // they light.
        if !presence.areScreensAsleep { animateNextAdaptiveTarget = true }
        applyAdaptive()
    }

    private func presenceWentAway() {
        guard learningEnabled, !isTerminating else { return }
        lastLearningTick = nil
        flushLearning()
        closeLearningDayAndApply()
    }

    /// Someone is back. A day that ended while they were away has closed already where the
    /// app kept running, and closes in `handleWake` before the first frame where the Mac
    /// slept. It does not close here, in front of whoever just returned.
    private func presenceReturned() {
        lastLearningTick = nil
    }

    // MARK: Learning: persistence

    private func loadLearning() {
        // On until the user switches it off.
        learningEnabled = defaults.object(forKey: "redlight.learningEnabled") as? Bool ?? Defaults.learningEnabled
        learningBackupCount = loadLearningBackups().count
        if let data = defaults.data(forKey: Self.habitKey) {
            habit = HabitModel.decode(data)
            // A newer version's learning is kept for when that version runs again: this one
            // learns from nothing and never writes over it.
            if let version = HabitModel.storedVersion(data), version > HabitModel.currentVersion {
                keepsNewerHabit = true
                Self.learningLog.notice("Saved learning is from a newer version; it is left as it is")
            } else if habit == nil {
                Self.learningLog.notice("Saved learning could not be read; starting with none")
            } else {
                lastSavedHabit = data
            }
        }
        guard learningEnabled else { return }
        if habit == nil { habit = freshHabit() }
        for channel in [OutputChannel.intensity, .whitepoint] {
            guard var learned = habitChannel(channel) else { continue }
            learned.reshape(to: habitAnchors(channel, learned.handBand))
            // The limits and the offset were changed outside the model (an older version,
            // `defaults write`): they are the user's, as at switch-on. The day goes on.
            let band = bandForModel(channel, keeping: learned.flags)
            if band != learned.flags {
                learned.setHandBand(band, anchors: { self.habitAnchors(channel, $0) })
            }
            // Against what `syncFromHabit` writes, which clamps: a wide flat offset is not a change.
            let mirrored = channel == .intensity
                ? clamp(learned.flat, to: -1...1)
                : clamp(toOutputDelta(learned.flat, channel), to: -0.75...0.75)
            let offset = channel == .intensity ? adaptiveIntensityOffset : adaptiveWhitepointOffset
            if abs(offset - mirrored) > 1e-9 {
                learned.setFlat(channel == .intensity ? offset : offset / 0.75)
            }
            setHabitChannel(channel, learned)
            // While learning is on the model is what holds the flags and the flat offset.
            syncFromHabit(channel)
        }
    }

    /// Writes what has been learned, if it changed. Also a test hook.
    func flushLearning() {
        habitSaveTimer?.invalidate()
        habitSaveTimer = nil
        guard let habit, !keepsNewerHabit else { return }
        guard let data = habit.encoded() else {
            Self.learningLog.error("What was learned could not be encoded and was not saved")
            return
        }
        lastHabitSave = uptime()
        guard data != lastSavedHabit else { return }
        defaults.set(data, forKey: Self.habitKey)
        lastSavedHabit = data
    }

    /// A drag writes many times a second; the model is saved on the trailing edge.
    private func scheduleLearningSave() {
        habitSaveTimer?.invalidate()
        habitSaveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushLearning() }
        }
    }

    // MARK: - Persistence

    private func save() {
        persist(colorPercent, "redlight.colorPercent")
        persist(whitepointPercent, "redlight.whitepointPercent")
        persist(saturationPercent, "redlight.saturationPercent")
        persist(saturationEnabled, "redlight.saturationEnabled")
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
        persist(learningEnabled, "redlight.learningEnabled")
        persist(adaptiveIntensityOffset, "redlight.adaptiveOffsetIntensity")
        persist(adaptiveWhitepointOffset, "redlight.adaptiveOffsetWhitepoint")
        persist(pendingAdaptiveIntensity, "redlight.pendingAdaptiveIntensity")
        persist(pendingAdaptiveWhitepoint, "redlight.pendingAdaptiveWhitepoint")
        persist(adaptiveMin, "redlight.adaptiveMin")
        persist(adaptiveMax, "redlight.adaptiveMax")
        persist(adaptiveWpMin, "redlight.adaptiveWpMin")
        persist(adaptiveWpMax, "redlight.adaptiveWpMax")
        persist(bedtime?.minuteOfDay, "redlight.adaptiveBedtime")
        persist(wakeTime?.minuteOfDay, "redlight.adaptiveWakeTime")
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
            presets = saved
            if let last = presets.indices.last, presets[last].name == Preset.legacyLastName {
                presets[last].name = Preset.defaults[last].name
            }
            // Rewrite legacy output fractions in the whole-percent format on first load.
            let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            if (presets != saved || records?.contains(where: { $0["intensity"] != nil }) == true),
               let encoded = try? JSONEncoder().encode(presets) {
                defaults.set(encoded, forKey: "redlight.presets")
            }
            lastSavedPresets = presets
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
