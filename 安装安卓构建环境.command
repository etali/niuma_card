#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 安装过程实时留日志；双击失败时保留窗口，命令行保留真实退出码。
set -e
cd "$(dirname "$0")"
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
	exec python3 tools/install_android_dependencies.py "$@"
fi
mkdir -p build/logs
touch build/.gdignore
INSTALL_LOG="build/logs/android-install-$(date +%Y%m%d-%H%M%S)-$$.log"
echo "安装日志：$INSTALL_LOG"
set +e
PYTHONUNBUFFERED=1 python3 tools/install_android_dependencies.py "$@" 2>&1 | python3 -u tools/project_paths.py | tee "$INSTALL_LOG"
INSTALL_CODES=("${PIPESTATUS[@]}")
INSTALL_STATUS=${INSTALL_CODES[0]}
for INSTALL_CODE in "${INSTALL_CODES[1]}" "${INSTALL_CODES[2]}"; do
	if [ "$INSTALL_STATUS" -eq 0 ] && [ "$INSTALL_CODE" -ne 0 ]; then
		INSTALL_STATUS=$INSTALL_CODE
	fi
done
if [ "$INSTALL_STATUS" -ne 0 ]; then
	echo ""
	echo "Android 环境安装未完成（退出码：${INSTALL_STATUS}）。完整日志：$INSTALL_LOG" >&2
	if [ -t 0 ] && [ -t 1 ] && [ "${CARD_INSTALL_NO_PAUSE:-0}" != "1" ] && [ -z "${CI:-}" ]; then
		printf '\n请先查看以上错误。按回车键退出…' >&2
		read -r _install_reply
	fi
fi
exit "$INSTALL_STATUS"
