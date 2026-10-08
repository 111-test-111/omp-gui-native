#!/bin/bash
# Local package contract: an explicit package request also updates /Applications.
# Build-only checks use xcodebuild instead. This script never quits/launches apps,
# syncs/deletes libraries or advances the other edition's version.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:---both}" in
  --dev) EDITIONS=(dev) ;;
  --release) EDITIONS=(release) ;;
  --both) EDITIONS=(release dev) ;;
  *) echo 'Usage: package_local.sh [--dev|--release|--both]' >&2; exit 1 ;;
esac
HASH=$(security find-identity -v -p codesigning | awk '/"Tivano Local Development"/ { print $2 }')
[[ "$HASH" =~ ^[0-9A-Fa-f]{40}$ ]] || { echo 'Run scripts/setup_local_signing.sh first.' >&2; exit 1; }

name_for() { if [ "$1" = dev ]; then printf 'Tivano Dev'; else printf 'Tivano'; fi; }
configuration_for() { if [ "$1" = dev ]; then printf 'Debug'; else printf 'Release'; fi; }
identifier_for() { if [ "$1" = dev ]; then printf 'dev.tivano.Tivano.dev'; else printf 'dev.tivano.Tivano'; fi; }
check_not_running() {
  local name="$1"
  if ps -axo command= | grep -F "/Applications/$name.app/Contents/MacOS/" | grep -v grep >/dev/null; then
    echo "$name is running. Quit it explicitly, then package again; it was not replaced." >&2
    exit 1
  fi
}
for edition in "${EDITIONS[@]}"; do check_not_running "$(name_for "$edition")"; done

# Verify all requested builds before changing either installed bundle.
for edition in "${EDITIONS[@]}"; do
  name=$(name_for "$edition")
  config=$(configuration_for "$edition")
  version=$(scripts/version.sh "$edition")
  display=$(scripts/version.sh "$edition" display)
  derived="build.noindex/$edition"
  mkdir -p "$derived"
  echo "Building $name $display with the fixed local identity..."
  # Judge scrolling/animation in optimized Dev packages; Xcode Debug stays -Onone.
  optimization=()
  if [ "$edition" = dev ]; then
    optimization=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule)
  fi
  # Overrides are LOCAL ONLY. The public Release configuration retains Developer ID.
  if ! xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration "$config" \
    -destination 'platform=macOS' -derivedDataPath "$derived" -skipPackagePluginValidation \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$HASH" ENABLE_HARDENED_RUNTIME=NO \
    ${optimization[@]+"${optimization[@]}"} \
    build > "$derived/build.log" 2>&1; then
    grep -E 'error:|BUILD FAILED' "$derived/build.log" | tail -30 || true
    exit 1
  fi
  product="$derived/Build/Products/$config/$name.app"
  codesign --verify --deep --strict \
    -R="identifier \"$(identifier_for "$edition")\" and certificate leaf = H\"$HASH\"" "$product"
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$product/Contents/Info.plist")
  [[ "$actual" = "$version" ]] || { echo "Version mismatch: $actual != $version" >&2; exit 1; }
  mkdir -p build.noindex/packages
  ditto -c -k --keepParent "$product" "build.noindex/packages/$name-$display.zip"
done

for edition in "${EDITIONS[@]}"; do check_not_running "$(name_for "$edition")"; done
for edition in "${EDITIONS[@]}"; do
  name=$(name_for "$edition")
  config=$(configuration_for "$edition")
  scripts/install_app.sh "build.noindex/$edition/Build/Products/$config/$name.app" "$edition"
done
