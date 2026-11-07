# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Planner = preload("res://engine/off_work_bot_planner.gd")
const Search = preload("res://engine/off_work_bot_tree.gd")

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
		if budget_mode != "ratio": old.bot.erase("decision_budget_ratio")
		if budget_mode == "fixed": old.bot.decision_budget_ms = 7
		var before := JSON.stringify(old)
		var imported := OffWorkConfig.new(config.balance_document(), old)
		check(imported.errors.is_empty(), "%s 旧策略能够载入" % budget_mode)
		for key in OffWorkConfig.BOT_SEARCH_DEFAULTS:
			check(imported.rules.bot[key] == OffWorkConfig.BOT_SEARCH_DEFAULTS[key], "%s 缺少 %s 时沿用旧搜索范围" % [budget_mode, key])
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
	for count in range(1, 9): config.rules.initial.groups.append({"work":count})
	config.rules.initial.money = 0
	config.rules.bot.buy_chance = 0.0
	config.roles.employee.work_seconds = 60.0
	config.rules.conveyor.interval_seconds = 1000.0
	var game := OffWorkState.new(config)
	game.new_game(719)
	return game

func _rank(game: OffWorkState) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 17
	return Planner.new().choose(game, 0, game.config.rules.bot, rng, Time.get_ticks_usec() + 2000000)

func _search(game: OffWorkState) -> Dictionary:
	var ranked := _rank(game)
	return Search.new().search(game, 0, game.config.rules.bot, ranked.finalists, Time.get_ticks_usec() + 2000000, Callable())

func _test_widths_and_depth() -> void:
	var game := _branching_game()
	var policy: Dictionary = game.config.rules.bot
	var default_rank := _rank(game)
	check(default_rank.finalists.size() == 4, "默认行为仍保留原来四个真实候选")
	policy.search_root_width = 8
	policy.search_max_depth = 1
	var ranked := _rank(game)
	check(ranked.finalists.size() == 8 and ranked.diagnostics.candidates.size() == 4, "真实候选拓宽到八个，日志仍只显示四个")
	var wide := _search(game)
	check(wide.search_depth == 1 and wide.search_nodes == 9 and wide.candidates.size() == 9, "首步宽度八实际展开八个派工加一个额外等待")
	policy.search_root_width = 2
	var narrow := _search(game)
	check(narrow.search_nodes == 3 and narrow.candidates.size() == 3, "首步缩至二实际只展开二个派工加等待")
	policy.search_max_depth = 2
	policy.search_reply_width = 1
	var one_reply := _search(game)
	policy.search_reply_width = 6
	check(_rank(game).finalists.size() == 6, "只提高后续宽度也会保留足够真实候选")
	var six_replies := _search(game)
	check(one_reply.search_depth == 2 and six_replies.search_depth == 2 and
		one_reply.search_nodes == 6 and six_replies.search_nodes == 21, "后续宽度一和六确实分别展开六和二十一个节点")
	policy.search_root_width = 1
	policy.search_reply_width = 1
	for depth in [1, 3, 5]:
		policy.search_max_depth = depth
		var bot := OffWorkBot.new(game, 0)
		bot.decide_action()
		check(bot.last_decision.search_depth == depth and bot.last_decision.principal_variation.size() == depth,
			"真实 BOT 入口完成所配 %d 层并可超过旧四层上限" % depth)

func _test_deadline() -> void:
	var game := _branching_game()
	game.config.rules.bot.search_max_depth = 16
	game.config.rules.bot.search_root_width = 16
	game.config.rules.bot.search_reply_width = 16
	var ranked := _rank(game)
	var expired := Search.new().search(game, 0, game.config.rules.bot, ranked.finalists, Time.get_ticks_usec() - 1, Callable())
	check(expired.cutoff and expired.search_depth == 0 and expired.search_nodes == 0, "最大深宽设置也不能越过已截止的时间预算")
	var search := Search.new()
	var reference: WeakRef = weakref(search)
	var first_layer := {}
	var publish := func(layer: Dictionary):
		first_layer.merge(layer.duplicate(true), true)
		reference.get_ref().deadline = Time.get_ticks_usec() - 1
	var interrupted := search.search(game, 0, game.config.rules.bot, ranked.finalists, Time.get_ticks_usec() + 2000000, Callable(), publish)
	check(interrupted.cutoff and interrupted.search_depth == 1 and interrupted.action == first_layer.action and
		interrupted.principal_variation == first_layer.principal_variation, "下一层开始前截止时仍发布完整第一层而不追求配置深度")
	var bot := OffWorkBot.new(game, 0)
	var action := bot.decide_action(Time.get_ticks_usec() - 1)
	check(action.kind == "wait" and bot.last_decision.search_depth == 0 and bot.last_decision.fallback,
		"真实决策入口也优先服从外部截止并返回可执行等待")
