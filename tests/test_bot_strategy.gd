# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Eval = preload("res://engine/on_work_bot_evaluation.gd")

func _initialize() -> void:
	OnWorkCardDB.ensure_loaded()
	_test_model_profile()
	_test_dispatch()
	_test_read_only()
	_test_card_table_driven()
	finish()

func _test_model_profile() -> void:
	var low := OnWorkBOTSearch.from_model("bot", 0.0)
	var high := OnWorkBOTSearch.from_model("bot", 1.0)
	check(low.model == "bot" and high.model == "bot", "低高档均使用当前策略")
	check(OnWorkBOTTurnPlan.effective_budget(low.resolved_parameters()) < OnWorkBOTTurnPlan.effective_budget(high.resolved_parameters()),
		"强度升高会增加当前实现的实际预算")
	check(OnWorkBOTSearch.from_tier("bot:0.45").model == "bot"
		and is_equal_approx(OnWorkBOTSearch.from_tier("bot:0.45").strength, 0.45),
		"from_tier 解析 model:strength")

func _test_dispatch() -> void:
	var Env = preload("res://engine/on_work_bot_environment.gd")
	var Implementation = preload("res://engine/on_work_bot_turn_strategy.gd")
	for seed_i in range(1, 4):
		var state := OnWorkState.new()
		state.set_seed(seed_i)
		state.new_game()
		var cfg := OnWorkBOTSearch.from_model("bot", 0.0)
		var selected := OnWorkBOTPlan.choose_plan(state, OnWorkState.BOT, cfg)
		var expected: Dictionary = Implementation.new().choose_plan(state, OnWorkState.BOT, cfg)
		check(selected["intents"] == expected["intents"]
			and selected["diagnostics"]["profile"] == expected["diagnostics"]["profile"],
			"策略入口把当前配置完整交给注册实现")
		var replay := Env.copy(state)
		check(Env.replay(replay, selected["intents"]), "默认策略方案可由环境逐条回放")

func _test_read_only() -> void:
	var state := OnWorkState.new()
	state.set_seed(20260917)
	state.new_game()
	var before := OnWorkStateCodec.canon(OnWorkStateCodec.snapshot(state))
	var features := Eval.features(state, OnWorkState.BOT)
	var score := Eval.score(state, OnWorkState.BOT)
	check(features.has("asset") and features.has("engine") and features.has("risk"),
		"BOT 评分器返回通用资产/引擎/风险特征")
	check(is_finite(score), "BOT 评分器返回有限排序分")
	check(OnWorkStateCodec.canon(OnWorkStateCodec.snapshot(state)) == before,
		"BOT 评分器不修改状态、UID 或随机流")

func _test_card_table_driven() -> void:
	var src := FileAccess.get_file_as_string("res://engine/on_work_bot_evaluation.gd") \
		+ FileAccess.get_file_as_string("res://engine/on_work_bot_turn_plan.gd") \
		+ FileAccess.get_file_as_string("res://engine/on_work_bot_context.gd")
	var forbidden := ["yunketang", "shuabuting", "xinxijianfang", "chunwan", "dujiaoshou"]
	var hardcoded := []
	for token in forbidden:
		if src.contains('"' + token + '"') or src.contains("'" + token + "'"):
			hardcoded.append(token)
	check(hardcoded.is_empty(), "BOT 实现不按具体卡名写策略分支（%s）" % [hardcoded])
	# 价格查询可抽到决策上下文；判真实估值随规则变化，避免绑定实现文件位置。
	var saved_cards := OnWorkCardDB.CARDS
	OnWorkCardDB.CARDS = saved_cards.duplicate(true)
	OnWorkCardDB.CARDS["valuation_probe"] = {"name": "估值夹具", "kind": OnWorkCardDB.KIND_LEGEND, "pawn": 3}
	var state := OnWorkState.new()
	state.players = {OnWorkState.PLAYER: {"cards": []}, OnWorkState.BOT: {"cards": []}}
	state.add_card(OnWorkState.BOT, "valuation_probe")
	var first := Eval.features(state, OnWorkState.BOT)
	OnWorkCardDB.CARDS["valuation_probe"]["pawn"] = 11
	var second := Eval.features(state, OnWorkState.BOT)
	check(first["asset"] == 3.0 and second["asset"] == 11.0
		and second["total"] - first["total"] == 8.0,
		"出售价格从 3 调至 11 后，新一次 BOT 估值资产和总分同步增加 8")
	OnWorkCardDB.CARDS = saved_cards
