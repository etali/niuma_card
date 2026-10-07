#!/bin/bash
# 独立预览窗口，默认使用构建好的应用，不进入牌局。
# 窗口左侧可切换原始 / 1024 / 768 / 512 / 384 / 256 分辨率，仅影响预览。
set -eu
cd "$(dirname "$0")"
preview_binary="$PWD/build/牛马牌.app/Contents/MacOS/牛马牌"
if [ -n "${GODOT:-}" ]; then
    exec "$GODOT" --path "$PWD" "$@" -- --animation-preview
elif [ -x "$preview_binary" ]; then
    exec "$preview_binary" "$@" -- --animation-preview
elif [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
    exec /Applications/Godot.app/Contents/MacOS/Godot --path "$PWD" "$@" -- --animation-preview
else
    echo "找不到已构建的应用或 Godot。请先运行 构建游戏.command。" >&2
    exit 1
fi
