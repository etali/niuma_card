# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Live = preload("res://engine/off_work_bot_live.gd")
const Preferences = preload("res://engine/off_work_bot_preferences.gd")
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Emergency = preload("res://engine/off_work_bot_emergency.gd")

class ObservedBot extends OffWorkBot:
	var submitted_action := {}
	func commit_action(action: Dictionary, report: Dictionary) -> bool:
		var committed := super.commit_action(action,report)
		if committed:submitted_action=action.duplicate(true)
		return committed

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	_opening_with_overtime()
	_bulk_opening()
	_union_destination()
	_active_overtime_stays()
	_enemy_overtime_stays()
	_plain_dispatch()
	_unavailable_people()
	_no_dispatchable_staff()
	_minimum_budget()
	_cold_scattered_cursor()
	finish()

func _state(groups: Array) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=groups
	# Keep the shipped money, opening market, first-action delay and fallback
	# allowance. Only the work amount differs from the ordinary opening.
	config.rules.bot.merge(Preferences.strength_parameters(0.5,config.rules.bot,config.bot_preferences),true)
	var state := OffWorkState.new(config)
	state.new_game(20261111)
	return state

func _first(state: OffWorkState, kind: String, owner := 1) -> int:
	var ids: Array=state._owner_type(owner,kind)
	return int(ids[0]) if not ids.is_empty() else -1

func _enemy_snapshot(state: OffWorkState, owner: int) -> PackedByteArray:
	var cards := {}
	var groups := {}
	var tasks := {}
	for uid in state.cards:
		if int(state.cards[uid].owner)!=owner:
			cards[uid]=state.cards[uid]
			if state.tasks.has(uid):tasks[uid]=state.tasks[uid]
	for gid in state.groups:
		if int(state.groups[gid].owner)!=owner:groups[gid]=state.groups[gid]
	return var_to_bytes([cards,groups,tasks])

func _tick(state: OffWorkState, label: String, owner := 1) -> ObservedBot:
	var bot := ObservedBot.new(state,owner)
	var driver := Live.new()
	var enemy_before := _enemy_snapshot(state,owner)
	var market_before := var_to_bytes([state.offers,state._rng.state])
	bot.start()
	check(bot.next_action_time()==0.0,label+"从真实start立即到首次行动点")
	driver.tick(bot,0.0)
	var action: Dictionary=bot.submitted_action
	print("OPENING_DISPATCH ",JSON.stringify({"case":label,"action":action,
		"selected_after_us":bot.last_decision.get("selected_after_us",-1),"elapsed_us":bot.last_decision.get("elapsed_us",-1)}))
	check(bot.decision_serial==1 and bot.last_decision.get("applied",false) \
		and bot.last_decision.get("live_fallback",false),label+"首次tick直接提交一次合法现场保底")
	check(state.time==0.0 and bot.next_action_time()==6.0 and driver._task<0 and driver._ready==null,
		label+"不插入额外思考秒数或后台等待，下一槽仍为6秒")
	check(int(bot.last_decision.get("selected_after_us",1500))<int(bot._policy.live_fallback_budget_us),
		label+"发布在原现场保底微秒截止前")
	check(action.get("ids",[]).all(func(uid):return state.cards.has(uid) and int(state.cards[uid].owner)==owner) \
		and (int(action.get("group",-1))<0 or int(state.groups[action.group].owner)==owner),
		label+"提交的人员、工具和目标组都属于BOT")
	check(_enemy_snapshot(state,owner)==enemy_before and var_to_bytes([state.offers,state._rng.state])==market_before,
		label+"不搬动敌人任何牌或读取未来市场")
	driver.close(self)
	return bot

func _opening_with_overtime() -> void:
	for owner in [0,1]:_opening_for_owner(owner)

