#!/bin/bash
# Ship a Lapang release: build, sign, notarize, publish, and tell existing installs about it.
#
#   ./release.sh 0.2.0 --dry-run   everything that can run without publishing anything
#   ./release.sh 0.2.0             the real thing (asks once before the first push)
#
# Options: --notes FILE  release notes as Markdown (default: commit subjects since the last tag)
#          --yes         don't ask before publishing
#
# Needs (see RELEASING.md): a "Developer ID Application" identity in LAPANG_SIGN_IDENTITY, a
# notarytool keychain profile named lapang-notary, the Sparkle EdDSA key in the login keychain
# (account "lapang"), and `gh` signed in with push access to lapang, afiqsazlan.com and homebrew-tap.
#
# Order, each step stopping the release if it fails:
#   1 bump the version   2 build universal   3 sign (Developer ID, hardened runtime)
#   4 notarize + staple   5 zip   6 EdDSA-sign the zip   7 commit, tag, push lapang
#   8 GitHub Release   9 appcast on afiqsazlan.com   10 Homebrew cask
set -euo pipefail
cd "$(dirname "$0")"

REPO="afiqsazlan/lapang"
SITE_REPO="afiqsazlan/afiqsazlan.com"
TAP_REPO="afiqsazlan/homebrew-tap"
APPCAST_PATH="public/lapang/appcast.xml"
NOTARY_PROFILE="${LAPANG_NOTARY_PROFILE:-lapang-notary}"
SPARKLE_ACCOUNT="${LAPANG_SPARKLE_ACCOUNT:-lapang}"
PLIST="Support/Info.plist"

# ---------------------------------------------------------------- arguments

VERSION="" DRY=0 YES=0 NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    --notes) NOTES_FILE="${2:?--notes needs a file}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) VERSION="$1" ;;
  esac
  shift
done

bold() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: ./release.sh X.Y.Z [--dry-run] [--notes FILE] [--yes]"
TAG="v$VERSION"
ZIP_NAME="Lapang-$VERSION.zip"
ASSET_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"
DIST="dist"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lapang-release.XXXXXX")"
[ "$DRY" = 1 ] && echo "DRY RUN: nothing is committed, pushed or published. Work files: $WORK"

# A dry run leaves Info.plist as it found it.
cp "$PLIST" "$WORK/Info.plist.orig"
restore() { [ "$DRY" = 1 ] && cp "$WORK/Info.plist.orig" "$PLIST"; true; }
trap restore EXIT

# ---------------------------------------------------------------- preflight

bold "Preflight"
for tool in git gh swift xcrun codesign ditto shasum python3; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)"

if [ -n "$(git status --porcelain)" ]; then
  [ "$DRY" = 1 ] && warn "working tree has changes (a real release refuses this)" || die "commit or stash your changes first"
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = main ] || { [ "$DRY" = 1 ] && warn "on $BRANCH, not main" || die "releases are cut from main (on $BRANCH)"; }
git fetch -q origin main --tags
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  [ "$DRY" = 1 ] && warn "main differs from origin/main" || die "main differs from origin/main: pull or push first"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && die "GitHub release $TAG already exists"

CUR_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
CUR_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
  python3 -c "import sys; a=tuple(map(int,'$VERSION'.split('.'))); b=tuple(map(int,'${LAST_TAG#v}'.split('.'))); sys.exit(0 if a>b else 1)" \
    || die "$VERSION is not newer than the last release ${LAST_TAG#v}"
  BUILD=$((CUR_BUILD + 1))
else
  BUILD="$CUR_BUILD"  # the first release keeps the build number already in Info.plist
fi
ok "version $CUR_VERSION ($CUR_BUILD) → $VERSION ($BUILD)${LAST_TAG:+, last release $LAST_TAG}"

SIGNED=1
if [ -z "${LAPANG_SIGN_IDENTITY:-}" ]; then
  [ "$DRY" = 1 ] || die "LAPANG_SIGN_IDENTITY is not set (see RELEASING.md)"
  warn "LAPANG_SIGN_IDENTITY not set: ad-hoc signing, notarization skipped"; SIGNED=0
