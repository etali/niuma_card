# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

const Catalog = preload("res://engine/tutorial_catalog.gd")
const Progress = preload("res://engine/tutorial_progress.gd")
var lesson: Dictionary
var step := 0
var last_feedback := ""
var used_demo := false
var _source_group := -1
var _extract_workers: Array = []
var _extract_materials: Array = []
var _meeting_tool := -1
var _transfer_tool := -1
var _transfer_group := -1
var _transfer_workers: Array = []

static func courses() -> Array:
	return Catalog.data().off_work_courses

func start(id: String) -> bool:
	for item in courses():
		if item.id == id:
			lesson = item
			step = 0
			last_feedback = ""
			used_demo = false
			_source_group = -1
			_extract_workers.clear()
			_extract_materials.clear()
			_meeting_tool = -1
			_transfer_tool = -1
			_transfer_group = -1
			_transfer_workers.clear()
			Progress.record(id, 0, "started", true)
			return true
	return false

func make_config() -> OffWorkConfig:
	var config := OffWorkConfig.new()
	if lesson.id == "solo":
		for group in config.rules.initial.groups:
			if group.has("work"):
				group.work = int(lesson.starting_work)
				break
		return config
	config.rules.bot.enabled = false
	config.rules.conveyor.interval_seconds = 60.0
	config.rules.initial.groups = [{"work": 12}, {"employee": 1}]
	config.rules.initial.money = int(config.cards.employee.price) - 1
	config.roles.employee.work_seconds = 2.0
	match lesson.id:
		"first":
			config.rules.conveyor.opening.fill("employee")
			config.rules.conveyor.employee_every = 1
		"extract":
			config.rules.initial.groups = [{"work":200,"employee":3,"overtime":1}]
		"meeting":
			config.rules.initial.groups = [{"work":40,"employee":1},{"leader":1},{"meeting":1}]
		"transfer":
			config.rules.initial.groups = [{"work":12,"employee":1},{"transfer":1}]
		"overtime":
			config.rules.initial.groups = [{"employee":1,"work":30},{"overtime":1}]
		"upgrade":
			config.rules.initial.groups = [{"work":3,"employee":1},{"coffee":1}]
		"interrupt":
			config.rules.initial.groups.append({"strike":1})
	return config

func setup_world(world: OffWorkState) -> void:
	match lesson.id:
		"extract":
			_extract_workers = world._owner_type(0, "employee").duplicate()
			_source_group = int(world.cards[_extract_workers[0]].group)
			_extract_materials = world.group_cards(_source_group).filter(func(id): return not _extract_workers.has(id))
		"meeting":
			_meeting_tool = int(world._owner_type(0, "meeting")[0])
			_dispatch(world, 1)
		"transfer":
			_transfer_tool = int(world._owner_type(0, "transfer")[0])
			# Keep received files visible until the learner has seen the batch.
			# The demonstration opponent has no live BOT to restaff this pile.
			world.move_cards(workers(world, 1))
		"interrupt":
			_dispatch(world, 1)

func source_group() -> int:
	return _source_group

func extract_ids() -> Array:
	return _extract_workers.duplicate()

func complete() -> bool:
	return not lesson.is_empty() and step == lesson.steps.size()

## Guided input steps wait for the learner. When a timer is the objective,
## let the real clock run only as far as its first settlement in this frame.
func clock_delta(world: OffWorkState, delta: float) -> float:
	if lesson.id == "solo": return delta
	if complete(): return 0.0
	var target: String = lesson.steps[step][0]
	# Cancelling a meeting invokes the real recovery rule. Stop at the end
	# of that wait so reading the renewed instruction cannot run the match.
	if target == "meeting_start" and world.cards.has(_meeting_tool):
		var tool: Dictionary = world.cards[_meeting_tool]
		if tool.status == "recovering": return minf(delta, float(tool.remaining))
	if target == "meeting_income" and not _meeting_running(world): return 0.0
	var first := INF
	for id in world.tasks:
		if world.cards[id].owner != 0: continue
		var task: Dictionary = world.tasks[id]
		if target in ["income", "own_income", "overtime_income", "meeting_income", "transfer_resume"] and task.kind == "work":
			if target == "overtime_income" and world._group_type(task.group, "overtime").is_empty(): continue
			if target == "transfer_resume" and (not _transfer_workers.has(id) or not world._group_type(task.group, "transfer").is_empty()): continue
			var rate := world.group_work_rate(task.group)
			if rate > 0: first = minf(first, (1.0 - world.group_work_progress(task.group)) / rate)
		if target == "transfer_sent" and task.kind == "transfer" and int(task.tool_id) == _transfer_tool:
			var rate := world.group_transfer_rate(task.group)
			if rate > 0: first = minf(first, (1.0 - world.group_transfer_progress(task.group)) / rate)
		if target in ["coffee", "upgrade"] and task.kind == "coffee":
			first = minf(first, float(task.total) * (1.0 - float(task.progress)))
	return minf(delta, maxf(0.000001, first)) if is_finite(first) else 0.0

