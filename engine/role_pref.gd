# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name RolePref
extends RefCounted

## 玩家在单机局里坐哪个角色（README.md §「2.12 角色」）。只存 id，角色内容每次开局现查卡表。
## 选了之后从下一局生效，和卡牌配置同一个节奏：当前这一局的规则不热替换。
## BOT 与联网不读这份偏好 —— 对手和联网双方固定是默认角色
const JsonStore = preload("res://engine/json_store.gd")
const SavePaths = preload("res://engine/save_paths.gd")

static func pref_path() -> String:
	return SavePaths.settings_file("role.json")

static var _selected := ""
static var _loaded := false

## 存下的角色。存的 id 在当前卡表里认不出（换过卡表）时按默认角色算，不改文件
static func selected() -> String:
	_load()
	return _selected if Roles.exists(_selected) else Roles.DEFAULT

static func select(role_id: String) -> Dictionary:
	if not Roles.exists(role_id):
		return {"ok": false, "reason": "没有这个角色：%s" % role_id}
	if not JsonStore.save(pref_path(), {"role": role_id}):
		return {"ok": false, "reason": "保存角色选择失败；原选择未改变，请检查存储空间和目录权限"}
	_selected = role_id
	_loaded = true
	return {"ok": true, "role": role_id}

## 测试换用户目录后重新读盘
static func reload() -> void:
	_loaded = false
	_selected = ""

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(pref_path()):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(pref_path()))
	if parsed is Dictionary:
		_selected = str(parsed.get("role", ""))
