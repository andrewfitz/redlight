# Redlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app that applies a pure red screen filter via gamma table manipulation, with per-display toggle and adjustable intensity.

**Architecture:** Single-process SwiftUI menu bar app. `GammaController` wraps Core Graphics gamma APIs behind a testable protocol. `DisplayManager` (@Observable) owns per-display state and persistence. `MenuBarView` renders the popover with toggles, slider, and quit.

**Tech Stack:** Swift, SwiftUI (MenuBarExtra), Core Graphics (CGSetDisplayTransferByFormula), Observation framework, UserDefaults, SMAppService

---

## File Structure

```
Redlight/
├── Package.swift                              # SwiftPM config, macOS 14+ target
├── Sources/
│   └── Redlight/
│       ├── RedlightApp.swift                  # @main, MenuBarExtra scene, AppDelegate
│       ├── GammaController.swift              # GammaControlling protocol + CG implementation
│       ├── DisplayManager.swift               # @Observable state manager + persistence
│       └── MenuBarView.swift                  # Popover UI: display toggles, slider, quit
└── Tests/
    └── RedlightTests/
        └── DisplayManagerTests.swift          # Mock-based state + persistence tests
```

---

### Task 1: Project Scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/Redlight/RedlightApp.swift`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Redlight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Redlight"),
        .testTarget(name: "RedlightTests", dependencies: ["Redlight"]),
    ]
)
```

- [ ] **Step 2: Create minimal RedlightApp.swift**

```swift
import SwiftUI

