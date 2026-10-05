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
	var low := BOTSearch.from_strength(0.5)
	var high := BOTSearch.from_strength(1.0)
	for cfg in [low,high]:
		cfg.apply_override("compute_budget",12000)
		cfg.work_session = preload("res://engine/bot_work_budget.gd").new(12000)
	var a := BOTTurnPlan.choose_plan(state,GameState.PLAYER,low)
	var b := BOTTurnPlan.choose_plan(state,GameState.PLAYER,high)
	var count := mini(a.diagnostics.search_batches.size(),b.diagnostics.search_batches.size())
	for i in count:
		check(StateCodec.canon(a.diagnostics.search_batches[i]) == StateCodec.canon(b.diagnostics.search_batches[i]),
			"高档的已有批次与低档计算费用、候选和完成层相同")
	high.work_session = preload("res://engine/bot_work_budget.gd").new(12000)
	var again := BOTTurnPlan.choose_plan(state,GameState.PLAYER,high)
	b.diagnostics.erase("elapsed_ms")
	again.diagnostics.erase("elapsed_ms")
	check(StateCodec.canon(b) == StateCodec.canon(again),"重复搜索不受墙钟速度或历史缓存影响")
	check(StateCodec.state_hash(state) == before,"任务搜索不改变规则状态")
	check(BOTEnvironment.replay(BOTEnvironment.copy(state),b.intents),"任务结果可真实执行")
	check(b.diagnostics.generation_nodes+b.diagnostics.current_nodes+b.diagnostics.future_nodes == b.diagnostics.compute_used,
		"所有已完成和中断任务的计算分账守恒")
	_different_budgets(state)
	_future_tasks()
	_resume_stack()
	finish()

func _different_budgets(state: GameState) -> void:
	var low := BOTSearch.from_strength(0.5)
	var high := BOTSearch.from_strength(1.0)
	for cfg in [low,high]: cfg.apply_override("compute_budget",200000)
	var a := BOTTurnPlan.choose_plan(state,GameState.PLAYER,low)
	var b := BOTTurnPlan.choose_plan(state,GameState.PLAYER,high)
	check(b.diagnostics.compute_used > a.diagnostics.compute_used,"实际更大预算推进更多计算")
	check(b.diagnostics.selected_evaluation_complete and b.diagnostics.current_complete > 0,"有限预算先形成基础完整评价，宽搜索不会阻止基础判断提交")
	var prefix: int = a.diagnostics.search_batches.size()-1
	var identical := true
	for i in prefix:
		identical = identical and StateCodec.canon(a.diagnostics.search_batches[i]) == StateCodec.canon(b.diagnostics.search_batches[i])
	check(identical and prefix > 0,"高预算完整包含低预算已有批次，末批截断后接着执行")
	check(a.diagnostics.compute_used <= int(BOTTurnPlan.effective_budget(low.resolved_parameters())*0.85)
		and b.diagnostics.compute_used <= 170000,"不同强度都不透支行动预算")
	var p := BOTSearch.from_strength(0.501).resolved_parameters()
	p.erase("search_fraction")
	var q := low.resolved_parameters();q.compute_budget = p.compute_budget;q.erase("search_fraction")
	check(p == q,"跨过旧阶段位置也只改变计算预算")

func _resume_stack() -> void:
	var ledger = preload("res://engine/bot_work_budget.gd").new(100)
	var tasks: Array = []
	for i in 2:
		var job = preload("res://engine/bot_search_task.gd").new()
		job.start(func(task):
			var iterations := 0
			for n in 20:
				if not task.charge(1,"test",{}): break
				iterations += 1
			return {"iterations":iterations},ledger)
		tasks.append(job)
	for turn in 5:
		for task in tasks:
			task.advance(4)
			check(task.work == (turn+1)*4,"暂停后接原栈执行，每项每轮只领四单位")
	for task in tasks:
		task.stop()
		check(task.result.iterations == 20,"小批次恢复不重算已完成循环")
	check(ledger.used == 40,"两任务实际收费守恒，未用配额不锁定总账")
	var waiting = preload("res://engine/bot_search_task.gd").new()
	waiting.start(func(task):
		for n in 100:
			if not task.charge(1,"test",{}): break
		return {},ledger)
	waiting.advance(4)
	var before: int = ledger.used
	waiting.stop()
	check(ledger.used == before,"取消能回收暂停栈，清理不追加计算")

func _future_tasks() -> void:
	var state := GameState.new()
	state.set_seed(123)
	state.players = {"bot":{"cards":[]},"player":{"cards":[]}}
	state.draw_first = "bot"
	for who in ["bot","player"]:
		for i in 3:
			state.add_card(who,"cash")
			state.add_card(who,"user")
	var cfg := BOTSearch.from_strength(1.0)
	cfg.apply_override("compute_budget",120000)
	for key in ["sales","financing_mode","resale_mode","allocation_mode","formation_mode","tactical_extension","attack_mode","target_trials","rollout_capabilities"]: cfg.apply_override(key,0)
	for key in ["future_rounds","samples","finalists","future_reply_limit","replies","buy_beam","build_beam","plans"]: cfg.apply_override(key,1)
	var result := BOTTurnPlan.choose_plan(state,"bot",cfg)
	check(result.diagnostics.future_complete_layers == 1 and result.diagnostics.future_depth == 1,"独立未来回应任务全部完成后提交共同层")
	check(result.diagnostics.search_tasks.any(func(x):return x.kind == "future_response" and x.complete),"未来回应也通过可暂停任务调度")
	check(result.diagnostics.generation_nodes+result.diagnostics.current_nodes+result.diagnostics.future_nodes == result.diagnostics.compute_used,"未来任务分账与总账一致")
	check(BOTEnvironment.replay(BOTEnvironment.copy(state),result.intents),"未来任务选中的完整方案可执行")
