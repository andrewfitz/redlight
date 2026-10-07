#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION_ARGS=(--root "$ROOT")
if [[ -n "${VERSION:-}" ]]; then VERSION_ARGS+=(--override "$VERSION"); fi
VERSION="$(python3 "$ROOT/Tools/build-version.py" release "${VERSION_ARGS[@]}")"
# Ad-hoc ("-") by default. macOS keys Location Services / Automation consent to the code
# signature, so an ad-hoc build re-prompts on every update. Pass a stable identity
# (Developer ID, or a self-signed "Redlight" certificate) to avoid that:
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Set this to build without replacing the app/DMG in the repository root.
OUTPUT_DIR="${REDLIGHT_BUILD_OUTPUT_DIR:-$ROOT}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP="$OUTPUT_DIR/Redlight.app"
CONTENTS="$APP/Contents"
DMG="$OUTPUT_DIR/Redlight-${VERSION}.dmg"
YEAR="$(date +%Y)"

# App Intents extraction and Control Center require full Xcode and a macOS 26+ SDK.
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$XCODE_DEVELOPER_DIR" != */Contents/Developer ]] || \
   [[ ! -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo "error: build.sh requires full Xcode, not Command Line Tools. Select Xcode.app with xcode-select." >&2
    exit 1
fi
if ! xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
    echo "error: the selected Xcode does not include appintentsmetadataprocessor." >&2
    exit 1
fi
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if (( ${SDK_VERSION%%.*} < 26 )); then
    echo "error: Control Center packaging requires a macOS 26+ SDK; selected SDK is $SDK_VERSION." >&2
    exit 1
fi
TOOLCHAIN_DIR="$(cd "$(dirname "$(xcrun --find swiftc)")/../.." && pwd)"
XCODE_VERSION="$(xcodebuild -version | sed -n 's/^Build version //p')"

# Every build reserves a new number, including attempts that later fail compilation.
# Seed from prior bundles so removing .build does not downgrade an installed build.
BUILD_NUMBER_ARGS=(--root "$ROOT" --state "$ROOT/.build/redlight-build-number.json"
    --seed-app "$ROOT/Redlight.app" --seed-app "$APP"
    --seed-app "/Applications/Redlight.app" --seed-app "$HOME/Applications/Redlight.app")
if [[ -n "${BUILD_NUMBER:-}" ]]; then BUILD_NUMBER_ARGS+=(--override "$BUILD_NUMBER"); fi
BUILD_NUMBER="$(python3 "$ROOT/Tools/build-version.py" next "${BUILD_NUMBER_ARGS[@]}")"

# Keep compiler outputs and metadata inputs from one invocation together. Dependencies
# never receive the app's const-values path: Package.swift scopes flags to Redlight.
mkdir -p "$ROOT/.build"
INVOCATION_DIR="$(mktemp -d "$ROOT/.build/command-control-build.XXXXXX")"
SWIFTPM_DIR="$INVOCATION_DIR/swiftpm"
PROTOCOLS="$INVOCATION_DIR/AppIntents.protocols.json"
python3 "$ROOT/Tools/app-intents-metadata.py" prepare \
    --toolchain-dir "$TOOLCHAIN_DIR" --output "$PROTOCOLS"
export REDLIGHT_APP_CONST_VALUES_PATH="$INVOCATION_DIR/Redlight.swiftconstvalues"
export REDLIGHT_APP_CONST_PROTOCOLS_PATH="$PROTOCOLS"

# Apple silicon only. The embedded Sparkle framework stays universal (it ships that way).
ARCH_FLAGS=(--arch arm64)
BUILD_FLAGS=(-c release "${ARCH_FLAGS[@]}" --package-path "$ROOT" --scratch-path "$SWIFTPM_DIR")
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
swift build "${BUILD_FLAGS[@]}"

# App icon: regenerated from Tools/make-icon.swift each build (fast, no deps).
# Fail soft — if the generator or iconutil breaks, keep a previously generated
# Resources/Redlight.icns, or warn and build without an icon.
ICONSET="$INVOCATION_DIR/Redlight.iconset"
ICNS="$ROOT/Resources/Redlight.icns"
mkdir -p "$ROOT/Resources"
if ! { swift "$ROOT/Tools/make-icon.swift" "$ICONSET" && iconutil -c icns "$ICONSET" -o "$ICNS"; }; then
    echo "warning: icon generation failed; using existing Redlight.icns if present" >&2
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/Redlight" "$CONTENTS/MacOS/Redlight"

# Sparkle (auto-update). SwiftPM links the framework but doesn't embed it, so copy it in
# and point the binary's rpath at Contents/Frameworks.
SPARKLE_FW="$SWIFTPM_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$CONTENTS/Frameworks"
ditto "$SPARKLE_FW" "$CONTENTS/Frameworks/Sparkle.framework"
if ! otool -l "$CONTENTS/MacOS/Redlight" | python3 -c 'import sys; sys.exit("@executable_path/../Frameworks" not in sys.stdin.read())'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/Redlight"
fi

