# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Original BOTPanel's parameter-provider contract, backed by the live WorkState.
const Config = preload("res://engine/work_config.gd")
class Bus extends RefCounted:
	signal changed(strength: float)
class Snapshot extends RefCounted:
	var model := "realtime"
	var values: Dictionary
	func get_knob(key: String) -> Variant: return values.get(key)

static var _bus := Bus.new()
static var _state: RefCounted
static var _defaults: Dictionary = {}
static var _config: Dictionary = {}
static var _strength := 0.5
static var _overrides: Dictionary = {}
static var PRESETS: Dictionary = {}

static func bind(state: RefCounted, config: Dictionary) -> void:
	_state = state
	_config = config
	_defaults = state.config.rules.bot.duplicate(true)
	_strength = float(config.default_strength)
	PRESETS = config.presets
	_overrides.clear()

static func bus() -> RefCounted: return _bus
static func pref_strength() -> float: return _strength
static func has_overrides() -> bool: return not _overrides.is_empty()
static func models() -> Array: return [{"id": "realtime", "label": str(_config.model_label)}]
static func help_text() -> String:
	if _defaults.has("decision_budget_ms"):
		return "载入的策略使用固定毫秒预算。\n选择强度后，预算会随行动间隔更新。"
	return str(_config.help)
static func editable_knobs(_model: String) -> Array:
	var knobs: Array = _config.knobs.duplicate()
	# Only legacy sessions retain this editable fixed allowance. The shared
	# panel hides the inactive mode when the player moves the strength slider.
	if _defaults.has("decision_budget_ms"):
		knobs.append({"key":"decision_budget_ms", "label":"旧策略固定时限（毫秒）", "group":"决策时限", "kind":"int",
			"min":1, "max":32, "step":1})
	knobs.append({"key":"budget_readout", "label":"当前单次决策时限", "group":"决策时限", "read_only":true})
	return knobs
static func prefs() -> Snapshot:
	var result := Snapshot.new()
	result.values = _state.config.rules.bot.duplicate(true)
	result.values.budget_readout = "%d 毫秒" % Config.decision_budget_ms(result.values)
	return result
static func set_pref_model(_model: String) -> void: pass
static func set_override(key: String, value: Variant) -> void:
	if key == "decision_budget_ratio": _state.config.rules.bot.erase("decision_budget_ms")
	if key == "decision_budget_ms": _state.config.rules.bot.erase("decision_budget_ratio")
	_overrides[key] = value
	_state.config.rules.bot[key] = value
	_bus.changed.emit(_strength)
static func set_pref_strength(value: float) -> void:
	_strength = clampf(value, 0.0, 1.0)
	_overrides.erase("decision_budget_ms")
	_overrides.erase("decision_budget_ratio")
	_state.config.rules.bot.erase("decision_budget_ms")
	_state.config.rules.bot.merge(strength_parameters(_strength, _defaults, _config), true)
	_bus.changed.emit(_strength)

## The game panel and the headless lab resolve presets through this same curve.
static func strength_parameters(strength: float, defaults: Dictionary, settings: Dictionary) -> Dictionary:
	var mid := float(settings.default_strength)
	var base := float(defaults.get("decision_budget_ratio", Config.DEFAULT_DECISION_BUDGET_RATIO))
	if strength == mid: return {"decision_budget_ratio": base}
	var ratio: float
	if strength < mid:
		ratio = lerpf(Config.MIN_DECISION_BUDGET_RATIO, base, strength / mid)
	else:
		ratio = lerpf(base, Config.MAX_DECISION_BUDGET_RATIO, (strength - mid) / (1.0 - mid))
	return {"decision_budget_ratio": roundi(ratio * 100) / 100.0}

static func restore_defaults() -> void:
	_state.config.rules.bot.erase("decision_budget_ratio")
	_state.config.rules.bot.erase("decision_budget_ms")
	_state.config.rules.bot.merge(_defaults, true)
	_overrides.clear()
	_strength = float(_config.default_strength)
	_bus.changed.emit(_strength)
