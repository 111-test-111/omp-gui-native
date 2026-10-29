#!/bin/bash
# Install a previously verified edition without quitting or launching anything.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:?Usage: install_app.sh <built.app> <dev|release>}
EDITION=${2:?Usage: install_app.sh <built.app> <dev|release>}
case "$EDITION" in
  dev) NAME='OMP GUI Dev'; IDENTIFIER='dev.ompgui.mac.dev' ;;
  release) NAME='OMP GUI'; IDENTIFIER='dev.ompgui.mac' ;;
  *) echo 'Invalid edition' >&2; exit 1 ;;
esac
TARGET="/Applications/$NAME.app"
if ps -axo command= | grep -F "$TARGET/Contents/MacOS/" | grep -v grep >/dev/null; then
  echo "$NAME is running. Quit it explicitly; it was not replaced." >&2
  exit 1
fi
codesign --verify --deep --strict -R="identifier \"$IDENTIFIER\"" "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$VERSION" = "$("$ROOT/scripts/version.sh" "$EDITION")" ]] || { echo 'Source app does not match the requested edition version' >&2; exit 1; }
STAGE=$(mktemp -d '/Applications/.omp-gui-install.XXXXXX')
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$NAME.app"
codesign --verify --deep --strict "$STAGE/$NAME.app"
# Check again after copying in case the owner launched the target in the meantime.
if ps -axo command= | grep -F "$TARGET/Contents/MacOS/" | grep -v grep >/dev/null; then
  echo "$NAME was launched during staging; it was not replaced." >&2
  exit 1
fi
BACKUP="$ROOT/build.noindex/install-backups/$(date '+%Y%m%d-%H%M%S')-$$/$NAME.app"
if [ -e "$TARGET" ]; then
  mkdir -p "$(dirname "$BACKUP")"
  mv "$TARGET" "$BACKUP"
fi
if ! mv "$STAGE/$NAME.app" "$TARGET"; then
  [ ! -e "$BACKUP" ] || mv "$BACKUP" "$TARGET"
  exit 1
fi
if ! codesign --verify --deep --strict "$TARGET"; then
  mv "$TARGET" "$STAGE/$NAME.app"
  [ ! -e "$BACKUP" ] || mv "$BACKUP" "$TARGET"
  exit 1
fi
echo "Installed $TARGET ($("$ROOT/scripts/version.sh" "$EDITION" display)); not launched."
