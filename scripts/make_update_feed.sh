#!/usr/bin/env bash
# Sign the DMG and produce the signed, release-specific Sparkle feed.
# Usage: scripts/make_update_feed.sh (after scripts/make_dmg.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
DIST="$ROOT/dist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw "$PLIST")"
KEY_ACCOUNT="local.notchisland.release"
ASSET="NotchIsland-$VERSION.dmg"
FEED="NotchIsland-appcast.xml"
SPARKLE="$("$ROOT/scripts/fetch_sparkle.sh")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]]
[[ -f "$DIST/$ASSET" ]]
if [[ "$("$SPARKLE/bin/generate_keys" --account "$KEY_ACCOUNT" -p)" != "$PUBLIC_KEY" ]]; then
  echo 'The signing key in the login Keychain does not match the public key shipped in Notch Island.' >&2
  exit 1
fi

WORK="$(mktemp -d "$DIST/.notchisland-appcast.XXXXXX")"
MOUNT="$(mktemp -d)"
cleanup() {
  hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$WORK"
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT
cp "$DIST/$ASSET" "$WORK/$ASSET"
hdiutil verify "$WORK/$ASSET" -quiet
hdiutil attach "$WORK/$ASSET" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet
PACKAGED_APP="$MOUNT/Notch Island.app"
PACKAGED_PLIST="$PACKAGED_APP/Contents/Info.plist"
codesign --verify --strict --deep --all-architectures "$PACKAGED_APP"
[[ "$(plutil -extract CFBundleShortVersionString raw "$PACKAGED_PLIST")" == "$VERSION" ]]
[[ "$(plutil -extract CFBundleVersion raw "$PACKAGED_PLIST")" == "$BUILD" ]]
[[ "$(plutil -extract SUPublicEDKey raw "$PACKAGED_PLIST")" == "$PUBLIC_KEY" ]]
[[ "$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$PACKAGED_PLIST")" == true ]]
[[ "$(plutil -extract SURequireSignedFeed raw "$PACKAGED_PLIST")" == true ]]
hdiutil detach "$MOUNT" -quiet

SIGNATURE="$("$SPARKLE/bin/sign_update" --account "$KEY_ACCOUNT" -p "$WORK/$ASSET")"
[[ "$SIGNATURE" =~ ^[A-Za-z0-9+/]{86}==$ ]]
SIZE="$(stat -f '%z' "$WORK/$ASSET")"
cat > "$WORK/$FEED" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Notch Island releases</title>
        <item>
            <title>Notch Island $VERSION</title>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/LeoFeng0816/Notch-Island/releases/download/v$VERSION/$ASSET"
                       sparkle:edSignature="$SIGNATURE" length="$SIZE" type="application/octet-stream" />
        </item>
    </channel>
</rss>
XML
"$SPARKLE/bin/sign_update" --account "$KEY_ACCOUNT" "$WORK/$FEED"
"$SPARKLE/bin/sign_update" --account "$KEY_ACCOUNT" --verify "$WORK/$FEED"
"$SPARKLE/bin/sign_update" --account "$KEY_ACCOUNT" --verify "$WORK/$ASSET" "$SIGNATURE"
if ! cmp -s "$WORK/$ASSET" "$DIST/$ASSET"; then
  echo 'The release DMG changed while signing. Run this script again.' >&2
  exit 1
fi
mv "$WORK/$FEED" "$DIST/$FEED"
shasum -a 256 "$DIST/$ASSET" "$DIST/$FEED"
