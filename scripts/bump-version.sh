#!/bin/bash
# Sets the app version, commits, and tags it. Pushing the tag triggers the Release workflow.
#   scripts/bump-version.sh 0.3.0
#   scripts/bump-version.sh patch|minor|major
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
CURRENT="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "${1:-}" in
    patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
    major) NEW="$((MAJOR + 1)).0.0" ;;
    [0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
    *) echo "usage: $0 <x.y.z|patch|minor|major>   (current: $CURRENT)" >&2; exit 2 ;;
esac

[[ -z "$(git status --porcelain)" ]] || { echo "error: commit or stash your changes first" >&2; exit 1; }
git rev-parse "v$NEW" >/dev/null 2>&1 && { echo "error: tag v$NEW already exists" >&2; exit 1; }

plutil -replace CFBundleShortVersionString -string "$NEW" "$PLIST"
git add "$PLIST"
git commit -m "Release v$NEW"
git tag -a "v$NEW" -m "AudioPilot v$NEW"
echo "Bumped $CURRENT → $NEW and tagged v$NEW."
echo "Publish with:  git push origin HEAD --follow-tags"
