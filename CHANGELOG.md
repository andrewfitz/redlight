# Changelog

## 2.0.0 - 2026-11-27

Redlight 2.0 is a redesign: a new popover, menu bar icon and app icon, one colour scale for light and dark, and slides between its pages drawn by Core Animation. It adds Saturation, colour temperature in kelvin, rules for each app, Learn my adjustments, a wake time for Auto and a Stream Deck plugin.

- **Saturation**, a slider with its own switch under White point: from full colour at 100% down to grayscale at 0%, applied before the red filter and White point, so a gray image is then tinted. Off by default; the switch keeps the level you set. Also `redlight saturation <0-100|on|off|toggle|up|down>`, `saturation` in `status --json` and a Shortcuts action.
- **Stream Deck plugin** (in `StreamDeck/`, for Stream Deck 7.1 or later on macOS 14 or later): Toggle, Pause / Peek (tap to pause or resume, hold to see true colours until you let go), Preset, Adjust (a step per press, or a dial on Stream Deck +, press the dial to reset) and a live Status key. Keys show the current state and values, Color temp in kelvin where it has one. It drives the app through the `redlight` command, with a new `redlight peek <on|off|tap|renew>` behind Pause / Peek.
- **Per-App**, the card for app rules, is now on the popover above Settings. Folded, it shows the icons of the apps with a rule, overlapping, up to 12 (or 11 and a count); open, each app is one row with its rule and a way to remove it.

