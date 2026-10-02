# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AISearch
extends RefCounted

## 通用 AI profile + 用户偏好。算法只拿已解析快照，面板和算法读同一参数规格。
const Registry = preload("res://engine/ai_strategy_registry.gd")
const Strategy = preload("res://engine/ai_strategy.gd")
const USER_PATH := "user://ai_search.json"

var model := "ai"
var strength := 0.0
var parameters: Dictionary = {}

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
	var value := float(search_defaults().get("default_strength", 1.0))
	return clampf(value, 0.0, 1.0) if is_finite(value) else 1.0

static func pref_strength() -> float:
	if _pref < 0.0:
		var stored := AIConfig.read_json(USER_PATH)
		var value: Variant = stored.get("strength", default_strength())
		_pref = clampf(float(value), 0.0, 1.0) if Strategy._number(value) else default_strength()
		_model_pref = str(stored.get("model", default_model()))
		# 只迁移曾保存的同一套实现；不把旧名字重新注册为可选模型。
		if _model_pref == "v2":
			_model_pref = "ai"
		var removed := Registry.get_strategy(_model_pref) == null
		if removed:
			_model_pref = default_model()
		_overrides = {}
		# 旧实现或未知键不可污染现模型；已知模型只接受其schema声明的参数。
		var ov: Variant = stored.get("overrides", {})
		if not removed and ov is Dictionary:
			var cfg := from_model(_model_pref, _pref)
			for key in ov:
				if cfg.apply_override(str(key), ov[key]):
					_overrides[key] = cfg.get_knob(str(key))
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
	_overrides.clear()
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

static func save() -> bool:
	var file := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"format_version":2, "model":pref_model(),
		"strength":pref_strength(), "overrides":_overrides}, "  ", false))
	return true

static func restore_defaults() -> void:
	if FileAccess.file_exists(USER_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PATH))
	_pref = default_strength()
	_model_pref = default_model()
	_overrides.clear()
	bus().changed.emit(_pref)

static func _reset_pref_cache() -> void:
	_pref = -1.0
	_model_pref = ""
	_overrides.clear()