if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "$CONTENTS/Resources/Redlight.icns"
else
    echo "warning: no Redlight.icns available; app will show the generic icon" >&2
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Redlight</string>
    <key>CFBundleIdentifier</key>
    <string>com.redlight.app</string>
    <key>CFBundleName</key>
    <string>Redlight</string>
    <key>CFBundleDisplayName</key>
    <string>Redlight</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>© ${YEAR} Andrew Fitzgerald. MIT License.</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.redlight.app.control</string>
        <key>CFBundleURLSchemes</key><array><string>redlight</string></array>
    </dict></array>
    <key>CFBundleIconFile</key>
    <string>Redlight</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Redlight uses System Events to toggle the system light/dark appearance.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Redlight uses your location to follow local sunrise and sunset times.</string>
    <key>NSLocationUsageDescription</key>
    <string>Redlight uses your location to follow local sunrise and sunset times.</string>
    <key>SUFeedURL</key>
    <string>https://github.com/andrewfitz/redlight/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>SEcy337jNOT0XmvFnGPciypmt8hO3YKfa/uXUHQXiI4=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST

# App metadata uses this build's const values and app sources, never .build/apple leftovers.
python3 "$ROOT/Tools/app-intents-metadata.py" extract \
    --invocation-dir "$INVOCATION_DIR" --const-values "$REDLIGHT_APP_CONST_VALUES_PATH" \
    --module Redlight --bundle "$APP" --toolchain-dir "$TOOLCHAIN_DIR" \
    --sdk-root "$SDK_ROOT" --xcode-version "$XCODE_VERSION" --deployment-target 14.0 \
    --source-root "$ROOT/Sources/Redlight"

# Both targets compile SetRedlightIntent.swift unchanged. Its action identifier matches
# even though the app and extension have different Swift module names.
EXTENSION="$CONTENTS/PlugIns/RedlightControl.appex"
EXTENSION_SOURCES=("$ROOT/Sources/Redlight/Intents/SetRedlightIntent.swift"
                   "$ROOT/Extensions/RedlightControl/RedlightControl.swift")
EXTENSION_CONST_VALUES="$INVOCATION_DIR/RedlightControl.swiftconstvalues"
mkdir -p "$EXTENSION/Contents/MacOS" "$EXTENSION/Contents/Resources"
xcrun swiftc -sdk "$SDK_ROOT" -target arm64-apple-macosx26.0 \
    -module-name RedlightControl -swift-version 6 -O -whole-module-optimization -parse-as-library \
    -application-extension -Xlinker -e -Xlinker _NSExtensionMain \
    -emit-const-values-path "$EXTENSION_CONST_VALUES" \
    -Xfrontend -const-gather-protocols-file -Xfrontend "$PROTOCOLS" \
    "${EXTENSION_SOURCES[@]}" -o "$EXTENSION/Contents/MacOS/RedlightControl"
python3 "$ROOT/Tools/app-intents-metadata.py" extract \
    --invocation-dir "$INVOCATION_DIR" --const-values "$EXTENSION_CONST_VALUES" \
    --module RedlightControl --bundle "$EXTENSION" --toolchain-dir "$TOOLCHAIN_DIR" \
    --sdk-root "$SDK_ROOT" --xcode-version "$XCODE_VERSION" --deployment-target 26.0 \
    --control --sources "${EXTENSION_SOURCES[@]}"
python3 - "$EXTENSION/Contents/Info.plist" "$VERSION" "$BUILD_NUMBER" <<'PYINFO'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleDevelopmentRegion": "en",
    "CFBundleExecutable": "RedlightControl",
    "CFBundleIdentifier": "com.redlight.app.RedlightControl",
    "CFBundleName": "RedlightControl",
    "CFBundleDisplayName": "Redlight",
    "CFBundleVersion": sys.argv[3],
    "CFBundleShortVersionString": sys.argv[2],
    "CFBundlePackageType": "XPC!",
    "LSMinimumSystemVersion": "26.0",
    "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
}))
PYINFO

# Sign from the inside out. --deep is limited to Sparkle's bundled helpers for ad-hoc
# builds; Developer ID distribution should sign each Sparkle helper individually.
codesign --force --deep --sign "$SIGN_IDENTITY" "$CONTENTS/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ROOT/Extensions/RedlightControl/RedlightControl.entitlements" "$EXTENSION"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
"$ROOT/Tools/verify-command-control.sh" "$APP"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/redlight-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
cp -R "$APP" "$STAGE/Redlight.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Redlight" -srcfolder "$STAGE" -ov -format UDZO \
    -imagekey zlib-level=9 "$DMG" >/dev/null

python3 "$ROOT/Tools/app-intents-metadata.py" build-info \
    --output-dir "$OUTPUT_DIR" --invocation-dir "$INVOCATION_DIR" --swiftpm-dir "$SWIFTPM_DIR" \
    --app "$APP" --dmg "$DMG" --version "$VERSION" --build "$BUILD_NUMBER"

echo "Version: $VERSION (build $BUILD_NUMBER)"
echo "Built: $APP"
echo "Disk image: $DMG"
echo "Build metadata inputs: $INVOCATION_DIR"
