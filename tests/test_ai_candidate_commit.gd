# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	CardDB.ensure_loaded()
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_candidate_commit.json"))
	var state := GameState.new()
	StateCodec.restore(state,fixture.state)
	var before := StateCodec.state_hash(state)
	var cfg := AISearch.from_strength(0.76)
	var reference := AIEnvironment.copy(state)
	if not need(AIEnvironment.replay(reference,fixture.reference_intents),"回归局面的生产基线可经真实意图执行"):
		finish()
		return
	# 与调度器的基础评价使用同一口径；不把未完成的宽回应或未来评分混入断言。
	var p := AITurnPlan._task_parameters(cfg.resolved_parameters(),"evaluation")
	p["_context"] = AIActions.Context.new()
	p["_resumable"] = true
	var evaluated := AITurnPlan.resolve_current(reference,"ai",p)
	check(evaluated.complete and not evaluated.coverage_limited,"对照生产方案完成同口径基础评价")
	var chosen := AITurnPlan.choose_plan(state,"ai",cfg)
	check(chosen.diagnostics.selected_evaluation_complete and not chosen.diagnostics.future_started,
		"回归局面在当前评价阶段耗尽预算，选择不依赖未完成前推")
	check(float(chosen.diagnostics.score) >= float(evaluated.score),
		"预算停止时，已完成的更高分生产方案不会被低分旧候选覆盖")
	check(not chosen.intents.is_empty(),"有更好已完成生产方案时不提交空操作")
	check(AIEnvironment.replay(AIEnvironment.copy(state),chosen.intents),"最终更新的完整方案可真实执行")
	check(StateCodec.state_hash(state)==before,"更新选择不修改输入局面")
	check(chosen.diagnostics.compute_used <= int(AITurnPlan.effective_budget(cfg.resolved_parameters())*0.85),
		"候选排序与选择更新不透支行动预算")
	finish()
