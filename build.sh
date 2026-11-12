#!/bin/bash
# Build Lapang.app, install it to ~/Applications and relaunch it.
#
#   ./build.sh               build, install, launch
#   ./build.sh --no-install  only build ./build/Lapang.app
#
# Signing is ad-hoc by default, which is all a Mac needs to run an app it built itself.
# To sign for distribution, set LAPANG_SIGN_IDENTITY to your "Developer ID Application: …"
# identity (see `security find-identity -v -p codesigning`).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Lapang"

APP="build/Lapang.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lapang"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # regenerate with: xcrun swift Support/make-icon.swift

if [ -n "${LAPANG_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$LAPANG_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi

[ "${1:-}" = "--no-install" ] && { echo "✓ built $APP"; exit 0; }

DEST="$HOME/Applications/Lapang.app"
pkill -x Lapang 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "✓ installed $DEST"

# the same binary is the `lapang` command (status, clean, …); link it where your shell finds it
BIN_DIR="${LAPANG_BIN_DIR:-$HOME/.local/bin}"
if [ -d "$BIN_DIR" ]; then
  ln -sfn "$DEST/Contents/MacOS/Lapang" "$BIN_DIR/lapang"
  echo "✓ linked $BIN_DIR/lapang"
else
  echo "  to use the lapang command: ln -s \"$DEST/Contents/MacOS/Lapang\" /usr/local/bin/lapang"
fi
