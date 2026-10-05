# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AISearch
extends RefCounted

## 通用 AI profile + 本次运行的设置。算法只拿已解析快照，面板和算法读同一参数规格。
const Registry = preload("res://engine/ai_strategy_registry.gd")
const Strategy = preload("res://engine/ai_strategy.gd")
## 仅用于清理旧版本的持久化文件；不再读取或写入玩家 AI 参数。
const USER_PATH := "user://ai_search.json"

var model := "ai"
var strength := 0.0
var parameters: Dictionary = {}
## 仅本次运行使用，不保存到配置或录像。
var cancelled_check: Callable = Callable()
## 运行时共享账本，不进入参数快照或录像。
var work_session: RefCounted

static func search_defaults() -> Dictionary:
	return AIConfig.read_section("search")

static func default_model() -> String:
	var requested := str(search_defaults().get("default_model", "ai"))
	return requested if Registry.get_strategy(requested) != null else "ai"

static func default_config() -> AISearch:
	return from_model(default_model(), 0.0)

static func from_strength(s: float) -> AISearch:
	return from_model(default_model(), s)

static func from_model(name: String, s: float) -> AISearch:
	var id := name.strip_edges().to_lower()
	var provider := Registry.get_strategy(id)
	if provider == null:
		push_warning("未知或已移除的 AI 实现：%s" % name)
		return null
	var cfg := AISearch.new()
	cfg.model = id
	cfg.strength = clampf(s, 0.0, 1.0) if is_finite(s) else 0.0
	cfg.parameters = provider.compile_parameters(cfg.strength, search_defaults().get(id, {}))
	return cfg

static func models() -> Array:
	return Registry.models()

static var PRESETS: Dictionary:
	get:
		return search_defaults()["presets"].duplicate(true)

static func parse_strength(txt: String) -> float:
	var t := txt.strip_edges().to_lower()
	if PRESETS.has(t):
		return float(PRESETS[t])
	return clampf(float(t), 0.0, 1.0) if t.is_valid_float() and is_finite(float(t)) else 0.0

static func from_tier(txt: String) -> AISearch:
	var parts := txt.strip_edges().to_lower().split(":", false)
	if parts.size() == 2:
		return from_model(str(parts[0]), parse_strength(str(parts[1])))
	var t := txt.strip_edges().to_lower()
	if not PRESETS.has(t) and not t.is_valid_float():
		push_warning("未知AI档位：%s" % txt)
		return null
	return from_strength(parse_strength(txt))

static func editable_knobs(id := "") -> Array:
	var provider := Registry.get_strategy(pref_model() if id == "" else id)
	return provider.parameter_schema().duplicate(true) if provider != null else []

func implementation() -> Strategy:
	return Registry.get_strategy(model)

func resolved_parameters() -> Dictionary:
	# bare AISearch.new()也解析当前最低档，避免存在未初始化的隐形策略。
	if parameters.is_empty():
		parameters = implementation().compile_parameters(strength, search_defaults().get(model, {}))
	return parameters.duplicate(true)

func get_knob(key: String) -> Variant:
	return resolved_parameters().get(key)

func apply_override(key: String, value: Variant) -> bool:
	for spec in editable_knobs(model):
		if spec["key"] != key:
			continue
		var checked: Variant = Strategy.validate_value(spec, value)
		if checked == null:
			return false
		resolved_parameters()
		# 全参数快照可以携带相同派生值，不能借覆盖项改写强度推导结果。
		if spec.get("read_only",false): return checked == parameters[key]
		parameters[key] = checked
		return true
	return false

func describe() -> String:
	var values: Array[String] = []
	var p := resolved_parameters()
	for spec in editable_knobs(model):
		values.append("%s=%s" % [spec["key"], p[spec["key"]]])
	return "%s 强度 %.2f：%s" % [implementation().display_name(), strength, "、".join(values)]

static func duel_seats(a: AISearch, b: AISearch, swap: bool) -> Dictionary:
	return {GameState.PLAYER: b if swap else a, GameState.AI: a if swap else b}

class Bus extends RefCounted:
	signal changed(strength: float)

static var _bus: Bus = null
static var _pref := -1.0
static var _model_pref := ""
static var _overrides: Dictionary = {}

static func bus() -> Bus:
	if _bus == null:
		_bus = Bus.new()
	return _bus

static func default_strength() -> float:
	var value := float(search_defaults().get("default_strength", 0.5))
	return clampf(value, 0.0, 1.0) if is_finite(value) else 0.5

static func pref_strength() -> float:
	if _pref < 0.0:
		_discard_saved_settings()
		_pref = default_strength()
		_model_pref = default_model()
		_overrides.clear()
	return _pref

static func pref_model() -> String:
	pref_strength()
	return _model_pref if Registry.get_strategy(_model_pref) != null else default_model()

static func prefs() -> AISearch:
	var cfg := from_model(pref_model(), pref_strength())
	for key in _overrides:
		cfg.apply_override(str(key), _overrides[key])
	return cfg

static func set_pref_model(id: String) -> void:
	if Registry.get_strategy(id) == null:
		return
	pref_strength()
	_model_pref = id
	_overrides.clear()
	bus().changed.emit(_pref)

static func set_pref_strength(s: float) -> void:
	pref_strength()
	if not is_finite(s):
		return
	_pref = clampf(s, 0.0, 1.0)
	var budget_overrides := {}
	for key in ["compute_budget","node_budget"]:
		if _overrides.has(key): budget_overrides[key] = _overrides[key]
	_overrides.clear()
	_overrides.merge(budget_overrides,true)
	bus().changed.emit(_pref)

static func set_override(key: String, value: Variant) -> void:
	var cfg := prefs()
	if not cfg.apply_override(key, value):
		return
	_overrides[key] = cfg.get_knob(key)
	bus().changed.emit(_pref)

static func clear_overrides() -> void:
	pref_strength()
	_overrides.clear()
	bus().changed.emit(_pref)

static func has_overrides() -> bool:
	pref_strength()
	return not _overrides.is_empty()

static func _discard_saved_settings() -> void:
	if not FileAccess.file_exists(USER_PATH):
		return
	var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PATH))
	if error != OK and FileAccess.file_exists(USER_PATH):
		push_warning("无法清理旧 AI 参数文件（仍不读取）：%s" % error_string(error))

static func restore_defaults() -> void:
	_discard_saved_settings()
	_pref = default_strength()
	_model_pref = default_model()
	_overrides.clear()
	bus().changed.emit(_pref)

static func _reset_pref_cache() -> void:
	_pref = -1.0
	_model_pref = ""
	_overrides.clear()
