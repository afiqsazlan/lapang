#!/bin/bash
# Build Headroom.app, install it to ~/Applications and relaunch it.
#
#   ./build.sh               build, install, launch
#   ./build.sh --no-install  only build ./build/Headroom.app
#
# Signing is ad-hoc by default, which is all a Mac needs to run an app it built itself.
# To sign for distribution, set HEADROOM_SIGN_IDENTITY to your "Developer ID Application: …"
# identity (see `security find-identity -v -p codesigning`).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Headroom"

APP="build/Headroom.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Headroom"
cp Support/Info.plist "$APP/Contents/Info.plist"

if [ -n "${HEADROOM_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$HEADROOM_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

[ "${1:-}" = "--no-install" ] && { echo "✓ built $APP"; exit 0; }

DEST="$HOME/Applications/Headroom.app"
pkill -x Headroom 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "✓ installed $DEST"
