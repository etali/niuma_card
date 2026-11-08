# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	for side in [0, 1]:
		_protected_actions(side)
		_ready_defence(side)
		_incoming_defence(side)
		_support_defence(side, "slack")
		_support_defence(side, "transfer")
		_recruiting(side)
	finish()

func _fixture() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":200,"employee":1}]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(8123)
	state.offers.clear()
	return state

func _work_group(state: OffWorkState, side: int) -> int:
	return int(state.cards[state._owner_type(side, "work")[0]].group)

func _actions(state: OffWorkState, side: int) -> Array:
	var snapshot := var_to_bytes([state.cards,state.groups,state.tasks,state._events,state._rng.state])
	var generated := Actions.generate(state,side,state.config.rules.bot,Time.get_ticks_usec()+500000)
	check(generated.complete,"%d号位全部语义候选在时限内完成" % side)
	check(snapshot==var_to_bytes([state.cards,state.groups,state.tasks,state._events,state._rng.state]),"%d号位候选枚举不改变世界或RNG" % side)
	return generated.actions

func _union_action(actions: Array, union: int, group: int) -> Dictionary:
	for action in actions:
		if action.kind=="move" and int(action.get("group",-1))==group and union in action.get("ids",[]): return action
	return {}

func _protected_actions(side: int) -> void:
	var state := _fixture()
	var group := _work_group(state, side)
	var person: int = state._owner_type(side, "employee")[0]
	state.cards[person].type = "work_emperor"
	state.add_card("union", side, group)
	var boss := state.add_card("boss", side, group)
	state._sync_schedule()
	var overtime := state.add_card("overtime", side)
	var enemy_group := _work_group(state, 1-side)
	state.add_card("union", 1-side, enemy_group)
	var strike := state.add_card("strike", side)
	check(state.effective_work_kind("work_emperor",group)=="employee","%d号位工会内皇帝按真实员工产能与工资处理" % side)
	check(not state.can_person_work(boss) and state.group_work_participants(group)==[person],"%d号位工会中老板仍是非工作人员" % side)
	var actions := _actions(state,side)
	for action in actions:
		check(not (action.kind=="activate" and int(action.get("tool",-1))==strike),"%d号位不对工会组生成罢工候选" % side)
		check(not (action.kind=="move" and overtime in action.get("ids",[]) and int(action.get("group",-1))==group),"%d号位不把加班送进工会组" % side)
	var expired := Actions.generate(state,side,{},Time.get_ticks_usec()-1)
	check(expired.actions.size()==1 and expired.actions[0].kind=="wait" and Actions.apply_action(state,side,expired.actions[0]),"%d号位预算耗尽仍有合法等待" % side)
	var before := state.money(side)
	state.advance(float(state.config.roles.employee.work_seconds))
	check(state.money(side)-before==state.config.income_per_work("employee"),"%d号位实际结算仅支付员工工资，不预支皇帝或老板产出" % side)

func _incoming_defence(side: int) -> void:
	var state := _fixture()
	var group := _work_group(state,side)
	for i in 2: state.add_card("employee",side,group)
	state._sync_schedule()
	var union := state.add_card("union",side)
	var strike := state.add_card("strike",1-side)
	check(state.activate(strike,group),"%d号位遭到可见罢工飞行" % side)
	var action := _union_action(_actions(state,side),union,group)
	check(not action.is_empty(),"%d号位被攻击组具有直接工会防守动作" % side)
	if action.is_empty(): return
	check(Actions.apply_action(state,side,action),"%d号位防守动作由真实规则执行" % side)
	state.advance(float(state.config.rules.strike.flight_seconds)+0.01)
	check(state.cards.has(strike) and state.cards[strike].status=="ready","%d号位成功拦截后对方保留罢工牌" % side)
	check(state.group_people(group).all(func(id): return not state.is_striking(id)),"%d号位被保护人员未罢工" % side)

