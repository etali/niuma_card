# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _evaluate(state: GameState, intents: Array, kind: String) -> Dictionary:
	var leaf := AIEnvironment.copy(state)
	check(AIEnvironment.replay(leaf,intents),"回应覆盖对照方案经真实规则执行")
	var p := AITurnPlan._task_parameters(AISearch.from_strength(0.76).resolved_parameters(),kind)
	p["_context"] = AIActions.Context.new()
	p["_resumable"] = true
	return AITurnPlan.resolve_current(leaf,"ai",p)

func _initialize() -> void:
	CardDB.ensure_loaded()
	_test_comparison_levels()
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_response_coverage.json"))
	var state := GameState.new()
	StateCodec.restore(state,fixture.state)
	var before := StateCodec.state_hash(state)
	var shallow := _evaluate(state,fixture.unsafe_intents,"evaluation")
	var unsafe := _evaluate(state,fixture.unsafe_intents,"refinement")
	var safe := _evaluate(state,fixture.safe_intents,"refinement")
	check(shallow.complete and unsafe.complete and safe.complete,"三个对照均完成各自规格的回应评价")
	check(float(shallow.score)>float(safe.score) and float(unsafe.score)<float(safe.score),
		"录像夹具重现浅评价乐观、同规格宽回应却判更差的反转")
	var cfg := AISearch.from_strength(0.76)
	var chosen := AITurnPlan.choose_plan(state,"ai",cfg)
	check(chosen.diagnostics.selected_refinement_complete,
		"已有完整宽回应方案时，未完成同等检查的候选不能替换它")
	var validated := _evaluate(state,chosen.intents,"refinement")
	check(validated.complete and float(validated.score)>=float(safe.score),
		"最终方案按相同宽回应规格验证，不丢失已完成的安全基线")
	var actual := AIEnvironment.copy(state)
	check(AIEnvironment.replay(actual,chosen.intents),"已验证的最终方案可实际执行")
	MatchSimulator.continue_rounds(actual,1,"ai",{"ai":AISearch.from_strength(0.76),"player":AISearch.from_strength(0.25)})
	check(actual.winner!="player" and actual.resource_count("ai","user")>0,
		"seed1017真实对手续行后，不再选择可避免的当回合用户清零方案")
	check(StateCodec.state_hash(state)==before,"覆盖比较不修改输入状态")
	check(chosen.diagnostics.compute_used<=int(AITurnPlan.effective_budget(cfg.resolved_parameters())*0.85),
		"同覆盖选择仍遵守原行动计算上限")
	finish()

func _test_comparison_levels() -> void:
	var optimistic := {"node":{"state":GameState.new(),"_refined":false},"score":10.0}
	var checked := {"node":{"state":GameState.new(),"_refined":true},"score":-2.0}
	var better_checked := {"node":{"state":GameState.new(),"_refined":true},"score":-1.0}
	var ranked := [optimistic,checked,better_checked]
	AITurnPlan._sort_current_candidates(ranked,"ai",{"formation_mode":0})
	check(ranked[0]==better_checked,"完整宽回应层内仍选择最高分，而非乐观基础分")
	var finalists := AITurnPlan._comparable_current_candidates(ranked,"ai")
	check(finalists.size()==2 and not finalists.has(optimistic),"未来候选池也排除未完成同等检查的方案")
	var other_basic := {"node":{"state":GameState.new(),"_refined":false},"score":5.0}
	ranked=[other_basic,optimistic]
	AITurnPlan._sort_current_candidates(ranked,"ai",{"formation_mode":0})
	check(ranked[0]==optimistic and AITurnPlan._comparable_current_candidates(ranked,"ai").size()==2,
		"尚无完整宽回应时仍按统一基础分提交可用结果")
	var won := GameState.new();won.winner="ai"
	var victory := {"node":{"state":won,"_refined":false},"score":AIEvaluator.TERMINAL_SCORE}
	ranked=[better_checked,victory]
	AITurnPlan._sort_current_candidates(ranked,"ai",{"formation_mode":0})
	check(ranked[0]==victory,"真实行动已获胜的方案不必等待对手回应")
