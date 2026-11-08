extends SceneTree

## Tests real commands and real simulation. No UI state or animation fixture
## is used as evidence that a game ended.
const Config = preload("res://engine/off_work_config.gd")
const State = preload("res://engine/off_work_state.gd")
const Bot = preload("res://engine/off_work_bot.gd")

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_configuration_changes_real_behavior()
	for seed_value in [17, 41, 137, 20261027]:
		_play_complete_game(seed_value)
	if failures.is_empty():
		print("WORK_INTEGRATION PASS (", checks, " checks)")
		quit(0)
	else:
		for message in failures:
			printerr("FAIL ", message)
		print("WORK_INTEGRATION FAIL (", failures.size(), " failures / ", checks, " checks)")
		quit(1)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _small_config() -> RefCounted:
	var config := Config.new()
	config.rules.initial.groups = [{"employee": 1, "work": 10}]
	config.rules.initial.money = 8
	config.rules.bot.enabled = false
	return config

func _configuration_changes_real_behavior() -> void:
	var slow := _small_config()
	slow.cards.work.work_seconds = 20.0
	var fast := _small_config()
	fast.cards.work.work_seconds = 5.0
	var a := State.new(slow)
	var b := State.new(fast)
	a.new_game(23)
	b.new_game(23)
	a.advance(10.0)
	b.advance(10.0)
	_check(a.work_count(0) == 10, "20-second configuration must not complete at 10 seconds")
	_check(b.work_count(0) == 8, "5-second configuration must complete exactly twice at 10 seconds")
	_check(b.money(0) - a.money(0) == 2 * int(fast.cards.work.income), "configured income must follow real completions")

	var belt_slow := _small_config()
	var belt_fast := _small_config()
	belt_slow.rules.conveyor.interval_seconds = 5.0
	belt_fast.rules.conveyor.interval_seconds = 1.0
	a = State.new(belt_slow)
	b = State.new(belt_fast)
	a.new_game(29)
	b.new_game(29)
	var slow_first := int(a.offers[0].id)
	var fast_first := int(b.offers[0].id)
	a.advance(2.0)
	b.advance(2.0)
	_check(int(a.offers[0].id) == slow_first, "configured five-second conveyor holds at two seconds")
	_check(int(b.offers[0].id) != fast_first, "configured one-second conveyor shifts before two seconds")

	var priced := _small_config()
	priced.cards.employee.price = 3
	priced.rules.conveyor.pool = {"employee": 1}
	a = State.new(priced)
	a.new_game(31)
	var before := a.money(0)
	var bought := int(a.buy(int(a.offers[0].id), 0))
	_check(bought >= 0 and a.cards.has(bought), "configured-price purchase produces a real card")
	_check(a.money(0) == before - 3, "purchase takes price from configuration")
	_check(a.offers[0].is_empty(), "purchased slot remains empty until scheduled conveyor shift")

func _play_complete_game(seed_value: int) -> void:
	var config := Config.new()
	_check(config.errors.is_empty(), "shipped configuration valid")
	var state := State.new(config)
	state.new_game(seed_value)
	_check(state.work_count(0) == 200 and state.work_count(1) == 200, "shipped opening gives each side 200 work cards")
	_check(state.people_count(0) == 1 and state.people_count(1) == 1, "shipped opening retains one employee per side")
	var first_snapshot := _snapshot(state)
	var bots := [Bot.new(state, 0), Bot.new(state, 1)]
	for bot in bots: bot.start()
	var owned_tools: Dictionary = {}
	var consumed_strikes: Dictionary = {}
	var last_work: int = state.work_count(0) + state.work_count(1)
	var all_invariants := true
	var reason := ""
	var steps := 0
	while state.winner == -1 and steps < 6000:
		for bot in bots:
			bot.advance(0.2)
		state.advance(0.2)
		for event in state.drain_events():
			if event.kind == "strike": consumed_strikes[int(event.source)] = true
		steps += 1
		var current_work: int = state.work_count(0) + state.work_count(1)
		if current_work > last_work:
			all_invariants = false
			reason = "work increased without a production rule"
		last_work = current_work
		for id in state.cards:
			var card: Dictionary = state.cards[id]
			if config.category(str(card.type)) == "tool":
				owned_tools[id] = str(card.type)
			if not state.groups.has(int(card.group)):
				all_invariants = false
				reason = "card refers to missing group"
		for person in state.tasks:
			if state.tasks[person].kind == "work" and not config.can_work(str(state.cards[person].type)):
				all_invariants = false
				reason = "nonworking role received ordinary work"
		for offer in state.offers:
			if not offer.is_empty() and offer.type == "fire":
				all_invariants = false
				reason = "removed firing card appeared on conveyor"
		for id in owned_tools:
			if not state.cards.has(id):
				if owned_tools[id] == "strike" and consumed_strikes.has(id): continue
				all_invariants = false
				reason = "durable tool disappeared"
		if state.money(0) < 0 or state.money(1) < 0:
			all_invariants = false
			reason = "negative money"
		if not all_invariants:
			break
	_check(all_invariants, "seed %d live invariants: %s" % [seed_value, reason])
	_check(state.winner != -1, "seed %d reaches a real result within 1200 simulation seconds" % seed_value)
	if state.winner in [0, 1]:
		_check(state.work_count(int(state.winner)) == 0, "winner has zero work")
	elif state.winner == 2:
		_check(state.work_count(0) == 0 and state.work_count(1) == 0, "draw clears both sides at the same timestamp")
	var finished_snapshot := _snapshot(state)
	state.advance(100.0)
	for bot in bots:
		bot.advance(100.0)
	_check(_snapshot(state) == finished_snapshot, "finished game remains locked after simulation and BOT updates")
	print("INTEGRATION_MATCH seed=", seed_value, " winner=", state.winner, " time=", state.time, " steps=", steps)
	state.new_game(seed_value)
	_check(_snapshot(state) == first_snapshot, "restart restores deterministic initial state and clears previous tasks")
	_check(state.winner == -1 and is_zero_approx(state.time), "restart resets winner and simulation time")
	var fresh := State.new(config)
	fresh.new_game(seed_value)
	state.advance(10.0)
	fresh.advance(10.0)
	_check(_snapshot(state) == _snapshot(fresh), "restarted game advances identically to a new instance")

func _snapshot(state: RefCounted) -> String:
	return JSON.stringify({"cards": state.cards, "groups": state.groups,
		"tasks": state.tasks, "offers": state.offers, "winner": state.winner,
		"time": state.time, "conveyor": state.conveyor_progress}, "", true)
