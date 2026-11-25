# Changelog

## Unreleased

- **Clear by**, a wake time for Auto, under Deepest by in Settings: the filter is back at its clearest by that time, even before sunrise, and stays there until solar noon. With it on, Deepest by holds through the night until the wake time instead of lifting from solar midnight, and a bedtime after solar midnight now counts. Also `redlight adaptive wake <HH:MM|off>`, `wake` in `status --json`, and the Shortcuts actions Set Redlight Wake Time and Turn Off Redlight Wake Time. The command protocol is now version 4.
- **Keep Night Shift off**, in Settings: Redlight turns Night Shift off whenever it comes on, so the two tints do not stack. Night Shift's schedule is not changed. Shown on Macs whose display supports Night Shift.
- Auto no longer jumps at solar noon in high-latitude winter. Where the sun peaks below +12° (north of about 55° in midwinter) the evening curve used to start part-way down: a step of up to 35% in Color temp at noon, on up to 94 days a year in Reykjavik. The evening's Day anchor now comes down to meet the noon sun.
- Auto now works under the midnight sun and through the polar night. Where the sun stays above −6° at solar midnight the curve slides up, so the night still reaches Late; before, the first night the sun did not set went from fully red to half, with a jump at solar midnight. Where the sun peaks below +4° the curve slides down, so noon still reaches Day. Latitudes below about 54° are unchanged.
- Sunrise and sunset under the sun arc, the countdown to them and **Until sunrise** use the apparent horizon, as almanacs do. They were 3 to 7 minutes off at mid-latitudes and more near the polar circles.
- The time-zone fallback for Auto's location knows every time zone's city (418, from the tz database) instead of about 100 and a guess by region, which put a few zones in the wrong hemisphere.
- A location fix is followed only while the Mac stays on the UTC offset it was taken in. After a move to another time zone, Auto follows that zone's city until a new fix arrives, instead of the old city's sun.
- Redesigned the menu bar popover. Displays are at the top, each with its Invert control. **Auto** follows the sun and shows the sun arc; **Manual** shows the presets and holds a setting. Sliders show their value as a percentage.
- Pause and the light/dark switch sit in the header beside the main switch. While paused, the Pause button shows the time left, counting down. Deepest by, Launch at Login, Pause for apps, Keyboard Shortcuts, location, Updates, About and Quit moved to a Settings page inside the popover, opened from the bottom of it.
- New menu bar icon: a setting sun. It is an outlined ring when no filter is showing, and a solid disc with one, two or three lines across it as the filter deepens. The part of the disc under each line is drawn at half strength. With only Invert showing it is the solid disc with no line.
- New app icon: a red sun setting behind a beige CRT monitor with a red screen, under a starry sky.
- Renamed the Deep Red preset to **Late**. A saved preset still named Deep Red is renamed on launch. `redlight preset late` is the new spelling; `deep-red` keeps working. `status --json` still reports `deep-red`; plain `status` and the Shortcuts status text now say `late`. Existing Shortcuts and keyboard shortcuts are unaffected.
- The Location row names where Auto's location comes from: Automatic, Time zone, Last known or Manual. A bedtime that is too early or too late to take effect is no longer shown as active.
- Sliders are easier to use: press anywhere on one to set it there, and drag to either end for exactly 0% or 100%. Arrow keys step 1%, Shift steps 10%, Home and End go to the ends.
- In Auto, each slider's minimum and maximum are labelled flags under the track. Drag a flag to change a limit and preview it; drag the value past a flag and the flag moves with it. Drag one flag onto the other and they merge into one “Fixed” flag that holds the slider at that value, including at 0% or 100%; drag it to either side to open the range again.
- Slider colors show the setting. In dark appearance the Color temp slider runs from white at 100% to red at 0%, and the White point slider is the same color at 100% and dimmer and less vivid as it goes down: a grey under white, a duller red under red. In light appearance the scale stays deep, because white does not show on the pale panel; the White point slider fades there instead.
- While an Auto limit flag is dragged, the popover's colors follow the limit, as the screen does, instead of waiting for the drag to pause. Pressing a flag without moving it previews its limit too.
- When an update is waiting, the Settings row at the bottom of the popover says **Update available**. A new **Update automatically** switch in Settings downloads new versions in the background and installs them when Redlight next quits.
- Switching between Auto and Manual slides the pane under the control sideways with the selected segment, and the popover changes height in step. The controls above no longer jump while it resizes. Settings and About slide in from the right the same way, and Back slides them away.
- **White point now runs from 0 to 100%** in the popover, the CLI, `status` and Shortcuts, like Color temp. Nothing changes on screen: 0% is the same strongest reduction that used to be called 25%, and saved settings and presets look as they did. Scripts and Shortcuts that set a white point or its limits need new numbers: new = (old − 25) ÷ 0.75, so 25 becomes 0, 50 becomes 33 and 100 stays 100. The default presets now read 100, 80, 53, 27 and 7%. The Dimmer and Brighter shortcuts step 5% of the new scale.
- Auto's default White point minimum is now 50%, so a night in Auto dims the screen to half the scale and no further unless you lower the flag. A minimum you already have is kept; Reset beside White point takes it to the new default.
- Reset beside a slider's value is a circular-arrow button.
- The popover is more compact: about a quarter shorter in Auto.
- The popover redraws about twice as fast while a slider is dragged.
- Slider handles, switches and buttons stay readable with the Late preset on, in light and dark appearance. Text and marks are stronger with Increase Contrast on.

