# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## The desktop game plans during the interval BEFORE an action. The simulation
## runner calls OffWorkBot directly and never waits for frames or worker threads.
const Bot = preload("res://engine/off_work_bot.gd")
const Config = preload("res://engine/off_work_config.gd")
const Replay = preload("res://engine/off_work_replay.gd")
const Cancellation = preload("res://engine/bot_cancellation.gd")

class Search extends RefCounted:
	var world: OffWorkState
	var worker: OffWorkBot
	var control := Cancellation.new()
	var due: float
	var deadline: int
	var bot_id: int
	var policy_hash: int
	var visible_offer_end: int
	var visible_card_end: int
	var visible_group_end: int
	var frame := {}
	var _mutex := Mutex.new()
	var _published := {}
	var _last_seen := {} # Only touched by the render thread.

	func run() -> void:
		if control.is_cancelled() or Time.get_ticks_usec() >= deadline: return
		if not frame.is_empty():
			var entry := Replay.decode_frame(frame, world)
			if entry.is_empty() or control.is_cancelled(): return
			for key in OffWorkState.WORLD_FIELDS: world.set(key,entry.world[key])
			# The private market RNG in the recorded game is never restored. Only
			# entities visible in this observation may be used by the root action.
			visible_offer_end = mini(visible_offer_end, world._next_offer)
			visible_card_end = mini(visible_card_end, world._next_card)
			visible_group_end = mini(visible_group_end, world._next_group)
		var delta := due - world.time
		if delta > 0 and not world.advance_for_search(delta, deadline, control.is_cancelled): return
		world.mask_search_market(visible_offer_end)
		if world.winner >= 0 or control.is_cancelled(): return
		var selected := worker.decide_action(deadline, control.is_cancelled, true, publish, uses_observed_entities)
		publish(selected, worker.last_decision)

	# Publish completed depths as they arrive. If the next expansion is still
	# running at the action point, the frame can take the last completed choice.
	func publish(command: Dictionary, report: Dictionary) -> void:
		if control.is_cancelled() or Time.get_ticks_usec() >= deadline: return
		var packet := {"action":command.duplicate(true), "report":report.duplicate(true),
			"rng":worker._rng.state, "hints":worker.export_decision_context()}
		# Natural events were projected between the observation and action time.
		# A future prefix may mention those predicted IDs even though its first
		# command passed the visible-entity filter. Bind all later commands to
		# the original observation, never to coincidentally matching live arrivals.
		packet.report["observed_card_end"]=mini(visible_card_end,int(report.get("observed_card_end",visible_card_end)))
		packet.report["observed_group_end"]=mini(visible_group_end,int(report.get("observed_group_end",visible_group_end)))
		_mutex.lock()
		if Time.get_ticks_usec() < deadline: _published = packet
		_mutex.unlock()

	func latest() -> Dictionary:
		if _mutex.try_lock():
			_last_seen = _published
			_mutex.unlock()
		return _last_seen

	## Keep predicted arrivals out of root ranking and emergency publications,
	## so they cannot overwrite a completed choice that the frame can execute.
	## These bounds are immutable after the worker has decoded its observation.
	func uses_observed_entities(action: Dictionary) -> bool:
		if action.is_empty(): return false
		if int(action.get("offer", -1)) >= visible_offer_end: return false
		if int(action.get("group", -1)) >= visible_group_end: return false
		for key in ["tool", "person"]:
			if int(action.get(key, -1)) >= visible_card_end: return false
		for id in action.get("ids", []):
			if int(id) >= visible_card_end: return false
		return true

	## A sampled future offer/card may have exactly the same ID as an unrelated
	## real arrival. Only use items visible when search started, in the same role
	## and pile that the worker expected immediately before acting.
	func still_legal(live: OffWorkState, action: Dictionary) -> bool:
		if not uses_observed_entities(action): return false
		if action.has("offer"):
			var known := false
			for offer in live.offers:
				if not offer.is_empty() and offer.id == action.offer and offer.type == action.get("card_type",""):
					known = true
					break
			if not known: return false
		var gid := int(action.get("group",-1))
		if gid >= 0 and (not live.groups.has(gid) or not world.groups.has(gid)
				or live.groups[gid].job != world.groups[gid].job or live.groups[gid].owner != world.groups[gid].owner):
			return false
		for key in ["tool","person"]:
			var id := int(action.get(key,-1))
			if id >= 0 and not _same_card(live,id): return false
		for id in action.get("ids",[]):
			if not _same_card(live,id): return false
		return true

	func _same_card(live: OffWorkState, id: int) -> bool:
		if id >= visible_card_end or not world.cards.has(id) or not live.cards.has(id): return false
		var expected: Dictionary = world.cards[id]
		var card: Dictionary = live.cards[id]
		return card.owner == expected.owner and card.group == expected.group and card.type == expected.type and card.status == expected.status

