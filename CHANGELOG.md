# Changelog

## Unreleased

- Added a Pause button next to the main switch. It suspends the tint for 30 minutes without changing which displays are enabled, keeps Invert on, survives sleep and relaunch, and resumes with a fade. Commands and Control Center report Redlight as off while paused.
- Added customizable system-wide keyboard shortcuts for on/off, Pause, Warmer/Cooler, White Point, Light/Dark, Adaptive and each preset, assigned in a Keyboard Shortcuts window. Nothing is assigned by default; suggested ⌥⌘ shortcuts are one click away. Tapping the Pause shortcut pauses and holding it shows true colors until release. Steps repeat while held and show a brief readout. No extra permissions are required.
- Added `redlight color|whitepoint up|down [step]`, `redlight pause` and `redlight resume`. The command protocol is now version 2; an older running app asks to be updated.
- Fixed local ad-hoc builds crashing at launch when signed with the hardened runtime.

## 1.4 - 2026-10-25

- Added automatic Sidecar filtering through the existing Color, White Point, Invert, presets, and Adaptive controls. The iPad is filtered in the Mac's compositor without screen recording or iPad setup.
- The pointer is tinted on Sidecar too. Redlight hides the system pointer while it is over a filtered iPad and draws the current cursor beneath the filter.
- Fixed the Color and White Point sliders. Clicking the track moves the value instead of a nearby limit, limits no longer stay grabbed or keep previewing after the mouse is released in the menu, and dragging the thumb outward from a limit moves that limit.
- Cached display routing and unchanged Sidecar output to avoid repeated display queries and filter submissions. Display and backing-scale changes invalidate the caches and refresh the compositor surface.
- Fixed repeated retries when a compositor API is unavailable and cleaned up notification observers when windows are released.
- Fixed the Xcode 27 process-ownership test worker launcher so the complete test suite can run.

## 1.3.1 - 2026-10-07

- Fixed an oversized settings window appearing when checking for updates.
- Updated the compact menu bar icon with a circular sun behind a monitor. The inner screen is 70% opaque with an active filter and 10% opaque when inactive.
- Added changelog release notes to the update dialog and GitHub. Both use the matching release entry from this file.

## 1.3 - 2026-10-07

- Control Redlight from the command line, Siri, Shortcuts, and Control Center on macOS 26 or later.
- Use the master switch to restore the displays you previously enabled.
- Run a single copy of Redlight across app locations, with commands routed to the running owner.
- Install the `redlight` command automatically when the app runs from Applications.
- Interrupt slider previews when a command changes the filter, so the command takes effect immediately.
- Keep the Adaptive sun chart and its guides on the same elevation scale.
- Show automatically increasing build numbers consistently in About, CLI output, and status.
