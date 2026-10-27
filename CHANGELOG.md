# Changelog

## 1.4 - 2026-10-26

- Added Sidecar support. iPads are filtered automatically with the same Color Temp, White Point, Invert, presets and Adaptive controls, in the Mac's compositor without screen recording or iPad setup. The pointer is tinted too.
- Added a Pause button next to the main switch. It suspends the tint for 30 minutes with a minutes countdown, keeps Invert on, survives sleep and relaunch, and fades back when time is up. Commands and Control Center report Redlight as off while paused.
- Added customizable system-wide keyboard shortcuts for on/off, Pause, Warmer/Cooler, White Point, Light/Dark, Adaptive and each preset, in a new Keyboard Shortcuts window. Nothing is assigned by default; suggested ⌥⌘ shortcuts are one click away. Tap the Pause shortcut to pause, or hold it to see true colors until release. Steps repeat while held and show a brief readout. No extra permissions are required.
- Added Siri and Shortcuts actions to pause, resume, and adjust the filter: “Pause Redlight”, “Resume Redlight”, and “Make Redlight warmer” (or cooler, dimmer, brighter).
- Added `redlight color|whitepoint up|down [step]`, `redlight pause` and `redlight resume`. The command protocol is now version 2, so an older running app asks to be updated.
- Fixed the sliders. Clicking the track moves the value instead of a nearby limit, limits no longer stay grabbed or keep previewing after the mouse is released, and dragging the thumb outward from a limit moves that limit.
- Added fixed values under Adaptive. A slider's limits can now meet, anywhere including 0 or 100%, to pin it while the other slider keeps following the sun. Moving a pinned slider, from the menu, a shortcut, Siri or the command line, moves the pin. `redlight limits` accepts equal limits, and status shows “fixed at”.
- Renamed the Color slider to Color Temp. The `color` command and JSON fields keep their names.
- Releases are now notarized by Apple, so they open without Gatekeeper warnings.

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
