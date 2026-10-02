#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 只消费已经编译好的 App；不运行 Godot，不进入字体或签名事务。
set -u
DMG_ROOT="$(cd "$(dirname "$0")" && pwd)" || exit 1
for DMG_ARG in "$@"; do
	case "$DMG_ARG" in
		-h|--help) exec python3 "$DMG_ROOT/tools/package_dmg.py" "$@" ;;
	esac
done

if ! mkdir -p "$DMG_ROOT/build/logs" || ! touch "$DMG_ROOT/build/.gdignore"; then
	echo "DMG 打包失败：无法创建日志目录 build/logs" >&2
	exit 1
fi
DMG_LOG_LABEL="build/logs/dmg-$(date +%Y%m%d-%H%M%S)-$$.log"
DMG_LOG="$DMG_ROOT/$DMG_LOG_LABEL"
echo "打包日志：$DMG_LOG_LABEL"
python3 -u "$DMG_ROOT/tools/package_dmg.py" "$@" 2>&1 | python3 -u "$DMG_ROOT/tools/project_paths.py" | tee "$DMG_LOG"
DMG_CODES=("${PIPESTATUS[@]}")
DMG_STATUS=${DMG_CODES[0]}
for DMG_CODE in "${DMG_CODES[1]}" "${DMG_CODES[2]}"; do
	if [ "$DMG_STATUS" -eq 0 ] && [ "$DMG_CODE" -ne 0 ]; then
		DMG_STATUS=$DMG_CODE
	fi
done
if [ "$DMG_STATUS" -ne 0 ]; then
	{
		echo ""
		echo "========== DMG 打包失败（退出码：${DMG_STATUS}） =========="
		tail -n 12 "$DMG_LOG" || true
		echo "完整日志：$DMG_LOG_LABEL"
	} >&2
	if [ -t 0 ] && [ -t 1 ] && [ "${CARD_BUILD_NO_PAUSE:-0}" != "1" ] && [ -z "${CI:-}" ]; then
		printf '\n请先查看以上错误。按回车键退出…' >&2
		read -r _dmg_reply || true
	fi
fi
exit "$DMG_STATUS"
