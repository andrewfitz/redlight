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
                if adaptiveEnabled { adaptiveEnabled = false }
                activePresetIndex = nil
            }
            applyToActiveDisplays()
            save()
        }
    }
    var whitepoint: Double = 1.0 {
        didSet {
            guard isInitialized else { return }
            if !internalUpdate {
                if adaptiveEnabled { adaptiveEnabled = false }
                activePresetIndex = nil
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
    private(set) var adaptiveStatusText: String = ""

    var grayscale: Bool = false {
        didSet {
            guard isInitialized else { return }
            gamma.setGrayscale(grayscale)
            save()
        }
    }

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

        internalUpdate = true
        intensity = t.intensity
        whitepoint = t.whitepoint
        internalUpdate = false

        let phase = elev >= 0 ? "day" : (elev >= -6 ? "twilight" : "night")
        adaptiveStatusText = "Following the sun · \(phase)"
    }

    private func startAdaptiveTimer() {
        adaptiveTimer?.invalidate()
        adaptiveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
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
        self.grayscale = defaults.bool(forKey: "redlight.grayscale")
        loadPresets()
        refreshDisplays()
        startListening()
        gamma.setGrayscale(grayscale)
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
            let i = display.isEnabled ? Float(intensity) : 1.0
            let w = display.isEnabled ? Float(whitepoint) : 1.0
            gamma.applyFilter(to: display.id, intensity: i, whitepoint: w, invert: display.isInverted)
        } else {
            gamma.restore(display.id)
        }
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
        defaults.set(grayscale, forKey: "redlight.grayscale")
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
