# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Bot = preload("res://engine/off_work_bot.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	_run.call_deferred()

func _fixture(kind: String) -> OffWorkState:
	var config := OffWorkConfig.new()
	# Large queues reproduce the real long-game case. A tiny 40-work fixture
	# already reaches depth 3 with the old BOT and therefore misses this bug.
	config.rules.initial.groups = [{"work":1000,"employee":2}]
	config.rules.initial.money = 1
	config.rules.conveyor.interval_seconds = 1000.0
	config.rules.conveyor.pool = {kind:1}
	config.cards[kind].price = 1
	config.cards.employee.refund = 0
	config.cards.leader.refund = 0
	config.rules.transfer.seconds = 1.0
	config.roles.leader.transfer_capacity = 3
	var world := OffWorkState.new(config)
	world.new_game(17)
	check(config.errors.is_empty() and world.work_count(0)==1000,"购买续接夹具由合法卡表建立完整1000工作对局")
	world.offers = [world._make_offer(kind)]
	return world

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var fields := []
	for key in OffWorkState.WORLD_FIELDS: fields.append(world.get(key))
	fields.append(world._rng.state)
	return var_to_bytes(fields)

func _decide(bot: OffWorkBot, label: String) -> Dictionary:
	var before := _snapshot(bot.state)
	var policy := var_to_bytes(bot._policy)
	check(OffWorkConfig.decision_budget_ms(bot._policy)==700 and is_equal_approx(bot._policy.think_seconds,6.0),
		label+"使用未改动的默认700ms预算及6秒行动周期")
	var action := bot.decide_action()
	check(before==_snapshot(bot.state),label+"购买续接前瞻不改变真实世界或RNG")
	check(policy==var_to_bytes(bot._policy),label+"前瞻不重写BOT策略参数")
	check(int(bot.last_decision.get("selected_after_us",700000))<700000,label+"选择在真实预算内发布")
	var shown := action.duplicate()
	if shown.has("ids"):
		shown["card_count"]=shown.ids.size()
		shown.erase("ids")
	print("PURCHASE_CONTINUATION ",JSON.stringify({"case":label,"action":shown,
		"depth":bot.last_decision.get("search_depth"),"layer":bot.last_decision.get("evaluation_layer"),
		"root_complete":bot.last_decision.get("root_complete"),"elapsed_us":bot.last_decision.get("elapsed_us")}))
	return action

func _is_buy(action: Dictionary, kind: String) -> bool:
	return action.kind=="buy" and action.get("card_type","")==kind

func _transfer_purchase() -> void:
	var world := _fixture("transfer")
	world.add_card("leader",0)
	var untreated := world.fork_for_bot(17)
	var bot := Bot.new(world,0)
	var action := _decide(bot,"有利甩锅")
	if not need(_is_buy(action,"transfer"),"1000工作时BOT识别购买后组装的甩锅收益并买入"): return
	check(bot.commit_action(action,bot.last_decision) and world.money(0)==0,
		"真实购买支付1元，不能凭空先获得工具效果")
	var tool: int = world._owner_type(0,"transfer")[0]
	check(world.tasks.is_empty() or world.groups[world.cards[tool].group].get("function","")!="transfer",
		"买入本身没有免费完成甩锅组装")
	world.advance(6.0)
	world.offers.clear()
	action = _decide(bot,"已购甩锅续接")
	if not need(action.kind=="move" and tool in action.get("ids",[]) and action.get("intent","")=="transfer",
		"下一己方行动槽由BOT实际组装买来的甩锅"): return
	check(bot.commit_action(action,bot.last_decision),"甩锅组装通过共用真实动作执行器")
	var gid: int = world.cards[tool].group
	check(world.groups[gid].get("function","")=="transfer","组装确实形成正在运行的甩锅组合")
	world.advance(100.0)
	untreated.advance(106.0)
	check(world.work_count(0)<untreated.work_count(0) and world.work_count(1)>untreated.work_count(1),
		"有利收益来自真实转移工作，既减少己方也增加对方待办")

