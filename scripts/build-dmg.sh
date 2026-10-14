#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 1. 确保构建最新的 App
"$PROJECT_DIR/scripts/build-app.sh"

APP_PATH="$PROJECT_DIR/build/Oil Find.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.6.2-plus")"
DMG_NAME="OilFind-Plus-v${VERSION}-macOS-arm64.dmg"
DMG_PATH="$PROJECT_DIR/build/$DMG_NAME"
STAGING_DIR="$PROJECT_DIR/build/dmg_staging"

echo "Building DMG: $DMG_NAME ..."

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

# 复制 App 到 staging 目录，保留属性和签名
ditto "$APP_PATH" "$STAGING_DIR/Oil Find.app"

# 创建指向 /Applications 的软链接，方便用户拖拽安装
ln -s /Applications "$STAGING_DIR/Applications"

# 生成压缩只读 DMG
hdiutil create \
    -volname "Oil Find Plus" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "DMG created at: $DMG_PATH"
shasum -a 256 "$DMG_PATH"
