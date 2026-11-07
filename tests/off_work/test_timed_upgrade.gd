extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_upgrade_clock()
	_split_and_move()
	_pause_and_cooldown()
	_no_market_grinder()
	_frame_independence()
	for failure in failures: printerr("FAIL ", failure)
	print("TIMED_UPGRADE %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 1, "work": 200}]
	config.rules.initial.money = 100
	var result := OffWorkState.new(config)
	result.new_game(41)
	return result

func person(s: OffWorkState, owner := 0) -> int:
	for id in s.cards:
		if s.cards[id].type == "employee" and int(s.cards[id].owner) == owner: return int(id)
	return -1

func drink(s: OffWorkState, p: int) -> int:
	var c := s.add_card("coffee", int(s.cards[p].owner))
	s.move_cards([p, c])
	return c

func _upgrade_clock() -> void:
	var s := state()
	var p := person(s)
	s.advance(2.0)
	var original: Dictionary = s.tasks[p].duplicate(true)
	var c := drink(s, p)
	var duration: float = s.config.number("coffee", "seconds")
	check(s.cards[p].type == "employee" and s.cards.has(c), "start neither transforms person nor consumes coffee")
	check(s.tasks[p].kind == "coffee" and s.cards[c].status == "active" and s.cards[c].remaining == duration, "real timed coffee task owns material")
	check(s.cards[p].progress == 0.0 and s.cards[c].progress == 0.0, "upgrade bars begin at zero rather than prior work progress")
	var extra := s.add_card("coffee", 0, s.cards[p].group)
	check(not s.activate(extra, s.cards[p].group, p) and s.cards[extra].status == "ready", "second cup cannot take an already upgrading employee")
	s.advance(duration * 0.5)
	check(is_equal_approx(s.cards[p].progress, 0.5) and is_equal_approx(s.cards[c].progress, 0.5), "person and coffee expose the same real half progress")
	check(is_equal_approx(s.cards[original.work_id].progress, 0.2) and s.tasks[p].work_id == -1, "separate drink leaves original work unreserved with its progress intact")
	s.advance(duration * 0.5 - 0.001)
	check(s.cards[p].type == "employee" and s.cards.has(c), "before deadline coffee remains and person is not yet grinder")
	s.advance(0.001)
	check(s.cards[p].type == "grinder" and not s.cards.has(c), "deadline consumes exactly one cup and changes same personnel UID")
	check(not s.tasks.has(p) and is_equal_approx(s.cards[original.work_id].progress, 0.2), "completed drink stays in its own group and leaves original work intact")
	var events := s.drain_events().filter(func(e): return e.kind == "coffee_upgrade")
	check(events.size() == 1 and events[0].person == p and events[0].source == c, "only completion emits stable-ID upgrade event")
	check(not s.activate(extra, s.cards[p].group, p) and s.cards.has(extra), "one spare cup is insufficient for the grinder two-cup upgrade")
	s.move_cards([p], original.group)
	s.advance(1.0)
	check(is_equal_approx(s.cards[original.work_id].progress, 0.3), "ordinary work resumes from preserved progress")

func _split_and_move() -> void:
	var s := state()
	var p := person(s)
	s.advance(1.0)
	var work: int = s.tasks[p].work_id
	var c := drink(s, p)
	s.advance(2.0)
	var old_group: int = s.cards[p].group
	var moved := s.move_cards([p, c], s.create_group(0))
	check(moved != old_group and s.tasks[p].group == moved and is_equal_approx(s.cards[c].progress, 0.4), "moving the intact pair retains timed progress")
	check(s.tasks[p].work_id == -1 and s.tasks[p].resume_task.is_empty(), "paired move releases work left in a different group")
	s.move_cards([c], -1)
	check(s.cards[c].status == "ready" and s.cards[c].progress == 0.0 and not s.tasks.has(p), "splitting the pair cancels its timer without consuming material")
	check(s.cards[p].type == "employee" and is_equal_approx(s.cards[work].progress, 0.1), "cancel neither upgrades nor loses saved work progress")
	s.advance(10.0)
	check(s.cards[p].type == "employee" and s.cards.has(c), "cancel has no delayed upgrade callback")
	check(not s.activate(c, s.cards[p].group, p), "remote coffee activation cannot upgrade a different group")
	s.move_cards([c], s.cards[p].group, p)
	check(s.cards[c].status == "active" and s.cards[c].progress == 0.0, "reforming the pair starts a fresh drink")
	s.advance(1.0)
	var before := s.money(0)
	check(s.dismiss_people([p], 0), "upgrading employee can be dismissed at employee refund")
	check(s.money(0) == before + int(s.config.cards.employee.refund) and s.cards[c].status == "ready", "dismiss refunds current role and frees unconsumed coffee")
	s.advance(10.0)
	check(not s.cards.has(p) and s.cards.has(c), "dismissal cannot resurrect a grinder")
	var claimed := state()
	var cp := person(claimed)
	var reserved: int = claimed.tasks[cp].work_id
	var workplace: int = claimed.cards[cp].group
	var cc := drink(claimed, cp)
	var coworker := claimed.add_card("employee", 0, workplace)
	claimed.advance(1.0)
	check(claimed.tasks[coworker].work_id == reserved and is_equal_approx(claimed.cards[reserved].progress, 0.1), "drinking does not reserve a group work slot away from the active colleague")
	claimed.move_cards([cc], -1)
	claimed.move_cards([cp], workplace)
	check(claimed.tasks[cp].kind == "work" and claimed.tasks[cp].group == workplace and claimed.tasks[coworker].work_id == reserved
		and is_equal_approx(claimed.cards[cp].progress, 0.1), "returning after cancellation joins shared progress without stealing the colleague work slot")

func _pause_and_cooldown() -> void:
	var s := state()
	var p := person(s, 1)
	var c := drink(s, p)
	s.advance(1.0)
	var host := person(s)
	var m := s.add_card("meeting", 0, s.cards[host].group)
	check(s.activate(m, s.cards[host].group, host), "meeting can target the drinking employee")
	check(s.cards[p].paused and s.cards[c].paused, "coffee and employee expose pause while attending")
	var value: float = s.cards[c].progress
	var duration: float = s.config.number("meeting", "duration_seconds")
	s.advance(duration * 0.5)
	check(s.cards[c].progress == value and s.cards[p].type == "employee", "meeting freezes upgrading rather than completing it")
	check(s.cards[m].status == "active" and is_equal_approx(s.cards[m].progress, 0.5), "meeting card itself exposes active progress")
	check(not s.activate(m, s.cards[host].group), "active meeting cannot be restarted")
	s.advance(duration * 0.5)
	check(not s.meetings.has(m) and not s.cards[p].paused and not s.cards[c].paused, "full active bar ends meeting and releases upgraded task")
	check(s.cards[m].status == "recovering" and s.cards[m].progress == 0.0 and s.cards[m].remaining == s.config.number("meeting", "recovery_seconds"), "meeting enters an independent zero-to-full cooldown")
	check(not s.activate(m, s.cards[host].group), "cooling meeting cannot run")
	var cooldown: float = s.config.number("meeting", "recovery_seconds")
	s.advance(cooldown * 0.5)
	check(s.cards[p].type == "grinder" and not s.cards.has(c), "coffee continues only after meeting ends")
	check(s.cards[m].status == "recovering" and is_equal_approx(s.cards[m].progress, 0.5), "cooldown bar follows real remaining time")
	s.advance(cooldown * 0.5)
	check(s.cards[m].status == "active" and s.meetings.has(m), "cooldown completion automatically starts the next meeting")
	check(not s.activate(m, s.cards[host].group), "automatic meeting cannot be started twice")

func _no_market_grinder() -> void:
	var s := state()
	check(not s.config.can_purchase("grinder") and not s.config.rules.conveyor.pool.has("grinder"), "grinder is absent from purchasable cards and pool")
	var offer := s._make_offer("grinder")
	s.offers[0] = offer
	var before := s.money(0)
	check(s.buy(offer.id, 0) < 0 and s.money(0) == before, "forged grinder offer is rejected before payment")
	for i in range(100): check(s._new_offer().type != "grinder", "weighted supply never creates grinder")
	var config := OffWorkConfig.new()
	config.rules.conveyor.pool.grinder = 1
	check(not config.validate(), "configuration rejects grinder in conveyor pool")
	config = OffWorkConfig.new()
	config.rules.conveyor.opening[0] = "grinder"
	check(not config.validate(), "configuration rejects grinder in opening")
	config = OffWorkConfig.new()
	config.rules.coffee.seconds = 0
	check(not config.validate(), "instant upgrade duration is rejected")
	config = OffWorkConfig.new()
	config.cards.grinder.purchasable = true
	check(not config.validate() and not config.can_purchase("grinder"), "purchase flag cannot bypass upgrade-only grinder rule")
	var tuned := state()
	tuned.config.rules.coffee.seconds = 2.0
	var employee := person(tuned)
	var cup := drink(tuned, employee)
	tuned.advance(1.0)
	check(is_equal_approx(tuned.cards[cup].progress, 0.5) and tuned.cards[employee].type == "employee", "configured upgrade duration changes actual progress")
	tuned.advance(1.0)
	check(tuned.cards[employee].type == "grinder" and not tuned.cards.has(cup), "configured two-second task completes at two seconds")

func _frame_independence() -> void:
	var coarse := state()
	var fine := state()
	drink(coarse, person(coarse))
	drink(fine, person(fine))
	coarse.advance(16.0)
	for i in range(160): fine.advance(0.1)
	check(coarse.work_count(0) == fine.work_count(0) and coarse.money(0) == fine.money(0), "large and small clock steps agree across upgrade completion")
	var p := person(coarse, 1)
	check(coarse.cards[p].type == fine.cards[p].type, "unrelated personnel remain consistent across clock steps")
	var bot_state := state()
	var bp := person(bot_state)
	var bc := bot_state.add_card("coffee", 0)
	bot_state.config.rules.bot.buy_chance = 0.0
	# Give the promotion a real production benefit in this cash-rich fixture,
	# so the public BOT chooses it when comparing against continued work.
	bot_state.config.roles.grinder.work_capacity = 2
	var bot := OffWorkBot.new(bot_state, 0)
	bot.start()
	bot.advance(0.0)
	check(bot_state.cards[bc].group == bot_state.cards[bp].group and bot_state.tasks[bp].kind == "coffee", "BOT combines coffee and employee through ordinary move action")
	bot_state.advance(bot_state.config.number("coffee", "seconds"))
	check(bot_state.cards[bp].type == "grinder" and not bot_state.cards.has(bc), "BOT waits for full upgrade task")
