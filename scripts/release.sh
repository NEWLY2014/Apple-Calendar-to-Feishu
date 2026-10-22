#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${APPLE_FEISHU_DIST_DIR:-$ROOT_DIR/dist}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apple-feishu-release.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

APPLE_FEISHU_BUILD_DIR="$STAGING_DIR/build" APPLE_FEISHU_ARCHS="arm64 x86_64" "$ROOT_DIR/scripts/build.sh"
APP_PATH="$STAGING_DIR/build/Apple日历同步到飞书.app"
/usr/bin/xcrun lipo "$APP_PATH/Contents/MacOS/AppleToFeishuSync" -verify_arch arm64 x86_64
mkdir -p "$DIST_DIR" "$STAGING_DIR/dmg"
BASE_NAME="Apple-Calendar-to-Feishu-$VERSION-universal"
/usr/bin/ditto --norsrc --noextattr "$APP_PATH" "$STAGING_DIR/dmg/Apple日历同步到飞书.app"
ln -s /Applications "$STAGING_DIR/dmg/Applications"
cp "$ROOT_DIR/docs/安装说明.md" "$STAGING_DIR/dmg/安装说明.md"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR/dmg/Apple日历同步到飞书.app"
/usr/bin/hdiutil create -ov -volname "Apple Calendar to Feishu $VERSION" -srcfolder "$STAGING_DIR/dmg" -format UDZO "$DIST_DIR/$BASE_NAME.dmg"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$APP_PATH" "$DIST_DIR/$BASE_NAME.zip"
cp "$ROOT_DIR/docs/安装说明.md" "$DIST_DIR/INSTALL.md"
(cd "$DIST_DIR" && /usr/bin/shasum -a 256 "$BASE_NAME.dmg" "$BASE_NAME.zip" INSTALL.md > SHA256SUMS.txt)
printf 'Release artifacts: %s\n' "$DIST_DIR"
