#!/usr/bin/env bash
# 制作同时支持 Intel / Apple 芯片的 macOS 下载包。
set -euo pipefail
cd "$(dirname "$0")/.."

# Fail before compiling if this machine cannot sign updates with the embedded key.
SPARKLE=$(bash scripts/fetch_sparkle.sh)
python3 scripts/update_keys.py check
./build.sh universal
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
STAGE=$(mktemp -d "$PWD/build/enote-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
OUTPUT="$STAGE/release"
PAYLOAD="$STAGE/payload"
mkdir -p "$OUTPUT"
mkdir -p "$PAYLOAD"

ditto "build/E note.app" "$PAYLOAD/E note.app"
ln -s /Applications "$PAYLOAD/Applications"
cp docs/INSTALL.txt "$PAYLOAD/安装说明.txt"
cp LICENSE "$PAYLOAD/LICENSE.txt"

hdiutil create -volname "E note $VERSION" -srcfolder "$PAYLOAD" \
  -format UDZO -ov "$OUTPUT/E-note-macOS-universal.dmg"
ditto -c -k --sequesterRsrc --keepParent "build/E note.app" "$OUTPUT/E-note-macOS-universal.zip"
python3 scripts/generate_appcast.py --archive "$OUTPUT/E-note-macOS-universal.zip" \
  --sparkle "$SPARKLE" --output "$OUTPUT/appcast.xml" \
  --notes "docs/releases/v$VERSION.md"
cp docs/INSTALL.txt "$OUTPUT/INSTALL.txt"
(
  cd "$OUTPUT"
  shasum -a 256 E-note-macOS-universal.dmg E-note-macOS-universal.zip appcast.xml > SHA256SUMS.txt
)
# A failed signature check must not leave new packages beside an old appcast.
rm -rf build/release
mv "$OUTPUT" build/release
echo "==> 下载包已生成：build/release（版本 $VERSION）"
