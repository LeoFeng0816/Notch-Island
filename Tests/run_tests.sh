#!/usr/bin/env bash
# Compiles the app sources (minus the app entry point) with Tests/main.swift and runs them.
# Usage: Tests/run_tests.sh [--live]   (--live also calls the real providers)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests"
mkdir -p "$OUT"
SOURCES=()
for f in "$ROOT"/Sources/NotchIsland/*.swift; do
  [[ "$(basename "$f")" == "main.swift" ]] || SOURCES+=("$f")
done
swiftc -Onone -swift-version 5 -module-name NotchIslandTests \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework Combine -framework IOKit -framework Security -framework LocalAuthentication -framework JavaScriptCore \
  -o "$OUT/run-tests" "${SOURCES[@]}" "$ROOT/Tests/main.swift"
"$OUT/run-tests" "$@"
