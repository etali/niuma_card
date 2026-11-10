# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Commitment = preload("res://engine/off_work_bot_growth_commitment.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	_recruited_ids_are_rebound()
	_empty_work_pile()
	_unfinished_upgrade_stays_put()
	_invalid_target_and_clock()
	finish()

func _world(coffee := false) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":3,"work":120}]
	config.rules.initial.money = 10 if not coffee else 0
	config.rules.conveyor.pool = {"employee":1}
	config.rules.conveyor.interval_seconds = 1000.0
	config.rules.recruitment.cost_per_employee = 5
	config.rules.recruitment.seconds = 10.0
	config.rules.bot.think_seconds = 6.0
	config.rules.bot.evaluation_max_seconds = 30.0
	var world := OffWorkState.new(config)
	world.new_game(814)
	world.offers.clear()
	if coffee:
		var tool := world.add_card("slack",0)
		var leader := world.add_card("leader",0)
		world.move_cards([leader],int(world.cards[tool].group))
		world.add_card("coffee",0)
	else: world.add_card("boss",0)
	return world

func _prefix(world: OffWorkState, intent: String) -> Dictionary:
	# This module only reads old saved contexts. Build its historical wire
	# format from real legal commands, without invoking an obsolete BOT policy.
	var generated: Dictionary=Actions.generate(world,0,world.config.rules.bot,-1)
	var public_intent := "coffee" if intent=="growth_upgrade" else "recruitment"
	var choices: Array=generated.actions.filter(func(action):return action.get("intent","")==public_intent)
	if not need(not choices.is_empty(),"普通规则提供旧格式夹具所需的真实投资命令"): return {}
	if intent=="growth_recruit": choices.sort_custom(func(a,b):return a.get("ids",[]).size()>b.get("ids",[]).size())
	var action: Dictionary=choices[0].duplicate(true)
	action["growth_intent"]=intent
	var target: int=world.cards[world._owner_type(0,"work")[0]].group
	var trial := world.fork_for_bot(821)
	if not need(Actions.apply_action(trial,0,action),"兼容夹具先真实支付投资而非伪造未来人员"): return {}
	var remaining := 0.0
	for id in trial.tasks:
		if trial.tasks[id].get("kind","") in ["coffee","recruitment"]: remaining=maxf(remaining,float(trial.cards[id].remaining))
	var period := float(world.config.rules.bot.think_seconds)
	var at := maxf(period,ceilf(remaining/period)*period)
	trial.advance(at)
	var staff: Array=[int(action.person)] if intent=="growth_upgrade" else \
		trial._owner_type(0,"employee").filter(func(id):return not world.cards.has(id))
	var returning := {"kind":"move","ids":staff,"group":target,"intent":"staff_batch","growth_intent":"growth_return"}
	if not need(not staff.is_empty() and Actions.apply_action(trial,0,returning),"完成真实招聘或升级后返岗命令合法"): return {}
	return {"action":action,"evaluation":{"sides":[{"production_chain":{"kind":"sustained_growth",
		"owner":0,"complete":true,"commands":[{"at":0.0,"action":action},{"at":at,"action":returning}]}},{}]}}

func _recruited_ids_are_rebound() -> void:
	var world := _world()
	var report := _prefix(world,"growth_recruit")
	if report.is_empty(): return
	check(Commitment.remember(world,0,report.action,report).is_empty(), "尚未实际支付投资时不建立承诺")
	check(Actions.apply_action(world,0,report.action), "首条招聘命令通过正式规则提交")
	var context := Commitment.remember(world,0,report.action,report)
	check(context.size()==3 and context.has("group") and context.has("ready_at") and context.has("observed_at"),
		"持久上下文仅保存目标、就绪时间与观察时间，不保存预测人员UID")
	check(Commitment.resolve(world,0,context,-1).action.kind=="wait", "招聘尚未到返岗时机只等待")
	var predicted: Array = report.evaluation.sides[0].production_chain.commands[1].action.ids
	# Other legitimate creation changes the global identity sequence before the
	# batch settles; planned recruitment UIDs must not be sent to live rules.
	for count in 4: world.add_card("coffee",1)
	world.advance(float(context.ready_at)-world.time)
	var before := _snapshot(world)
	var resolved: Dictionary = Commitment.resolve(world,0,context,-1)
	check(_snapshot(world)==before, "解析承诺只读取局面，不提前移动人员、支付资金或推进时间")
	if not need(resolved.action.kind=="move", "招聘完成后从实际空闲员工重建批量返岗"): return
	check(resolved.action.ids.size()==2 and resolved.action.ids!=predicted,
		"招聘得到的真实UID已变化，仍准确找到两名新员工")
	check(resolved.action.ids.all(func(id): return world.cards[id].owner==0 and world.can_person_work(id) and not world.tasks.has(id)),
		"返岗不移动敌方、原有工作者或其它生产中的人员")
	check(not str(resolved.action.reason).is_empty() and resolved.action.get("growth_intent","")=="growth_continuation",
		"返岗候选有可显示原因和一次性承诺标记")
	check(Actions.apply_action(world,0,resolved.action) and resolved.action.ids.all(func(id): return world.tasks.get(id,{}).get("kind","")=="work"),
		"重绑定后的返岗命令真正让新员工投入工作")
	check(Commitment.resolve(world,0,context,-1).context.is_empty(), "人员已返岗且没有待完投资时承诺自然清空")
	check(Commitment.remember(world,0,{"kind":"wait"},report).is_empty(), "未执行计划的真实投资动作不能续建承诺")

