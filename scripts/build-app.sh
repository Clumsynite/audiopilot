#!/bin/bash
# Builds build/AudioPilot.app (release). Never launches or installs it.
#
# Environment (all optional):
#   VERSION=1.2.3          CFBundleShortVersionString (default: the value in Resources/Info.plist)
#   BUILD_NUMBER=42        CFBundleVersion            (default: number of git commits, else 1)
#   SIGN_IDENTITY="Developer ID Application: …"   sign with hardened runtime (default: ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
rm -rf build/AudioPilot.app && mkdir -p build/AudioPilot.app/Contents/{MacOS,Resources}
cp "$BIN_DIR/AudioPilot" build/AudioPilot.app/Contents/MacOS/AudioPilot
PLIST=build/AudioPilot.app/Contents/Info.plist
cp Resources/Info.plist "$PLIST"
cp Resources/AppIcon.icns build/AudioPilot.app/Contents/Resources/AppIcon.icns
VERSION="${VERSION:-$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -lint "$PLIST"
echo "Version $VERSION ($BUILD_NUMBER)"

# App Intents metadata (Spotlight actions + Shortcuts app). SwiftPM compiles the const values
# but doesn't run Xcode's metadata step, so run it here.
OBJ=".build/out/Intermediates.noindex/AudioPilot.build/Release/AudioPilot-p.build/Objects-normal/arm64"
TC="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
if [[ -f "$OBJ/AudioPilot-primary.swiftconstvalues" && -x "$TC/usr/bin/appintentsmetadataprocessor" ]]; then
    LIST="$(mktemp -t audiopilot-constvals)"
    echo "$PWD/$OBJ/AudioPilot-primary.swiftconstvalues" > "$LIST"
    XCODE_BUILD="$(xcodebuild -version | awk '/Build version/ {print $3}')"
    "$TC/usr/bin/appintentsmetadataprocessor" \
        --output build/AudioPilot.app/Contents/Resources \
        --toolchain-dir "$TC" --module-name AudioPilot --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$XCODE_BUILD" --platform-family macOS --deployment-target 14.0 \
        --target-triple arm64-apple-macos14.0 --source-file-list "$OBJ/AudioPilot.SwiftFileList" \
        --swift-const-vals-list "$LIST" --deployment-aware-processing --no-app-shortcuts-localization \
        --force --quiet-warnings 2>&1 | grep -v "^20..-" || true
    rm -f "$LIST"
    if [[ -f build/AudioPilot.app/Contents/Resources/Metadata.appintents/extract.actionsdata ]]; then
        echo "App Intents metadata: OK"
    else
        echo "warning: App Intents metadata not generated (Spotlight actions/Shortcuts won't appear)" >&2
    fi
else
    echo "warning: skipping App Intents metadata (const values or processor not found)" >&2
fi

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --timestamp=none build/AudioPilot.app
else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements Resources/AudioPilot.entitlements build/AudioPilot.app
fi
codesign --verify --verbose build/AudioPilot.app
echo "Built build/AudioPilot.app"
