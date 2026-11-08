extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_test_mutual_transfer()
	_test_batch_recovery()
	_test_progress_carrying_recovery()
	for failure in failures: printerr("FAIL " + failure)
	print("BOT_PRODUCTION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _test_mutual_transfer() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 2, "work": 30, "transfer": 1}]
	config.rules.conveyor.interval_seconds = 1000.0
	var state := OffWorkState.new(config)
	state.new_game(17)
	state.offers.clear()
	for uid in state.cards.keys():
		if state.cards[uid].type == "transfer": state.activate(uid, int(state.cards[uid].group))
	var initial := state.work_count(0) + state.work_count(1)
	state.advance(20.0)
	_check(state.work_count(0) + state.work_count(1) == initial, "all-transfer fixture only exchanges work before bots intervene")
	# Give both sides a real productive way out. In a perfectly symmetric
	# transfer-only zero-sum table, unilaterally accepting all incoming work can
	# lose; a rational opponent need not sacrifice itself to satisfy a test.
	for side in 2:
		for count in 6: state.add_card("overtime", side)
	var bots := [OffWorkBot.new(state, 0), OffWorkBot.new(state, 1)]
	for bot in bots: bot.start()
	for step in 6:
		for bot in bots: bot.advance(0.0)
		state.advance(config.rules.bot.think_seconds)
		state.drain_events()
		if state.winner >= 0: break
	_check(state.tasks.values().any(func(task): return task.kind == "work"), "BOT recognizes an available productive continuation out of mutual transfers")
	state.advance(200.0)
	_check(state.winner >= 0, "chosen real production arrangement clears the table without more purchases")
	_check(state.work_count(0) + state.work_count(1) < initial, "repair destroys real work instead of merely choosing a winner")

func _recovery_state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 2, "work": 30}]
	config.rules.conveyor.interval_seconds = 1000.0
	var state := OffWorkState.new(config)
	state.new_game(41)
	state.offers.clear()
	return state

func _test_batch_recovery() -> void:
	var state := _recovery_state()
	var people := state._owner_type(0, "employee").duplicate()
	var target: int = state.cards[people[0]].group
	_check(state.activate(state.add_card("strike", 1), target), "batch fixture launches a real strike")
	# Start only after impact: neither worker escaped into a productive group
	# whose partial batch would be worth completing ahead of redeployment.
	state.advance(state.config.rules.strike.flight_seconds)
	_check(people.all(func(uid): return state.is_striking(uid)), "the complete workforce is actually struck before BOT starts")
	var bot := OffWorkBot.new(state, 0)
	bot.start()
	var recovered_at: float = state.config.rules.strike.flight_seconds + state.config.rules.strike.duration_seconds
	var returned_at := INF
	var worked_while_locked := false
	for step in 140:
		bot.advance(0.2)
		var all_working: bool = people.all(func(uid): return state.tasks.get(uid, {}).get("kind") == "work")
		if state.time < recovered_at - 0.0001:
			worked_while_locked = worked_while_locked or people.any(func(uid): return state.tasks.get(uid, {}).get("kind") == "work")
		elif all_working:
			returned_at = state.time
			break
		state.advance(0.2)
		state.drain_events()
	_check(not worked_while_locked, "batch redeployment respects the real strike lock")
	_check(returned_at <= recovered_at + state.config.rules.bot.think_seconds + 0.2,
		"all recovered staff resume real work within the next action opportunity")
	_check(state.people_count(0) == people.size(), "batch recovery keeps every recovered worker")

func _test_progress_carrying_recovery() -> void:
	var state := _recovery_state()
	var config: OffWorkConfig = state.config
	var target := -1
	for gid in state.groups:
		if int(state.groups[gid].owner) == 0 and not state.group_work(int(gid)).is_empty(): target = int(gid)
	var people := state.group_people(target).duplicate()
	var attack := state.add_card("strike", 1)
	_check(state.activate(attack, target), "fixture applies an actual strike to ordinary production")
	var bot := OffWorkBot.new(state, 0)
	bot.start()
	var recovered_at: float = config.rules.strike.flight_seconds + config.rules.strike.duration_seconds
	var returned_at := INF
	var productive_during_attack_window := false
	var initial_work := state.work_count(0)
	for step in 140:
		bot.advance(0.2)
		if state.time >= config.rules.strike.flight_seconds and state.time < recovered_at:
			productive_during_attack_window = productive_during_attack_window or people.any(func(uid): return state.tasks.get(uid, {}).get("kind") == "work")
		if state.time >= recovered_at and people.all(func(uid): return state.tasks.has(uid) and state.tasks[uid].kind == "work"):
			returned_at = minf(returned_at, state.time)
		state.advance(0.2)
		state.drain_events()
	_check(people.all(func(uid): return not state.is_striking(uid)), "bot waits until the real strike lock expires")
	# This position permits a real alternative: finish a carried-progress batch
	# with the escaped worker, then bring both workers into the next batch.
	_check(productive_during_attack_window, "active defense preserves production through the attack window, whether some or all workers escape")
	_check(state.work_count(0) < initial_work, "progress-preserving decisions actually consume work")
	_check(returned_at < INF and state.people_count(0) == people.size(),
		"progress-preserving continuation redeploys the whole workforce without dismissing it")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)
