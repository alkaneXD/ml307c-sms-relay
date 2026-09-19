#!/usr/bin/env bash
# Packages the app into a standard Finder drag-to-Applications DMG:
# icon view, no toolbar, app on the left, Applications on the right, UDZO.
#
#   Scripts/make-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SMS Relay"
EXEC_NAME="SMSRelay"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/smsrelay-dmg.XXXXXX")"
RW="$(mktemp "${TMPDIR:-/tmp}/smsrelay-rw.XXXXXX").dmg"
APP="$STAGE/$APP_NAME.app"
trap 'rm -rf "$STAGE" "$RW"' EXIT

SMSRELAY_APP_OUT="$APP" "$ROOT/Scripts/bundle.sh" release "$(uname -m)"
[[ -d "$APP" ]] || { echo "bundle failed" >&2; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
ARCH="$(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME" | tr ' ' '-')"
mkdir -p "$ROOT/build"
DMG="$ROOT/build/SMS-Relay-${VERSION}-${ARCH}.dmg"
VOLNAME="SMS Relay"

ln -s /Applications "$STAGE/Applications"

hdiutil create -quiet -fs HFS+ -volname "$VOLNAME" -srcfolder "$STAGE" \
  -format UDRW -ov "$RW"

ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
DEVICE="$(echo "$ATTACH" | awk '/Apple_HFS/ {print $1; exit}')"
MOUNT="$(echo "$ATTACH" | sed -n 's|.*\(/Volumes/.*\)|\1|p' | tail -1)"
if [[ -z "${MOUNT:-}" ]]; then
  MOUNT="/Volumes/$VOLNAME"
fi
# Wait for Finder to see the volume.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -d "$MOUNT/$APP_NAME.app" ]] && break
  sleep 0.3
done

layout() {
  osascript - "$VOLNAME" "$APP_NAME.app" <<'APPLESCRIPT'
on run argv
  set volName to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    tell disk volName
      open
      delay 1
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      try
        set sidebar width of container window to 0
      end try
      set the bounds of container window to {200, 120, 740, 480}
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 128
      try
        set text size of opts to 12
      end try
      set position of item appName to {140, 180}
      set position of item "Applications" to {400, 180}
      close
      open
      delay 1
      update without registering applications
      delay 1
    end tell
  end tell
end run
APPLESCRIPT
}

if ! layout; then
  echo "warning: Finder window layout skipped (no GUI); DMG still has App + Applications" >&2
fi

bless --folder "$MOUNT" --openfolder "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet || hdiutil detach "$DEVICE" -quiet

rm -f "$DMG"
# UDZO = zlib, the usual Finder-downloadable disk image.
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"

rm -rf "$ROOT/build/$APP_NAME.app" "$ROOT/build/ML307C SMS Relay.app" "$ROOT/build/dmg-stage"

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$DMG" 2>/dev/null || true
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
