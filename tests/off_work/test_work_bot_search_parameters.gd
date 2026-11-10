# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Search = preload("res://engine/off_work_bot_search.gd")

class ShortSearch extends Search:
	# Isolate the configured adversarial depth/width from the optional
	# deadline-driven long tree, whose plan length is a different contract.
	func _rank(node: Dictionary, root := false) -> bool:
		if root: growth_reserve_us=0
		return super._rank(node,root)
	func _growth_pass(_root: Dictionary) -> bool:
		return false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_test_config()
	_test_widths_and_depth()
	_test_deadline()
	finish()

func _test_config() -> void:
	var config := OffWorkConfig.new()
	check(config.errors.is_empty(), "默认搜索策略配置通过校验")
	var knobs := {}
	for item in config.bot_preferences.knobs: knobs[item.key] = item
	for key in config.rules.bot:
		if key == "owner" or config.rules.bot[key] is Array or config.rules.bot[key] is Dictionary: continue
		check(knobs.has(key) and not str(knobs[key].get("hint", "")).is_empty(), "%s 有可用的参数说明" % key)
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/off_work_bot.json"))
	for key in OffWorkConfig.BOT_SEARCH_DEFAULTS: document.bot.erase(key)
	document.preferences.knobs = document.preferences.knobs.filter(func(item): return not OffWorkConfig.BOT_SEARCH_DEFAULTS.has(item.key))
	for budget_mode in ["ratio", "fixed", "legacy"]:
		var old := document.duplicate(true)
		# A historical ratio is explicit and must survive current preset tuning.
		old.bot.think_seconds = 2.8
		old.bot.decision_budget_ratio = 0.5
		if budget_mode != "ratio": old.bot.erase("decision_budget_ratio")
		if budget_mode == "fixed": old.bot.decision_budget_ms = 7
		var before := JSON.stringify(old)
		var imported := OffWorkConfig.new(config.balance_document(), old)
		check(imported.errors.is_empty(), "%s 旧策略能够载入" % budget_mode)
		for key in OffWorkConfig.BOT_SEARCH_DEFAULTS:
			check(imported.rules.bot[key] == OffWorkConfig.BOT_SEARCH_DEFAULTS[key], "%s 缺少 %s 时补齐当前搜索范围" % [budget_mode, key])
		check(JSON.stringify(old) == before, "补搜索字段不改写 %s 历史文档" % budget_mode)
		if budget_mode == "ratio":
			check(not imported.rules.bot.has("decision_budget_ms") and OffWorkConfig.decision_budget_ms(imported.rules.bot) == 1400, "旧比例预算保留")
		else:
			check(not imported.rules.bot.has("decision_budget_ratio") and OffWorkConfig.decision_budget_ms(imported.rules.bot) == (7 if budget_mode == "fixed" else 12), "旧固定预算不会被新比例预算覆盖")
	for key in OffWorkConfig.BOT_SEARCH_DEFAULTS:
		for invalid in [0, 17, 1.5, "4", null]:
			var invalid_config := OffWorkConfig.new()
			invalid_config.rules.bot[key] = invalid
			check(not invalid_config.validate(), "%s 拒绝非法值 %s" % [key, invalid])
		for allowed in [1, 16]:
			var valid_config := OffWorkConfig.new()
			valid_config.rules.bot[key] = allowed
			check(valid_config.validate(), "%s 接受边界 %d" % [key, allowed])

func _branching_game() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":1}]
	for count in range(1, 5): config.rules.initial.groups.append({"work":count})
	config.rules.initial.money = 0
	config.cards.work.work_seconds = 60.0
	config.rules.conveyor.interval_seconds = 1000.0
	var game := OffWorkState.new(config)
	game.new_game(719)
	game.offers.clear()
	return game

func _search(game: OffWorkState, deepen := true) -> Dictionary:
	return ShortSearch.new().search(game, 0, game.config.rules.bot, Time.get_ticks_usec() + 3000000,
		Callable(),Callable(),deepen)

func _test_widths_and_depth() -> void:
	var game := _branching_game()
	var policy: Dictionary = game.config.rules.bot
	policy.search_max_depth = 1
	policy.search_root_width = 8
	var wide := _search(game,false)
	policy.search_root_width = 1
	var narrow := _search(game,false)
	check(wide.root_coverage_complete and narrow.root_coverage_complete and wide.root_candidates > 8, "全部合法动作先经过同一真实规则评价")
	check(wide.completed_candidates == narrow.completed_candidates and wide.search_nodes == narrow.search_nodes and wide.action == narrow.action,
		"深搜宽度不裁剪首层候选，也不改变已完整比较的首层选择")
	policy.search_max_depth = 3
	policy.search_reply_width = 1
	var one_reply := _search(game)
	policy.search_reply_width = 4
	var more_replies := _search(game)
	check(one_reply.short_search_depth == 3 and more_replies.short_search_depth == 3 and more_replies.short_search_nodes > one_reply.short_search_nodes,
		"后续宽度确实改变深层展开范围，双方回应仍用同一评价")
	policy.search_reply_width = 1
	policy.search_root_width = 4
	var more_roots := _search(game)
	check(more_roots.short_search_depth==3 and more_roots.short_root_candidates>one_reply.short_root_candidates \
		and more_roots.short_search_nodes>one_reply.short_search_nodes,"根深搜宽度控制进入后续回应树的首步数量")
	policy.search_root_width = 1
	for depth in [1, 3, 5]:
		policy.search_max_depth = depth
		var found := _search(game)
		check(found.short_search_depth == depth and found.principal_variation.size() == depth,
			"完成所配 %d 层且主变化包含每一步" % depth)

func _test_deadline() -> void:
	var game := _branching_game()
	game.config.rules.bot.search_max_depth = 16
	game.config.rules.bot.search_root_width = 16
	game.config.rules.bot.search_reply_width = 16
	var expired := Search.new().search(game, 0, game.config.rules.bot, Time.get_ticks_usec() - 1)
	check(expired.cutoff and expired.search_depth == 0 and expired.search_nodes == 0, "最大深宽设置也不能越过已截止的时间预算")
	var search := Search.new()
	var reference: WeakRef = weakref(search)
	var first_layer := {}
	var publish := func(layer: Dictionary):
		if layer.search_depth != 1: return
		first_layer.merge(layer.duplicate(true), true)
		reference.get_ref().deadline = Time.get_ticks_usec() - 1
	var interrupted := search.search(game, 0, game.config.rules.bot, Time.get_ticks_usec() + 10000000, Callable(), publish)
	check(interrupted.cutoff and interrupted.search_depth == 1 and interrupted.action == first_layer.action and
		interrupted.principal_variation == first_layer.principal_variation, "下一层开始前截止时仍发布完整第一层")
	var bot := OffWorkBot.new(game, 0)
	var action := bot.decide_action(Time.get_ticks_usec() - 1)
	check(action.kind == "wait" and bot.last_decision.search_depth == 0 and bot.last_decision.fallback,
		"真实决策入口也服从外部截止并返回可执行等待")
