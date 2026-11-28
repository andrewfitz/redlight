# Redlight Stream Deck Plugin Plan

## Current controls (0.2)

Each key and dial has a Color temp unit setting. Percent is the default. Kelvin uses the calibrated target when available. The former Pause / Peek slot is now Hold to Peek. Every release sends `peek off`, regardless of duration. Pause Redlight and Resume Redlight are dedicated actions. These controls supersede the combined tap/hold gesture and Kelvin default in the original plan below.

## Goal

Build a macOS-only Stream Deck plugin that controls Redlight, mirrors its current state across every visible key and Stream Deck + display, and preserves the existing Pause-and-hold Peek behavior.

The plugin will use Redlight's existing CLI and JSON status surface. Relevant app code lives in [README.md](README.md#command-line), [CLI.swift](Sources/Redlight/Command/CLI.swift), and [RedlightCommand.swift](Sources/Redlight/Command/RedlightCommand.swift).

## Implementation status

- The Swift Peek bridge uses separate shortcut and command ownership and a four-second app-side lease. Peek was introduced in protocol 6. Sustained Stream Deck holds use the dedicated renewal command in the current protocol 8 build.
- The Stream Deck plugin uses `@elgato/streamdeck` 3.0.6 and `@elgato/cli` 1.10.5, with Toggle, Pause / Peek, Preset, Adjust, and Status actions, property inspectors, dynamic key images, channel-specific Adjust feedback, and a two-row Status layout with numeric readings and bars.
- Key and encoder status surfaces show Color Temp in kelvin when `colorKelvin` is available, with percentage fallback, plus White Point and the current operating state.
- Verification includes Swift tests, Stream Deck action and polling regressions, TypeScript typechecking, Elgato manifest validation, and a packaged-plugin smoke test with a simulated host.
- Display Control, hardware verification on a real Stream Deck, and failure-injection checks remain follow-up work.

## Before starting

The Swift files phase one edits (`RedlightCommand.swift`, `CLI.swift`, `CommandHandler.swift`, `CommandClient.swift`, `DisplayManager.swift`, `ShortcutController.swift`) carried uncommitted work before this build. The implementation preserved that working tree and limited new changes to the command, display, test, and Stream Deck paths.

## Action set

### Toggle

Tap to turn Redlight on, off, or toggle it. The key shows the current state and current Color Temp and White Point values.

`toggle` resolves against "on and not paused", so toggling while paused resumes. The key renders paused as its own state, not as off.

### Pause / Peek

Match the existing shortcut in [ShortcutController.swift](Sources/Redlight/Shortcuts/ShortcutController.swift) exactly.

- Key-down starts Peek immediately (0.15 s fade), as `pausePressed` does. It also captures whether a pause was active at that moment.
- Key-up within 350 ms is a tap. It pauses if no pause was active at key-down and resumes if one was.
- Key-up after 350 ms only ends Peek.
- Existing pause deadlines are unchanged by Peek.
- Page change (`willDisappear`), device disconnect, and plugin shutdown end Peek.
- A lost key-up, a plugin crash, a Stream Deck quit, or sleep must not leave the tint hidden. The app-side lease covers loss of the plugin or its connection. A 60-second maximum hold also ends Peek when a connected host drops only the key-up event and would otherwise keep renewing.

The tap decision and its ordering live in the app, not the plugin, because two separate CLI calls cannot reproduce the shortcut's ordering. When pausing, the shortcut pauses first and then ends Peek. When resuming, it ends Peek first and then resumes. The wrong order flashes the tint for about 150 ms.

### Preset

Apply Day, Warm, Sunset, Night, or Late. The action is configurable through a property inspector and shows the active preset plus current values.

The CLI accepts `late`, but `activePreset` in status JSON is `"deep-red"` for Late. The plugin maps it.

### Adjust

One configurable action supports Color Temp and White Point.

- Key press applies a configured step.
- Dial rotation adjusts continuously on Stream Deck +.
- Dial press resets the selected channel (`reset <color|whitepoint>`).
- Dial ticks are serialized through the shared command queue, so commands remain ordered and only one mutation is in flight.
- Steps are clamped to ±100, which `CommandHandler` enforces.

Debouncing matters beyond process count. With Adaptive and "Learn my adjustments" on, every manual Color Temp write calls `learnedNudge`, so a spun dial must not become dozens of learning events.

Color Temp can display as kelvin from `colorKelvin`, falling back to percent when kelvin is absent (tints redder than about 1,000 K).

### Status

A live dashboard action showing Color Temp target, White Point target, Adaptive state, pause state and remaining time, Peek state, active app rule, and the current status line.

### Display Control

Per-display enable, disable, and invert using display number, name, or stable display key. Phase four.

The wire protocol already has `CommandDisplaySelector.key`, but the CLI accepts only a number, a name, or `all`. Phase four adds a CLI spelling for the key, for example `display key:<uuid> on`, so a renamed or renumbered display keeps its key binding.

