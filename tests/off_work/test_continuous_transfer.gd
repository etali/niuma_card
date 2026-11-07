extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_repeat_and_capacity()
	_membership_and_pause()
	_dismantle_and_refill()
	_tail_and_config()
	_frame_independence()
	for failure in failures: push_error(failure)
	print("CONTINUOUS_TRANSFER %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _state(contents: Dictionary) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [contents]
	config.rules.initial.money = 0
	config.rules.bot.enabled = false
	var state := OffWorkState.new(config)
	state.new_game(61)
	# Keep the opponent's queue stationary so outputs are exactly observable.
	for group in state.groups.keys():
		if int(state.groups[group].owner) == 1 and not state.group_people(group).is_empty():
			state.move_cards(state.group_people(group), -1)
	state.drain_events()
	return state

func _group(state: OffWorkState) -> int:
	for group in state.groups:
		if int(state.groups[group].owner) == 0 and not state.group_work(group).is_empty(): return int(group)
	return -1

func _start(state: OffWorkState, group: int) -> int:
	var tool := state.add_card("transfer", 0)
	_check(state.move_cards([tool], group) == group and state.cards[tool].status == "active", "stacking starts a real transfer combination")
	state.drain_events()
	return tool

func _transfers(state: OffWorkState) -> Array:
	return state.drain_events().filter(func(event): return event.kind == "transfer" and event.owner == 0)

func _repeat_and_capacity() -> void:
	var state := _state({"employee": 5, "work": 60})
	var group := _group(state)
	var tool := _start(state, group)
	for cycle in range(1, 4):
		state.advance(9.9)
		_check(state.work_count(0) == 60 - (cycle - 1) * 5, "batch never settles early")
		for person in state.group_transfer_participants(group):
			_check(is_equal_approx(float(state.cards[person].progress), state.group_transfer_progress(group)), "all personnel project one shared transfer clock")
		state.advance(0.1)
		var events := _transfers(state)
		_check(events.size() == 1 and events[0].ids.size() == 5 and events[0].participants.size() == 5, "five employees produce one five-work transfer event each cycle")
		_check(state.work_count(0) == 60 - cycle * 5 and state.work_count(1) == 60 + cycle * 5, "continuous cycles conserve and transfer real work")
		_check(state.cards[tool].status == "active" and is_zero_approx(state.group_transfer_progress(group)), "next cycle starts immediately without recovery")
		_check(state.money(0) == 0, "transfer never earns money")
	var mixed := _state({"employee": 1, "grinder": 1, "leader": 1, "work": 40})
	group = _group(mixed)
	_start(mixed, group)
	mixed.advance(5.0)
	_check(mixed.work_count(0) == 40 and is_equal_approx(mixed.group_transfer_progress(group), 0.5), "leader changes capacity, not the shared ten-second cycle")
	mixed.advance(15.0)
	var mixed_events := _transfers(mixed)
	_check(mixed_events.size() == 2 and mixed_events[0].ids.size() == 4 and mixed_events[1].ids.size() == 4, "employee plus grinder plus leader transfers four per ten seconds")
	_check(mixed.money(0) == 0, "grinder transfer does not trigger its work income multiplier")

func _membership_and_pause() -> void:
	var state := _state({"employee": 1, "work": 30})
	var group := _group(state)
	var tool := _start(state, group)
	state.advance(4.0)
	var leader := state.add_card("leader", 0)
	state.move_cards([leader], group)
	_check(is_equal_approx(state.group_transfer_progress(group), 0.4), "joining personnel keeps existing shared progress")
	state.advance(6.0)
	_check(_transfers(state)[0].ids.size() == 3, "joining leader contributes two at the same settlement")
	state.advance(4.0)
	state.move_cards([leader], -1)
	_check(is_equal_approx(state.group_transfer_progress(group), 0.4), "leaving personnel keeps shared progress")
	state.advance(6.0)
	_check(_transfers(state)[0].ids.size() == 1, "departed leader cannot contribute from outside the group")
	var host := state.add_card("leader", 1)
	var meeting := state.add_card("meeting", 1, int(state.cards[host].group))
	state.advance(3.0)
	state.activate(meeting, int(state.cards[host].group), host)
	state.advance(11.0)
	_check(is_equal_approx(state.group_transfer_progress(group), 0.3) and state.cards[tool].paused, "all participants in enemy meeting freeze the shared transfer timer")
	_check(_transfers(state).is_empty(), "paused transfer cannot settle")
	state.advance(1.0)
	state.advance(7.0)
	_check(_transfers(state).size() == 1 and not state.cards[tool].paused, "meeting return resumes the same unfinished cycle")
	var partial := _state({"employee": 2, "leader": 1, "work": 30})
	group = _group(partial)
	_start(partial, group)
	partial.advance(3.0)
	host = partial.add_card("leader", 1)
	meeting = partial.add_card("meeting", 1, int(partial.cards[host].group))
	partial.activate(meeting, int(partial.cards[host].group), host)
	partial.advance(7.0)
	_check(_transfers(partial)[0].ids.size() == 2, "unaffected leader keeps the shared cycle moving and contributes only its own two files")
	partial.advance(10.0)
	_check(_transfers(partial)[0].ids.size() == 4, "returned staff join the current group cycle without separate catch-up settlements")

func _dismantle_and_refill() -> void:
	var state := _state({"employee": 1, "work": 30})
	var group := _group(state)
	state.advance(2.0)
	var tool := _start(state, group)
	state.advance(4.0)
	var same := state.move_cards(state.group_cards(group), -1)
	_check(same == group and is_equal_approx(state.group_transfer_progress(group), 0.4), "whole-stack movement preserves transfer progress")
	state.move_cards([tool], -1)
	_check(state.cards[tool].status == "ready" and state.group_transfer_participants(group).is_empty(), "removing transfer tool releases all transfer assignments")
	_check(is_equal_approx(state.group_work_progress(group), 0.2), "ordinary work resumes its own pre-transfer progress")
	state.advance(1.0)
	state.move_cards([tool], group)
	_check(is_zero_approx(state.group_transfer_progress(group)), "rebuilding a dismantled transfer combination starts a new cycle")
	var worker: int = state.group_people(group)[0]
	state.advance(4.0)
	state.move_cards([worker], -1)
	state.advance(3.0)
	_check(is_equal_approx(state.group_transfer_progress(group), 0.4), "temporarily empty workforce cannot advance transfer")
	state.move_cards([worker], group)
	state.advance(6.0)
	_check(_transfers(state).size() == 1, "returning worker continues retained combination progress")
	# An empty local queue can refill while other own work prevents victory.
	var tail := _state({"leader": 1, "work": 1})
	group = _group(tail)
	var spare := tail.add_card("work", 0)
	tool = _start(tail, group)
	tail.advance(10.0)
	_check(tail.cards[tool].status == "ready" and tail.group_work(group).is_empty(), "empty queue becomes ready with no recovery timer")
	tail.add_card("work", 0)
	tail.move_cards([spare], group)
	_check(tail.cards[tool].status == "active", "refilling the same stack automatically resumes transfer")
	tail.advance(10.0)
	_check(tail.group_work(group).is_empty() and tail.work_count(0) == 1, "refilled combination settles normally")
	# Direct deliveries, such as opposing transfers, do not call move_cards.
	tail.add_card("work", 0, group)
	tail.advance(4.0)
	_check(tail.cards[tool].status == "active" and is_equal_approx(tail.group_transfer_progress(group), 0.4), "a previously used combination also resumes after direct work delivery")

func _tail_and_config() -> void:
	var state := _state({"leader": 2, "work": 3})
	var group := _group(state)
	_start(state, group)
	state.advance(10.0)
	var events := _transfers(state)
	_check(events.size() == 1 and events[0].ids.size() == 3 and state.winner == 0, "short final batch transfers only remaining work and wins immediately")
	var configured := _state({"leader": 1, "work": 30})
	configured.config.rules.transfer.seconds = 8.0
	configured.config.roles.leader.transfer_capacity = 3
	group = _group(configured)
	_start(configured, group)
	configured.advance(16.0)
	_check(configured.work_count(0) == 24 and _transfers(configured).size() == 2, "cycle length and role output both come from configuration")
	configured.config.roles.leader.transfer_capacity = 1.5
	_check(not configured.config.validate(), "fractional transfer capacity is rejected")

func _frame_independence() -> void:
	var coarse := _state({"employee": 2, "leader": 1, "work": 60})
	var fine := _state({"employee": 2, "leader": 1, "work": 60})
	_start(coarse, _group(coarse))
	_start(fine, _group(fine))
	coarse.advance(32.5)
	for _step in 325: fine.advance(0.1)
	_check(coarse.work_count(0) == fine.work_count(0) and coarse.work_count(0) == 48, "coarse and fine steps produce the same repeated batches")
	_check(is_equal_approx(coarse.group_transfer_progress(_group(coarse)), fine.group_transfer_progress(_group(fine))), "residual shared progress is independent of frame size")
