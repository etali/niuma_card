extends SceneTree

const Actions = preload("res://engine/off_work_bot_actions.gd")
const Emergency = preload("res://engine/off_work_bot_emergency.gd")
var failures := []
var checks := 0

func _initialize() -> void:
	_test_financing()
	_test_target()
	_test_production_alternatives()
	_test_deadline()
	_test_scattered_deadline()
	for msg in failures: printerr(msg)
	print("WORK_BOT_PLANNING %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, msg: String) -> void:
	checks += 1
	if not ok: failures.append(msg)

func choose(state: OffWorkState) -> Dictionary:
	var bot := OffWorkBot.new(state,0)
	var action := bot.decide_action(Time.get_ticks_usec()+1000000)
	return {"action":action,"diagnostics":bot.last_decision}

func _state(groups: Array) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = groups
	config.rules.initial.money = 0
	config.rules.conveyor.interval_seconds = 30.0
	var state := OffWorkState.new(config)
	state.new_game(23)
	return state

func _test_financing() -> void:
	var state := _state([{"employee":1,"work":40},{"leader":1}])
	# Wait is free, but firing an idle host funds a second productive worker.
	state.offers = [state._make_offer("employee")]
	var decision := choose(state)
	check(decision.action.kind == "dismiss","select a financing sequence instead of waiting for cash")
	check(state.people_count(0) == 2 and state.money(0) == 0,"forecast never mutates the game")
	if decision.action.kind != "dismiss": return
	check(state.cards[decision.action.ids[0]].type == "leader","retain the productive employee")
	check(Actions.apply_action(state,0,decision.action) and state.money(0) == state.config.cards.leader.refund,"real dismissal pays the actual configured refund")
	decision = choose(state)
	check(decision.action.kind == "buy","buy the planned employee when financing is in place")
	check(Actions.apply_action(state,0,decision.action) and state.people_count(0) == 2,"purchase resolves through OffWorkState")

func _test_target() -> void:
	var state := _state([{"employee":2,"work":10},{"grinder":1,"work":150}])
	state.config.roles.grinder.work_capacity = 10
	state.offers.clear()
	# Our production is already consolidated. The rival's high-capacity group
	# carries the critical queue, so this tests target selection rather than
	# competing against an obviously stronger consolidation of our own work.
	var own_target: int = int(state.cards[state._owner_type(0,"grinder")[0]].group)
	var own_source: int = int(state.cards[state._owner_type(0,"employee")[0]].group)
	state.move_cards(state.group_cards(own_source),own_target)
	state.add_card("strike",0)
	state.advance(0.01)
	var target := -1
	for id in state.cards:
		if state.cards[id].owner == 1 and state.cards[id].type == "grinder": target = state.cards[id].group
	var decision := choose(state)
	check(decision.action.kind == "activate" and decision.action.get("group") == target,"strike the single high-capacity producer ahead of the two-person group")
	check(decision.diagnostics.root_complete and decision.diagnostics.evaluated >= 3,"complete root comparison includes both enemy targets and wait")
	check(decision.diagnostics.get("algorithm")=="race_search_v2","target selection uses the shared race search, without an old planner score")

func _test_deadline() -> void:
	var state := _state([{"work":3900},{"employee":1}])
	var expired := Emergency.choose(state,0,Time.get_ticks_usec()-1,{})
	check(expired.action.kind=="wait" and Actions.apply_action(state,0,expired.action),"expired emergency budget returns an immediately legal wait")
	var short := Emergency.choose(state,0,Time.get_ticks_usec()+800,{})
	check(short.action.kind=="move","small emergency budget can staff a large production pile")
	if short.action.kind=="move": check(Actions.apply_action(state,0,short.action),"large-pile emergency dispatch executes through the same public rule executor")

func _test_scattered_deadline() -> void:
	var state := OffWorkState.new(OffWorkConfig.new())
	for seat in 2:
		for i in 2048: state.add_card("work",seat)
		state.add_card("employee",seat)
	var bot := OffWorkBot.new(state,1)
	var attempts := 0
	for tick in 180:
		attempts += 1
		if tick==4:
			var saved := bot.export_decision_context()
			bot = OffWorkBot.new(state,1)
			bot.import_decision_context(saved)
		var result := Emergency.choose(state,1,Time.get_ticks_usec()+800,bot.export_decision_context())
		bot.import_decision_context(result.context)
		if result.action.kind!="move": continue
		check(state.cards[result.action.ids[0]].owner==1 and state.groups[result.action.group].owner==1,"resumed emergency scan finds a same-seat production assignment")
		check(Actions.apply_action(state,1,result.action),"resumed scattered-table command is a real legal action")
		break
	check(attempts<180,"small deadlines eventually reach the employee among 4098 separate groups")
	print("SCATTERED_SEARCH decisions=",attempts)

func _test_production_alternatives() -> void:
	var state := _state([{"work":60,"employee":2},{"work":60},{"employee":1}])
	state.offers.clear()
	state.advance(0.01)
	var staffed := -1
	var separate := -1
	for gid in state.groups:
		if state.groups[gid].owner!=0 or state.group_work(gid).is_empty(): continue
		if state.group_people(gid).is_empty(): separate=gid
		else: staffed=gid
	state.add_card("strike",1)
	var before := var_to_bytes([state.cards,state.groups,state.tasks,state._rng.state])
	var generated := Actions.generate(state,0,state.config.rules.bot,Time.get_ticks_usec()+1000000)
	check(generated.complete and before==var_to_bytes([state.cards,state.groups,state.tasks,state._rng.state]),"production alternatives are complete and read-only under a visible strike")
	for target in [staffed,separate]:
		var found := false
		for action in generated.actions:
			if action.kind!="move" or action.group!=target or action.get("intent") not in ["staff","staff_batch","assemble_work"]: continue
			var branch := state.fork_for_bot(23)
			if Actions.apply_action(branch,0,action) and branch.group_work_participants(target).size()>state.group_work_participants(target).size():
				found=true
				break
		check(found,"existing and separate work groups both reach search as real staffing options")
	var split: Array = generated.actions.filter(func(a): return a.kind=="move" and a.group<0 and a.get("intent")=="split_work")
	check(not split.is_empty(),"fresh independent production groups remain available even with an existing productive group")
