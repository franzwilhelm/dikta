#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID="no.franzvonderlippe.Diktat"
APP_DIR="$PROJECT_DIR/dist/Dikta.app"
INSTALL_DIR="${DIKTAT_INSTALL_DIR:-$HOME/Applications}"

if pgrep -x 'Dikta|Diktat' >/dev/null; then
    echo 'Avslutt Dikta fra menyfeltet før du installerer på nytt.' >&2
    exit 1
fi
"$PROJECT_DIR/scripts/download-models.sh"
"$PROJECT_DIR/scripts/package-app.sh"
mkdir -p "$INSTALL_DIR"
rm -f "$INSTALL_DIR/Dikta.app/Contents/Helpers/whisper-cli"
ditto "$APP_DIR" "$INSTALL_DIR/Dikta.app"
codesign --verify --deep --strict "$INSTALL_DIR/Dikta.app"
if [ -d "$INSTALL_DIR/Diktat.app" ]; then
    LEGACY_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_DIR/Diktat.app/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$LEGACY_ID" = "$APP_ID" ]; then rm -rf "$INSTALL_DIR/Diktat.app"; fi
fi
echo "Installert: $INSTALL_DIR/Dikta.app"