@main
struct RedlightApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("Redlight is running")
                .padding()
        } label: {
            Image(systemName: "circle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Build to verify scaffold compiles**

Run: `swift build 2>&1`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/
git commit -m "scaffold: minimal menu bar app with SwiftPM"
```

---

### Task 2: Gamma Controller

**Files:**
- Create: `Sources/Redlight/GammaController.swift`

- [ ] **Step 1: Create GammaControlling protocol and GammaController implementation**

```swift
import CoreGraphics

protocol GammaControlling {
    func applyRedFilter(to displayID: CGDirectDisplayID, intensity: Float)
    func restoreGamma(for displayID: CGDirectDisplayID)
    func restoreAll()
}

struct GammaController: GammaControlling {
    func applyRedFilter(to displayID: CGDirectDisplayID, intensity: Float) {
        _ = CGSetDisplayTransferByFormula(
            displayID,
            0, intensity, 1.0,   // red: ramp from 0 to intensity
            0, 0,         1.0,   // green: zeroed
            0, 0,         1.0    // blue: zeroed
        )
    }

    func restoreGamma(for displayID: CGDirectDisplayID) {
        // Identity gamma: linear ramp 0→1 on all channels
        _ = CGSetDisplayTransferByFormula(
            displayID,
            0, 1, 1,
            0, 1, 1,
            0, 1, 1
        )
    }

    func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/Redlight/GammaController.swift
git commit -m "feat: add GammaControlling protocol and CoreGraphics implementation"
```

---

### Task 3: DisplayManager — Core Toggle Behavior (TDD)

**Files:**
- Create: `Sources/Redlight/DisplayManager.swift`
- Create: `Tests/RedlightTests/DisplayManagerTests.swift`

- [ ] **Step 1: Write failing test — toggle on applies red filter**

Create `Tests/RedlightTests/DisplayManagerTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import Redlight

final class MockGammaController: GammaControlling {
    var applyCalls: [(displayID: CGDirectDisplayID, intensity: Float)] = []
    var restoreCalls: [CGDirectDisplayID] = []
    var restoreAllCount = 0

    func applyRedFilter(to displayID: CGDirectDisplayID, intensity: Float) {
        applyCalls.append((displayID, intensity))
    }

    func restoreGamma(for displayID: CGDirectDisplayID) {
        restoreCalls.append(displayID)
    }

    func restoreAll() {
        restoreAllCount += 1
    }
}

@Suite struct DisplayManagerTests {
    let mock = MockGammaController()

    func makeManager(
        displayIDs: [CGDirectDisplayID] = [1],
        defaults: UserDefaults? = nil
    ) -> DisplayManager {
        let d = defaults ?? freshDefaults()
        let manager = DisplayManager(
            gamma: mock,
            getDisplayIDs: { displayIDs },
            getDisplayName: { "Display \($0)" },
            defaults: d
        )
        manager.refreshDisplays()
        return manager
    }

    func freshDefaults() -> UserDefaults {
        let name = "RedlightTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func toggleOnAppliesRedFilter() {
        let manager = makeManager()
        manager.toggle(1)

        #expect(mock.applyCalls.count == 1)
        #expect(mock.applyCalls[0].displayID == 1)
        #expect(mock.applyCalls[0].intensity == 0.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter toggleOnAppliesRedFilter 2>&1`
Expected: FAIL — `DisplayManager` does not exist yet.

- [ ] **Step 3: Write minimal DisplayManager to pass**

Create `Sources/Redlight/DisplayManager.swift`:

```swift
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
    var intensity: Double = 0.5

    private let gamma: GammaControlling
    private let getDisplayIDs: () -> [CGDirectDisplayID]
    private let getDisplayName: (CGDirectDisplayID) -> String
    let defaults: UserDefaults

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
    }

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
            gamma.applyRedFilter(to: displayID, intensity: Float(intensity))
        } else {
            gamma.restoreGamma(for: displayID)
        }
        save()
    }

    func restoreAllDisplays() {
        gamma.restoreAll()
    }

    var isAnyActive: Bool {
        displays.contains(where: \.isEnabled)
    }

    private func applyToActiveDisplays() {
        for display in displays where display.isEnabled {
            gamma.applyRedFilter(to: display.id, intensity: Float(intensity))
        }
    }

    private func save() {
        defaults.set(intensity, forKey: "redlight.intensity")
        for display in displays {
            defaults.set(display.isEnabled, forKey: "redlight.display.\(display.id).enabled")
        }
    }

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter toggleOnAppliesRedFilter 2>&1`
Expected: PASS

- [ ] **Step 5: Write failing test — toggle off restores gamma**

Add to `DisplayManagerTests`:

```swift
@Test func toggleOffRestoresGamma() {
    let manager = makeManager()
    manager.toggle(1) // on
    manager.toggle(1) // off

    #expect(mock.restoreCalls.count == 1)
    #expect(mock.restoreCalls[0] == 1)
}
```

- [ ] **Step 6: Run test to verify it passes (implementation already handles this)**

Run: `swift test --filter toggleOffRestoresGamma 2>&1`
Expected: PASS (toggle logic already handles both directions)

- [ ] **Step 7: Write failing test — intensity change updates only active displays**

Add to `DisplayManagerTests`:

```swift
@Test func intensityChangeUpdatesActiveDisplaysOnly() {
    let manager = makeManager(displayIDs: [1, 2])
    manager.toggle(1) // enable display 1 only
    mock.applyCalls.removeAll()

    manager.intensity = 0.8

    #expect(mock.applyCalls.count == 1)
    #expect(mock.applyCalls[0].displayID == 1)
    #expect(mock.applyCalls[0].intensity == Float(0.8))
}
```

- [ ] **Step 8: Run test to verify it fails**

Run: `swift test --filter intensityChangeUpdatesActiveDisplaysOnly 2>&1`
Expected: FAIL — `intensity` didSet does not yet call `applyToActiveDisplays()`.

- [ ] **Step 9: Add didSet to intensity property**

In `DisplayManager`, change the `intensity` property:

```swift
var intensity: Double = 0.5 {
    didSet {
        applyToActiveDisplays()
        save()
    }
}
```

- [ ] **Step 10: Run test to verify it passes**

Run: `swift test --filter intensityChangeUpdatesActiveDisplaysOnly 2>&1`
Expected: PASS

- [ ] **Step 11: Write test — isAnyActive reflects state**

Add to `DisplayManagerTests`:

```swift
@Test func isAnyActiveReflectsToggleState() {
    let manager = makeManager(displayIDs: [1, 2])

    #expect(manager.isAnyActive == false)
    manager.toggle(1)
    #expect(manager.isAnyActive == true)
    manager.toggle(1)
    #expect(manager.isAnyActive == false)
}
```

- [ ] **Step 12: Run all tests**

Run: `swift test 2>&1`
Expected: All tests PASS

- [ ] **Step 13: Commit**

```bash
git add Sources/Redlight/DisplayManager.swift Tests/
git commit -m "feat: add DisplayManager with toggle, intensity, and mock-based tests"
```

---

### Task 4: DisplayManager — Persistence (TDD)

**Files:**
- Modify: `Tests/RedlightTests/DisplayManagerTests.swift`

- [ ] **Step 1: Write failing test — intensity persists across instances**

Add to `DisplayManagerTests`:

```swift
@Test func persistenceRoundTripsIntensity() {
    let d = freshDefaults()
    let manager1 = makeManager(defaults: d)
    manager1.intensity = 0.7

    let manager2 = DisplayManager(
        gamma: mock,
        getDisplayIDs: { [1] },
        getDisplayName: { "Display \($0)" },
        defaults: d
    )

    #expect(manager2.intensity == 0.7)
}
```

- [ ] **Step 2: Run test to verify it passes (save already called in didSet)**

Run: `swift test --filter persistenceRoundTripsIntensity 2>&1`
Expected: PASS (intensity didSet calls save(), and init reads from defaults)

- [ ] **Step 3: Write failing test — display enabled state persists**

Add to `DisplayManagerTests`:

```swift
@Test func persistenceRoundTripsDisplayState() {
    let d = freshDefaults()
    let manager1 = makeManager(displayIDs: [1], defaults: d)
    manager1.toggle(1)

    let manager2 = DisplayManager(
        gamma: mock,
        getDisplayIDs: { [1] },
        getDisplayName: { "Display \($0)" },
        defaults: d
    )
    manager2.refreshDisplays()

    #expect(manager2.displays[0].isEnabled == true)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter persistenceRoundTripsDisplayState 2>&1`
Expected: PASS (toggle calls save(), refreshDisplays reads from defaults for unknown displays)

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1`
Expected: All 6 tests PASS

- [ ] **Step 6: Commit**

```bash
git add Tests/
git commit -m "test: add persistence round-trip tests for DisplayManager"
```

---

### Task 5: Menu Bar Popover View

**Files:**
- Create: `Sources/Redlight/MenuBarView.swift`
- Modify: `Sources/Redlight/RedlightApp.swift`

- [ ] **Step 1: Create MenuBarView**

```swift
import SwiftUI

struct MenuBarView: View {
    @Bindable var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redlight")
                .font(.headline)

            Divider()

            ForEach(manager.displays) { display in
                Toggle(display.name, isOn: Binding(
                    get: { display.isEnabled },
                    set: { _ in manager.toggle(display.id) }
                ))
            }

            if manager.displays.isEmpty {
                Text("No displays detected")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Intensity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(
                    value: $manager.intensity,
                    in: 0.1...1.0
                )
            }

            Divider()

            Button("Quit") {
                manager.restoreAllDisplays()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
```

- [ ] **Step 2: Update RedlightApp to use MenuBarView and DisplayManager**

Replace `Sources/Redlight/RedlightApp.swift` with:

```swift
import SwiftUI

@main
struct RedlightApp: App {
    @State private var manager = DisplayManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: manager)
                .onAppear {
                    manager.refreshDisplays()
                }
        } label: {
            Image(systemName: manager.isAnyActive ? "circle.fill" : "circle")
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Redlight/MenuBarView.swift Sources/Redlight/RedlightApp.swift
git commit -m "feat: add menu bar popover with display toggles and intensity slider"
```

---

### Task 6: System Event Handling

**Files:**
- Modify: `Sources/Redlight/DisplayManager.swift`

- [ ] **Step 1: Add system event listeners to DisplayManager**

Add these methods to `DisplayManager`:

```swift
private var wakeObserver: NSObjectProtocol?
private var screenObserver: NSObjectProtocol?

func startListening() {
    wakeObserver = NotificationCenter.default.addObserver(
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
    if let o = wakeObserver { NotificationCenter.default.removeObserver(o) }
    if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    wakeObserver = nil
    screenObserver = nil
}
```

Add `wakeObserver` and `screenObserver` as stored properties at the top of the class (alongside the other private properties).

- [ ] **Step 2: Call startListening from RedlightApp**

In `RedlightApp.swift`, update the `onAppear`:

```swift
.onAppear {
    manager.refreshDisplays()
    manager.startListening()
}
```

- [ ] **Step 3: Build and run all tests**

Run: `swift build 2>&1 && swift test 2>&1`
Expected: Build succeeds, all tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/
git commit -m "feat: handle wake-from-sleep and display connect/disconnect events"
```

---

### Task 7: Launch at Login and Dock Icon

**Files:**
- Modify: `Sources/Redlight/RedlightApp.swift`

- [ ] **Step 1: Add AppDelegate for activation policy and launch-at-login**

Add to `RedlightApp.swift`, above the `RedlightApp` struct:

```swift
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        try? SMAppService.mainApp.register()
    }
}
```

Add the delegate adaptor to `RedlightApp`:

```swift
@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
```

Note: `SMAppService.mainApp.register()` requires the app to be code-signed. During development with `swift run`, this call will silently fail — that's fine. It activates when the app is signed and bundled (e.g., via Xcode archive).

- [ ] **Step 2: Build and run all tests**

Run: `swift build 2>&1 && swift test 2>&1`
Expected: Build succeeds, all tests pass

- [ ] **Step 3: Commit**

```bash
git add Sources/Redlight/RedlightApp.swift
git commit -m "feat: hide dock icon and register for launch at login"
```

---

### Task 8: Manual Smoke Test

- [ ] **Step 1: Build and launch the app**

Run: `swift build 2>&1 && .build/debug/Redlight &`

Verify:
- A circle icon appears in the menu bar
- Clicking it shows a popover with your display name(s), toggle(s), intensity slider, and quit button
- No dock icon visible

- [ ] **Step 2: Test toggle and intensity**

- Toggle a display on — screen should turn red
- Adjust slider — red intensity should change live
- Toggle off — screen should return to normal
- If multiple displays: toggle them independently

- [ ] **Step 3: Test persistence**

- Set intensity to a non-default value, toggle a display on
- Quit the app (via popover quit button)
- Relaunch: `.build/debug/Redlight &`
- Verify intensity and toggle state are restored

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final build verification"
```
