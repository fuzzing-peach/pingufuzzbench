#!/bin/bash

# 简洁的 git 备份脚本

set -e

# 检查是否在 git 仓库中
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "错误: 当前目录不是 git 仓库"
    exit 1
fi

# 获取提交信息
if [ $# -eq 0 ]; then
    COMMIT_MSG="Auto backup on $(date '+%Y-%m-%d %H:%M:%S')"
else
    COMMIT_MSG="$*"
fi

# 检查是否有变更
if git diff --quiet && git diff --cached --quiet; then
    echo "没有变更需要备份"
    exit 0
fi

# 执行备份
echo "正在备份..."

git add .
git commit -m "$COMMIT_MSG"

# 检查是否有远程仓库并推送
if git remote -v | grep -q .; then
    BRANCH=$(git branch --show-current)
    git push origin "$BRANCH"
    echo "备份完成并已推送到远程仓库"
else
    echo "备份完成（本地提交）"
fi