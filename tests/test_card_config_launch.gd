# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const CardConfigClass = preload("res://engine/card_config.gd")

# 用真实子进程传参，验证 OS 读取、场景开局、重开和联网切回的完整路径。
func _initialize() -> void:
	var args := LaunchConfig.parse_flags(OS.get_cmdline_user_args())
	if args.has("verify-launch"):
		await _verify_child(args)
		return
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CardConfigClass.DEFAULT_PATH))
	var custom := base.duplicate(true)
	custom["yunketang"]["price"] = 8
	custom["yunketang"]["pawn"] = 9
	custom["_game"]["start_cash"] = 23
	var path := ProjectSettings.globalize_path("user://试玩 配置-%d.json" % OS.get_process_id())
	var saved_path := path + ".saved.json"
	_write_cards(path, custom)
	var saved := base.duplicate(true)
	saved["yunketang"]["price"] = 6
	_write_cards(saved_path, saved)
	_run_child(["--cards-config=" + path, "--verify-launch=explicit", "--saved-config=" + saved_path], 0, "显式卡表优先于保存偏好，实际开局/出售/重开/联网均走共享加载")
	_run_child(["--cards-config", path, "--verify-launch=explicit", "--saved-config=" + saved_path], 0, "空格形式卡表参数进入真实游戏")
	_run_child(["--verify-launch=saved", "--saved-config=" + saved_path], 0, "无参数启动保持既有保存偏好行为")
	_run_child(["--verify-launch=default"], 0, "无参数也无偏好时仍使用默认卡表")
	_run_child(["--cards-config=" + path + ".missing", "--verify-launch=invalid", "--saved-config=" + saved_path], 0, "错误路径明确失败且不回退或改写偏好")
	# 真实主场景收到坏路径必须退出，不能只有选择器报错、场景仍继续开局。
	var output: Array = []
	var status := OS.execute(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"), "--quit-after", "2", "--",
		"--cards-config=" + path + ".missing"
	]), output, true)
	var logs := "\n".join(output)
	check(status == 1 and "指定卡表加载失败" in logs and not "CARDS_CONFIG_READY:" in logs and not "SCRIPT ERROR" in logs,
		"错误启动参数阻止主场景开局并明确报错")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(saved_path)
	finish()

func _run_child(flags: Array, expected: int, label: String) -> void:
	var command := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", "res://tests/test_card_config_launch.gd", "--"])
	command.append_array(PackedStringArray(flags))
	var output: Array = []
	var status := OS.execute(OS.get_executable_path(), command, output, true)
	var logs := "\n".join(output)
	var ok := status == expected and "0 失败" in logs and not "SCRIPT ERROR" in logs
	if flags.has("--verify-launch=explicit"):
		ok = ok and "CARDS_CONFIG_READY: " in logs
	check(ok, label)
	if not ok:
		printerr(logs)

func _verify_child(args: Dictionary) -> void:
	var mode := str(args["verify-launch"])
	var pref_before := FileAccess.get_file_as_bytes(CardConfigClass.PREF_PATH) if FileAccess.file_exists(CardConfigClass.PREF_PATH) else PackedByteArray()
	# 模拟已加载的玩家选择；测试不改真实 user:// 偏好文件。
	CardConfigClass._loaded = true
	CardConfigClass._selected_path = str(args.get("saved-config", ""))
	var saved_path := CardConfigClass._selected_path
	if mode == "invalid":
		CardDB.load_default()
		var result := CardConfigClass.apply_solo()
		check(not result.get("ok", true) and not result.get("used_default", false), "错误显式配置不回退")
		check("指定卡表加载失败" in str(result.get("reason", "")), "错误消息指出指定卡表")
		check(CardConfigClass._selected_path == saved_path, "失败保留原选择")
	else:
		var main: Node = await boot_main()
		if mode == "explicit":
			var expected := str(args["cards-config"])
			check(CardDB.loaded_from == expected and CardDB.get_def("yunketang")["price"] == 8,
				"显式文件覆盖原保存卡表且真实卡面数值正确")
			check(main.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == 23 and CardDB.pawn_value("yunketang") == 9,
				"开局资金和出售价格实际来自指定配置")
			var card: Dictionary = main.state.add_card(GameState.PLAYER, "yunketang")
			var sale: Dictionary = main.state.pawn(GameState.PLAYER, [card["uid"]])
			check(sale.get("ok", false) and main.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == 32,
				"实际出售收入使用卡表覆盖")
			main.state.winner = GameState.PLAYER
			main._show_game_over()
			main._on_restart()
			await settle()
			check(CardDB.loaded_from == expected and main.state.resource_count(GameState.PLAYER, CardDB.RES_CASH) == 23,
				"重开单机仍使用本次指定配置")
			var prepared: Dictionary = main.prepare_network_cards()
			check(not prepared.get("ok", true) and CardDB.loaded_from == expected,
				"自定义卡表局拒绝联网等待，保留当前规则")
			main.state.winner = GameState.PLAYER
			main._show_game_over()
			main._on_restart()
			await settle()
			check(CardDB.loaded_from == expected, "回到单机时恢复本次指定配置")
			check(not main.choose_card_config(saved_path).get("ok", true) and not main.clear_card_config().get("ok", true),
				"指定配置时不允许设置界面静默更改偏好")
			check(CardConfigClass._selected_path == saved_path, "临时试玩不覆盖原保存选择")
		elif mode == "saved":
			check(CardDB.loaded_from == saved_path and CardDB.get_def("yunketang")["price"] == 6,
				"无命令行覆盖时加载保存选择")
		else:
			check(CardDB.loaded_from == CardConfigClass.DEFAULT_PATH, "无选择时使用内置默认")
		main.queue_free()
		await process_frame
	var pref_after := FileAccess.get_file_as_bytes(CardConfigClass.PREF_PATH) if FileAccess.file_exists(CardConfigClass.PREF_PATH) else PackedByteArray()
	check(pref_after == pref_before, "整个试玩过程不修改持久化偏好文件")
	finish()

func _write_cards(path: String, cards: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(cards))
	file.close()
