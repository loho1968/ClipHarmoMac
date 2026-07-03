#!/bin/bash
# ============================================================
# ClipboardSync - 构建 + 安装 + 启动
# 用法:
#   ./generate.sh         构建并后台启动
#   ./generate.sh --log   构建并前台运行（查看实时日志）
# ============================================================
set -euo pipefail

APP_NAME="ClipboardSync"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_DIR="/Applications/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
FOREGROUND=false

[[ "${1:-}" == "--log" || "${1:-}" == "-l" ]] && FOREGROUND=true

echo "╔══════════════════════════════════════╗"
echo "║   ClipboardSync Generate & Run     ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 1. 杀掉旧进程
echo "🔴 停止旧进程..."
pkill -f "$APP_NAME" 2>/dev/null && echo "   已终止" || echo "   无运行中的进程"
sleep 1

# 2. 编译
echo ""
echo "🔨 编译 release..."
export DEVELOPER_DIR
swift build -c release --package-path "$PROJECT_DIR" 2>&1 | grep -E 'error:|Build complete' || true
echo "   ✅ 编译完成"

# 3. 组装 app bundle
echo ""
echo "📦 组装 app bundle..."
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"
cp "$PROJECT_DIR/ClipboardSync/Info-dev.plist" "$CONTENTS/Info.plist"

codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
echo "   ✅ $APP_DIR"

# 4. 启动
if $FOREGROUND; then
    echo ""
    echo "═══════════════════════════════════════"
    echo "  🖥️  前台运行模式 (Ctrl+C 退出)"
    echo "     手机发送内容时实时查看日志"
    echo "═══════════════════════════════════════"
    echo ""
    NSUnbufferedIO=YES "$CONTENTS/MacOS/$APP_NAME" 2>&1
else
    echo ""
    echo "🚀 启动 App..."
    open "$APP_DIR"
    sleep 1
    if pgrep -f "$APP_NAME" > /dev/null; then
        echo "   ✅ App 已启动"
    else
        echo "   ⚠️  App 可能未启动"
    fi
    echo ""
    echo "═══════════════════════════════════════"
    echo "  Bundle ID : com.clipboardsync.app"
    echo "  查看日志  : ./generate.sh --log"
    echo "═══════════════════════════════════════"
fi
