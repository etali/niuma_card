# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name BOTConfig
extends RefCounted

const ConfigData = preload("res://engine/config_data.gd")

## BOT 出厂参数。模拟参数供无头驱动使用，各实现的超参数独立读取，
## 不读取任何玩家偏好，也不依赖 CardDB、Palette 或 UIConfig，避免加载环。
const PATH := "res://data/bot.json"
const EXTERNAL_FILE := "bot.json"

static var _cache: Dictionary = {}
static var _source := ""

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

## 外置覆盖内置，缺失字段（包括嵌套搜索阶梯）继续取内置值。
## 返回深拷贝，调用方不能改污染缓存；显式 path 供工具和测试读取指定配置。
static func read_section(key: String, path := "") -> Dictionary:
	var resolved := source_path() if path.is_empty() else path
	var builtin := builtin_section(key)
	if resolved == PATH:
		return builtin
	return ConfigData.overlay(builtin, _raw_section(key, resolved))

## 外置配置缺项时取内置值，返回独立副本。
static func builtin_section(key: String) -> Dictionary:
	return _raw_section(key, PATH)

static func _raw_section(key: String, path: String) -> Dictionary:
	if not _cache.has(path):
		_cache[path] = read_json(path, true)
	var section: Variant = (_cache[path] as Dictionary).get(key, {})
	var result := (section as Dictionary).duplicate(true) if section is Dictionary else {}
	return result

static func _config_candidates() -> Array[String]:
	var exe_dir := OS.get_executable_path().get_base_dir()
	return [
		exe_dir.path_join(EXTERNAL_FILE),
		exe_dir.path_join("../../../" + EXTERNAL_FILE), # macOS .app 旁边
		"res://" + EXTERNAL_FILE,
		PATH,
	]

## 可选文件缺失时不警告；必需的出厂配置由调用方指定 warn_missing。
## FileAccess 同时支持 res:// 导出包内文件与外置绝对路径。
static func read_json(path: String, warn_missing := false) -> Dictionary:
	return ConfigData.read_dictionary(path, warn_missing, "BOT 配置")

## 配置热重载/测试时使用，只清理出厂参数缓存，不重置本次运行的玩家设置。
static func reset_cache() -> void:
	_cache.clear()
	_source = ""
