# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name TutorialCatalog
extends RefCounted

## 教程、学习中心与图鉴的措辞集中于配置；卡名和数值从当前卡表展开。
const ConfigData = preload("res://engine/config_data.gd")
const PATH := "res://data/tutorial.json"
static var _data: Dictionary = {}
static var _quantity_join: RegEx

static func reload() -> void:
	_data = ConfigData.read_dictionary(PATH, true, "tutorial")

static func data() -> Dictionary:
	if _data.is_empty(): reload()
	return _data

static func ui(key: String, vars: Dictionary = {}) -> String:
	return format_text(str(data().get("ui", {}).get(key, key)), vars)

static func format_text(value: String, vars: Dictionary = {}) -> String:
	var out := value.replace("{win_cash}", text_value(CardDB.game_rules().get("win_cash", 100)))
	for key in vars:
		out = out.replace("{%s}" % str(key), text_value(vars[key]))
	if "{card." in out:
		for id in CardDB.all_cards():
			var definition := CardDB.get_def(str(id))
			for key in definition:
				out = out.replace("{card.%s.%s}" % [id, key], text_value(definition[key]))
	# 中文智能换行仍可拆开“6 张”甚至“6张”；展开后用零宽连接符绑定数量与量词。
	# 配置保持普通可读文字，重复展开已经绑定的文字也不会追加连接符。
	if _quantity_join == null:
		_quantity_join = RegEx.new()
		_quantity_join.compile("([0-9]+) *张")
	return _quantity_join.sub(out, "$1\u2060张", true)

static func _expand(value: Variant) -> Variant:
	if value is String: return format_text(value)
	if value is Array:
		var array: Array = []
		for item in value: array.append(_expand(item))
		return array
	if value is Dictionary:
		var dictionary := {}
		for key in value: dictionary[key] = _expand(value[key])
		return dictionary
	return value

static func courses() -> Array:
	return _expand(data().get("courses", []))

static func course(id: String) -> Dictionary:
	for entry in data().get("courses", []):
		if str(entry.get("id", "")) == id: return _expand(entry)
	return {}

static func next_course_id(id: String) -> String:
	var entries: Array = data().get("courses", [])
	for index in entries.size():
		if str(entries[index].get("id", "")) == id:
			return str(entries[index + 1].get("id", "")) if index + 1 < entries.size() else ""
	return ""

static func topics() -> Array:
	return _expand(data().get("topics", []))

static func scenario(id: String) -> Dictionary:
	return _expand(data().get("scenarios", {}).get(id, {}))

static func text_value(value: Variant) -> String:
	if value is float and is_finite(value) and value == floorf(value): return str(int(value))
	return str(value)
