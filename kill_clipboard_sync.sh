#!/bin/bash
# 杀掉所有 ClipboardSync 进程，然后重新编译并启动

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pids=$(pgrep -x ClipboardSync)
if [ -z "$pids" ]; then
    echo "没有 ClipboardSync 进程在运行"
else
    echo "找到 ClipboardSync 进程: $pids"
    kill $pids
    sleep 1
    # 检查是否还有残留
    remaining=$(pgrep -x ClipboardSync)
    if [ -z "$remaining" ]; then
        echo "已成功终止所有 ClipboardSync 进程"
    else
        echo "部分进程未响应，强制终止: $remaining"
        kill -9 $remaining
        echo "已强制终止"
    fi
fi

# 启动（start.sh 内部已包含编译和运行）
exec "$SCRIPT_DIR/ClipboardSync/mac/ClipboardSync/start.sh"