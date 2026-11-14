extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_configuration_and_limit()
	_batch_and_refill()
	_cancellation_and_wallet()
	_immunities_and_coworkers()
	_clock_fork_and_allocation()
	_net_capacity_unit_money()
	_net_capacity_nonmonotone_and_refill()
	_net_capacity_other_reservations()
	_net_capacity_shared_wallet()
	_single_batch_allocation_limit()
	_capacity_enumeration_oracle()
	for failure in failures: printerr("FAIL ", failure)
	print("OFF_WORK_BOSS_RULES %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 40}, {"employee": 1}]
	config.rules.initial.money = 0
	var s := OffWorkState.new(config)
	s.new_game(57)
	return s

func ids(s: OffWorkState, kind: String, owner := 0) -> Array:
	return s.cards.keys().filter(func(id): return s.cards[id].type == kind and s.cards[id].owner == owner)

func wallet(s: OffWorkState, amount: int, owner := 0) -> int:
	var id := s.add_card("money", owner)
	s.cards[id].amount = amount
	return id

func start(s: OffWorkState, amount: int, owner := 0) -> Dictionary:
	var boss := s.add_card("boss", owner)
	var cash := wallet(s, amount, owner)
	s.move_cards([cash], s.cards[boss].group)
	return {"boss": boss, "cash": cash, "group": int(s.cards[boss].group)}

func _configuration_and_limit() -> void:
	var cfg := OffWorkConfig.new()
	check(cfg.validate() and cfg.cards.boss.price == 12 and cfg.cards.boss.refund == 6, "boss has configurable purchasing and refund values")
	cfg.rules.initial.groups = [{"work": 40, "employee": 1, "boss": 1}, {"boss": 1}]
	check(not cfg.validate(), "initial boss count is checked across all stacks")
	cfg = OffWorkConfig.new()
	cfg.rules.recruitment.cost_per_employee = 0
	check(not cfg.validate(), "free recruitment is rejected")
	cfg = OffWorkConfig.new()
	cfg.rules.recruitment.cost_per_employee = cfg.cards.employee.price
	check(not cfg.validate(), "recruitment must cost more per employee than the market")
	cfg = OffWorkConfig.new()
	cfg.cards.employee.price = 6
	check(not cfg.validate(), "raising market price requires updating recruitment price too")
	cfg = OffWorkConfig.new()
	cfg.roles.erase("boss")
	check(not cfg.validate(), "missing boss roles fail validation without accessing an absent object")
	var s := state()
	var first := s.add_card("boss", 0)
	check(s.add_card("boss", 0) == -1 and s.add_card("boss", 1) > 0, "one boss per side is enforced for direct creation")
	wallet(s, 100)
	var offer := s._make_offer("boss")
	s.offers[0] = offer
	var funds := s.money(0)
	check(s.buy(offer.id, 0) == -1 and s.money(0) == funds and s.offers[0] == offer, "duplicate boss purchase does not spend money or remove the offer")
	s.dismiss_people([first], 0)
	check(s.buy(offer.id, 0) >= 0, "dismissal allows a later boss purchase")

func _batch_and_refill() -> void:
	var s := state()
	var setup := start(s, 21)
	check(s.recruitment[setup.boss].count == 4 and s.reserved_money(0) == 20 and s.available_money(0) == 1, "21 money reserves exactly four employees and leaves one spendable")
	check(s.cards[setup.boss].activity == "recruitment" and s.cards[setup.boss].status == "active" and s.cards[setup.boss].remaining == 10.0, "boss publishes recruitment activity and timer")
	s.advance(4.0)
	check(is_equal_approx(s.cards[setup.boss].progress, 0.4) and ids(s, "employee").size() == 1, "batch cannot produce employees before completion")
	var additional := wallet(s, 5)
	s.move_cards([additional], setup.group)
	check(s.recruitment[setup.boss].count == 5 and is_equal_approx(s.recruitment[setup.boss].remaining, 6.0), "mid-batch cash adds employees without restarting the clock")
	s.advance(6.0)
	check(ids(s, "employee").size() == 6 and s.money(0) == 1 and s.reserved_money(0) == 0, "completion spends five configured payments once and keeps remainder")
	check(not s.recruitment.has(setup.boss) and s.cards[setup.boss].status == "ready" and is_zero_approx(s.cards[setup.boss].progress), "boss returns to idle when remainder cannot fund another employee")
	var completed := s.drain_events().filter(func(event): return event.kind == "recruitment_complete")
	check(completed.size() == 1 and completed[0].person_ids.size() == 5 and completed[0].spent == 25, "completion event identifies every spawned employee and payment")
	check(completed[0].person_group != setup.group and s.group_cards(completed[0].person_group) == completed[0].person_ids, "new employees form one separate stack")
	var refill := wallet(s, 4)
	s.move_cards([refill], setup.group)
	check(s.recruitment[setup.boss].count == 1 and s.cards[setup.boss].progress == 0.0, "old remainder and new funds start a new full batch")

func _cancellation_and_wallet() -> void:
	var s := state()
	var setup := start(s, 21)
	check(not s._spend(0, 2) and s.money(0) == 21, "reserved recruitment money cannot be spent on other purchases")
	check(s._spend(0, 1) and s.money(0) == 20 and s.recruitment[setup.boss].count == 4, "unreserved part of the same cash card stays spendable")
	s.advance(3.0)
	s.move_cards([setup.cash])
	check(s.recruitment.is_empty() and s.money(0) == 20 and s.reserved_money(0) == 0, "moving reserved money cancels without charging")
	check(s.cards[setup.boss].status == "ready" and s.cards[setup.boss].remaining == 0.0, "cancelled boss timer is cleared")
	s.advance(12.0)
	check(ids(s, "employee").size() == 1, "cancelled callbacks cannot recruit later")
	s.move_cards([setup.cash], setup.group)
	s.dismiss_people([setup.boss], 0)
	check(s.recruitment.is_empty() and s.money(0) == 26 and ids(s, "boss").is_empty(), "dismissing a recruiting boss releases all funds and pays its own refund")
	var shared := state()
	setup = start(shared, 21)
	var work: int = ids(shared, "work")[0]
	shared.move_cards([work], setup.group)
	var outsource := shared.add_card("outsource", 0, setup.group)
	shared.activate(outsource)
	check(shared.outsourcing[outsource].amount == 1 and shared.reserved_money(0) == 21, "outsourcing and recruitment cannot reserve the same cash twice")
	shared.advance(10.0)
	check(shared.money(0) == 0 and shared.work_count(0) == 39 and ids(shared, "employee").size() == 5, "shared cash reservations settle independently without underpayment")

func _immunities_and_coworkers() -> void:
	var s := state()
	var setup := start(s, 20, 1)
	var employee := int(ids(s, "employee", 1)[0])
	var work: int = ids(s, "work", 1)[0]
	s.move_cards([employee, work], setup.group)
	var host := s.add_card("leader", 0)
	var meeting := s.add_card("meeting", 0, s.cards[host].group)
	check(not s.meeting_candidates(0).has(setup.boss) and s.meeting_candidates(0).has(employee), "boss meeting immunity does not protect its coworker")
	check(not s.can_person_be_struck(setup.boss) and s.can_person_be_struck(employee), "boss strike immunity is individual")
	var attack := s.add_card("strike", 0)
	s.activate(attack, setup.group)
	s.advance(1.2)
	check(s.is_striking(employee) and not s.is_striking(setup.boss) and s.recruitment.has(setup.boss), "strike ejects coworkers while boss recruitment continues")
	check(not s.can_strike_group(setup.group, 0), "boss alone cannot be attacked after coworkers leave")
	s.activate(meeting)
	check(not s.is_meeting_target(setup.boss), "boss remains immune when another meeting begins")
	s.advance(8.8)
	check(ids(s, "employee", 1).size() == 5, "individual immunity does not disturb the recruitment deadline")

func _clock_fork_and_allocation() -> void:
	var coarse := state()
	var setup := start(coarse, 21)
	coarse.advance(2.0)
	var branch := coarse.fork_for_bot(77)
	check(branch.recruitment == coarse.recruitment, "search fork preserves batch reservations and deadline")
	branch.advance(8.0)
	check(ids(branch, "employee").size() == 5 and ids(coarse, "employee").size() == 1, "fork completion cannot spend or spawn in live state")
	var fine := state()
	start(fine, 21)
	coarse.advance(8.0)
	for i in 100: fine.advance(0.1)
	check(ids(coarse, "employee").size() == ids(fine, "employee").size() and coarse.money(0) == fine.money(0), "coarse and fine clocks recruit identical batches")
	var capped := state()
	var boss := capped.add_card("boss", 0)
	var cash := wallet(capped, 1000000)
	while capped.cards.size() < OffWorkConfig.MAX_CARD_ALLOCATION - 2: capped.add_card("employee", 0)
	capped.move_cards([cash], capped.cards[boss].group)
	check(capped.recruitment[boss].count == 2, "cash cannot reserve employees beyond global card allocation capacity")
	capped.advance(10.0)
	check(capped.cards.size() == OffWorkConfig.MAX_CARD_ALLOCATION and capped.money(0) == 999990 and capped.recruitment.is_empty(), "allocation guard caps real spawns and charges only produced employees")

func unit_cash(s: OffWorkState, count: int, owner := 0) -> Array:
	var group := s.create_group(owner)
	var result: Array = []
	for _index in count: result.append(s.add_card("money", owner, group))
	return result

func pad_cards(s: OffWorkState, total: int) -> void:
	var group := s.create_group(1)
	while s.cards.size() < total: s.add_card("work", 1, group)

func _net_capacity_unit_money() -> void:
	for total in [4096, 4101]:
		var s := state()
		var boss := s.add_card("boss", 0)
		var cash := unit_cash(s, 5)
		pad_cards(s, total)
		s.move_cards(cash, int(s.cards[boss].group))
		check(s.recruitment.has(boss) and s.recruitment[boss].count == 1,
			"unit cash reserves a shrinking transaction at or above the guard %d" % total)
		s.advance(10.0)
		check(s.cards.size() == total - 4 and ids(s, "employee").size() == 2 and s.money(0) == 0,
			"five real cash UIDs become one employee even if the world remains above 4096 %d" % total)
		check(s.drain_events().filter(func(event): return event.kind == "recruitment_cancel").is_empty(),
			"shrinking transaction is not reported as cancelled %d" % total)
	# Match the shape of the observed 2000-work failure without replaying a BOT.
	var grown := state()
	var boss := grown.add_card("boss", 0)
	var cash := unit_cash(grown, 120)
	grown.move_cards(cash, int(grown.cards[boss].group))
	pad_cards(grown, 4099)
	grown.advance(10.0)
	check(grown.cards.size() == 4003 and ids(grown, "employee").size() == 25 and grown.money(0) == 0,
		"completion rechecks actual payment deletion: 4099 minus120 plus24 equals4003")

func _net_capacity_nonmonotone_and_refill() -> void:
	var s := state()
	var boss := s.add_card("boss", 0)
	var large := wallet(s, 6)
	var cash := [large] + unit_cash(s, 4)
	pad_cards(s, 4096)
	s.move_cards(cash, int(s.cards[boss].group))
	check(s.recruitment.has(boss) and s.recruitment[boss].count == 2 and s.recruitment[boss].payments[large] == 6,
		"six-plus-four is nonmonotone: one employee grows the world but two free five UIDs")
	s.advance(10.0)
	check(s.cards.size() == 4093 and s.money(0) == 0 and ids(s, "employee").size() == 3,
		"largest feasible nonmonotone payment is charged exactly once")

	var refill := state()
	var setup := start(refill, 6)
	refill.advance(4.0)
	var added := unit_cash(refill, 4)
	pad_cards(refill, 4100)
	refill.move_cards(added, setup.group)
	check(refill.recruitment[setup.boss].count == 2 and refill.recruitment[setup.boss].payments[setup.cash] == 6
		and is_equal_approx(refill.recruitment[setup.boss].remaining, 6.0),
		"refill combines previous payment with new cash and does not restart the ten-second clock")
	refill.advance(6.0)
	check(refill.cards.size() == 4097 and refill.money(0) == 0 and ids(refill, "employee").size() == 3,
		"over-limit refill reduces4100 to4097 without requiring one transaction to reach4096")

func _net_capacity_other_reservations() -> void:
	var s := state()
	var boss0 := s.add_card("boss", 0)
	var boss1 := s.add_card("boss", 1)
	var cash0 := wallet(s, 1000000, 0)
	var cash1 := wallet(s, 1000000, 1)
	pad_cards(s, 4094)
	s.move_cards([cash0], int(s.cards[boss0].group))
	s.move_cards([cash1], int(s.cards[boss1].group))
	check(s.recruitment[boss0].count == 2 and not s.recruitment.has(boss1),
		"two bosses cannot reserve the same positive global growth allowance")
	s.move_cards([cash0])
	check(not s.recruitment.has(boss0) and s.recruitment[boss1].count == 2 and s.money(0) == 1000000,
		"cancellation releases positive reservation without spending its cash")
	s.advance(10.0)
	check(s.cards.size() == 4096 and s.money(1) == 999990, "remaining positive batch reaches but does not exceed the guard")

	var shrinking := state()
	boss0 = shrinking.add_card("boss", 0)
	boss1 = shrinking.add_card("boss", 1)
	var units := unit_cash(shrinking, 10)
	cash1 = wallet(shrinking, 1000000, 1)
	pad_cards(shrinking, 4096)
	shrinking.move_cards(units, int(shrinking.cards[boss0].group))
	shrinking.move_cards([cash1], int(shrinking.cards[boss1].group))
	check(shrinking.recruitment[boss0].count == 2 and not shrinking.recruitment.has(boss1),
		"a pending shrinking batch does not lend its future deletion to another boss")
	shrinking.advance(10.0)
	check(shrinking.cards.size() == 4088 and shrinking.recruitment[boss1].count == 8
		and is_equal_approx(shrinking.recruitment[boss1].remaining, 10.0),
		"only actual settlement releases eight slots for a fresh later batch")

func _net_capacity_shared_wallet() -> void:
	var s := state()
	var setup := start(s, 6)
	var work: int = ids(s, "work")[0]
	s.move_cards([work], setup.group)
	var tool := s.add_card("outsource", 0, setup.group)
	check(s.activate(tool), "shared-wallet outsourcing reserves its own remaining one money")
	pad_cards(s, 4096)
	check(s.reserved_cash_amount(setup.cash) == 6 and s._recruitment_net_growth(1, s.recruitment[setup.boss].payments) == 1,
		"other batch's reserved remainder does not make this partial payment free a wallet UID")
	s.advance(10.0)
	check(s.cards.size() == 4095 and s.money(0) == 0 and ids(s, "employee").size() == 2
		and s.work_count(0) == 39, "actual earlier outsourcing settlement makes the remaining recruitment payment exact")

	var blocked := state()
	setup = start(blocked, 6)
	pad_cards(blocked, 4096)
	blocked.advance(10.0)
	var cancelled := blocked.drain_events().filter(func(event): return event.kind == "recruitment_cancel")
	check(blocked.cards.size() == 4096 and blocked.money(0) == 6 and ids(blocked, "employee").size() == 1
		and cancelled.size() == 1 and cancelled[0].spent == 0,
		"external growth still cancels a genuinely growing partial-wallet batch atomically")

func _single_batch_allocation_limit() -> void:
	var s := state()
	var boss := s.add_card("boss", 0)
	var group := s.create_group(0)
	var wallets: Array = []
	for _index in 4097:
		var id := s.add_card("money", 0, group)
		s.cards[id].amount = 5
		wallets.append(id)
	var before := s.cards.size()
	s.move_cards(wallets, int(s.cards[boss].group))
	check(s.recruitment[boss].count == 4096 and s.reserved_money(0) == 20480,
		"net-neutral over-limit payments still cannot allocate more than4096 employees in one batch")
	s.advance(1.0)
	check(s.recruitment[boss].count == 4096 and is_equal_approx(s.recruitment[boss].remaining, 9.0),
		"repeated refill does not evade the single-batch allocation limit")
	s.advance(9.0)
	var completed := s.drain_events().filter(func(event): return event.kind == "recruitment_complete")
	check(completed.size() == 1 and completed[0].count == 4096 and completed[0].spent == 20480
		and s.cards.size() == before and s.money(0) == 5 and s.recruitment[boss].count == 1,
		"bounded completion deletes payment UIDs before spawning and leaves the remainder for a new batch")
	var malformed := state()
	var setup := start(malformed, 5)
	malformed.recruitment[setup.boss].count = 4097
	malformed._complete_recruitment(setup.boss)
	check(malformed.recruitment.is_empty() and malformed.money(0) == 5 and ids(malformed, "employee").size() == 1,
		"imported oversized batch is cancelled before payment or allocation")

func _capacity_enumeration_oracle() -> void:
	# Independent small oracle: rebuild each candidate payment from scratch and
	# count physical survivors. Do not reuse the production threshold scanner.
	var cases := [
		{"amounts":[6,1,1,1,1], "own":[0,0,0,0,0], "other":[0,0,0,0,0], "count":0},
		{"amounts":[6,1,1,1,1], "own":[5,0,0,0,0], "other":[0,0,0,0,0], "count":1},
		{"amounts":[11,3,2,7], "own":[5,0,0,0], "other":[1,0,0,0], "count":1},
		{"amounts":[5,5,1,9], "own":[5,0,0,0], "other":[0,1,0,0], "count":1},
		{"amounts":[21,4,1], "own":[10,0,0], "other":[1,0,0], "count":2},
	]
	for spec in cases:
		for headroom in [-3, 0, 2]:
			for other_growth in [0, 2]:
				var s := state()
				if other_growth > 0: start(s, other_growth * 5 + 1, 1)
				var boss := s.add_card("boss", 0)
				var group := int(s.cards[boss].group)
				var cash: Array = []
				var own: Dictionary = {}
				var other: Dictionary = {}
				var funds := 0
				for index in spec.amounts.size():
					var id := s.add_card("money", 0, group)
					s.cards[id].amount = spec.amounts[index]
					cash.append(id)
					if spec.own[index] > 0: own[id] = spec.own[index]
					if spec.other[index] > 0: other[id] = spec.other[index]
					funds += spec.amounts[index] - spec.own[index] - spec.other[index]
				if spec.count > 0: s.recruitment[boss] = {"count":spec.count, "payments":own, "group":group}
				if not other.is_empty(): s.outsourcing[-1] = {"payments":other}
				pad_cards(s, 4096 - headroom)
				var best := 0
				var expected: Dictionary = {}
				for candidate in range(1, funds / 5 + 1):
					var remaining := candidate * 5
					var proposed: Dictionary = {}
					var survivors := s.cards.size()
					for index in cash.size():
						var spend := mini(remaining, spec.amounts[index] - spec.own[index] - spec.other[index])
						if spend > 0: proposed[cash[index]] = spend
						remaining -= spend
						if spec.own[index] + spend == spec.amounts[index]: survivors -= 1
					if survivors + spec.count + candidate <= s.cards.size() + maxi(0, headroom - other_growth):
						best = candidate
						expected = proposed
				var actual := s._recruitment_additions(group, boss)
				check(actual.count == best and actual.payments == expected and actual.amount == best * 5,
					"enumerated payment/survivor oracle matches amounts%s own%s other%s headroom%d reservation%d" %
					[spec.amounts, spec.own, spec.other, headroom, other_growth])
