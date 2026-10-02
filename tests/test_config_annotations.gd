# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Config = preload("res://engine/card_config.gd")
const Logic = preload("res://tools/balance/logic.gd")

func _initialize() -> void:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Config.DEFAULT_PATH))
	var legacy := base.duplicate(true)
	legacy["_comment"] = "旧卡表说明：同名传说材料"
	legacy["_upgrade"]["_note"] = "旧升级路线说明"
	legacy["_game"]["_note"] = "旧全局规则说明"
	legacy["yunketang"]["output_n"] += 1
	var before := legacy.duplicate(true)
	var path := "user://test-config-annotations-%d.json" % OS.get_process_id()
	_check_config(path, legacy, base, true, "说明不同的旧配置仍可用于游戏和评估")
	check(legacy == before, "校验不会重写旧配置的说明或参数")
	for key in ["_comment", "_upgrade", "_game"]:
		var invalid := legacy.duplicate(true)
		if key == "_comment":
			invalid[key] = 7
		else:
			invalid[key]["_note"] = {"not": "text"}
		_check_config(path, invalid, base, false, "拒绝非文本说明：%s" % key)
	for field in ["_note", "dup_key", "routes"]:
		var invalid := legacy.duplicate(true)
		invalid["_upgrade"].erase(field)
		_check_config(path, invalid, base, false, "升级规则段仍要求完整字段：%s" % field)
	var route := legacy.duplicate(true)
	route["_upgrade"]["routes"][0]["per"] = 99
	_check_config(path, route, base, false, "不能借修改说明改变材料折算率")
	var extra := legacy.duplicate(true)
	extra["_upgrade"]["extra_rule"] = true
	_check_config(path, extra, base, false, "不能借修改说明添加未知升级规则")
	var threshold := legacy.duplicate(true)
	threshold["dujiaoshou"]["upgrade_dup_n"] += 1
	_check_config(path, threshold, base, false, "卡表导入仍禁止修改升级门槛")
	var victory := legacy.duplicate(true)
	victory["_game"]["win_cash"] += 1
	_check_config(path, victory, base, false, "固定胜负规则仍受保护")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	finish()

func _check_config(path: String, cards: Dictionary, baseline: Dictionary, expected: bool, label: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(cards))
	file.close()
	check(bool(Config.validate_file(path).get("ok", false)) == expected, label + "（游戏）")
	check(Logic.validate(cards, baseline).is_empty() == expected, label + "（模拟）")
