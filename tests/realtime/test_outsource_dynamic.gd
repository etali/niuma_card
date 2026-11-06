extends "res://tests/realtime/test_outsource_batch.gd"

func _run() -> void:
	_auto_start_and_recover()
	_wait_for_real_materials()
	_partial_refills_and_purchases()
	_new_reservation_cancellation()
	_configured_fee_and_two_tools()
	_refill_clock_independence()
	_winning_last_moment_refill()
	for failure in failures: printerr("FAIL ", failure)
	print("OUTSOURCE_DYNAMIC ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _auto_start_and_recover() -> void:
	for owner in [0, 1]:
		var f := _fixture(24, [156])
		var state: WorkState = f.state
		if owner == 1:
			state.groups[f.group].owner = owner
			for id in state.group_cards(f.group): state.cards[id].owner = owner
		var money_before := state.money(owner)
		var works_before := state.work_count(owner)
		state.advance(0.25)
		_check(state.outsourcing.has(f.tool) and state.cards[f.tool].status == "active", "ready 24-work 156-money stack automatically reads on both sides")
		_check(state.outsourcing[f.tool].amount == 24 and is_equal_approx(float(state.cards[f.tool].remaining), 9.75), "automatic start reserves all affordable work and advances immediately")
		state.advance(9.75)
		_check(state.work_count(owner) == works_before - 24 and state.money(owner) == money_before - 24, "automatic batch charges and clears exactly once")
		_check(state.cards[f.tool].status == "recovering" and is_equal_approx(float(state.cards[f.tool].remaining), 18.0), "completion retains configured eighteen-second recovery")
		var additions: Array = []
		for i in 6: additions.append(state.add_card("work", owner))
		state.move_cards(additions, f.group)
		_check(not state.outsourcing.has(f.tool) and state.reserved_money(owner) == 0, "new ingredients do not skip recovery or prematurely reserve money")
		state.advance(17.99)
		_check(state.cards[f.tool].status == "recovering", "tool cannot restart before cooldown completes")
		state.advance(0.01)
		_check(state.cards[f.tool].status == "active" and state.outsourcing[f.tool].work_ids == additions, "tool restarts at exact recovery boundary with all waiting work")
		_check(is_equal_approx(float(state.cards[f.tool].remaining), 10.0) and is_zero_approx(float(state.cards[f.tool].progress)), "new cycle starts from zero without waiting for an input or frame")
		state.advance(10.0)
		var completed := state.drain_events().filter(func(event): return event.kind == "outsource")
		_check(completed.size() == 2 and is_equal_approx(completed[0].time, 10.0) and is_equal_approx(completed[1].time, 38.0), "two cycles resolve exactly at ten and thirty-eight seconds")
		_check(state.cards[f.cash[0]].amount == 126, "repeated outsourcing never adds income")

func _wait_for_real_materials() -> void:
	var f := _fixture(8, [])
	var state: WorkState = f.state
	state.advance(1.0)
	_check(state.cards[f.tool].status == "ready" and state.outsourcing.is_empty(), "wealthy remote wallet cannot auto-start an unfunded stack")
	var cash := state.add_card("money", 0)
	state.cards[cash].amount = 3
	state.advance(1.0)
	_check(state.outsourcing.is_empty(), "money on the same table but outside combination is not a payment")
	state.move_cards([cash], f.group)
	_check(state.outsourcing[f.tool].amount == 3 and is_zero_approx(float(state.cards[f.tool].progress)), "moving real local payment automatically starts without activate button")
	state.advance(10.0)
	_check(state.cards[f.tool].status == "recovering" and state.group_work(f.group).size() == 5, "insufficient local funds clear only one-to-one matched work")
	state.advance(18.0)
	_check(state.cards[f.tool].status == "ready" and not state.outsourcing.has(f.tool), "recovered tool stays ready if its stack has no currency")
	var funded := state.add_card("money", 0)
	state.cards[funded].amount = 7
	state.move_cards([funded], f.group)
	_check(state.outsourcing[f.tool].amount == 5 and state.available_cash_amount(funded) == 2, "ready tool begins as soon as missing payment arrives")

func _partial_refills_and_purchases() -> void:
	var f := _fixture(4, [7])
	var state: WorkState = f.state
	_start(f)
	var opening_events := state.drain_events()
	var original_start: Dictionary = opening_events.filter(func(event): return event.kind == "outsource_start")[0]
	state.advance(4.0)
	var additions: Array = []
	for i in 5: additions.append(state.add_card("work", 0))
	state.move_cards(additions, f.group)
	_check(state.outsourcing[f.tool].amount == 7 and state.outsourcing[f.tool].work_ids.size() == 7, "work refill extends only as far as existing same-wallet surplus can pay")
	_check(state.reserved_cash_amount(f.cash[0]) == 7 and state.available_cash_amount(f.cash[0]) == 0, "newly included work immediately protects the corresponding money")
	_check(original_start.ids == f.works, "extending live reservation does not mutate previously emitted start event")
	_check(is_equal_approx(float(state.cards[f.tool].progress), 0.4) and is_equal_approx(float(state.cards[f.tool].remaining), 6.0), "partial refill preserves displayed forty-percent progress")
	var snapshot: Dictionary = state.outsourcing[f.tool].duplicate(true)
	var offer: Dictionary = state.offers[0].duplicate()
	_check(state.buy(offer.id, 0, f.cash) < 0 and state.outsourcing[f.tool] == snapshot, "purchase cannot steal dynamically reserved same-wallet surplus")
	_check(state.buy(offer.id, 0) >= 0 and state.outsourcing[f.tool] == snapshot, "outside wallet purchase leaves expanded batch untouched")
	var extra_cash := state.add_card("money", 0)
	state.cards[extra_cash].amount = 10
	state.move_cards([extra_cash], f.group)
	_check(state.outsourcing[f.tool].amount == 9 and state.outsourcing[f.tool].payments[extra_cash] == 2, "cash refill includes waiting work in the same batch")
	_check(state.available_cash_amount(extra_cash) == 8 and is_equal_approx(float(state.cards[f.tool].remaining), 6.0), "only matching amount is reserved and cash refill does not reset time")
	snapshot = state.outsourcing[f.tool].duplicate(true)
	_check(state._spend(0, 8, [extra_cash]) and state.cards[extra_cash].amount == 2 and state.outsourcing[f.tool] == snapshot, "all true surplus remains spendable without disturbing added reservations")
	var removed: int = additions.back()
	_check(state.outsourcing[f.tool].work_ids.has(removed), "previously unmatched late work becomes truly reserved after cash refill")
	var before_money := state.money(0)
	var before_work := state.work_count(0)
	state.advance(5.999)
	_check(state.work_count(0) == before_work and state.money(0) == before_money, "expanded batch pays nothing before original deadline")
	state.advance(0.001)
	_check(state.work_count(0) == before_work - 9 and state.money(0) == before_money - 9, "all initial and later matched work settle together at original deadline")
	_check(not state.cards.has(f.cash[0]) and not state.cards.has(extra_cash), "each dynamically reserved payment identity is consumed exactly once")
	var events := state.drain_events().filter(func(event): return event.kind.begins_with("outsource"))
	_check(events.size() == 1 and events[0].kind == "outsource" and events[0].ids.size() == 9 and events[0].spent == 9, "refill emits no false start or cancel and one accurate final settlement")

func _new_reservation_cancellation() -> void:
	for kind in ["work", "cash"]:
		var f := _fixture(2, [2])
		var state: WorkState = f.state
		_start(f)
		state.advance(6.0)
		var work := state.add_card("work", 0)
		var cash := state.add_card("money", 0)
		state.cards[cash].amount = 1
		state.move_cards([work, cash], f.group)
		_check(state.outsourcing[f.tool].amount == 3 and is_equal_approx(float(state.cards[f.tool].remaining), 4.0), "new ingredients are added to old deadline before split")
		state.move_cards([work if kind == "work" else cash], -1)
		_check(state.outsourcing[f.tool].amount == 2 and is_equal_approx(float(state.cards[f.tool].remaining), 10.0), "splitting newly reserved " + kind + " cancels original clock and restarts valid remainder")
		state.advance(4.0)
		_check(state.work_count(0) == 23, "cancelled original deadline never clears any work")
		state.advance(6.0)
		_check(state.work_count(0) == 21, "replacement batch consumes only remaining affordable work at fresh deadline")

func _configured_fee_and_two_tools() -> void:
	var f := _fixture(5, [5])
	var state: WorkState = f.state
	state.config.rules.outsource.cost_per_work = 2
	state.advance(1.0)
	_check(state.outsourcing[f.tool].amount == 4 and state.outsourcing[f.tool].work_ids.size() == 2, "automatic batch honors configured fee instead of hardcoded one")
	var second := state.add_card("outsource", 0, f.group)
	var cash := state.add_card("money", 0)
	state.cards[cash].amount = 5
	state.move_cards([cash], f.group)
	_check(state.outsourcing.size() == 1 and state.cards[second].status == "ready", "two tools cannot claim the same combination or money simultaneously")
	_check(state.outsourcing[f.tool].amount == 10 and state.outsourcing[f.tool].work_ids.size() == 5, "extension respects configured two-currency fee across wallets")
	var before := state.money(0)
	state.advance(9.0)
	_check(state.group_work(f.group).is_empty() and state.money(0) == before - 10, "configured fee is debited once for every extended work identity")

func _refill_clock_independence() -> void:
	var a := _fixture(5, [3])
	var b := _fixture(5, [3])
	for f in [a, b]:
		var state: WorkState = f.state
		if f == a: state.advance(3.0)
		else:
			for i in 30: state.advance(0.1)
		var cash := state.add_card("money", 0)
		state.cards[cash].amount = 10
		state.move_cards([cash], f.group)
		if f == a: state.advance(12.0)
		else:
			for i in 120: state.advance(0.1)
		var new_work: Array = []
		for i in 3: new_work.append(state.add_card("work", 0))
		state.move_cards(new_work, f.group)
		if f == a: state.advance(25.0)
		else:
			for i in 250: state.advance(0.1)
	var coarse: WorkState = a.state
	var fine: WorkState = b.state
	_check(coarse.work_count(0) == fine.work_count(0) and coarse.money(0) == fine.money(0), "coarse and fine advancement agree across refill, recovery and restart")
	_check(coarse.work_count(0) == 20 and coarse.money(0) == 105, "two real cycles clear five plus three work with no income")
	_check(coarse.cards[a.tool].status == fine.cards[b.tool].status and is_equal_approx(float(coarse.cards[a.tool].remaining), float(fine.cards[b.tool].remaining)), "coarse and fine recovery timers agree after second cycle")
	var events_a := coarse.drain_events()
	var events_b := fine.drain_events()
	_check(events_a.size() == events_b.size(), "event count is stable across all automatic transitions")
	for index in mini(events_a.size(), events_b.size()):
		_check(is_equal_approx(events_a[index].time, events_b[index].time), "refill and recovery events retain exact causal time")
		events_a[index].erase("time")
		events_b[index].erase("time")
	_check(events_a == events_b, "all event identities and payloads are frame independent")

func _winning_last_moment_refill() -> void:
	var f := _fixture(0, [100])
	var state: WorkState = f.state
	var work: Array = state.cards.keys().filter(func(id): return state.cards[id].type == "work" and state.cards[id].owner == 0)
	state.move_cards(work.slice(0, 10), f.group)
	state.advance(9.999)
	state.move_cards(work.slice(10), f.group)
	_check(state.outsourcing[f.tool].amount == 20 and is_equal_approx(float(state.cards[f.tool].remaining), 0.001), "last-moment refill includes every remaining work without delaying completion")
	_check(state.winner == -1 and state.work_count(0) == 20, "refill never consumes or declares victory before deadline")
	state.advance(0.001)
	_check(state.winner == 0 and is_equal_approx(state.time, 10.0) and state.work_count(0) == 0, "expanded final batch wins exactly at the original deadline")
	_check(state.cards[f.cash[0]].amount == 80, "winning late refill pays actual complete amount")
