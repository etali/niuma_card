extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_configuration_and_limit()
	_batch_and_refill()
	_cancellation_and_wallet()
	_immunities_and_coworkers()
	_clock_fork_and_allocation()
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
