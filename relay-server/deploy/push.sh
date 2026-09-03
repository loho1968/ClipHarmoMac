#!/bin/bash
# ============================================================
# ClipboardSync 中继服务器 —— 增量部署脚本（在本机执行）
# @file relay-server/deploy/push.sh
# @author loho
#
# 用法:
#   bash deploy/push.sh            推送代码到服务器并重启
#   bash deploy/push.sh rollback   回滚到最近一次备份
#
# 流程: 本地语法检查 → 远端备份 → rsync 同步 → 依赖检查
#       → 远端语法检查 → 运行目录校验 + pm2 重启 → 健康检查（失败自动回滚）
# ============================================================
set -euo pipefail

# ---- 配置（按需修改） ----
SSH_HOST="tencent"                                  # ~/.ssh/config 中的主机别名
REMOTE_DIR="/opt/harmony-and-mac/relay-server"      # 服务器上的项目目录
PM2_APP="clipboardsync-relay"
HEALTH_URL="http://localhost:3000/health"
BACKUP_KEEP=5                                       # 服务器上保留的备份份数

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "${CYAN}[..]${NC} $1"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "用法: bash deploy/push.sh [push|rollback]"
  echo "  push      默认，推送代码到服务器并重启（健康检查失败自动回滚）"
  echo "  rollback  回滚到服务器上最近一次备份"
}

# 本地语法检查：src 下所有 js 必须通过 node --check
preflight() {
  step "1/6 本地语法检查..."
  local f
  for f in "$PROJECT_DIR"/src/*.js; do
    node --check "$f"
  done
  ok "本地 src/*.js 语法全部通过"
}

# 远端备份 src + package.json + ecosystem.config.js（保留最近 BACKUP_KEEP 份）
remote_backup() {
  step "2/6 远端备份..."
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  ssh "$SSH_HOST" "cd '$REMOTE_DIR' && mkdir -p backups && \
    tar czf backups/relay-$ts.tar.gz src package.json ecosystem.config.js 2>/dev/null; \
    cd backups && ls -t relay-*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f"
  ok "已备份为 backups/relay-$ts.tar.gz（保留最近 $BACKUP_KEEP 份）"
}

# rsync 同步（不带 --delete，服务器端多余文件不会被误删）
sync_files() {
  step "3/6 rsync 同步..."
  local pkg_before pkg_after
  pkg_before="$(ssh "$SSH_HOST" "md5sum '$REMOTE_DIR/package.json' 2>/dev/null | cut -d' ' -f1" || true)"
  rsync -a \
    --exclude 'node_modules' \
    --exclude 'logs' \
    --exclude 'backups' \
    --exclude 'deploy' \
    --exclude '.git' \
    "$PROJECT_DIR/src" "$PROJECT_DIR/package.json" "$PROJECT_DIR/ecosystem.config.js" \
    "$SSH_HOST:$REMOTE_DIR/"
  pkg_after="$(ssh "$SSH_HOST" "md5sum '$REMOTE_DIR/package.json' 2>/dev/null | cut -d' ' -f1" || true)"
  if [ -n "$pkg_before" ] && [ "$pkg_before" != "$pkg_after" ]; then
    step "package.json 有变化，安装依赖..."
    ssh "$SSH_HOST" "cd '$REMOTE_DIR' && npm install --production --no-audit --no-fund"
    ok "依赖安装完成"
  else
    ok "同步完成（package.json 无变化，跳过依赖安装）"
  fi
}

# 远端语法检查：部署文件损坏时在重启前拦下
remote_check() {
  step "4/6 远端语法检查..."
  ssh "$SSH_HOST" "cd '$REMOTE_DIR' && for f in src/*.js; do node --check \"\$f\" || exit 1; done"
  ok "远端 src/*.js 语法全部通过"
}

# 重启服务并做健康检查，失败自动回滚
restart_and_verify() {
  step "5/6 校验运行目录并重启 $PM2_APP..."
  local pid actual
  # 防回归：若 PM2 应用被人手动 start 到了别的目录，restart 会重启到旧/错误代码，
  # 因此重启前先核对运行进程的工作目录是否就是部署目录。
  pid="$(ssh "$SSH_HOST" "pm2 pid $PM2_APP 2>/dev/null" | tr -d '[:space:]' || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" != "0" ]; then
    actual="$(ssh "$SSH_HOST" "readlink /proc/$pid/cwd 2>/dev/null" | tr -d '[:space:]')"
    if [ -n "$actual" ] && [ "$actual" != "$REMOTE_DIR" ]; then
      fail "PM2 应用 $PM2_APP 运行目录异常: $actual (期望 $REMOTE_DIR)"
      fail "多半是有人在服务器上手动 pm2 start 到了别的目录。本次中止，避免重启到错误代码。"
      echo "    修复命令: ssh $SSH_HOST \"pm2 delete $PM2_APP && cd $REMOTE_DIR && pm2 start ecosystem.config.js && pm2 save\""
      fail "(代码已同步到 $REMOTE_DIR, 但未重启; 修复后重跑 push.sh 即可)"
      return 1
    fi
    ok "运行目录校验通过 ($actual)"
    ssh "$SSH_HOST" "cd '$REMOTE_DIR' && pm2 restart $PM2_APP --update-env >/dev/null"
  else
    ok "应用 $PM2_APP 当前未运行/未注册，从部署目录全新启动"
    ssh "$SSH_HOST" "cd '$REMOTE_DIR' && pm2 start ecosystem.config.js && pm2 save >/dev/null"
  fi
  ok "已重启/启动"

  step "6/6 健康检查..."
  local i health
  for i in 1 2 3 4 5 6 7 8 9 10; do
    health="$(ssh "$SSH_HOST" "curl -s --max-time 3 '$HEALTH_URL'" || true)"
    if echo "$health" | grep -q '"status":"ok"'; then
      ok "$health"
      echo ""
      ok "部署成功"
      return 0
    fi
    sleep 1
  done
  fail "健康检查未通过: $health"
  fail "自动回滚到本次部署前的状态..."
  rollback
  return 1
}

# 回滚到服务器上最近一次备份
rollback() {
  step "回滚到最近一次备份..."
  ssh "$SSH_HOST" "cd '$REMOTE_DIR' && \
    latest=\$(ls -t backups/relay-*.tar.gz 2>/dev/null | head -1) && \
    test -n \"\$latest\" && tar xzf \"\$latest\" && \
    pm2 restart $PM2_APP --update-env >/dev/null && \
    echo \"已回滚: \$latest\""
  ok "回滚完成，请手动确认服务状态: ssh $SSH_HOST 'pm2 logs $PM2_APP --lines 20'"
}

main() {
  echo ""
  echo "========================================================"
  echo "  ClipboardSync 中继服务器增量部署"
  echo "  目标: $SSH_HOST:$REMOTE_DIR"
  echo "========================================================"
  echo ""
  preflight
  remote_backup
  sync_files
  remote_check
  restart_and_verify
}

case "${1:-push}" in
  push)
    main
    ;;
  rollback)
    rollback
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