func _opening_for_owner(owner: int) -> void:
	var state := _state([{"work":800},{"employee":1},{"overtime":1},{"coffee":1}])
	var worker := _first(state,"employee",owner)
	var overtime := _first(state,"overtime",owner)
	var target: int=int(state.cards[_first(state,"work",owner)].group)
	check(state.config.bot_preferences.default_strength==0.5 \
		and OffWorkConfig.decision_budget_ms(state.config.rules.bot)==700 \
		and state.config.rules.bot.live_fallback_budget_us==1500,
		"800工作复现使用默认0.5的700ms/6秒及既有1500us现场保底")
	var generated: Dictionary=Actions.generate(state,owner,state.config.rules.bot,-1)
	check(generated.complete and generated.actions.any(func(action):return _same_move(action,[worker,overtime],target)),
		"正常完整Actions也有员工加班同命令候选，owner=%d"%owner)
	var bot := _tick(state,"已有加班开局 owner=%d"%owner,owner)
	var action: Dictionary=bot.submitted_action
	check(action.kind=="move" and action.ids.size()==2 and action.ids.has(worker) and action.ids.has(overtime) \
		and int(action.group)==target,"首次同一命令同时派入员工和已有闲置加班")
	check(state.tasks.get(worker,{}).get("kind","")=="work" and int(state.cards[overtime].group)==target \
		and is_equal_approx(state.group_work_rate(target),state.config.work_rate("employee",1)),
		"真实工作任务从首槽获得既有加班倍率")

func _same_move(action: Dictionary, ids: Array, target: int) -> bool:
	return action.get("kind","")=="move" and int(action.get("group",-1))==target \
		and action.get("ids",[]).size()==ids.size() and ids.all(func(uid):return action.ids.has(uid))

func _bulk_opening() -> void:
	var state := _state([{"work":800},{"employee":2},{"employee":1},{"overtime":2},{"overtime":1}])
	var people: Array=state._owner_type(1,"employee")
	var tools: Array=state._owner_type(1,"overtime")
	var target: int=int(state.cards[_first(state,"work")].group)
	var bot := _tick(state,"多个闲置人员与加班")
	check(_same_move(bot.submitted_action,people+tools,target),"分散的3名闲置员工和3张加班在同一真实命令部署")
	check(people.all(func(uid):return state.tasks.get(uid,{}).get("kind","")=="work") \
		and is_equal_approx(state.group_work_rate(target),state.config.work_rate("employee",3)),
		"批量部署使用3张加班的共享进度速率，人数不额外倍增进度时钟")
	var work_before := state.work_count(1)
	var cash_before := state.money(1)
	state.advance(1.0/state.config.work_rate("employee",3)+0.000001)
	check(state.work_count(1)==work_before-3 and state.money(1)==cash_before+3*state.config.income_per_work("employee"),
		"真实一轮结算由3名员工完成3份工作并领取对应工资")

func _union_destination() -> void:
	var state := _state([{"work":800,"union":1},{"employee":1},{"overtime":1}])
	var worker := _first(state,"employee")
	var overtime := _first(state,"overtime")
	var original: int=int(state.cards[overtime].group)
	var target: int=int(state.cards[_first(state,"work")].group)
	var bot := _tick(state,"工会目标")
	check(bot.submitted_action.kind=="move" and bot.submitted_action.ids==[worker] \
		and int(state.cards[worker].group)==target,"目标已有工会时仍立即派人，不混入互斥加班")
	check(state.group_has_union(target) and int(state.cards[overtime].group)==original \
		and state._group_type(target,"overtime").is_empty(),"保留工会及原闲置加班，不靠规则排出来修正错误命令")

func _active_overtime_stays() -> void:
	var state := _state([{"work":800},{"employee":1},{"employee":1,"work":20,"overtime":1},{"overtime":1}])
	var target: int=int(state.cards[_first(state,"work")].group)
	var idle: int=int(state._owner_type(1,"employee").filter(func(uid):return not state.tasks.has(uid))[0])
	var overtimes: Array=state._owner_type(1,"overtime")
	var active: int=int(overtimes[0])
	var loose: int=int(overtimes[1])
	var source: int=int(state.cards[active].group)
	var original_rate := state.group_work_rate(source)
	var original_tasks: Dictionary=state.tasks.duplicate(true)
	var bot := _tick(state,"另一组已工作")
	check(bot.submitted_action.kind=="move" and bot.submitted_action.ids.has(idle) \
		and bot.submitted_action.ids.has(loose) and not bot.submitted_action.ids.has(active) \
		and int(state.cards[idle].group)==target,"只合并闲置加班，不从已有生产组合抽走加班")
	var working: int=int(state._group_type(source,"employee")[0])
	check(int(state.cards[active].group)==source and state.tasks[working]==original_tasks[working] \
		and is_equal_approx(state.group_work_rate(source),original_rate),"原生产组人员任务、加班归属和产速都不受影响")

