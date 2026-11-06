extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var config := WorkConfig.new()
	config.rules.initial.groups = [{"employee": 2, "work": 30, "transfer": 1}]
	config.rules.bot.buy_chance = 0.0
	var state := WorkState.new(config)
	state.new_game(17)
	for uid in state.cards.keys():
		if state.cards[uid].type == "transfer": state.activate(uid, int(state.cards[uid].group))
	var initial := state.work_count(0) + state.work_count(1)
	state.advance(20.0)
	_check(state.work_count(0) + state.work_count(1) == initial, "all-transfer fixture only exchanges work before bots intervene")
	var bots := [WorkBot.new(state, 0), WorkBot.new(state, 1)]
	for bot in bots: bot.start()
	for step in 2000:
		for bot in bots: bot.advance(0.2)
		state.advance(0.2)
		state.drain_events()
		if state.winner >= 0: break
	_check(state.winner >= 0, "both bots escape an existing all-transfer deadlock without buying cards")
	_check(state.work_count(0) + state.work_count(1) < initial, "repair destroys real work instead of merely choosing a winner")
	config.rules.initial.groups = [{"employee": 2, "work": 30}]
	state.new_game(41)
	var target := -1
	for gid in state.groups:
		if int(state.groups[gid].owner) == 0 and not state.group_work(int(gid)).is_empty(): target = int(gid)
	var people := state.group_people(target).duplicate()
	var attack := state.add_card("strike", 1)
	_check(state.activate(attack, target), "fixture applies an actual strike to ordinary production")
	var bot := WorkBot.new(state, 0)
	bot.start()
	for step in 140:
		bot.advance(0.2)
		state.advance(0.2)
		state.drain_events()
	_check(people.all(func(uid): return not state.is_striking(uid)), "bot waits until the real strike lock expires")
	_check(people.all(func(uid): return state.tasks.has(uid) and state.tasks[uid].kind == "work"), "recovered scattered staff all rejoin ordinary work")
	for failure in failures: printerr("FAIL " + failure)
	print("BOT_PRODUCTION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)
