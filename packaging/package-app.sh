#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift package clean
swift build -c release

BUILD_DIR="$ROOT/.build/arm64-apple-macosx/release"
APP="$ROOT/outputs/MacPet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/MacPet" "$APP/Contents/MacOS/MacPet"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp -R "$BUILD_DIR/MacPet_MacPet.bundle" "$APP/Contents/Resources/MacPet_MacPet.bundle"
codesign --force --deep --sign - "$APP"
echo "$APP"
