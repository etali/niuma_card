extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_three_batches_can_split_and_pay()
	_refunds_are_unit_cards()
	for failure in failures: printerr("FAIL ", failure)
	print("UNIT_MONEY_CARDS %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _money_ids(state: WorkState, owner := 0) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].type == "money" and int(state.cards[id].owner) == owner)

func _check_units(state: WorkState, amount: int) -> void:
	var ids := _money_ids(state)
	_check(ids.size() == amount and state.money(0) == amount, "money amount and real card count both equal %d" % amount)
	_check(ids.all(func(id): return int(state.cards[id].amount) == 1), "each real cash card is independently worth one")

func _three_batches_can_split_and_pay() -> void:
	var config := WorkConfig.new()
	config.rules.initial.money = 0
	config.rules.initial.groups = [{"employee": 3, "work": 30}]
	var state := WorkState.new(config)
	state.new_game(93)
	state.drain_events()
	state.advance(30.0)
	var incomes := state.drain_events().filter(func(event): return event.kind == "work_complete" and event.owner == 0)
	_check(incomes.size() == 3, "three group cycles still emit exactly three shared settlements")
	var cash: Array = []
	for event in incomes:
		_check(event.amount == 3 and event.money_ids.size() == 3 and event.money_id == event.money_ids[0], "each batch reports its three real cash cards and compatible first UID")
		_check(event.money_ids.all(func(id): return not cash.has(id)), "new batches never reuse already credited UIDs")
		cash.append_array(event.money_ids)
	_check_units(state, 9)
	var bank: int = state.cards[cash[0]].group
	_check(state.group_cards(bank) == cash, "three payouts form one nine-card pile, never three amount-wallet cards")
	var production: int = incomes[0].group
	for person in state.group_people(production): state.move_cards([person], -1)
	var split: Array = cash.slice(0, 3)
	var split_group := state.move_cards(split, -1)
	_check(state.group_cards(split_group) == split and state.group_cards(bank).size() == 6, "three exact card UIDs split away from the nine-card cash pile")
	state.offers[0].price = 4
	var unchanged: Dictionary = state.cards.duplicate(true)
	_check(state.buy(state.offers[0].id, 0, split) < 0 and state.cards == unchanged, "three selected money cards cannot pay four or borrow from the other six")
	state.offers[0].price = 2
	_check(state.buy(state.offers[0].id, 0, split) >= 0, "two-money purchase succeeds from the selected three-card pile")
	_check(not state.cards.has(split[0]) and not state.cards.has(split[1]) and state.cards.has(split[2]), "purchase removes exactly two real cards and preserves the remaining UID")
	_check_units(state, 7)
	var outsourced_work: Array = state.group_work(production).slice(0, 2)
	var tool := state.add_card("outsource", 0)
	var batch_group: int = state.cards[tool].group
	var payment: Array = [split[2], cash[3], cash[4]]
	state.move_cards(payment + outsourced_work, batch_group)
	_check(state.outsourcing.has(tool) and state.reserved_money(0) == 2, "two work reserve two unit cards in a three-card payment pile")
	_check(state.outsourcing[tool].payments.size() == 2 and state.outsourcing[tool].payments.values().all(func(value): return int(value) == 1), "reservation keeps exact one-money UID entries")
	state.offers[1].price = 2
	var reserved: Dictionary = state.outsourcing[tool].duplicate(true)
	_check(state.buy(state.offers[1].id, 0, payment) < 0 and state.outsourcing[tool] == reserved, "one unreserved card cannot pay two or consume reserved cards")
	_check(state.buy(state.offers[1].id, 0, cash.slice(5, 7)) >= 0 and state.outsourcing[tool] == reserved, "separate unit cards pay normally while the outsource batch remains intact")
	_check_units(state, 5)
	state.advance(4.0)
	var remaining: float = state.cards[tool].remaining
	state.move_cards([state.group_work(production)[0]], batch_group)
	_check(state.reserved_money(0) == 3 and is_equal_approx(state.cards[tool].remaining, remaining), "late work joins the batch using its third unit card without resetting progress")
	state.advance(remaining)
	_check(payment.all(func(id): return not state.cards.has(id)) and state.reserved_money(0) == 0, "one batch consumes the three exact reserved real cards")
	_check_units(state, 2)

func _refunds_are_unit_cards() -> void:
	var config := WorkConfig.new()
	config.rules.initial.money = 0
	config.rules.initial.groups = [{"leader": 1}, {"work": 5}]
	var state := WorkState.new(config)
	state.new_game(95)
	state.drain_events()
	var person: int = state.cards.keys().filter(func(id): return state.cards[id].type == "leader" and state.cards[id].owner == 0)[0]
	_check(state.dismiss_people([person], 0), "leader can be dismissed through the real command")
	var event: Dictionary = state.drain_events().filter(func(item): return item.kind == "fire")[0]
	var refund: int = config.cards.leader.refund
	_check(event.amount == refund and event.money_ids.size() == refund, "one dismissal event reports all configured refund cards")
	_check_units(state, refund)
