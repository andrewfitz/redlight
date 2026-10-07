#!/bin/bash
# Build, sign the update for Sparkle, and publish a GitHub release.
#   VERSION=1.2 Tools/release.sh
# The release carries the DMG plus appcast.xml; installed copies poll
# releases/latest/download/appcast.xml (SUFeedURL in build.sh). The EdDSA private key
# lives in the login keychain (Sparkle's generate_keys).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${VERSION:?set VERSION, e.g. VERSION=1.2 Tools/release.sh}"
TAG="v$VERSION"
REPO="andrewfitz/redlight"
OUTPUT_DIR="${REDLIGHT_BUILD_OUTPUT_DIR:-$ROOT}"
DMG="$OUTPUT_DIR/Redlight-$VERSION.dmg"

VERSION="$VERSION" "$ROOT/build.sh"
# The release build uses a fresh scratch directory. Read the matching Sparkle tool
# instead of depending on an old .build/artifacts download from another invocation.
SPARKLE_APPCAST_TOOL="$(python3 "$ROOT/Tools/app-intents-metadata.py" sparkle-tool --output-dir "$OUTPUT_DIR")"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/redlight-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG" "$STAGE/"
"$SPARKLE_APPCAST_TOOL" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO/releases/tag/$TAG" \
    -o "$STAGE/appcast.xml" "$STAGE"

gh release create "$TAG" "$DMG" "$STAGE/appcast.xml" \
    --repo "$REPO" --title "Redlight $VERSION" --generate-notes
