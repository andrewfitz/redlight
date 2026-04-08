#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Redlight.app"
CONTENTS="$APP/Contents"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"

cp "$ROOT/.build/arm64-apple-macosx/release/Redlight" "$CONTENTS/MacOS/Redlight"

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
</dict>
</plist>
PLIST

echo "Built: $APP"
