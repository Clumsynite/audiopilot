#!/bin/bash
# Sets the app version, dates the CHANGELOG section, commits, and tags it.
# Pushing the tag triggers the Release workflow.
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

# The release notes come from CHANGELOG.md: "## Unreleased" becomes this version's section.
if grep -q '^## Unreleased' CHANGELOG.md; then
    sed -i '' -E "s/^## Unreleased.*/## $NEW — $(date +%Y-%m-%d)/" CHANGELOG.md
elif ! grep -qE "^## $NEW( |\$)" CHANGELOG.md; then
    echo "error: CHANGELOG.md has no '## Unreleased' or '## $NEW' section to release" >&2
    exit 1
fi

plutil -replace CFBundleShortVersionString -string "$NEW" "$PLIST"
# Keep the README version badge in step.
sed -i '' -E "s#badge/version-[0-9]+\.[0-9]+\.[0-9]+-blue#badge/version-$NEW-blue#" README.md
git add "$PLIST" README.md CHANGELOG.md
git commit -m "Release v$NEW"
git tag -a "v$NEW" -m "AudioPilot v$NEW"
echo "Bumped $CURRENT → $NEW and tagged v$NEW."
echo "Publish with:  git push origin HEAD --follow-tags"
