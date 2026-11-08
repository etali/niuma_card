# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Original BOTPanel's parameter-provider contract, backed by the live OffWorkState.
const Config = preload("res://engine/off_work_config.gd")
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

static func bind(state: RefCounted, config: Dictionary, selection: Dictionary = {}) -> void:
	_state = state
	_config = config.duplicate(true)
	# A saved table keeps its actual policy. The live control uses today's
	# curve, so a previous calibration is custom until explicitly reselected.
	# Do not rewrite the saved document or experiment's strength mapping.
	_config.strength_curves = Config.new().bot_preferences.strength_curves.duplicate(true)
	_defaults = state.config.rules.bot.duplicate(true)
	PRESETS = _config.presets
	_overrides.clear()
	_resolve_strength()
	if not selection.is_empty():
		_defaults = selection.defaults.duplicate(true)
		_strength = float(selection.strength)
		_overrides = selection.overrides.duplicate(true)
	_bus.changed.emit(_strength)

## A practice/replay table has its own policy. Keep the parked table's control
## metadata with that table, rather than leaving the panel bound to it.
static func selection_snapshot() -> Dictionary:
	return {"defaults":_defaults.duplicate(true), "strength":_strength, "overrides":_overrides.duplicate(true)}

static func _resolve_strength() -> void:
	_strength = float(_config.default_strength)
	var policy: Dictionary = _state.config.rules.bot
	if not policy.has("decision_budget_ms"):
		var choices := [_strength]
		for percent in range(101): choices.append(percent / 100.0)
		for value in choices:
			var parameters := strength_parameters(float(value), _defaults, _config)
			var matches := true
			for key in parameters:
				if not policy.has(key) or not is_equal_approx(float(policy[key]), float(parameters[key])):
					matches = false
					break
			if matches:
				_strength = float(value)
				return
	# Old slots preserve their actual policy even when it does not match a
	# current strength point. Mark it custom instead of presenting an exact match.
	var reference := strength_parameters(_strength, _defaults, _config)
	for key in reference:
		if policy.has(key) and not is_equal_approx(float(policy[key]), float(reference[key])):
			_overrides[key] = policy[key]
	if policy.has("decision_budget_ms"): _overrides.decision_budget_ms = policy.decision_budget_ms

static func bus() -> RefCounted: return _bus
static func pref_strength() -> float: return _strength
static func has_overrides() -> bool: return not _overrides.is_empty()
static func models() -> Array: return [{"id": "realtime", "label": str(_config.model_label)}]
static func help_text() -> String:
	if _defaults.has("decision_budget_ms"):
		return "载入的策略使用固定毫秒预算。\n选择整体强度后，行动间隔和思考预算一起更新。"
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
	if not _state.config.rules.bot.has(key) and key not in ["decision_budget_ms", "decision_budget_ratio"]: return
	if key == "decision_budget_ratio": _state.config.rules.bot.erase("decision_budget_ms")
	if key == "decision_budget_ms": _state.config.rules.bot.erase("decision_budget_ratio")
	_overrides[key] = value
	_state.config.rules.bot[key] = value
	_bus.changed.emit(_strength)
static func set_pref_strength(value: float) -> void:
	_strength = clampf(value, 0.0, 1.0)
	_overrides.erase("decision_budget_ms")
	for key in strength_parameters(_strength, _defaults, _config): _overrides.erase(key)
	_state.config.rules.bot.erase("decision_budget_ms")
	_state.config.rules.bot.merge(strength_parameters(_strength, _defaults, _config), true)
	_bus.changed.emit(_strength)

## The game panel and the headless lab resolve presets through this same curve.
static func strength_parameters(strength: float, _defaults_unused: Dictionary, settings: Dictionary) -> Dictionary:
	var value := clampf(strength, 0.0, 1.0)
	# Installed curves are the shared product contract. Older saved strategies
	# did not have them, so use the installed definition rather than silently
	# keeping their obsolete CPU-only strength slider.
	var curves: Dictionary = settings.get("strength_curves", {})
	if curves.is_empty():
		curves = Config.new().bot_preferences.strength_curves
	var result := {}
	for key in curves:
		result[key] = _curve_value(value, curves[key])
	# Linear time and ratio interpolation can make their product peak between
	# anchors. Interpolate real time allowance instead, then derive the ratio.
	var budgets := []
	for point in curves.decision_budget_ratio:
		budgets.append([point[0], float(point[1]) * _curve_value(float(point[0]), curves.think_seconds)])
	result.decision_budget_ratio = _curve_value(value, budgets) / float(result.think_seconds)
	return result

static func _curve_value(strength: float, points: Array) -> float:
	for index in range(1, points.size()):
		if strength <= float(points[index][0]):
			var lower: Array = points[index - 1]
			var upper: Array = points[index]
			return lerpf(float(lower[1]), float(upper[1]),
				(strength - float(lower[0])) / (float(upper[0]) - float(lower[0])))
	return float(points.back()[1])

static func restore_defaults() -> void:
	_state.config.rules.bot.erase("decision_budget_ratio")
	_state.config.rules.bot.erase("decision_budget_ms")
	_state.config.rules.bot.merge(_defaults, true)
	_overrides.clear()
	_resolve_strength()
	_bus.changed.emit(_strength)
