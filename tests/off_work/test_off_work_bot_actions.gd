# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Actions = preload("res://engine/off_work_bot_actions.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, reason: String) -> void:
	checks += 1
	if not value: failures.append(reason)

func _state(work_count := 60) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":work_count},{"employee":1}]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(431)
	# Keep a valid opening configuration; each scene installs its own staff.
	for id in state._owner_type(0,"employee") + state._owner_type(1,"employee"): state._consume(id)
	return state

func _add(state: OffWorkState, kind: String, count: int, group := -1, owner := 0) -> Array:
	var ids := []
	if group < 0: group = state.create_group(owner)
	for index in count: ids.append(state.add_card(kind,owner,group))
	return ids

func _work_group(state: OffWorkState, owner := 0) -> int:
	return int(state.cards[state._owner_type(owner,"work")[0]].group)

func _generate(state: OffWorkState, policy := {}) -> Array:
	var before := _snapshot(state)
	var result := Actions.generate(state,0,policy,Time.get_ticks_usec()+2000000)
	check(result.complete,"ordinary scene finishes enumerating all semantic choices")
	check(_snapshot(state)==before,"generation leaves cards, tasks, rules, events, error and RNG unchanged")
	return result.actions

func _snapshot(state: OffWorkState) -> PackedByteArray:
	var values := []
	for key in OffWorkState.WORLD_FIELDS: values.append(state.get(key))
	values.append_array([state._rng.state,state._events,state.last_error,state.config.rules])
	return var_to_bytes(values)

func _find(actions: Array, predicate: Callable) -> Dictionary:
	for action in actions:
		if predicate.call(action): return action
	return {}

func _apply(state: OffWorkState, action: Dictionary, label: String) -> OffWorkState:
	check(not action.is_empty(),label+" is generated")
	var branch := state.fork_for_bot(981)
	if not action.is_empty(): check(Actions.apply_action(branch,0,action),label+" executes through real rules")
	return branch

func _count(state: OffWorkState, action: Dictionary, kind: String) -> int:
	return action.get("ids",[]).filter(func(id): return state.cards[id].type==kind).size()

