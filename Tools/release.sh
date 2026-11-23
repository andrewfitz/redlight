#!/bin/bash
# Build, sign the update for Sparkle, and publish a GitHub release.
#   Tools/release.sh (uses VERSION), or VERSION=1.4 Tools/release.sh
# The release carries the DMG plus appcast.xml; installed copies poll
# releases/latest/download/appcast.xml (SUFeedURL in build.sh). The EdDSA private key
# lives in the login keychain (Sparkle's generate_keys).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="andrewfitz/redlight"
OUTPUT_DIR="${REDLIGHT_BUILD_OUTPUT_DIR:-$ROOT}"
TARGET="$(git -C "$ROOT" rev-parse HEAD)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/redlight-release.XXXXXX")"
INVOCATION_DIR=""
KEEP_INVOCATION=0
cleanup_release() {
    rm -rf "$STAGE"
    if [[ -n "$INVOCATION_DIR" ]] && (( !KEEP_INVOCATION )); then rm -rf "$INVOCATION_DIR"; fi
}
trap cleanup_release EXIT

# Build the same committed sources the GitHub tag will name, including the build script.
mkdir -p "$ROOT/.build"
INVOCATION_DIR="$(mktemp -d "$ROOT/.build/command-control-build.XXXXXX")"
SOURCE="$INVOCATION_DIR/source"
mkdir "$SOURCE"
git -C "$ROOT" archive --output="$STAGE/source.tar" "$TARGET"
tar -xf "$STAGE/source.tar" -C "$SOURCE"

VERSION_ARGS=(--root "$SOURCE")
if [[ -n "${VERSION:-}" ]]; then VERSION_ARGS+=(--override "$VERSION"); fi
VERSION="$(python3 "$SOURCE/Tools/build-version.py" release "${VERSION_ARGS[@]}")"
TAG="v$VERSION"
RELEASE_BASENAME="Redlight-$VERSION"
ASSET_URL_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
VERSION_HISTORY_URL="https://github.com/$REPO/releases"

NOTES_MARKDOWN="$STAGE/release-notes.md"
SNAPSHOT="$STAGE/artifacts"
NOTES_HTML="$SNAPSHOT/$RELEASE_BASENAME.html"
# Validate the matching changelog section before reserving a build number or building.
python3 "$SOURCE/Tools/release-notes.py" render --changelog "$SOURCE/CHANGELOG.md" \
    --version "$VERSION" --markdown "$NOTES_MARKDOWN" --html "$STAGE/$RELEASE_BASENAME.html"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
export REDLIGHT_BUILD_OUTPUT_DIR="$OUTPUT_DIR"
DMG="$SNAPSHOT/$RELEASE_BASENAME.dmg"

KEEP_INVOCATION=1
if ! VERSION="$VERSION" REDLIGHT_BUILD_WORKSPACE="$ROOT" REDLIGHT_BUILD_SNAPSHOT_DIR="$SNAPSHOT" \
    "$SOURCE/build.sh"; then
    KEEP_INVOCATION=0
    exit 1
fi
# The release build uses a fresh scratch directory. Read the matching Sparkle tool
# instead of depending on an old .build/artifacts download from another invocation.
SPARKLE_APPCAST_TOOL="$(python3 "$SOURCE/Tools/app-intents-metadata.py" sparkle-tool --output-dir "$SNAPSHOT")"

mv "$STAGE/$RELEASE_BASENAME.html" "$NOTES_HTML"
"$SPARKLE_APPCAST_TOOL" \
    --download-url-prefix "$ASSET_URL_PREFIX" \
    --release-notes-url-prefix "$ASSET_URL_PREFIX" \
    --full-release-notes-url "$VERSION_HISTORY_URL" \
    --link "https://github.com/$REPO/releases/tag/$TAG" \
    -o "$SNAPSHOT/appcast.xml" "$SNAPSHOT"

python3 "$SOURCE/Tools/release-notes.py" verify-appcast --appcast "$SNAPSHOT/appcast.xml" \
    --dmg-url "$ASSET_URL_PREFIX$RELEASE_BASENAME.dmg" \
    --dmg-file "$DMG" --version "$VERSION" --build-info "$SNAPSHOT/.redlight-build-info.json" \
    --notes-url "$ASSET_URL_PREFIX$RELEASE_BASENAME.html" \
    --history-url "$VERSION_HISTORY_URL"

REMOTE_TAGS="$(git -C "$ROOT" ls-remote "https://github.com/$REPO.git" "refs/tags/$TAG" "refs/tags/$TAG^{}")"
REMOTE_TARGET=""
while read -r commit reference; do
    if [[ "$reference" == "refs/tags/$TAG^{}" ]]; then
        REMOTE_TARGET="$commit"
        break
    fi
    if [[ "$reference" == "refs/tags/$TAG" ]]; then REMOTE_TARGET="$commit"; fi
done <<< "$REMOTE_TAGS"
if [[ -n "$REMOTE_TARGET" && "$REMOTE_TARGET" != "$TARGET" ]]; then
    echo "error: GitHub tag $TAG points to $REMOTE_TARGET, but the release was built from $TARGET." >&2
    exit 1
fi

gh release create "$TAG" "$DMG" "$SNAPSHOT/appcast.xml" "$NOTES_HTML" \
    --repo "github.com/$REPO" --title "Redlight $VERSION" --notes-file "$NOTES_MARKDOWN" \
    --target "$TARGET"
