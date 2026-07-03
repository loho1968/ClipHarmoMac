#!/bin/bash
# ============================================================
# ClipboardSync macOS App Bundle 构建脚本
# ============================================================
set -euo pipefail

APP_NAME="ClipboardSync"
PROJECT_DIR="/Users/loho/Developer/harmony-and-mac/ClipboardSync/mac"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_DIR="/Applications/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "========================================"
echo " ClipboardSync App Bundle Builder"
echo "========================================"
echo ""

# 1. 编译 release 二进制
echo "[1/4] Building release binary..."
export DEVELOPER_DIR
swift build -c release --package-path "$PROJECT_DIR"
echo "  ✅ Build complete"

# 2. 创建 app bundle 目录结构
echo "[2/4] Creating app bundle structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
echo "  ✅ $APP_DIR"

# 3. 复制二进制 + Info.plist
echo "[3/4] Copying files..."
cp "$BUILD_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$PROJECT_DIR/ClipboardSync/Info-dev.plist" "$CONTENTS/Info.plist"
echo "  ✅ Binary + Info.plist (Bundle ID: com.clipboardsync.app)"

# 4. 清除旧签名 + ad-hoc 签名
echo "[4/4] Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null && \
    echo "  ✅ Signed" || \
    echo "  ⚠️  codesign not available (optional)"

echo ""
echo "========================================"
echo " ✅ App bundle ready: $APP_DIR"
echo "========================================"
echo ""
echo "  启动: open $APP_DIR"
echo "  日志: log stream --predicate 'process == \"ClipboardSync\"' --level debug"
echo "  终端: $MACOS_DIR/$APP_NAME"
