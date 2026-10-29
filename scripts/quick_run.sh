#!/bin/bash
# Only for an explicitly requested Dev run/relaunch. Packaging alone uses
# package_local.sh and never launches. Each edition has an isolated OMP GUI library.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME='OMP GUI Dev'
TARGET="/Applications/$APP_NAME.app"
running() { ps -axo command= | grep -F "$TARGET/Contents/MacOS/" | grep -v grep >/dev/null; }
if running; then
  osascript -e 'with timeout of 300 seconds' -e "tell application \"$APP_NAME\" to quit" -e 'end timeout'
  for _ in $(seq 1 300); do
    running || break
    sleep 1
  done
  if running; then echo 'Dev is still finishing work; it was not replaced.' >&2; exit 1; fi
fi
scripts/package_local.sh --dev
open "$TARGET"
