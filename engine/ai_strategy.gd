# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIStrategy
extends RefCounted

## 可注册的 AI 实现接口。环境规则不属于此接口；只选择动作、评价和暴露超参数。
## 参数 schema 是面板、校验、强度映射与报告的唯一规格来源。
func identifier() -> String:
	return ""

func display_name() -> String:
	return identifier()

func profile_version() -> String:
	return "1"

## [{key,label,group,kind,min,max,step,hint,default,strength_range?,options?}]
## kind: int / float / bool / enum；enum.options: [{value,label}]。
func parameter_schema() -> Array:
	return []

func compile_parameters(strength: float, source: Dictionary) -> Dictionary:
	var s := clampf(strength, 0.0, 1.0) if is_finite(strength) else 0.0
	var out := {"profile_version": profile_version()}
	for spec in parameter_schema():
		var value: Variant = spec["default"]
		var configured: Variant = source.get(spec["key"], spec.get("strength_range", value))
		if configured is Array and configured.size() == 2 and str(spec["kind"]) in ["int", "float"]:
			if _number(configured[0]) and _number(configured[1]):
				value = lerpf(float(configured[0]), float(configured[1]), s)
		else:
			value = configured
		var checked: Variant = validate_value(spec, value)
		out[spec["key"]] = checked if checked != null else spec["default"]
	return out

func choose_plan(_state: GameState, _who: String, _config) -> Dictionary:
	push_error("AI 实现没有提供 choose_plan")
	return {"intents": []}

func target_picker(_config) -> Callable:
	push_error("AI 实现没有提供 target_picker")
	return Callable()

func evaluate(_state: GameState, _who: String, _parameters: Dictionary) -> float:
	push_error("AI 实现没有提供 evaluate")
	return 0.0

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

## 未知类型或非法值返回 null；数值越界夹取到规格边界，步长也由规格决定。
static func validate_value(spec: Dictionary, value: Variant) -> Variant:
	match str(spec.get("kind", "")):
		"bool":
			return value if value is bool else null
		"enum":
			for option in spec.get("options", []):
				if typeof(option["value"]) == typeof(value) and option["value"] == value:
					return option["value"]
				# JSON 将整数恢复为浮点，数值枚举按值匹配并还原声明的类型。
				if _number(option["value"]) and _number(value) and float(option["value"]) == float(value):
					return option["value"]
			return null
		"int", "float":
			if not _number(value):
				return null
			var lower := float(spec["min"])
			var upper := float(spec["max"])
			var n := clampf(float(value), lower, upper)
			var step := float(spec.get("step", 1.0 if spec["kind"] == "int" else 0.01))
			if step > 0:
				n = clampf(lower + roundf((n - lower) / step) * step, lower, upper)
			return roundi(n) if spec["kind"] == "int" else n
	return null
