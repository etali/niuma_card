# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Per-board interaction preferences. A live edit does not touch disk until
## Save; each new board reads the last successfully saved value independently.
const JsonStore = preload("res://engine/json_store.gd")
const ConfigData = preload("res://engine/config_data.gd")
const SavePaths = preload("res://engine/save_paths.gd")

var _spec: Dictionary
var _path: String
var _hit_fraction: float

func _init(spec: Dictionary, read_user_preferences := true) -> void:
	_spec = spec.duplicate(true)
	assert(float(_spec.min_hit_fraction) > 0.0 and float(_spec.max_hit_fraction) <= 1.0 \
		and float(_spec.min_hit_fraction) < float(_spec.max_hit_fraction) and float(_spec.step) > 0.0,
		"Invalid snapping bounds in ui.json.board")
	_hit_fraction = _validated(float(_spec.hit_fraction))
	if not read_user_preferences: return
	_path = SavePaths.off_work_settings_file(str(_spec.preferences_file))
	var value: Variant = ConfigData.read_dictionary(_path).get("hit_fraction")
	if (value is int or value is float) and is_finite(float(value)):
		_hit_fraction = _validated(float(value))

func get_hit_fraction() -> float:
	return _hit_fraction

func set_hit_fraction(value: float) -> void:
	if is_finite(value): _hit_fraction = _validated(value)

func _validated(value: float) -> float:
	return clampf(snappedf(value, float(_spec.step)), float(_spec.min_hit_fraction), float(_spec.max_hit_fraction))

func save() -> bool:
	return not _path.is_empty() and JsonStore.save(_path, {"hit_fraction": _hit_fraction})

func reset() -> bool:
	_hit_fraction = _validated(float(_spec.hit_fraction))
	return save()
