# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Bot = preload("res://engine/off_work_bot.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
var fixture: Dictionary

func _initialize() -> void: _run.call_deferred()

func _restore(owner: int) -> OffWorkState:
	var row: Dictionary = fixture.states[owner]
	var bytes := Marshalls.base64_to_raw(row.gzip_base64).decompress(int(row.bytes),FileAccess.COMPRESSION_GZIP)
	var snapshot: Dictionary = bytes_to_var(bytes)
	var world := OffWorkState.new(OffWorkConfig.new(fixture.cards,fixture.bot))
	for key in OffWorkState.WORLD_FIELDS: world.set(key,snapshot[key])
	world._rng.seed=snapshot.rng_seed
	world._rng.state=snapshot.rng_state
	return world

func _run() -> void:
	fixture = JSON.parse_string(FileAccess.get_file_as_string("res://tests/off_work/fixtures/production_stall_1001.json"))
	for owner in 2:
		var world := _restore(owner)
		var bot := Bot.new(world,owner,world.config.rules.bot,1001)
		var action := bot.decide_action()
		var result := bot.last_decision
		print("STALL_ROOT ",JSON.stringify({"owner":owner,"action":action,"covered":result.completed_candidates,
			"total":result.root_candidates,"layer":result.evaluation_layer,"ordinary_us":result.root_ordinary_us,"elapsed_us":result.elapsed_us}))
		check(result.budget_ms==700 and result.root_complete and result.completed_candidates==result.root_candidates,
			"真实t306快照在默认700ms覆盖全部普通候选（座位%d）"%owner)
		check(action.kind!="wait" and bot.commit_action(action,result), "真实停滞快照选择并执行合法非等待动作")
	_future_work_is_not_immune()
	_continuation()
	finish()

func _future_work_is_not_immune() -> void:
	var world := _restore(0)
	var staff: Dictionary = {}
	for action in Actions.generate(world,0,world.config.rules.bot,-1).actions:
		if action.get("intent","")=="assemble_work" and action.get("group",-1)==1 and action.get("ids",[]).size()==8:
			staff=action;break
	if not need(not staff.is_empty(), "原始快照确有8名空闲员工的真实返岗动作"): return
	var values := []
	for action in [{"kind":"wait"},staff]:
		var child := world.fork_for_bot(1001)
		Actions.apply_search_action(child,0,action)
		child.advance_for_search(3.0,-1)
		child.mask_search_market(world._next_offer)
		var evaluator := Evaluation.new()
		values.append({"current":evaluator.evaluate_current(child,0,world.config.rules.bot,-1,[3.0,0.0]),
			"economic":evaluator.evaluate(child,0,world.config.rules.bot,-1,[3.0,0.0],false)})
	check(float(values[1].current.detail.sides[0].eta)<=float(values[0].current.detail.sides[0].eta),
		"相同当前安排模型中实际返岗不劣于等待后假设返岗")
	var attack: Dictionary = values[0].economic.detail.sides[1].get("forecast_attack",{})
	if not need(attack.get("kind","")=="strike", "等待的未来工作队也被纳入对手真实罢工机会"): return
	check(float(values[1].economic.detail.sides[0].eta)<=float(values[0].economic.detail.sides[0].eta),
		"完整经济攻击模型不再给等待授予虚假的罢工免疫")
	var actual := world.fork_for_bot(1001)
	actual.advance(3.0)
	check(not actual.can_strike_group(int(attack.target_group),1), "自动返岗前真实空工作堆不可发起罢工")
	actual.advance(3.0)
	check(Actions.apply_action(actual,0,staff), "用正常规则支付下一己方行动槽并实际组队")
	check(float(attack.use_at)>=3.0, "前瞻罢工发起不能早于真实返岗时隙")
	actual.advance(maxf(0.0,world.time+3.0+float(attack.use_at)-actual.time))
	check(actual.activate(int(attack.tool),int(attack.target_group)), "同一预测攻击在其发起时刻可用真实规则提交")
	actual.advance(float(attack.flight_seconds))
	check(staff.ids.all(func(id): return actual.is_striking(int(id))), "实际落地命中完整8人，未只打首次投影事件中的一人")

func _continuation() -> void:
	var world := _restore(0)
	var before := [world.work_count(0),world.work_count(1)]
	var idle := []
	for person in world.activity_card_ids():
		if world.config.can_work(str(world.cards[person].type)) and not world.tasks.has(person): idle.append(person)
	var bots := [Bot.new(world,0,world.config.rules.bot,1001),Bot.new(world,1,world.config.rules.bot,1001)]
	var returned := false
	world.drain_events()
	for turn in 10:
		if world.winner>=0: break
		for owner in 2:
			if world.winner>=0: break
			var action: Dictionary = bots[owner].decide_action()
			check(bots[owner].commit_action(action,bots[owner].last_decision), "停滞快照的连续对局使用正常BOT及真实提交")
			print("STALL_STEP ",JSON.stringify({"time":world.time,"owner":owner,"intent":action.get("intent",action.kind),
				"work":[world.work_count(0),world.work_count(1)],"coffee":world._owner_type(1,"coffee").size()}))
			returned = returned or idle.any(func(person): return world.tasks.get(person,{}).get("kind","")=="work")
		world.advance(6.0)
		world.drain_events()
	check(world.work_count(0)<before[0] and world.work_count(1)<before[1], "恢复后的60游戏秒双方待办实际下降，不只是把wait换成另一种停滞")
	check(returned, "停滞时空闲的员工在连续真实对局中确实返岗；升级另由无干扰积杯回归验证")
