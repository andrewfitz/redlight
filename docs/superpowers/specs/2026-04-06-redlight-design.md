# Redlight - Deep Red Screen Filter for macOS

## Overview

A private macOS menu bar app that applies a pure red screen filter by manipulating display gamma tables. Unlike Night Shift (which caps at orange), Redlight zeroes out green and blue channels entirely, producing a true red-only display. Supports multiple displays with independent per-display toggle and a shared intensity slider.

## Requirements

- Pure red output: zero blue, zero green light emission
- Adjustable red intensity (0.1–1.0)
- Per-display on/off toggle
- Menu bar icon with popover UI
- Remembers last-used intensity and per-display state across launches
- Launches at login automatically
- No dock icon
- Built with Swift, SwiftUI, and macOS 26 (Tahoe) APIs

## Architecture

Single-process SwiftUI menu bar app with three layers:

### GammaController

Wraps Core Graphics gamma APIs. Responsible for applying and restoring gamma on a single display.

- **Apply filter:** `CGSetDisplayTransferByFormula(displayID, 0, intensity, 1.0, 0, 0, 1.0, 0, 0, 1.0)`
  - Red channel: `min = 0, max = intensity, gamma = 1.0`
  - Green channel: `min = 0, max = 0, gamma = 1.0`
  - Blue channel: `min = 0, max = 0, gamma = 1.0`
- **Restore single display:** Call `CGDisplayRestoreColorSyncSettings()` (global, no per-display parameter), then re-apply filter to any other still-active displays. This preserves custom ICC color profiles.
- Stateless — receives display ID and intensity, applies or restores.

### DisplayManager

Manages the set of connected displays and their filter state.

- Detects displays via `CGGetActiveDisplayList`
- Listens for display configuration change notifications (`CGDisplayRegisterReconfigurationCallback`) to handle connect/disconnect
- Holds per-display state: display ID, display name, on/off
- Holds shared intensity value (0.1–1.0)
- On display disconnect: removes state for that display
- On display reconnect: reapplies filter if it was previously on
- Listens for `NSWorkspace.didWakeNotification` to reapply gamma after sleep (macOS resets gamma tables on wake)
- Persists state to `UserDefaults`: intensity value and per-display on/off keyed by display ID

### MenuBarUI

SwiftUI `MenuBarExtra` with a popover.

- **Menu bar icon:** SF Symbol `circle.fill`, tinted red when any display filter is active, gray when all are off
- **Popover contents:**
  - One row per connected display: display name (from `NSScreen.localizedName`) + toggle switch
  - Shared intensity slider (0.1–1.0), live-updates any active displays when moved
  - Quit button
- No dock icon: configured via `App` scene or `LSUIElement` in Info.plist

## Persistence

- `UserDefaults` stores:
  - `redlight.intensity` (Double, default 0.5)
  - `redlight.displays.<displayID>.enabled` (Bool per display)
- Read on launch, written on every change

## Launch at Login

- Uses `SMAppService.mainApp.register()` (modern macOS API, no helper app)
- Registered on first launch, user can disable via System Settings > Login Items

## Edge Cases

| Scenario | Behavior |
|---|---|
| App quit | Restore all displays to original gamma |
| Display disconnected | Remove from UI, clean up state |
| Display reconnected | Reappear in UI, reapply filter if previously on |
| Wake from sleep | Reapply gamma to all active displays |
| Another app resets gamma | Not actively defended; user re-toggles if needed |
| All displays toggled off | Menu bar icon turns gray |
| Intensity set to minimum (0.1) | Very dim red — screen nearly black |
| Intensity set to maximum (1.0) | Full brightness red channel, zero green/blue |

## Tech Stack

- **Language:** Swift
- **UI Framework:** SwiftUI (MenuBarExtra)
- **Gamma API:** Core Graphics (`CGSetDisplayTransferByFormula`, `CGDisplayRestoreColorSyncSettings`, `CGGetActiveDisplayList`, `CGDisplayRegisterReconfigurationCallback`)
- **Persistence:** UserDefaults
- **Launch at login:** SMAppService
- **Target:** macOS 26 (Tahoe)
- **Build system:** Xcode / Swift Package Manager

## Out of Scope

- Scheduling / timers
- Color temperature adjustment
- Keyboard shortcuts
- Preferences window
- Night Shift integration
- App Store distribution
