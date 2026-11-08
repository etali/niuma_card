# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Search = preload("res://engine/off_work_bot_search.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	_test_visible_reply()
	_mixed_partial_batches()
	finish()

func _test_visible_reply() -> void:
	var config := OffWorkConfig.new()
	# Fix this two-ply attack/recovery window independently of preset tuning.
	config.rules.bot.think_seconds = 2.8
	config.rules.initial.groups = [{"employee":3,"work":120},{"employee":1,"work":30}]
	config.rules.initial.money = 0
	config.rules.conveyor.interval_seconds = 1000
	config.rules.bot.search_max_depth = 2
	config.rules.bot.search_root_width = 16
	config.rules.bot.search_reply_width = 4
	var world := OffWorkState.new(config)
	world.new_game(119)
	world.offers.clear()
	var safe := Search.new().search(world, 0, config.rules.bot, Time.get_ticks_usec()+10000000)
	check(safe.root_complete and safe.search_depth == 2, "安全局面完整比较所有首步与真实对方回应")
	var strike := world.add_card("strike",1)
	var before := _snapshot(world)
	var threatened := Search.new().search(world, 0, config.rules.bot, Time.get_ticks_usec()+10000000)
	check(threatened.root_complete and threatened.search_depth == 2, "持有罢工后的对方回应也完成同层比较")
	check(threatened.action != safe.action, "公开罢工改变真实根动作，非旧启发式分数覆盖")
	var line: Array = threatened.principal_variation
	check(line.size() == 2 and line[1].kind == "activate" and line[1].get("tool") == strike,
		"最佳防御仍以对方实际罢工回应为依据")
	var waiting: Array = threatened.candidates.filter(func(row): return row.kind == "wait")
	check(not waiting.is_empty() and threatened.candidates[0].score > waiting[0].score,
		"选择的防御在同一完工时间尺度上优于原地等待")
	var branch := world.fork_for_bot(71)
	for i in line.size():
		check(line[i].seat == i and is_equal_approx(line[i].seconds, branch.time), "双方回应按实际推演时刻交替")
		check(Actions.apply_action(branch,i,line[i]), "回应主变化每一步均能由真实规则执行")
		branch.advance(config.rules.bot.think_seconds * 0.5)
	check(_snapshot(world) == before and world.cards[strike].status == "ready", "搜索不消费真人局面中的工具或未来随机流")

func _mixed_partial_batches() -> void:
	var config := OffWorkConfig.new()
	config.roles.employee.work_seconds = 20
	config.roles.employee.work_capacity = 1
	config.roles.grinder.work_seconds = 2
	config.roles.grinder.work_capacity = 4
	config.rules.initial.groups = [{"grinder":1,"employee":1,"work":5},{"employee":1,"work":3}]
	config.rules.initial.money = 0
	var world := OffWorkState.new(config)
	world.new_game(51)
	world.offers.clear()
	var groups: Array = world.groups.keys().filter(func(gid): return world.groups[gid].owner == 0 and not world.group_work(gid).is_empty())
	var person: int = world._owner_type(0,"grinder")[0]
	check(world.move_cards([person],int(groups[1])) >= 0, "混合工时人员真正重派到较小工作批次")
	var expected := 0.0
	for gid in groups:
		var assigned := 0
		for id in world.group_work_participants(gid): assigned += world.tasks[id].work_ids.size()
		expected += world.group_work_rate(gid) * assigned
	var forecast := Evaluation.new().evaluate(world,0,config.rules.bot)
	check(forecast.complete and is_equal_approx(forecast.detail.sides[0].current_rate, expected),
		"统一评价按实际分配份数和参与者平均速度计算吞吐，不按名义总容量计分")
	check(is_equal_approx(world.group_work_rate(groups[1])*3,0.825), "卷王仅获余下两份，组时钟匹配 20 与 2 秒的真实规则")

func _snapshot(world: OffWorkState) -> String:
	return JSON.stringify([world.revision,world.time,world.cards,world.groups,world.tasks,world.offers,world._rng.state])
