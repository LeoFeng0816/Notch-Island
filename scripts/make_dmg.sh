#!/usr/bin/env bash
# Usage: scripts/make_dmg.sh [--release | --notarize]
# --release signs the app and DMG with Developer ID. --notarize also submits
# the DMG to Apple using the Keychain profile in NOTCHISLAND_NOTARY_PROFILE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="NotchIsland"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
DIST="$ROOT/dist"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
PYTHON="$ROOT/build/dmg-tools/bin/python"
RELEASE=0
NOTARIZE=0

for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1 ;;
    --notarize) RELEASE=1; NOTARIZE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ $NOTARIZE == 1 && -z "${NOTCHISLAND_NOTARY_PROFILE:-}" ]]; then
  echo '--notarize requires NOTCHISLAND_NOTARY_PROFILE (a notarytool Keychain profile).' >&2
  exit 2
fi
if [[ ! -x "$PYTHON" ]] || ! "$PYTHON" -I -c 'import dmgbuild' >/dev/null 2>&1; then
  echo 'Install the DMG tools from the project root:' >&2
  echo '  python3 -m venv build/dmg-tools' >&2
  echo '  build/dmg-tools/bin/python -m pip install -r scripts/dmg-requirements.txt' >&2
  exit 2
fi

build_flags=(--universal)
if [[ $RELEASE == 1 ]]; then
  build_flags+=(--release)
fi
"$ROOT/build.sh" "${build_flags[@]}"
APP="$ROOT/build/$APP_NAME.app"

mkdir -p "$DIST"
STAGE="$(mktemp -d "$DIST/.notchisland-dmg.XXXXXX")"
MOUNT="$(mktemp -d)"
cleanup() { hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$STAGE"; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT

ditto --norsrc --noextattr "$APP" "$STAGE/Notch Island.app"
xcrun swift "$ROOT/scripts/render_artwork.swift" installer "$STAGE" "$VERSION"
CANDIDATE="$STAGE/$APP_NAME-$VERSION.dmg"
"$PYTHON" -I -m dmgbuild -s "$ROOT/scripts/dmg_settings.py" \
  -D "app=$STAGE/Notch Island.app" -D "background=$STAGE/installer.png" \
  -D "icon=$ROOT/Resources/NotchIsland.icns" \
  "Notch Island $VERSION" "$CANDIDATE"

if [[ $RELEASE == 1 ]]; then
  BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
  codesign --sign "$NOTCHISLAND_SIGN_IDENTITY" --timestamp --identifier "$BUNDLE_ID.dmg" "$CANDIDATE"
  codesign --verify --strict "$CANDIDATE"
fi

hdiutil verify "$CANDIDATE" -quiet
echo '==> Checking the mounted image (read-only)'
hdiutil attach "$CANDIDATE" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
INSTALLED="$MOUNT/Notch Island.app"
BIN="$INSTALLED/Contents/MacOS/$APP_NAME"
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == /Applications ]]
"$PYTHON" -I - "$MOUNT" <<'PY'
from pathlib import Path
import sys
from ds_store import DSStore

mount = Path(sys.argv[1])
assert {p.name for p in mount.iterdir() if not p.name.startswith(".")} == {"Notch Island.app", "Applications"}
assert any((mount / name).is_file() for name in (".background.png", ".background.tiff"))
assert (mount / ".VolumeIcon.icns").is_file()
with DSStore.open(str(mount / ".DS_Store"), "r") as layout:
    app = layout["Notch Island.app"]["Iloc"]
    link = layout["Applications"]["Iloc"]
    assert 0 < app[0] < link[0] < 620 and app[1] == link[1] == 223
print("    Finder background, icon positions and two visible items verified")
PY
ARCHS=" $(lipo -archs "$BIN") "
[[ "$ARCHS" == *' arm64 '* && "$ARCHS" == *' x86_64 '* ]]
codesign --verify --deep --strict --all-architectures "$INSTALLED"
plutil -lint -s "$INSTALLED/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw "$INSTALLED/Contents/Info.plist")" == "$VERSION" ]]
if strings -a "$BIN" | grep '/Users/' >/dev/null; then
  echo 'Unexpected absolute home path in executable.' >&2
  exit 1
fi
if [[ -n "$(find "$INSTALLED" \( -name '*.png' -o -name '*.jpg' -o -name '*.mov' -o -name '*.json' -o -name '.DS_Store' \) -print -quit)" ]]; then
  echo 'Unexpected file in app bundle.' >&2
  exit 1
fi
echo '    universal binary, both slices’ signatures, Info.plist and payload verified'

if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
  /usr/bin/arch -arm64 "$BIN" --self-test
  echo '    Intel slice verified statically. Rosetta was not used.'
else
  /usr/bin/arch -x86_64 "$BIN" --self-test
fi
echo '==> App signature'
codesign -dv "$INSTALLED" 2>&1 | grep -E '^(Signature|TeamIdentifier|Identifier)='
hdiutil detach "$MOUNT" -quiet

if [[ $NOTARIZE == 1 ]]; then
  RESULT="$STAGE/notary-result.plist"
  echo '==> Submitting the signed DMG to Apple for notarization'
  if ! xcrun notarytool submit "$CANDIDATE" --keychain-profile "$NOTCHISLAND_NOTARY_PROFILE" \
       --wait --output-format plist > "$RESULT"; then
    cat "$RESULT" >&2
    exit 1
  fi
  STATUS="$(plutil -extract status raw "$RESULT")"
  if [[ "$STATUS" != Accepted ]]; then
    cat "$RESULT" >&2
    echo 'See xcrun notarytool log <submission-id> --keychain-profile <profile> for details.' >&2
    exit 1
  fi
  xcrun stapler staple "$CANDIDATE"
  xcrun stapler validate "$CANDIDATE"
  codesign --verify --strict "$CANDIDATE"
  hdiutil verify "$CANDIDATE" -quiet
  spctl --assess --type open --context context:primary-signature --verbose=2 "$CANDIDATE"
else
  echo '    No notarization requested.'
fi

mv -f "$CANDIDATE" "$DMG"
shasum -a 256 "$DMG" | sed 's/^/    sha256 /'
echo "==> $DMG OK"
