# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name OnWorkCardConfig
extends RefCounted

## 单机自定义卡表选择器。
## 当前对局不热替换状态；选择成功后从下一局生效。联网入口要求先恢复内置卡表并重开。
const ConfigData = preload("res://engine/config_data.gd")
const DEFAULT_PATH := ConfigData.ON_WORK_CARDS
const Rules = preload("res://engine/on_work_card_config_rules.gd")
const JsonStore = preload("res://engine/json_store.gd")
const SavePaths = preload("res://engine/save_paths.gd")

static func pref_path() -> String:
	return SavePaths.settings_file("cards_config.json")

static var _selected_path := ""
static var _loaded := false

static func selected_path() -> String:
	if has_launch_override():
		return launch_path()
	_load_pref()
	return _selected_path

## 命令行覆盖只属于当前进程；不写入玩家的持久化选择。
static func has_launch_override() -> bool:
	return not LaunchConfig.desktop_args().has("--off-work-playtest") and LaunchConfig.current().has("cards_config")

static func launch_path() -> String:
	return _normalize(str(LaunchConfig.current().get("cards_config", "")))

static func has_custom() -> bool:
	return not selected_path().is_empty()

static func display_name() -> String:
	var path := selected_path()
	return "上班默认卡表" if path.is_empty() else path

static func validate_file(path: String) -> Dictionary:
	return _validate_custom(_normalize(path))

static func select(path: String) -> Dictionary:
	if has_launch_override():
		return {"ok": false, "reason": "本次启动由 --cards-config 指定卡表；请关闭游戏后重新选择配置启动"}
	var normalized := _normalize(path)
	if normalized.is_empty():
		return {"ok": false, "reason": "路径为空"}
	var check := _validate_custom(normalized)
	if not check["ok"]:
		return check
	if not _save_pref(normalized):
		return {"ok": false, "reason": "保存卡牌配置选择失败；原选择未改变，请检查存储空间和目录权限"}
	_selected_path = normalized
	_loaded = true
	return {"ok": true, "path": normalized}

static func clear_selection() -> Dictionary:
	if has_launch_override():
		return {"ok": false, "reason": "本次启动由 --cards-config 指定卡表，不能修改保存选择"}
	if not _save_pref(""):
		return {"ok": false, "reason": "恢复默认配置失败；原选择未改变，请检查存储空间和目录权限"}
	_selected_path = ""
	_loaded = true
	return {"ok": true}

static func apply_solo() -> Dictionary:
	if has_launch_override():
		var explicit_path := launch_path()
		var check := validate_file(explicit_path)
		if not check.get("ok", false):
			return {"ok": false, "path": explicit_path, "reason": "指定卡表加载失败：%s\n%s" % [explicit_path, check.get("reason", "卡表无效")]}
		if not OnWorkCardDB.load_from(explicit_path):
			return {"ok": false, "path": explicit_path, "reason": "指定卡表无法读取：%s" % explicit_path}
		return {"ok": true, "path": explicit_path, "custom": true, "launch_override": true}
	_load_pref()
	var path := _selected_path if not _selected_path.is_empty() else DEFAULT_PATH
	# 文件可在选择之后被编辑；每次真正应用都验证，失败不替换当前规则。
	if path != DEFAULT_PATH:
		var check := validate_file(path)
		if not check.get("ok", false):
			return {"ok": false, "path": path, "reason": "自定义卡表加载失败：%s" % check.get("reason", "卡表无效")}
	if not OnWorkCardDB.load_from(path):
		if path != DEFAULT_PATH:
			if _save_pref(""):
				_selected_path = ""
			OnWorkCardDB.load_from(DEFAULT_PATH)
			return {"ok": false, "used_default": true, "reason": "自定义卡表加载失败，已回退上班默认卡表"}
		return {"ok": false, "reason": "上班默认卡表 加载失败"}
	return {"ok": true, "path": path, "custom": path != DEFAULT_PATH}

static func apply_default() -> Dictionary:
	if not OnWorkCardDB.load_from(DEFAULT_PATH):
		return {"ok": false, "reason": "上班默认卡表 加载失败"}
	return {"ok": true, "path": DEFAULT_PATH, "custom": false}

static func _load_pref() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(pref_path()):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(pref_path()))
	if parsed is Dictionary:
		var path := str(parsed.get("path", ""))
		var resolved := _normalize(path)
		if not resolved.is_empty() and _validate_custom(resolved)["ok"]:
			_selected_path = resolved
			if resolved != path:
				_save_pref(resolved)

static func _save_pref(path: String) -> bool:
	return JsonStore.save(pref_path(), {"path": path})

static func _normalize(path: String) -> String:
	var value := path.strip_edges()
	if value.begins_with("~/"):
		value = OS.get_environment("HOME").path_join(value.substr(2))
	value = ConfigData.bundled_path(value)
	if value.begins_with("res://") or not value.is_absolute_path():
		return value
	return ProjectSettings.globalize_path(value)

static func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

static func _validate_custom(path: String) -> Dictionary:
	if path.is_empty():
		return {"ok": false, "reason": "--cards-config 需要指定配置文件路径"}
	var parsed: Variant = _read(path)
	if not (parsed is Dictionary):
		return {"ok": false, "reason": "不是有效的 JSON 对象"}
	var builtin: Variant = _read(DEFAULT_PATH)
	if not (builtin is Dictionary):
		return {"ok": false, "reason": "上班内置卡表 读取失败"}
	var errors := Rules.validate(parsed, builtin)
	return {"ok": true} if errors.is_empty() else {"ok": false, "reason": "\n".join(errors)}
