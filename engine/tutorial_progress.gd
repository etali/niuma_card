# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const Store = preload("res://engine/json_store.gd")
const Config = preload("res://engine/config_data.gd")
const PATH := "user://tutorial_progress.json"

static func read() -> Dictionary:
	var value := Config.read_dictionary(PATH)
	if not value.get("courses", {}) is Dictionary:
		value["courses"] = {}
	return value

static func invitation_seen() -> bool:
	return bool(read().get("invitation_seen", false))

static func dismiss_invitation() -> bool:
	var value := read()
	value["invitation_seen"] = true
	return Store.save(PATH, value)

static func course(id: String) -> Dictionary:
	var item: Variant = read().get("courses", {}).get(id, {})
	return item if item is Dictionary else {}

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
	return Store.save(PATH, value)

static func resume_id() -> String:
	var value := read()
	var id := str(value.get("last_course", ""))
	return id if course(id).get("status", "") != "completed" else ""
