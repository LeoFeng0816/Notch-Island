#!/usr/bin/env bash
# Builds build/NotchIsland.app with swiftc only (no Xcode project needed).
# Usage: ./build.sh [--universal] [--run] [--release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NotchIsland"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
MIN_MACOS="14.0"
UNIVERSAL=0
RUN=0
RELEASE=0

for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --run) RUN=1 ;;
    --release) RELEASE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

SIGN_IDENTITY="${NOTCHISLAND_SIGN_IDENTITY:--}"
BUNDLE_ID="${NOTCHISLAND_BUNDLE_ID:-}"
if [[ -n "$BUNDLE_ID" && ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo 'NOTCHISLAND_BUNDLE_ID must be an explicit reverse-DNS identifier.' >&2
  exit 2
fi
if [[ $RELEASE == 1 ]]; then
  if [[ "$SIGN_IDENTITY" != 'Developer ID Application: '* ]] ||
      ! security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null; then
    echo '--release requires NOTCHISLAND_SIGN_IDENTITY with a valid Developer ID Application certificate and private key in Keychain.' >&2
    exit 2
  fi
fi

SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=("$ROOT"/Sources/NotchIsland/*.swift)

if [[ $UNIVERSAL == 1 ]]; then
  ARCHS=(arm64 x86_64)
elif [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
  ARCHS=(arm64)
else
  ARCHS=(x86_64)
fi

mkdir -p "$BUILD_DIR/obj"
STAGING="$(mktemp -d "$BUILD_DIR/.notchisland-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

BINARIES=()
for arch in "${ARCHS[@]}"; do
  out="$STAGING/$APP_NAME-$arch"
  echo "==> Compiling ($arch)"
  swiftc \
    -O -wmo \
    -file-prefix-map "$ROOT=." \
    -swift-version 5 \
    -module-name "$APP_NAME" \
    -sdk "$SDK" \
    -target "$arch-apple-macos$MIN_MACOS" \
    -framework AppKit -framework SwiftUI -framework Combine -framework IOKit -framework Security -framework LocalAuthentication \
    -o "$out" \
    "${SOURCES[@]}"
  BINARIES+=("$out")
done

if [[ ${#BINARIES[@]} -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/$APP_NAME"
else
  cp "${BINARIES[0]}" "$STAGED_APP/Contents/MacOS/$APP_NAME"
fi

cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT/Resources/NotchIsland.icns" "$STAGED_APP/Contents/Resources/"
if [[ -n "$BUNDLE_ID" ]]; then
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$STAGED_APP/Contents/Info.plist"
fi
for lproj in "$ROOT"/Resources/*.lproj; do
  cp -R "$lproj" "$STAGED_APP/Contents/Resources/"
done
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature by default: enough to run locally and to get permission prompts.
# Ad-hoc identity = the binary's hash, so macOS privacy grants (Accessibility /
# post events, Automation) don't survive a rebuild. To keep them, sign with a
# real identity, e.g. NOTCHISLAND_SIGN_IDENTITY="Apple Development: Name (TEAMID)".
if [[ $RELEASE == 1 ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
    --entitlements "$ROOT/Resources/DeveloperID.entitlements" "$STAGED_APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$STAGED_APP"
fi
codesign --verify --deep --strict --all-architectures "$STAGED_APP"

# Keep the previous working app until the new bundle has compiled and signed.
if [[ -e "$APP" ]]; then
  mv "$APP" "$STAGING/previous.app"
fi
if ! mv "$STAGED_APP" "$APP"; then
  [[ ! -e "$STAGING/previous.app" ]] || mv "$STAGING/previous.app" "$APP"
  exit 1
fi
for binary in "${BINARIES[@]}"; do
  cp "$binary" "$BUILD_DIR/obj/"
done

echo "==> Built $APP"

if [[ $RUN == 1 ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  open "$APP"
fi
