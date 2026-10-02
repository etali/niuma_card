# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Config = preload("res://engine/card_config.gd")
const Logic = preload("res://tools/balance/logic.gd")

func _initialize() -> void:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Config.DEFAULT_PATH))
	var cases: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/card_config_contract.json"))
	var results: Array = []
	var path := "user://config-contract-%d.json" % OS.get_process_id()
	for entry in cases:
		var candidate := base.duplicate(true)
		for change in entry["changes"]:
			var target: Variant = candidate
			var keys: Array = change["path"]
			for key in keys.slice(0, -1):
				target = target[key]
			if change.get("remove", false):
				target.erase(keys[-1])
			else:
				target[keys[-1]] = change["value"]
		_write(path, candidate)
		var game: bool = Config.validate_file(path).get("ok", false)
		var evaluation := Logic.validate(candidate, base).is_empty()
		check(game == entry["ok"] and evaluation == entry["ok"], str(entry["name"]) + " 游戏与评估遵守同一导入契约")
		results.append({"name": entry["name"], "ok": game})
	# 模拟当前进程已经选过一个合法文件；只改内存选择，不碰持久化偏好。
	_write(path, base)
	Config._loaded = true
	Config._selected_path = path
	check(Config.apply_solo().get("ok", false), "合法选择可以应用")
	var original_hash := StateCodec.table_hash()
	var invalid := base.duplicate(true)
	invalid["_game"]["win_cash"] = 999
	_write(path, invalid)
	check(not Config.apply_solo().get("ok", true), "选择后被外部修改的非法卡表仍被拒绝")
	check(StateCodec.table_hash() == original_hash, "拒绝重载不会污染正在使用的规则")
	Config._selected_path = ""
	Config.apply_default()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--contract-output="):
			_write(arg.trim_prefix("--contract-output="), results)
	finish()

func _write(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()
