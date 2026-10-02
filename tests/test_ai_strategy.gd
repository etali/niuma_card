# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Eval = preload("res://engine/ai_evaluation.gd")

func _initialize() -> void:
	CardDB.ensure_loaded()
	_test_model_profile()
	_test_dispatch()
	_test_read_only()
	_test_card_table_driven()
	finish()

func _test_model_profile() -> void:
	var low := AISearch.from_model("ai", 0.0)
	var high := AISearch.from_model("ai", 1.0)
	check(low.model == "ai" and high.model == "ai", "低高档均使用当前策略")
	check(int(low.get_knob("node_budget")) < int(high.get_knob("node_budget")),
		"强度升高会增加当前实现的实际预算")
	check(AISearch.from_tier("ai:0.45").model == "ai"
		and is_equal_approx(AISearch.from_tier("ai:0.45").strength, 0.45),
		"from_tier 解析 model:strength")

func _test_dispatch() -> void:
	var Env = preload("res://engine/ai_environment.gd")
	var Implementation = preload("res://engine/ai_turn_strategy.gd")
	for seed_i in range(1, 4):
		var state := GameState.new()
		state.set_seed(seed_i)
		state.new_game()
		var cfg := AISearch.from_model("ai", 0.0)
		var selected := AIPlan.choose_plan(state, GameState.AI, cfg)
		var expected: Dictionary = Implementation.new().choose_plan(state, GameState.AI, cfg)
		check(selected["intents"] == expected["intents"]
			and selected["diagnostics"]["profile"] == expected["diagnostics"]["profile"],
			"策略入口把当前配置完整交给注册实现")
		var replay := Env.copy(state)
		check(Env.replay(replay, selected["intents"]), "默认策略方案可由环境逐条回放")

func _test_read_only() -> void:
	var state := GameState.new()
	state.set_seed(20260917)
	state.new_game()
	var before := StateCodec.canon(StateCodec.snapshot(state))
	var features := Eval.features(state, GameState.AI)
	var score := Eval.score(state, GameState.AI)
	check(features.has("asset") and features.has("engine") and features.has("risk"),
		"AI 评分器返回通用资产/引擎/风险特征")
	check(is_finite(score), "AI 评分器返回有限排序分")
	check(StateCodec.canon(StateCodec.snapshot(state)) == before,
		"AI 评分器不修改状态、UID 或随机流")

func _test_card_table_driven() -> void:
	var src := FileAccess.get_file_as_string("res://engine/ai_evaluation.gd") \
		+ FileAccess.get_file_as_string("res://engine/ai_turn_plan.gd") \
		+ FileAccess.get_file_as_string("res://engine/ai_context.gd")
	var forbidden := ["yunketang", "shuabuting", "xinxijianfang", "chunwan", "dujiaoshou"]
	var hardcoded := []
	for token in forbidden:
		if src.contains('"' + token + '"') or src.contains("'" + token + "'"):
			hardcoded.append(token)
	check(hardcoded.is_empty(), "AI 实现不按具体卡名写策略分支（%s）" % [hardcoded])
	# 价格查询可抽到决策上下文；判真实估值随规则变化，避免绑定实现文件位置。
	var saved_cards := CardDB.CARDS
	CardDB.CARDS = saved_cards.duplicate(true)
	CardDB.CARDS["valuation_probe"] = {"name": "估值夹具", "kind": CardDB.KIND_LEGEND, "pawn": 3}
	var state := GameState.new()
	state.players = {GameState.PLAYER: {"cards": []}, GameState.AI: {"cards": []}}
	state.add_card(GameState.AI, "valuation_probe")
	var first := Eval.features(state, GameState.AI)
	CardDB.CARDS["valuation_probe"]["pawn"] = 11
	var second := Eval.features(state, GameState.AI)
	check(first["asset"] == 3.0 and second["asset"] == 11.0
		and second["total"] - first["total"] == 8.0,
		"出售价格从 3 调至 11 后，新一次 AI 估值资产和总分同步增加 8")
	CardDB.CARDS = saved_cards
