# Appended to release-specific constants and model helpers by release.sh.
# This file is a template; use the generated install.sh from a release.
fail() { echo "Dikta: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'Krever macOS 26 eller nyere.'
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ] || fail 'Krever Apple Silicon (M1 eller nyere).'
OS_MAJOR="$(sw_vers -productVersion | cut -d . -f 1)"
[ "$OS_MAJOR" -ge 26 ] || fail 'Krever macOS 26 eller nyere.'
[ "$(id -u)" -ne 0 ] || fail 'Kjør uten sudo; appen installeres for din bruker.'
if pgrep -x 'Dikta|Diktat' >/dev/null; then
    fail 'Avslutt Dikta fra menyfeltet og kjør samme kommando igjen.'
fi
INSTALL_DIR="${DIKTAT_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$INSTALL_DIR"
LOCK_DIR="$INSTALL_DIR/.diktat-install.lock"
mkdir "$LOCK_DIR" 2>/dev/null || fail "En installasjon pågår allerede. Hvis en tidligere installasjon ble avbrutt, fjern $LOCK_DIR og prøv igjen."
STAGE=""
COMMITTED=no
cleanup() {
    local result=$?
    trap - EXIT
    if [ -n "$STAGE" ]; then
        if [ "$COMMITTED" = no ] && [ -d "$STAGE/Previous.app" ]; then
            if [ -e "$INSTALL_DIR/Dikta.app" ]; then
                mv "$INSTALL_DIR/Dikta.app" "$STAGE/Failed.app"
            fi
            mv "$STAGE/Previous.app" "$INSTALL_DIR/Dikta.app"
        fi
        rm -rf "$STAGE"
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE="$(mktemp -d "$INSTALL_DIR/.diktat-install.XXXXXX")"
echo "Installerer Dikta $APP_VERSION …"
if [ -n "${DIKTAT_ARCHIVE_PATH:-}" ]; then
    cp "$DIKTAT_ARCHIVE_PATH" "$STAGE/app.zip"
else
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 20 "$ARCHIVE_URL" -o "$STAGE/app.zip"
fi
ACTUAL="$(shasum -a 256 "$STAGE/app.zip" | awk '{print $1}')"
[ "$ACTUAL" = "$ARCHIVE_SHA256" ] || fail 'Apppakken har feil kontrollsum. Ingen app er erstattet.'
ditto -x -k "$STAGE/app.zip" "$STAGE/unpacked"
APP="$STAGE/unpacked/Dikta.app"
[ -d "$APP" ] || fail 'Apppakken mangler Dikta.app.'
codesign --verify --deep --strict "$APP"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[ "$IDENTIFIER" = no.franzvonderlippe.Diktat ] || fail 'Feil appidentitet i pakken.'
# Download models separately, before replacing an existing working app.
download_models
if pgrep -x 'Dikta|Diktat' >/dev/null; then
    fail 'Dikta ble startet under installasjonen. Avslutt appen og kjør kommandoen igjen.'
fi
if [ -e "$INSTALL_DIR/Dikta.app" ]; then
    mv "$INSTALL_DIR/Dikta.app" "$STAGE/Previous.app"
fi
mv "$APP" "$INSTALL_DIR/Dikta.app"
COMMITTED=yes
# Retire the earlier display name only when it is our app, never an unrelated bundle.
LEGACY="$INSTALL_DIR/Diktat.app"
if [ -d "$LEGACY" ]; then
    LEGACY_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$LEGACY_ID" = no.franzvonderlippe.Diktat ]; then
        mv "$LEGACY" "$STAGE/Legacy.app"
    fi
fi
echo "Installert: $INSTALL_DIR/Dikta.app"
echo 'Første gang: gi mikrofontilgang og aktiver Dikta under Tilgjengelighet for automatisk innliming.'
if [ "${DIKTAT_NO_OPEN:-0}" != 1 ]; then
    open "$INSTALL_DIR/Dikta.app"
fi
