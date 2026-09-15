#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/download-models.sh"
"$SCRIPT_DIR/prepare-native.sh"
