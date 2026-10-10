# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name UIConfig
extends RefCounted

const ConfigData = preload("res://engine/config_data.gd")

## 展示配置统一入口：启动默认值、配色、素材呈现、资源名称与音效。
## 独立于 CardDB / Palette，避免加载环；玩家偏好仍由各自的设置模块覆盖。
const PATH := "res://data/ui.json"
const EXTERNAL_FILE := "ui.json"
const USER_PATH := "user://ui_preferences.json"
const FALLBACK := {
	"window_fraction": 0.98,
	"perspective_angle": 80.0,
	"icon_scale": 0.75,
	"table_zoom": 1.0,
	"hover_animation_speed": 2.0,
}
const RANGES := {
	"window_fraction": Vector2(0.5, 1.0),
	"perspective_angle": Vector2(45.0, 80.0),
	"icon_scale": Vector2(0.5, 3.0),
	"table_zoom": Vector2(1.0, 2.5),
}
const HOVER_SPEED_CONTROL := {"min": 0.5, "max": 2.0, "step": 0.1}

static var _cache: Dictionary = {}
static var _source := ""
static var _hover_animation_speed := -1.0

## 仅缓存播放倍率；正在播放的卡牌每帧读取，因此调速不会重启或重载动画。
static func get_hover_animation_speed() -> float:
	if _hover_animation_speed < 0.0:
		_hover_animation_speed = read_defaults()["hover_animation_speed"]
	return _hover_animation_speed

static func set_hover_animation_speed(value: float) -> void:
	_hover_animation_speed = validated_defaults({"hover_animation_speed": value})["hover_animation_speed"]

static func hover_speed_text(value: float) -> String:
	var text := String.num(value, 3)
	return (text if text.contains(".") else text + ".0") + "×"

static func hover_speed_control(path := "") -> Dictionary:
	var source: Variant = read_section("controls", path).get("hover_animation_speed", {})
	var result := HOVER_SPEED_CONTROL.duplicate()
	if not source is Dictionary:
		return result
	for key in result:
		var value: Variant = source.get(key)
		if (value is int or value is float) and is_finite(float(value)) and float(value) > 0.0:
			result[key] = float(value)
	if result["min"] >= result["max"] or result["step"] > result["max"] - result["min"]:
		return HOVER_SPEED_CONTROL.duplicate()
	return result

## 与外置 cards.json 同优先级，但独立选择文件，不要求两份配置一起外置。
static func source_path() -> String:
	if _source.is_empty():
		for candidate in _config_candidates():
			if FileAccess.file_exists(candidate):
				_source = candidate
				break
		if _source.is_empty():
			_source = PATH
	return _source

## 外置覆盖内置，缺失字段（包括嵌套色板和音效动作）继续取内置值。
## 返回深拷贝，调用方不能改污染缓存；显式 path 供工具和测试读取指定配置。
static func read_section(key: String, path := "") -> Dictionary:
	var resolved := source_path() if path.is_empty() else path
	var builtin := builtin_section(key)
	if resolved == PATH:
		return builtin
	return ConfigData.overlay(builtin, _raw_section(key, resolved))

## 缺键兜底只取内置值，不混入外置 UI 参数。
static func builtin_section(key: String) -> Dictionary:
	return _raw_section(key, PATH)

static func _raw_section(key: String, path: String) -> Dictionary:
	if not _cache.has(path):
		_cache[path] = read_json(path, true)
	var section: Variant = (_cache[path] as Dictionary).get(key, {})
	return (section as Dictionary).duplicate(true) if section is Dictionary else {}

static func _config_candidates() -> Array[String]:
	var exe_dir := OS.get_executable_path().get_base_dir()
	return [
		exe_dir.path_join(EXTERNAL_FILE),
		exe_dir.path_join("../../../" + EXTERNAL_FILE), # macOS .app 旁边
		"res://" + EXTERNAL_FILE,
		PATH,
	]

## 缺失的玩家偏好不警告；必需的出厂配置由调用方指定 warn_missing。
## FileAccess 同时支持 res:// 导出包内文件与外置绝对路径。
static func read_json(path: String, warn_missing := false) -> Dictionary:
	return ConfigData.read_dictionary(path, warn_missing, "UI 配置")

## 配置热重载/测试时使用，不触碰 user://palette.json。
static func reset_cache() -> void:
	_cache.clear()
	_source = ""
	_hover_animation_speed = -1.0

static func read_defaults(path: String = "") -> Dictionary:
	var values := read_section("defaults", path)
	if path.is_empty():
		var user: Variant = read_json(USER_PATH).get("defaults", {})
		if user is Dictionary:
			values = ConfigData.overlay(values, user)
	return validated_defaults(values, path)

static func save_preferences(values: Dictionary) -> bool:
	var file := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"defaults": validated_defaults(values)}, "  ", false))
	return true

static func restore_preferences() -> Dictionary:
	if FileAccess.file_exists(USER_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(USER_PATH))
	var defaults := validated_defaults(read_section("defaults"))
	_hover_animation_speed = defaults["hover_animation_speed"]
	return defaults

static func validated_defaults(source: Variant, path := "") -> Dictionary:
	var result := FALLBACK.duplicate()
	if not source is Dictionary:
		return result
	for key in FALLBACK:
		var value: Variant = source.get(key)
		if not (value is int or value is float) or not is_finite(float(value)):
			continue
		var limits: Vector2
		if key == "hover_animation_speed":
			var control := hover_speed_control(path)
			limits = Vector2(control["min"], control["max"])
		else:
			limits = RANGES[key]
		result[key] = clampf(float(value), limits.x, limits.y)
	result["perspective_angle"] = roundf(result["perspective_angle"])
	return result
