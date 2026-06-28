import AppKit
import Observation

@Observable
final class DisplayManager {
    struct DisplayInfo: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        var isEnabled: Bool
        var isInverted: Bool
    }

    private(set) var displays: [DisplayInfo] = []
    var intensity: Double = 0.5 {
        didSet {
            guard isInitialized else { return }
            if !internalUpdate {
                // While adaptive: a manual nudge becomes a baseline offset the
                // curve keeps riding. Otherwise it's a plain manual override.
                if adaptiveEnabled {
                    adaptiveIntensityOffset = intensity - lastCurveIntensity
                } else {
                    activePresetIndex = nil
                }
            }
            applyToActiveDisplays()
            save()
        }
    }
    var whitepoint: Double = 1.0 {
        didSet {
            guard isInitialized else { return }
            if !internalUpdate {
                if adaptiveEnabled {
                    adaptiveWhitepointOffset = whitepoint - lastCurveWhitepoint
                } else {
                    activePresetIndex = nil
                }
            }
            applyToActiveDisplays()
            save()
        }
    }

    var isAnyActive: Bool {
        displays.contains { $0.isEnabled || $0.isInverted }
    }

    // MARK: - Presets

    var presets: [Preset] = Preset.defaults
    var activePresetIndex: Int? = nil

    // MARK: - Adaptive

    var adaptiveEnabled: Bool = false {
        didSet {
            guard isInitialized else { return }
            if adaptiveEnabled {
                activePresetIndex = nil
                adaptiveIntensityOffset = 0   // fresh enable = clean baseline
                adaptiveWhitepointOffset = 0
                location.requestWhenInUse()
                applyAdaptive()
                startAdaptiveTimer()
            } else {
                adaptiveTimer?.invalidate()
                adaptiveTimer = nil
            }
            save()
        }
    }
    /// Adaptive intensity is remapped into this band: Day → max, deepest night → min.
    /// Defaults 0…1 = no constraint. White Point is unaffected.
    var adaptiveMin: Double = 0.0 {
        didSet {
            guard isInitialized else { return }
            if adaptiveEnabled { applyAdaptive() }
            save()
        }
    }
    var adaptiveMax: Double = 1.0 {
        didSet {
            guard isInitialized else { return }
            if adaptiveEnabled { applyAdaptive() }
            save()
        }
    }
    /// White Point band. Defaults 0.3…1.0 = the unbanded preset curve (non-breaking).
    var adaptiveWpMin: Double = 0.3 {
        didSet {
            guard isInitialized else { return }
            if adaptiveEnabled { applyAdaptive() }
            save()
        }
    }
    var adaptiveWpMax: Double = 1.0 {
        didSet {
            guard isInitialized else { return }
            if adaptiveEnabled { applyAdaptive() }
            save()
        }
    }
    private(set) var adaptiveStatusText: String = ""

    func applyAdaptive() {
        guard adaptiveEnabled else { return }
        switch location.authorization {
        case .denied: adaptiveStatusText = "Location needed"; return
        default: break
        }
        guard let coord = location.coordinate else { adaptiveStatusText = "Locating…"; return }

        let date = now()
        let elev = SolarCalculator.elevation(at: date, latitude: coord.latitude, longitude: coord.longitude)
        let minElev = SolarCalculator.elevationAtSolarMidnight(at: date, latitude: coord.latitude, longitude: coord.longitude)
        let t = SolarCurve.target(elevation: elev, minElevation: minElev, presets: presets)

        // Normalize each channel to a 0…1 day→deep fraction, then remap into its band
        // (Day → max, deepest night → min). Default bands reproduce the raw curve.
        let dayI = presets[0].intensity, deepI = presets[4].intensity
        let dayW = presets[0].whitepoint, deepW = presets[4].whitepoint
        let fracI = dayI != deepI ? (t.intensity - deepI) / (dayI - deepI) : 1
        let fracW = dayW != deepW ? (t.whitepoint - deepW) / (dayW - deepW) : 1

        let iLo = min(adaptiveMin, adaptiveMax), iHi = max(adaptiveMin, adaptiveMax)
        let wLo = min(adaptiveWpMin, adaptiveWpMax), wHi = max(adaptiveWpMin, adaptiveWpMax)
        let bandedIntensity = iLo + (iHi - iLo) * min(1, max(0, fracI))
        let bandedWhitepoint = wLo + (wHi - wLo) * min(1, max(0, fracW))
        lastCurveIntensity = bandedIntensity
        lastCurveWhitepoint = bandedWhitepoint

        internalUpdate = true
        intensity = min(1, max(0, bandedIntensity + adaptiveIntensityOffset))
        whitepoint = min(1, max(0.25, bandedWhitepoint + adaptiveWhitepointOffset))
        internalUpdate = false

        let phase: String
        if elev >= 0 { phase = "day" }
        else if elev >= -6 { phase = "civil twilight" }
        else if elev >= -12 { phase = "nautical twilight" }
        else if elev >= -18 { phase = "astronomical twilight" }
        else { phase = "night" }
        let adjusted = (adaptiveIntensityOffset != 0 || adaptiveWhitepointOffset != 0) ? " (adjusted)" : ""
        adaptiveStatusText = "Following the sun · \(phase)\(adjusted)"
    }

    private func startAdaptiveTimer() {
        adaptiveTimer?.invalidate()
        adaptiveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.applyAdaptive()
        }
    }

    // MARK: - Private

    private let gamma: GammaControlling
    private let getDisplayIDs: () -> [CGDirectDisplayID]
    private let getDisplayName: (CGDirectDisplayID) -> String
    private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let location: LocationProviding
    @ObservationIgnored private var adaptiveTimer: Timer?
    @ObservationIgnored private var adaptiveIntensityOffset: Double = 0
    @ObservationIgnored private var adaptiveWhitepointOffset: Double = 0
    // Transient live-preview overrides while a band marker is being dragged.
    @ObservationIgnored private var previewIntensityValue: Double?
    @ObservationIgnored private var previewWhitepointValue: Double?
    @ObservationIgnored private var lastCurveIntensity: Double = 1.0
    @ObservationIgnored private var lastCurveWhitepoint: Double = 1.0
    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var internalUpdate = false

    init(
        gamma: GammaControlling = GammaController(),
        getDisplayIDs: @escaping () -> [CGDirectDisplayID] = { DisplayManager.systemDisplayIDs() },
        getDisplayName: @escaping (CGDirectDisplayID) -> String = { DisplayManager.systemDisplayName(for: $0) },
        defaults: UserDefaults = .standard,
        location: LocationProviding = LocationProvider(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.gamma = gamma
        self.getDisplayIDs = getDisplayIDs
        self.getDisplayName = getDisplayName
        self.defaults = defaults
        self.location = location
        self.now = now
        self.intensity = defaults.object(forKey: "redlight.intensity") as? Double ?? 0.5
        self.whitepoint = defaults.object(forKey: "redlight.whitepoint") as? Double ?? 1.0
        self.adaptiveEnabled = defaults.bool(forKey: "redlight.adaptiveEnabled")
        self.adaptiveIntensityOffset = defaults.object(forKey: "redlight.adaptiveOffsetIntensity") as? Double ?? 0
        self.adaptiveWhitepointOffset = defaults.object(forKey: "redlight.adaptiveOffsetWhitepoint") as? Double ?? 0
        self.adaptiveMin = defaults.object(forKey: "redlight.adaptiveMin") as? Double ?? 0.0
        self.adaptiveMax = defaults.object(forKey: "redlight.adaptiveMax") as? Double ?? 1.0
        self.adaptiveWpMin = defaults.object(forKey: "redlight.adaptiveWpMin") as? Double ?? 0.3
        self.adaptiveWpMax = defaults.object(forKey: "redlight.adaptiveWpMax") as? Double ?? 1.0
        loadPresets()
        refreshDisplays()
        startListening()
        location.onChange = { [weak self] in
            guard let self, self.adaptiveEnabled else { return }
            self.applyAdaptive()
        }
        isInitialized = true
        if adaptiveEnabled {
            location.requestWhenInUse()
            applyAdaptive()
            startAdaptiveTimer()
        }
    }

    // MARK: - Displays

    func refreshDisplays() {
        let ids = getDisplayIDs()
        let prevEnabled = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.isEnabled) })
        let prevInverted = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.isInverted) })
        displays = ids.map { id in
            let enabled = prevEnabled[id] ?? defaults.bool(forKey: "redlight.display.\(id).enabled")
            let inverted = prevInverted[id] ?? defaults.bool(forKey: "redlight.display.\(id).inverted")
            return DisplayInfo(id: id, name: getDisplayName(id), isEnabled: enabled, isInverted: inverted)
        }
        applyToActiveDisplays()
    }

    func toggle(_ displayID: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[i].isEnabled.toggle()
        applyToDisplay(displays[i])
        save()
    }

    func toggleInvert(_ displayID: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[i].isInverted.toggle()
        applyToDisplay(displays[i])
        save()
    }

    func restoreAllDisplays() {
        gamma.restoreAll()
    }

    // MARK: - Presets

    func applyPreset(_ index: Int) {
        guard index >= 0, index < presets.count else { return }
        if adaptiveEnabled { adaptiveEnabled = false }
        let preset = presets[index]
        internalUpdate = true
        intensity = preset.intensity
        whitepoint = preset.whitepoint
        internalUpdate = false
        activePresetIndex = index
        save()
    }

    func saveToPreset(_ index: Int) {
        guard index >= 0, index < presets.count else { return }
        presets[index].intensity = intensity
        presets[index].whitepoint = whitepoint
        activePresetIndex = index
        save()
    }

    // MARK: - System Events

    func startListening() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyToActiveDisplays()
            self?.applyAdaptive()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDisplays()
        }
    }

    func stopListening() {
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        wakeObserver = nil
        screenObserver = nil
        adaptiveTimer?.invalidate()
        adaptiveTimer = nil
    }

    // MARK: - Persistence

    private func applyToActiveDisplays() {
        for display in displays { applyToDisplay(display) }
    }

    private func applyToDisplay(_ display: DisplayInfo) {
        if display.isEnabled || display.isInverted {
            let i = display.isEnabled ? Float(previewIntensityValue ?? intensity) : 1.0
            let w = display.isEnabled ? Float(previewWhitepointValue ?? whitepoint) : 1.0
            gamma.applyFilter(to: display.id, intensity: i, whitepoint: w, invert: display.isInverted)
        } else {
            gamma.restore(display.id)
        }
    }

    // MARK: - Band marker live preview

    /// Temporarily drive the live filter to `v` (a dragged intensity-band marker) without
    /// touching stored state, so the user sees that intensity in real time.
    func previewIntensity(_ v: Double) {
        previewIntensityValue = min(1, max(0, v))
        applyToActiveDisplays()
    }

    func previewWhitepoint(_ v: Double) {
        previewWhitepointValue = min(1, max(0.25, v))
        applyToActiveDisplays()
    }

    /// End any marker preview and revert to the current (adaptive) value.
    func endPreview() {
        previewIntensityValue = nil
        previewWhitepointValue = nil
        applyToActiveDisplays()
    }

    private func save() {
        defaults.set(intensity, forKey: "redlight.intensity")
        defaults.set(whitepoint, forKey: "redlight.whitepoint")
        for display in displays {
            defaults.set(display.isEnabled, forKey: "redlight.display.\(display.id).enabled")
            defaults.set(display.isInverted, forKey: "redlight.display.\(display.id).inverted")
        }
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: "redlight.presets")
        }
        defaults.set(activePresetIndex ?? -1, forKey: "redlight.activePresetIndex")
        defaults.set(adaptiveEnabled, forKey: "redlight.adaptiveEnabled")
        defaults.set(adaptiveIntensityOffset, forKey: "redlight.adaptiveOffsetIntensity")
        defaults.set(adaptiveWhitepointOffset, forKey: "redlight.adaptiveOffsetWhitepoint")
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
        }
        if defaults.object(forKey: "redlight.activePresetIndex") != nil {
            let idx = defaults.integer(forKey: "redlight.activePresetIndex")
            activePresetIndex = idx >= 0 && idx < 5 ? idx : nil
        }
    }

    // MARK: - System Helpers

    static func systemDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids
    }

    static func systemDisplayName(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenID == id {
                return screen.localizedName
            }
        }
        return "Display \(id)"
    }
}
