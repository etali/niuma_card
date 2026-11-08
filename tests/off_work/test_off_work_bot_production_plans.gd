# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Plans = preload("res://engine/off_work_bot_production_plans.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Budget = preload("res://engine/off_work_bot_budget.gd")

func _initialize() -> void:
	_owned_chain()
	_current_quote_and_income()
	_active_progress_and_custom_recipe()
	_interrupted_production()
	_pending_strike_resume()
	_existing_upgrade()
	_no_recipe_and_deadline()
	finish()

func _world(groups: Array, money := 0) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = groups
	config.rules.initial.money = money
	config.rules.bot.think_seconds = 6.0
	config.rules.bot.evaluation_max_seconds = 120.0
	var world := OffWorkState.new(config)
	world.new_game(814)
	world.offers.clear()
	return world

func _snapshot(world: OffWorkState) -> PackedByteArray:
	var fields := {}
	for field in OffWorkState.WORLD_FIELDS: fields[field] = world.get(field)
	return var_to_bytes([fields,world._rng.state,world._events,world.config.rules])

func _plans(world: OffWorkState, clock: Array = [0.0, 0.0]) -> Array:
	var result := []
	var before := _snapshot(world)
	var status: Dictionary = Plans.visit(world,0,world.config.rules.bot,-1,clock,func(plan): result.append(plan))
	check(status.complete, "生产链完整枚举，不使用未完成前瞻")
	check(_snapshot(world) == before, "前瞻不改原世界、规则、事件或随机流")
	return result

func _shortest(rows: Array, predicate: Callable = Callable()) -> Dictionary:
	var found := {}
	for row in rows:
		if predicate.is_valid() and not predicate.call(row): continue
		if found.is_empty() or row.elapsed < found.elapsed: found = row
	return found

func _replay(world: OffWorkState, plan: Dictionary) -> void:
	var actual := world.fork_for_bot(814)
	actual._bot_branch = false
	var previous := -INF
	for command in plan.commands:
		check(float(command.at) >= previous + world.config.rules.bot.think_seconds - 1e-8,
			"生产链每个命令独占一个真实行动机会")
		actual.advance(world.time + float(command.at) - actual.time)
		check(Actions.apply_action(actual,0,command.action), "记录的生产链命令通过正式规则重放")
		previous = float(command.at)
	actual.advance(world.time + float(plan.elapsed) - actual.time)
	check(_same_state(actual.cards,plan.world.cards) and _same_state(actual.groups,plan.world.groups) and _same_state(actual.tasks,plan.world.tasks),
		"真实规则重放与前瞻全部牌、组合和任务一致")
	check(is_equal_approx(actual.time,plan.world.time) and actual.money(0) == plan.world.money(0),
		"真实规则重放与前瞻时钟、资金一致")

func _same_state(a: Variant, b: Variant) -> bool:
	if a is float and b is float: return is_equal_approx(a,b)
	if a is Dictionary and b is Dictionary:
		if a.size()!=b.size(): return false
		for key in a:
			if not b.has(key) or not _same_state(a[key],b[key]): return false
		return true
	if a is Array and b is Array:
		if a.size()!=b.size(): return false
		for index in a.size():
			if not _same_state(a[index],b[index]): return false
		return true
	return a==b

func _owned_chain() -> void:
	var world := _world([{"employee":1,"work":100},{"slack":1}])
	var plan := _shortest(_plans(world))
	if not need(not plan.is_empty(), "已有摸鱼可生成完整生产、升级、返岗链"): return
	check(plan.commands.map(func(c): return c.action.intent) == ["slack","production_upgrade","production_return"],
		"先组队摸鱼，再拿真实咖啡升级，最后返岗")
	check(plan.commands.map(func(c): return float(c.at)) == [0.0,18.0,24.0],
		"14秒首批及5秒升级必须等6秒行动槽，不能在14/23秒免费操作")
	check(plan.world.cards[plan.person].type == "grinder" and plan.world.tasks[plan.person].kind == "work",
		"只在真正成为卷王并返岗后发布计划")
	check(plan.world._owner_type(0,"coffee").is_empty(), "配方使用真实产生的咖啡并消耗一次")
	check(plan.next_actions == [6.0,0.0], "返岗占用己方当前槽，对手到点仍可行动")
	_replay(world,plan)

func _current_quote_and_income() -> void:
	var world := _world([{"employee":1,"work":100}],4)
	world.offers = [{},{},{},{},{},world._make_offer("slack")]
	var quote: int = world.offers[-1].id
	# With six-second commands, the t10 wage arrives before the next t12
	# command, but the original last-slot quote expires at t12.
	check(_plans(world).is_empty(), "到账后才可购买；在下一行动槽已过期的公开报价不能借用")
	world.config.rules.bot.think_seconds = 5.0
	var plan := _shortest(_plans(world))
	if not need(not plan.is_empty(), "t10工资入账且报价未过期时允许真实采购"): return
	check(plan.commands[0].action.kind == "buy" and plan.commands[0].at == 10.0,
		"不会在t0预支未来工资，购买使用t10行动槽")
	check(plan.purchases.keys() == [quote] and plan.purchases[quote].price == 5,
		"记录唯一原公开报价及真实扣款")
	check(plan.commands[1].at == 15.0, "买入和摸鱼组堆占不同动作")
	check(plan.world.offers.all(func(offer): return offer.is_empty() or int(offer.id)<world._next_offer),
		"等待期间随机新供给不能成为确定材料")
	_replay(world,plan)