## 1.5.1 - 2026-11-22

- Preserved native display calibration resolution and fixed stale slider previews when switching controls.
- Fixed repeated solar events, adaptive adjustments lost after location recovery, and fractional CLI steps that could move a setting in the wrong direction.

## 1.6 - 2026-11-21

- The menu bar popover now accepts keyboard input, grows as sections expand, and scrolls on shorter screens. Press Return to save a manual location, or use the arrow keys to adjust a focused slider or band limit.
- Drag the center of an existing pinned slider to move its fixed value. Drag a bracket tip to widen the band. You can set an exact pin with equal limits, such as `redlight limits whitepoint 80 80`.
- Display fades reuse calibration samples and gamma table buffers. In a benchmark of 200,000 frames across three simulated displays, gamma table preparation dropped from 3.375 seconds to 0.239 seconds with matching output.
- Fixed redundant ColorSync resets during wake and shutdown. Connecting a monitor while Redlight is quitting no longer applies a fresh tint. The Sidecar pointer updates when the overlay geometry changes.
- **Until sunrise** now resumes at the calculated sunrise even when it is less than a minute away or more than 24 hours away. The deadline survives relaunch and clock changes. Adaptive also handles brief sunrise and sunset crossings near the polar circles.
- Fixed stale location callbacks after cancellation and incorrect bedtime tint during the midnight sun. The sun arc reuses the day's samples between refreshes.
- Fixed shortcut conflicts, repeated toggle events, and Pause holds that could get stuck after a missed key release.
- The CLI handles simultaneous launches more reliably. Control Center retries preserve the result of the original request, so an older retry cannot undo a newer toggle.
- Release builds now use the tagged commit's source and locked dependencies. The Sparkle feed and GitHub download use the same disk image.

## 1.5 - 2026-11-18

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
- Fixed excess tint after a failed calibration read and incorrect filter settings when macOS reuses a display ID. Sidecar also keeps a single visible pointer when macOS declines to hide it.
- Holding the Pause shortcut now preserves an existing pause and its deadline. Suggested shortcuts respect combinations reserved by macOS.
- Fixed blank controls after quickly reopening the menu, stale app suspension after wake, and appearance toggles that missed a recent system change.
- Corrected the sun arc on days that skip local midnight and caught solar events at the edge of the search window.
- Improved Control Center handoffs after clock changes, CLI feedback for incompatible app versions, and update checks while Sparkle is busy.

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
