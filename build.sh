#!/bin/bash
# Build Lapang.app, install it to ~/Applications and relaunch it.
#
#   ./build.sh               build, install, launch
#   ./build.sh --no-install  only build ./build/Lapang.app
#
# Signing is ad-hoc by default, which is all a Mac needs to run an app it built itself.
# To sign for distribution, set LAPANG_SIGN_IDENTITY to your "Developer ID Application: …"
# identity (see `security find-identity -v -p codesigning`).
#
# LAPANG_RELEASE=1 (set by release.sh) builds a universal binary and keeps the update feed in
# Info.plist. Other builds leave the feed out, so a build from source never updates itself
# from a release: update it with `git pull && ./build.sh`.
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
[ "${LAPANG_RELEASE:-}" = 1 ] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR_BUILD="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Lapang.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR_BUILD/Lapang" "$APP/Contents/MacOS/Lapang"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # regenerate with: xcrun swift Support/make-icon.swift
ditto "$BIN_DIR_BUILD/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [ "${LAPANG_RELEASE:-}" != 1 ]; then
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist"
fi

# Sign inside out: Sparkle's helpers, then the framework, then the app. No --deep.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -n "${LAPANG_SIGN_IDENTITY:-}" ]; then
  SIGN=(codesign --force --options runtime --timestamp --sign "$LAPANG_SIGN_IDENTITY")
else
  SIGN=(codesign --force --sign -)
fi
"${SIGN[@]}" "$FW/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Autoupdate"
"${SIGN[@]}" "$FW/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"

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