func _active_progress_and_custom_recipe() -> void:
	var world := _world([{"employee":2,"slack":2},{"work":100}])
	world.config.rules.slack.seconds = 9.0
	world.config.rules.slack.speed_multiplier = 1.5
	world.config.rules.slack.coffee_per_person = 2
	world.config.rules.coffee.seconds = 3.0
	world.config.rules.coffee.upgrades.employee.cost = 3
	world.config.rules.bot.think_seconds = 1.0
	world.advance(3.0)
	var plan := _shortest(_plans(world),func(row): return row.commands[0].action.intent == "production_upgrade")
	if not need(not plan.is_empty(), "正在摸鱼的半批进度可以直接续接"): return
	check(plan.commands[0].at == 3.0 and plan.commands[0].action.ids.size() == 4,
		"真实配置剩余3秒产4杯，只取配方所需3杯")
	check(plan.elapsed == 6.0 and plan.world.cards[plan.person].type == "grinder",
		"自定义生产与升级时长均由状态规则执行")
	check(plan.world._owner_type(0,"coffee").size() == 1,
		"首批4杯用3杯剩1杯，下一批尚未完成不能提前赠送")
	_replay(world,plan)

func _interrupted_production() -> void:
	var world := _world([{"employee":1,"slack":1},{"work":100}])
	world.config.rules.bot.think_seconds = 1.0
	world.config.rules.strike.flight_seconds = 0.0
	world.config.rules.strike.duration_seconds = 3.0
	world.advance(7.0)
	var person: int = world._owner_type(0,"employee")[0]
	var group: int = world.cards[person].group
	var strike := world.add_card("strike",1)
	check(world.activate(strike,group), "夹具在半批摸鱼时罢工")
	# The group has no current personnel after landing. An ordinary legal
	# assembly after recovery must be used; no automatic teleport is granted.
	check(_plans(world).is_empty(), "当前罢工人员不可被当作立即可组堆的摸鱼人手")
	world.advance(3.0)
	var plan := _shortest(_plans(world))
	if not need(not plan.is_empty(), "恢复后可通过真实组堆重新启动生产链"): return
	check(plan.commands[0].action.intent == "slack", "恢复后回到摸鱼要付出组堆动作")
	_replay(world,plan)

func _no_recipe_and_deadline() -> void:
	var world := _world([{"work_emperor":1,"work":100},{"slack":1}])
	check(not Plans.available(world,0) and _plans(world).is_empty(), "只有满级人员时不奖励无消费用途的咖啡")
	world = _world([{"employee":1,"work":100},{"slack":1}])
	var rows := []
	var status: Dictionary = Plans.visit(world,0,world.config.rules.bot,Time.get_ticks_usec()-1,[0.0,0.0],func(plan): rows.append(plan))
	check(not status.complete and rows.is_empty(), "过期预算不发布空想或半成品计划")
	status = Plans.visit(world,0,world.config.rules.bot,-1,[0.0,0.0],func(plan): rows.append(plan),func(): return true)
	check(not status.complete and rows.is_empty(), "取消请求停止真实规则前瞻并保持零发布")
	status = Plans.visit(world,0,world.config.rules.bot,Time.get_ticks_usec()+Budget.fork_cost(world),[0.0,0.0],func(plan): rows.append(plan))
	check(not status.complete and rows.is_empty(), "不足以复制并释放分支时沿用共享预算保护，不启动不可中断复制")
	world = _world([{"employee":1,"work":100}],5)
	world.offers = [world._make_offer("slack")]
	status = Plans.visit(world,0,world.config.rules.bot,-1,[0.0,0.0],func(plan): rows.append(plan),Callable(),
		{"allow_purchase":false,"allow_assembly":false})
	check(status.complete and status.examined==0 and rows.is_empty(), "普通等待候选没有实际生产组时跳过无用分支复制")

func _pending_strike_resume() -> void:
	var world := _world([{"employee":1,"slack":1},{"work":100}])
	world.config.rules.bot.think_seconds = 1.0
	world.config.rules.strike.flight_seconds = 2.0
	world.config.rules.strike.duration_seconds = 3.0
	world.advance(7.0)
	var person: int = world._owner_type(0,"employee")[0]
	var strike := world.add_card("strike",1)
	check(world.activate(strike,int(world.cards[person].group)), "前瞻起点含仍在飞行的真实罢工")
	var plan := _shortest(_plans(world),func(row): return row.commands.any(func(c): return c.action.intent=="production_resume"))
	if not need(not plan.is_empty(), "前瞻处理飞行、罢工、恢复和重新组堆"): return
	check(plan.commands[0].at==5.0 and plan.commands[0].action.intent=="production_resume", "2秒飞行+3秒罢工后才用真实动作归队")
	_replay(world,plan)

func _existing_upgrade() -> void:
	var world := _world([{"employee":1,"slack":1},{"employee":1,"coffee":1},{"work":100}])
	world.config.rules.bot.think_seconds = 1.0
	world.advance(2.0)
	var plan := _shortest(_plans(world),func(row): return row.commands.size()==1 and row.commands[0].action.intent=="production_return")
	if not need(not plan.is_empty(), "已经在喝咖啡的真实任务可续接到返岗"): return
	check(plan.elapsed==3.0 and plan.world.cards[plan.person].type=="grinder", "只等待当前任务剩余3秒，不重新买杯或重启5秒")
	_replay(world,plan)
