# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const SearchStop = preload("res://engine/ai_cancellation.gd")
const Allocation = preload("res://engine/ai_resource_allocation.gd")
func _initialize() -> void:
	CardDB.ensure_loaded()
	var fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_time_budget.json"))
	for strength in [0.5,1.0]:
		var state := GameState.new()
		StateCodec.restore(state,fixture.state)
		var before := StateCodec.state_hash(state)
		var cfg := AISearch.from_strength(strength)
		check(cfg.get_knob("think_time_ms") == 5000,"各强度共用默认5秒时限")
		cfg.apply_override("think_time_ms",100)
		var started := Time.get_ticks_msec()
		var result := AITurnPlan.choose_plan(state,fixture.seat,cfg)
		var elapsed := Time.get_ticks_msec()-started
		check(elapsed < 500,"复杂录像局面超时及时返回：%d毫秒"%elapsed)
		check(before == StateCodec.state_hash(state),"超时不改变真实输入")
		check(AIEnvironment.replay(AIEnvironment.copy(state),result.intents),"超时返回完整合法意图")
		check(not result.diagnostics.profile.has("_deadline_usec"),"诊断不保存运行时截止时间")
		check(not result.diagnostics.selected_evaluation_complete or result.diagnostics.score != null,"只有完成评价才报告确定分数")
	var p := {"_work":[123],"_deadline_usec":Time.get_ticks_usec()-1}
	check(SearchStop.requested(p) and not AIActions.spend(p),"截止时间中断展开")
	check(p._work[0] == 123,"时间耗尽不伪造节点额度耗尽")
	var cache := {};var stats := {}
	Allocation.value({"cash":1,"users":1},[1,1],true,cache,stats,SearchStop.checker(p))
	check(cache.is_empty(),"超时不缓存未完成资源分配")
	var fixture2 = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/ai_search_quality.json"))
	var state := GameState.new();StateCodec.restore(state,fixture2.state)
	var resolved := AITurnPlan.resolve_current(state,"ai",p)
	check(not resolved.complete and resolved.score == null,"过期的对手回应不成为完整安全评价")
	finish()
