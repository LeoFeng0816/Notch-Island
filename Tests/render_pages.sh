#!/usr/bin/env bash
# Renders island subpages off-screen (synthetic data, mocked network) to build/qa/pages.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/qa/pages"
mkdir -p "$OUT" "$ROOT/build/tests"
SOURCES=()
for f in "$ROOT"/Sources/NotchIsland/*.swift; do
  [[ "$(basename "$f")" == "main.swift" ]] || SOURCES+=("$f")
done
swiftc -Onone -swift-version 5 -parse-as-library -module-name NotchIslandRender \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework Combine -framework IOKit -framework Security -framework LocalAuthentication \
  -o "$ROOT/build/tests/render-pages" "${SOURCES[@]}" "$ROOT/Tests/render_pages.swift"
"$ROOT/build/tests/render-pages" "$OUT"
