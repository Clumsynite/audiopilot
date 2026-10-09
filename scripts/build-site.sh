#!/bin/bash
# Assembles site/dist: the page, screenshots, a changelog from CHANGELOG.md and, given a release folder,
# its .dmg, .zip, update.json and signature. Used by the Release workflow; also runs locally:
#   SITE_URL=https://audiopilot.example.workers.dev scripts/build-site.sh [release-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SITE_URL:?set SITE_URL to the https address of the site, without a trailing slash}"
SITE_URL="${SITE_URL%/}"
DIST=site/dist

rm -rf "$DIST"
cp -R site/public "$DIST"
mkdir -p "$DIST/screens"
cp docs/screenshots/*.png "$DIST/screens/"
cp docs/icon.png "$DIST/icon.png"
python3 scripts/site_changelog.py CHANGELOG.md "$DIST/changelog.html"
grep -rl '%SITE_URL%' "$DIST" | while read -r f; do
    sed -i.bak "s|%SITE_URL%|$SITE_URL|g" "$f" && rm -f "$f.bak"
done

if [[ $# -ge 1 ]]; then
    REL="$1"
    for f in update.json update.json.sig; do
        [[ -f "$REL/$f" ]] || { echo "error: $REL/$f missing" >&2; exit 1; }
        cp "$REL/$f" "$DIST/"
    done
    VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REL/update.json")"
    cp "$REL/AudioPilot-$VERSION.zip" "$REL/AudioPilot-$VERSION.dmg" "$DIST/"
    # A stable link for the download button; the files keep their versioned names.
    printf '/download /AudioPilot-%s.dmg 302\n' "$VERSION" > "$DIST/_redirects"
    echo "site built for $SITE_URL with $VERSION"
else
    echo "site built for $SITE_URL (no release files)"
fi
