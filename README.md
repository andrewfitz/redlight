# Redlight

A macOS menu bar app that applies a red screen filter by manipulating display gamma tables. Goes deeper than Night Shift — removes blue and green light entirely for a true red display.

## What it does

- **Intensity slider** goes from **normal screen** (100%) to **pure red** (0%), passing through warm orange tones
- **Reduce White Point slider** dims bright areas while leaving darks mostly unchanged — like iOS Reduce White Point but adjustable
- **Adaptive** mode follows real solar elevation: it begins warming before sunset, follows the golden-hour and twilight markers, reaches deepest red at solar midnight, and eases back by dawn — set it once and forget it (location stays on your Mac)
- Adaptive fades in and out over two seconds; turning it off restores the exact manual values you had before, while its nudges and all four band limits remain intact for next time
- Each display checkbox fades that monitor's filter in or out over 0.7 seconds; enabled displays use the same gentle fade when Redlight starts and quits
- **Band limits** — while Adaptive is on, drag the bracket markers on each slider to set a hard min/max the filter can never leave; nudging a slider inside the band shifts the curve's baseline without turning Adaptive off
- **Invert** colors per display (checkbox next to each display) — flips light and dark beneath the red filter
- Per-display toggle — control each monitor independently
- Optional **Launch at Login** toggle (off by default, never registered behind your back)
- Remembers your settings across launches
- Restores each display's ColorSync calibration when its filter turns off, and everything on quit
- No dock icon, lives in the menu bar

## Screenshot

Click the sun icon in the menu bar to open the popover:

- Toggle each display on/off, or check **Invert** to flip its colors
- Drag the intensity slider to control how much blue/green light to remove
- Drag the white point slider to reduce peak brightness without dimming darks
- Flip on **Adaptive** to let the sun drive the filter automatically, then drag the red bracket markers to fence in how far it can go; turn it off to fade back to your saved manual setting
- Filled sun = active, outline = inactive

## Install

Download the latest `Redlight-<version>.dmg` from [Releases](../../releases), open it, and drag **Redlight** to `/Applications`.

Or build from source:

```bash
git clone https://github.com/andrewfitz/redlight.git
cd redlight
./build.sh
```

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools or Xcode.app (for building from source)

## How it works

Uses CoreGraphics gamma table APIs (`CGSetDisplayTransferByTable`) to modify the display lookup table per display at the GPU level. Red channel stays at full brightness while green and blue channels scale down — blue drops faster than green to produce a warm orange-to-red transition instead of purple. The white point slider applies a custom transfer curve that concentrates brightness reduction on highlights while preserving darks.

No overlay windows, no accessibility permissions, no screen capture. Just gamma tables.

Adaptive mode adds CoreLocation: it caches an approximate coordinate for offline use, refreshes it occasionally and after wake, and computes the sun's elevation angle locally with a standard NOAA solar algorithm. The filter starts easing at +12°, reaches Warm at +6°, Sunset at 0°, follows the civil/nautical/astronomical twilight boundaries at −6°/−12°/−18°, and reaches Deep Red at solar midnight. The popover shows the live elevation on its sun arc. Invert is the innermost layer of the same per-display gamma table (`x → 1 − x`), so it composes with the red filter without extra permissions.

## License

MIT
