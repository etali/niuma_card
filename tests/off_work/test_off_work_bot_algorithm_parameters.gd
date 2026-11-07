# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Planner = preload("res://engine/off_work_bot_planner.gd")
const Search = preload("res://engine/off_work_bot_tree.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_material_candidates_execute_configured_batch()
	_candidate_minimum_is_independent_of_diagnostics()
	_probe_limit_and_deadline()
	_forecast_windows_and_ranking()
	_tree_valuation_and_terminal_order()
	_tree_weights_change_real_choice()
	finish()

func _game(initial: Array, cash := 0) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = initial
	config.rules.initial.money = cash
	config.rules.bot.buy_chance = 0.0
	config.rules.bot.tool_priority = []
	config.rules.conveyor.interval_seconds = 1000.0
	var game := OffWorkState.new(config)
	game.new_game(472)
	check(game.last_error.is_empty(), "行为测试局面经真实规则建立")
	return game

func _rank(game: OffWorkState, planner: RefCounted, overrides: Dictionary = {}) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 41
	return planner.choose(game, 0, overrides, rng, Time.get_ticks_usec() + 1000000)

func _material_candidates_execute_configured_batch() -> void:
	for limit in [3, 23]:
		var game := _game([{"employee":1,"work":2},{"work":40}])
		var planner := Planner.new()
		# Partial policies exercise the same default filling used by callers.
		var decision := _rank(game, planner, {"material_batch_limit":limit,"planner_horizon_work_cycles":100.0})
		var action: Dictionary = decision.action
		if not need(action.kind == "move" and action.ids.size() == limit, "补料候选和实选动作使用配置的 %d 张，不再截为16张" % limit): continue
		var target: int = action.group
		var before := game.group_work(target).size()
		check(planner.apply_action(game, 0, action), "配置生成的补料命令可在真实牌局执行")
		check(game.group_work(target).size() == before + limit, "执行后目标组实际增加配置指定的工作牌数")
		check(game.work_count(0) == 42, "修改候选批量不改变卡牌规则和工作总量")

func _candidate_minimum_is_independent_of_diagnostics() -> void:
	var initial: Array = [{"employee":1}]
	for amount in range(1, 11): initial.append({"work":amount})
	var game := _game(initial)
	for minimum in [1, 4, 7]:
		var ranked := _rank(game, Planner.new(),
			{"planner_candidate_minimum":minimum,"search_root_width":1,"search_reply_width":1})
		check(ranked.finalists.size() == minimum, "实际候选保留下限%d独立于诊断展示数量" % minimum)
		check(ranked.diagnostics.candidates.size() == mini(minimum, 4), "保留%d个真实候选时诊断仍最多展示4条" % minimum)
	var standard := _rank(game, Planner.new())
	var explicit_default := _rank(game, Planner.new(), {"planner_candidate_minimum":4})
	check(standard.finalists == explicit_default.finalists and standard.finalists.size() == 4,
		"默认值仍保留原先4个候选及相同排名")
	var wide := _rank(game, Planner.new(), {"planner_candidate_minimum":1,"search_root_width":9,"search_reply_width":1})
	check(wide.finalists.size() == 9 and wide.diagnostics.candidates.size() == 4,
		"较小候选下限不截断显式搜索宽度，日志数量也不截断搜索候选")

func _probe_limit_and_deadline() -> void:
	var game := OffWorkState.new(OffWorkConfig.new())
	for i in 205: game.add_card("work", 0)
	var person := game.add_card("employee", 0)
	for limit in [192, 256]:
		var planner := Planner.new()
		planner.state = game
		planner.owner = 0
		planner.policy = OffWorkConfig.merge_bot_policy(game.config.rules.bot, {"fallback_probe_group_limit":limit})
		planner.deadline = Time.get_ticks_usec() + 1000000
		planner._reset_observations()
		planner._opening_move()
		check(planner.quick_move.is_empty() == (limit == 192), "探测%d组能否找到第206组的人员由配置决定" % limit)
		if limit == 256:
			check(planner.quick_move.ids == [person] and planner.apply_action(game, 0, planner.quick_move), "扩大探测范围找到的派工动作真实可执行")
	var cancelled := Planner.new()
	cancelled.state = game
	cancelled.owner = 0
	cancelled.policy = OffWorkConfig.merge_bot_policy(game.config.rules.bot,
		{"fallback_probe_group_limit":65536,"fallback_probe_min_us":1000,"fallback_probe_budget_ratio":0.9})
	cancelled.deadline = Time.get_ticks_usec() - 1
	cancelled._reset_observations()
	cancelled._opening_move()
	check(cancelled.expired and cancelled.quick_move.is_empty(), "再大的探测范围和最小预算也不能突破总截止")

func _forecast_windows_and_ranking() -> void:
	var game := _game([{"employee":1,"work":2},{"work":40}])
	var short := Planner.new()
	var longer := Planner.new()
	_rank(game, short, {"planner_horizon_work_cycles":1.0,"planner_horizon_action_intervals":0.01})
	_rank(game, longer, {"planner_horizon_work_cycles":5.0,"planner_horizon_action_intervals":0.01})
	check(is_equal_approx(longer.horizon, 5.0 * short.horizon), "规划窗口实际引用员工周期倍数")
	check(longer.best_score > short.best_score, "更长预测窗口实际改变补料动作估值")
	_rank(game, short, {"planner_horizon_work_cycles":0.01,"planner_horizon_action_intervals":1.0})
	_rank(game, longer, {"planner_horizon_work_cycles":0.01,"planner_horizon_action_intervals":5.0})
	check(is_equal_approx(longer.horizon, 5.0 * short.horizon), "行动间隔窗口独立生效，并与工作周期窗口取大值")
	# An unstaffed batch retains partial progress as a meaningful first-ply estimate.
	game = _game([{"employee":1},{"work":40}])
	_rank(game, short, {"planner_horizon_work_cycles":0.01,"planner_horizon_action_intervals":0.01,"planner_partial_progress_weight":0.0})
	_rank(game, longer, {"planner_horizon_work_cycles":0.01,"planner_horizon_action_intervals":0.01,"planner_partial_progress_weight":1.0})
	check(short.best_score == 0.0 and longer.best_score > 0.0, "未完成批次权重改变实际派工排名，不再固定0.1")
	check(short.best.kind == "wait" and longer.best.kind == "move", "估值参数变化会改变等待与派工的实选动作")

func _value(game: OffWorkState, overrides: Dictionary = {}) -> float:
	var search := Search.new()
	search.seat = 0
	search.policy = OffWorkConfig.merge_bot_policy(game.config.rules.bot, overrides)
	search.period = float(search.policy.think_seconds)
	search.deadline = Time.get_ticks_usec() + 1000000
	return search._score(game)

func _tree_valuation_and_terminal_order() -> void:
	var game := OffWorkState.new(OffWorkConfig.new())
	game.add_card("work", 0)
	check(is_equal_approx(_value(game), -1.0) and is_equal_approx(_value(game, {"tree_pending_work_weight":3.0}), -3.0), "搜索剩余工作惩罚引用配置")
	game = OffWorkState.new(OffWorkConfig.new())
	game.add_card("overtime", 0)
	check(is_equal_approx(_value(game, {"tree_tool_value":0.75}), 0.75), "库存工具价值引用配置")
	check(is_equal_approx(_value(game, {"tree_tool_value":2.0,"tree_tool_value_cap":0.5}), 0.5), "库存价值上限引用配置")
	game = OffWorkState.new(OffWorkConfig.new())
	game.add_card("leader", 0)
	check(is_equal_approx(_value(game, {"tree_support_person_value":1.25}), 1.25), "辅助人员估值引用配置")
	game = OffWorkState.new(OffWorkConfig.new())
	game.add_card("money", 0)
	check(is_equal_approx(_value(game, {"tree_cash_log_weight":5.0}), 5.0 * log(2.0)), "资金购买力估值引用配置")
	game = _game([{"employee":1},{"work":40}])
	var person: int = game._owner_type(1, "employee")[0]
	game.cards[person].paused = true
	var narrow := _value(game, {"tree_horizon_work_cycles":0.5})
	var wide := _value(game, {"tree_horizon_work_cycles":5.0})
	check(wide > narrow, "树预测窗口实际改变可用产能相对价值")
	check(_value(game, {"tree_paused_worker_rate_ratio":1.0}) < _value(game, {"tree_paused_worker_rate_ratio":0.0}), "暂停人员估值比例实际改变对手产能价值")
	game = OffWorkState.new(OffWorkConfig.new())
	var group := game.create_group(1)
	for i in 6000: game.add_card("work", 1, group)
	var large_heuristic := _value(game, {"tree_pending_work_weight":100.0})
	check(large_heuristic == Search.WIN * 0.5, "高权重的非终局得分不进入终局分数区间")
	game.winner = 0
	game.time = 100.0
	var victory := _value(game, {"tree_terminal_time_penalty":2.0,"tree_terminal_time_penalty_cap":50.0})
	check(victory == Search.WIN - 50.0 and victory > large_heuristic, "终局时长偏好读取配置，且真实胜利仍优先")
	game.winner = 1
	check(_value(game) < -large_heuristic, "真实失败不能被乐观估值覆盖")
	game.winner = 2
	check(_value(game) == 0.0, "估值调参不改变平局分值")

func _tree_weights_change_real_choice() -> void:
	var game := _game([{"work":20},{"employee":1}], 10)
	game.config.cards.overtime.price = 8
	game.offers = [game._make_offer("overtime")]
	var finalists := [
		{"action":{"kind":"wait"},"score":0.0,"reason":"等待"},
		{"action":{"kind":"buy","offer":game.offers[0].id,"card_type":"overtime"},"score":0.0,"reason":"购牌"}]
	var choices := []
	for weight in [0.0, 4.0]:
		var policy: Dictionary = game.config.rules.bot.merged({"tree_tool_value":weight,"search_max_depth":1,"search_root_width":2}, true)
		var result: Dictionary = Search.new().search(game, 0, policy, finalists, Time.get_ticks_usec() + 2000000, Callable())
		if not need(result.get("search_depth", 0) == 1, "真实树搜索完成同一层双方候选比较"): return
		choices.append(result.action)
	check(choices[0].kind == "wait" and choices[1].kind == "buy", "仅调整树工具价值就改变真实搜索的等待/购牌选择")
	check(Planner.new().apply_action(game, 0, choices[1]) and game._owner_type(0, "overtime").size() == 1 and game.money(0) == 2,
		"搜索选定的配置相关动作通过真实购牌规则执行")
