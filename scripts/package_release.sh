#!/usr/bin/env bash
# 制作同时支持 Intel / Apple 芯片的 macOS 下载包。
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh universal
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
OUTPUT="build/release"
STAGE=$(mktemp -d "$PWD/build/enote-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUTPUT"

ditto "build/E note.app" "$STAGE/E note.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.txt "$STAGE/安装说明.txt"
cp LICENSE "$STAGE/LICENSE.txt"

hdiutil create -volname "E note $VERSION" -srcfolder "$STAGE" \
  -format UDZO -ov "$OUTPUT/E-note-macOS-universal.dmg"
ditto -c -k --sequesterRsrc --keepParent "build/E note.app" "$OUTPUT/E-note-macOS-universal.zip"
cp docs/INSTALL.txt "$OUTPUT/INSTALL.txt"
(
  cd "$OUTPUT"
  shasum -a 256 E-note-macOS-universal.dmg E-note-macOS-universal.zip > SHA256SUMS.txt
)
echo "==> 下载包已生成：$OUTPUT（版本 $VERSION）"
