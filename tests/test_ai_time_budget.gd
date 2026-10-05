# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# 旧文件入口保留给测试发现器；验证内容已改为确定性计算额度，不测墙钟。
extends "res://tests/harness.gd"
const Work = preload("res://engine/ai_work_budget.gd")
const Stop = preload("res://engine/ai_cancellation.gd")
const Allocation = preload("res://engine/ai_resource_allocation.gd")

func _initialize() -> void:
	CardDB.ensure_loaded()
	_scopes()
	_settings()
	_partial_allocation()
	_session()
	finish()

func _scopes() -> void:
	var total = Work.new(10)
	var child = total.scope(3,"reply_generation",{"stage":4,"candidate":2})
	check(child.spend(2,"allocation") and total.used == 2,"子额度只扣实际完成工作")
	check(not child.spend(2,"allocation") and child.used == 2 and total.used == 2,"失败扣费不伪造工作量")
	check(child.stopped() and not total.stopped(),"局部额度中断不冻结父账的其他阶段")
	var failure: Dictionary = total.failure_log["events"][0]
	check(failure.scope == "reply_generation" and failure.limit == 3 and failure.used == 2
		and failure.requested == 2 and failure.category == "allocation",
		"失败日志保存子额度、已用量、请求量与失败操作")
	check(failure.location.stage == 4 and failure.location.candidate == 2
		and failure.path[0].remaining == 8,"失败日志定位阶段和候选，显示总额度仍有剩余")
	child.spend(1)
	check(total.failure_log["events"].size() == 1,"同一子额度只记录首次失败")
	check(total.spend(8,"settlement") and total.used == 10 and not total.spend(),"总工作量不超上限")
	check(total.categories.allocation == 2 and total.categories.settlement == 8,"操作类别计入同一总账")
	var p := {"_compute":total,"_work":[123]}
	check(Stop.requested(p) and not AIActions.spend(p) and p._work[0] == 123,"计算额度耗尽中断候选且不伪造节点计数")

func _settings() -> void:
	var previous := 0
	for i in range(101):
		var p := AISearch.from_strength(i/100.0).resolved_parameters()
		var amount := AITurnPlan.effective_budget(p)
		check(amount >= previous and amount <= int(p.compute_budget),"101档实际计算上限非递减且有界")
		previous = amount
	var cfg := AISearch.from_strength(0.5)
	check(not cfg.apply_override("search_fraction",0.9),"不能覆盖由强度推导的计算比例")
	check(cfg.apply_override("search_fraction",cfg.get_knob("search_fraction")),"完整参数快照可以携带相同只读值")
	cfg.apply_override("compute_budget",6000000)
	cfg.apply_override("node_budget",5000000)
	check(AITurnPlan.effective_budget(cfg.resolved_parameters()) > AITurnPlan.effective_budget(AISearch.from_strength(0.5).resolved_parameters()),"提高上限可以突破同档基准算力")
	AISearch.set_override("node_budget",5000000)
	AISearch.set_override("compute_budget",240000)
	AISearch.set_pref_strength(1.0)
	check(AISearch.prefs().get_knob("compute_budget") == 240000,"强度变更保留玩家提高的计算上限")
	check(AISearch.prefs().get_knob("node_budget") == 5000000,"强度变更保留玩家提高的节点上限")
	AISearch.restore_defaults()

func _partial_allocation() -> void:
	var summary := {"cash":10,"users":10,"inventory":{"test":2},
		"cores":[{"kind":"product","recipe_res":"user","recipe_n":1,"output_res":"cash","output_n":2}],
		"mults":{"output_x2":2,"attack_x2":0,"user_fill":0}}
	var total = Work.new(1)
	var p := {"_compute":total}
	var cache := {};var stats := {}
	Allocation.value(summary,[1.0,1.0],true,cache,stats,Stop.checker(p),Work.checker(p,"allocation"))
	check(cache.is_empty() and total.used <= total.limit,"未完成DP不缓存半成品且不越额度")

func _session() -> void:
	var state := GameState.new()
	state.set_seed(27)
	state.new_game()
	var cfg := AISearch.from_strength(1.0)
	cfg.apply_override("compute_budget",100)
	cfg.apply_override("node_budget",5000000)
	var meter := AIPlan.work_session(state,GameState.PLAYER,cfg)
	var before := StateCodec.state_hash(state)
	var result := AIPlan.choose_plan(state,GameState.PLAYER,cfg)
	check(result.diagnostics.search_tasks[0].parameters.node_budget == 5000000,"玩家提高的阶段节点上限直接生效")
	check(result.diagnostics.budget_policy == "resumable_round_robin_v2","决策记录公平预算策略版本")
	check(result.diagnostics.rng == state.rng_snapshot(),"决策记录精确字符串种子及随机数位置")
	check(result.diagnostics.has("budget_failures") and result.diagnostics.has("search_stop_reason"),"中断决策保存失败位置与停止原因")
	check(result.diagnostics.compute_used <= 85 and meter.used <= 100,"行动为实际攻击保留15%且总账有界")
	check(AIEnvironment.replay(AIEnvironment.copy(state),result.intents),"极小计算额度仍返回可执行意图")
	check(StateCodec.state_hash(state) == before,"运行时账本不改变规则状态")
	cfg.apply_override("compute_budget",240000)
	check(AIPlan.work_session(state,GameState.PLAYER,cfg) == meter and meter.limit == 100,"局内调档或重规划不重新领取额度")
	var again := AIPlan.choose_plan(state,GameState.PLAYER,cfg)
	check(meter.used <= 100 and again.diagnostics.compute_limit == 100,"重复搜索沿用原账本")
	state.round_num += 1
	check(AIPlan.work_session(state,GameState.PLAYER,cfg) != meter,"新回合按新设置建立额度")
