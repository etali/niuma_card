# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Debug has its own preference, so toggling it never commits unfinished UI edits.
const JsonStore = preload("res://engine/json_store.gd")
const ConfigData = preload("res://engine/config_data.gd")
const SavePaths = preload("res://engine/save_paths.gd")

var enabled := false
var _path := ""

func _init(spec: Dictionary, read_user_preferences := true) -> void:
	enabled = bool(spec.enabled)
	# Preview boards must not even create the user's settings directory.
	if not read_user_preferences: return
	_path = SavePaths.off_work_settings_file(str(spec.preferences_file))
	var value: Variant = ConfigData.read_dictionary(_path).get("enabled")
	if value is bool:
		enabled = value

func save() -> bool:
	return not _path.is_empty() and JsonStore.save(_path, {"enabled": enabled})
