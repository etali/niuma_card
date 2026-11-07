# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Slots = preload("res://engine/shift_slot.gd")

func _initialize() -> void:
	if "--check-shift-playtest" in OS.get_cmdline_user_args() or "--check-shift-playtest" in OS.get_cmdline_args(): _probe.call_deferred()
	else: _run.call_deferred()

func _run() -> void:
	for variant in ["on", "off", "off-desktop"]:
		var off: bool = variant != "on"
		var desktop: bool = variant == "off-desktop"
		var path := "res://data/off_work_cards.json" if off else "res://data/on_work_cards.json"
		var args := PackedStringArray(["--headless","--path",ProjectSettings.globalize_path("res://"),
			"--script","res://tests/test_shift_playtest.gd"])
		if not desktop: args.append("--")
		args.append("--check-shift-playtest")
		if desktop: args.append_array(["--cards-config", ProjectSettings.globalize_path(path)])
		else: args.append("--cards-config=" + ProjectSettings.globalize_path(path))
		if off: args.append("--off-work-playtest")
		var output := []
		var code := OS.execute(OS.get_executable_path(),args,output,true)
		var ready := "WORK_PLAYTEST_READY " if off else "CARDS_CONFIG_READY: "
		var log := "\n".join(output)
		var entry := "桌面启动器下班" if desktop else ("下班" if off else "上班")
		check(code == 0 and log.count(ready) == 1 and "SCRIPT ERROR" not in log,
			entry + "试玩经真实入口载入、发出 READY、门可往返且正式存档不变")
		if code != 0: printerr(log)
	finish()

func _probe() -> void:
	var off := "--off-work-playtest" in LaunchConfig.desktop_args()
	var mode := 1 if off else 0
	var saved := {"test_sentinel":"untouched"}
	for slot in [Slots.ON_WORK,Slots.OFF_WORK,"last_mode"]: Slots.save(slot,saved)
	root.size = Vector2i(1600,900)
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	for _i in 16: await process_frame
	var host := current_scene
	if not need(host.has_method("switch_mode") and host.active == mode,"试玩进入对应班次"):
		finish()
		return
	var original: Node = host.tables[mode]
	var state: RefCounted = original.state
	await host.switch_mode(1-mode)
	check(host.tables[1-mode].state != null,"另一套规则独立开局")
	check(OnWorkCardConfig.has_launch_override() != off,"自定义卡表只由对应的规则读取")
	await host.switch_mode(mode)
	check(host.tables[mode].state == state and host.active == mode,"回到同一试玩局")
	for slot in [Slots.ON_WORK,Slots.OFF_WORK,"last_mode"]:
		check(Slots.load_slot(slot) == saved,"保留正式存档 " + slot)
	finish()
