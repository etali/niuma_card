# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const ON_WORK_CARDS := "res://data/on_work_cards.json"
const OFF_WORK_CARDS := "res://data/off_work_cards.json"
const ON_WORK_BOT := "res://data/on_work_bot.json"
const OFF_WORK_BOT := "res://data/off_work_bot.json"

## 仅迁移本项目旧的内置文件名，外部路径仍使用玩家自己的文件。
const MOVED_CONFIGS := {
	"res://data/cards.json": ON_WORK_CARDS,
	"res://off_work/data/cards.json": OFF_WORK_CARDS,
	"res://data/bot.json": ON_WORK_BOT,
	"res://data/off_work_ai.json": OFF_WORK_BOT,
	"res://off_work/data/ai.json": OFF_WORK_BOT,
}

static func bundled_path(path: String) -> String:
	if path.is_empty() or FileAccess.file_exists(path):
		return path
	var local := ProjectSettings.localize_path(path) if path.is_absolute_path() else "res://".path_join(path)
	return MOVED_CONFIGS.get(local.simplify_path(), path)

## 配置只共享读取和合并机制；来源优先级、缓存、字段校验仍由各模块负责。
static func read_dictionary(path: String, warn_missing := false, label := "配置") -> Dictionary:
	if not FileAccess.file_exists(path):
		if warn_missing:
			push_warning("找不到 %s：%s" % [label, path])
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		if warn_missing:
			push_warning("无法读取 %s：%s" % [label, path])
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
		return json.data
	if warn_missing:
		push_warning("%s 必须是 JSON 字典：%s" % [label, path])
	return {}

## 字典递归覆盖；数组和标量整体替换，返回值不与任一输入共享可变容器。
static func overlay(base: Dictionary, over: Variant) -> Dictionary:
	var result := base.duplicate(true)
	if over is Dictionary:
		for key in over:
			var value: Variant = over[key]
			if value is Dictionary and result.get(key) is Dictionary:
				result[key] = overlay(result[key], value)
			else:
				result[key] = value.duplicate(true) if value is Dictionary or value is Array else value
	return result
