# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 玩家数据统一在 ~/.niumapai_record：录像在根目录，设置与学习进度在 settings/。
## 只在测试沙箱里验证搬迁和目录选择；产品默认值只做无副作用的路径推算。
const Progress = preload("res://engine/tutorial_progress.gd")
const CardConfigScript = preload("res://engine/card_config.gd")
const PickerScript = preload("res://scenes/replay_picker.gd")
const RolePrefScript = preload("res://engine/role_pref.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 玩家数据目录统一 ===")
	_check_default_layout()
	_check_modules_share_settings_dir()
	_check_migration()
	_check_data_dir_env()
	await _check_picker_hides_settings()
	SavePaths.settings_override = "user://"
	finish()

func _check_default_layout() -> void:
	var saved_env := OS.get_environment(SavePaths.DATA_DIR_ENV)
	OS.unset_environment(SavePaths.DATA_DIR_ENV)
	var home := OS.get_environment("HOME")
	check(SavePaths.root() == home.path_join(".niumapai_record"), "玩家数据根目录是 ~/.niumapai_record")
	check(not SavePaths.root().contains("Application Support") and not SavePaths.root().contains("~"),
		"根目录不在 Application Support 底下，`~` 已展开")
	OS.set_environment(SavePaths.DATA_DIR_ENV, saved_env)

func _check_modules_share_settings_dir() -> void:
	SavePaths.settings_override = "user://unified/settings"
	var dir := SavePaths.settings_dir()
	check(dir == ProjectSettings.globalize_path("user://unified/settings").simplify_path() and DirAccess.dir_exists_absolute(dir),
		"设置目录按需建出来")
	var paths := {"tutorial_progress.json": Progress.path(), "ui_preferences.json": UIConfig.user_path(),
		"palette.json": Palette.user_path(), "sound.json": Sfx.pref_path(),
		"cards_config.json": CardConfigScript.pref_path(), "role.json": RolePrefScript.pref_path()}
	for file_name in paths:
		check(paths[file_name] == dir.path_join(file_name), "%s 存在统一的设置目录" % file_name)
	check(paths.keys().all(func(file_name): return file_name in SavePaths.LEGACY_FILES)
		and SavePaths.LEGACY_FILES.size() == paths.size(), "每一份设置都在旧存档搬迁清单里")
	SavePaths.settings_override = "user://"

func _check_migration() -> void:
	var legacy := {"palette.json": '{"world":{"background":"#112233"}}', "role.json": '{"role":"hr"}',
		"sound.json": '{"muted":true}'}
	for file_name in legacy:
		_write("user://" + file_name, legacy[file_name])
	_write("user://moved/settings/sound.json", '{"muted":false}')
	SavePaths.settings_override = "user://moved/settings"
	var dir := SavePaths.settings_dir()
	check(FileAccess.get_file_as_string(dir.path_join("palette.json")) == legacy["palette.json"]
		and FileAccess.get_file_as_string(dir.path_join("role.json")) == legacy["role.json"], "旧存档原样搬进设置目录")
	check(not FileAccess.file_exists("user://palette.json") and not FileAccess.file_exists("user://role.json"),
		"搬成功后删掉旧位置的文件")
	check(FileAccess.get_file_as_string(dir.path_join("sound.json")) == '{"muted":false}'
		and FileAccess.get_file_as_string("user://sound.json") == legacy["sound.json"], "新位置已有的文件为准，旧文件原样不动")
	var leftovers := Array(DirAccess.get_files_at(dir)).filter(func(file_name): return file_name.ends_with(".tmp"))
	check(leftovers.is_empty(), "搬迁不留临时文件")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://sound.json"))
	SavePaths.settings_override = "user://"

func _check_data_dir_env() -> void:
	var saved_env := OS.get_environment(SavePaths.DATA_DIR_ENV)
	var saved_tape := Tape.directory_override
	var custom := ProjectSettings.globalize_path("user://env-data")
	OS.set_environment(SavePaths.DATA_DIR_ENV, custom)
	Tape.directory_override = ""
	SavePaths.settings_override = ""
	check(SavePaths.root() == custom and Tape.path_dir() == custom, "CARD_DATA_DIR 指定录像根目录")
	check(SavePaths.settings_dir() == custom.path_join("settings"), "设置跟着同一个根目录放进 settings/")
	OS.set_environment(SavePaths.DATA_DIR_ENV, "relative/dir")
	check(not SavePaths.root().begins_with("relative"), "相对路径的 CARD_DATA_DIR 不采用，避免存进工作目录")
	OS.set_environment(SavePaths.DATA_DIR_ENV, saved_env)
	Tape.directory_override = saved_tape
	SavePaths.settings_override = "user://"

func _check_picker_hides_settings() -> void:
	var saved_env := OS.get_environment(SavePaths.DATA_DIR_ENV)
	var saved_tape := Tape.directory_override
	var data := ProjectSettings.globalize_path("user://picker-data")
	OS.set_environment(SavePaths.DATA_DIR_ENV, data)
	Tape.directory_override = ""
	SavePaths.settings_override = ""
	SavePaths.settings_dir()
	DirAccess.make_dir_recursive_absolute(data.path_join("2026-赛季"))
	_write(data.path_join("old_match.json"), "{}")
	var stub := GDScript.new()
	stub.source_code = "extends Node\nvar drawer_presentation = null\n"
	stub.reload()
	var host := Node.new()
	host.set_script(stub)
	root.add_child(host)
	var picker: CanvasLayer = PickerScript.new()
	picker.bind(host)
	root.add_child(picker)
	await process_frame
	var shown: Array = []
	for i in picker._files.item_count:
		shown.append(picker._files.get_item_text(i))
	check(shown.has("old_match.json") and shown.has("2026-赛季/"), "录像目录照常列出录像和子目录")
	check(not shown.has("settings/"), "设置目录不出现在读入录像的列表里")
	picker.queue_free()
	host.queue_free()
	await process_frame
	OS.set_environment(SavePaths.DATA_DIR_ENV, saved_env)
	Tape.directory_override = saved_tape

func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
