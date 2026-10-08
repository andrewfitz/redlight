#!/bin/bash
# Build, sign the update for Sparkle, and publish a GitHub release.
#   Tools/release.sh (uses VERSION), or VERSION=1.4 Tools/release.sh
# The release carries the DMG plus appcast.xml; installed copies poll
# releases/latest/download/appcast.xml (SUFeedURL in build.sh). The EdDSA private key
# lives in the login keychain (Sparkle's generate_keys).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_ARGS=(--root "$ROOT")
if [[ -n "${VERSION:-}" ]]; then VERSION_ARGS+=(--override "$VERSION"); fi
VERSION="$(python3 "$ROOT/Tools/build-version.py" release "${VERSION_ARGS[@]}")"
TAG="v$VERSION"
REPO="andrewfitz/redlight"
OUTPUT_DIR="${REDLIGHT_BUILD_OUTPUT_DIR:-$ROOT}"
RELEASE_BASENAME="Redlight-$VERSION"
ASSET_URL_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
VERSION_HISTORY_URL="https://github.com/$REPO/releases"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/redlight-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
NOTES_MARKDOWN="$STAGE/release-notes.md"
NOTES_HTML="$STAGE/$RELEASE_BASENAME.html"
# Validate the matching changelog section before reserving a build number or building.
python3 "$ROOT/Tools/release-notes.py" render --changelog "$ROOT/CHANGELOG.md" \
    --version "$VERSION" --markdown "$NOTES_MARKDOWN" --html "$NOTES_HTML"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
export REDLIGHT_BUILD_OUTPUT_DIR="$OUTPUT_DIR"
DMG="$OUTPUT_DIR/$RELEASE_BASENAME.dmg"

VERSION="$VERSION" "$ROOT/build.sh"
# The release build uses a fresh scratch directory. Read the matching Sparkle tool
# instead of depending on an old .build/artifacts download from another invocation.
SPARKLE_APPCAST_TOOL="$(python3 "$ROOT/Tools/app-intents-metadata.py" sparkle-tool --output-dir "$OUTPUT_DIR")"

cp "$DMG" "$STAGE/"
"$SPARKLE_APPCAST_TOOL" \
    --download-url-prefix "$ASSET_URL_PREFIX" \
    --release-notes-url-prefix "$ASSET_URL_PREFIX" \
    --full-release-notes-url "$VERSION_HISTORY_URL" \
    --link "https://github.com/$REPO/releases/tag/$TAG" \
    -o "$STAGE/appcast.xml" "$STAGE"

python3 "$ROOT/Tools/release-notes.py" verify-appcast --appcast "$STAGE/appcast.xml" \
    --dmg-url "$ASSET_URL_PREFIX$RELEASE_BASENAME.dmg" \
    --notes-url "$ASSET_URL_PREFIX$RELEASE_BASENAME.html" \
    --history-url "$VERSION_HISTORY_URL"

gh release create "$TAG" "$DMG" "$STAGE/appcast.xml" "$NOTES_HTML" \
    --repo "$REPO" --title "Redlight $VERSION" --notes-file "$NOTES_MARKDOWN" \
    --target "$(git -C "$ROOT" rev-parse HEAD)"
