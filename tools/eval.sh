#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 兼容命令行入口：手动评估只接受一份请求 JSON，不再接受旧批量参数。
set -o pipefail
cd "$(dirname "$0")/.." || exit 2
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
if [ ! -x "$GODOT" ]; then
    echo "找不到 Godot：${GODOT}"
    exit 2
fi
if [ "$#" -ne 1 ]; then
    echo "用法：tools/eval.sh 手动评估请求.json"
    echo "推荐直接双击项目根目录「启动手动调参.command」。"
    exit 2
fi
"$GODOT" --headless --path "$PWD" -s tools/eval_report.gd -- "$1"
