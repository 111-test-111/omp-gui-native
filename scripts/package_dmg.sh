#!/usr/bin/env bash
# Package a built Droppy Code.app into the styled installer DMG.
#
# Stages the app + Applications symlink together with the pre-baked window
# styling from release/dmg (background, .DS_Store, volume icon), then builds
# a compressed ULMO (LZMA) image via a read-write intermediate so the volume root
# can carry the custom-icon Finder flag. Signing/notarization stay with the
# caller (release.sh).
#
# Usage: package_dmg.sh --app <path/to/Droppy Code.app> --output <path/to/out.dmg>
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DMG_ASSET_DIR="$REPO_ROOT/release/dmg"
BACKGROUND_ASSET="$DMG_ASSET_DIR/installer-background.tiff"
# The baked .DS_Store is kept as base64 text so git and reviews treat it as source.
DSSTORE_ASSET="$DMG_ASSET_DIR/installer-DS_Store.base64"

error() { echo "package_dmg: $1" >&2; exit 1; }

APP_PATH=""
OUTPUT_PATH=""
VOLNAME="Droppy Code"
APP_BUNDLE_NAME="$VOLNAME.app"

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP_PATH="${2:-}"; shift 2 ;;
        --output) OUTPUT_PATH="${2:-}"; shift 2 ;;
        *) error "Unknown argument: $1" ;;
    esac
done

[ -n "$APP_PATH" ] && [ -n "$OUTPUT_PATH" ] || error "Usage: --app <Droppy Code.app> --output <out.dmg>"
[ -d "$APP_PATH" ] || error "App bundle not found at $APP_PATH"

# The pre-baked .DS_Store keys icon positions and the background alias by
# name ("Droppy Code.app", volume "Droppy Code", "/.background.tiff"). Refuse anything
# that would silently ship a broken-looking window; see release/dmg/README.md.
[ "$(basename "$APP_PATH")" = "$APP_BUNDLE_NAME" ] || error "App bundle must be named $APP_BUNDLE_NAME (got $(basename "$APP_PATH"))"
[ -f "$BACKGROUND_ASSET" ] || error "Missing installer background asset at $BACKGROUND_ASSET"
[ -f "$DSSTORE_ASSET" ] || error "Missing installer .DS_Store asset at $DSSTORE_ASSET"

VOLUME_ICON_SOURCE="$APP_PATH/Contents/Resources/AppIcon.icns"
[ -f "$VOLUME_ICON_SOURCE" ] || error "Missing app icon at $VOLUME_ICON_SOURCE (needed for the DMG volume icon)"

WORK_DIR="$(mktemp -d /tmp/droppy-code-dmg-XXXX)"
ACTIVE_MOUNT_POINT=""
cleanup() {
    if [ -n "$ACTIVE_MOUNT_POINT" ] && [ -d "$ACTIVE_MOUNT_POINT" ]; then
        hdiutil detach "$ACTIVE_MOUNT_POINT" -force -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

STAGE_PATH="$WORK_DIR/dmg-root"
DSSTORE_PATH="$WORK_DIR/DS_Store"
RW_DMG_PATH="$WORK_DIR/droppy-code-rw.dmg"
MOUNT_POINT="$WORK_DIR/mnt"

# Decoded before any disk-image work so a bad asset fails in a second, not a
# minute. The alias inside must name the volume, or Finder shows a plain window.
base64 -d < "$DSSTORE_ASSET" > "$DSSTORE_PATH" || error "Failed to decode $DSSTORE_ASSET"
LC_ALL=C grep -a -q -- "/Volumes/$VOLNAME" "$DSSTORE_PATH" \
    || error "The installer .DS_Store does not point its background at /Volumes/$VOLNAME; re-bake it (see release/dmg/README.md)"

mkdir -p "$STAGE_PATH"
# ditto, not cp: it keeps the bundle's signature, extended attributes and the
# stapled notarization ticket intact.
ditto "$APP_PATH" "$STAGE_PATH/$APP_BUNDLE_NAME"
ln -s /Applications "$STAGE_PATH/Applications"
cp "$BACKGROUND_ASSET" "$STAGE_PATH/.background.tiff"
cp "$VOLUME_ICON_SOURCE" "$STAGE_PATH/.VolumeIcon.icns"

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE_PATH" -ov -format UDRW -fs HFS+ "$RW_DMG_PATH" >/dev/null \
    || error "Failed to create read-write image"

mkdir -p "$MOUNT_POINT"
hdiutil attach "$RW_DMG_PATH" -nobrowse -noverify -mountpoint "$MOUNT_POINT" >/dev/null \
    || error "Failed to mount read-write image"
ACTIVE_MOUNT_POINT="$MOUNT_POINT"

# The window layout .DS_Store is written on the live volume rather than piped
# through -srcfolder, mirroring how dmgbuild/create-dmg apply it.
cp "$DSSTORE_PATH" "$MOUNT_POINT/.DS_Store" || error "Failed to write the installer .DS_Store"

# Volume root FinderInfo: finderFlags at byte offset 8, kHasCustomIcon = 0x0400.
# This is what makes Finder honor /.VolumeIcon.icns for the mounted volume.
xattr -wx com.apple.FinderInfo \
    "00 00 00 00 00 00 00 00 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" \
    "$MOUNT_POINT" || error "Failed to set the volume custom-icon flag"

detached=0
for _ in 1 2 3 4 5 6 7 8; do
    if hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1; then
        detached=1
        break
    fi
    sleep 1
done
if [ "$detached" -ne 1 ]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || error "Failed to detach read-write image"
fi
ACTIVE_MOUNT_POINT=""

# ULMO is supported since macOS 10.15, below Droppy Code's macOS 26 minimum.
# It preserves every byte and compresses the measured installer about 19%
# smaller than the previous maximum-zlib UDZO image.
rm -f "$OUTPUT_PATH"
hdiutil convert "$RW_DMG_PATH" -format ULMO -ov -o "$OUTPUT_PATH" >/dev/null \
    || error "Failed to convert image to ULMO"
[ -f "$OUTPUT_PATH" ] || error "hdiutil convert did not produce $OUTPUT_PATH"

echo "Styled DMG packaged at $OUTPUT_PATH"
