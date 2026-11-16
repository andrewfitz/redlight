# Changelog

## 1.5 - 2026-11-15

- Added Pause for apps. Choose apps in the popover, or with `redlight apps add|remove|list|clear <bundle-id>`, and the tint fades out while one of them is in front and back when you switch away. Invert stays on. Redlight still counts as on; the header and `status` show “suspended for” and the app's name.
- Added pause lengths. The chevron beside the Pause button offers 30 minutes, 1 hour, 2 hours and Until sunrise, and `redlight pause <minutes>` and `redlight pause until sunrise` accept anything from 1 minute to 24 hours. Plain Pause is still 30 minutes. Long pauses count down in hours and minutes in the popover.
- Added a bedtime for Adaptive. **Deepest by**, or `redlight adaptive bedtime <HH:MM|off>`, ramps the filter to the deepest end of your limits over the two hours before the chosen time and holds it until solar midnight. It only ever makes the evening redder, and mornings are unchanged. The sun arc and status line show it.
- Added manual location. Enter a latitude and longitude under Adaptive, or run `redlight location <latitude> <longitude>`, and Redlight stops using Location Services and no longer asks for permission. `redlight location auto` switches back.
- Added a next solar event countdown, such as “Sunset in 1 h 12 m”, under the Adaptive status.
- Presets now fade over two seconds whether or not Adaptive was on, instead of jumping.
- Added Shortcuts actions for pause length, pause until sunrise, bedtime, location and pause for apps.
- The command protocol is now version 3, so an older running app asks to be updated. `status --json` adds optional `locationSource`, `bedtime`, `suspendedFor` and `apps` fields.
- Adaptive now retries for a precise location once an hour instead of once a minute.
- Fixed the main switch doing nothing when a pause outlived its only enabled display.
- Fixed a brief fade from a stale value at launch when a location arrived immediately.
- Fixed Use Suggested Shortcuts leaving the same combination on two actions.
- Fixed a held Warmer/Cooler shortcut stopping its repeat when you rolled onto another step key.
- Reduced work when closing the popover, showing the shortcut readout, opening Keyboard Shortcuts and answering `status`.

## 1.4.1 - 2026-10-27

- Improved recovery when an external monitor wakes or reconnects, addressing excessive red tint and a screen split between tinted and clear halves. Redlight now handles display-only wake and hardware mode changes even when the display ID stays the same, and resets color calibration again after the connection settles.
- Wake recovery respects changes made while the monitor reconnects, including turning the filter off.

## 1.4 - 2026-10-26

- Added Sidecar support. iPads are filtered automatically with the same Color Temp, White Point, Invert, presets and Adaptive controls, in the Mac's compositor without screen recording or iPad setup. The pointer is tinted too.
- Added a Pause button next to the main switch. It suspends the tint for 30 minutes with a minutes countdown, keeps Invert on, survives sleep and relaunch, and fades back when time is up. Commands and Control Center report Redlight as off while paused.
- Added customizable system-wide keyboard shortcuts for on/off, Pause, Warmer/Cooler, White Point, Light/Dark, Adaptive and each preset, in a new Keyboard Shortcuts window. Nothing is assigned by default; suggested ⌥⌘ shortcuts are one click away. Tap the Pause shortcut to pause, or hold it to see true colors until release. Steps repeat while held and show a brief readout. No extra permissions are required.
- Added Siri and Shortcuts actions to pause, resume, and adjust the filter: “Pause Redlight”, “Resume Redlight”, and “Make Redlight warmer” (or cooler, dimmer, brighter).
- Added `redlight color|whitepoint up|down [step]`, `redlight pause` and `redlight resume`. The command protocol is now version 2, so an older running app asks to be updated.
- Fixed the sliders. Clicking the track moves the value instead of a nearby limit, limits no longer stay grabbed or keep previewing after the mouse is released, and dragging the thumb outward from a limit moves that limit.
- Added fixed values under Adaptive. A slider's limits can now meet, anywhere including 0 or 100%, to pin it while the other slider keeps following the sun. Moving a pinned slider, from the menu, a shortcut, Siri or the command line, moves the pin. `redlight limits` accepts equal limits, and status shows “fixed at”.
- Renamed the Color slider to Color Temp. The `color` command and JSON fields keep their names.

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