func _enemy_overtime_stays() -> void:
	var state := _state([{"work":800},{"employee":1}])
	var enemy_overtime := state.add_card("overtime",0)
	state._sync_schedule(false)
	var original: int=int(state.cards[enemy_overtime].group)
	var worker := _first(state,"employee")
	var bot := _tick(state,"只有对手有加班")
	check(bot.submitted_action.kind=="move" and bot.submitted_action.ids==[worker] \
		and int(state.cards[enemy_overtime].group)==original,"对手闲置加班不能随己方员工一起搬走")

func _plain_dispatch() -> void:
	var state := _state([{"work":800},{"employee":1}])
	var worker := _first(state,"employee")
	var bot := _tick(state,"没有加班")
	check(bot.submitted_action.kind=="move" and bot.submitted_action.ids==[worker] \
		and state.tasks.get(worker,{}).get("kind","")=="work","无闲置加班时保留单员工立即派工")

func _unavailable_people() -> void:
	var meeting := _state([{"work":800},{"employee":1},{"overtime":1}])
	var paused := _first(meeting,"employee")
	var host := _first(meeting,"employee",0)
	var tool := meeting.add_card("meeting",0,int(meeting.cards[host].group))
	check(meeting.activate(tool,int(meeting.cards[host].group),host) and meeting.is_meeting_target(paused),
		"边界夹具通过真实开会将原员工暂停")
	var replacement := meeting.add_card("employee",1)
	meeting._sync_schedule(false)
	var paused_group: int=int(meeting.cards[paused].group)
	var bot := _tick(meeting,"员工正在被叫去开会")
	check(bot.submitted_action.kind=="move" and bot.submitted_action.ids.has(replacement) \
		and not bot.submitted_action.ids.has(paused) and meeting.is_meeting_target(paused) \
		and int(meeting.cards[paused].group)==paused_group,"只派新闲置人员，不从真实会议抢回参会人员")

	var strike := _state([{"work":800},{"employee":1},{"work":20,"employee":1},{"overtime":1}])
	var working: int=int(strike._owner_type(1,"employee").filter(func(uid):return strike.tasks.has(uid))[0])
	var attacking := strike.add_card("strike",0)
	check(strike.deliver_strike(attacking,int(strike.cards[working].group)) and strike.is_striking(working),
		"边界夹具由真实罢工使原工作员工脱岗")
	var remaining: float=float(strike.cards[working].remaining)
	var blocked_group: int=int(strike.cards[working].group)
	bot=_tick(strike,"员工正在罢工")
	check(bot.submitted_action.kind=="move" and not bot.submitted_action.ids.has(working) \
		and strike.is_striking(working) and int(strike.cards[working].group)==blocked_group \
		and float(strike.cards[working].remaining)==remaining,"罢工人员保持原恢复时钟，不进入批量派工")

