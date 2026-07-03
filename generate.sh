#!/bin/bash
# ============================================
# ClipboardSync 一键生成脚本
# 用法:
#   ./generate.sh         构建并后台启动
#   ./generate.sh --log   构建并前台运行（查看实时日志）
# ============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo "  ClipboardSync 一键生成"
echo "========================================="

# ---- 1. 杀掉旧进程 ----
echo ""
echo "[1/2] 停止正在运行的 ClipboardSync..."
pkill -f ClipboardSync 2>/dev/null && echo "  已终止" || echo "  无运行中的进程"
sleep 1

# ---- 2. 构建 Mac App ----
echo ""
echo "[2/2] 构建 Mac App..."
bash "$SCRIPT_DIR/ClipboardSync/mac/generate.sh" "${1:-}"

echo ""
echo "========================================="
echo "  全部完成！"
echo "========================================="
