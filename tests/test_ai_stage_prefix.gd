# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	CardDB.ensure_loaded()
	var state := GameState.new()
	state.set_seed(27)
	state.new_game()
	var before := StateCodec.state_hash(state)
	# 相同总额度隔离强度允许阶段，验证高档实际执行低档的同一前缀。
	var low := AISearch.from_strength(0.5)
	var high := AISearch.from_strength(1.0)
	for cfg in [low,high]:
		cfg.apply_override("compute_budget",12000)
		cfg.work_session = preload("res://engine/ai_work_budget.gd").new(12000)
	var a := AITurnPlan.choose_plan(state,GameState.PLAYER,low)
	var b := AITurnPlan.choose_plan(state,GameState.PLAYER,high)
	var count := mini(a.diagnostics.search_stages.size(),b.diagnostics.search_stages.size())
	for i in count:
		check(StateCodec.canon(a.diagnostics.search_stages[i]) == StateCodec.canon(b.diagnostics.search_stages[i]),
			"高档的已有阶段与低档计算费用、候选和完成层相同")
	high.work_session = preload("res://engine/ai_work_budget.gd").new(12000)
	var again := AITurnPlan.choose_plan(state,GameState.PLAYER,high)
	b.diagnostics.erase("elapsed_ms")
	again.diagnostics.erase("elapsed_ms")
	check(StateCodec.canon(b) == StateCodec.canon(again),"重复搜索不受墙钟速度或历史缓存影响")
	check(StateCodec.state_hash(state) == before,"阶段搜索不改变规则状态")
	check(AIEnvironment.replay(AIEnvironment.copy(state),b.intents),"阶段结果可真实执行")
	check(b.diagnostics.generation_nodes+b.diagnostics.current_nodes+b.diagnostics.future_nodes == b.diagnostics.compute_used,
		"所有已完成和中断阶段的计算分账守恒")
	finish()