- Light and dark use the same colours: the tint scale runs from a barely warm white at 100% through peach and orange to Late's red in both. Light had a darker scale of its own that turned mustard and brick. On the pale panel, a fill as pale as the top of the scale (the Day swatch, a slider or switch at 100%) has a faint edge, and the sun arc's line deepens just enough to stay visible. The White point slider dims toward grey in both appearances.
- **Show color temp as** % or K, a new setting under Units. In kelvin, Color temp and its limit flags show the colour temperature the displays actually show, worked out from the first tinted display's colour profile: 100% is the display's own white, D65 or about 6,500 K on a standard or Apple display, and the tint follows the blackbody curve all the way down: 0% reads as the display's red primary, about 990 K on an sRGB display, 820 K on Display P3 and lower on wider-gamut displays. White point stays a percent. On the command line, `redlight color 3400K` sets Color temp by kelvin and `redlight limits color 1200K 6500K` sets Auto's limits by kelvin, on the same display; `redlight status` adds the kelvin to the Color temp line ("Color temp: 78.3%, 3,200 K") and `status --json` reports `colorKelvin`.
- The sun arc's line is thicker, so the tint along it is easier to see.
- Launch at login is on for a new install: the first launch of a copy in Applications, with no Redlight settings saved before, adds it to Login Items. Switching it off keeps it off, and an existing install keeps what it has.
- **Apps** replaces Pause for apps: each app you choose gets a rule for while it is in front. **Pause** hides the tint, as before. **Hold** shows a Color temp and White point of its own, whatever Auto or Manual is doing, for an app that needs one steady look. **Shift** adds a signed amount to whatever Auto or Manual shows, so the app follows the sun a little warmer or cooler; in Auto it stays inside your limit flags and leaves a Fixed slider alone. Pause, a peek and Off still win over any rule, and a peek always shows the screen with no tint. Switching apps fades to the new rule in 0.4 s from what is on screen, however quickly you switch. Settings lists each app with its rule and, for Hold and Shift, its two amounts in steps of 5%. Opening the popover over an app with a Hold or Shift says so above the sliders ("Photoshop: Hold"), and the sliders set that rule until you choose **Edit Auto instead**; the Warmer, Cooler, Dimmer and Brighter keyboard shortcuts also change the rule of the app in front. The command line and Shortcuts stay global: `redlight color 40` changes Auto or Manual, never a rule. Time in an app with a Pause or Hold does not count for Learn my adjustments, time in an app with a Shift counts as if the shift were not there, and editing a rule is never something learned. Apps chosen for Pause for apps are not carried over: choose them again in Settings. Commands: `redlight apps set <bundle-id> pause | hold <color> <white> | shift <±color> <±white>`, `apps remove <bundle-id>`, `apps list` (one rule per line) and `apps clear`; `apps add` is gone. While an app with a rule is in front, the status line in `redlight status` and the Shortcuts status ends with " · Photoshop: hold". `status --json` reports `appRules` and `activeApp` in place of `apps` and `suspendedFor`. Shortcuts actions Set Redlight App Rule, Remove Redlight App Rule, List Redlight App Rules and Clear Redlight App Rules replace the four Pause for apps actions.
- **Learn my adjustments**, a switch for Auto under Clear by in Settings, on by default. With it on, a change you make to a slider in Auto belongs to that part of the sun's day: go redder around sunset on a few evenings and that part of the curve stays redder, at every season and in every time zone. A first change still moves the whole curve, as before. Where Auto already knows your habit, a change of more than 8% has to be made on two days to stick, so a guest or a film night is gone the next morning; a smaller one is kept at once. The limit flags follow what you keep at midday and late at night, so leaving Color temp at 90% by day moves the max flag to 90%. A flag you move yourself always wins. What was learned is applied when nobody is at the screen (asleep, locked, or half an hour idle with no video playing), or 12 hours past 04:00 if someone always is. Settings draws what was learned, a line for each slider through the day over Auto's own curve, and has **Reset learning**, which asks first and keeps a backup: `redlight learn restore` brings back the last reset (five are kept). Also `redlight learn <on|off|toggle|reset|restore>`, `learning` in `status --json`, the same sentences in `redlight status` and the Shortcuts status, " · learned" in the status line, and the Shortcuts actions Set Redlight Learning and Reset Redlight Learning. The command protocol is now version 5.
- The sun arc is drawn in the tint Auto will show at each time of day, white by day (gold in the light appearance) and red at night, and as bright as White Point will be, as the White Point slider's own fill is: dimmer at night with the default limits. It includes your limits and what was learned. It was one colour from end to end.
- **Clear by**, a wake time for Auto, under Deepest by in Settings: the filter is back at its clearest by that time, even before sunrise, and stays there until solar noon. With it on, Deepest by holds through the night until the wake time instead of lifting from solar midnight, and a bedtime after solar midnight now counts. Also `redlight adaptive wake <HH:MM|off>`, `wake` in `status --json`, and the Shortcuts actions Set Redlight Wake Time and Turn Off Redlight Wake Time. The command protocol is now version 4.
- **Keep Night Shift off**, in Settings and on by default: Redlight turns Night Shift off whenever it comes on, so the two tints do not stack. Night Shift's schedule is not changed. Shown on Macs whose display supports Night Shift.
- Auto no longer jumps at solar noon in high-latitude winter. Where the sun peaks below +12° (north of about 55° in midwinter) the evening curve used to start part-way down: a step of up to 35% in Color temp at noon, on up to 94 days a year in Reykjavik. The evening's Day anchor now comes down to meet the noon sun.
- Auto now works under the midnight sun and through the polar night. Where the sun stays above −6° at solar midnight the curve slides up, so the night still reaches Late; before, the first night the sun did not set went from fully red to half, with a jump at solar midnight. Where the sun peaks below +4° the curve slides down, so noon still reaches Day. Latitudes below about 54° are unchanged.
- Sunrise and sunset under the sun arc, the countdown to them and **Until sunrise** use the apparent horizon, as almanacs do. They were 3 to 7 minutes off at mid-latitudes and more near the polar circles.
- The time-zone fallback for Auto's location knows every time zone's city (418, from the tz database) instead of about 100 and a guess by region, which put a few zones in the wrong hemisphere.
- A location fix is followed only while the Mac stays on the UTC offset it was taken in. After a move to another time zone, Auto follows that zone's city until a new fix arrives, instead of the old city's sun.
- Redesigned the menu bar popover. Displays are at the top, each with its Invert control. **Auto** follows the sun and shows the sun arc; **Manual** shows the presets and holds a setting. Sliders show their value as a percentage.
- Pause and the light/dark switch sit in the header beside the main switch. While paused, the Pause button shows the time left, counting down. Deepest by, Launch at Login, Apps, Keyboard Shortcuts, location, Updates, About and Quit moved to a Settings page inside the popover, opened from the bottom of it.
- New menu bar icon: a setting sun. It is the whole sun when there is no filter to show: when Redlight is off, when Color temp is at 100%, and when only Invert is showing. It has one line across it from 99% down, two from 66% and three from 33%. Under the lines is the sea, drawn faded: with each line the sun above is a little smaller and the sea a little wider, like a sun going down over the water.
- New app icon: a beige 1990s CRT monitor, with a red sun setting over the sea on its screen and a small Redlight badge and power button below.
- Renamed the Deep Red preset to **Late**. A saved preset still named Deep Red is renamed on launch. `redlight preset late` is the new spelling; `deep-red` keeps working. `status --json` still reports `deep-red`; plain `status` and the Shortcuts status text now say `late`. Existing Shortcuts and keyboard shortcuts are unaffected.
- The Location row names where Auto's location comes from: Automatic, Time zone, Last known or Manual. A bedtime that is too early or too late to take effect is no longer shown as active.
- Sliders are easier to use: press anywhere on one to set it there, and drag to either end for exactly 0% or 100%. Arrow keys step 1%, Shift steps 10%, Home and End go to the ends.
- In Auto, each slider's minimum and maximum are labelled flags under the track. Drag a flag to change a limit and preview it; drag the value past a flag and the flag moves with it. Drag one flag onto the other and they merge into one “Fixed” flag that holds the slider at that value, including at 0% or 100%; drag it to either side to open the range again.
- Slider colors show the setting. In dark appearance the Color temp slider runs from white at 100% to red at 0%, and the White point slider is the same color at 100% and dimmer and less vivid as it goes down: a grey under white, a duller red under red. In light appearance the scale stays deep, because white does not show on the pale panel; the White point slider fades there instead.
- While an Auto limit flag is dragged, the popover's colors follow the limit, as the screen does, instead of waiting for the drag to pause. Pressing a flag without moving it previews its limit too.
- When an update is waiting, the Settings row at the bottom of the popover says **Update available**. A new **Update automatically** switch in Settings downloads new versions in the background and installs them when Redlight next quits. It is on unless you switch it off.
- Switching between Auto and Manual slides the pane under the control sideways with the selected segment, and the popover changes height in step. The controls above no longer jump while it resizes. The slides between Auto and Manual and to Settings and back are smooth at any display rate: they are pictures moved by Core Animation, which the display draws at its own rate, while the panes underneath swap at once, so SwiftUI does no work during a slide. The selected segment of the mode switch and of the other switches slides the same way. The popover's top edge no longer wobbles as its height changes, and a Settings page taller than the controls is no longer cut across at the controls' height while it slides in. Auto, Manual, Settings and About are each built once per opening of the popover and kept, so Settings keeps what was typed or opened in it until the popover closes (leaving Settings for the controls still puts unsaved coordinates back). Tab no longer reaches the Deepest by and Clear by fields of a page that is out of sight.
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
