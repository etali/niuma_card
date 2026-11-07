# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Game = preload("res://scenes/off_work_main.tscn")

func _initialize() -> void:
	OS.set_environment("WORK_DATA_DIR", _test_data_dir.path_join("quotes"))
	_run.call_deferred()

func _open_game() -> Node:
	var game := Game.instantiate()
	game.set_meta("shift_session_enabled", true)
	root.add_child(game)
	game.set_process(false)
	return game

func _run() -> void:
	var game := _open_game()
	var board_rng: int = game.state._rng.state
	var last := ["", ""]
	for cycle in 2:
		var seen := [{}, {}]
		for i in 9:
			for winner in 2:
				var quote: String = game.hud.draw_result_taunt(winner)
				var pool: Array = game.hud.hud_config.result["win_taunts" if winner == 0 else "lose_taunts"]
				check(pool.size() == 9 and pool.has(quote), "各取本方胜负文案")
				check(not seen[winner].has(quote) and last[winner] != quote, "同轮不重复，跨轮相邻也不同")
				seen[winner][quote] = true
				last[winner] = quote
	check(game.state._rng.state == board_rng, "结算文案不影响供牌随机序列")

	var path := SavePaths.off_work_settings_file("result_taunts.json")
	var prior := FileAccess.get_file_as_string(path)
	game.hud.show_result(0, 5, func(): pass)
	check(FileAccess.get_file_as_string(path) == prior, "预览同一个面板不会消耗实战文案")
	game.hud.clear_result()

	game.state.resign(1)
	game._show_result()
	var won: String = game.result_layer.find_child("ResultMessage", true, false).text
	check(game.hud.hud_config.result.win_taunts.has(won), "对手认输显示本地胜利文案")
	var saved_bag := FileAccess.get_file_as_string(path)
	game.free()
	game = _open_game()
	check(game.state.winner == 0 and game.result_layer.find_child("ResultMessage", true, false).text == won, "恢复已结束的牌局沿用同一句")
	check(FileAccess.get_file_as_string(path) == saved_bag, "恢复结算不会推进文案轮次")
	game._new_game()
	game.state.resign(0)
	game._show_result()
	check(game.hud.hud_config.result.lose_taunts.has(game.result_layer.find_child("ResultMessage", true, false).text), "本地认输显示失败文案")
	game._new_game()
	game.state.winner = 2
	game._show_result()
	check(game.result_layer.find_child("ResultMessage", true, false) == null, "平局保持中性结算")
	game.free()
	finish()
