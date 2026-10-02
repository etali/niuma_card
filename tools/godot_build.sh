#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 导入和导出共用的错误判定。Godot 部分错误返回 0，必须同时检查完整日志。
godot_checked() {
	local log status=0 filter_status=0
	log=$(mktemp "${TMPDIR:-/tmp}/card-combine-godot.XXXXXX") || return 1
	"$GODOT" "$@" > "$log" 2>&1 || status=$?
	if [ "$status" -eq 0 ] && grep -Eq '(^|[[:space:]])(SCRIPT ERROR|ERROR):' "$log"; then
		echo "Godot 报错，停止构建。" >&2
		status=1
	fi
	python3 "$(dirname "${BASH_SOURCE[0]}")/project_paths.py" < "$log" || filter_status=$?
	if [ "$status" -eq 0 ]; then
		status=$filter_status
	fi
	rm -f "$log"
	return "$status"
}

build_stage() {
	mkdir -p build || return 1
	_BUILD_STAGE=$(mktemp -d "$PWD/build/.export-stage.XXXXXX")
}

build_stage_cleanup() {
	if [ -n "${_BUILD_STAGE:-}" ]; then
		rm -rf "$_BUILD_STAGE"
		_BUILD_STAGE=""
	fi
}
