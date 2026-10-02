#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

# 构建期间的字体事务。由项目根目录 source，调用方须提供 FONT/GODOT 并启用 set -e。
# 完整 TTF、导入配置与缓存一起恢复，避免 .import 尚在但 fontdata 已被删掉。
source "$(dirname "${BASH_SOURCE[0]}")/godot_build.sh"

# flock 跟随共享的打开文件描述符，Python 退出后仍由当前 shell 的 fd 9 持有。
# macOS 自带 bash 没有 flock 命令；使用 Python 标准库，避免 mkdir 锁的崩溃残留。
# 锁文件不能删除：等待者可能已打开它，删除会让后来的构建锁住另一份 inode。
font_transaction_begin() {
	[ "${_FONT_TRANSACTION_ACTIVE:-0}" = "1" ] && return 0
	_FONT_SUBSET_BACKUP=""
	_FONT_SUBSET_READY=0
	_FONT_SUBSET_ROOT="$PWD"
	_FONT_LOCK_WAIT_PID=""
	trap '_font_subset_on_exit $?' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	mkdir -p build || return 1
	exec 9>build/.font-transaction.lock || return 1
	python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)' &
	_FONT_LOCK_WAIT_PID=$!
	wait "$_FONT_LOCK_WAIT_PID" || return $?
	_FONT_LOCK_WAIT_PID=""
	_FONT_TRANSACTION_ACTIVE=1
}

font_import_resources() {
	font_transaction_begin || return $?
	# 标准构建/发布打包共用的前置条件。字体第一次导入也不能扫描build里的引擎源码。
	mkdir -p build || return 1
	touch build/.gdignore || return 1
	godot_checked --headless --import || return $?
	python3 - "$FONT.import" <<-'PY_CHECK'
		import pathlib, re, sys
		config = pathlib.Path(sys.argv[1])
		text = config.read_text() if config.is_file() else ""
		match = re.search(r'^path="res://([^"\n]+\.fontdata)"$', text, re.M)
		cache = pathlib.Path(match.group(1)) if match else None
		if cache is None or not cache.is_file() or not cache.stat().st_size:
		    sys.exit(f"字体导入失败：{config} 没有指向有效的 fontdata 缓存")
	PY_CHECK
}

_font_subset_on_exit() {
	local status=$1
	trap - EXIT INT TERM HUP
	if [ -n "${_FONT_LOCK_WAIT_PID:-}" ]; then
		kill "$_FONT_LOCK_WAIT_PID" 2>/dev/null || true
		wait "$_FONT_LOCK_WAIT_PID" 2>/dev/null || true
	fi
	if ! restore_font; then
		echo "字体恢复失败，备份保留在：$_FONT_SUBSET_BACKUP" >&2
		[ "$status" -ne 0 ] || status=1
	fi
	build_stage_cleanup
	# restore_font() 本身不释放锁：导出后的验证、发布与异常收尾也属于同一事务。
	exec 9>&-
	exit "$status"
}

subset_font() {
	font_transaction_begin || return $?
	if ! command -v pyftsubset > /dev/null 2>&1; then
		echo "     跳过（没装 fonttools：pip3 install fonttools）"
		return 0
	fi
	# 先导入完整字体，修复旧构建留下的缺失缓存，再保存一致的完整状态。
	font_import_resources
	_FONT_SUBSET_BACKUP=$(mktemp -d "${TMPDIR:-/tmp}/card-combine-font.XXXXXX")
	mkdir "$_FONT_SUBSET_BACKUP/imported"
	cp -p "$FONT" "$_FONT_SUBSET_BACKUP/font"
	cp -p "$FONT.import" "$_FONT_SUBSET_BACKUP/font.import"
	local cache chars
	for cache in .godot/imported/"${FONT##*/}"-*; do
		[ -f "$cache" ] || continue
		cp -p "$cache" "$_FONT_SUBSET_BACKUP/imported/"
	done
	_FONT_SUBSET_READY=1
	# heredoc 只剥离 tab；Python 自身的缩进必须保留为空格。
	chars=$(python3 - <<-'PY'
		import os
		pts = set(range(0x20, 0x7F)) | set(range(0xA0, 0x100))
		# 只收集运行时文字，开发测试与构建源码不应撑大随包字体。
		# 主动剪枝，避免精简引擎的源码/对象缓存被遍历数遍。
		for directory, dirs, files in os.walk("."):
		    dirs[:] = [d for d in dirs if d not in
		               (".godot", ".git", "build", "test_image", "ref_image", "tests", "tools", "reports", "__pycache__")]
		    for name in files:
		        if name.rsplit(".", 1)[-1] not in ("gd", "json", "tscn", "tres"):
		            continue
		        with open(os.path.join(directory, name), encoding="utf-8", errors="ignore") as f:
		            pts |= {ord(c) for c in f.read()}
		print(",".join(f"U+{p:04X}" for p in sorted(pts) if p >= 0x20 and p != 0x7F))
	PY
	)
	# 先输出到临时文件，失败不会写坏源字体；保留 variable font 的 wght 轴。
	pyftsubset "$_FONT_SUBSET_BACKUP/font" --unicodes="$chars" --notdef-outline \
		--output-file="$_FONT_SUBSET_BACKUP/subset.ttf"
	mv -f "$_FONT_SUBSET_BACKUP/subset.ttf" "$FONT"
	rm -f .godot/imported/"${FONT##*/}"-*
	echo "     $(du -h "$_FONT_SUBSET_BACKUP/font" | cut -f1) → $(du -h "$FONT" | cut -f1)"
}

restore_font() {
	[ -n "${_FONT_SUBSET_BACKUP:-}" ] || return 0
	if [ "$_FONT_SUBSET_READY" -eq 1 ]; then
		# 使用保存的根目录，即使调用方已 cd 到打包目录也能安全恢复。
		(
			cd "$_FONT_SUBSET_ROOT" || exit 1
			cp -p "$_FONT_SUBSET_BACKUP/font" "$FONT" || exit 1
			cp -p "$_FONT_SUBSET_BACKUP/font.import" "$FONT.import" || exit 1
			rm -f .godot/imported/"${FONT##*/}"-* || exit 1
			cp -p "$_FONT_SUBSET_BACKUP/imported/"* .godot/imported/ || exit 1
		) || return 1
		_FONT_SUBSET_READY=0
	fi
	rm -rf "$_FONT_SUBSET_BACKUP" || return 1
	_FONT_SUBSET_BACKUP=""
}