func _unfinished_upgrade_stays_put() -> void:
	var world := _world(true)
	var report := _prefix(world,"growth_upgrade")
	if report.is_empty(): return
	# A slower actual recipe makes the saved expected return time stale. It
	# remains a real paid upgrade, and must never be cancelled by dispatch.
	world.config.rules.coffee.seconds = 18.0
	world.config.rules.coffee.upgrades.employee["seconds"] = 18.0
	check(Actions.apply_action(world,0,report.action), "真实升级按当前18秒配方开始")
	var context := Commitment.remember(world,0,report.action,report)
	if not need(not context.is_empty(), "已支付升级产生返岗承诺"): return
	world.advance(float(context.ready_at)-world.time)
	var person: int = report.action.person
	var resolved: Dictionary = Commitment.resolve(world,0,context,-1)
	check(world.tasks[person].kind=="coffee" and resolved.action.kind=="wait" and not resolved.context.is_empty(),
		"预计时刻已到而实际升级未完时继续等待，不移动或取消该人员")
	world.advance(18.0-world.time)
	resolved = Commitment.resolve(world,0,context,-1)
	check(resolved.action.kind=="move" and resolved.action.ids.has(person), "实际升级结束才允许返岗")

func _empty_work_pile() -> void:
	var world := _world()
	var target: int = world.cards[world._owner_type(0,"employee")[0]].group
	world.move_cards(world._owner_type(0,"employee"),-1)
	check(world.groups[target].function=="" and not world.group_work(target).is_empty(), "移出全部工人后真实工作堆释放功能锁")
	# Record a real paid prefix without inventing the recruited identities.
	var boss: int = world._owner_type(0,"boss")[0]
	var action := {"kind":"move","ids":[boss]+world._owner_type(0,"money"),"group":-1,"person":-1,"intent":"recruitment","growth_intent":"growth_recruit"}
	var trial := world.fork_for_bot(822)
	Actions.apply_action(trial,0,action)
	trial.advance(12.0)
	var staff: Array = trial._owner_type(0,"employee").filter(func(id): return not world.cards.has(id))
	var returning := {"kind":"move","ids":staff,"group":target,"person":-1,"intent":"staff_batch","growth_intent":"growth_return"}
	check(Actions.apply_action(trial,0,returning), "真实招聘产生的员工可合法进入空工作堆")
	var report := {"action":action,"evaluation":{"sides":[{"production_chain":{"kind":"sustained_growth","owner":0,"complete":true,
		"commands":[{"at":0.0,"action":action},{"at":12.0,"action":returning}]}},{}]}}
	Actions.apply_action(world,0,report.action)
	var context := Commitment.remember(world,0,report.action,report)
	if not need(not context.is_empty(), "空工作堆仍能保存已付款招聘的真实返岗承诺"): return
	world.advance(float(context.ready_at)-world.time)
	var resolved: Dictionary = Commitment.resolve(world,0,context,-1)
	check(resolved.action.kind=="move" and int(resolved.action.group)==target and Actions.apply_action(world,0,resolved.action),
		"到期后将真实空闲人员派进同一空工作堆")
	check(world.groups[target].function=="work" and world.group_work_rate(target)>0.0, "新员工进入后功能成为工作并恢复真实生产")

func _invalid_target_and_clock() -> void:
	var world := _world()
	world.advance(2.0)
	var report := _prefix(world,"growth_recruit")
	if report.is_empty(): return
	Actions.apply_action(world,0,report.action)
	var context := Commitment.remember(world,0,report.action,report)
	if not need(not context.is_empty(), "失效用例具有真实招聘承诺"): return
	var timed: Dictionary = Commitment.resolve(world,0,context,Time.get_ticks_usec()-1)
	check(timed.action.kind=="wait" and timed.context==context, "计算预算到期不遗失仍有效承诺")
	var destination := world.create_group(0)
	world.move_cards(world.group_cards(int(context.group)),destination)
	check(Commitment.resolve(world,0,context,-1).context.is_empty(), "原目标组被合法移动清空后不追随猜测的新目标")
	world.new_game(814)
	check(Commitment.resolve(world,0,context,-1).context.is_empty(), "重开局时钟回退清除旧局承诺")
	check(Commitment.resolve(world,0,{},-1).action.kind=="wait", "无承诺始终返回带kind的等待动作")

func _snapshot(world: OffWorkState) -> Dictionary:
	var fields := {}
	for name in OffWorkState.WORLD_FIELDS: fields[name]=world.get(name)
	return {"fields":fields.duplicate(true),"events":world._events.duplicate(true),"rng":world._rng.state}
