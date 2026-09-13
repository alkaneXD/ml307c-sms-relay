#!/usr/bin/env bash
# Wraps the SwiftPM-built binary into a proper .app bundle so it runs as a
# menu-bar-only app (LSUIElement) and can be supervised by launchd.
#
#   Scripts/bundle.sh [release|debug] [arch]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
ARCH="${2:-$(uname -m)}"
APP_NAME="ML307C SMS Relay"
EXEC_NAME="SMSRelay"
BUNDLE_ID="dev.smsrelay.app"
BIN="$ROOT/.build/${ARCH}-apple-macosx/$CONFIG/$EXEC_NAME"
[[ -x "$BIN" ]] || BIN="$ROOT/.build/$CONFIG/$EXEC_NAME"
OUT="$ROOT/build/$APP_NAME.app"
IDENTITY="${CODESIGN_IDENTITY:--}"   # "-" = ad-hoc; export CODESIGN_IDENTITY="Developer ID Application: …" to sign for real

if [[ ! -x "$BIN" ]]; then
  echo "binary not found at $BIN — run 'swift build -c $CONFIG --arch $ARCH' first" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
echo -n "APPL????" > "$OUT/Contents/PkgInfo"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  swift "$ROOT/Scripts/make-icon.swift" "$ROOT/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

if [[ "$CONFIG" == "release" ]]; then
  strip -Sx "$OUT/Contents/MacOS/$EXEC_NAME"   # drop debug + local symbols
fi

codesign --force --deep --options runtime --timestamp=none \
  --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$OUT"

echo "built $OUT ($(du -sh "$OUT" | cut -f1), $(lipo -archs "$OUT/Contents/MacOS/$EXEC_NAME"))"