## Peek integration

Redlight already owns the Peek implementation through `DisplayManager.setPeeking`.

### Command

Use `RedlightCommand.peek(CommandPeek)` with four cases, spelled as words because the CLI treats leading dashes as options:

```text
redlight peek on    # acquire this source's Peek on key-down
redlight peek renew # extend a live lease while held
redlight peek off   # end this source's Peek (a hold)
redlight peek tap   # end this source's Peek and pause or resume (a tap)
```

- `peek on` requires Redlight to be on and fails with invalid input otherwise. It persists nothing and leaves pause deadlines unchanged. It records whether a pause was active at the start, the way `pauseWasActive` does, and does not overwrite that value when renewing.
- `peek tap` uses that recorded value. If no pause was active, it pauses and then ends Peek. If one was, it ends Peek and then resumes. It is a no-op returning status if no command Peek is active.
- `peek off` is a no-op returning status if no command Peek is active.

### Lease

A command Peek expires 4 s after acquisition or the last successful renewal, matching `ShortcutController.untrackedHoldLimit`. While a key is held, the plugin renews by sending `peek renew` every 1.5 s. Expiry ends only the command source. The app's lease timer guarantees a crashed or disconnected plugin cannot leave the screen untinted.

### Sources

`DisplayManager` replaces `isPeeking: Bool` with a set of sources, `shortcut` and `command`. `isPeeking` becomes "the set is non-empty". `setPeeking(_:source:)` inserts or removes one source, so releasing one cannot end another's Peek.

The CLI and every Stream Deck key share the `command` source. The plugin reference-counts held Pause / Peek keys and sends `peek off` or `peek tap` only when the last one is released.

Every existing site that clears `isPeeking` clears all sources:

- `startPause` (`DisplayManager.swift` around line 2215)
- both branches of `endPauseIntoFadeOut` (around lines 2402 and 2413)
- turning the last display off (around line 1359)

So a pause started from Stream Deck also ends a keyboard Peek, as it does today.

### Protocol and stopped app

The command protocol moves from version 5 to version 6 because the command and status schemas change. Update the version history comment on `CommandRequest.currentVersion`.

`Status` gains an optional `peeking: Bool`, absent from older apps.

In `CommandClient.execute`, the stopped-app list (`.status, .master(.off), .pause(.on), .pauseFor, .quit`) covers every Peek verb, so a key-up after Redlight quits never relaunches it.

The bridge extends [RedlightCommand.swift](Sources/Redlight/Command/RedlightCommand.swift), [CLI.swift](Sources/Redlight/Command/CLI.swift), [CommandHandler.swift](Sources/Redlight/Command/CommandHandler.swift), [CommandClient.swift](Sources/Redlight/Command/CommandClient.swift), and [DisplayManager.swift](Sources/Redlight/DisplayManager.swift). [ShortcutController.swift](Sources/Redlight/Shortcuts/ShortcutController.swift) passes the `shortcut` source.

## Live status architecture

```text
Redlight CLI
  └─ status --json

Stream Deck plugin
  ├─ RedlightClient
  ├─ serialized command queue
  ├─ StatusStore
  ├─ key action renderers
  └─ Stream Deck + feedback renderers
```