var _task: int = -1
var _search: Search
var _ready: Search
var _retained_source: Search
var _retained_packet := {}
var _frozen_config: OffWorkConfig
var _source_config_id := 0
var needs_keyframe := false

func bind_config(source: OffWorkConfig) -> void:
	if _source_config_id == source.get_instance_id(): return
	_frozen_config = Config.new(source.balance_document(), {"bot": source.rules.bot, "preferences": source.bot_preferences})
	_source_config_id = source.get_instance_id()

func tick(bot: OffWorkBot, frame_delta: float, frozen_frame: Dictionary = {}) -> void:
	_collect()
	var due := bot.next_action_time()
	if not bot.is_started() or not is_finite(due) or bot.state.winner >= 0:
		cancel()
		return
	var in_flight := _ready if _ready != null else _search
	if in_flight != null and (in_flight.bot_id != bot.get_instance_id() or in_flight.due != due
			or in_flight.policy_hash != hash(bot._policy)):
		cancel()
	if _retained_source != null and not _matches(bot, _retained_source):
		_retained_source = null
		_retained_packet = {}
	var remaining: float = due - bot.state.time
	if remaining <= 0:
		var source := _ready if _ready != null else _search
		var used := false
		if source != null and not source.control.is_cancelled():
			used = _commit_packet(bot, source, source.latest())
		if not used and _retained_source != null:
			used = _commit_packet(bot, _retained_source, _retained_packet)
			if used: bot.last_decision["live_retained"] = true
		if not used:
			var action := bot.decide_action(Time.get_ticks_usec() + int(bot._policy.live_fallback_budget_us), Callable(), false)
			bot.last_decision["live_fallback"] = true
			if not bot.commit_action(action, bot.last_decision):
				var waiting := bot.last_decision.merged({"kind":"wait", "reason":"现场条件已变化，保持当前安排", "fallback":true}, true)
				bot.commit_action({"kind":"wait"}, waiting)
		bot._next_think = float(bot.state.time) + float(bot._policy.think_seconds)
		cancel()
		return
	if _task >= 0:
		_search.latest() # Keep the previous publication for a lock-free deadline fallback.
		return
	if _ready != null: return
	# Start up to one frame early, so small budgets can finish between ticks.
	var budget_us := Config.decision_budget_ms(bot._policy) * 1000
	var wall_to_due := ceili(remaining / maxf(0.001, Engine.time_scale) * 1000000.0)
	if wall_to_due > budget_us + ceili(maxf(0,frame_delta) / maxf(0.001, Engine.time_scale) * 1000000.0): return
	# Thresholds choose how to copy the complete world; they never exclude
	# cards or legal actions from the search.
	var large: bool = bot.state.cards.size() > int(bot._policy.live_snapshot_card_limit) or bot.state.groups.size() > int(bot._policy.live_snapshot_group_limit)
	if large and frozen_frame.is_empty():
		# Ask the existing recorder for one coherent frame. A large table
		# resumes full search the next frame even after a replay/restore.
		needs_keyframe = true
		return
	needs_keyframe = false
	_launch(bot, due, Time.get_ticks_usec() + mini(budget_us, wall_to_due), frozen_frame if large else {})

func _matches(bot: OffWorkBot, source: Search) -> bool:
	return bot != null and source.bot_id == bot.get_instance_id() and source.due == bot.next_action_time() \
		and source.policy_hash == hash(bot._policy)