func _minimum_budget() -> void:
	var within := 0
	var legal := true
	var timely := true
	var delays := false
	for iteration in 20:
		var state := _state([{"work":800},{"employee":1},{"overtime":1}])
		state.config.rules.bot.live_fallback_budget_us=100
		var bot := ObservedBot.new(state,1)
		var driver := Live.new()
		bot.start()
		driver.tick(bot,0.0)
		var action: Dictionary=bot.submitted_action
		within+=int(int(bot.last_decision.get("elapsed_us",101))<=100)
		timely=timely and int(bot.last_decision.get("selected_after_us",100))<100
		legal=legal and bot.decision_serial==1 and bool(bot.last_decision.get("applied",false)) \
			and action.get("kind","") in ["wait","move"] \
			and action.get("ids",[]).all(func(uid):return state.cards.has(uid) and int(state.cards[uid].owner)==1)
		delays=delays or state.time!=0.0 or bot.next_action_time()!=6.0 or driver._task>=0
		driver.close(self)
	check(timely and legal,"100us低预算只发布截止前已完成的合法等待或派工，不发布半成品/越界UID")
	# As in the existing deadline regression, allow occasional OS descheduling
	# while requiring normal calls to obey the real elapsed-time allowance.
	check(within>=18,"20次100us保底至少18次计算在原时限内结束（实际%d次）"%within)
	check(not delays,"极低预算也不延后首次行动点或偷偷增加下一槽等待")

func _no_dispatchable_staff() -> void:
	var state := _state([{"work":800},{"employee":1},{"overtime":1}])
	var paused := _first(state,"employee")
	var host := _first(state,"employee",0)
	var tool := state.add_card("meeting",0,int(state.cards[host].group))
	check(state.activate(tool,int(state.cards[host].group),host) and state.is_meeting_target(paused),
		"无可派人员负控由真实会议占用唯一员工")
	var overtime := _first(state,"overtime")
	var origin: int=int(state.cards[overtime].group)
	var paused_group: int=int(state.cards[paused].group)
	var target: int=int(state.cards[_first(state,"work")].group)
	var bot := _tick(state,"没有任何可派人员")
	check(not _same_move(bot.submitted_action,[overtime],target) \
		and int(state.cards[overtime].group)==origin and state.group_work_rate(target)==0.0,
		"无人可工作时不把闲置加班单独塞进800工作空堆耗掉行动")
	check(state.is_meeting_target(paused) and int(state.cards[paused].group)==paused_group \
		and not bot.submitted_action.get("ids",[]).has(paused),"无可用人员也不能拆走参会者来补齐组合")

func _cold_scattered_cursor() -> void:
	var state := _state([{"work":800,"employee":1}])
	var first_scattered := state._next_group
	# 4096 inert singleton piles followed by a worker and work: the existing
	# crews remain busy. No generation limit or product setting is changed.
	for index in 4096:state.add_card("coffee",1)
	var worker := state.add_card("employee",1)
	var work := state.add_card("work",1)
	var target: int=int(state.cards[work].group)
	state._invalidate_group_index()
	var original := var_to_bytes([state.cards,state.groups,state.tasks,state.time,state.revision,state._rng.state])
	var context := {"group_cursor":first_scattered}
	var action := {"kind":"wait"}
	var calls := 0
	var in_time := 0
	var progressed := true
	var budget := 1000
	var reserve := ceili(budget*float(state.config.rules.bot.decision_publish_reserve_ratio))
	while calls<128 and action.kind=="wait":
		var previous: int=int(context.group_cursor)
		var started := Time.get_ticks_usec()
		var result: Dictionary=Emergency.choose(state,1,started+budget-reserve,context)
		in_time+=int(Time.get_ticks_usec()-started<=budget)
		calls+=1
		context=result.context
		action=result.action
		if action.kind=="wait":progressed=progressed and int(context.group_cursor)!=previous
	check(calls>1 and progressed and _same_move(action,[worker],target),
		"冷索引4098散组在多次限时扫描中推进游标，最终找到末端真实员工与工作")
	check(in_time>=ceili(calls*0.9),"冷扫描含既有发布预留仍在1ms调用预算内返回（%d/%d）"%[in_time,calls])
	check(state._membership_index.is_empty() and state._indexed_card_count==-1 \
		and original==var_to_bytes([state.cards,state.groups,state.tasks,state.time,state.revision,state._rng.state]),
		"应急扫描不偷偷重建全桌冷索引，不改变牌、时钟或随机流")
	check(Actions.apply_action(state,1,action) and int(state.cards[worker].group)==target \
		and state.tasks.get(worker,{}).get("kind","")=="work","游标最终候选通过真实规则执行并立即开始处理末端工作")
