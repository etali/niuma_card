extends SceneTree

const Planner = preload("res://engine/off_work_bot_planner.gd")
var failures := []
var checks := 0

func _initialize() -> void:
	_test_financing()
	_test_target()
	_test_real_reply_changes_assignment()
	_test_deadline()
	_test_scattered_deadline()
	for msg in failures: printerr(msg)
	print("WORK_BOT_PLANNING %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL",checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, msg: String) -> void:
	checks += 1
	if not ok: failures.append(msg)

func choose(p: RefCounted, s: OffWorkState) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	return p.choose(s,0,s.config.rules.bot,rng,Time.get_ticks_usec()+100000)

func _state(groups: Array) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = groups
	config.rules.initial.money = 0
	config.rules.bot.buy_chance = 1.0
	config.rules.bot.min_reserve = 0
	config.rules.bot.purchase_priority = ["employee"]
	config.rules.conveyor.interval_seconds = 30.0
	var state := OffWorkState.new(config)
	state.new_game(23)
	return state

func _test_financing() -> void:
	var state := _state([{"employee":1,"work":40},{"leader":1}])
	# Wait is free, but firing an idle host funds a second productive worker.
	state.offers = [state._make_offer("employee")]
	var p := Planner.new()
	var decision := choose(p,state)
	check(decision.action.kind == "dismiss","select a financing sequence instead of waiting for cash")
	check(state.people_count(0) == 2 and state.money(0) == 0,"forecast never mutates the game")
	if decision.action.kind != "dismiss": return
	check(state.cards[decision.action.ids[0]].type == "leader","retain the productive employee")
	check(p.apply_action(state,0,decision.action) and state.money(0) == state.config.cards.leader.refund,"real dismissal pays the actual configured refund")
	decision = choose(p,state)
	check(decision.action.kind == "buy","buy the planned employee when financing is in place")
	check(p.apply_action(state,0,decision.action) and state.people_count(0) == 2,"purchase resolves through OffWorkState")

func _test_target() -> void:
	var state := _state([{"employee":2,"work":80},{"grinder":1,"work":80}])
	state.config.roles.grinder.work_capacity = 10
	state.config.rules.bot.purchase_priority = []
	state.config.rules.bot.tool_priority = ["strike"]
	state.add_card("strike",0)
	state.advance(0.01)
	var target := -1
	for id in state.cards:
		if state.cards[id].owner == 1 and state.cards[id].type == "grinder": target = state.cards[id].group
	var p := Planner.new()
	var decision := choose(p,state)
	check(decision.action.kind == "activate" and decision.action.get("group") == target,"strike the single high-capacity producer ahead of the two-person group")
	check(decision.diagnostics.evaluated >= 3,"both enemy targets and wait are compared")
	check(not p.forecast_context().is_empty() and p.forecast_context().throughput[1] > 0,"publish observed output for opponent-response forecasts")

func _test_deadline() -> void:
	var state := _state([{"work":3900},{"employee":1}])
	var p := Planner.new()
	var rng := RandomNumberGenerator.new()
	var expired: Dictionary = p.choose(state,0,state.config.rules.bot,rng,Time.get_ticks_usec()-1)
	check(expired.action.kind == "wait" and expired.diagnostics.fallback,"expired budget returns immediately with a legal action")
	var short: Dictionary = p.choose(state,0,state.config.rules.bot,rng,Time.get_ticks_usec()+800)
	check(short.action.kind == "move","within a small budget a large production pile can still be staffed")

func _test_scattered_deadline() -> void:
	var state := OffWorkState.new(OffWorkConfig.new())
	for seat in 2:
		for i in 2048: state.add_card("work",seat)
		state.add_card("employee",seat)
	var p := Planner.new()
	var rng := RandomNumberGenerator.new()
	var attempts := 0
	for tick in 180:
		attempts += 1
		if tick == 4:
			var saved := p.save_scan_hints()
			p = Planner.new()
			p.restore_scan_hints(saved)
		var result := p.choose(state,1,state.config.rules.bot,rng,Time.get_ticks_usec()+800)
		if result.action.kind != "move": continue
		check(state.cards[result.action.ids[0]].owner == 1 and state.groups[result.action.group].owner == 1,
			"resumed scan finds a legal same-seat production assignment")
		break
	check(attempts < 180,"a small deadline eventually reaches the employee in the last of 4098 separate groups")
	print("SCATTERED_SEARCH decisions=", attempts)

func _test_real_reply_changes_assignment() -> void:
	var state := _state([{"work":60,"employee":2},{"work":60},{"employee":1}])
	state.config.rules.bot.buy_chance = 0.0
	state.config.rules.bot.decision_budget_ratio = 0.5
	state.advance(0.01)
	var staffed := -1
	var separate := -1
	for gid in state.groups:
		if state.groups[gid].owner != 0 or state.group_work(gid).is_empty(): continue
		if state.group_people(gid).is_empty():
			separate = gid
		else:
			staffed = gid
	var bot := OffWorkBot.new(state,0)
	var concentrated := bot.decide_action()
	check(concentrated.get("group") == staffed,"with no threat the extra worker can join the established group")
	var distinct := {}
	for entry in bot.last_decision.candidates:
		if entry.kind == "move" and entry.get("group",-1) in [staffed,separate]: distinct[entry.group] = true
	check(distinct.size() == 2,"the public planner submits both production destinations to reply search")
	state.add_card("strike",1)
	var dispersed := bot.decide_action()
	check(dispersed.get("group") == separate,"a visible enemy strike changes the public BOT assignment to a separate group")
	check("罢工" in bot.last_decision.reason,"the selected decision explains the concrete opposing strike")
