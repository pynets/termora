#!/usr/bin/env bash
# Termora — 根目录一键发布快捷入口
# 执行方式: ./release.sh [版本号] [构建号]
# 示例: ./release.sh 0.0.3

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${DIR}/scripts/release.sh" "$@"
