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
# The vendored localization helper checks Contents/Resources before SwiftPM.
for bundle in "$BIN_DIR/"*.bundle; do
    [ -d "$bundle" ] || continue
    ditto "$bundle" "$APP_DIR/Contents/Resources/$(basename "$bundle")"
done
codesign --force --sign "${DIKTAT_SIGNING_IDENTITY:--}" \
    --identifier "$APP_ID" \
    --requirements "=designated => identifier \"$APP_ID\"" \
    --entitlements "$PROJECT_DIR/Resources/Diktat.entitlements" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
echo "Pakket: $APP_DIR"
