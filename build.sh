#!/usr/bin/env bash
# E note 构建脚本:swiftc 直编译,组装 .app,ad-hoc 签名。
# 用法:./build.sh [release|debug|run|universal]   默认 release
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
TARGET="$(uname -m)-apple-macosx13.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="build/E note.app"
BIN="build/E note"

mkdir -p build

if [ ! -f assets/AppIcon.icns ] || [ ! -f assets/icon-1024.png ] || \
   [ assets/make_icon.swift -nt assets/AppIcon.icns ] || \
   [ assets/build-icon.sh -nt assets/AppIcon.icns ]; then
  ./assets/build-icon.sh
fi

case "$MODE" in
  debug) OPT=(-Onone) ;;
  release|run|universal) OPT=(-O) ;;
  *) echo "用法: $0 [release|debug|run|universal]" >&2; exit 2 ;;
esac

if [ "$MODE" = "universal" ]; then
  for ARCH in x86_64 arm64; do
    echo "==> 编译 ($ARCH, release)"
    swiftc "${OPT[@]}" -target "$ARCH-apple-macosx13.0" -sdk "$SDK" Sources/*.swift -o "$BIN-$ARCH"
  done
  lipo -create "$BIN-x86_64" "$BIN-arm64" -output "$BIN"
else
  echo "==> 编译 ($TARGET, $MODE)"
  swiftc "${OPT[@]}" -target "$TARGET" -sdk "$SDK" Sources/*.swift -o "$BIN"
fi

echo "==> 组装 $APP"
rm -rf "$APP" "build/Noty.app" "build/Noty"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/E note"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp assets/cloud-server.json "$APP/Contents/Resources/cloud-server.json"
cp LICENSE "$APP/Contents/Resources/LICENSE"

echo "==> 签名"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 完成:$APP"
if [ "$MODE" = "run" ]; then
  open "$APP"
fi
