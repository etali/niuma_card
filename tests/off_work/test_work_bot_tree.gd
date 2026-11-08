# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Actions = preload("res://engine/off_work_bot_actions.gd")
const Search = preload("res://engine/off_work_bot_search.gd")

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_test_finish_in_three_plies()
	_test_completed_depth()
	_test_hidden_market()
	print("WORK_BOT_TREE %s (%d checks)" % ["PASS" if failures == 0 else "FAIL", checks])
	quit(1 if failures else 0)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func _race(conveyor_seconds := 40.0) -> OffWorkState:
	var config := OffWorkConfig.new()
	# Three-second work must span three plies in this fixed search-clock case.
	config.rules.bot.think_seconds = 2.8
	config.rules.bot.decision_budget_ratio = 0.25
	config.rules.initial.groups = [{"work":1},{"employee":1}]
	config.rules.initial.money = 6
	config.rules.bot.search_root_width = 3
	config.rules.bot.search_reply_width = 2
	config.cards.work.work_seconds = 3.0
	config.rules.conveyor.interval_seconds = conveyor_seconds
	var state := OffWorkState.new(config)
	state.new_game(110)
	return state

func _snapshot(game: OffWorkState) -> String:
	var fields := [game._rng.state, game._events, game.config.rules, game.config.cards, game.config.roles]
	for key in OffWorkState.WORLD_FIELDS: fields.append(game.get(key))
	return JSON.stringify(fields)

func _test_finish_in_three_plies() -> void:
	var game := _race()
	var before := _snapshot(game)
	var bot := OffWorkBot.new(game, 0)
	var action := bot.decide_action(Time.get_ticks_usec() + 5000000)
	var direct: Dictionary = bot.last_decision
	_check(action.kind == "move" and action.get("ids", []) == game._owner_type(0,"employee"), "终局推演优先让已有员工开工")
	_check(direct.search_depth >= 3 and direct.search_nodes > direct.search_depth, "真实决策入口搜索了多步以及多个分支")
	_check(_snapshot(game) == before, "选择动作不会改动正式局面、定时任务、事件或洗牌状态")

	var pv: Array = direct.principal_variation
	_check(pv.size() >= 3 and pv[0].kind == action.kind, "返回的主变化从实选动作开始且包含对方回应和后继行动")
	var replay := game.fork_for_bot(758) # 在这盘结束前没有商品刷新。
	var executor := Actions.new()
	for i in pv.size():
		var step: Dictionary = pv[i]
		_check(step.seat == i % 2 and is_equal_approx(step.seconds, replay.time), "主变化的座位与虚拟时刻按序交替")
		_check(executor.apply_action(replay, step.seat, step), "主变化的每步均为当前局面上的合法动作")
		replay.advance(game.config.rules.bot.think_seconds * 0.5)
	_check(replay.winner == 0 and replay.work_count(0) == 0, "主变化可用真实规则重放，先派工的一方清空最后一张工作")
	_check(_snapshot(game) == before, "在副本上重放不会影响原局")

func _test_completed_depth() -> void:
	var game := _race()
	var config: Dictionary = game.config.rules.bot
	config.search_max_depth = 4
	var first := {}
	# Cancel only after the complete root ranking, inside different reply branches.
	for extra in [1, 2]:
		var search := Search.new()
		var observer: WeakRef = weakref(search)
		var root_done := {"nodes": -1}
		var published := func(layer: Dictionary):
			if layer.search_depth == 1: root_done.nodes = observer.get_ref().nodes
		var interrupt := func(): return root_done.nodes >= 0 and observer.get_ref().nodes >= root_done.nodes + extra
		var result := search.search(game, 0, config, Time.get_ticks_usec() + 5000000, interrupt, published)
		_check(result.cutoff and result.search_depth == 1 and result.search_nodes > root_done.nodes,
			"下一层已展开，但截止时只发布上一完整层")
		if first.is_empty(): first = result
		else:
			_check(result.candidates == first.candidates and result.action == first.action and
				result.principal_variation == first.principal_variation, "第二层不同位置截断仍发布同一组完整排名和主变化")

func _test_hidden_market() -> void:
	var game := _race(0.5)
	var first := {}
	for seed_value in [4321,8765]:
		# 两局公开信息完全相同，只改变玩家看不到的未来市场 RNG。
		game._rng.seed = seed_value
		var before := _snapshot(game)
		var bot := OffWorkBot.new(game, 0)
		var action := bot.decide_action(Time.get_ticks_usec() + 5000000)
		var log: Dictionary = bot.last_decision
		_check(log.search_depth >= 3 and log.principal_variation.back().seconds >= game.config.rules.conveyor.interval_seconds,
			"搜索的主变化跨过了商品补给")
		_check(_snapshot(game) == before, "在未来补给处分支也不会碰真实市场或真实事件")
		var observed := {"action":action, "line":log.principal_variation, "ranking":log.candidates}
		if first.is_empty(): first = observed
		else: _check(observed == first, "改变私有市场随机状态不会泄漏到动作、排名或主变化")