func _commit_packet(bot: OffWorkBot, source: Search, packet: Dictionary) -> bool:
	if packet.is_empty() or not _matches(bot, source) or not source.still_legal(bot.state, packet.action): return false
	# Worker hints describe the state BEFORE this command, including any
	# independent step selected ahead of a waiting production recipe. Install
	# that queue first so commit consumes the correct step or saves a new paid
	# plan. Importing it afterward would undo every one of those transitions.
	var previous_context := bot.export_decision_context()
	bot.import_decision_context(packet.hints)
	if not bot.commit_action(packet.action, packet.report):
		bot.import_decision_context(previous_context)
		return false
	bot._rng.state = packet.rng
	return true

## Player input invalidates the forecast, but a completed command can still be
## legal. Keep exactly that publication while replanning; validate it again at
## the action point if no newer result can be used. Lifecycle cancellation must
## still discard everything, including this backup.
func replan(bot: OffWorkBot) -> void:
	_collect()
	var source := _ready if _ready != null else _search
	if source != null and not source.control.is_cancelled() and _matches(bot, source):
		var packet := source.latest()
		var previous_legal := _retained_source != null and not _retained_packet.is_empty() \
			and _matches(bot, _retained_source) and _retained_source.still_legal(bot.state, _retained_packet.action)
		# A tool may only finish cooling at the predicted action time. Keep that
		# candidate if there is no currently legal backup to protect.
		if not packet.is_empty() and (source.still_legal(bot.state, packet.action) or not previous_legal):
			_retained_source = source
			_retained_packet = packet.duplicate(true)
	if _retained_source != null and not _matches(bot, _retained_source):
		_retained_source = null
		_retained_packet = {}
	_cancel_search()

func _launch(bot: OffWorkBot, due: float, deadline: int, frozen_frame: Dictionary) -> void:
	var job := Search.new()
	job.due = due
	job.deadline = deadline
	job.bot_id = bot.get_instance_id()
	job.policy_hash = hash(bot._policy)
	job.visible_offer_end = bot.state._next_offer
	job.visible_card_end = bot.state._next_card
	job.visible_group_end = bot.state._next_group
	bind_config(bot.state.config)
	if not frozen_frame.is_empty():
		# The recorder never edits published frames. Share its compressed string;
		# the gameplay thread does not copy thousands of live card dictionaries.
		job.frame = frozen_frame
		job.world = OffWorkState.new(_frozen_config)
		job.world._bot_branch = true
		job.world._rng.seed = bot._rng.state
	else:
		job.world = bot.state.fork_for_bot(bot._rng.state)
		job.world.config = _frozen_config
	if Time.get_ticks_usec() >= deadline: return
	job.worker = Bot.new(job.world, bot.owner, bot._policy.duplicate(true))
	job.worker._rng.state = bot._rng.state
	job.worker.import_decision_context(bot.export_decision_context())
	_task = WorkerThreadPool.add_task(job.run, false, "下班 BOT")
	if _task >= 0: _search = job

func _collect() -> void:
	if _task < 0 or not WorkerThreadPool.is_task_completed(_task): return
	WorkerThreadPool.wait_for_task_completion(_task)
	if not _search.control.is_cancelled() and not _search.latest().is_empty():
		_ready = _search
	_task = -1
	_search = null

func cancel() -> void:
	_retained_source = null
	_retained_packet = {}
	_cancel_search()

func _cancel_search() -> void:
	needs_keyframe = false
	_ready = null
	if _search != null: _search.control.request()

func close(tree: SceneTree) -> void:
	cancel()
	if _task < 0: return
	_reap(tree, _task, _search)
	_task = -1
	_search = null

## A scene can disappear while the independent worker is in an evaluation.
## Retain its job until the pool confirms completion; never join a live task
## on the UI thread, including when leaving a table or opening another one.
static func _reap(tree: SceneTree, task: int, job: Search) -> void:
	if WorkerThreadPool.is_task_completed(task):
		WorkerThreadPool.wait_for_task_completion(task)
	elif is_instance_valid(tree):
		tree.process_frame.connect(_reap.bind(tree, task, job), CONNECT_ONE_SHOT)
