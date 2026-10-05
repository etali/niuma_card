# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _evaluate(state: GameState, intents: Array, kind: String) -> Dictionary:
	var leaf := BOTEnvironment.copy(state)
	check(BOTEnvironment.replay(leaf,intents),"回应覆盖对照方案经真实规则执行")
	var p := BOTTurnPlan._task_parameters(BOTSearch.from_strength(0.76).resolved_parameters(),kind)
	p["_context"] = BOTActions.Context.new()
	p["_resumable"] = true
	return BOTTurnPlan.resolve_current(leaf,"bot",p)

func _initialize() -> void:
	CardDB.ensure_loaded()
	_test_comparison_levels()
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/bot_response_coverage.json"))
	var state := GameState.new()
	StateCodec.restore(state,fixture.state)
	var before := StateCodec.state_hash(state)
	var shallow := _evaluate(state,fixture.unsafe_intents,"evaluation")
	var unsafe := _evaluate(state,fixture.unsafe_intents,"refinement")
	var safe := _evaluate(state,fixture.safe_intents,"refinement")
	check(shallow.complete and unsafe.complete and safe.complete,"三个对照均完成各自规格的回应评价")
	check(float(shallow.score)>float(safe.score) and float(unsafe.score)<float(safe.score),
		"录像夹具重现浅评价乐观、同规格宽回应却判更差的反转")
	_test_real_coverage_priority(state,fixture,unsafe,safe)
	var cfg := BOTSearch.from_strength(0.76)
	var chosen := BOTTurnPlan.choose_plan(state,"bot",cfg)
	check(chosen.diagnostics.selected_refinement_complete,
		"已有完整宽回应方案时，未完成同等检查的候选不能替换它")
	var validated := _evaluate(state,chosen.intents,"refinement")
	check(validated.complete and float(validated.score)>=float(safe.score),
		"最终方案按相同宽回应规格验证，不丢失已完成的安全基线")
	var actual := BOTEnvironment.copy(state)
	check(BOTEnvironment.replay(actual,chosen.intents),"已验证的最终方案可实际执行")
	MatchSimulator.continue_rounds(actual,1,"bot",{"bot":BOTSearch.from_strength(0.76),"player":BOTSearch.from_strength(0.25)})
	check(actual.winner!="player" and actual.resource_count("bot","user")>0,
		"seed1017真实对手续行后，不再选择可避免的当回合用户清零方案")
	check(StateCodec.state_hash(state)==before,"覆盖比较不修改输入状态")
	check(chosen.diagnostics.compute_used<=int(BOTTurnPlan.effective_budget(cfg.resolved_parameters())*0.85),
		"同覆盖选择仍遵守原行动计算上限")
	finish()

func _test_comparison_levels() -> void:
	var optimistic := {"node":{"state":GameState.new(),"_refined":false},"score":10.0}
	var checked := {"node":{"state":GameState.new(),"_refined":true},"score":-2.0}
	var better_checked := {"node":{"state":GameState.new(),"_refined":true},"score":-1.0}
	var ranked := [optimistic,checked,better_checked]
	BOTTurnPlan._sort_current_candidates(ranked,"bot",{"formation_mode":0})
	check(ranked[0]==better_checked,"完整宽回应层内仍选择最高分，而非乐观基础分")
	var finalists := BOTTurnPlan._comparable_current_candidates(ranked,"bot")
	check(finalists.size()==2 and not finalists.has(optimistic),"未来候选池也排除未完成同等检查的方案")
	var other_basic := {"node":{"state":GameState.new(),"_refined":false},"score":5.0}
	ranked=[other_basic,optimistic]
	BOTTurnPlan._sort_current_candidates(ranked,"bot",{"formation_mode":0})
	check(ranked[0]==optimistic and BOTTurnPlan._comparable_current_candidates(ranked,"bot").size()==2,
		"尚无完整宽回应时仍按统一基础分提交可用结果")
	var won := GameState.new();won.winner="bot"
	var victory := {"node":{"state":won,"_refined":false},"score":BOTEvaluator.TERMINAL_SCORE}
	ranked=[better_checked,victory]
	BOTTurnPlan._sort_current_candidates(ranked,"bot",{"formation_mode":0})
	check(ranked[0]==victory,"真实行动已获胜的方案不必等待对手回应")

## 真实回应已推翻乐观初筛时，即使宽复核判为败局，也不能退回不同覆盖的高分。
## 本测试约束比较口径，不承诺有限预算下必须发现某条存活路线。
func _test_real_coverage_priority(state: GameState, fixture: Dictionary, unsafe: Dictionary, safe: Dictionary) -> void:
	var safe_basic := _evaluate(state,fixture.safe_intents,"evaluation")
	check(safe_basic.complete and float(safe_basic.score)>float(unsafe.score),
		"真实局面存在基础分优于已完成不利宽回应结果的候选")
	var safe_leaf := BOTEnvironment.copy(state)
	var unsafe_leaf := BOTEnvironment.copy(state)
	check(BOTEnvironment.replay(safe_leaf,fixture.safe_intents) and BOTEnvironment.replay(unsafe_leaf,fixture.unsafe_intents),
		"覆盖优先级对照候选均可真实执行")
	var basic := {"node":{"state":safe_leaf,"intents":fixture.safe_intents},"score":safe_basic.score}
	var checked_bad := {"node":{"state":unsafe_leaf,"intents":fixture.unsafe_intents,"_refined":true},"score":unsafe.score}
	var ranked := [basic,checked_bad]
	BOTTurnPlan._sort_current_candidates(ranked,"bot",{"formation_mode":0})
	check(ranked[0]==checked_bad,"宽回应结论不因分数不利而被未充分检查的乐观分替换")
	var checked_better := {"node":{"state":safe_leaf,"intents":fixture.safe_intents,"_refined":true},"score":safe.score}
	ranked.append(checked_better)
	BOTTurnPlan._sort_current_candidates(ranked,"bot",{"formation_mode":0})
	check(ranked[0]==checked_better,"同等宽复核完成后，真实较优方案能够替换旧选择")
	var finalists := BOTTurnPlan._comparable_current_candidates(ranked,"bot")
	check(finalists.size()==2 and finalists.has(checked_bad) and finalists.has(checked_better) and not finalists.has(basic),
		"后续前推沿用完成宽复核的比较池，不混入不同覆盖的候选")
