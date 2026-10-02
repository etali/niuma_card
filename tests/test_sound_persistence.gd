# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var sound := Sfx.new()
	root.add_child(sound)
	check(not sound.user_muted, "首次启动没有偏好时默认有声")
	check(sound.set_user_muted(true), "用户静音设置成功写入持久文件")
	sound.queue_free()
	await process_frame
	sound = Sfx.new()
	root.add_child(sound)
	check(sound.user_muted and sound.muted, "重建声音节点恢复已保存的静音偏好")
	sound.set_user_muted(false)
	sound.set_drawer_suspended(true)
	sound.queue_free()
	await process_frame
	sound = Sfx.new()
	root.add_child(sound)
	check(not sound.user_muted and not sound.muted, "抽屉临时静音不会写成用户偏好")

	var path := ProjectSettings.globalize_path(Sfx.PREF_PATH)
	DirAccess.remove_absolute(path)
	DirAccess.make_dir_absolute(path)
	check(not sound.set_user_muted(true) and sound.user_muted, "持久写入失败返回失败，当前静音仍即时生效")
	DirAccess.remove_absolute(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string('{"muted":"false"}')
	file.close()
	sound.queue_free()
	await process_frame
	sound = Sfx.new()
	root.add_child(sound)
	check(not sound.user_muted, "错误类型的旧偏好安全回退默认值")

	# 两个真正的Godot进程共享runner的临时项目目录，不能依赖静态内存缓存。
	# 子脚本不继承harness，避免harness按PID再隔离到两个不同目录。
	var child_path := ProjectSettings.globalize_path("user://sound-child.gd")
	file = FileAccess.open(child_path, FileAccess.WRITE)
	file.store_string("""extends SceneTree
func _initialize():
 call_deferred("_run")
func _run():
 var sound = preload("res://scenes/sfx.gd").new()
 root.add_child(sound)
 var save = "--save-sound" in OS.get_cmdline_user_args()
 var ok = sound.set_user_muted(true) if save else sound.user_muted
 print("SOUND_PERSISTED=" + str(ok))
 sound.queue_free()
 await process_frame
 quit(0 if ok else 1)
""")
	file.close()
	for flag in ["--save-sound", "--read-sound"]:
		var output: Array = []
		var code := OS.execute(OS.get_executable_path(), PackedStringArray([
			"--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", child_path, "--", flag]), output, true)
		var logs := "\n".join(output)
		check(code == 0 and logs.contains("SOUND_PERSISTED=true") and not logs.contains("SCRIPT ERROR"),
			"独立进程%s验证静音跨启动保存" % flag)
		if code != 0:
			printerr(logs)
	finish()
