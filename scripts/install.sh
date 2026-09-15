#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID="no.franzvonderlippe.Diktat"
APP_DIR="$PROJECT_DIR/dist/Diktat.app"
INSTALL_DIR="${DIKTAT_INSTALL_DIR:-$HOME/Applications}"

if pgrep -x Diktat >/dev/null; then
    echo 'Avslutt Diktat fra menyfeltet før du installerer på nytt.' >&2
    exit 1
fi
"$PROJECT_DIR/scripts/download-models.sh"
"$PROJECT_DIR/scripts/package-app.sh"
mkdir -p "$INSTALL_DIR"
rm -f "$INSTALL_DIR/Diktat.app/Contents/Helpers/whisper-cli"
ditto "$APP_DIR" "$INSTALL_DIR/Diktat.app"
codesign --verify --deep --strict "$INSTALL_DIR/Diktat.app"
echo "Installert: $INSTALL_DIR/Diktat.app"
