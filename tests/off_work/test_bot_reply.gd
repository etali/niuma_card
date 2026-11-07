# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Config = preload("res://engine/off_work_config.gd")
const State = preload("res://engine/off_work_state.gd")
const Planner = preload("res://engine/off_work_bot_planner.gd")
const Reply = preload("res://engine/off_work_bot_reply.gd")

func _initialize() -> void:
	var config := Config.new()
	config.rules.initial.groups = [{"employee":2,"work":50},{"employee":1,"work":50},{"employee":1}]
	var game := State.new(config)
	game.new_game(119)
	game.advance(2.5)
	var ours := []
	for gid in game.groups:
		if game.groups[gid].owner == 0 and not game.group_people(gid).is_empty():
			ours.append(gid)
	var worker: int = game.group_people(ours[2])[0]
	var concentrate := {"kind":"move","ids":[worker],"group":ours[0]}
	var spread := {"kind":"move","ids":[worker],"group":ours[1]}
	var finals := [
		{"kind":"move","action":concentrate,"score":4.2,"reason":"集中派工"},
		{"kind":"move","action":spread,"score":4.0,"reason":"分摊派工"}]
	game.offers.clear()
	var safe := _observe(game)
	check(_refine(game,safe,finals).action == concentrate, "没有可见干扰时保留收益较高的集中派工")
	var strike := game.add_card("strike",1)
	var threatened := _observe(game)
	var before := _snapshot(game)
	var answer := _refine(game,threatened,finals)
	check(answer.depth == 1 and answer.action == spread, "敌方有现成罢工，比较立即罢工后的停产量并转选分散派工")
	check(answer.candidates[0].reply.contains("罢工") and answer.candidates[0].has("base_score"), "保留原评分和具体回应")
	check(_snapshot(game) == before and game.cards[strike].status == "ready", "推演不消耗工具、移动牌或查看下一张商品")
	check(Reply.refine(game,0,config.rules.bot,threatened,finals,Time.get_ticks_usec()).is_empty(), "超时保留前一层所有排名")

	game = State.new(config)
	game.new_game(119)
	game.offers = [{"id":91,"type":"employee","price":5}]
	var buy := {"kind":"buy","offer":91,"card_type":"employee"}
	var choices := [finals[0],{"kind":"buy","action":buy,"score":4.0,"reason":"抢购员工"}]
	var market := _observe(game)
	var contested := _refine(game,market,choices)
	check(contested.action == buy, "对手能买唯一员工并派工时，阻断该回应可超过单看基础收益的派工")
	game.offers.append({"id":92,"type":"employee","price":5})
	check(_refine(game,_observe(game),choices).action == concentrate, "仍有等价雇员时不会虚增抢购收益")
	_mixed_partial_batches()
	finish()

func _mixed_partial_batches() -> void:
	var config := Config.new()
	config.roles.employee.work_seconds = 20
	config.roles.employee.work_capacity = 1
	config.roles.grinder.work_seconds = 2
	config.roles.grinder.work_capacity = 4
	config.rules.initial.groups = [{"grinder":1,"employee":1,"work":5},{"employee":1,"work":3}]
	var game := State.new(config)
	game.new_game(51)
	var ours := []
	for gid in game.groups:
		if game.groups[gid].owner == 0 and not game.group_work(gid).is_empty(): ours.append(gid)
	var source: int = ours[0]
	var target: int = ours[1]
	var worker: int = game.group_people(source).filter(func(id): return game.cards[id].type == "grinder")[0]
	var ctx := _observe(game)
	var changed := {}
	Reply._group_delta(ctx,changed,source,game.cards[worker],-1)
	Reply._group_delta(ctx,changed,target,game.cards[worker],1)
	for gid in changed:
		check(Reply._assign_batch(game,changed[gid],Time.get_ticks_usec()+100000),"两种工时人员重新分配批次")
	game.move_cards([worker],target)
	for gid in changed:
		var assigned := 0
		for id in game.group_work_participants(gid):
			assigned += game.tasks[id].work_ids.size()
		var actual: float = game.group_work_rate(gid)*assigned
		check(changed[gid].capacity == assigned and is_equal_approx(actual,changed[gid].rate),
			"派出和接收组按实际分配份数 × 参与者平均速度，匹配真实结算")
	check(changed[target].capacity == 3 and is_equal_approx(changed[target].rate,0.825),
		"卷王最多四份，本组只分到剩下两份，工作组时钟按 20 和 2 秒工时平均")

func _observe(game: RefCounted) -> Dictionary:
	var planner := Planner.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	planner.choose(game,0,game.config.rules.bot,rng,Time.get_ticks_usec()+100000)
	return planner.forecast_context()

func _refine(game: RefCounted, context: Dictionary, rows: Array) -> Dictionary:
	return Reply.refine(game,0,game.config.rules.bot,context,rows,Time.get_ticks_usec()+100000)

func _snapshot(game: RefCounted) -> String:
	return JSON.stringify([game.revision,game.time,game.cards,game.groups,game.tasks,game.offers,game._rng.state])