func _run() -> void:
	_market_without_strategy_caps()
	_bulk_return_after_strike()
	_single_action_production_assembly()
	_overtime_and_group_equivalence()
	_group_assignment_effects()
	_full_coffee_recipe()
	_outsource_full_and_preserved_production()
	_outsource_active_wallet_surplus()
	_independent_tool_functions()
	_union_and_strike()
	_recruitment_and_finance()
	_deadline_and_owner_validation()
	for failure in failures: printerr("FAIL "+failure)
	print("OFF_WORK_BOT_ACTIONS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)

func _market_without_strategy_caps() -> void:
	var state := _state()
	_add(state,"employee",12,_work_group(state))
	_add(state,"overtime",5,_work_group(state))
	_add(state,"money",100)
	state.offers = [state._make_offer("employee"),state._make_offer("overtime"),state._make_offer("coffee"),state._make_offer("boss"),state._make_offer("union")]
	state.advance(0.001)
	var policy := {"desired_people":0,"max_card_copies":{"overtime":0},"max_tool_copies":0,"material_batch_limit":1,"purchase_priority":[],"buy_chance":0.0,"min_reserve":10000}
	var actions := _generate(state,policy)
	for offer in state.offers:
		var action := _find(actions,func(a): return a.kind=="buy" and a.offer==offer.id)
		var after := _apply(state,action,"visible affordable "+offer.type)
		check(after._owner_type(0,offer.type).size()==state._owner_type(0,offer.type).size()+1,"no heuristic ownership cap on "+offer.type)
	_add(state,"boss",1)
	var restricted := _generate(state,policy)
	check(_find(restricted,func(a): return a.kind=="buy" and a.card_type=="boss").is_empty(),"real one-boss rule remains enforced")
	var expensive: Dictionary = state.offers[0]
	expensive.price = 1000
	var unaffordable := _generate(state)
	check(_find(unaffordable,func(a): return a.kind=="buy" and a.offer==expensive.id).is_empty(),"no buying with money that does not exist")

func _bulk_return_after_strike() -> void:
	var state := _state()
	var group := _work_group(state)
	var workers := _add(state,"employee",5,group)
	state.config.rules.strike.flight_seconds = 0.0
	var strike: int = _add(state,"strike",1,-1,1)[0]
	state.advance(0.001)
	check(state.activate(strike,group),"fixture strikes five actual working people")
	var during := _generate(state)
	check(_find(during,func(a): return a.kind=="move" and a.get("ids",[]).any(func(id): return id in workers)).is_empty(),"striking people are not illegally staffed before recovery")
	state.advance(state.config.number("strike","duration_seconds"))
	var actions := _generate(state)
	var batch := _find(actions,func(a): return a.kind=="move" and a.group==group and a.get("ids",[]).size()==5 and workers.all(func(id): return id in a.ids))
	var after := _apply(state,batch,"five-person post-strike return")
	check(workers.all(func(id): return after.tasks.get(id,{}).get("kind")=="work"),"one action restores all five people instead of five think intervals")
	var singles := actions.filter(func(a): return a.kind=="move" and a.group==group and a.ids.size()==1 and a.ids[0] in workers)
	check(singles.size()==1,"equivalent recovered single people use one representative, alongside bulk action")

func _overtime_and_group_equivalence() -> void:
	var state := _state()
	var target := _work_group(state)
	_add(state,"employee",2,target)
	var overtime := _add(state,"overtime",7)
	state.advance(0.001)
	var actions := _generate(state)
	var action := _find(actions,func(a): return a.kind=="move" and a.group==target and a.ids.size()==7 and overtime.all(func(id): return id in a.ids))
	var after := _apply(state,action,"seven overtime cards in one move")
	check(after._group_type(target,"overtime").size()==7,"all seven overtimes remain legal and active")
	check(is_equal_approx(after.group_work_rate(target),pow(1.2,7)/10.0),"real exponential overtime speed survives without four-card ceiling")
	var singles := actions.filter(func(a): return a.kind=="move" and a.group==target and a.ids.size()==1 and a.ids[0] in overtime)
	check(singles.size()==1,"identical loose overtime cards do not fill the action list")

func _group_assignment_effects() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups=[{"employee":1,"grinder":1,"work":5},{"employee":1,"grinder":1,"work":5},{"employee":1,"grinder":1,"work":5}]
	config.rules.initial.money=0
	config.roles.employee.work_capacity=2
	config.roles.grinder.work_capacity=4
	var state := OffWorkState.new(config)
	state.new_game(77)
	state.offers.clear()
	var groups := []
	for gid in state.groups:
		if int(state.groups[gid].owner)==0: groups.append(gid)
	var reversed: Array = state.groups[groups[1]].cards
	var grinder: int = state._group_type(groups[1],"grinder")[0]
	reversed.erase(grinder)
	reversed.push_front(grinder)
	state.advance(0.0)
	var overtime: int = _add(state,"overtime",1)[0]
	var actions := _generate(state)
	var choices: Array = actions.filter(func(action): return action.kind=="move" and action.get("ids",[])==[overtime])
	var targets: Array = choices.map(func(action): return action.group)
	check(targets.size()==2 and targets.has(groups[0]) and targets.has(groups[1]),"different real work allocation orders keep both overtime destinations")
	check(not targets.has(groups[2]),"identical role order and assignment still deduplicate despite different UIDs")
	for index in 2:
		var action := _find(choices,func(choice): return choice.group==groups[index])
		var after := _apply(state,action,"overtime on partial-batch allocation order %d"%index)
		after.advance(1.0/after.group_work_rate(groups[index]))
		check(after.group_work(groups[index]).is_empty(),"the selected group really completes its five-work batch first")
		check(after.money(0)==8+index,"different role order yields its actual eight-versus-nine income rather than a merged estimate")

func _single_action_production_assembly() -> void:
	var state := _state()
	var group := _work_group(state)
	_add(state,"employee",2,group)
	var idle := _add(state,"employee",5)
	var overtime := _add(state,"overtime",3)
	var extra_work := _add(state,"work",12)
	state.advance(0.001)
	var actions := _generate(state)
	var all_ids: Array = idle + overtime + extra_work
	var action := _find(actions,func(a): return a.get("intent")=="assemble_work" and a.group==group and all_ids.all(func(id): return id in a.ids))
	var after := _apply(state,action,"single-action joint personnel/material/overtime assembly")
	check(after.group_work(group).size()==72,"joint assembly brings every loose work card")
	check(after.group_work_participants(group).size()==7,"joint assembly assigns all idle people in the same action")
	check(after._group_type(group,"overtime").size()==3,"joint assembly installs all loose overtime in the same action")
	check(is_equal_approx(after.group_work_rate(group),pow(1.2,3)/10.0),"joint assembly's projected production is physically realizable")

func _full_coffee_recipe() -> void:
	var state := _state()
	var person: int = _add(state,"workaholic",1,_work_group(state))[0]
	_add(state,"employee",1,_work_group(state))
	var cups := _add(state,"coffee",4)
	state.advance(0.001)
	var actions := _generate(state,{"material_batch_limit":1})
	var action := _find(actions,func(a): return a.get("intent")=="coffee" and a.kind=="move" and person in a.ids and cups.all(func(id): return id in a.ids))
	var after := _apply(state,action,"four-cup complete upgrade recipe")
	check(after.tasks.get(person,{}).get("kind")=="coffee","complete coffee recipe starts real upgrade")
	check(after.group_work(int(after.cards[person].group)).is_empty(),"coffee receives an independent group without work")
	after.advance(after.config.coffee_seconds("workaholic"))
	check(after.cards[person].type=="work_emperor","full recipe reaches the configured next rank")

func _outsource_full_and_preserved_production() -> void:
	var state := _state(200)
	var group := _work_group(state)
	_add(state,"employee",10,group)
	_add(state,"money",200)
	var tool: int = _add(state,"outsource",1)[0]
	state.advance(0.001)
	var actions := _generate(state,{"material_batch_limit":16})
	var full := _find(actions,func(a): return a.get("intent")=="outsource" and _count(state,a,"work")==200)
	var after := _apply(state,full,"full 200-work 200-money outsource")
	check(after.outsourcing.get(tool,{}).get("work_ids",[]).size()==200,"real outsource batch exceeds sixteen and covers the finish line")
	var preserve := _find(actions,func(a): return a.get("intent")=="outsource" and _count(state,a,"work")==190)
	var working := _apply(state,preserve,"outsource while preserving the assigned production batch")
	check(working.group_work(group).size()==10 and working.group_work_participants(group).size()==10,"preserve-production representative leaves ten ordinary workers productive")
	check(working.outsourcing.get(tool,{}).get("work_ids",[]).size()==190,"preserve representative still supplies complete payment")
	var before := _snapshot(state)
	Actions.generate(state,0,{},Time.get_ticks_usec()+1000000)
	check(_snapshot(state)==before,"large-material enumeration does not reserve or spend original cards")

func _outsource_active_wallet_surplus() -> void:
	for extra_location in ["none","outside","local"]:
		var state := _state(20)
		var tool: int = _add(state,"outsource",1)[0]
		var group: int = state.cards[tool].group
		_add(state,"work",4,group)
		var wallet: int = _add(state,"money",1,group)[0]
		state.cards[wallet].amount=10
		check(state.activate(tool),"partial-wallet fixture starts a real four-work batch")
		state.advance(3.0)
		var extra := 0 if extra_location=="none" else 3
		if extra>0:
			var cash: int = _add(state,"money",1,group if extra_location=="local" else -1)[0]
			state.cards[cash].amount=extra
		var remaining: float = state.cards[tool].remaining
		var actions := _generate(state)
		var feed := _find(actions,func(action): return action.get("intent")=="outsource_feed" and action.group==group and _count(state,action,"work")==6+extra)
		var after := _apply(state,feed,"active batch can use its wallet balance with "+extra_location+" extra funding")
		check(not feed.get("ids",[]).has(wallet),"reserved wallet remains attached rather than being moved or dismantled")
		check(after.cards[wallet].group==group and after.outsourcing.has(tool),"the original active batch survives replenishment")
		check(after.outsourcing[tool].amount==10+extra,"batch extension uses local surplus exactly once plus any outside payment")
		check(after.outsourcing[tool].payments[wallet]==10,"new work consumes the original wallet's available six without losing its old reservation")
		check(is_equal_approx(after.cards[tool].remaining,remaining),"additional work preserves the original completion deadline")
		if extra_location!="outside": check(_count(state,feed,"money")==0,"local funds need only a work movement, with no duplicate money operation")

func _independent_tool_functions() -> void:
	for kind in ["meeting","transfer","slack"]:
		var state := _state()
		var group := _work_group(state)
		var staff := _add(state,"employee",3,group)
		_add(state,"employee",3,_work_group(state,1),1)
		state.advance(0.001)
		var tool: int = _add(state,kind,1,group)[0]
		state.advance(0.001)
		check(state.groups[group].function=="work","fixture keeps existing work lock with added "+kind)
		var actions := _generate(state)
		var action := _find(actions,func(a): return a.get("intent")==kind and a.kind=="move" and a.group<0 and tool in a.ids and _count(state,a,"employee")==1 and (kind!="transfer" or _count(state,a,"work")==1))
		var after := _apply(state,action,"independent "+kind+" recipe")
		var destination: int = int(after.cards[tool].group)
		check(after.groups[destination].function==kind,"new tool group has exactly "+kind+" function")
		check(after.groups[group].function=="work" and after.group_work_participants(group).size()==2,"original work group retains the other two workers")
		check(staff.any(func(id): return after.tasks.get(id,{}).get("kind")==kind),kind+" starts through public move rules")
		if kind == "slack":
			var bulk := _find(actions,func(a): return a.get("intent")=="slack" and a.kind=="move" and staff.all(func(id): return id in a.ids))
			var bulk_after := _apply(state,bulk,"entire working crew can change to independent coffee production")
			check(staff.all(func(id): return bulk_after.tasks.get(id,{}).get("kind")=="slack"),"tool staffing has a batch alternative for active workers too")

func _union_and_strike() -> void:
	var state := _state()
	var group := _work_group(state)
	_add(state,"employee",3,group)
	_add(state,"overtime",2,group)
	_add(state,"employee",3,_work_group(state,1),1)
	var union: int = _add(state,"union",1)[0]
	var strike: int = _add(state,"strike",1)[0]
	state.advance(0.001)
	var actions := _generate(state)
	var protect := _find(actions,func(a): return a.get("intent")=="union" and a.group==group and union in a.ids)
	var after := _apply(state,protect,"union protection")
	check(after.group_has_union(group) and after._group_type(group,"overtime").is_empty(),"union uses real overtime-ejection tradeoff")
	var attack := _find(actions,func(a): return a.get("intent")=="strike" and a.tool==strike)
	var attacked := _apply(state,attack,"strike attack")
	check(attacked.pending_strikes.has(strike),"strike uses actual flight instead of directly mutating the rival")

func _recruitment_and_finance() -> void:
	var state := _state()
	_add(state,"employee",12,_work_group(state))
	var boss: int = _add(state,"boss",1)[0]
	_add(state,"money",100)
	state.advance(0.001)
	var actions := _generate(state,{"desired_people":1,"material_batch_limit":16})
	var recruit := _find(actions,func(a): return a.get("intent")=="recruitment" and boss in a.ids and _count(state,a,"money")==100)
	var after := _apply(state,recruit,"full-funds twenty-person recruitment")
	check(after.recruitment.get(boss,{}).get("count")==20,"recruitment has no strategy headcount/material cap")
	var poor := _state()
	_add(poor,"employee",5)
	poor.config.rules.fire.minimum_people = 1
	poor.offers = [poor._make_offer("employee")]
	var financing := _generate(poor)
	var sell := _find(financing,func(a): return a.get("intent")=="finance" and a.ids.size()==2)
	var funded := _apply(poor,sell,"two-person financing for the visible four-money offer")
	check(funded.available_money(0)==4 and funded.people_count(0)==3,"fundraising really dismisses two people and credits their refund")

func _deadline_and_owner_validation() -> void:
	var state := _state()
	var before := _snapshot(state)
	var expired := Actions.generate(state,0,{},Time.get_ticks_usec()-1)
	check(not expired.complete and expired.actions.size()==1 and expired.actions[0].kind=="wait","expired generation returns promptly with wait")
	var cancelled := Actions.generate(state,0,{},Time.get_ticks_usec()+1000000,func(): return true)
	check(not cancelled.complete and cancelled.actions.size()==1,"cancellation stops enumeration")
	check(_snapshot(state)==before,"deadline/cancellation leave world and RNG untouched")
	var enemy: int = _add(state,"employee",1,-1,1)[0]
	check(not Actions.apply_action(state,0,{"kind":"move","ids":[enemy],"group":-1}),"shared action executor rejects rival personnel")
	check(not Actions.apply_action(state,0,{"kind":"dismiss","ids":[enemy]}),"shared action executor rejects rival dismissal")
	check(not Actions.apply_action(state,0,{"kind":"buy","offer":-1}),"expired/unknown offer is rejected by real rules")
