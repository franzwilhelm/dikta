#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
REPOSITORY="${DIKTAT_REPOSITORY:-franzwilhelm/dikta}"
BASE_URL="${DIKTAT_RELEASE_BASE_URL:-https://github.com/$REPOSITORY/releases/download/v$VERSION}"
OUT="$PROJECT_DIR/dist/release/v$VERSION"
ARCHIVE="Dikta-$VERSION-macos-arm64.zip"
"$PROJECT_DIR/scripts/package-app.sh"
mkdir -p "$OUT"
rm -f "$OUT/$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$PROJECT_DIR/dist/Dikta.app" "$OUT/$ARCHIVE"
SHA="$(shasum -a 256 "$OUT/$ARCHIVE" | awk '{print $1}')"
{
    printf '#!/bin/bash\nset -euo pipefail\n'
    printf 'APP_VERSION=%q\nARCHIVE_URL=%q\nARCHIVE_SHA256=%q\n' "$VERSION" "$BASE_URL/$ARCHIVE" "$SHA"
    cat "$PROJECT_DIR/scripts/lib/models.sh"
    cat "$PROJECT_DIR/scripts/install-release-body.sh"
} > "$OUT/install.sh"
chmod +x "$OUT/install.sh"
(cd "$OUT" && shasum -a 256 "$ARCHIVE" install.sh > SHA256SUMS)
bash -n "$OUT/install.sh"
printf 'Release klar: %s\n' "$OUT"
printf 'Etter publisering:\ncurl -fsSL https://github.com/%s/releases/latest/download/install.sh | bash\n' "$REPOSITORY"
