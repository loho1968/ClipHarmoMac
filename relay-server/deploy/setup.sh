#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  ClipboardSync 中继服务器 一键部署          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# 1. 检查 Node.js
echo -e "${CYAN}[1/5] 检查 Node.js...${NC}"
if ! command -v node &>/dev/null; then
    echo -e "${RED}Node.js 未安装！${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Node.js $(node -v)"

# 2. 安装 PM2
echo -e "${CYAN}[2/5] 安装 PM2...${NC}"
if command -v pm2 &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} PM2 已安装 ($(pm2 -v))"
else
    npm install -g pm2
    echo -e "  ${GREEN}✓${NC} PM2 安装完成"
fi

# 3. 安装依赖
echo -e "${CYAN}[3/5] 安装依赖...${NC}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
npm install --production
mkdir -p "$PROJECT_DIR/logs"
echo -e "  ${GREEN}✓${NC} 依赖安装完成"

# 4. 启动 PM2
echo -e "${CYAN}[4/5] 启动服务...${NC}"
if pm2 list 2>/dev/null | grep -q "clipboardsync-relay"; then
    pm2 reload ecosystem.config.js
    echo -e "  ${GREEN}✓${NC} 服务重载完成"
else
    pm2 start ecosystem.config.js
    pm2 save
    pm2 startup 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} 服务启动完成，已设置开机自启"
fi

# 5. 验证
echo -e "${CYAN}[5/5] 验证...${NC}"
sleep 2
pm2 list 2>/dev/null | grep clipboardsync-relay

if curl -s http://localhost:3000/health >/dev/null 2>&1; then
    echo ""
    echo -e "${GREEN}✓${NC} 健康检查通过:"
    curl -s http://localhost:3000/health
else
    echo -e "${YELLOW}⚠${NC} 健康检查失败，查看日志: pm2 logs clipboardsync-relay"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  部署完成！                               ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  WS 地址:  ws://<服务器IP>:3000           ║${NC}"
echo -e "${GREEN}║  状态页面: http://<服务器IP>:3000          ║${NC}"
echo -e "${GREEN}║  健康检查: http://<服务器IP>:3000/health    ║${NC}"
echo -e "${GREEN}║  查看日志: pm2 logs clipboardsync-relay    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}别忘了：腾讯云控制台防火墙开放 3000 端口${NC}"
echo ""