elif ! security find-identity -v -p codesigning | grep -qF "$LAPANG_SIGN_IDENTITY"; then
  die "no valid signing identity matching \"$LAPANG_SIGN_IDENTITY\" in the keychain"
else
  [[ "$LAPANG_SIGN_IDENTITY" == "Developer ID Application"* ]] || die "LAPANG_SIGN_IDENTITY must be a Developer ID Application identity"
  ok "signing as $LAPANG_SIGN_IDENTITY"
fi

NOTARIZE="$SIGNED"
if [ "$SIGNED" = 1 ]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    ok "notary profile $NOTARY_PROFILE works"
  else
    [ "$DRY" = 1 ] || die "notarytool profile $NOTARY_PROFILE missing or rejected (see RELEASING.md)"
    warn "notary profile $NOTARY_PROFILE not usable: notarization skipped"; NOTARIZE=0
  fi
fi

swift package resolve >/dev/null
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/sign_update" ] || die "Sparkle's sign_update not found in $SPARKLE_BIN"
PUBKEY_PLIST="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
PUBKEY_KEYCHAIN="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)" \
  || die "no Sparkle key for account \"$SPARKLE_ACCOUNT\" in the keychain (see RELEASING.md)"
[ "$PUBKEY_PLIST" = "$PUBKEY_KEYCHAIN" ] || die "SUPublicEDKey in $PLIST doesn't match the keychain's Sparkle key"
ok "Sparkle key matches SUPublicEDKey"

# ---------------------------------------------------------------- notes

if [ -n "$NOTES_FILE" ]; then
  cp "$NOTES_FILE" "$WORK/notes.md"
else
  git log --no-merges --format='- %s' ${LAST_TAG:+"$LAST_TAG..HEAD"} > "$WORK/notes.md"
fi
[ -s "$WORK/notes.md" ] || die "release notes are empty"
python3 - "$WORK/notes.md" "$WORK/notes.html" <<'PY'
import html, re, sys
lines = open(sys.argv[1]).read().splitlines()
out, in_list = [], False
for l in lines:
    m = re.match(r"^\s*[-*]\s+(.*)", l)
    if m:
        if not in_list: out.append("<ul>"); in_list = True
        out.append(f"<li>{html.escape(m.group(1))}</li>")
        continue
    if in_list: out.append("</ul>"); in_list = False
    if l.strip(): out.append(f"<p>{html.escape(l.strip().lstrip('#').strip())}</p>")
if in_list: out.append("</ul>")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
ok "release notes ($(wc -l < "$WORK/notes.md" | tr -d ' ') lines): $WORK/notes.md"

# ---------------------------------------------------------------- 1-3 bump, build, sign

bold "1. Bump version"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
ok "$PLIST → $VERSION ($BUILD)"

bold "2-3. Build universal and sign"
if [ "$SIGNED" = 1 ]; then
  LAPANG_RELEASE=1 ./build.sh --no-install
else
  LAPANG_RELEASE=1 LAPANG_SIGN_IDENTITY= ./build.sh --no-install
fi
APP="build/Lapang.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || die "built app has the wrong version"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" >/dev/null || die "built app has no SUFeedURL"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Lapang")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || die "expected a universal binary, got: $ARCHS"
codesign --verify --strict --deep "$APP" || die "signature check failed"
if [ "$SIGNED" = 1 ]; then
  SIGN_INFO="$(codesign -dv "$APP" 2>&1)"
  [[ "$SIGN_INFO" =~ flags=.*runtime ]] || die "app is not signed with the hardened runtime"
  [[ "$SIGN_INFO" == *"Authority=Developer ID Application"* ]] || die "app is not signed with Developer ID"
fi
REPORTED="$("$APP/Contents/MacOS/Lapang" --version)"
[ "$REPORTED" = "lapang $VERSION ($BUILD)" ] || die "lapang --version says \"$REPORTED\", expected $VERSION ($BUILD)"
ok "built $APP ($ARCHS)"

# ---------------------------------------------------------------- 4 notarize