func observe(world: OffWorkState, events: Array, interaction: Dictionary = {}) -> bool:
	if lesson.is_empty() or complete(): return false
	var target := str(lesson.steps[step][0])
	var satisfied := false
	if target == "meeting_income" and (not _meeting_running(world) or not _has_task(world, "work")):
		return _rewind(0, "开会组合已拆开，开会牌冷却结束后，把它交给独立主持人，并让另一名员工继续工作。")
	if target == "transfer_sent" and not _transfer_running(world) and not _received_transfer(world, events):
		return _rewind(0, "甩锅组合已拆开，把人员、工作和甩锅牌重新放在一起。")
	var has_grinder := not world._owner_type(0, "grinder").is_empty() if target in ["coffee", "upgrade"] else false
	if target in ["coffee", "upgrade"] and not has_grinder and separate_worker(world) < 0:
		step = 0
		last_feedback = "人员和工作又放到一起了，先把人员单独拖出来。"
		Progress.record(lesson.id, step, "viewed" if used_demo else "started", true)
		return true
	# Moving a card out of an active combination cancels its timer. Show the
	# actionable step again instead of asking the player to wait for it.
	if target == "overtime_income" and not _has_task(world, "work", true):
		step -= 1
		last_feedback = "提效组合已拆开，把员工和加班牌放回工作堆。"
		Progress.record(lesson.id, step, "viewed" if used_demo else "started", true)
		return true
	if (target == "upgrade" and not has_grinder and not _has_task(world, "coffee")) or (
		target == "income" and not _has_task(world, "work") and not events.any(func(e): return e.kind == "work_complete" and e.owner == 0)):
		step -= 1
		last_feedback = "咖啡组合已拆开。" if target == "upgrade" else "员工已离开工作堆。"
		Progress.record(lesson.id, step, "viewed" if used_demo else "started", true)
		return true
	match target:
		"inspect_type":
			satisfied = bool(interaction.get("inspected", false)) and int(interaction.get("source_group", interaction.get("group", -1))) == _source_group and str(interaction.get("type", "")) == "employee"
		"extract_type":
			satisfied = _extracted(world)
		"meeting_start":
			satisfied = _meeting_running(world) and _has_task(world, "work")
			if world.cards.has(_meeting_tool) and world.cards[_meeting_tool].status == "recovering":
				var feedback := "开会牌正在冷却，结束后把它交给独立主持人，另一名员工继续工作。"
				if last_feedback != feedback:
					last_feedback = feedback
					return true
		"meeting_income":
			satisfied = _meeting_running(world) and events.any(func(e): return e.kind == "work_complete" and e.owner == 0)
		"transfer_start":
			satisfied = _transfer_running(world)
			if satisfied:
				_transfer_group = int(world.cards[_transfer_tool].group)
				_transfer_workers = world.group_transfer_participants(_transfer_group).duplicate()
		"transfer_sent":
			satisfied = _received_transfer(world, events)
		"transfer_resume":
			satisfied = events.any(func(e):
				return e.kind == "work_complete" and e.owner == 0 and world._group_type(e.group, "transfer").is_empty() \
					and e.participants.any(func(id): return _transfer_workers.has(id)))
		"separate_worker":
			satisfied = separate_worker(world) >= 0
		"assign", "overtime":
			satisfied = _has_task(world, "work", target == "overtime")
		"win":
			satisfied = world.winner == 0 and world.work_count(0) == 0
		"coffee", "upgrade":
			satisfied = has_grinder or (target == "coffee" and _has_task(world, "coffee"))
		"overtime_income":
			satisfied = events.any(func(e):
				return e.kind == "work_complete" and e.owner == 0 and not world._group_type(e.group, "overtime").is_empty())
		_:
			var kind := str({"income":"work_complete", "own_income":"work_complete", "buy":"buy", "strike":"strike"}[target])
			satisfied = events.any(func(e): return e.kind == kind and e.owner == 0 and (target != "buy" or e.card_type == "employee"))
	if not satisfied: return false
	last_feedback = lesson.steps[step][2]
	step += 1
	var status := "started"
	if used_demo: status = "viewed"
	elif complete(): status = "completed"
	Progress.record(lesson.id, step, status, true)
	return true

