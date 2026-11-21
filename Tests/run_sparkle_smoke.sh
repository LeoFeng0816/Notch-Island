#!/usr/bin/env bash
# End-to-end updater test with disposable ad-hoc apps, a local feed, and an ephemeral
# key. Runs the real Sparkle downloader, verifier, installer and relaunch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE="$("$ROOT/scripts/fetch_sparkle.sh")"
OUTPUT="$ROOT/build/sparkle-smoke"
mkdir -p "$OUTPUT"
umask 077
WORK="$(mktemp -d)"
SERVER=""
ACTIVE=""

cleanup() {
  [[ -z "$ACTIVE" ]] || kill "$ACTIVE" 2>/dev/null || true
  [[ -z "$SERVER" ]] || kill "$SERVER" 2>/dev/null || true
  if [[ -f "$WORK/bundle-ids" ]]; then
    while IFS= read -r bundle; do
      rm -rf "$HOME/Library/Caches/$bundle" "$HOME/Library/Preferences/$bundle.plist"
    done < "$WORK/bundle-ids"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

xcrun clang -fobjc-arc -F "$SPARKLE" -framework AppKit -framework Sparkle \
  -Wl,-rpath,@executable_path/../Frameworks "$ROOT/Tests/SparkleUpdateFixture.m" -o "$WORK/Smoke"
cat > "$WORK/key.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let secret = URL(fileURLWithPath: CommandLine.arguments[1])
try key.rawRepresentation.base64EncodedString().write(to: secret, atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
swift "$WORK/key.swift" "$WORK/test-key" > "$WORK/public-key"
mkdir "$WORK/web"
python3 - "$WORK" > "$OUTPUT/http.log" 2>&1 <<'PY' &
import functools
import http.server
import pathlib
import sys

scratch = pathlib.Path(sys.argv[1])
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=scratch / "web")
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
(scratch / "port").write_text(str(server.server_address[1]))
server.serve_forever()
PY
SERVER=$!
for ((attempt=0; attempt<30; attempt++)); do
  [[ ! -s "$WORK/port" ]] || break
  sleep 0.1
done
PORT="$(cat "$WORK/port")"

for scenario in tampered-feed tampered-dmg cancel valid; do
  TEST="$WORK/$scenario"
  WEB="$WORK/web/$scenario"
  mkdir -p "$TEST" "$WEB"
  ID="local.notchisland.fixture.$(uuidgen | tr '[:upper:]' '[:lower:]').$scenario.app"
  printf '%s\n' "$ID" >> "$WORK/bundle-ids"
  for build in 1 2; do
    APP="$TEST/$build/Update Fixture.app"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
    ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    cp "$WORK/Smoke" "$APP/Contents/MacOS/Smoke"
    python3 - "$APP" "$TEST" "$WORK/public-key" "$PORT" "$scenario" "$ID" "$build" <<'PY'
import pathlib
import plistlib
import sys

app, test, public_key = map(pathlib.Path, sys.argv[1:4])
port, scenario, bundle_id, build = sys.argv[4:]
props = {
    "CFBundleIdentifier": bundle_id,
    "CFBundleExecutable": "Smoke",
    "CFBundleName": "Isolated Notch Island Update Fixture",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": build,
    "CFBundleShortVersionString": "0.1." + build,
    "CFBundleDevelopmentRegion": "en",
    "LSUIElement": True,
    "SUFeedURL": f"http://127.0.0.1:{port}/{scenario}/feed.xml",
    "SUPublicEDKey": public_key.read_text().strip(),
    "SUVerifyUpdateBeforeExtraction": True,
    "SURequireSignedFeed": True,
    "SUSignedFeedFailureExpirationInterval": 0,
    "SUEnableAutomaticChecks": False,
    "SUAllowsAutomaticUpdates": False,
    "SmokeReceipt": str(test / "receipt"),
}
(app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(props))
PY
    codesign --force --sign - "$APP"
    codesign --verify --deep --strict "$APP"
  done
  hdiutil create -quiet -fs HFS+ -format UDZO -srcfolder "$TEST/2" "$WEB/fixture.dmg"
  SIGNATURE="$("$SPARKLE/bin/sign_update" --ed-key-file "$WORK/test-key" -p "$WEB/fixture.dmg")"
  LENGTH="$(stat -f '%z' "$WEB/fixture.dmg")"
  cat > "$WEB/feed.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Fixture feed</title><item><title>Fixture update</title>
<sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.1.2</sparkle:shortVersionString>
<enclosure url="http://127.0.0.1:$PORT/$scenario/fixture.dmg" sparkle:edSignature="$SIGNATURE" length="$LENGTH" type="application/octet-stream"/>
</item></channel>
</rss>
XML
  "$SPARKLE/bin/sign_update" --ed-key-file "$WORK/test-key" "$WEB/feed.xml" >/dev/null
  if [[ "$scenario" == tampered-dmg ]]; then
    python3 - "$WEB/fixture.dmg" <<'PY'
import pathlib
import sys

image = pathlib.Path(sys.argv[1])
with image.open("r+b") as file:
    file.seek(64)
    byte = file.read(1)
    file.seek(64)
    file.write(bytes([byte[0] ^ 1]))
PY
  elif [[ "$scenario" == tampered-feed ]]; then
    python3 - "$WEB/feed.xml" <<'PY'
import pathlib
import sys

feed = pathlib.Path(sys.argv[1])
feed.write_bytes(feed.read_bytes().replace(b"Fixture update", b"Changed update", 1))
PY
  fi
  APP="$TEST/1/Update Fixture.app"
  LOG="$OUTPUT/$scenario.log"
  set --
  if [[ "$scenario" == cancel ]]; then set -- --cancel; fi
  "$APP/Contents/MacOS/Smoke" "$@" > "$LOG" 2>&1 &
  ACTIVE=$!
  for ((attempt=0; attempt<50; attempt++)); do
    if [[ "$scenario" == valid ]] && [[ -r "$TEST/receipt" ]] && [[ "$(cut -d ' ' -f 1 "$TEST/receipt")" == 2 ]]; then
      break
    elif [[ "$scenario" != valid ]] && ! kill -0 "$ACTIVE" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  case "$scenario" in
    valid)
      [[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == 2 ]]
      [[ "$(cat "$TEST/receipt")" == "2 $(cd "$APP" && pwd -P)" ]]
      sleep 2
      ;;
    cancel)
      [[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == 1 ]]
      ! rg -q "GET /$scenario/fixture.dmg" "$OUTPUT/http.log"
      ;;
    *)
      [[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == 1 ]]
      rg -qi 'signature|improperly signed|verification|validation|verify' "$LOG"
      ! rg -q 'extracting after signature verification' "$LOG"
      ;;
  esac
  kill "$ACTIVE" 2>/dev/null || true
  wait "$ACTIVE" 2>/dev/null || true
  ACTIVE=""
  echo "Sparkle $scenario passed"
done
