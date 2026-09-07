#!/usr/bin/env bash
# Builds a release binary and wraps it into CSwapBar.app (LSUIElement, no
# Dock icon) so it behaves like a normal menu bar app instead of a dev build.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building universal release binary…"
swift build -c release --arch arm64 --arch x86_64

APP_DIR="$ROOT_DIR/dist/CSwapBar.app"
CONTENTS="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$ROOT_DIR/.build/apple/Products/Release/CSwapBar" "$CONTENTS/MacOS/CSwapBar"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"


echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run it directly with: open \"$APP_DIR\""
echo "It registers itself as a login item on first launch."
