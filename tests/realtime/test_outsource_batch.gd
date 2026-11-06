extends SceneTree
## Rule acceptance for durable, timed outsourcing paid only by the same stack.
class ClockDriver:
	extends Node
	var state: WorkState
	func _process(delta: float) -> void: state.advance(delta)

var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	_defaults()
	_amounts_and_time()
	_invalid_groups()
	_refilled_batch_and_whole_move()
	_cancellations()
	_spending_reserved_cash()
	_multiple_reservations()
	_bot_uses_surplus()
	_frame_independence()
	_winning_batch()
	await _pause_resume()
	for failure in failures: printerr("FAIL ", failure)
	print("OUTSOURCE_BATCH ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)

func _defaults() -> void:
	var config := WorkConfig.new()
	_check(config.validate(), "shipped outsourcing configuration validates")
	_check(is_equal_approx(config.number("outsource", "seconds"), 10.0), "default outsourced batch reads for ten seconds")
	_check(config.integer("outsource", "cost_per_work") == 1, "one money clears one work")
	_check(not config.rules.outsource.has("max_batch"), "old six-work cap is removed from configuration")

func _fixture(work_count: int, amounts: Array) -> Dictionary:
	var config := WorkConfig.new()
	config.rules.initial.groups = [{"employee": 1}, {"work": 20}]
	config.rules.initial.money = 100
	config.rules.bot.enabled = false
	# These rule cases inspect fixed purchase prices independently of supply cadence.
	config.rules.conveyor.interval_seconds = 100.0
	var state := WorkState.new(config)
	state.new_game(20261031)
	var tool := state.add_card("outsource", 0)
	var group: int = state.cards[tool].group
	var works: Array = []
	for index in work_count: works.append(state.add_card("work", 0, group))
	var cash: Array = []
	for amount in amounts:
		var id := state.add_card("money", 0, group)
		state.cards[id].amount = int(amount)
		cash.append(id)
	state.drain_events()
	return {"state": state, "tool": tool, "group": group, "works": works, "cash": cash}

func _start(f: Dictionary) -> void:
	var state: WorkState = f.state
	_check(state.group_people(f.group).is_empty(), "outsource group has no personnel")
	_check(state.activate(f.tool), "local work and cash start outsourcing")
	_check(state.outsourcing.has(f.tool) and state.cards[f.tool].status == "active", "batch owns durable tool and active timer")
	_check(is_equal_approx(float(state.cards[f.tool].remaining), state.config.number("outsource", "seconds")), "tool timer starts at actual configured duration")

func _amounts_and_time() -> void:
	for pair in [[12, [9]], [3, [10]], [12, [2, 3, 4]]]:
		var f := _fixture(int(pair[0]), pair[1])
		var state: WorkState = f.state
		var cash_amount := 0
		for amount in pair[1]: cash_amount += int(amount)
		var matched := mini(int(pair[0]), cash_amount)
		var money_before := state.money(0)
		var work_before := state.work_count(0)
		_start(f)
		var batch: Dictionary = state.outsourcing[f.tool].duplicate(true)
		_check(batch.work_ids.size() == matched and int(batch.amount) == matched, "batch matches amount rather than number of money cards")
		_check(batch.payments.size() <= f.cash.size(), "reservation uses only local money identities")
		var reserved := 0
		for id in batch.payments:
			reserved += int(batch.payments[id])
			_check(f.cash.has(id) and int(state.cards[id].group) == f.group, "each reserved payment belongs to the stack")
		_check(reserved == matched, "reserved currency exactly equals matched workload")
		_check(state.money(0) == money_before and state.work_count(0) == work_before, "starting reserves without paying or consuming early")
		state.advance(5.0)
		_check(state.money(0) == money_before and state.work_count(0) == work_before, "half progress consumes neither money nor work")
		_check(is_equal_approx(float(state.cards[f.tool].progress), 0.5) and is_equal_approx(float(state.cards[f.tool].remaining), 5.0), "tool exposes the actual half timer")
		state.advance(4.99)
		_check(state.outsourcing.has(f.tool) and state.work_count(0) == work_before, "batch cannot settle before full progress")
		state.advance(0.01)
		_check(not state.outsourcing.has(f.tool) and state.cards.has(f.tool), "finished batch releases its reservation and retains tool")
		_check(state.money(0) == money_before - matched and state.work_count(0) == work_before - matched, "full timer pays and clears the entire matched batch together")
		for id in batch.work_ids: _check(not state.cards.has(id), "only reserved work is consumed")
		_check(state.group_work(f.group).size() == int(pair[0]) - matched, "unmatched work stays in the original group")
		var events := state.drain_events()
		var completed := events.filter(func(event): return event.kind == "outsource")
		_check(completed.size() == 1, "one timer emits exactly one outsourced completion")
		if completed.size() == 1:
			_check(completed[0].ids == batch.work_ids and int(completed[0].amount) == matched and int(completed[0].spent) == matched, "completion event records exact batch work and actual fee")
		_check(events.all(func(event): return event.kind not in ["work_complete", "bonus"]), "outsourcing produces no employee or bonus income")
		state.advance(1.0)
		_check(state.drain_events().all(func(event): return event.kind != "outsource"), "finished batch cannot settle twice")

func _invalid_groups() -> void:
	for pair in [[5, []], [0, [8]], [0, []], [5, [0]]]:
		var f := _fixture(pair[0], pair[1])
		var state: WorkState = f.state
		var before := JSON.stringify(state.cards)
		_check(not state.activate(f.tool), "missing local money or work rejects outsourcing")
		_check(not state.outsourcing.has(f.tool) and state.cards[f.tool].status == "ready" and JSON.stringify(state.cards) == before, "invalid combination is atomic despite wealthy outside wallet")
	var f := _fixture(5, [5])
	var state: WorkState = f.state
	var remote := state.create_group(0)
	state.add_card("work", 0, remote)
	var cash := state.add_card("money", 0, remote)
	state.cards[cash].amount = 8
	_check(not state.activate(f.tool, remote), "tool cannot remotely outsource another friendly stack")
	var opponent: int = state.cards.keys().filter(func(id): return state.cards[id].type == "work" and int(state.cards[id].owner) == 1)[0]
	_check(not state.activate(f.tool, int(state.cards[opponent].group)), "tool cannot use opponent work or money")

func _refilled_batch_and_whole_move() -> void:
	var f := _fixture(7, [4])
	var state: WorkState = f.state
	_start(f)
	var original: Dictionary = state.outsourcing[f.tool].duplicate(true)
	state.advance(3.0)
	var tool_remaining: float = state.cards[f.tool].remaining
	var old_group: int = f.group
	_check(state.move_cards(state.group_cards(old_group), -1) == old_group, "moving intact stack keeps its original group identity")
	_check(state.outsourcing[f.tool].work_ids == original.work_ids and is_equal_approx(float(state.cards[f.tool].remaining), tool_remaining), "whole-stack movement keeps reservation and progress")
	var new_work := state.add_card("work", 0)
	var extra_cash := state.add_card("money", 0)
	state.cards[extra_cash].amount = 20
	state.move_cards([new_work, extra_cash], f.group)
	_check(state.outsourcing[f.tool].work_ids.size() == 8 and state.outsourcing[f.tool].work_ids.has(new_work), "new cash and work enlarge the reading to include all affordable work")
	_check(state.outsourcing[f.tool].payments[f.cash[0]] == 4 and state.outsourcing[f.tool].payments[extra_cash] == 4, "extension retains original reservations and reserves only the additional fee")
	_check(is_equal_approx(float(state.cards[f.tool].remaining), tool_remaining), "refill preserves current timer")
	var free_cash := state.add_card("money", 0)
	state.cards[free_cash].amount = 9
	state.move_cards([free_cash], f.group)
	state.move_cards([free_cash], -1)
	_check(state.outsourcing.has(f.tool) and is_equal_approx(float(state.cards[f.tool].remaining), tool_remaining), "removing fully unreserved additions keeps the batch and its deadline")
	var money_before := state.money(0)
	state.advance(7.0)
	_check(not state.cards.has(new_work) and state.cards[extra_cash].amount == 16 and state.money(0) == money_before - 8, "extended batch settles all matched work together at original deadline")

func _cancellations() -> void:
	for category in ["tool", "work", "cash"]:
		var f := _fixture(8, [5])
		var state: WorkState = f.state
		_start(f)
		state.advance(4.0)
		var work_before := state.work_count(0)
		var money_before := state.money(0)
		var id: int = f.tool if category == "tool" else (f.works[0] if category == "work" else f.cash[0])
		_check(state.move_cards([id], -1) >= 0, "moving reserved " + category + " is an allowed split")
		if category == "work":
			_check(state.outsourcing.has(f.tool) and is_equal_approx(float(state.cards[f.tool].remaining), 10.0) and is_zero_approx(float(state.cards[f.tool].progress)), "remaining valid ingredients restart a fresh timer after reserved work is removed")
			_check(state.outsourcing[f.tool].work_ids.size() == 5 and not state.outsourcing[f.tool].work_ids.has(id), "fresh reservation excludes detached work and replaces it from remaining stack")
			_check(state.money(0) == money_before and state.work_count(0) == work_before, "cancelling and restarting do not consume ingredients early")
			var events := state.drain_events()
			_check(events.filter(func(event): return event.kind == "outsource_cancel").size() == 1 and events.filter(func(event): return event.kind == "outsource_start").size() == 2, "split emits exactly one cancellation and one fresh restart")
			state.advance(6.0)
			_check(state.money(0) == money_before and state.work_count(0) == work_before, "cancelled old deadline cannot settle the new batch")
			state.advance(4.0)
			_check(state.money(0) == money_before - 5 and state.work_count(0) == work_before - 5 and state.cards.has(id), "fresh batch settles only at its own complete reading and leaves detached work")
			continue
		_check(not state.outsourcing.has(f.tool) and state.cards[f.tool].status == "ready", "moving reserved " + category + " cancels immediately")
		_check(is_zero_approx(float(state.cards[f.tool].remaining)) and is_zero_approx(float(state.cards[f.tool].progress)), "cancelled tool clears its old timer")
		_check(state.work_count(0) == work_before and state.money(0) == money_before, "cancelled " + category + " split consumes no resource")
		state.advance(20.0)
		_check(state.work_count(0) == work_before and state.money(0) == money_before, "old cancelled timer cannot settle later")
		_check(state.drain_events().all(func(event): return event.kind != "outsource"), "cancel never emits successful outsourced completion")
		_check(state.move_cards([id], f.group) >= 0 and state.outsourcing.has(f.tool), "recombining cancelled ingredients starts a fresh batch")
		_check(is_zero_approx(float(state.cards[f.tool].progress)), "new combination reads again from zero")

func _spending_reserved_cash() -> void:
	var f := _fixture(8, [8])
	var state: WorkState = f.state
	_start(f)
	state.advance(4.0)
	var work_before := state.work_count(0)
	var money_before := state.money(0)
	var original: Dictionary = state.outsourcing[f.tool].duplicate(true)
	var cards_before := state.cards.duplicate(true)
	var offers_before := state.offers.duplicate(true)
	var offer: Dictionary = state.offers[0].duplicate()
	_check(state.reserved_cash_amount(f.cash[0]) == 8 and state.available_cash_amount(f.cash[0]) == 0, "reserved wallet exposes zero spendable amount")
	_check(state.reserved_money(0) == 8 and state.available_money(0) == 100 and state.money(0) == 108, "available and reserved amounts sum to actual total")
	_check(state.buy(int(offer.id), 0, [f.cash[0]]) < 0, "explicit reserved wallet cannot fund a purchase")
	_check(state.last_error.contains("外包") and state.last_error.contains("预留"), "rejected reserved payment explains the unavailable funds")
	_check(state.cards == cards_before and state.offers == offers_before and state.outsourcing[f.tool] == original, "rejected purchase is atomic and leaves exact outsource timer untouched")
	_check(state.buy(int(offer.id), 0) >= 0, "normal purchasing uses another unreserved wallet")
	_check(state.cards[f.cash[0]].amount == 8 and state.outsourcing[f.tool] == original and state.cards[f.tool].status == "active", "successful purchase never disturbs reserved cash or reading progress")
	_check(state.work_count(0) == work_before and state.money(0) == money_before - int(offer.price), "purchase removes only its real price")
	state.advance(6.0)
	_check(state.work_count(0) == work_before - 8 and state.money(0) == money_before - int(offer.price) - 8, "outsourcing still settles its entire original batch at the original deadline")
	_check(state.reserved_money(0) == 0 and state.available_money(0) == state.money(0), "successful settlement releases reservation without making free money")
	_check(state.drain_events().all(func(event): return event.kind != "outsource_cancel"), "purchasing never emits an outsource cancellation")
	# There is no fallback into another wallet when explicit payment is selected.
	f = _fixture(4, [10])
	state = f.state
	_start(f)
	state.advance(3.0)
	original = state.outsourcing[f.tool].duplicate(true)
	offer = state.offers[0].duplicate()
	_check(state.available_cash_amount(f.cash[0]) == 6 and state.reserved_cash_amount(f.cash[0]) == 4, "surplus in the same cash card remains available")
	_check(state.buy(int(offer.id), 0, [f.cash[0]]) >= 0, "a real purchase can spend surplus in an outsourcing wallet")
	_check(state.outsourcing[f.tool] == original and int(state.cards[f.cash[0]].amount) == 6, "surplus purchase keeps four reserved currency and original progress")
	var next_offer: Dictionary = state.offers[1].duplicate()
	_check(state.buy(int(next_offer.id), 0, [f.cash[0]]) < 0, "insufficient surplus cannot silently borrow from the outside wallet")
	_check(state.outsourcing[f.tool] == original and int(state.cards[f.cash[0]].amount) == 6, "failed second purchase changes neither funds nor timer")
	state.advance(7.0)
	_check(state.cards.has(f.cash[0]) and int(state.cards[f.cash[0]].amount) == 2, "completion debits exactly reserved amount from surviving cash identity")
	# Ordinary price-tag purchase must also refuse when every coin is reserved.
	f = _fixture(8, [8])
	state = f.state
	for id in state.cards.keys():
		if state.cards[id].owner == 0 and state.cards[id].type == "money" and not f.cash.has(id): state._consume(id)
	_start(f)
	state.advance(2.0)
	original = state.outsourcing[f.tool].duplicate(true)
	offer = state.offers[0].duplicate()
	_check(state.money(0) == 8 and state.available_money(0) == 0, "a visibly nonempty wallet may be entirely reserved")
	_check(state.buy(int(offer.id), 0) < 0 and state.outsourcing[f.tool] == original, "price-tag purchase with no free funds cannot interrupt outsourcing")
	state.advance(8.0)
	_check(state.money(0) == 0 and state.work_count(0) == 20, "protected last funds pay the entire batch once")
	f = _fixture(0, [])
	state = f.state
	_check(not state._spend(0, state.money(0) + 1) and not state.last_error.contains("预留"), "ordinary insufficient funds do not invent a reservation explanation")
	# Multiple selected wallets can spend each free part without consuming any
	# protected cash entity, even when it appears first in payment order.
	f = _fixture(5, [6, 4])
	state = f.state
	_start(f)
	_check(state._spend(0, 4, f.cash), "split-wallet payment uses available portions")
	_check(state.cards[f.cash[0]].amount == 5 and state.cards[f.cash[1]].amount == 1 and state.reserved_money(0) == 5, "payment preserves protected identity and subtracts only surplus")
	var snapshot := state.cards.duplicate(true)
	_check(not state._spend(0, 1, [f.cash[1], f.cash[1]]) and state.cards == snapshot, "duplicate payment identities cannot duplicate surplus")
	state.advance(10.0)
	_check(not state.cards.has(f.cash[0]) and state.cards[f.cash[1]].amount == 1, "batch spends the protected wallet exactly once and leaves other surplus")

func _multiple_reservations() -> void:
	var f := _fixture(6, [6])
	var state: WorkState = f.state
	_start(f)
	var duplicate_tool := state.add_card("outsource", 0, f.group)
	_check(not state.activate(duplicate_tool) and state.reserved_money(0) == 6, "a second tool cannot reserve the same running group twice")
	var tool := state.add_card("outsource", 0)
	var group: int = state.cards[tool].group
	for index in 5: state.add_card("work", 0, group)
	var cash := state.add_card("money", 0, group)
	state.cards[cash].amount = 5
	_check(state.activate(tool) and state.reserved_money(0) == 11 and state.available_money(0) == 100, "independent batches reserve disjoint funds")
	state.advance(4.0)
	var before: Dictionary = state.outsourcing.duplicate(true)
	var offer: Dictionary = state.offers[0].duplicate()
	_check(state.buy(int(offer.id), 0) >= 0 and state.outsourcing == before, "normal purchase preserves all simultaneous batches")
	_check(state.move_cards([cash], -1) >= 0 and not state.outsourcing.has(tool) and state.outsourcing.has(f.tool), "intentional split cancels only the affected reservation")
	_check(state.reserved_money(0) == 6 and state.available_cash_amount(cash) == 5, "dismantling releases funds for later purchases")
	state.advance(6.0)
	_check(state.reserved_money(0) == 0 and not state.cards.has(f.cash[0]) and state.cards[cash].amount == 5, "remaining batch completes without touching released funds")

func _bot_uses_surplus() -> void:
	var f := _fixture(4, [10])
	var state: WorkState = f.state
	for id in state.cards.keys():
		if state.cards[id].owner == 0 and state.cards[id].type == "money" and not f.cash.has(id): state._consume(id)
	_start(f)
	state.advance(3.0)
	state.config.rules.bot.buy_chance = 1.0
	state.config.rules.bot.min_reserve = 0
	state.config.rules.bot.purchase_priority = ["employee"]
	state.config.rules.bot.enabled = true
	state.config.rules.bot.think_seconds = 0.2
	var bot := WorkBot.new(state, 0)
	bot.start()
	var payments: Dictionary = state.outsourcing[f.tool].payments.duplicate()
	var bought := false
	for i in 5:
		bot.advance(0.0)
		if bot.last_decision.kind == "buy" and bot.last_decision.applied:
			bought = true
			break
		state.advance(bot.next_action_time() - state.time)
	_check(bought and state.outsourcing.has(f.tool), "BOT can buy an employee without dismantling an active outsource job")
	_check(state.outsourcing[f.tool].payments == payments, "BOT leaves reserved wallets attached to their batch")
	_check(state.available_cash_amount(f.cash[0]) == 2 and state.reserved_cash_amount(f.cash[0]) == 4, "BOT spends wallet surplus with the same accounting as the player")

func _frame_independence() -> void:
	var a := _fixture(12, [9])
	var b := _fixture(12, [9])
	_start(a)
	_start(b)
	var coarse: WorkState = a.state
	var fine: WorkState = b.state
	coarse.advance(9.9)
	for i in 99: fine.advance(0.1)
	_check(coarse.work_count(0) == fine.work_count(0) and coarse.money(0) == fine.money(0), "coarse and fine clocks reserve equal resources before boundary")
	_check(is_equal_approx(float(coarse.cards[a.tool].remaining), float(fine.cards[b.tool].remaining)), "coarse and fine clocks expose equal true remaining time")
	coarse.advance(0.1)
	fine.advance(0.1)
	_check(coarse.work_count(0) == fine.work_count(0) and coarse.money(0) == fine.money(0), "coarse and fine clocks settle identical work and cost")
	var coarse_events := coarse.drain_events()
	var fine_events := fine.drain_events()
	_check(coarse_events.size() == fine_events.size(), "frame size does not change number of emitted events")
	for index in mini(coarse_events.size(), fine_events.size()):
		_check(is_equal_approx(float(coarse_events[index].time), float(fine_events[index].time)), "event boundary time is independent of frame size")
		coarse_events[index].erase("time")
		fine_events[index].erase("time")
	_check(coarse_events == fine_events, "frame size does not change outsourced completion payloads")

func _winning_batch() -> void:
	var f := _fixture(0, [20])
	var state: WorkState = f.state
	var works: Array = state.cards.keys().filter(func(id): return state.cards[id].type == "work" and int(state.cards[id].owner) == 0)
	_check(state.move_cards(works, f.group) >= 0 and state.outsourcing.has(f.tool), "combining all remaining work starts twenty-work batch")
	state.advance(9.99)
	_check(state.winner == -1 and state.work_count(0) == 20, "outsourcing cannot win before its progress completes")
	state.advance(0.01)
	_check(state.winner == 0 and state.work_count(0) == 0 and is_equal_approx(state.time, 10.0), "batch clearing final work wins exactly at completion")
	_check(state.cards.has(f.tool) and state.money(0) == 100, "winner retains durable tool and pays only local twenty currency")
	var before: float = state.time
	state.advance(100.0)
	_check(state.time == before, "completed match stops before any later events")

func _pause_resume() -> void:
	var f := _fixture(8, [8])
	var state: WorkState = f.state
	_start(f)
	state.advance(3.0)
	var driver := ClockDriver.new()
	driver.state = state
	driver.process_mode = Node.PROCESS_MODE_PAUSABLE
	root.add_child(driver)
	var before: float = state.time
	var remaining: float = state.cards[f.tool].remaining
	paused = true
	await create_timer(0.08, true).timeout
	_check(state.time == before and state.cards[f.tool].remaining == remaining, "SceneTree pause freezes outsourcing clock and reservation")
	paused = false
	await create_timer(0.08, true).timeout
	_check(state.time > before and state.cards[f.tool].remaining < remaining and state.outsourcing.has(f.tool), "resume advances the same batch without reset or hidden catch-up")
	driver.queue_free()
	await process_frame

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
