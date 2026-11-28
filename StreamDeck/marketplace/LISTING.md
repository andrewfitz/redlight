# Redlight

## Marketplace description

Control the Redlight Mac app from Stream Deck. Adjust color temperature and white point, apply a preset, and see the current values on a key or the Stream Deck + touch strip. Each control shows color temperature in percent by default and can display kelvin when available.

Hold the Peek key to see true colors, then release it to restore the previous state. Separate Pause and Resume keys control the timed pause.

Requires Redlight 2.0.0 for Mac, macOS 14 or later, and Stream Deck software 7.1 or later. Install and open the Redlight Mac app before using the plugin.

AI assisted with plugin development, listing copy, and supporting artwork. The previews illustrate the plugin’s controls with example readings.

## Release notes for 0.2.1

Adds monochrome action-list icons, distinct artwork for Peek, Pause, and Resume, and correctly sized plugin icons. Existing key and dial assignments carry over.

## Maker Console files

- Upload the installer from [dist](../dist/com.redlight.app.streamdeck.streamDeckPlugin).
- Use [app-icon.png](app-icon.png) for the app icon and [thumbnail.png](thumbnail.png) for the listing thumbnail.
- Upload [gallery-units.png](gallery-units.png), [gallery-peek.png](gallery-peek.png), and [gallery-dials.png](gallery-dials.png) in this order.
- Use the [Redlight project](https://github.com/andrewfitz/redlight) for product information and the [issue tracker](https://github.com/andrewfitz/redlight/issues) for support.

## Before submission

Publish a compatible Mac app download and add its verified public URL to the listing. The local [Redlight 2.0.0 disk image](../../Redlight-2.0.0.dmg) contains the Peek renewal command. Select your organization's intended pricing in Maker Console.

## Reviewer setup

1. Install the companion Mac app in Applications and open it. Install the plugin and add Redlight Status to a key.
2. Adjust color temperature in the app. The key should update. Select Kelvin in the key’s property inspector to switch units.
3. With tint active, press and release Hold to Peek. The tint returns without starting a pause countdown.
4. Start a pause using Pause Redlight. Press and release Hold to Peek during that pause, then use Resume Redlight to end the pause.
5. On Stream Deck +, add Adjust Redlight to a dial. Rotate it to change the selected channel and press it to reset.