`StatusStore` polls while any action is visible, refreshes immediately after every mutation (using the mutation's own reply), and distributes one snapshot to every visible action. It allows one status request in flight and polls every 2 s while stable.

The current first build renders the pause state from `pausedUntil`. A local one-second countdown and error backoff are follow-up refinements.

### Reading status

- `on` means "on and not paused". Use `pausedUntil` to tell paused from off.
- `color.target` and `whitepoint.target` are the values the displays are heading for, including an app's Hold or Shift rule. They are endpoints, not fade frames, and they ignore pause and Peek. A paused or peeking key shows "Paused" or "Peeking", not those numbers.
- `set` is the slider value. Surface it when it differs from `target` because of a fade or an app rule.
- `activeApp` is present only while Redlight is on and an app with a rule is in front.

### Error states

Every action renders these distinctly:

- **Redlight not running:** status is exactly `{"running":false}`.
- **CLI not found:** no candidate path is executable, and the shared status store keeps the actions in the Offline state while surfacing command errors on interaction.
- **Redlight too old:** the CLI reports a protocol version mismatch or rejects `peek`; the action shows the returned error and does not relaunch a stopped app for Peek cleanup.

Every action updates its title or image from the shared status snapshot. Stream Deck keys support runtime titles and dynamic SVG images. Stream Deck + supports encoder feedback layouts and indicators. [Keys](https://docs.elgato.com/streamdeck/sdk/guides/keys/), [Dials and Touch Strip](https://docs.elgato.com/streamdeck/sdk/guides/dials/)

## CLI discovery

In order:

1. The `REDLIGHT_CLI_PATH` environment override, for development against a debug build.
2. `/opt/homebrew/bin/redlight`.
3. `/usr/local/bin/redlight`.
4. `/Applications/Redlight.app/Contents/MacOS/Redlight` and `~/Applications/Redlight.app/Contents/MacOS/Redlight`. `EntryRouter.isCLI` treats any argument outside LaunchServices' own as a CLI invocation, so the bundle executable works directly.

The two symlinks are the locations `CLIInstaller` uses.

## Project layout

```text
StreamDeck/
  package.json
  tsconfig.json
  rollup.config.mjs
  src/
    plugin.ts
    redlight/
      client.ts
      status.ts
      command-queue.ts
      peek-lease.ts
    actions/
      toggle.ts
      pause-peek.ts
      preset.ts
      adjust.ts
      status.ts
      display.ts (phase four)
  com.redlight.app.streamdeck.sdPlugin/
    manifest.json
    bin/
    imgs/
    ui/ (bundled property inspectors)
```

The plugin will be separate from the Swift package.

## Implementation phases

### Phase one (Swift)

- Add protocol version 6 and `Status.peeking`.
- Add source-aware Peek state, clearing all sources at every existing reset site.
- Add `peek on|off|tap` with the app-side tap ordering and the 4 s command lease.
- Add the stopped-app cases for `peek`.
- Add Swift tests:
  - Peek ownership across sources.
  - Lease expiry and renewal, including that renewal keeps the original pause state.
  - Pause preservation through Peek.
  - Tap ordering, with no tint frame between pausing and ending Peek.
  - Stopped-app behavior.
  - Status and wire encoding.

### Phase two (plugin core)

- Scaffold the TypeScript plugin.
- Implement CLI path discovery with the environment override.
- Implement the serialized command client.
- Implement the shared status store and the error states.
- Implement Toggle and Status rendering.

### Phase three (actions)

- Implement Pause / Peek: key-down sends `peek on`, renewal every 1.5 s while held, and key-up sends `peek tap` or `peek off`. Count held keys, and end Peek on `willDisappear` and plugin shutdown.
- Implement Preset (including the `deep-red` mapping) and Adjust (with the debounced, clamped step).
- Add property inspectors.
- Add dynamic key images and status fan-out.
- Exclude Pause / Peek from multi-actions because hold duration has no reliable multi-action lifecycle.

### Phase four (Stream Deck + and displays)

- Add Stream Deck + dial feedback. (Implemented in the initial build.)
- Add Display Control.
- Add a CLI spelling for `CommandDisplaySelector.key`.
- Add action disappearance and device disconnect cleanup.
- Add default profile assets.

### Phase five (verification)

- Run Swift and TypeScript tests.
- Validate and package the plugin.
- Test by hand:
  - keypad actions and Stream Deck + feedback
  - external keyboard Peek together with Stream Deck Peek
  - killing the plugin mid-hold (the tint must return within 4 s)
  - CLI changes, fades, pause countdowns, and app rules
  - Redlight stopped, and an older Redlight installed

## Stream Deck compatibility

The initial manifest will use the current documented baseline.

- Node.js 24.
- Stream Deck 7.1 or later.
- macOS 14 or later, matching Redlight.
- `SDKVersion` 2 for the initial plugin.
- UUID `com.redlight.app.streamdeck`.
- `SupportedInMultiActions: false` for Pause / Peek.
- `layouts/status.json` for Stream Deck + dual-indicator feedback with readable numeric targets.
- `setFeedback` values keyed as `title`, `color`, `whitepoint`, `indicator1`, and `indicator2`.

The manifest supports `SupportedInMultiActions`, Node.js 24, the 7.1 minimum, and encoder layouts. The current SDK documents `$C1` as a two-indicator layout and `setFeedback` as the runtime update API. [Manifest reference](https://docs.elgato.com/streamdeck/sdk/references/manifest/), [Getting Started](https://docs.elgato.com/streamdeck/sdk/introduction/getting-started/), [Dials and Touch Strip](https://docs.elgato.com/streamdeck/sdk/guides/dials/)

## Acceptance criteria

- Pause / Peek starts revealing true colors on key-down, like the existing shortcut.
- A short press pauses or resumes exactly like the shortcut, with no tint flash.
- A long hold restores the tint on release.
- Existing pause deadlines survive Peek.
- Keyboard Peek and Stream Deck Peek coexist; releasing one never ends the other.
- A crashed or disconnected plugin cannot leave the tint hidden for more than 4 s.
- A Peek release never launches a stopped Redlight.
- Every action rendered by default shows current Color Temp and White Point values, or a clear paused, peeking, not running, or update state.
- Stream Deck + displays show both values with progress indicators.
- Changes from Redlight, the CLI, shortcuts, or another action propagate to every visible action.
- Dial adjustments remain ordered and responsive, and do not flood "Learn my adjustments".
- The plugin requires no additional macOS permission for normal CLI operation.
- The plugin targets macOS 14 or later with Node.js 24, Stream Deck 7.1 or later, and manifest SDKVersion 2.
