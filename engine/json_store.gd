# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 同目录写入并替换，失败保留旧文件。独占保存用目录声明协调多个游戏进程。
static func save(path: String, value: Variant, overwrite := true) -> bool:
	var target := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(target):
		return false
	var parent := target.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(parent) != OK:
		return false
	var claim := target + ".writing"
	if not overwrite:
		if DirAccess.make_dir_absolute(claim) != OK:
			return false
		if FileAccess.file_exists(target) or DirAccess.dir_exists_absolute(target):
			DirAccess.remove_absolute(claim)
			return false
	var temporary := target + "." + Crypto.new().generate_random_bytes(16).hex_encode() + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	var ok := false
	if file != null:
		file.store_string(JSON.stringify(value, "  ", false) + "\n")
		file.flush()
		ok = file.get_error() == OK
		file.close()
		if ok:
			ok = DirAccess.rename_absolute(temporary, target) == OK
	if FileAccess.file_exists(temporary):
		DirAccess.remove_absolute(temporary)
	if not overwrite:
		DirAccess.remove_absolute(claim)
	return ok
