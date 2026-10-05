# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name BOTStrategy
extends RefCounted

## 可注册的 BOT 实现接口。环境规则不属于此接口；只选择动作、评价和暴露超参数。
## 参数 schema 是面板、校验、强度映射与报告的唯一规格来源。
func identifier() -> String:
	return ""

func display_name() -> String:
	return identifier()

func profile_version() -> String:
	return "1"

## [{key,label,group,kind,min,max,step,hint,default,strength_points?,strength_interpolation?,strength_range?,options?}]
## kind: int / float / bool / enum；enum.options: [{value,label}]。
func parameter_schema() -> Array:
	return []

func compile_parameters(strength: float, source: Dictionary) -> Dictionary:
	var s := clampf(strength, 0.0, 1.0) if is_finite(strength) else 0.0
	var out := {"profile_version": profile_version()}
	var schema := parameter_schema()
	for spec in schema:
		var zero_equivalent := 0.0
		# 0为共享额度哨兵时，插值的正值段从默认强度的有效总额度开始。
		# 不插值成刚刚大于0的局部额度，否则滑块稍微变强反而会丢失绝大部分候选。
		if spec.has("effective_zero_limit"):
			for reference in schema:
				if reference["key"] == spec["effective_zero_limit"]:
					var effective: Variant = validate_value(reference,_configured_value(reference,source,0.5))
					if effective == null: effective = reference["default"]
					if _number(effective): zero_equivalent = float(effective)
		var value: Variant = _configured_value(spec,{} if spec.get("read_only",false) else source,s,zero_equivalent)
		var checked: Variant = validate_value(spec, value)
		out[spec["key"]] = checked if checked != null else spec["default"]
	return out

static func _configured_value(spec: Dictionary, source: Dictionary, strength: float, zero_equivalent := 0.0) -> Variant:
	var fallback: Variant = spec["default"]
	var configured: Variant = source.get(spec["key"], spec.get("strength_points", spec.get("strength_range", fallback)))
	if configured is Array and not configured.is_empty() and configured[0] is Array:
		return interpolate_points(configured,strength,str(spec.get("strength_interpolation","linear")),fallback,zero_equivalent)
	if configured is Array and configured.size() == 2 and str(spec["kind"]) in ["int", "float"]:
		if _number(configured[0]) and _number(configured[1]):
			return lerpf(float(configured[0]), float(configured[1]), strength)
		return fallback
	return configured

## 锚点区间线性插值，随后统一按schema量化整数/步长。step仅为其他注册模型保留。
static func interpolate_points(points: Array, strength: float, mode: String, fallback: Variant, zero_equivalent := 0.0) -> Variant:
	if points.is_empty(): return fallback
	var previous := -1.0
	for point in points:
		if not point is Array or point.size() != 2 or not _number(point[0]): return fallback
		var position := float(point[0])
		if position < 0.0 or position > 1.0 or position <= previous: return fallback
		previous = position
	if float(points[0][0]) != 0.0 or float(points.back()[0]) != 1.0: return fallback
	for index in range(1,points.size()):
		var left: Array = points[index-1]
		var right: Array = points[index]
		if strength < float(right[0]):
			if mode == "step": return left[1]
			if mode != "linear" or not _number(left[1]) or not _number(right[1]): return fallback
			var fraction := (strength-float(left[0]))/(float(right[0])-float(left[0]))
			var left_value := float(left[1])
			if strength > float(left[0]) and left_value == 0.0 and float(right[1]) > 0.0:
				left_value = zero_equivalent
			return lerpf(left_value,float(right[1]),fraction)
	return points.back()[1]

func choose_plan(_state: GameState, _who: String, _config) -> Dictionary:
	push_error("BOT 实现没有提供 choose_plan")
	return {"intents": []}

func target_picker(_config) -> Callable:
	push_error("BOT 实现没有提供 target_picker")
	return Callable()

## 只有确定不会展开搜索的选靶才能在主线程执行；新模型默认仍走工作线程。
func can_pick_target_inline(_targets: Array) -> bool:
	return false

func evaluate(_state: GameState, _who: String, _parameters: Dictionary) -> float:
	push_error("BOT 实现没有提供 evaluate")
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
