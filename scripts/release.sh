#!/bin/bash
# Builds, signs, notarizes and packages Tivano, then updates /Applications.
# Never quits or launches the app.
#
#   scripts/release.sh
#
# Needs Xcode, XcodeGen, a Developer ID Application certificate for the team below
# and a notarytool keychain profile (NOTARY_PROFILE, "Tivano-Notarize" by default).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
TEAM_ID="NARHG44L48"
NOTARY_PROFILE="${NOTARY_PROFILE:-Tivano-Notarize}"
APP_NAME="Tivano"
# ".noindex" keeps Spotlight and Launchpad from listing the build copies of the app.
BUILD="$ROOT/build.noindex/public-release"
ARCHIVE="$BUILD/Tivano.xcarchive"
EXPORT="$BUILD/export"
VERSION=$(scripts/version.sh release)
DMG="$ROOT/build.noindex/Tivano-$VERSION.dmg"

step() { printf '\n==> %s\n' "$1"; }

notarize() {
  local file="$1" result status id
  result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  status=$(printf '%s' "$result" | plutil -extract status raw - 2>/dev/null || true)
  if [ "$status" != "Accepted" ]; then
    printf '%s\n' "$result"
    id=$(printf '%s' "$result" | plutil -extract id raw - 2>/dev/null || true)
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
    exit 1
  fi
  echo "Notarization accepted for $(basename "$file")"
}

step "Generating the Xcode project"
xcodegen generate --quiet

step "Archiving $APP_NAME $VERSION"
rm -rf "$BUILD"
mkdir -p "$BUILD"
if ! xcodebuild archive \
  -project Tivano.xcodeproj \
  -scheme Tivano \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/DerivedData" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=NO > "$BUILD/archive.log" 2>&1; then
  grep -E "error:" "$BUILD/archive.log" | head -40 || tail -40 "$BUILD/archive.log"
  exit 1
fi

step "Exporting with Developer ID"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
</dict>
</plist>
PLIST
if ! xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" > "$BUILD/export.log" 2>&1; then
  tail -40 "$BUILD/export.log"
  exit 1
fi
APP="$EXPORT/$APP_NAME.app"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
details=$(codesign -dv --verbose=4 "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<< "$details"
grep -q "flags=.*runtime" <<< "$details"
grep -q "Timestamp=" <<< "$details"
archs=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
if [ "$archs" != "arm64" ]; then
  echo "Expected an Apple silicon binary, got: $archs"
  exit 1
fi

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$BUILD/Tivano.zip"
notarize "$BUILD/Tivano.zip"
xcrun stapler staple "$APP"

step "Building the disk image"
# The styled window (background, baked .DS_Store, volume icon) lives in release/dmg, see release/dmg/README.md.
"$ROOT/scripts/package_dmg.sh" --app "$APP" --output "$DMG"
IDENTITY=$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\($TEAM_ID\))\".*/\1/p" | head -1)
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"

step "Checking Gatekeeper"
spctl --assess --type execute --ignore-cache --no-cache --verbose "$APP"
spctl --assess --type open --context context:primary-signature --ignore-cache --no-cache --verbose "$DMG"
xcrun stapler validate "$DMG"

step "Updating the installed Release (without launching)"
"$ROOT/scripts/install_app.sh" "$APP" release

step "Cleaning up"
# Only the disk image stays, so Spotlight and Launchpad never list a second copy of the app.
rm -rf "$ARCHIVE" "$EXPORT" "$BUILD/Tivano.zip" "$BUILD/DerivedData"

printf '\nReady: %s\nPublish it with scripts/publish_release.sh once CHANGELOG.md has a ## [%s] section.\n' "$DMG" "$VERSION"
