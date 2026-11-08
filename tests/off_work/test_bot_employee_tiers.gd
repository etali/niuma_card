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

func _fixture(role := "employee", can_compete_for_recipes := true) -> RefCounted:
	var config := Config.new()
	config.rules.initial.groups = [{role: 1, "work": 200}]
	config.rules.initial.money = 40 if can_compete_for_recipes else 0
	# Make each promotion valuable for this long production queue.
	config.roles.grinder.work_capacity = 2
	config.roles.workaholic.work_capacity = 4
	config.roles.work_emperor.work_capacity = 8
	config.rules.conveyor.interval_seconds = 1000.0
	if not can_compete_for_recipes: config.rules.conveyor.slots = 7
	var state := State.new(config)
	state.new_game(67)
	state.offers.clear()
	if not can_compete_for_recipes:
		# The rival legally dismisses its only employee. The refund cannot pay
		# for a cup and no productive/finance assets remain, so search agrees
		# with the undriven rival about the visible recipe's availability.
		state.dismiss_people(state._owner_type(1, role), 1)
		state._credit(0, 40)
	return state

func _person(state: RefCounted, role: String) -> int:
	for id in state.cards:
		if int(state.cards[id].owner) == 0 and str(state.cards[id].type) == role:
			return int(id)
	return -1

func _collect_complete_stage(role: String, next: String, cost: int) -> void:
	var state := _fixture(role)
	# This case checks promotion and redeployment, not reactions to a random
	# market strike. Keep the opponent's future purchases out of this fixture.
	state.offers.clear()
	state.config.rules.conveyor.interval_seconds = 1000.0
	var person := _person(state, role)
	var workplace: int = state.cards[person].group
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
	# Recipe completion does not grant an extra BOT command. Reach its next
	# actual action slot even when the configured interval exceeds 5 seconds.
	state.advance(maxf(0.0, bot.next_action_time() - state.time))
	bot.advance(0.0)
	# A fresh legal work batch also redeploys the promoted person. Group IDs
	# are a layout choice, so verify the actual task and completed production.
	_check(state.tasks.get(person, {}).get("kind") == "work" and not state.group_work(state.cards[person].group).is_empty(),
		"bot returns the promoted worker to waiting work through a real action")
	var work_before: int = state.work_count(0)
	state.advance(state.config.roles[next].work_seconds)
	_check(work_before-state.work_count(0)>=int(state.config.roles[next].work_capacity),
		"redeployed promoted worker completes a real full-capacity production batch")

func _purchase_fourth_cup() -> void:
	var state := _fixture("workaholic")
	var bot := Bot.new(state, 0)
	for i in 3: state.add_card("coffee", 0)
	state.offers = [state._make_offer("coffee")]
	bot.start()
	bot.advance(0.0)
	_check(state._owner_type(0, "coffee").size() == 4, "bot buys the fourth cup for the final recipe")
	state.advance(bot.next_action_time() - state.time)
	bot.advance(0.0)
	state.advance(5.0)
	_check(_person(state, "work_emperor") >= 0, "four purchased cups reach emperor")
	state.offers = [state._make_offer("coffee")]
	var funds := int(state.money(0))
	state.advance(maxf(0.0, bot.next_action_time() - state.time))
	bot.advance(0.0)
	_check(state._owner_type(0, "coffee").is_empty(), "bot stops buying coffee when only max-level personnel remain")
	_check(state.money(0) == funds, "max-level stop does not spend cash")

func _full_bot_progression() -> void:
	var state := _fixture("employee", false)
	# The final promotion must beat the real alternative of carrying partial
	# progress into a fresh four-file batch at every action opportunity.
	state.config.roles.work_emperor.work_seconds = 2.0
	var person := _person(state, "employee")
	# Publish the entire finite 1 + 2 + 4 recipe before the first decision.
	# Nothing refills behind the search's back, and the opponent cannot buy.
	for cup in 7: state.offers.append(state._make_offer("coffee"))
	_check(state.people_count(1) == 0 and state.money(1) < state.config.cards.coffee.price, "progression rival has no unmodelled purchasing opportunity")
	var bot := Bot.new(state, 0)
	bot.start()
	var transitions: Array = []
	for step in 400:
		bot.advance(0.2)
		state.advance(0.2)
		for event in state.drain_events():
			if event.kind == "coffee_upgrade" and int(event.person) == person:
				transitions.append(str(state.cards[person].type))
		if str(state.cards[person].type) == "work_emperor": break
	_check(transitions == ["grinder", "workaholic", "work_emperor"], "real bot loop buys, accumulates and completes all three stages in order")
	_check(str(state.cards[person].type) == "work_emperor", "real bot loop reaches maximum level without manual activation")
	if str(state.cards[person].type) != "work_emperor": return
	state.advance(maxf(0.0, bot.next_action_time() - state.time))
	bot.advance(0.0)
	_check(state.tasks.get(person, {}).get("kind") == "work", "the final promotion returns to real production")
	var work_before: int = state.work_count(0)
	state.advance(state.config.roles.work_emperor.work_seconds)
	_check(work_before - state.work_count(0) >= state.config.roles.work_emperor.work_capacity,
		"the completed investment processes a full emperor batch through the real clock")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)
