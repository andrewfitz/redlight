# Redlight

A macOS menu bar app that applies a red screen filter by manipulating display gamma tables. Goes deeper than Night Shift — removes blue and green light entirely for a true red display.

## What it does

- **Intensity slider** goes from **normal screen** (100%) to **pure red** (0%), passing through warm orange tones
- **Reduce White Point slider** dims bright areas while leaving darks mostly unchanged — like iOS Reduce White Point but adjustable
- Per-display toggle — control each monitor independently
- Remembers your settings across launches
- Restores normal display on quit
- No dock icon, lives in the menu bar

## Screenshot

Click the circle icon in the menu bar to open the popover:

- Toggle each display on/off
- Drag the intensity slider to control how much blue/green light to remove
- Drag the white point slider to reduce peak brightness without dimming darks
- Filled circle = active, outline = inactive

## Install

Download `Redlight-v1.0.zip` from [Releases](../../releases), unzip, and drag to `/Applications`.

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

## License

MIT
