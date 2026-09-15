#!/usr/bin/env bash
# E note 图标构建 — 作者：韦冬 2220285589@qq.com
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/enote-icon.XXXXXX")"
trap 'rm -rf "$ICON_BUILD_DIR"' EXIT
swiftc -O assets/make_icon.swift -o "$ICON_BUILD_DIR/make_icon"
"$ICON_BUILD_DIR/make_icon"
mkdir -p "$ICON_BUILD_DIR/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/icon-1024.png --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/icon-1024.png --out "$ICON_BUILD_DIR/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_BUILD_DIR/AppIcon.iconset" -o assets/AppIcon.icns
printf '生成：assets/AppIcon.icns\n'
