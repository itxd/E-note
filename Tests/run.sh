#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
SPARKLE=$(bash scripts/fetch_sparkle.sh)
SOURCES=()
for source in Sources/*.swift; do
  [ "$source" = Sources/Main.swift ] || SOURCES+=("$source")
done
swiftc -Onone -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE" \
  "${SOURCES[@]}" Tests/*.swift -o build/enote-tests
python3 Tests/test_api.py
