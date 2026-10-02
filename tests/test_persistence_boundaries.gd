# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Store = preload("res://engine/json_store.gd")

func _initialize() -> void:
	_check_preference_failure()
	_check_recording_files()
	_check_competing_writers()
	finish()

func _check_preference_failure() -> void:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CardConfig.DEFAULT_PATH))
	var first := "user://first-cards.json"
	var second := "user://second-cards.json"
	check(Store.save(first, base) and Store.save(second, base), "创建两份合法卡表")
	check(CardConfig.select(first).get("ok", false), "原选择成功持久化")
	var selected := CardConfig.selected_path()
	var pref := ProjectSettings.globalize_path(CardConfig.PREF_PATH)
	var backup := pref + ".previous"
	check(DirAccess.rename_absolute(pref, backup) == OK and DirAccess.make_dir_absolute(pref) == OK,
		"构造偏好文件不可写的失败条件")
	check(not CardConfig.select(second).get("ok", true), "保存失败不会报告选择成功")
	check(CardConfig.selected_path() == selected, "保存失败保留原内存选择")
	check(not CardConfig.clear_selection().get("ok", true), "恢复默认同样报告持久化失败")
	check(CardConfig.selected_path() == selected, "恢复失败也保留原选择")
	DirAccess.remove_absolute(pref)
	DirAccess.rename_absolute(backup, pref)
	CardConfig._selected_path = ""
	CardConfig._loaded = false
	check(CardConfig.selected_path() == selected, "重启读取原来成功保存的选择")
	check(CardConfig.clear_selection().get("ok", false), "存储恢复后可以正常清除选择")
	CardConfig._loaded = false
	check(CardConfig.selected_path().is_empty(), "清除选择确实持久化")

func _record(seed_value: int, note: String) -> Tape:
	var state := GameState.new()
	state.set_seed(seed_value)
	state.new_game()
	var tape := Tape.new()
	tape.start(IntentApply.new(state), note)
	tape.stop()
	return tape

func _check_recording_files() -> void:
	var first := _record(711, "first")
	var second := _record(712, "second")
	var first_path := first.save()
	var second_path := second.save()
	check(not first_path.is_empty() and not second_path.is_empty() and first_path != second_path,
		"不同牌局同进度连续默认保存使用不同文件")
	var loaded := Tape.load_from(first_path)
	check(loaded.get("ok", false) and loaded["tape"].meta["note"] == "first", "第二次保存不覆盖第一局")
	check(not second.save().is_empty(), "同一录像重复保存也保留新副本")
	var fixed := first.save("collision.json")
	check(not fixed.is_empty() and second.save("collision.json").is_empty(), "指定同名文件也拒绝静默覆盖")
	loaded = Tape.load_from(fixed)
	check(loaded.get("ok", false) and loaded["tape"].meta["note"] == "first", "拒绝覆盖后原文件仍完整")
	check(second.save("../escape.json").is_empty(), "文件名不能逃离录像目录")
	var directory := DirAccess.open(Tape.path_dir())
	check(directory.get_directories().is_empty(), "保存完成释放独占声明")
	for file in directory.get_files():
		check(not file.ends_with(".tmp"), "保存完成没有遗留临时文件")

func _check_competing_writers() -> void:
	var target := "user://concurrent.json"
	var left := Thread.new()
	var right := Thread.new()
	left.start(func(): return Store.save(target, {"writer": "left"}, false))
	right.start(func(): return Store.save(target, {"writer": "right"}, false))
	var a: bool = left.wait_to_finish()
	var b: bool = right.wait_to_finish()
	check(a != b, "并发保存同名文件只有一方能够成功")
	var result = JSON.parse_string(FileAccess.get_file_as_string(target))
	check(result["writer"] == ("left" if a else "right"), "落盘内容属于成功的一方")
	check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(target) + ".writing"),
		"并发保存也释放独占声明")
