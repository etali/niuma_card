# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Cancellation = preload("res://engine/ai_cancellation.gd")
func _initialize() -> void:
	await _long_once()
	await _cancel()
	await _flush()
	_search()
	await _actual_running()
	_allocation_cancel()
	finish()
func _long_once() -> void:
	var t := AIThink.new()
	var calls := [0]
	var scale := Engine.time_scale
	Engine.time_scale = 4000
	var frames := Engine.get_process_frames()
	var result = await t.run(func():
		calls[0] += 1
		OS.delay_msec(250)
		return OS.get_thread_caller_id()
	,self)
	Engine.time_scale = scale
	check(calls[0] == 1,"长思考只计算一次")
	check(result != OS.get_main_thread_id(),"长思考仍在后台")
	check(Engine.get_process_frames()-frames >= 3,"越过旧超时值仍刷新画面")
	check(not t.busy(),"正常完成收回线程")
func _cancel() -> void:
	var t := AIThink.new()
	var frames := Engine.get_process_frames()
	var start := Time.get_ticks_msec()
	var result = await t.run(func(probe: Callable = Callable()):
		while not Cancellation.probe_requested(probe): OS.delay_msec(1)
		return {"stale":true}
	,self,func():return Engine.get_process_frames()-frames >= 3)
	check(result == {},"取消后丢弃旧结果")
	check(Time.get_ticks_msec()-start < 1000,"运行中任务能及时取消")
	check(not t.busy(),"取消后收回线程")
func _flush() -> void:
	var t := AIThink.new()
	var results := []
	_collect(t,results)
	await process_frame
	var start := Time.get_ticks_msec()
	t.flush()
	await process_frame
	check(Time.get_ticks_msec()-start < 1000,"flush请求停止")
	check(results == [{}],"flush后旧结果不落地")
	check(not t.busy(),"flush后线程已收回")
	t.flush()
func _collect(t: AIThink, results: Array) -> void:
	results.append(await t.run(func(probe: Callable = Callable()):
		while not Cancellation.probe_requested(probe): OS.delay_msec(1)
		return {"stale":true}
	,self))
func _search() -> void:
	CardDB.ensure_loaded()
	var state := GameState.new()
	state.new_game()
	state.start_round()
	var cfg := AISearch.from_model("ai",0.0)
	cfg.parameters["future_rounds"] = 0
	var normal := AITurnPlan.choose_plan(state,GameState.PLAYER,cfg)
	cfg.cancelled_check = func():return false
	var controlled := AITurnPlan.choose_plan(state,GameState.PLAYER,cfg)
	normal["diagnostics"].erase("elapsed_ms")
	controlled["diagnostics"].erase("elapsed_ms")
	check(StateCodec.canon(normal) == StateCodec.canon(controlled),"未取消时动作评分和节点数完全相同")
	var token := Cancellation.new()
	token.request()
	cfg.cancelled_check = token.is_cancelled
	var start := Time.get_ticks_msec()
	var result := AITurnPlan.choose_plan(state,GameState.PLAYER,cfg)
	check(Time.get_ticks_msec()-start < 1000,"实际AI预取消及时结束")
	check(not result["diagnostics"]["profile"].has("_cancelled"),"运行令牌不写入录像配置")
	var p := {"_work":[123],"_cancelled":token.is_cancelled}
	check(not AIActions.spend(p) and p["_work"][0] == 123,"取消不伪造已消耗节点数")

func _actual_running() -> void:
	var state := GameState.new()
	state.new_game()
	state.start_round()
	var before := StateCodec.canon(StateCodec.snapshot(state))
	var cfg := AISearch.from_model("ai",1.0)
	var think := AIThink.new()
	var frames := Engine.get_process_frames()
	var start := Time.get_ticks_msec()
	var result = await think.run(func(probe: Callable = Callable()):
		cfg.cancelled_check = probe
		return AITurnPlan.choose_plan(state,GameState.PLAYER,cfg)
	,self,func():return Engine.get_process_frames()-frames >= 3)
	check(result == {},"运行中实际搜索取消后不返回计划")
	check(Time.get_ticks_msec()-start < 2000,"运行中实际搜索及时停止")
	check(before == StateCodec.canon(StateCodec.snapshot(state)),"取消搜索不改变输入局面")

func _allocation_cancel() -> void:
	var summary := {"cash":10,"users":10,"inventory":{},"cores":[],"mults":{"output_x2":0,"attack_x2":0,"user_fill":0}}
	var cache := {}
	var stats := {}
	var token := Cancellation.new()
	token.request()
	var allocation = preload("res://engine/ai_resource_allocation.gd")
	allocation.value(summary,[1.0,1.0],true,cache,stats,token.is_cancelled)
	check(cache.is_empty() and stats.is_empty(),"取消的资源分配不缓存半成品")
