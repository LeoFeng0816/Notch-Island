#!/usr/bin/env bash
# Sparkle is distributed under its upstream open-source license.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
CACHE="$ROOT/build/sparkle"
ARCHIVE="Sparkle-$VERSION.tar.xz"
SOURCE="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/$ARCHIVE"
DESTINATION="$CACHE/$VERSION"
mkdir -p "$CACHE"
if [[ ! -f "$CACHE/$ARCHIVE" ]]; then
  PART="$(mktemp "$CACHE/.sparkle-download.XXXXXX")"
  trap 'rm -f "$PART"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 180 "$SOURCE" -o "$PART"
  printf '%s  %s\n' "$SHA256" "$PART" | shasum -a 256 --check >&2
  mv "$PART" "$CACHE/$ARCHIVE"
  trap - EXIT
fi
printf '%s  %s\n' "$SHA256" "$CACHE/$ARCHIVE" | shasum -a 256 --check >&2
if [[ ! -d "$DESTINATION" ]]; then
  STAGE="$(mktemp -d "$CACHE/.sparkle-extract.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  tar -xJf "$CACHE/$ARCHIVE" -C "$STAGE"
  mv "$STAGE" "$DESTINATION"
  trap - EXIT
fi
printf '%s\n' "$DESTINATION"
