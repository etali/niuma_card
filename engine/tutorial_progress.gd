# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const Store = preload("res://engine/json_store.gd")
const Config = preload("res://engine/config_data.gd")
const SavePaths = preload("res://engine/save_paths.gd")

static func path() -> String:
	return SavePaths.settings_file("tutorial_progress.json")

static func read() -> Dictionary:
	var value := Config.read_dictionary(path())
	if not value.get("courses", {}) is Dictionary:
		value["courses"] = {}
	return value

## 入口提示和首次邀请只面向新玩家。新版首次运行时判定一次并写入：已有学习记录或录像的
## 老玩家视为已展开过入口、也回应过邀请。之后不再按录像推断——新玩家退出时自动存下的
## 录像不能让提示提前消失。
static func settle_returning_player() -> void:
	var value := read()
	if value.has("handle_opened"):
		return
	var returning := FileAccess.file_exists(path()) or _has_recordings()
	value["handle_opened"] = returning
	if returning:
		value["invitation_seen"] = true
	Store.save(path(), value)

static func _has_recordings() -> bool:
	var directory := DirAccess.open(Tape.path_dir())
	if directory == null:
		return false
	for name in directory.get_files():
		if name.get_extension() == "json":
			return true
	return false

static func handle_opened() -> bool:
	return bool(read().get("handle_opened", false))

static func mark_handle_opened() -> bool:
	var value := read()
	value["handle_opened"] = true
	return Store.save(path(), value)

static func invitation_seen() -> bool:
	return bool(read().get("invitation_seen", false))

## choice 记录首次邀请的回答："tutorial" 跟教程，"skip" 直接开局。
static func dismiss_invitation(choice := "skip") -> bool:
	var value := read()
	value["invitation_seen"] = true
	value["invitation_choice"] = choice
	return Store.save(path(), value)

## 首次邀请选了直接开局、也从没开过任何课程的玩家，第一次输掉单机局时在结算页补一次入口。
static func wants_post_game_nudge() -> bool:
	var value := read()
	return str(value.get("invitation_choice", "")) == "skip" and value.get("courses", {}).is_empty() \
		and not bool(value.get("post_game_nudged", false))

static func mark_post_game_nudged() -> bool:
	var value := read()
	value["post_game_nudged"] = true
	return Store.save(path(), value)

static func course(id: String) -> Dictionary:
	var item: Variant = read().get("courses", {}).get(id, {})
	return item if item is Dictionary else {}

static func request_first_game_help() -> bool:
	if tip_seen("first_game"): return true
	var value := read()
	value["first_game_help"] = true
	return Store.save(path(), value)

static func consume_first_game_help() -> bool:
	var value := read()
	if not value.get("first_game_help", false): return false
	value["first_game_help"] = false
	Store.save(path(), value)
	return true

static func tip_seen(id: String) -> bool:
	var tips: Variant = read().get("tips", {})
	return tips is Dictionary and bool(tips.get(id, false))

static func mark_tip_seen(id: String) -> bool:
	var value := read()
	var tips: Dictionary = value.get("tips", {}) if value.get("tips", {}) is Dictionary else {}
	tips[id] = true
	value["tips"] = tips
	return Store.save(path(), value)

static func record(id: String, step: int, status: String) -> bool:
	if id.is_empty() or status not in ["started", "completed", "viewed", "skipped"]:
		return false
	var value := read()
	var entries: Dictionary = value.get("courses", {})
	var previous: Variant = entries.get(id, {})
	var item: Dictionary = previous.duplicate(true) if previous is Dictionary else {}
	item["step"] = maxi(0, step)
	if status == "viewed":
		item["seen_demo"] = true
	# 重练或看演示不会抹掉曾经亲手完成的记录。
	if item.get("status", "") != "completed":
		item["status"] = status
	entries[id] = item
	value["courses"] = entries
	value["last_course"] = id
	value["invitation_seen"] = true
	return Store.save(path(), value)

static func resume_id() -> String:
	var value := read()
	var id := str(value.get("last_course", ""))
	return id if course(id).get("status", "") != "completed" else ""