bold "4. Notarize and staple"
rm -rf "$DIST" && mkdir -p "$DIST"
if [ "$NOTARIZE" = 1 ]; then
  ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
  OUT="$(xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" \
    || die "notarytool submit failed: $OUT"
  STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$OUT")"
  SUB_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$OUT")"
  if [ "$STATUS" != Accepted ]; then
    xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization $STATUS (submission $SUB_ID)"
  fi
  ok "notarized (submission $SUB_ID)"
  xcrun stapler staple "$APP" || die "stapling failed"
  xcrun stapler validate "$APP" || die "stapled ticket doesn't validate"
  spctl --assess --type execute -vv "$APP" || die "Gatekeeper rejects the app"
  ok "stapled; Gatekeeper accepts it"
else
  warn "skipped: needs a Developer ID identity and the $NOTARY_PROFILE profile"
fi

# ---------------------------------------------------------------- 5-6 package and sign the update

bold "5. Package"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP_NAME"
SHA256="$(shasum -a 256 "$DIST/$ZIP_NAME" | cut -d' ' -f1)"
ok "$DIST/$ZIP_NAME ($(du -h "$DIST/$ZIP_NAME" | cut -f1 | tr -d ' '), sha256 $SHA256)"

bold "6. EdDSA-sign the update"
SIG_ATTRS="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DIST/$ZIP_NAME")" || die "sign_update failed"
ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIG_ATTRS")"
LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$SIG_ATTRS")"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || die "couldn't read sign_update output: $SIG_ATTRS"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$DIST/$ZIP_NAME" "$ED_SIG" >/dev/null \
  || die "signature doesn't verify"
ok "signed: $SIG_ATTRS"

# ---------------------------------------------------------------- prepare appcast + cask

bold "Prepare appcast and cask"
gh repo clone "$SITE_REPO" "$WORK/site" -- -q --depth 1 || die "couldn't clone $SITE_REPO"
if [ ! -f "$WORK/site/$APPCAST_PATH" ]; then
  [ "$DRY" = 1 ] || die "$APPCAST_PATH not found in $SITE_REPO: push the empty feed first (RELEASING.md)"
  warn "$APPCAST_PATH not in $SITE_REPO yet: using an empty feed"
  mkdir -p "$(dirname "$WORK/site/$APPCAST_PATH")"
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' \
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
    '  <channel>' '    <title>Lapang</title>' '  </channel>' '</rss>' > "$WORK/site/$APPCAST_PATH"
  git -C "$WORK/site" add "$APPCAST_PATH"
fi
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
python3 - "$WORK/site/$APPCAST_PATH" "$WORK/notes.html" <<PY || die "couldn't update the appcast"
import sys
path, notes = sys.argv[1], open(sys.argv[2]).read()
xml = open(path).read()
if 'sparkle:version>$BUILD<' in xml:
    sys.exit("appcast already has build $BUILD")
item = """    <item>
      <title>Lapang $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <description><![CDATA[
%s      ]]></description>
      <enclosure url="$ASSET_URL" type="application/octet-stream" $SIG_ATTRS/>
    </item>
""" % notes
anchor = "  </channel>"
assert xml.count(anchor) == 1, "no single </channel> in the appcast"
# newest first: right after the channel's own fields, before any older item
i = xml.find("    <item>")
xml = xml[:i] + item + xml[i:] if i != -1 else xml.replace(anchor, item + anchor)
open(path, "w").write(xml)
PY
xmllint --noout "$WORK/site/$APPCAST_PATH" || die "appcast is not valid XML"
ok "appcast item added ($WORK/site/$APPCAST_PATH)"

if gh repo view "$TAP_REPO" >/dev/null 2>&1; then
  gh repo clone "$TAP_REPO" "$WORK/tap" -- -q --depth 1 || die "couldn't clone $TAP_REPO"
else
  [ "$DRY" = 1 ] || die "$TAP_REPO doesn't exist yet (see RELEASING.md)"
  warn "$TAP_REPO doesn't exist yet: writing the cask to a scratch folder"
  mkdir -p "$WORK/tap" && git -C "$WORK/tap" init -q -b main
