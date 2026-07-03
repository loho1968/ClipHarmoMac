#!/bin/bash
# ============================================================
# ClipboardSync 中继服务器 —— 环境检查脚本
# 用法：在腾讯云轻量服务器上执行
#   curl -sL https://... | bash
#   或
#   chmod +x check_env.sh && bash check_env.sh
# ============================================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PASS=0
WARN=0
FAIL=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; WARN=$((WARN+1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   ClipboardSync 中继服务器环境检查             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================
# 1. 系统基本信息
# ============================================================
echo -e "${CYAN}━━━ 1. 系统信息 ━━━${NC}"
echo "  主机名: $(hostname)"
echo "  系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo '未知')"
echo "  内核: $(uname -r)"
echo "  架构: $(uname -m)"
echo "  当前用户: $(whoami)"
echo "  运行时间: $(uptime -p 2>/dev/null || uptime)"
echo ""

# ============================================================
# 2. Node.js 环境
# ============================================================
echo -e "${CYAN}━━━ 2. Node.js 环境 ━━━${NC}"

if command -v node &>/dev/null; then
    NODE_VER=$(node -v)
    NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v//' | cut -d. -f1)
    echo "  版本: $NODE_VER"
    echo "  路径: $(which node)"

    if [ "$NODE_MAJOR" -ge 20 ]; then
        pass "Node.js 版本满足要求 (>=20)"
    elif [ "$NODE_MAJOR" -ge 18 ]; then
        warn "Node.js >=18 可用，建议升级到 20+ (当前: $NODE_VER)"
    else
        fail "Node.js 版本过低，需要 >=18 (当前: $NODE_VER)"
    fi
else
    fail "Node.js 未安装！请安装 Node.js 18+"
fi

if command -v npm &>/dev/null; then
    echo "  npm 版本: $(npm -v)"
    echo "  npm 路径: $(which npm)"
    pass "npm 可用"

    # 检查 npm 镜像源连通性
    NPM_REGISTRY=$(npm config get registry 2>/dev/null)
    echo "  npm 镜像源: $NPM_REGISTRY"
else
    fail "npm 不可用"
fi
echo ""

# ============================================================
# 3. PM2 进程管理器
# ============================================================
echo -e "${CYAN}━━━ 3. PM2 进程管理器 ━━━${NC}"

if command -v pm2 &>/dev/null; then
    echo "  版本: $(pm2 -v)"
    echo "  路径: $(which pm2)"
    pass "PM2 已安装"
else
    warn "PM2 未安装（稍后可通过 npm install -g pm2 安装）"
fi
echo ""

# ============================================================
# 4. Nginx
# ============================================================
echo -e "${CYAN}━━━ 4. Nginx ━━━${NC}"

if command -v nginx &>/dev/null; then
    NGINX_VER=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
    echo "  版本: $NGINX_VER"
    echo "  路径: $(which nginx)"

    if nginx -t &>/dev/null 2>&1; then
        pass "Nginx 配置正常"
    else
        warn "Nginx 配置有误，请检查"
    fi
else
    warn "Nginx 未安装（如不需要 wss:// 反代可跳过）"
fi
echo ""

# ============================================================
# 5. Git
# ============================================================
echo -e "${CYAN}━━━ 5. Git ━━━${NC}"

if command -v git &>/dev/null; then
    echo "  版本: $(git --version)"
    pass "Git 可用"
else
    warn "Git 未安装（如通过 rsync 部署可跳过）"
fi
echo ""

# ============================================================
# 6. 端口占用检查
# ============================================================
echo -e "${CYAN}━━━ 6. 端口检查 ━━━${NC}"

check_port() {
    local port=$1
    local name=$2
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            PROC=$(ss -tlnp 2>/dev/null | grep ":$port " | awk '{print $NF}')
            warn "端口 $port ($name) 已被占用: $PROC"
        else
            pass "端口 $port ($name) 空闲"
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
            warn "端口 $port ($name) 已被占用"
        else
            pass "端口 $port ($name) 空闲"
        fi
    else
        warn "无法检查端口 $port (ss/netstat 不可用)"
    fi
}

check_port 3000 "中继 WS 服务（内部）"
check_port 8443 "中继 WSS 服务（外部）"
check_port 80   "HTTP"
check_port 443  "HTTPS"
echo ""

# ============================================================
# 7. 防火墙检查
# ============================================================
echo -e "${CYAN}━━━ 7. 防火墙 ━━━${NC}"

# 检查 firewalld
if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "  firewalld 运行中"
    if firewall-cmd --list-ports 2>/dev/null | grep -q "8443"; then
        pass "端口 8443 已开放 (firewalld)"
    else
        warn "端口 8443 未在 firewalld 中开放"
    fi
    if firewall-cmd --list-ports 2>/dev/null | grep -q "3000"; then
        pass "端口 3000 已开放 (firewalld)"
    else
        warn "端口 3000 未在 firewalld 中开放（内部端口可不开放）"
    fi
elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    echo "  ufw 运行中"
    ufw status verbose 2>/dev/null | grep -q "8443" && pass "端口 8443 已开放 (ufw)" || warn "端口 8443 未在 ufw 中开放"
elif command -v iptables &>/dev/null; then
    echo "  iptables 可用"
    if iptables -L INPUT -n 2>/dev/null | grep -q "8443"; then
        pass "端口 8443 在 iptables 中有规则"
    fi
else
    echo "  未检测到防火墙服务"
fi

echo ""
echo -e "  ${YELLOW}⚠ 注意：腾讯云轻量服务器还需在控制台「防火墙」中开放端口 8443${NC}"
echo ""
echo -e "  ${YELLOW}   操作路径：控制台 → 轻量应用服务器 → 防火墙 → 添加规则${NC}"
echo -e "  ${YELLOW}   协议: TCP, 端口: 8443, 策略: 允许${NC}"
echo ""

# ============================================================
# 8. 系统资源
# ============================================================
echo -e "${CYAN}━━━ 8. 系统资源 ━━━${NC}"

# CPU
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "未知")
echo "  CPU 核心数: $CPU_CORES"

# 内存
if command -v free &>/dev/null; then
    TOTAL_MEM=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
    AVAIL_MEM=$(free -m 2>/dev/null | awk '/Mem:/ {print $7}')
    echo "  总内存: ${TOTAL_MEM}MB"
    echo "  可用内存: ${AVAIL_MEM}MB"

    if [ "$AVAIL_MEM" -ge 256 ]; then
        pass "内存充足 (可用 ${AVAIL_MEM}MB >= 256MB)"
    else
        warn "可用内存较少 (${AVAIL_MEM}MB)，可能影响运行"
    fi
else
    warn "无法获取内存信息"
fi

# 磁盘
DISK_AVAIL=$(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}' || df -h / 2>/dev/null | awk 'NR==2 {print $4}')
DISK_PCT=$(df -h /opt 2>/dev/null | awk 'NR==2 {print $5}' || df -h / 2>/dev/null | awk 'NR==2 {print $5}')
echo "  磁盘可用: $DISK_AVAIL (已用 $DISK_PCT)"

# 检查 /opt 目录
if [ -d /opt ]; then
    if [ -w /opt ]; then
        pass "/opt 目录可写"
    else
        fail "/opt 目录不可写，请检查权限"
    fi
else
    warn "/opt 目录不存在，部署时会自动创建"
fi
echo ""

# ============================================================
# 9. 网络连通性
# ============================================================
echo -e "${CYAN}━━━ 9. 网络连通性 ━━━${NC}"

# 出站连通性
if curl -s --connect-timeout 5 https://registry.npmjs.org/ >/dev/null 2>&1; then
    pass "npm 镜像源可达 (registry.npmjs.org)"
elif curl -s --connect-timeout 5 https://registry.npmmirror.com/ >/dev/null 2>&1; then
    pass "npm 镜像源可达 (registry.npmmirror.com)"
else
    warn "npm 镜像源不可达，请检查网络"
fi

# 入站连通性（公网IP）
SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || \
            curl -s --connect-timeout 5 ip.sb 2>/dev/null || \
            curl -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || \
            echo "")
