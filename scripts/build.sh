#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${APPLE_FEISHU_BUILD_DIR:-$ROOT_DIR/build}"
APP_PATH="$BUILD_DIR/Apple日历同步到飞书.app"
ARCHS="${APPLE_FEISHU_ARCHS:-$(uname -m)}"

mkdir -p "$APP_PATH/Contents/MacOS" "$BUILD_DIR/objects"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
BINARIES=()
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64|x86_64) ;;
    *) printf 'Unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
  esac
  BINARY="$BUILD_DIR/objects/AppleToFeishuSync-$ARCH"
  /usr/bin/xcrun swiftc \
    -swift-version 5 \
    -O \
    -target "${ARCH}-apple-macosx14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -framework Cocoa \
    -framework EventKit \
    -framework CryptoKit \
    "$ROOT_DIR/Sources/AppleToFeishuSync.swift" \
    -o "$BINARY"
  BINARIES+=("$BINARY")
done
/usr/bin/xcrun lipo -create "${BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/AppleToFeishuSync"
# Remove Finder metadata that prevents ad-hoc signing.
/usr/bin/xattr -cr "$APP_PATH"
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
