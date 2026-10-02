# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Duel := preload("res://tools/ai_duel.gd")

func _initialize() -> void:
	print("=== AI 成对对打统计 ===")
	var games: Array = [
		_game(1, GameState.PLAYER, "A"), _game(1, GameState.AI, "B"),
		_game(2, GameState.PLAYER, "A"), _game(2, GameState.AI, "draw"),
	]
	var summary := Duel.summarize(games)
	check(summary["a_wins"] == 2 and summary["b_wins"] == 1 and summary["draws"] == 1,
		"逐局结果分别计数，不把无结果记成胜负")
	check(is_equal_approx(float(summary["a_decisive_win_rate"]), 2.0 / 3.0),
		"分胜负胜率只用三场有胜者的对局")
	check(is_equal_approx(float(summary["a_score_rate"]), 0.625),
		"全局得分率把无结果计半分，保留它对结论的影响")
	check(is_equal_approx(float(summary["draw_rate"]), 0.25), "无结果率单独报告")
	check(summary["completed_seed_pairs"] == 2, "四场对应两个种子对")
	check(summary["by_a_seat"][GameState.PLAYER]["A"] == 2
		and summary["by_a_seat"][GameState.AI]["A"] == 0, "报告座位偏差")
	var interval: Array = summary["a_score_pair_bootstrap_95"]
	check(interval.size() == 2 and is_equal_approx(float(interval[0]), 0.5)
		and is_equal_approx(float(interval[1]), 0.75),
		"bootstrap 重采样整个种子对，两对观测均值是 0.5 和 0.75")
	check(summary["a_score_pair_bootstrap_95"] == Duel.summarize(games)["a_score_pair_bootstrap_95"],
		"报告区间可复现")
	var no_winner := Duel.summarize([_game(7, GameState.PLAYER, "draw"), _game(7, GameState.AI, "draw")])
	check(no_winner["a_decisive_win_rate"] == null, "全是无结果时不捏造分胜负胜率")
	check(no_winner["a_score_pair_bootstrap_95"].is_empty(), "少于两个种子对不报告区间")
	check(Duel._valid_label("ai:0") and Duel._valid_label("ai:max")
		and not Duel._valid_label("v1:max")
		and not Duel._valid_label("v2:0")
		and not Duel._valid_label("v3:0") and not Duel._valid_label("ai:2")
		and not Duel._valid_label("ai:garbage"), "对比模型和强度必须明确且合法")
	finish()

func _game(seed_i: int, a_seat: String, winner: String) -> Dictionary:
	return {"seed": seed_i, "a_seat": a_seat, "winner": winner, "duration_ms": 1.0, "rounds": 2}
