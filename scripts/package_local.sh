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
TEAM_ID=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p' config/release.xcconfig)
DEV_TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p' config/dev.xcconfig)
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] && [ "$DEV_TEAM" = "$TEAM_ID" ] || {
  echo 'Release and Dev must use the same Developer ID team.' >&2; exit 1;
}
IDENTITIES=$(security find-identity -v -p codesigning | sed -nE "s/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}) \"Developer ID Application: .*\($TEAM_ID\)\".*/\1/p")
IDENTITY_COUNT=$(printf '%s\n' "$IDENTITIES" | awk 'NF { n++ } END { print n+0 }')
[ "$IDENTITY_COUNT" = 1 ] || {
  echo "Expected one usable Developer ID Application identity for team $TEAM_ID; found $IDENTITY_COUNT." >&2
  exit 1
}
HASH="$IDENTITIES"

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
  echo "Building $name $display with Developer ID..."
  # Judge scrolling/animation in optimized Dev packages; Xcode Debug stays -Onone.
  optimization=()
  if [ "$edition" = dev ]; then
    optimization=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule)
  fi
  # Keep both editions on a stable Apple signing identity and secure timestamp.
  if ! xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration "$config" \
    -destination 'platform=macOS' -derivedDataPath "$derived" -skipPackagePluginValidation \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$HASH" DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
    ${optimization[@]+"${optimization[@]}"} \
    build > "$derived/build.log" 2>&1; then
    grep -E 'error:|BUILD FAILED' "$derived/build.log" | tail -30 || true
    exit 1
  fi
  product="$derived/Build/Products/$config/$name.app"
  codesign --verify --deep --strict \
    -R="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$TEAM_ID\" and identifier \"$(identifier_for "$edition")\"" "$product"
  details=$(codesign -dv --verbose=4 "$product" 2>&1)
  grep -qx "TeamIdentifier=$TEAM_ID" <<< "$details"
  grep -q "flags=.*runtime" <<< "$details"
  grep -q "Timestamp=" <<< "$details"
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
