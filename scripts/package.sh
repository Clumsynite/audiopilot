#!/bin/bash
# Packages build/AudioPilot.app into dist/AudioPilot-<version>.dmg and .zip (+ SHA-256 sums).
# Run scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/AudioPilot.app
[[ -d "$APP" ]] || { echo "error: $APP not found; run scripts/build-app.sh first" >&2; exit 1; }
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
NAME="AudioPilot-$VERSION"
rm -rf dist && mkdir -p dist

# Zip: keeps the signature and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME.zip"

# DMG with an Applications shortcut for drag-to-install.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AudioPilot $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg" >/dev/null
rm -rf "$STAGE"

(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
echo "Packaged:"
ls -lh dist