func _ready_defence(side: int) -> void:
	var state := _fixture()
	state.config.rules.conveyor.interval_seconds = 1000.0
	var group := _work_group(state,side)
	for i in 2: state.add_card("employee",side,group)
	state._sync_schedule()
	var union := state.add_card("union",side)
	var strike := state.add_card("strike",1-side)
	var action := _union_action(_actions(state,side),union,group)
	check(not action.is_empty(),"%d号位现成罢工威胁具有预防性工会动作" % side)
	if action.is_empty(): return
	var shielded := state.fork_for_bot(901)
	var exposed := state.fork_for_bot(901)
	check(Actions.apply_action(shielded,side,action) and not shielded.activate(strike,group),"%d号位真实工会阻止尚未发出的罢工" % side)
	check(is_equal_approx(shielded.group_work_rate(group),exposed.group_work_rate(group)),"%d号位纯员工组合的工会不凭空增加基础产速" % side)
	check(exposed.activate(strike,group),"%d号位无保护对照确实遭受罢工" % side)
	var interruption: float = state.config.rules.strike.flight_seconds+state.config.rules.strike.duration_seconds
	exposed.advance(interruption)
	exposed.move_cards(exposed._owner_type(side,"employee"),group)
	exposed.advance(10.0)
	shielded.advance(interruption+10.0)
	var prevented := exposed.work_count(side)-shielded.work_count(side)
	check(prevented>0,"%d号位工会的防护收益对应真实避免的工作损失" % side)

func _support_defence(side: int, activity: String) -> void:
	var state := _fixture()
	var group := state.create_group(side)
	for i in 2: state.add_card("employee",side,group)
	if activity=="transfer":
		for i in 30: state.add_card("work",side,group)
	var tool := state.add_card(activity,side,group)
	check(state.activate(tool,group),"%d号位%s组合正常工作" % [side,activity])
	var union := state.add_card("union",side)
	var strike := state.add_card("strike",1-side)
	check(state.activate(strike,group),"%d号位%s组合可以被罢工攻击" % [side,activity])
	var action := _union_action(_actions(state,side),union,group)
	check(not action.is_empty(),"%d号位%s组合在途攻击具有工会防守动作" % [side,activity])
	if action.is_empty(): return
	check(Actions.apply_action(state,side,action),"%d号位%s防守动作合法" % [side,activity])
	state.advance(float(state.config.rules.strike.flight_seconds)+0.01)
	check(state.cards.has(strike) and state.group_people(group).size()==2,"%d号位%s人员被工会保留" % [side,activity])

func _recruiting(side: int) -> void:
	var state := _fixture()
	var boss := state.add_card("boss",side)
	var count_before := state._owner_type(side,"employee").size()
	var cost: int = state.config.rules.recruitment.cost_per_employee
	state._credit(side,cost*2)
	var action := {}
	for candidate in _actions(state,side):
		if candidate.get("intent")!="recruitment" or candidate.kind!="move" or boss not in candidate.ids: continue
		if candidate.ids.filter(func(id): return state.cards[id].type=="money").size()==cost*2:
			action = candidate
			break
	check(not action.is_empty(),"%d号位有老板与两人完整资金的独立招聘动作" % side)
	if action.is_empty(): return
	check(Actions.apply_action(state,side,action) and state.recruitment.has(boss),"%d号位真实招聘已经启动" % side)
	if not state.recruitment.has(boss): return
	check(state.recruitment[boss].count==2 and state.reserved_money(side)==cost*2,"%d号位批量招聘冻结两人费用" % side)
	state.offers = [state._make_offer("employee")]
	var followup := _actions(state,side)
	check(state.available_money(side)==0 and not followup.any(func(a): return a.kind=="buy"),"%d号位BOT不把招聘预留资金计作可购买现金" % side)
	check(not followup.any(func(a): return a.kind=="move" and a.ids.any(func(id): return state.cards[id].type=="money")),"%d号位不会把已预留招聘资金搬给别的材料任务" % side)
	state.advance(float(state.config.rules.recruitment.seconds)+0.01)
	check(state._owner_type(side,"employee").size()==count_before+2,"%d号位虚拟时间完成招聘并生成员工" % side)
	check(state.reserved_money(side)==0,"%d号位招聘结算释放预留" % side)
