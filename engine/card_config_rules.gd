# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 游戏与无头评估共享校验器；跨语言工作台读取同一份字段、边界和约束规格。
const SCHEMA_PATH := "res://data/card_config_schema.json"
static var _schema: Dictionary = {}

static func schema() -> Dictionary:
	if _schema.is_empty():
		_schema = JSON.parse_string(FileAccess.get_file_as_string(SCHEMA_PATH))
	return _schema

static func editable_fields(id: String, base: Dictionary) -> Dictionary:
	var section := "_game" if id == "_game" else "cards"
	if id != "_game" and (id.begins_with("_") or base.get("kind") == "unit"):
		return {}
	var result := {}
	for field in schema()["editable"][section]:
		var spec: Dictionary = schema()["editable"][section][field]
		if not base.has(field) and not spec.get("optional", false):
			continue
		if spec.get("positive_default", false) and float(base.get(field, 0)) <= 0:
			continue
		result[field] = spec
	return result

static func number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func fixed_equal(path: String, value: Variant, baseline: Variant) -> bool:
	if path in schema()["fixed_text_paths"]:
		return value is String and baseline is String
	if baseline is Dictionary:
		if not value is Dictionary or value.size() != baseline.size():
			return false
		for key in baseline:
			if not value.has(key) or not fixed_equal(path + "." + str(key), value[key], baseline[key]):
				return false
		return true
	if baseline is Array:
		if not value is Array or value.size() != baseline.size():
			return false
		for i in baseline.size():
			if not fixed_equal(path + "." + str(i), value[i], baseline[i]):
				return false
		return true
	if number(baseline):
		return number(value) and value == baseline
	return typeof(value) == typeof(baseline) and value == baseline

static func validate(source: Variant, baseline: Dictionary) -> Array:
	if not source is Dictionary:
		return ["卡表必须是完整 JSON 对象"]
	var candidate: Dictionary = source.duplicate()
	for key in schema()["ignored_metadata"]:
		if candidate.has(key) and not candidate[key] is String:
			return ["配置名称必须是文本"]
		candidate.erase(key)
	if candidate.size() != baseline.size():
		return ["卡表必须包含与默认配置相同的卡牌和规则段"]
	var errors: Array = []
	for id in baseline:
		if not candidate.has(id):
			errors.append("缺字段：" + str(id))
			continue
		var base: Variant = baseline[id]
		var value: Variant = candidate[id]
		if not base is Dictionary:
			if not fixed_equal(str(id), value, base):
				errors.append("不能修改固定字段：" + str(id))
			continue
		if not value is Dictionary:
			errors.append("字段集合改变：" + str(id))
			continue
		var editable := editable_fields(str(id), base)
		var keys_valid := true
		for field in base:
			keys_valid = keys_valid and value.has(field)
		for field in value:
			keys_valid = keys_valid and (base.has(field) or (editable.has(field) and editable[field].get("optional", false)))
		if not keys_valid:
			errors.append("字段集合改变：" + str(id))
			continue
		for field in value:
			var path := "%s.%s" % [id, field]
			if editable.has(field):
				var lower := int(editable[field]["min"])
				var upper := int(editable[field].get("max", schema()["max_integer"]))
				var amount: Variant = value[field]
				if not number(amount) or float(amount) < lower or float(amount) > upper or float(amount) != floorf(float(amount)):
					errors.append("%s 必须是%s（最大 %d）" % [path, "非负整数" if lower == 0 else "正整数", upper])
			elif not fixed_equal(path, value[field], base[field]):
				errors.append("不能修改固定字段：" + path)
	if errors.is_empty():
		for rule in schema()["less_than"]:
			if _value_at(candidate, rule["left"]) >= _value_at(candidate, rule["right"]):
				errors.append(rule["message"])
	return errors

static func _value_at(source: Dictionary, path: Array) -> Variant:
	var value: Variant = source
	for key in path:
		value = value[key]
	return value
