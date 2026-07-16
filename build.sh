#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Redlight.app"
CONTENTS="$APP/Contents"

BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"
swift build -c release --package-path "$ROOT"

# App icon: regenerated from Tools/make-icon.swift each build (fast, no deps).
# Fail soft — if the generator or iconutil breaks, keep a previously generated
# Resources/Redlight.icns, or warn and build without an icon.
ICONSET="$ROOT/.build/Redlight.iconset"
ICNS="$ROOT/Resources/Redlight.icns"
mkdir -p "$ROOT/Resources"
if ! { swift "$ROOT/Tools/make-icon.swift" "$ICONSET" && iconutil -c icns "$ICONSET" -o "$ICNS"; }; then
    echo "warning: icon generation failed; using existing Redlight.icns if present" >&2
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/Redlight" "$CONTENTS/MacOS/Redlight"

if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "$CONTENTS/Resources/Redlight.icns"
else
    echo "warning: no Redlight.icns available; app will show the generic icon" >&2
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Redlight</string>
    <key>CFBundleIdentifier</key>
    <string>com.redlight.app</string>
    <key>CFBundleName</key>
    <string>Redlight</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>Redlight</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Redlight uses System Events to toggle the system light/dark appearance.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Redlight uses your location to follow local sunrise and sunset times.</string>
    <key>NSLocationUsageDescription</key>
    <string>Redlight uses your location to follow local sunrise and sunset times.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

echo "Built: $APP"