if [ -n "$SERVER_IP" ]; then
    pass "公网 IP: $SERVER_IP"
else
    warn "无法获取公网 IP"
fi

# DNS
if nslookup google.com >/dev/null 2>&1 || dig google.com >/dev/null 2>&1 || host google.com >/dev/null 2>&1; then
    pass "DNS 解析正常"
else
    warn "DNS 可能有问题"
fi
echo ""

# ============================================================
# 10. 其他工具
# ============================================================
echo -e "${CYAN}━━━ 10. 其他依赖 ━━━${NC}"

# systemd / PM2 startup
if command -v systemctl &>/dev/null; then
    pass "systemd 可用（PM2 可配置开机自启）"
elif command -v service &>/dev/null; then
    warn "systemd 不可用，但 service 命令可用"
else
    warn "建议安装 systemd 以支持 PM2 开机自启"
fi

# tar（用于打包部署）
command -v tar &>/dev/null && pass "tar 可用" || warn "tar 不可用"

# rsync（用于同步部署）
command -v rsync &>/dev/null && pass "rsync 可用" || warn "rsync 不可用（如通过 Git 部署可跳过）"

# curl
command -v curl &>/dev/null && pass "curl 可用" || warn "curl 不可用"

# OpenSSL (用于生成证书)
if command -v openssl &>/dev/null; then
    echo "  OpenSSL 版本: $(openssl version 2>/dev/null | head -1)"
    pass "OpenSSL 可用"
else
    warn "OpenSSL 不可用"
fi
echo ""

# ============================================================
# 11. 总结
# ============================================================
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              检查结果汇总                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}通过: $PASS${NC}"
echo -e "  ${YELLOW}警告: $WARN${NC}"
echo -e "  ${RED}失败: $FAIL${NC}"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}  存在 $FAIL 项失败，请先修复后再部署！${NC}"
    echo ""
    echo -e "  ${YELLOW}常见修复命令：${NC}"
    echo "    # 安装 Node.js 20 (使用 nvm)"
    echo "    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash"
    echo "    source ~/.bashrc && nvm install 20"
    echo ""
    echo "    # 安装 PM2"
    echo "    npm install -g pm2"
    echo ""
    echo "    # 安装 Nginx"
    echo "    yum install -y nginx    # CentOS/RHEL"
    echo "    apt install -y nginx    # Ubuntu/Debian"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e "${YELLOW}  存在 $WARN 项警告，建议处理后再部署。${NC}"
    echo ""
    echo -e "${YELLOW}  如仅使用 rsync 或 scp 部署（不用 Git），Git 缺失可忽略。${NC}"
    echo -e "${YELLOW}  如使用服务器 IP 直连（不走 wss://），Nginx 缺失可忽略。${NC}"
    exit 0
else
    echo -e "${GREEN}  一切就绪！可以开始部署中继服务了。${NC}"
    echo ""
    echo -e "  ${CYAN}下一步：${NC}"
    echo "    1. 将代码同步到服务器"
    echo "    2. cd /opt/relay-server && npm install"
    echo "    3. pm2 start ecosystem.config.js"
    echo "    4. (可选) 配置 Nginx 反代 + SSL"
    echo "    5. 在腾讯云控制台开放 8443 端口"
    exit 0
fi