func _union_world(flight: float, pending := true) -> OffWorkState:
	var world := _fixture("union")
	world.config.rules.strike.flight_seconds = flight
	world.config.rules.strike.duration_seconds = 90.0
	var strike := world.add_card("strike",1)
	if pending:
		var group: int = world.cards[world._owner_type(0,"employee")[0]].group
		check(world.activate(strike,group),"工会回归以真实可见罢工威胁开始")
	return world

func _union_purchase() -> void:
	# This explicit rule fixture permits a purchase at t=0 and assembly at t=6
	# before the real strike lands at t=12. It changes no installed card table.
	var world := _union_world(12.0)
	var untreated := world.fork_for_bot(17)
	var workers: Array = world._owner_type(0,"employee")
	var group: int = world.cards[workers[0]].group
	var bot := Bot.new(world,0)
	var action := _decide(bot,"及时工会防守")
	if not need(_is_buy(action,"union"),"1000工作时BOT愿购买能够及时组装并阻止在途罢工的工会"): return
	check(bot.commit_action(action,bot.last_decision) and world.money(0)==0,"工会支付实际1元")
	var tool: int = world._owner_type(0,"union")[0]
	check(int(world.cards[tool].group)!=group,"买入工会尚未保护目标组")
	world.advance(6.0)
	world.offers.clear()
	action = _decide(bot,"已购工会续接")
	if not need(action.kind=="move" and tool in action.get("ids",[]) and action.get("group",-1)==group,
		"下一己方行动槽由BOT实际把工会放入受威胁组"): return
	check(bot.commit_action(action,bot.last_decision),"工会保护通过真实规则提交")
	world.advance(6.1)
	untreated.advance(12.1)
	check(workers.all(func(id): return not world.is_striking(id) and int(world.cards[id].group)==group),
		"真实落地时工会留住全部工作人员")
	check(workers.all(func(id): return untreated.is_striking(id)),"未购买对照确实承受罢工，防护收益不是空断言")

func _negative_controls() -> void:
	var slow := _fixture("transfer")
	slow.add_card("leader",0)
	slow.config.rules.transfer.seconds = 10000.0
	check(not _is_buy(_decide(Bot.new(slow,0),"低效甩锅"),"transfer"),
		"周期远长于对局的甩锅不能因新增前瞻得到固定购买奖励")
	var no_staff := _fixture("transfer")
	check(no_staff.dismiss_people(no_staff._owner_type(0,"employee"),0)
		and no_staff.dismiss_people(no_staff._owner_type(1,"employee"),1)
		and no_staff.people_count(0)==0 and no_staff.people_count(1)==0
		and no_staff.work_count(0)==1000 and no_staff.work_count(1)==1000 and no_staff.winner<0,
		"双方无人员负例通过真实开除形成，排除抢购阻止对手使用甩锅的合法副收益")
	check(not _is_buy(_decide(Bot.new(no_staff,0),"无人员甩锅"),"transfer"),
		"双方都无真实可用人员时，买甩锅既不能组装也不能靠抢购获益")
	var peaceful := _fixture("union")
	check(not _is_buy(_decide(Bot.new(peaceful,0),"无威胁工会"),"union"),
		"没有罢工威胁时不为工会附加固定资产分")
	var too_late := _union_world(1.2)
	check(not _is_buy(_decide(Bot.new(too_late,0),"来不及的工会"),"union"),
		"1.2秒落地早于6秒组装时机，不能预支买入后的防护")
	var ready_enemy := _union_world(1.2,false)
	check(not _is_buy(_decide(Bot.new(ready_enemy,0),"对手抢先罢工"),"union"),
		"对方可在t3发出并于t4.2落地，不得假设它等到t6工会装好")

func _run() -> void:
	_transfer_purchase()
	_union_purchase()
	_negative_controls()
	finish()
