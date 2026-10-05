#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# BOT 实现对打：每个种子换边各打一局，独立于卡表 Q1~Q9 评估。
# tools/bot_duel.sh [种子对数=20] [A=bot:1] [B=bot:0] [首种子=1001] [JSON报告路径]
# 示例：tools/bot_duel.sh 50 bot:1 bot:0 1001 tmp/bot-high-low.json
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
if [ ! -x "$GODOT" ]; then
	echo "找不到 Godot：${GODOT}（可用 GODOT=/path/to/godot 覆盖）" >&2
	exit 1
fi
"$GODOT" --headless -s tools/bot_duel.gd -- "${1:-20}" "${2:-bot:1}" "${3:-bot:0}" "${4:-1001}" "${5:-}"