func demonstrate(world: OffWorkState) -> bool:
	if lesson.is_empty() or complete() or lesson.id == "solo": return false
	var target: String = lesson.steps[step][0]
	var acted := false
	match target:
		"inspect_type":
			# Opening the real side panel is owned by the scene's UI bridge.
			acted = true
		"extract_type":
			acted = world.move_cards(_extract_workers) >= 0
		"meeting_start":
			acted = _demonstrate_meeting(world)
		"meeting_income":
			acted = _meeting_running(world) and _dispatch(world, 0)
		"transfer_start":
			_dispatch(world, 0)
			var people := workers(world, 0)
			if not people.is_empty() and world.cards.has(_transfer_tool):
				acted = world.move_cards([_transfer_tool], world.cards[people[0]].group, people[0]) >= 0
		"transfer_sent":
			acted = _transfer_running(world)
		"transfer_resume":
			if world.cards.has(_transfer_tool):
				world.move_cards([_transfer_tool])
				acted = _dispatch(world, 0)
		"separate_worker":
			var people := workers(world, 0)
			if not people.is_empty(): acted = world.move_cards([people[0]]) >= 0
		"assign", "own_income", "income":
			acted = _dispatch(world, 0)
		"buy":
			for offer in world.offers:
				if not offer.is_empty() and offer.type == "employee":
					acted = world.buy(offer.id, 0) >= 0
					break
		"overtime", "coffee":
			if target == "overtime": _dispatch(world, 0)
			var people := workers(world, 0)
			var tools := world._owner_type(0, target)
			if not people.is_empty() and not tools.is_empty():
				acted = world.move_cards([tools[0]], world.cards[people[0]].group, people[0]) >= 0
		"strike":
			var tools := world._owner_type(0, "strike")
			if not tools.is_empty():
				for group in world.groups:
					if world.can_strike_group(group, 0):
						acted = world.activate(tools[0], group)
						break
		"upgrade", "overtime_income":
			# Let the same visible timer finish at normal game speed.
			acted = true
	if acted:
		used_demo = true
		Progress.record(lesson.id, step, "viewed", true)
	return acted

func _rewind(to_step: int, feedback: String) -> bool:
	step = to_step
	last_feedback = feedback
	Progress.record(lesson.id, step, "viewed" if used_demo else "started", true)
	return true

func _extracted(world: OffWorkState) -> bool:
	if _extract_workers.is_empty() or not world.cards.has(_extract_workers[0]): return false
	var destination: int = world.cards[_extract_workers[0]].group
	if destination == _source_group or world.group_cards(destination).size() != _extract_workers.size(): return false
	return _extract_workers.all(func(id): return world.cards.has(id) and int(world.cards[id].group) == destination) \
		and _extract_materials.all(func(id): return world.cards.has(id) and int(world.cards[id].group) == _source_group)

func _meeting_running(world: OffWorkState) -> bool:
	if not world.meetings.has(_meeting_tool): return false
	var meeting: Dictionary = world.meetings[_meeting_tool]
	return meeting.targets.any(func(id):
		return world.cards.has(id) and int(world.cards[id].owner) == 1 \
			and not world.group_work(int(world.cards[id].group)).is_empty() and world.is_meeting_target(id))

func _transfer_running(world: OffWorkState) -> bool:
	if not world.cards.has(_transfer_tool): return false
	var group: int = world.cards[_transfer_tool].group
	return world.cards[_transfer_tool].status == "active" and not world.group_transfer_participants(group).is_empty()

func _received_transfer(world: OffWorkState, events: Array) -> bool:
	return events.any(func(event):
		return event.kind == "transfer" and event.owner == 0 and event.source == _transfer_tool and not event.ids.is_empty() \
			and event.ids.all(func(id): return world.cards.has(id) and int(world.cards[id].owner) == 1))

func _demonstrate_meeting(world: OffWorkState) -> bool:
	if not world.cards.has(_meeting_tool): return false
	var leaders := world._owner_type(0, "leader")
	if leaders.is_empty(): return false
	var tool: Dictionary = world.cards[_meeting_tool]
	if tool.status == "recovering": return true
	if world.meetings.has(_meeting_tool):
		if _has_task(world, "work"): return true
		# Undo an accidental worker-host assignment through the real rules.
		return world.move_cards([_meeting_tool]) >= 0
	_dispatch(world, 0)
	var host: int = leaders[0]
	if not world.group_work(world.cards[host].group).is_empty():
		world.move_cards([host])
	return world.move_cards([_meeting_tool], world.cards[host].group, host) >= 0

static func _has_task(world: OffWorkState, kind: String, with_overtime := false) -> bool:
	for id in world.tasks:
		if world.cards[id].owner != 0 or world.tasks[id].kind != kind: continue
		if with_overtime and world._group_type(world.cards[id].group, "overtime").is_empty(): continue
		return true
	return false

static func workers(world: OffWorkState, owner: int) -> Array:
	return world.cards.keys().filter(func(id): return world.cards[id].owner == owner and world.config.can_work(world.cards[id].type))

static func separate_worker(world: OffWorkState) -> int:
	for id in workers(world, 0):
		if world.group_work(world.cards[id].group).is_empty(): return int(id)
	return -1

static func _dispatch(world: OffWorkState, owner: int) -> bool:
	var people := workers(world, owner)
	var jobs := world._owner_type(owner, "work")
	if people.is_empty() or jobs.is_empty(): return false
	var group: int = world.cards[jobs[0]].group
	return world.cards[people[0]].group == group or world.move_cards([people[0]],group) >= 0
