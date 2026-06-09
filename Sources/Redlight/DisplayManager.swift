import AppKit
import Observation

@Observable
final class DisplayManager {
    struct DisplayInfo: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        var isEnabled: Bool
    }

    private(set) var displays: [DisplayInfo] = []
    var intensity: Double = 0.5 {
        didSet {
            guard isInitialized else { return }
            if !internalUpdate { activePresetIndex = nil }
            applyToActiveDisplays()
            save()
        }
    }
    var whitepoint: Double = 1.0 {
        didSet {
            guard isInitialized else { return }
            if !internalUpdate { activePresetIndex = nil }
            applyToActiveDisplays()
            save()
        }
    }

    var isAnyActive: Bool {
        displays.contains(where: \.isEnabled)
    }

    // MARK: - Presets

    var presets: [Preset] = Preset.defaults
    var activePresetIndex: Int? = nil

    // MARK: - Private

    private let gamma: GammaControlling
    private let getDisplayIDs: () -> [CGDirectDisplayID]
    private let getDisplayName: (CGDirectDisplayID) -> String
    private let defaults: UserDefaults
    @ObservationIgnored private var isInitialized = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var internalUpdate = false

    init(
        gamma: GammaControlling = GammaController(),
        getDisplayIDs: @escaping () -> [CGDirectDisplayID] = { DisplayManager.systemDisplayIDs() },
        getDisplayName: @escaping (CGDirectDisplayID) -> String = { DisplayManager.systemDisplayName(for: $0) },
        defaults: UserDefaults = .standard
    ) {
        self.gamma = gamma
        self.getDisplayIDs = getDisplayIDs
        self.getDisplayName = getDisplayName
        self.defaults = defaults
        self.intensity = defaults.object(forKey: "redlight.intensity") as? Double ?? 0.5
        self.whitepoint = defaults.object(forKey: "redlight.whitepoint") as? Double ?? 1.0
        loadPresets()
        refreshDisplays()
        startListening()
        isInitialized = true
    }

    // MARK: - Displays

    func refreshDisplays() {
        let ids = getDisplayIDs()
        let previous = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.isEnabled) })
        displays = ids.map { id in
            let wasEnabled = previous[id] ?? defaults.bool(forKey: "redlight.display.\(id).enabled")
            return DisplayInfo(id: id, name: getDisplayName(id), isEnabled: wasEnabled)
        }
        applyToActiveDisplays()
    }

    func toggle(_ displayID: CGDirectDisplayID) {
        guard let i = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[i].isEnabled.toggle()
        if displays[i].isEnabled {
            gamma.applyFilter(to: displayID, intensity: Float(intensity), whitepoint: Float(whitepoint))
        } else {
            gamma.restoreAll()
            applyToActiveDisplays()
        }
        save()
    }

    func restoreAllDisplays() {
        gamma.restoreAll()
    }

    // MARK: - Presets

    func applyPreset(_ index: Int) {
        guard index >= 0, index < presets.count else { return }
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
    }

    // MARK: - Persistence

    private func applyToActiveDisplays() {
        for display in displays where display.isEnabled {
            gamma.applyFilter(to: display.id, intensity: Float(intensity), whitepoint: Float(whitepoint))
        }
    }

    private func save() {
        defaults.set(intensity, forKey: "redlight.intensity")
        defaults.set(whitepoint, forKey: "redlight.whitepoint")
        for display in displays {
            defaults.set(display.isEnabled, forKey: "redlight.display.\(display.id).enabled")
        }
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: "redlight.presets")
        }
        defaults.set(activePresetIndex ?? -1, forKey: "redlight.activePresetIndex")
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
