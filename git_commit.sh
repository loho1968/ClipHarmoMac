#!/bin/bash
# Git 提交脚本：暂存所有修改和新增文件并提交
# 用法：./git_commit.sh [提交消息]

COMMIT_MSG="${1:-临时提交}"

git add -A
git commit -m "$COMMIT_MSG"
git push origin main
echo "提交成功：$COMMIT_MSG"