#!/usr/bin/env bash
# Packages the app bundle into a compressed, drag-to-Applications DMG.
#
#   Scripts/make-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ML307C SMS Relay"
EXEC_NAME="SMSRelay"
APP="$ROOT/build/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "build/$APP_NAME.app missing — run 'make app' first" >&2; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
ARCH="$(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME" | tr ' ' '-')"
DMG="$ROOT/build/ML307C-SMS-Relay-${VERSION}-${ARCH}.dmg"
STAGE="$ROOT/build/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# ULFO = LZFSE: small and fast to mount on Apple silicon.
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG"
rm -rf "$STAGE"

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$DMG" 2>/dev/null || true
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
