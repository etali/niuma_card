# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name BOTStrategyRegistry
extends RefCounted

const Strategy = preload("res://engine/bot_strategy.gd")
const BuiltinBOT = preload("res://engine/bot_turn_strategy.gd")
static var _providers: Dictionary = {}
static var _ready := false

static func _ensure() -> void:
	if _ready:
		return
	_ready = true
	register(BuiltinBOT.new())

## 新 BOT 实现注册一次即可接入模型选择、参数面板、运行时设置和统一执行入口。
static func register(strategy: Strategy) -> bool:
	_ensure()
	var id := strategy.identifier()
	if id == "" or _providers.has(id):
		return false
	var keys := {}
	for spec in strategy.parameter_schema():
		if not spec is Dictionary or not spec.has_all(["key", "label", "kind", "default"]):
			return false
		var key := str(spec["key"])
		if key == "" or key.begins_with("_") or key == "profile_version" or keys.has(key):
			return false
		if spec["kind"] in ["int", "float"]:
			if not spec.has_all(["min", "max", "step"]) or float(spec["min"]) > float(spec["max"]) or float(spec["step"]) <= 0:
				return false
		if Strategy.validate_value(spec, spec["default"]) == null:
			return false
		keys[key] = true
	_providers[id] = strategy
	return true

static func get_strategy(id: String) -> Strategy:
	_ensure()
	return _providers.get(id)

static func models() -> Array:
	_ensure()
	var result: Array = []
	for id in _providers:
		result.append({"id":id, "label":_providers[id].display_name()})
	return result

## 供独立测试或可卸载实现使用；内置 BOT 不能被卸载。
static func unregister(id: String) -> bool:
	_ensure()
	if id == "bot":
		return false
	return _providers.erase(id)
