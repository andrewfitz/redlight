#!/bin/bash
# Re-sign a built Redlight.app with the team's cloud-managed Developer ID certificate
# through the Xcode account (no local certificate needed), notarize it, and replace it
# with the stapled copy. The app must already be signed with the hardened runtime.
#   Tools/notarize.sh path/to/Redlight.app TEAM_ID
set -euo pipefail

APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
TEAM="$2"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/redlight-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/Redlight.xcarchive"

# xcodebuild only distributes archives, so wrap the SwiftPM-built app in a minimal one.
mkdir -p "$ARCHIVE/Products/Applications"
ditto "$APP" "$ARCHIVE/Products/Applications/Redlight.app"
python3 - "$ARCHIVE" "$TEAM" "$WORK/export.plist" <<'PY'
import datetime, plistlib, sys
archive, team, export = sys.argv[1:]
with open(f"{archive}/Products/Applications/Redlight.app/Contents/Info.plist", "rb") as f:
    info = plistlib.load(f)
with open(f"{archive}/Info.plist", "wb") as f:
    plistlib.dump({
        "ApplicationProperties": {
            "ApplicationPath": "Applications/Redlight.app",
            "CFBundleIdentifier": info["CFBundleIdentifier"],
            "CFBundleShortVersionString": info["CFBundleShortVersionString"],
            "CFBundleVersion": info["CFBundleVersion"],
            "Team": team,
        },
        "ArchiveVersion": 2,
        "CreationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
        "Name": "Redlight",
        "SchemeName": "Redlight",
    }, f)
with open(export, "wb") as f:
    plistlib.dump({"method": "developer-id", "signingStyle": "automatic",
                   "teamID": team, "destination": "upload"}, f)
PY

echo "Uploading Redlight for notarization (team $TEAM)…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$WORK/upload" \
    -exportOptionsPlist "$WORK/export.plist" -allowProvisioningUpdates >"$WORK/upload.log" 2>&1 \
    || { cat "$WORK/upload.log" >&2; exit 1; }

# The upload returns before Apple's verdict; the stapled export succeeds once accepted.
for attempt in $(seq 1 960); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" \
        -exportPath "$WORK/notarized" >"$WORK/notary.log" 2>&1; then
        break
    fi
    if ! grep -q "processing and not ready" "$WORK/notary.log"; then
        cat "$WORK/notary.log" >&2
        echo "error: notarization failed; see the Xcode Organizer for Apple's log." >&2
        exit 1
    fi
    if (( attempt == 960 )); then
        cat "$WORK/notary.log" >&2
        echo "error: notarization did not finish within four hours." >&2
        exit 1
    fi
    sleep 15
done

NOTARIZED="$WORK/notarized/Redlight.app"
xcrun stapler validate "$NOTARIZED"
spctl --assess --type execute "$NOTARIZED"
rm -rf "$APP"
ditto "$NOTARIZED" "$APP"
echo "Notarized and stapled: $APP"
