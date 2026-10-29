#!/bin/bash
# Local development only. Signed installation still uses package_local.sh.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_ROOT="$ROOT/build.noindex"
DERIVED="$BUILD_ROOT/development"
APP="$DERIVED/Build/Products/Debug/OMP GUI Dev.app"
LOG="$DERIVED/build.log"

is_running_under() {
  local prefix="$1/" command
  while IFS= read -r command; do
    case "$command" in "$prefix"*) return 0 ;; esac
  done < <(ps -axo command=)
  return 1
}

build() {
  if is_running_under "$APP"; then
    echo 'OMP GUI Dev is running from this build. Quit it before rebuilding.' >&2
    exit 1
  fi
  mkdir -p "$DERIVED"
  python3 "$ROOT/scripts/browser_runtime.py" prepare > "$DERIVED/browser-runtime.log" 2>&1 || { tail -n 60 "$DERIVED/browser-runtime.log" >&2; exit 1; }
  local verification_inputs
  verification_inputs=$(python3 "$ROOT/tests/support/build_inputs.py")
  rm -f "$DERIVED/verification-inputs.json"
  echo 'Building OMP GUI Dev...'
  if ! python3 "$ROOT/tests/support/local_build.py" run --product "$APP" "$ROOT" "$DERIVED/tmp" -- \
    xcodebuild -project "$ROOT/OMPGUI.xcodeproj" -scheme OMPGUI \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" -skipPackagePluginValidation \
    SWIFT_EXEC="$ROOT/build.noindex/tools/swiftc" \
    CODE_SIGNING_ALLOWED=NO build > "$LOG" 2>&1; then
    tail -n 80 "$LOG" >&2
    echo "Build failed. Full log: $LOG" >&2
    exit 1
  fi
  test -x "$APP/Contents/MacOS/OMP GUI Dev"
  python3 "$ROOT/tests/support/build_inputs.py" --record "$verification_inputs"
  echo "Built $APP"
}

cd "$ROOT"
case "${1:-build}" in
  build) build ;;
  run)
    # Starting an already open instance preserves its active work. After editing,
    # quit it and run again to compile and open the updated app.
    if ! is_running_under "$APP"; then build; fi
    open "$APP"
    ;;
  clean)
    if is_running_under "$BUILD_ROOT"; then
      echo 'A process is running from build.noindex. Quit it before cleaning.' >&2
      exit 1
    fi
    rm -rf "$BUILD_ROOT"
    echo 'Removed build.noindex (products, packages and build caches).'
    ;;
  *) echo 'Usage: scripts/develop.sh [build|run|clean]' >&2; exit 1 ;;
esac
