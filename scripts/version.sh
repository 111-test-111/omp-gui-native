#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EDITION=${1:-release}
case "$EDITION" in dev|release) ;; *) echo 'Usage: version.sh [dev|release] [display]' >&2; exit 1 ;; esac
VERSION=$(awk -F= '/^MARKETING_VERSION[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT/config/$EDITION.xcconfig")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid numeric version' >&2; exit 1; }
if [ "${2:-}" = display ] && [ "$EDITION" = dev ]; then printf 'dev-%s\n' "$VERSION"; else printf '%s\n' "$VERSION"; fi
