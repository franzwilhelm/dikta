#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID="no.franzvonderlippe.Diktat"
APP_DIR="$PROJECT_DIR/dist/Dikta.app"
"$PROJECT_DIR/scripts/prepare-native.sh"
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c release --show-bin-path)"
# SwiftPM does not track changes to the externally built static archives.
rm -f "$BIN_DIR/Dikta"
swift build --package-path "$PROJECT_DIR" -c release
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Dikta" "$APP_DIR/Contents/MacOS/Dikta"
"$PROJECT_DIR/scripts/build-icon.sh"
cp "$PROJECT_DIR/.build/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -f "$APP_DIR/Contents/Helpers/whisper-cli"
cp "$PROJECT_DIR/.build/whisper-source/LICENSE" "$APP_DIR/Contents/Resources/whisper.cpp-LICENSE"
cp "$PROJECT_DIR/Vendor/KeyboardShortcuts/license" "$APP_DIR/Contents/Resources/KeyboardShortcuts-LICENSE"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
SPARKLE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "Fant ikke Sparkle.framework; kjør swift package resolve." >&2; exit 1; }
cp "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP_DIR/Contents/Resources/Sparkle-LICENSE"
rm -rf "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto "$SPARKLE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
# The vendored localization helper checks Contents/Resources before SwiftPM.
for bundle in "$BIN_DIR/"*.bundle; do
    [ -d "$bundle" ] || continue
    ditto "$bundle" "$APP_DIR/Contents/Resources/$(basename "$bundle")"
done
# Sparkle ships signed by its own Developer ID; re-sign so the whole bundle shares one identity.
codesign --force --sign "${DIKTAT_SIGNING_IDENTITY:--}" --deep --options runtime \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "${DIKTAT_SIGNING_IDENTITY:--}" \
    --identifier "$APP_ID" \
    --requirements "=designated => identifier \"$APP_ID\"" \
    --entitlements "$PROJECT_DIR/Resources/Diktat.entitlements" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
echo "Pakket: $APP_DIR"
