#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Releases always bundle the Pro application library that lives in this repository.
if [[ ! -d Pro/Sources ]]; then
    printf '%s\n' 'Packaging requires Pro/Sources in this repository.' >&2
    exit 1
fi
if [[ -n "${OILFIND_FREE+x}" ]]; then
    printf '%s\n' 'Packaging refuses OILFIND_FREE; unset it to include Pro.' >&2
    exit 1
fi

"$PROJECT_DIR/scripts/build-app.sh"
APP_PATH="$PROJECT_DIR/build/Oil Find Plus.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

# In-app updates check the candidate against the running app's designated requirement, so a build
# that is only ad-hoc signed (requirement bound to its cdhash) could never update itself.
AUTHORITY="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
if [[ -z "$AUTHORITY" ]]; then
    printf '%s\n' 'Packaging needs a signing identity: set OILFIND_SIGN_IDENTITY or install an Apple Development certificate.' >&2
    exit 1
fi
printf 'Signed by: %s\n' "$AUTHORITY"

ARCHIVE_NAME="OilFind-Plus-v$VERSION-macOS-arm64.zip"
ARCHIVE_PATH="$PROJECT_DIR/build/$ARCHIVE_NAME"
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
python3 Tests/Scripts/test_packaged_launch.py "$APP_PATH"

# The app reads updates/latest.json from this repository; the website reads the site copy.
mkdir -p updates site/public/downloads site/public/updates
node --experimental-strip-types scripts/generate-update-manifest.mjs Resources/Info.plist "$ARCHIVE_PATH" updates/latest.json \
    "https://github.com/Weicoz/oil-find-plus/releases/download/v$VERSION/$ARCHIVE_NAME"
cp updates/latest.json site/public/updates/latest.json
cp "$ARCHIVE_PATH" "site/public/downloads/$ARCHIVE_NAME"
# The website links to this stable name.
cp "$ARCHIVE_PATH" site/public/downloads/Oil-Find.zip

printf 'File: %s\n' "$ARCHIVE_PATH"
printf 'Size: %s bytes\n' "$(stat -f '%z' "$ARCHIVE_PATH")"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$ARCHIVE_PATH" | cut -d ' ' -f 1)"
printf 'Tag: v%s\n' "$VERSION"
printf 'Publish: gh release create v%s "%s" --title "Oil Find Plus %s"\n' "$VERSION" "$ARCHIVE_PATH" "$VERSION"
