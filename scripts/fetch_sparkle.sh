#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
CACHE="$PWD/.build/sparkle"
ARCHIVE="$CACHE/Sparkle-$VERSION.tar.xz"
DEST="$CACHE/$VERSION"
mkdir -p "$CACHE"
if [ ! -f "$ARCHIVE" ]; then
  curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
    -o "$ARCHIVE.partial"
  mv "$ARCHIVE.partial" "$ARCHIVE"
fi
ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "Sparkle 校验失败，请删除 $ARCHIVE 后重试。" >&2
  exit 1
fi
# Extract only the pinned, verified distribution; never trust a stale framework cache.
mkdir -p "$DEST"
tar -xf "$ARCHIVE" -C "$DEST"
echo "$DEST"
