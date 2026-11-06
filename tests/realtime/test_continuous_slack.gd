extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_continuous_batches()
	_tool_stacking()
	_dynamic_people()
	_meetings()
	_strike_and_return()
	_split_and_remove_tools()
	_config_and_frame_steps()
	for failure in failures: printerr("FAIL ", failure)
	print("CONTINUOUS_SLACK %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func near(actual: float, expected: float, label: String) -> void:
	check(absf(actual - expected) < 0.00001, "%s: %s versus %s" % [label, actual, expected])

func _state(people := 3, tools := 1, settings: WorkConfig = null) -> WorkState:
	var c := settings if settings != null else WorkConfig.new()
	c.rules.initial.groups = [{"employee": people}, {"work": 200}]
	c.rules.initial.money = 0
	var s := WorkState.new(c)
	s.new_game(20261101)
	check(s.last_error.is_empty(), "fixture is a valid game")
	var group := _group(s)
	for _i in tools:
		var tool := s.add_card("slack", 0)
		check(s.move_cards([tool], group) == group, "stacking slack starts or accelerates production automatically")
	s.drain_events()
	return s

func _group(s: WorkState, owner := 0) -> int:
	for group in s.groups:
		if s.groups[group].owner == owner and not s.group_people(group).is_empty(): return int(group)
	return -1

func _coffees(s: WorkState, owner := 0) -> Array:
	return s.cards.keys().filter(func(id): return s.cards[id].type == "coffee" and s.cards[id].owner == owner)

func _events(s: WorkState) -> Array:
	return s.drain_events().filter(func(e): return e.kind == "slack_complete" and e.owner == 0)

func _continuous_batches() -> void:
	var s := _state(5)
	var group := _group(s)
	var tool: int = s.group_tools(group)[0]
	check(s.groups[group].job == "slack" and s.group_slack_participants(group).size() == 5, "five people share the active slack combination")
	s.advance(7.0)
	near(s.group_slack_progress(group), 0.5, "single shared clock reaches halfway")
	for person in s.group_people(group): near(s.cards[person].progress, 0.5, "all participants project the same clock")
	check(_coffees(s).is_empty(), "no coffee before the batch completes")
	s.advance(7.0)
	var events := _events(s)
	check(events.size() == 1 and events[0].ids.size() == 5 and events[0].participants.size() == 5, "one settlement produces five real coffees in one batch event")
	check(events[0].coffee_ids == events[0].ids and events[0].coffee_id == events[0].ids[0], "event offers full batch and first-coffee compatibility")
	for id in events[0].coffee_ids:
		check(s.cards[id].group != group and s.group_cards(s.cards[id].group).all(func(member): return s.cards[member].type == "coffee"), "coffee goes to an independent pure coffee stack")
		check(s.cards[id].status == "ready" and is_zero_approx(s.cards[id].remaining) and is_zero_approx(s.cards[id].total), "new coffee is ready immediately with no additional timer")
	near(s.group_slack_progress(group), 0.0, "next cycle starts immediately at zero")
	check(s.cards[tool].status == "active" and s.group_slack_participants(group).size() == 5, "tool has no recovery gap and personnel keep producing")
	check(s.money(0) == 0 and s.work_count(0) == 200, "free coffee production does not consume work or cash")
	s.advance(14.0)
	check(_events(s).size() == 1 and _coffees(s).size() == 10, "second batch completes without another activation")
	check(s.activate(tool, group), "repeated activation is idempotent")
	near(s.group_slack_progress(group), 0.0, "repeated activation grants no extra progress")
	s.advance(28.0)
	check(_events(s).size() == 2 and _coffees(s).size() == 20, "multiple later cycles keep producing")

func _tool_stacking() -> void:
	var s := _state(2)
	var group := _group(s)
	s.advance(7.0)
	var second := s.add_card("slack", 0)
	s.move_cards([second], group)
	near(s.group_slack_progress(group), 0.5, "adding a second tool retains progress")
	near(s.group_slack_rate(group), 1.2 / 14.0, "second tool multiplies speed by 1.2")
	for tool in s.group_tools(group): near(s.cards[tool].remaining, 7.0 / 1.2, "all tools expose updated remaining time")
	var third := s.add_card("slack", 0)
	s.move_cards([third], group)
	near(s.group_slack_rate(group), 1.44 / 14.0, "third tool stacks multiplicatively")
	s.advance(7.0 / 1.44)
	check(_coffees(s).size() == 2 and _events(s).size() == 1, "faster cycle still produces one coffee per person")
	s.advance(3.0)
	var progress := s.group_slack_progress(group)
	s.move_cards([second], -1)
	near(s.group_slack_progress(group), progress, "removing one tool keeps the current progress")
	near(s.group_slack_rate(group), 1.2 / 14.0, "removing a tool removes exactly its multiplier")
	check(s.cards[second].status == "ready", "a tool moved to an empty group waits idle")
	var overtime := s.add_card("overtime", 0)
	s.move_cards([overtime], group)
	near(s.group_slack_rate(group), 1.2 / 14.0, "overtime does not silently accelerate coffee production")

func _dynamic_people() -> void:
	var s := _state(2)
	var group := _group(s)
	s.advance(7.0)
	var joiner := s.add_card("leader", 0)
	s.move_cards([joiner], group)
	near(s.cards[joiner].progress, 0.5, "mid-batch leader joins the existing clock")
	s.advance(7.0)
	check(_coffees(s).size() == 3 and _events(s)[0].participants.size() == 3, "new participant joins the next unified settlement")
	s.advance(7.0)
	var people := s.group_people(group)
	var detached := s.move_cards([people[0]], -1)
	near(s.group_slack_progress(group), 0.5, "departing employee does not reset the group")
	s.advance(7.0)
	check(_coffees(s).size() == 5 and _events(s)[0].participants.size() == 2, "departed employee does not produce a phantom coffee")
	s.advance(7.0)
	var remaining := s.group_people(group)
	s.move_cards(remaining, -1)
	near(s.group_slack_progress(group), 0.5, "empty staffed group retains its shared clock")
	check(s.groups[group].job == "slack" and s.group_slack_rate(group) == 0.0 and s.cards[s.group_tools(group)[0]].paused, "unmanned production stays visibly paused")
	s.advance(30.0)
	check(_coffees(s).size() == 5, "unmanned tools cannot produce coffee")
	near(s.group_slack_progress(group), 0.5, "waiting does not advance the unmanned clock")
	s.move_cards([people[0]], group)
	check(s.groups.has(detached) == false, "returning employee removes the now-empty loose group")
	s.advance(7.0)
	check(_coffees(s).size() == 6, "returning employee resumes the unfinished batch")

func _start_enemy_meeting(s: WorkState, leader := false) -> int:
	var host := s.add_card("leader" if leader else "employee", 1)
	var group: int = s.cards[host].group
	var meeting := s.add_card("meeting", 1, group)
	check(s.activate(meeting, group, host), "opponent can start a meeting while employees slack")
	return meeting

func _meetings() -> void:
	var s := _state(5)
	var group := _group(s)
	s.advance(7.0)
	var meeting := _start_enemy_meeting(s)
	check(s.meetings[meeting].targets.size() == 2 and s.group_slack_participants(group).size() == 3, "meeting removes only its two attendees from output")
	s.advance(7.0)
	check(_coffees(s).size() == 3 and _events(s)[0].participants.size() == 3, "only present coworkers produce this batch")
	s.advance(5.0)
	check(not s.meetings.has(meeting) and s.group_slack_participants(group).size() == 5, "meeting attendees return to the active slack combination")
	near(s.group_slack_progress(group), 5.0 / 14.0, "meeting return does not reset the next shared batch")
	s = _state(3)
	group = _group(s)
	s.advance(7.0)
	meeting = _start_enemy_meeting(s, true)
	check(s.group_slack_participants(group).is_empty(), "leader can pull every eligible slacker")
	s.advance(11.0)
	near(s.group_slack_progress(group), 0.5, "all participants absent freezes progress")
	check(_coffees(s).is_empty() and s.cards[s.group_tools(group)[0]].paused, "fully absent team makes no coffee and exposes paused tool")
	s.advance(1.0)
	check(s.group_slack_participants(group).size() == 3, "all return when meeting ends")
	s.advance(7.0)
	check(_coffees(s).size() == 3, "returned team completes the preserved half-batch")
	s = _state(2)
	group = _group(s)
	var leader := s.add_card("leader", 0)
	s.move_cards([leader], group)
	meeting = _start_enemy_meeting(s, true)
	check(not s.meetings[meeting].targets.has(leader) and s.group_slack_participants(group) == [leader], "slacking leaders retain their meeting immunity")

func _strike_and_return() -> void:
	var s := _state(3)
	var group := _group(s)
	s.advance(7.0)
	check(s.group_work(group).is_empty() and s.can_strike_group(group, 1), "active coffee group is a valid strike target without work cards")
	var people := s.group_people(group)
	var strike := s.add_card("strike", 1)
	check(s.activate(strike, group), "strike hits the slacking combination")
	check(not s.cards.has(strike) and s.group_people(group).is_empty(), "successful strike consumes card and ejects all present personnel")
	for person in people: check(s.is_striking(person) and s.cards[person].group != group, "ejected person dances in a separate group")
	near(s.group_slack_progress(group), 0.5, "strike retains the interrupted group clock")
	check(not s.can_strike_group(group, 1), "unmanned coffee group cannot be struck again")
	s.advance(20.0)
	check(_coffees(s).is_empty() and people.all(func(person): return not s.is_striking(person)), "strike period produces nothing and ends normally")
	s.move_cards(people, group)
	s.advance(7.0)
	check(_coffees(s).size() == 3, "returned staff resumes production after strike")

func _split_and_remove_tools() -> void:
	var s := _state(3, 2)
	var group := _group(s)
	s.advance(14.0 / 1.2 * 0.4)
	var people := s.group_people(group)
	var tools := s.group_tools(group)
	var split := s.move_cards([people[0], tools[0]], -1)
	near(s.group_slack_progress(group), 0.4, "split source retains its shared progress")
	near(s.group_slack_progress(split), 0.4, "staff and tool moved together carry the same unfinished work")
	near(s.group_slack_rate(group), 1.0 / 14.0, "split removes one source speed multiplier")
	near(s.group_slack_rate(split), 1.0 / 14.0, "split group has one base-speed tool")
	check(s.move_cards(s.group_cards(split), -1) == split, "moving complete combination preserves identity")
	near(s.group_slack_progress(split), 0.4, "moving complete combination keeps its clock")
	s.move_cards([tools[1]], -1)
	check(s.groups[group].job == "work" and not s.groups[group].has("slack_progress"), "removing the last tool ends the coffee job")
	check(not s.tasks.has(people[1]) and s.group_slack_rate(group) == 0.0, "no invisible coffee task survives removing the tool")

func _config_and_frame_steps() -> void:
	var c := WorkConfig.new()
	c.rules.slack.seconds = 9.0
	c.rules.slack.speed_multiplier = 1.5
	c.rules.slack.coffee_per_person = 2
	var s := _state(3, 3, c)
	var group := _group(s)
	near(s.group_slack_rate(group), 2.25 / 9.0, "stacked rate reads custom configuration")
	s.advance(4.0)
	check(_coffees(s).size() == 6 and _events(s)[0].ids.size() == 6, "configured per-person output settles as one batch")
	var coarse := _state(4, 2)
	var fine := _state(4, 2)
	coarse.advance(53.0)
	for _i in 530: fine.advance(0.1)
	check(_coffees(coarse).size() == _coffees(fine).size(), "coarse and fine simulation steps produce the same coffee count")
	near(coarse.group_slack_progress(_group(coarse)), fine.group_slack_progress(_group(fine)), "coarse and fine steps retain equal partial progress")
	check(_events(coarse).size() == _events(fine).size(), "frame size does not duplicate batch events")
	for field in ["speed_multiplier", "coffee_per_person"]:
		var invalid := WorkConfig.new()
		invalid.rules.slack[field] = 0
		check(not invalid.validate(), "configuration rejects invalid slack " + field)
