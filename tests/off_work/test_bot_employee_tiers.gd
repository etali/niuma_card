extends SceneTree

const Config = preload("res://engine/off_work_config.gd")
const State = preload("res://engine/off_work_state.gd")
const Bot = preload("res://engine/off_work_bot.gd")

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_collect_complete_stage("grinder", "workaholic", 2)
	_collect_complete_stage("workaholic", "work_emperor", 4)
	_purchase_fourth_cup()
	_full_bot_progression()
	for failure in failures: printerr("FAIL " + failure)
	print("BOT_EMPLOYEE_TIERS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _fixture(role := "employee") -> RefCounted:
	var config := Config.new()
	config.rules.initial.groups = [{role: 1, "work": 200}]
	config.rules.initial.money = 40
	# Make each promotion valuable for this long production queue.
	config.roles.grinder.work_capacity = 2
	config.roles.workaholic.work_capacity = 4
	config.roles.work_emperor.work_capacity = 8
	config.rules.bot.buy_chance = 1.0
	config.rules.bot.purchase_priority = ["coffee"]
	config.rules.bot.tool_priority = ["coffee"]
	var state := State.new(config)
	state.new_game(67)
	return state

func _person(state: RefCounted, role: String) -> int:
	for id in state.cards:
		if int(state.cards[id].owner) == 0 and str(state.cards[id].type) == role:
			return int(id)
	return -1

func _collect_complete_stage(role: String, next: String, cost: int) -> void:
	var state := _fixture(role)
	var person := _person(state, role)
	var workplace: int = state.cards[person].group
	state.config.rules.bot.buy_chance = 0.0
	state.advance(0.001)
	var cups: Array = []
	for i in cost - 1: cups.append(state.add_card("coffee", 0))
	var old_groups: Array = cups.map(func(id): return int(state.cards[id].group))
	var bot := Bot.new(state, 0)
	bot.start()
	bot.advance(0.0)
	_check(cups.map(func(id): return int(state.cards[id].group)) == old_groups, "incomplete recipe stays available")
	_check(state.tasks[person].kind == "work", "worker keeps working while ingredients accumulate")
	cups.append(state.add_card("coffee", 0))
	state.advance(bot.next_action_time() - state.time)
	bot.advance(0.0)
	_check(state.tasks[person].kind == "coffee" and state.tasks[person].coffee_ids.size() == cost, "all required cups reserved for the selected senior")
	_check(int(state.cards[person].group) != workplace and state.group_work(state.cards[person].group).is_empty(), "bot splits personnel and coffee into a separate work-free combination")
	_check(state.group_work(workplace).size() == 200 and state.tasks[person].work_id == -1, "promotion leaves the unfinished work at its workplace")
	state.advance(5.0)
	_check(str(state.cards[person].type) == next, "bot recipe completes next stage with same UID")
	_check(cups.all(func(id): return not state.cards.has(id)), "complete recipe consumed exactly once")
	bot.advance(0.0)
	_check(state.cards[person].group == workplace and state.tasks.get(person, {}).get("kind") == "work", "bot returns the promoted worker to the waiting work through a real action")

func _purchase_fourth_cup() -> void:
	var state := _fixture("workaholic")
	var bot := Bot.new(state, 0)
	for i in 3: state.add_card("coffee", 0)
	state.offers[0] = state._make_offer("coffee")
	bot.start()
	bot.advance(0.0)
	_check(state._owner_type(0, "coffee").size() == 4, "bot buys the fourth cup for the final recipe")
	state.advance(bot.next_action_time() - state.time)
	bot.advance(0.0)
	state.advance(5.0)
	_check(_person(state, "work_emperor") >= 0, "four purchased cups reach emperor")
	state.offers[0] = state._make_offer("coffee")
	var funds := int(state.money(0))
	bot.advance(0.0)
	_check(state._owner_type(0, "coffee").is_empty(), "bot stops buying coffee when only max-level personnel remain")
	_check(state.money(0) == funds, "max-level stop does not spend cash")

func _full_bot_progression() -> void:
	var state := _fixture()
	var person := _person(state, "employee")
	var bot := Bot.new(state, 0)
	bot.start()
	var transitions: Array = []
	for step in 400:
		state.offers[0] = state._make_offer("coffee")
		bot.advance(0.2)
		state.advance(0.2)
		for event in state.drain_events():
			if event.kind == "coffee_upgrade" and int(event.person) == person:
				transitions.append(str(state.cards[person].type))
		if str(state.cards[person].type) == "work_emperor": break
	_check(transitions == ["grinder", "workaholic", "work_emperor"], "real bot loop buys, accumulates and completes all three stages in order")
	_check(str(state.cards[person].type) == "work_emperor", "real bot loop reaches maximum level without manual activation")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)
