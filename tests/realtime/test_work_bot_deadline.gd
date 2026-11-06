# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var config := WorkConfig.new()
	config.rules.initial.money = 0
	config.rules.initial.groups = [{"work": 4095}, {"employee": 1}]
	config.rules.bot.erase("decision_budget_ratio")
	config.rules.bot.decision_budget_ms = 1
	var state := WorkState.new(config)
	state.new_game(904)
	var bot := WorkBot.new(state, 1)
	bot.start()
	var initial_revision := state.revision
	var market_rng := state._rng.state
	var initial_events := state.drain_events()
	var expired := bot.decide_action(Time.get_ticks_usec() - 1)
	_check(expired.kind == "wait" and bot.last_decision.fallback and bot.last_decision.cutoff,
		"an expired deadline immediately returns the preselected legal wait")
	_check(bot.last_decision.evaluated == 0, "an expired deadline starts no search")

	var opening_moves := 0
	var peak_usec := 0
	var returned_in_time := 0
	for _n in 40:
		var before := Time.get_ticks_usec()
		var command := bot.decide_action()
		var wall_usec := Time.get_ticks_usec() - before
		peak_usec = maxi(peak_usec, wall_usec)
		returned_in_time += int(wall_usec <= 1000)
		opening_moves += int(command.kind == "move")
		_check(int(bot.last_decision.selected_after_us) < 1000, "a result produced after the deadline was committed")
	# A loaded OS can deschedule the test process between reads. Also check the
	# external clock, independently of the driver's own diagnostics.
	_check(returned_in_time >= 36, "normal 1 ms calls must finish within their wall-clock budget")
	_check(opening_moves > 0, "a 1 ms decision can dispatch an idle employee beside a 4095-card stack")
	_check(state.revision == initial_revision and state._rng.state == market_rng and is_zero_approx(state.time),
		"previewing candidates must not advance the game clock, deal cards or read the future market")
	_check(initial_events.size() > 0 and state.drain_events().is_empty(), "planning emits no live game events")
	_check(bot.decision_serial == 0, "planning alone does not count as a played decision")

	bot.advance(0.0)
	_check(bot.decision_serial == 1 and bot.last_decision.applied, "the selected command is applied through the real match")
	bot.advance(99.0)
	_check(bot.decision_serial == 1, "wall time and the frame argument do not advance the virtual decision clock")

	for failure in failures: printerr("FAIL " + failure)
	print("WORK_BOT_DEADLINE %s (%d checks, 40 decisions, 1 ms, peak %d us)" % ["PASS" if failures.is_empty() else "FAIL", checks, peak_usec])
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