fi
mkdir -p "$WORK/tap/Casks"
cat > "$WORK/tap/Casks/lapang.rb" <<RB
cask "lapang" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/Lapang-#{version}.zip"
  name "Lapang"
  desc "Menu bar app that keeps an eye on what fills a developer's Mac"
  homepage "https://www.afiqsazlan.com/tools/lapang"

  livecheck do
    url "https://www.afiqsazlan.com/lapang/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Lapang.app"
  binary "#{appdir}/Lapang.app/Contents/MacOS/Lapang", target: "lapang"

  uninstall quit: "com.afiqsazlan.lapang"

  zap trash: [
    "~/.config/lapang",
    "~/Library/Application Support/Lapang",
    "~/Library/Caches/com.afiqsazlan.lapang",
    "~/Library/HTTPStorages/com.afiqsazlan.lapang",
    "~/Library/Preferences/com.afiqsazlan.lapang.plist",
  ]
end
RB
ruby -c "$WORK/tap/Casks/lapang.rb" >/dev/null || die "cask is not valid Ruby"
ok "cask written ($WORK/tap/Casks/lapang.rb)"

if [ "$DRY" = 1 ]; then
  bold "Dry run done. A real run would now:"
  echo "  7. commit \"Release $VERSION\" ($PLIST), tag $TAG, push main and $TAG to $REPO"
  echo "  8. gh release create $TAG $DIST/$ZIP_NAME"
  echo "  9. push the appcast to $SITE_REPO (live in about a minute):"
  git -C "$WORK/site" --no-pager diff --stat
  echo " 10. push Casks/lapang.rb to $TAP_REPO"
  [ "$NOTARIZE" = 1 ] || warn "this build is not notarized; a real release requires it"
  exit 0
fi

# ---------------------------------------------------------------- publish

if [ "$YES" != 1 ]; then
  printf '\nPublish Lapang %s (%s) to %s, the appcast and the tap? [y/N] ' "$VERSION" "$BUILD" "$REPO"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || die "stopped before publishing; $PLIST is bumped but not committed"
fi

bold "7. Commit, tag, push"
git add "$PLIST"
git commit -q -m "Release $VERSION"
git tag -a "$TAG" -m "Lapang $VERSION"
git push -q origin main "$TAG" || die "push failed: the release commit and tag $TAG exist only locally"
ok "pushed main and $TAG"

bold "8. GitHub Release"
gh release create "$TAG" "$DIST/$ZIP_NAME" -R "$REPO" --verify-tag --title "Lapang $VERSION" --notes-file "$WORK/notes.md" \
  || die "gh release create failed: $TAG is pushed; retry with: gh release create $TAG $DIST/$ZIP_NAME --notes-file $WORK/notes.md"
# Sparkle and Homebrew both download this URL; make sure it serves the bytes we signed.
curl -fsSL "$ASSET_URL" -o "$WORK/check.zip" || die "release asset isn't downloadable at $ASSET_URL"
[ "$(shasum -a 256 "$WORK/check.zip" | cut -d' ' -f1)" = "$SHA256" ] || die "downloaded asset doesn't match $DIST/$ZIP_NAME"
ok "released: https://github.com/$REPO/releases/tag/$TAG"

bold "9. Appcast"
git -C "$WORK/site" add "$APPCAST_PATH"
git -C "$WORK/site" commit -q -m "[Tools] Lapang $VERSION in the update feed"
git -C "$WORK/site" push -q origin HEAD:main || die "appcast push failed; the clone with the commit is $WORK/site"
ok "appcast pushed; live at https://www.afiqsazlan.com/lapang/appcast.xml in about a minute"

bold "10. Homebrew cask"
git -C "$WORK/tap" add Casks/lapang.rb
git -C "$WORK/tap" commit -q -m "lapang $VERSION"
git -C "$WORK/tap" push -q origin HEAD:main || die "cask push failed; the clone with the commit is $WORK/tap"
ok "cask pushed: brew install --cask afiqsazlan/tap/lapang"

bold "Lapang $VERSION is out"
echo "  Check the feed:  curl -s https://www.afiqsazlan.com/lapang/appcast.xml | grep shortVersionString"
