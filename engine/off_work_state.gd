# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkState
extends RefCounted

const ConfigSource = preload("res://engine/off_work_config.gd")
const CoffeePlanSource = preload("res://engine/off_work_coffee_plan.gd")
const CancellationSource = preload("res://engine/bot_cancellation.gd")
const WORLD_FIELDS := ["cards", "groups", "tasks", "meetings", "outsourcing", "pending_strikes", "recruitment", "offers",
	"winner", "time", "conveyor_progress", "revision", "_next_card", "_next_group",
	"_next_offer", "_conveyor_elapsed", "_supply_count", "_supply_mode", "_supply_bag", "_supply_bag_signature"]
const SHUFFLE_SUPPLY := "shuffle_bag_v1"
const LEGACY_SUPPLY := "weighted_v0"

var config: RefCounted
var cards: Dictionary = {}
var groups: Dictionary = {}
var tasks: Dictionary = {}
var meetings: Dictionary = {}
var outsourcing: Dictionary = {}
var pending_strikes: Dictionary = {}
var recruitment: Dictionary = {}
var offers: Array = []
var winner: int = -1
var time: float = 0.0
var conveyor_progress: float = 0.0
var last_error: String = ""
var revision: int = 0
var _events: Array = []
var _next_card: int = 1
var _next_group: int = 1
var _next_offer: int = 1
var _conveyor_elapsed: float = 0.0
var _supply_count: int = 0
var _supply_mode: String = SHUFFLE_SUPPLY
var _supply_bag: Array = []
var _supply_bag_signature: String = ""
var _rng := RandomNumberGenerator.new()
var _bot_branch := false
# These flags retain the command-local query scope used by BOT search. The
# membership cache below survives frames; status/progress are still read live.
var _index_queries := false
# Search commands may reuse membership queries without postponing any normal
# card refresh. Keep this separate from advance()'s event batching flag.
var _search_queries := false
# Scoped to one validated middle passive activation in move_cards().
var _defer_passive_schedule := false
var _group_index: Dictionary = {}
var _membership_index: Dictionary = {}
var _owner_index: Dictionary = {}
var _type_index: Dictionary = {}
var _activity_ids: Array = []
var _people_ids: Array = []
var _indexed_card_count := -1
var _indexed_group_count := -1
var _indexed_config_signature := 0
# Arbitrary cancellation callbacks may mutate data outside the usual helpers.
# Their next structural change keeps the old full-invalidation behavior.
var _incremental_membership_safe := true
var _inside_membership_callback := false
var _membership_card_count := -1
var _membership_group_count := -1
var _membership_generation := 0
var _schedule_dirty := true
var _scheduled_config := 0
var _active_groups: Dictionary = {"work": [], "transfer": [], "slack": []}

## Restore/import callers use this same invalidation as ordinary mutations.
## Derived indexes are never serialized or copied into a BOT branch.
func _invalidate_group_index() -> void:
	_membership_generation += 1
	_group_index.clear()
	_membership_index.clear()
	_owner_index.clear()
	_type_index.clear()
	_activity_ids.clear()
	_people_ids.clear()
	_indexed_card_count = -1
	_indexed_group_count = -1
	_indexed_config_signature = 0
	_incremental_membership_safe = true
	_membership_card_count = cards.size()
	_membership_group_count = groups.size()
	_schedule_dirty = true

func _ensure_membership_shape() -> void:
	if _membership_card_count != cards.size():
		_invalidate_group_index()
	elif _membership_group_count != groups.size():
		_invalidate_group_layout()

## Layout is independent of global owner/type membership. Unknown imports and
## polymorphic implementations keep the full invalidation contract above.
func _invalidate_group_layout(affected: Array = []) -> void:
	if get_script() != OffWorkState or config.get_script() != ConfigSource \
			or not _incremental_membership_safe or _inside_membership_callback \
			or (not _index_queries and _scheduled_config != _config_schedule_signature()):
		_invalidate_group_index()
		return
	_membership_generation += 1
	if affected.is_empty():
		_group_index.clear()
		_membership_index.clear()
	else:
		for group in affected:
			_group_index.erase(group)
			_membership_index.erase(group)
	_membership_card_count = cards.size()
	_membership_group_count = groups.size()
	# Retained for callers that inspect cache shape; global validity no longer
	# depends on the number of groups, which cannot change owner/type arrays.
	if _indexed_card_count == cards.size(): _indexed_group_count = groups.size()
	_schedule_dirty = true

func _can_update_membership_index() -> bool:
	_ensure_membership_shape()
	if get_script() != OffWorkState or config.get_script() != ConfigSource \
			or not _incremental_membership_safe or _inside_membership_callback \
			or _indexed_card_count != cards.size(): return false
	# advance() already validates this configuration before entering its event
	# batch. Do not hash it again for every real coin in one settled wage.
	if _index_queries and _indexed_config_signature == _scheduled_config: return true
	return _indexed_config_signature == _config_schedule_signature()

func _index_card(id: int) -> void:
	var card: Dictionary = cards[id]
	var kind := str(card.type)
	var owner := int(card.owner)
	if not _type_index.has(kind): _type_index[kind] = []
	_type_index[kind].append(id)
	if not _owner_index.has(owner): _owner_index[owner] = {"types": {}, "people": [], "activity": []}
	var entry: Dictionary = _owner_index[owner]
	if not entry.types.has(kind): entry.types[kind] = []
	entry.types[kind].append(id)
	var category: String = config.category(kind)
	if category == "person":
		_people_ids.append(id)
		entry.people.append(id)
	if category in ["person", "tool", "ingredient"]:
		_activity_ids.append(id)
		entry.activity.append(id)

func _unindex_card(id: int) -> void:
	var card: Dictionary = cards[id]
	var kind := str(card.type)
	var owner := int(card.owner)
	_type_index[kind].erase(id)
	if _type_index[kind].is_empty(): _type_index.erase(kind)
	var entry: Dictionary = _owner_index[owner]
	entry.types[kind].erase(id)
	if entry.types[kind].is_empty(): entry.types.erase(kind)
	var category: String = config.category(kind)
	if category == "person":
		_people_ids.erase(id)
		entry.people.erase(id)
	if category in ["person", "tool", "ingredient"]:
		_activity_ids.erase(id)
		entry.activity.erase(id)
	if entry.types.is_empty(): _owner_index.erase(owner)

func _ensure_membership_index() -> void:
	_ensure_membership_shape()
	if _indexed_card_count == cards.size(): return
	# A single-group query may already have rebuilt that group's membership
	# since the last mutation. Building owner/type indexes must not discard it.
	_owner_index.clear()
	_type_index.clear()
	_activity_ids.clear()
	_people_ids.clear()
	for id in cards:
		_index_card(int(id))
	_indexed_card_count = cards.size()
	_indexed_group_count = groups.size()
	_indexed_config_signature = _config_schedule_signature()

## Local cache lifetime, separate from gameplay/replay revision. Transfers and
## restored snapshots can change membership without increasing that revision.
func membership_version() -> int:
	_ensure_membership_index()
	return _membership_generation

## UI and timers need only personnel/tools/materials, never every queued file
## or cash card. Return a copy so a caller cannot mutate the shared index.
func activity_card_ids(owner: int = -1) -> Array:
	_ensure_membership_index()
	return _activity_ids.duplicate() if owner < 0 else _owner_index.get(owner, {}).get("activity", []).duplicate()

func _cards_of_type(kind: String) -> Array:
	_ensure_membership_index()
	return _type_index.get(kind, []).duplicate()

func _config_schedule_signature() -> int:
	return hash([config.cards, config.roles, config.rules])

func _rebuild_active_groups() -> void:
	_active_groups = {"work": [], "transfer": [], "slack": []}
	for task in tasks.values():
		if _active_groups.has(task.kind) and not _active_groups[task.kind].has(task.group):
			_active_groups[task.kind].append(task.group)

func _indexed_group(group: int) -> Dictionary:
	# Group queries never need the global owner/type tables. In particular,
	# settling one pile must not rescan every card before crediting its income.
	_ensure_membership_shape()
	if _membership_index.has(group): return _membership_index[group]
	var entry := {"types": {}, "people": [], "tools": [], "actions": []}
	if groups.has(group):
		for id in groups[group].cards:
			if not cards.has(id): continue
			var kind := str(cards[id].type)
			if not entry.types.has(kind): entry.types[kind] = []
			entry.types[kind].append(id)
			var category: String = config.category(kind)
			if category == "person": entry.people.append(id)
			if category == "tool": entry.tools.append(id)
			if category in ["tool", "ingredient"]: entry.actions.append(id)
	_membership_index[group] = entry
	if _index_queries or _search_queries: _group_index[group] = entry
	return entry

func _init(config_override: RefCounted = null) -> void:
	config = config_override if config_override != null else ConfigSource.new()

## Search starts with visible cards, running timers and offers. Unseen offers
## come from a hypothetical seed; the authoritative market RNG is never copied.
func fork_for_bot(sample_seed: int, isolate_config := false) -> OffWorkState:
	var branch_config := config
	if isolate_config:
		branch_config = ConfigSource.new(config.balance_document(),
			{"bot": config.rules.bot, "preferences": config.bot_preferences})
	var branch := OffWorkState.new(branch_config)
	for key in WORLD_FIELDS:
		var value: Variant = get(key)
		branch.set(key, value.duplicate(true) if value is Dictionary or value is Array else value)
	branch._bot_branch = true
	branch._rng.seed = sample_seed
	# The remaining multiset follows from the public bag counts and cards
	# already dealt. Its real order is private: canonicalize before sampling,
	# so changing the hidden real permutation cannot influence a BOT forecast.
	branch.sample_hidden_supply()
	return branch

## Used by both live snapshot paths. Only an isolated hypothetical world may
## replace the hidden permutation; the already public remaining counts stay.
func sample_hidden_supply() -> void:
	assert(_bot_branch)
	if _supply_mode == SHUFFLE_SUPPLY and not _supply_bag.is_empty():
		_supply_bag.sort()
		_shuffle_supply_bag()

## Descendants share the same hypothetical supply stream, including how far
## it advanced in their parent. Unrelated branches never modify each other.
func fork_search_node() -> OffWorkState:
	assert(_bot_branch)
	var branch := fork_for_bot(_rng.seed)
	branch._rng.state = _rng.state
	# This is a descendant of an existing hypothetical world, not a fresh
	# observation. Preserve that scenario's already sampled future sequence.
	branch._supply_bag = _supply_bag.duplicate()
	# WORLD_FIELDS already contains the authoritative tasks and group clocks.
	# Preserve a completed schedule instead of rebuilding those same slots in
	# every child. Membership indexes remain branch-local and rebuild lazily;
	# seeding only their shape prevents that first read from marking this copied
	# schedule dirty. Unreconciled direct edits and configuration changes still
	# take the normal authoritative rescheduling path in advance().
	branch._membership_card_count = branch.cards.size()
	branch._membership_group_count = branch.groups.size()
	branch._schedule_dirty = _schedule_dirty or _membership_card_count != cards.size() or _membership_group_count != groups.size()
	branch._scheduled_config = _scheduled_config
	branch._active_groups = _active_groups.duplicate(true)
	return branch

## Preserve conveyor positions and expiry, but do not present a sampled future
## offer as a resource on which an irreversible plan can depend. Opt-in for the
## current search only; normal play and legacy simulator branches are unchanged.
func mask_search_market(known_offer_end: int) -> void:
	assert(_bot_branch)
	for index in offers.size():
		if not offers[index].is_empty() and int(offers[index].id) >= known_offer_end:
			offers[index] = {}

func new_game(seed_value: int = 0) -> void:
	_invalidate_group_index()
	if not config.validate():
		last_error = "配置错误：\n" + "\n".join(config.errors)
		return
	cards.clear()
	groups.clear()
	tasks.clear()
	meetings.clear()
	pending_strikes.clear()
	recruitment.clear()
	outsourcing.clear()
	offers.clear()
	_events.clear()
	winner = -1
	time = 0.0
	conveyor_progress = 0.0
	_conveyor_elapsed = 0.0
	_supply_count = 0
	_supply_mode = SHUFFLE_SUPPLY
	_supply_bag.clear()
	_supply_bag_signature = ""
	_next_card = 1
	_next_group = 1
	_next_offer = 1
	last_error = ""
	_rng.seed = seed_value if seed_value != 0 else config.integer("simulation", "default_seed")
	for owner_value in config.rules.simulation.owners:
		var owner: int = int(owner_value)
		for initial in config.rules.initial.groups:
			var group: int = create_group(owner)
			for kind in initial:
				for _index in range(int(initial[kind])):
					add_card(str(kind), owner, group)
		_credit(owner, config.integer("initial", "money"))
	for index in range(config.integer("conveyor", "slots")):
		offers.append(_new_offer())
	_reschedule()
	_emit("new_game", {"seed": _rng.seed})
	revision += 1

func create_group(owner: int) -> int:
	_ensure_membership_shape()
	var id: int = _next_group
	_next_group += 1
	groups[id] = {"id": id, "owner": owner, "cards": [], "job": "work", "function": ""}
	_invalidate_group_layout([id])
	return id

## A production combination keeps its first function while its defining cards
## remain, including tool cooldowns and waits for personnel or materials.
## Union/overtime are modifiers; coffee and boss recruitment retain their
## separate personnel/material rules rather than claiming this production lock.
func _sync_group_function(group: int) -> void:
	if not groups.has(group): return
	var current := str(groups[group].get("function", ""))
	if not groups[group].has("function"):
		# Existing session/replay snapshots predate the lock. Retain their running
		# tool, including a just-finished meeting/outsource still cooling down.
		var previous := str(groups[group].get("job", "work"))
		if previous in ["meeting", "transfer", "slack", "outsource"]:
			current = previous
		else:
			for id in group_actions(group):
				if cards[id].type in ["meeting", "transfer", "slack", "outsource"] and cards[id].status in ["active", "recovering"]:
					current = str(cards[id].type)
					break
	if current == "work":
		if group_work(group).is_empty() or group_workers(group).is_empty(): current = ""
	elif not current.is_empty() and _group_type(group, current).is_empty():
		current = ""
	if current.is_empty():
		var people := _available_people(group)
		for id in group_actions(group):
			var kind := str(cards[id].type)
			if kind == "meeting" and not people.is_empty() and not meeting_candidates(int(groups[group].owner)).is_empty():
				current = kind
			elif kind == "transfer" and not people.is_empty() and not _transfer_work(group).is_empty():
				current = kind
			elif kind == "slack" and not group_people(group).is_empty():
				current = kind
			elif kind == "outsource" and not _outsource_additions(group).work_ids.is_empty():
				current = kind
			if not current.is_empty(): break
		if current.is_empty() and not group_work(group).is_empty() and not group_workers(group).is_empty():
			current = "work"
	groups[group]["function"] = current
	groups[group].job = current if not current.is_empty() else "work"

func _accepts_function(group: int, kind: String) -> bool:
	_sync_group_function(group)
	return groups.has(group) and str(groups[group].get("function", "")) == kind

func add_card(kind: String, owner: int, group: int = -1) -> int:
	assert(config.cards.has(kind), "未知卡种：" + kind)
	if not can_acquire(kind, owner):
		_fail("已达到这类牌的每方持有上限")
		return -1
	if not groups.has(group):
		group = create_group(owner)
	assert(int(groups[group].owner) == owner)
	var id: int = _next_card
	var indexed := _can_update_membership_index() and not cards.has(id)
	_next_card += 1
	cards[id] = {"id": id, "type": kind, "owner": owner, "group": group,
		"progress": 0.0, "status": "ready", "remaining": 0.0, "total": 0.0,
		"amount": 1 if kind == "money" else 0, "activity": "idle", "paused": false, "rate_multiplier": 0.0}
	groups[group].cards.append(id)
	if indexed:
		_index_card(id)
		_indexed_card_count = cards.size()
		_invalidate_group_layout([group])
	else:
		_invalidate_group_index()
	revision += 1
	return id

func can_acquire(kind: String, owner: int) -> bool:
	return not config.cards[kind].has("max_per_owner") or _owner_type(owner, kind).size() < int(config.cards[kind].max_per_owner)

func can_person_be_struck(person: int) -> bool:
	return cards.has(person) and config.is_person(str(cards[person].type)) and bool(config.roles[cards[person].type].get("can_be_strike_target", true)) and not _is_paused(person)

func money(owner: int) -> int:
	var result := 0
	for id in _owner_type(owner, "money"): result += int(cards[id].amount)
	return result

## Outsourcing owns reserved currency until its batch settles or is dismantled.
## The unused part of the same physical cash card remains spendable.
func reserved_cash_amount(id: int) -> int:
	if not cards.has(id) or cards[id].type != "money": return 0
	var reserved := 0
	for batch in outsourcing.values(): reserved += int(batch.payments.get(id, 0))
	for batch in recruitment.values(): reserved += int(batch.payments.get(id, 0))
	return reserved

func available_cash_amount(id: int) -> int:
	if not cards.has(id) or cards[id].type != "money": return 0
	return maxi(0, int(cards[id].amount) - reserved_cash_amount(id))

func reserved_money(owner: int) -> int:
	var reserved := 0
	for id in _owner_type(owner, "money"): reserved += reserved_cash_amount(int(id))
	return reserved

func available_money(owner: int) -> int:
	var available := 0
	for id in _owner_type(owner, "money"): available += available_cash_amount(int(id))
	return available

func work_count(owner: int) -> int:
	_ensure_membership_index()
	return _owner_index.get(owner, {}).get("types", {}).get("work", []).size()

func people_count(owner: int) -> int:
	_ensure_membership_index()
	return _owner_index.get(owner, {}).get("people", []).size()

func group_cards(group: int) -> Array:
	return groups[group].cards.duplicate() if groups.has(group) else []

## 工作摞的读条进度是在场人员已经投入的工时，拆摞时不能凭空多出一份。
## 整摞搬走，进度跟着走。只拆出一部分时：正在处理它的人跟着走，进度随人带走，
## 原摞还有人在处理才保留自己的进度；只搬工作不带人，搬走的那部分从头读条。
func _conserve_work_progress(moved: Array, target_group: int) -> void:
	var sources := {}
	for id in moved:
		var gid := int(cards[id].group)
		if gid == target_group or not groups.has(gid): continue
		if not sources.has(gid): sources[gid] = {"work": [], "people": []}
		if str(cards[id].type) == "work": sources[gid].work.append(id)
		elif tasks.get(id, {}).get("kind", "") == "work" and int(tasks[id].group) == gid: sources[gid].people.append(id)
	for gid in sources:
		var leaving: Dictionary = sources[gid]
		if leaving.work.is_empty(): continue
		var staying_work: Array = group_work(gid).filter(func(work): return not leaving.work.has(work))
		if staying_work.is_empty(): continue
		if leaving.people.is_empty():
			for work in leaving.work: cards[work].progress = 0.0
		elif group_work_participants(gid).all(func(person): return moved.has(person)):
			groups[gid]["work_progress"] = 0.0
			for work in staying_work: cards[work].progress = 0.0

func group_people(group: int) -> Array:
	return _indexed_group(group).people.duplicate()

func group_has_union(group: int) -> bool:
	return not _group_type(group, "union").is_empty()

func effective_work_kind(kind: String, group: int) -> String:
	if group_has_union(group) and config.can_work(kind):
		return str(config.rules.union.work_role)
	return kind

func can_person_work(person: int) -> bool:
	if not cards.has(person): return false
	var kind := str(cards[person].type)
	if not config.is_person(kind): return false
	return config.can_work(kind)

func _eject_union_overtime() -> void:
	for group in groups.keys():
		if not group_has_union(int(group)): continue
		var ejected: Array = _group_type(int(group), "overtime")
		for id in ejected:
			groups[group].cards.erase(id)
			var destination := create_group(int(cards[id].owner))
			cards[id].group = destination
			groups[destination].cards.append(id)
		if not ejected.is_empty():
			_invalidate_group_layout([group])
			_emit("union_eject", {"source": _group_type(int(group), "union")[0], "owner": groups[group].owner,
				"group": group, "ids": ejected})

func group_workers(group: int) -> Array:
	var result: Array = []
	for person in group_people(group):
		if can_person_work(int(person)):
			result.append(person)
	return result

func group_work(group: int) -> Array:
	return _group_type(group, "work")

func group_work_progress(group: int) -> float:
	if not groups.has(group): return 0.0
	return float(groups[group].get("work_progress", 0.0))

func group_work_participants(group: int) -> Array:
	var participants: Array = []
	for person in group_people(group):
		if not tasks.has(person) or tasks[person].kind != "work" or _is_paused(int(person)):
			continue
		if can_person_work(int(person)) and cards.has(tasks[person].work_id):
			participants.append(person)
	return participants

func group_work_rate(group: int) -> float:
	var participants := group_work_participants(group)
	if participants.is_empty(): return 0.0
	var rate := 0.0
	var overtime := _group_type(group, "overtime").size()
	if get_script() == OffWorkState and config.get_script() == ConfigSource:
		# Standard roles share one work-card duration. Keep every addition in
		# the original order so the shared clock retains its exact rounding.
		var unit_rate: float = config.work_rate(effective_work_kind(str(cards[participants[0]].type), group), overtime)
		for _person in participants: rate += unit_rate
	else:
		# State/config overrides may give different participants different rates.
		for person in participants:
			rate += config.work_rate(effective_work_kind(str(cards[person].type), group), overtime)
	return rate / float(participants.size())

## Transfer is a continuous combination cycle, just like ordinary work.
## Role capacity changes output, never the shared clock or coworkers' speed.
func group_transfer_progress(group: int) -> float:
	return float(groups[group].get("transfer_progress", 0.0)) if groups.has(group) else 0.0

func group_transfer_participants(group: int) -> Array:
	var participants: Array = []
	for person in group_people(group):
		if tasks.has(person) and tasks[person].kind == "transfer" and not _is_paused(int(person)):
			participants.append(person)
	return participants

func group_transfer_rate(group: int) -> float:
	return 0.0 if group_transfer_participants(group).is_empty() else 1.0 / config.number("transfer", "seconds")

## Coffee production belongs to the combination, never to individual people.
func group_slack_progress(group: int) -> float:
	return float(groups[group].get("slack_progress", 0.0)) if groups.has(group) else 0.0

func group_slack_participants(group: int) -> Array:
	return group_people(group).filter(func(person): return tasks.has(person) and tasks[person].kind == "slack" and not _is_paused(int(person)))

func group_slack_rate(group: int) -> float:
	return 0.0 if group_slack_participants(group).is_empty() else config.slack_rate(_group_type(group, "slack").size())

func group_tools(group: int) -> Array:
	return _indexed_group(group).tools.duplicate()

func group_actions(group: int) -> Array:
	return _indexed_group(group).actions.duplicate()

func move_cards(ids: Array, target_group: int = -1, target_card: int = -1) -> int:
	last_error = ""
	if winner >= 0 or ids.is_empty():
		_fail("对局已经结束" if winner >= 0 else "没有选中卡牌")
		return -1
	var unique: Array = []
	for id_value in ids:
		var id := int(id_value)
		if not cards.has(id):
			_fail("这张牌已不在桌上")
			return -1
		if pending_strikes.has(id):
			_fail("飞行中的罢工牌不能移动")
			return -1
		if is_meeting_target(id):
			_fail("开会中的人员不能自行离开")
			return -1
		if not unique.has(id):
			unique.append(id)
	var owner: int = int(cards[unique[0]].owner)
	for id in unique:
		if int(cards[id].owner) != owner:
			_fail("不能把双方的牌合成一组")
			return -1
	# Striking people may be repositioned as loose single cards, never grouped.
	# A blank-board drop uses -1; an explicit empty group or its own singleton
	# is equally safe. Position changes must not restart the status timer.
	if unique.any(func(id): return is_striking(int(id))):
		var alone := unique.size() == 1
		var empty_destination := target_group < 0 or (groups.has(target_group) and group_cards(target_group).all(func(id): return id == unique[0]))
		if not alone or not empty_destination or (target_card >= 0 and target_card != int(unique[0])):
			_fail("罢工中的人员只能单独移动，不能组合")
			return -1
	# Relocating a complete stack changes only its board position, not its
	# identity, active batch or meeting. UI keeps position separately.
	var original_group: int = int(cards[unique[0]].group)
	if target_group < 0 and groups.has(original_group) and unique.size() == groups[original_group].cards.size():
		var entire_group := true
		for id in unique:
			if int(cards[id].group) != original_group:
				entire_group = false
		if entire_group:
			return original_group
	if groups.has(target_group) and int(groups[target_group].owner) != owner:
		_fail("只能移动自己的牌；罢工请指定对面的组")
		return -1
	if group_people(target_group).any(func(person): return is_striking(int(person))) and group_cards(target_group) != unique:
		_fail("罢工跳舞中的人员暂时不能组合")
		return -1
	if group_has_union(target_group) and unique.any(func(id): return str(cards[id].type) == "overtime"):
		_fail("工会组合不能加入加班牌")
		return -1
	if target_group < 0:
		target_group = create_group(owner)
	elif not groups.has(target_group):
		_fail("目标组已经不存在")
		return -1
	_conserve_work_progress(unique, target_group)
	var affected_groups: Array = [target_group]
	for id in unique:
		var previous: int = int(cards[id].group)
		if previous == target_group:
			continue
		if groups.has(previous):
			groups[previous].cards.erase(id)
		if not affected_groups.has(previous): affected_groups.append(previous)
		cards[id].group = target_group
		groups[target_group].cards.append(id)
	_invalidate_group_layout(affected_groups)
	_cleanup_groups()
	_reschedule(false)
	# New combinations may start ready tools. Meetings additionally repeat after
	# cooling down; moving a complete group keeps its current task and timer.
	var moved_tools: Array = []
	for id in unique:
		if cards.has(id) and config.category(str(cards[id].type)) in ["tool", "ingredient"]:
			moved_tools.append(id)
	var candidates: Array = moved_tools if not moved_tools.is_empty() else group_actions(target_group)
	var batch_passives := _can_batch_passive_activation(candidates, target_group, owner)
	for index in candidates.size():
		var tool: Variant = candidates[index]
		if cards.has(tool) and str(cards[tool].status) == "ready" and str(cards[tool].type) != "strike":
			if batch_passives and index > 0 and index < candidates.size() - 1:
				_defer_passive_schedule = true
				activate(int(tool), target_group, target_card)
				_defer_passive_schedule = false
			else:
				activate(int(tool), target_group, target_card)
	_sync_coffee_groups()
	last_error = ""
	_emit("group_changed", {"owner": owner, "group": target_group, "ids": unique})
	revision += 1
	return target_group

func _can_batch_passive_activation(candidates: Array, target_group: int, owner: int) -> bool:
	if get_script() != OffWorkState or config.get_script() != ConfigSource or candidates.size() < 3:
		return false
	if not groups.has(target_group) or int(groups[target_group].owner) != owner: return false
	var protected_group := group_has_union(target_group)
	for tool in candidates:
		if not cards.has(tool): return false
		var card: Dictionary = cards[tool]
		if str(card.type) not in ["overtime", "union"] or str(card.status) != "ready" \
				or int(card.owner) != owner or int(card.group) != target_group: return false
		if config.category(str(card.type)) not in ["tool", "ingredient"]: return false
		if str(card.type) == "overtime" and protected_group: return false
	# Keep the first and last full schedules. The first can start coffee in
	# another group; the second places rebuilt work tasks after those new tasks,
	# preserving their original dictionary order as well as all rule events.
	return true

func activate(tool_id: int, target_group: int = -1, target_card: int = -1) -> bool:
	return _activate_tool(tool_id, target_group, target_card, false)

## A pointer drop has already delivered the card; only automatic throws fly.
func deliver_strike(tool_id: int, target_group: int) -> bool:
	return _activate_tool(tool_id, target_group, -1, true)

func _activate_tool(tool_id: int, target_group: int, target_card: int, delivered: bool) -> bool:
	_schedule_dirty = true
	last_error = ""
	if winner >= 0:
		return _fail("已经下班了")
	if not cards.has(tool_id):
		return _fail("工具已经不在桌上")
	var tool: Dictionary = cards[tool_id]
	var kind: String = str(tool.type)
	if delivered and kind != "strike":
		return _fail("只能直接送达罢工牌")
	if config.category(kind) not in ["tool", "ingredient"]:
		return _fail("这张牌不是可用工具或材料")
	if str(tool.status) != "ready" and not (kind == "slack" and tool.status == "active"):
		return _fail("这张工具还没有准备好")
	if target_group < 0:
		target_group = int(tool.group)
	if not groups.has(target_group):
		return _fail("先把工具叠到一个组")
	var owner: int = int(tool.owner)
	var target_owner: int = int(groups[target_group].owner)
	if kind == "strike":
		if target_owner == owner:
			return _fail("罢工要交给对面的工作组")
		return _activate_strike(tool_id, target_group, delivered)
	if target_owner != owner:
		return _fail("这张工具只能给己方使用")
	if kind in ["meeting", "transfer", "slack", "outsource"] and not _accepts_function(target_group, kind):
		return _fail("这个组合已在执行其他功能，请先拆出原功能牌或另组一摞")
	if kind == "coffee":
		return _activate_coffee(tool_id, target_group, target_card)
	if kind == "outsource":
		return _activate_outsource(tool_id, target_group)
	if int(tool.group) != target_group:
		return _fail("先把工具叠进这个组")
	if kind == "overtime" and group_has_union(target_group):
		return _fail("工会组合不能使用加班牌")
	if kind in ["overtime", "union"]:
		if not _defer_passive_schedule: _reschedule()
		return true
	if kind == "slack":
		return _activate_slack(tool_id, target_group)
	if kind == "meeting":
		return _activate_meeting(tool_id, target_group, target_card)
	if kind == "transfer":
		return _activate_transfer(tool_id, target_group)
	return _fail("这个组合还不能开始")

func buy(offer_id: int, owner: int, payment_ids: Array = []) -> int:
	last_error = ""
	if winner >= 0:
		_fail("已经下班了")
		return -1
	for index in range(offers.size()):
		var offer: Dictionary = offers[index]
		if offer.is_empty() or int(offer.id) != offer_id:
			continue
		if not config.can_purchase(str(offer.type)):
			_fail("高卷度人员需要喝咖啡逐级提升卷度获得" if config.is_upgrade_role(str(offer.type)) else "这张牌不可购买")
			return -1
		if not can_acquire(str(offer.type), owner):
			_fail("每方最多持有一名老板")
			return -1
		if not _spend(owner, int(offer.price), payment_ids):
			if last_error.is_empty(): _fail("钱还不够")
			return -1
		var card_id: int = add_card(str(offer.type), owner)
		offers[index] = {}
		_emit("buy", {"owner": owner, "source": card_id, "offer_id": offer_id, "card_type": offer.type, "group": cards[card_id].group})
		return card_id
	_fail("这张牌已经离开传送带")
	return -1

func advance(delta: float) -> void:
	_advance_events(delta, -1)

func advance_for_search(delta: float, deadline_usec: int, cancelled: Callable = Callable()) -> bool:
	assert(_bot_branch)
	return _advance_events(delta, deadline_usec, cancelled)

func _read_only_cancel_probe(probe: Callable) -> bool:
	if not probe.is_valid() or probe.get_bound_arguments_count() != 0: return false
	var target := probe.get_object()
	return target != null and target.get_script() == CancellationSource and probe.get_method() == &"is_cancelled"

func _poll_cancelled(probe: Callable) -> bool:
	if _read_only_cancel_probe(probe): return bool(probe.call())
	var was_inside := _inside_membership_callback
	_inside_membership_callback = true
	var stopped := bool(probe.call())
	_inside_membership_callback = was_inside
	_incremental_membership_safe = false
	return stopped

func _advance_events(delta: float, deadline_usec: int, cancelled: Callable = Callable()) -> bool:
	if not config.errors.is_empty() or winner >= 0 or delta <= 0.0:
		return config.errors.is_empty()
	_index_queries = true
	if _scheduled_config != _config_schedule_signature(): _invalidate_group_index()
	_ensure_membership_index()
	if _schedule_dirty: _reschedule()
	var left: float = delta
	var iterations := 0
	# epsilon controls event settlement, while the clock must consume every
	# positive delta, including the small tail before a bot or timeout deadline.
	while left > 0.0 and winner < 0:
		if deadline_usec >= 0 and (Time.get_ticks_usec() >= deadline_usec or (cancelled.is_valid() and _poll_cancelled(cancelled))):
			_index_queries = false
			_group_index.clear()
			return false
		iterations += 1
		if iterations > config.integer("simulation", "maximum_events_per_advance"):
			push_error("模拟事件超过配置预算；检查零时长配置")
			break
		var step: float = minf(left, config.number("conveyor", "interval_seconds") - _conveyor_elapsed)
		for id in activity_card_ids():
			var card: Dictionary = cards[id]
			if _has_timer(card):
				step = minf(step, maxf(0.0, float(card.remaining)))
		for meeting in meetings.values():
			step = minf(step, maxf(0.0, float(meeting.remaining)))
		for batch in outsourcing.values():
			step = minf(step, maxf(0.0, float(batch.remaining)))
		for flight in pending_strikes.values():
			step = minf(step, maxf(0.0, float(flight.remaining)))
		for batch in recruitment.values():
			step = minf(step, maxf(0.0, float(batch.remaining)))
		for group in _active_groups.work:
			var rate := group_work_rate(int(group))
			if rate > 0.0:
				step = minf(step, maxf(0.0, 1.0 - group_work_progress(int(group))) / rate)
		for group in _active_groups.transfer:
			var rate := group_transfer_rate(int(group))
			if rate > 0.0:
				step = minf(step, maxf(0.0, 1.0 - group_transfer_progress(int(group))) / rate)
		for group in _active_groups.slack:
			var rate := group_slack_rate(int(group))
			if rate > 0.0:
				step = minf(step, maxf(0.0, 1.0 - group_slack_progress(int(group))) / rate)
		for person in tasks:
			if tasks[person].kind in ["work", "transfer", "slack"]: continue
			var rate: float = _task_rate(int(person))
			if rate > 0.0:
				step = minf(step, maxf(0.0, 1.0 - _task_progress(int(person))) / rate)
		_progress_time(step)
		left -= step
		_settle_due()
		_check_winner()
		if winner < 0 and _schedule_dirty:
			_reschedule()
	_refresh_card_views()
	_index_queries = false
	_group_index.clear()
	return winner >= 0 or left <= 0.0

func drain_events() -> Array:
	var output: Array = _events
	_events = []
	return output

func _activate_transfer(tool_id: int, group: int) -> bool:
	if _available_people(group).is_empty(): return _fail("这个组没有能工作的人员")
	if _transfer_work(group).is_empty(): return _fail("没有可以甩出去的工作")
	_cancel_group_work(group)
	groups[group].job = "transfer"
	if not groups[group].has("transfer_progress"): groups[group]["transfer_progress"] = 0.0
	cards[tool_id].status = "active"
	cards[tool_id].total = config.number("transfer", "seconds")
	cards[tool_id]["transfer_group"] = group
	cards[tool_id]["destination"] = -1
	_sync_transfer_groups()
	_emit("transfer_start", {"owner": cards[tool_id].owner, "source": tool_id, "group": group, "targets": group_transfer_participants(group)})
	_refresh_card_views()
	return true

func _transfer_work(group: int) -> Array:
	var works := group_work(group)
	for task in tasks.values():
		if task.kind == "coffee": works.erase(task.work_id)
	return works

func _sync_transfer_groups() -> void:
	for person in tasks.keys():
		if tasks[person].kind == "transfer": tasks.erase(person)
	for id in _cards_of_type("transfer"):
		var card: Dictionary = cards[id]
		if card.type == "transfer" and card.status == "active" and int(card.get("transfer_group", -1)) != int(card.group):
			card.status = "ready"
			card.remaining = 0.0
			card.total = 0.0
	for group in groups:
		if not _accepts_function(int(group), "transfer"):
			if _group_type(int(group), "transfer").is_empty(): groups[group].erase("transfer_progress")
			for id in _group_type(int(group), "transfer"):
				if cards[id].status == "active":
					cards[id].status = "ready"
					cards[id].remaining = 0.0
					cards[id].total = 0.0
			continue
		var tool := -1
		for id in _group_type(int(group), "transfer"):
			if cards[id].status == "active": tool = int(id); break
		# A previously used combination waits for its people/materials rather
		# than requiring another button press when they become available.
		if tool < 0 and not _transfer_work(int(group)).is_empty() and not _available_people(int(group)).is_empty():
			for id in _group_type(int(group), "transfer"):
				if cards[id].status == "ready" and int(cards[id].get("transfer_group", -1)) == int(group):
					tool = int(id)
					cards[tool].status = "active"
					cards[tool].total = config.number("transfer", "seconds")
					if not groups[group].has("transfer_progress"): groups[group]["transfer_progress"] = 0.0
					break
		if tool < 0:
			if _group_type(int(group), "transfer").is_empty(): groups[group].erase("transfer_progress")
			continue
		var works := _transfer_work(int(group))
		var people := group_people(int(group))
		if works.is_empty() or people.is_empty():
			cards[tool].status = "ready"
			cards[tool].remaining = 0.0
			cards[tool].total = 0.0
			if works.is_empty(): groups[group].erase("transfer_progress")
			continue
		groups[group].job = "transfer"
		_cancel_group_work(int(group))
		people.sort_custom(func(a, b): return int(config.roles[cards[a].type].transfer_capacity) > int(config.roles[cards[b].type].transfer_capacity))
		var index := 0
		for person in people:
			if tasks.has(person) or _is_paused(int(person)): continue
			if index >= works.size(): break
			tasks[person] = {"kind": "transfer", "group": group, "tool_id": tool, "work_id": works[index], "progress": group_transfer_progress(int(group))}
			index += 1

func _activate_slack(_tool_id: int, group: int) -> bool:
	if not _accepts_function(group, "slack"):
		return _fail("这个组已经在执行另一种任务")
	if _available_people(group).is_empty() and group_slack_participants(group).is_empty() and not groups[group].has("slack_progress"):
		return _fail("这个组没有能摸鱼的人员")
	_sync_slack_groups()
	_refresh_card_views()
	return str(groups[group].job) == "slack"

func _sync_slack_groups() -> void:
	# Rebuild slots from current membership. Joining/leaving changes only this
	# batch's output; callers retain the group's single progress clock.
	for person in tasks.keys():
		if tasks[person].kind == "slack": tasks.erase(person)
	for group in groups:
		var tools := _group_type(int(group), "slack")
		if tools.is_empty():
			_sync_group_function(int(group))
			groups[group].erase("slack_progress")
			continue
		var people := group_people(int(group))
		var eligible: bool = _accepts_function(int(group), "slack") and (not people.is_empty() or groups[group].has("slack_progress"))
		if not eligible:
			for id in tools:
				cards[id].status = "ready"
				cards[id].progress = 0.0
				cards[id].remaining = 0.0
				cards[id].total = 0.0
			continue
		var starting: bool = not tools.any(func(id): return cards[id].status == "active")
		if not groups[group].has("slack_progress"):
			var carried := 0.0
			for id in tools:
				if cards[id].status == "active":
					carried = float(cards[id].progress)
					break
			groups[group]["slack_progress"] = carried
		groups[group].job = "slack"
		_cancel_group_work(int(group))
		var duration: float = 1.0 / config.slack_rate(tools.size())
		for id in tools:
			cards[id].status = "active"
			cards[id].total = duration
		for person in people:
			if tasks.has(person) or _is_paused(int(person)): continue
			tasks[person] = {"kind": "slack", "group": group, "tool_id": tools[0], "work_id": -1, "progress": group_slack_progress(int(group))}
		if starting:
			_emit("slack_start", {"owner": groups[group].owner, "source": tools[0], "group": group, "targets": group_slack_participants(int(group))})

## Meeting combinations share one session, all available hosts and one clock.
## The representative host/tool remain for old recordings and presentation.
func group_meeting_hosts(group: int) -> Array:
	var result: Array = []
	for person in group_people(group):
		if _is_paused(int(person)): continue
		var task: Dictionary = tasks.get(person, {})
		if task.is_empty() or task.kind == "work" or (task.kind == "meeting" and int(task.group) == group):
			result.append(person)
	return result

func group_meeting_tools(group: int) -> Array:
	return _group_type(group, "meeting").duplicate()

func group_meeting_capacity(group: int) -> int:
	var capacity := 0
	for person in group_meeting_hosts(group):
		capacity += config.meeting_capacity(str(cards[person].type))
	return capacity

func group_meeting_duration(group: int) -> float:
	return config.meeting_duration(group_meeting_tools(group).size())

## An idle stack starts only after every participating tool has recovered.
func group_meeting_ready_seconds(group: int) -> float:
	var remaining := 0.0
	for tool in group_meeting_tools(group):
		if cards[tool].status == "recovering":
			remaining = maxf(remaining, float(cards[tool].remaining))
	return remaining

func meeting_for_tool(tool_id: int) -> Dictionary:
	if meetings.has(tool_id): return meetings[tool_id]
	for meeting in meetings.values():
		if meeting.get("tools", []).has(tool_id): return meeting
	return {}

func _meeting_in_group(group: int) -> int:
	for tool_id in meetings:
		if int(meetings[tool_id].group) == group: return int(tool_id)
	return -1

func _meeting_group_cooling(group: int) -> bool:
	return group_meeting_tools(group).any(func(id): return cards[id].status == "recovering")

func _draw_meeting_targets(owner: int, capacity: int, retained: Array = []) -> Array:
	var selected := retained.duplicate()
	if selected.size() > capacity: selected.resize(capacity)
	if selected.size() >= capacity: return selected
	var candidates := meeting_candidates(owner)
	for person in selected: candidates.erase(person)
	while not candidates.is_empty() and selected.size() < capacity:
		selected.append(candidates.pop_at(_rng.randi_range(0, candidates.size() - 1)))
	return selected

func _assign_meeting(tool_id: int, meeting: Dictionary) -> void:
	_cancel_group_work(int(meeting.group))
	groups[meeting.group].job = "meeting"
	for tool in meeting.tools:
		cards[tool].status = "active"
		cards[tool]["meeting_repeat"] = true
		cards[tool].total = meeting.total
		cards[tool].remaining = meeting.remaining
	for person in meeting.hosts:
		var task: Dictionary = tasks.get(person, {})
		if task.get("kind") == "meeting" and int(task.tool_id) == tool_id and int(task.group) == int(meeting.group): continue
		tasks[person] = {"kind": "meeting", "tool_id": tool_id, "group": meeting.group, "work_id": -1, "progress": 0.0}
	for person in meeting.targets:
		if tasks.has(person) and tasks[person].kind == "coffee":
			_cancel_coffee(int(person), tasks[person].duplicate(true))

func _activate_meeting(tool_id: int, group: int, selected_host: int) -> bool:
	if not _accepts_function(group, "meeting"):
		return _fail("这个组合已在执行其他功能")
	if _meeting_in_group(group) >= 0:
		return _fail("这组已经在共同开会")
	if _meeting_group_cooling(group):
		return _fail("这组开会牌仍在冷却")
	var people := group_meeting_hosts(group)
	if people.is_empty(): return _fail("需要至少一名空闲的主持人")
	people.sort_custom(func(a: int, b: int) -> bool:
		return config.meeting_capacity(str(cards[a].type)) > config.meeting_capacity(str(cards[b].type)))
	var host: int = selected_host if people.has(selected_host) else int(people[0])
	var targets := _draw_meeting_targets(int(cards[tool_id].owner), group_meeting_capacity(group))
	if targets.is_empty(): return _fail("对面没有可叫来开会的人")
	var tools := group_meeting_tools(group)
	var duration: float = config.meeting_duration(tools.size())
	var meeting := {"id": tool_id, "host": host, "hosts": people, "tools": tools, "group": group,
		"targets": targets, "remaining": duration, "total": duration}
	meetings[tool_id] = meeting
	_assign_meeting(tool_id, meeting)
	_emit("meeting_start", {"owner": cards[tool_id].owner, "source": tool_id, "group": group,
		"host": host, "hosts": people.duplicate(), "tools": tools.duplicate(), "targets": targets.duplicate()})
	_sync_coffee_groups()
	_refresh_card_views()
	return true

## Reconcile membership without restarting either the meeting or its cooldown.
## Added/removed tools preserve completed progress; added hosts fill vacancies
## while existing targets keep their identities until capacity actually shrinks.
func _sync_meetings() -> void:
	_coalesce_meeting_groups()
	for original_tool in meetings.keys():
		if not meetings.has(original_tool): continue
		var meeting: Dictionary = meetings[original_tool]
		var group := int(meeting.group)
		var old_tools: Array = meeting.get("tools", [original_tool])
		var old_hosts: Array = meeting.get("hosts", [meeting.host])
		var tools: Array = []
		for tool in group_meeting_tools(group):
			if cards[tool].status == "ready" or (old_tools.has(tool) and cards[tool].status == "active"):
				tools.append(tool)
		var people := group_meeting_hosts(group)
		if tools.is_empty() or people.is_empty():
			_end_meeting(int(original_tool))
			continue
		for tool in old_tools:
			if not tools.has(tool) and cards.has(tool): _recover(int(tool))
		for person in old_hosts:
			if not people.has(person) and tasks.has(person) and tasks[person].kind == "meeting" and int(tasks[person].tool_id) == int(original_tool):
				tasks.erase(person)
		var tool_id := int(original_tool) if tools.has(original_tool) else int(tools[0])
		if tool_id != int(original_tool):
			meetings.erase(original_tool)
			meetings[tool_id] = meeting
		if not meeting.has("id"): meeting.id = original_tool
		if not people.has(meeting.host): meeting.host = people[0]
		if tools.size() != old_tools.size():
			var fraction := clampf(float(meeting.remaining) / float(meeting.total), 0.0, 1.0)
			meeting.total = config.meeting_duration(tools.size())
			meeting.remaining = fraction * float(meeting.total)
		# 名额随主持人增减：新增主持只补足新增的名额，减少主持按原顺序收回名额。
		# 开会时就空着的名额不再补人，之后才到场的对方人员不会被拉进这场会。
		var previous_capacity := 0
		for person in old_hosts:
			if cards.has(person): previous_capacity += config.meeting_capacity(str(cards[person].type))
		var capacity := group_meeting_capacity(group)
		meeting.hosts = people
		meeting.tools = tools
		var retained: Array = meeting.targets.filter(func(id): return cards.has(id))
		var seats: int = mini(capacity, retained.size() + maxi(0, capacity - previous_capacity))
		meeting.targets = _draw_meeting_targets(int(cards[tool_id].owner), seats, retained)
		_assign_meeting(tool_id, meeting)

## Older checkpoints could hold several independent sessions in one stack.
## Normalize them once through the same shared timer, retaining every visitor
## without resetting progress or cooling a tool that still participates.
func _coalesce_meeting_groups() -> void:
	var primary_by_group := {}
	for tool_id in meetings.keys():
		var meeting: Dictionary = meetings[tool_id]
		var group := int(meeting.group)
		if not primary_by_group.has(group):
			primary_by_group[group] = tool_id
			continue
		var primary: int = primary_by_group[group]
		var shared: Dictionary = meetings[primary]
		var fraction := minf(float(shared.remaining) / float(shared.total), float(meeting.remaining) / float(meeting.total))
		var tools: Array = shared.get("tools", [primary]).duplicate()
		var hosts: Array = shared.get("hosts", [shared.host]).duplicate()
		for tool in meeting.get("tools", [tool_id]):
			if not tools.has(tool): tools.append(tool)
		for person in meeting.get("hosts", [meeting.host]):
			if not hosts.has(person): hosts.append(person)
		for person in meeting.targets:
			if not shared.targets.has(person): shared.targets.append(person)
		shared.tools = tools
		shared.hosts = hosts
		shared.total = config.meeting_duration(tools.size())
		shared.remaining = clampf(fraction, 0.0, 1.0) * float(shared.total)
		meetings.erase(tool_id)

func meeting_candidates(owner: int) -> Array:
	var candidates: Array = []
	_ensure_membership_index()
	for id in _people_ids:
		var card: Dictionary = cards[id]
		if int(card.owner) == owner or not config.can_be_meeting_target(str(card.type)) or _is_paused(int(id)):
			continue
		if tasks.has(id) and str(tasks[id].kind) == "meeting":
			continue
		candidates.append(id)
	return candidates

func _restart_ready_meetings() -> void:
	if winner >= 0 or not bool(config.rules.meeting.auto_repeat): return
	for id in _cards_of_type("meeting"):
		var card: Dictionary = cards[id]
		if card.type != "meeting" or card.status != "ready" or not bool(card.get("meeting_repeat", false)):
			continue
		var group: int = int(card.group)
		if not groups.has(group) or not _accepts_function(group, "meeting") or _available_people(group).is_empty():
			continue
		# Waiting for an eligible opponent is idle, not a failed player command.
		if _meeting_in_group(group) >= 0 or _meeting_group_cooling(group): continue
		if meeting_candidates(int(card.owner)).is_empty(): continue
		_activate_meeting(int(id), group, -1)

func _activate_coffee(coffee_id: int, group: int, target_card: int) -> bool:
	if not group_work(group).is_empty():
		return _fail("这组还有工作；请把人员与咖啡另组一摞")
	if int(cards[coffee_id].group) != group:
		return _fail("先把人员拆出工作堆，再与咖啡单独组堆")
	if target_card < -1: return _fail("要提升卷度的人员已经不存在")
	if str(groups[group].job) not in ["work", "meeting"]:
		return _fail("这个组正在执行其他任务")
	if tasks.values().any(func(task): return task.kind == "coffee" and int(task.group) == group):
		return _fail("这组正在升级，新加入的人员和咖啡将在下一轮处理")
	var available: Array = _group_type(group, "coffee").filter(func(id): return cards[id].status == "ready")
	if not available.has(coffee_id): return _fail("这杯咖啡已分配给本轮升级")
	var people: Array = []
	for person in group_people(group):
		if not _is_paused(int(person)) and (not tasks.has(person) or tasks[person].kind == "work"):
			people.append({"id": int(person), "kind": str(cards[person].type)})
	var plan: Dictionary = CoffeePlanSource.plan(config, people, available.size())
	if plan.upgrades.is_empty(): return _fail("请为要提升卷度的人员补足咖啡")
	# Freeze every final role and ingredient allocation before publishing the
	# round. Late arrivals remain ready and cannot change this committed plan.
	available.erase(coffee_id)
	available.push_front(coffee_id)
	var members: Array = plan.upgrades.map(func(upgrade): return int(upgrade.person))
	var batch_owner := int(members[0])
	var duration: float = config.coffee_batch_seconds()
	var offset := 0
	for upgrade in plan.upgrades:
		var person := int(upgrade.person)
		var ingredients := available.slice(offset, offset + int(upgrade.cost))
		offset += int(upgrade.cost)
		var resume: Dictionary = tasks.get(person, {}).duplicate(true)
		tasks[person] = {"kind": "coffee", "group": group, "tool_id": ingredients[0],
			"coffee_ids": ingredients, "from_type": upgrade.from_type, "to_type": upgrade.to_type,
			"steps": upgrade.steps.duplicate(true), "total": duration, "batch_owner": batch_owner,
			"work_id": int(resume.get("work_id", -1)),
			"progress": 0.0, "resume_task": resume}
		if person == batch_owner: tasks[person]["batch_members"] = members.duplicate()
		for id in ingredients:
			cards[id].status = "active"
			cards[id].total = duration
			cards[id].remaining = duration
	for person in members:
		var task: Dictionary = tasks[person]
		var event := {"source": task.tool_id, "owner": cards[person].owner,
			"group": group, "person": person, "targets": [person], "batch_owner": batch_owner,
			"coffee_ids": task.coffee_ids.duplicate(),
			"from_type": task.from_type, "to_type": task.to_type,
			"steps": task.steps.duplicate(true), "amount": task.coffee_ids.size()}
		if int(person) == batch_owner: event["batch_members"] = members.duplicate()
		_emit("coffee_start", event)
	if duration == 0.0: _complete_task(batch_owner)
	_refresh_card_views()
	return true

func _coffee_batch_members(person: int, task: Dictionary) -> Array:
	# Store the roster once, so many-person rounds and their saved replays grow
	# linearly. Legacy tasks without a batch owner retain their one-person clock.
	var owner := int(task.get("batch_owner", person))
	var source: Dictionary = task if owner == person else tasks.get(owner, task)
	return source.get("batch_members", [person])

func _coffee_batch_valid(person: int, task: Dictionary) -> bool:
	if not cards.has(person): return false
	var group := int(cards[person].group)
	if not group_work(group).is_empty(): return false
	var batch_owner := int(task.get("batch_owner", person))
	var members := _coffee_batch_members(person, task)
	if not members.has(batch_owner) or not tasks.has(batch_owner): return false
	for member in members:
		var current: Dictionary = task if int(member) == person else tasks.get(member, {})
		if current.get("kind") != "coffee" or int(current.get("batch_owner", member)) != batch_owner: return false
		if not cards.has(member) or str(cards[member].type) != str(current.from_type) \
				or int(cards[member].group) != group or _is_paused(int(member)): return false
		for id in current.coffee_ids:
			if not cards.has(id) or cards[id].type != "coffee" or int(cards[id].group) != group: return false
	return true

func has_invalid_coffee_batch() -> bool:
	var seen := {}
	for person in tasks:
		var task: Dictionary = tasks[person]
		if task.kind != "coffee": continue
		var owner := int(task.get("batch_owner", person))
		if seen.has(owner): continue
		seen[owner] = true
		if not _coffee_batch_valid(int(person), task): return true
	return false

func _sync_coffee_groups() -> void:
	# One immutable upgrade round per combination. Only after it settles or is
	# cancelled do ready materials and eligible personnel form a new snapshot.
	var previous_error := last_error
	for group in groups:
		if str(groups[group].job) not in ["work", "meeting"] or not group_work(int(group)).is_empty(): continue
		if tasks.values().any(func(task): return task.kind == "coffee" and int(task.group) == int(group)): continue
		for id in _group_type(int(group), "coffee"):
			if cards[id].status == "ready":
				_activate_coffee(int(id), int(group), -1)
				break
	last_error = previous_error

func _restore_coffee_work(person: int, task: Dictionary) -> void:
	var resume: Dictionary = task.get("resume_task", {})
	if resume.is_empty() or not cards.has(person) or not cards.has(resume.work_id): return
	var group: int = int(cards[person].group)
	if int(cards[resume.work_id].group) != group or not groups.has(group) or str(groups[group].job) not in ["work", "meeting"]: return
	for current in tasks.values():
		if int(current.work_id) == int(resume.work_id): return
	resume.group = group
	tasks[person] = resume

func _cancel_coffee(person: int, task: Dictionary) -> void:
	var snapshots := {}
	for member in _coffee_batch_members(person, task):
		var current: Dictionary = task if int(member) == person else tasks.get(member, {})
		if current.get("kind") == "coffee": snapshots[member] = current.duplicate(true)
	for member in snapshots: tasks.erase(member)
	for member in snapshots:
		var current: Dictionary = snapshots[member]
		for id in current.coffee_ids:
			if not cards.has(id): continue
			cards[id].status = "ready"
			cards[id].progress = 0.0
			cards[id].total = 0.0
			cards[id].remaining = 0.0
		_restore_coffee_work(int(member), current)
		_emit("coffee_cancel", {"source": current.tool_id, "person": member, "group": current.group,
			"coffee_ids": current.coffee_ids.duplicate()})

func can_strike_group(group: int, attacker_owner: int) -> bool:
	if winner >= 0 or not groups.has(group) or int(groups[group].owner) == attacker_owner:
		return false
	if not config.rules.simulation.owners.any(func(value): return int(value) == attacker_owner):
		return false
	if group_has_union(group): return false
	if group_people(group).filter(func(person): return can_person_be_struck(int(person))).is_empty():
		return false
	if group_work_rate(group) > 0.0 or group_transfer_rate(group) > 0.0 or group_slack_rate(group) > 0.0:
		return true
	for tool_id in outsourcing:
		if int(outsourcing[tool_id].group) == group and _outsource_batch_valid(int(tool_id)):
			return true
	return false

func _activate_strike(tool_id: int, group: int, delivered := false) -> bool:
	var owner: int = int(cards[tool_id].owner)
	if not can_strike_group(group, owner):
		return _fail("罢工需要对方正在处理工作或摸鱼的组合，且组内有人员")
	var flight_seconds := float(config.rules.strike.get("flight_seconds", 0.0))
	if delivered or flight_seconds <= 0.0:
		_apply_strike(tool_id, group)
		return true
	var flight := {"source": tool_id, "owner": owner, "group": int(cards[tool_id].group),
		"target_group": group, "duration": flight_seconds, "total": flight_seconds, "remaining": flight_seconds}
	pending_strikes[tool_id] = flight
	cards[tool_id].status = "in_flight"
	cards[tool_id].total = flight_seconds
	cards[tool_id].remaining = flight_seconds
	cards[tool_id].progress = 0.0
	_emit("strike_launch", flight.duplicate(true))
	revision += 1
	return true

func _resolve_strike(tool_id: int) -> void:
	var flight: Dictionary = pending_strikes[tool_id]
	pending_strikes.erase(tool_id)
	if not cards.has(tool_id): return
	var target := int(flight.target_group)
	if can_strike_group(target, int(flight.owner)):
		_apply_strike(tool_id, target)
		return
	_return_strike(tool_id, flight, "union" if group_has_union(target) else "target_unavailable")

func _return_strike(tool_id: int, flight: Dictionary, reason: String) -> void:
	if not cards.has(tool_id): return
	cards[tool_id].status = "ready"
	cards[tool_id].total = 0.0
	cards[tool_id].remaining = 0.0
	cards[tool_id].progress = 0.0
	flight["reason"] = reason
	_emit("strike_blocked", flight)
	revision += 1

func _cancel_pending_strikes() -> void:
	for tool_id in pending_strikes.keys():
		var flight: Dictionary = pending_strikes[tool_id]
		pending_strikes.erase(tool_id)
		_return_strike(int(tool_id), flight, "match_finished")

func _apply_strike(tool_id: int, group: int) -> void:
	var owner: int = int(cards[tool_id].owner)
	var source_group: int = int(cards[tool_id].group)
	var duration: float = config.number("strike", "duration_seconds")
	var affected: Array = group_people(group).filter(func(person): return can_person_be_struck(int(person)))
	for person in affected:
		# Moving a host ends its meeting; moving an upgrading employee cancels
		# the upgrade through the normal scheduler and returns its ingredient.
		groups[group].cards.erase(person)
		var destination := create_group(int(cards[person].owner))
		groups[destination].cards.append(person)
		cards[person].group = destination
		cards[person].status = "striking"
		cards[person].total = duration
		cards[person].remaining = duration
	_invalidate_group_layout([group])
	_consume(tool_id)
	_cleanup_groups()
	_reschedule()
	_emit("strike", {"source": tool_id, "owner": owner, "group": source_group,
		"target_group": group, "targets": affected, "ids": affected, "duration": duration})

## Dismiss only the selected personnel. Validate the whole request before any
## removal, refund or task changes so malformed drag payloads cannot partly sell.
func dismiss_people(ids: Array, owner: int) -> bool:
	last_error = ""
	if winner >= 0:
		return _fail("已经下班了")
	if ids.is_empty() or not config.rules.simulation.owners.any(func(value): return int(value) == owner):
		return _fail("请拖入己方人员")
	var seen: Dictionary = {}
	for person in ids:
		if not person is int or seen.has(person) or not cards.has(person):
			return _fail("人员选择无效或重复")
		if int(cards[person].owner) != owner or not config.is_person(str(cards[person].type)):
			return _fail("只能开除己方人员")
		if is_meeting_target(person):
			return _fail("开会中的人员暂时不能开除")
		seen[person] = true
	if people_count(owner) - ids.size() < config.integer("fire", "minimum_people"):
		return _fail("未达到配置要求的保留人数")
	for person in ids:
		var group: int = int(cards[person].group)
		var refund: int = int(config.cards[cards[person].type].refund)
		for meeting in meetings.values():
			meeting.targets.erase(person)
		_consume(person)
		var money_ids: Array = _credit(owner, refund)
		var money_id: int = int(money_ids[0]) if not money_ids.is_empty() else -1
		_emit("fire", {"source": person, "owner": owner, "group": group, "targets": [person], "amount": refund,
			"money_ids": money_ids, "money_id": money_id, "money_group": int(cards[money_id].group) if money_id >= 0 else -1})
	_reschedule()
	return true

func _activate_outsource(tool_id: int, group: int) -> bool:
	if int(cards[tool_id].group) != group:
		return _fail("先把外包与金钱、工作叠成一组")
	if not _accepts_function(group, "outsource"):
		return _fail("这个组正在执行另一种任务")
	var owner: int = int(cards[tool_id].owner)
	var materials := _outsource_additions(group)
	if materials.work_ids.is_empty():
		return _fail("把金钱和工作一起叠到外包牌上")
	var duration: float = config.number("outsource", "seconds")
	outsourcing[tool_id] = {"group": group, "owner": owner, "work_ids": materials.work_ids,
		"payments": materials.payments, "amount": materials.amount, "total": duration, "remaining": duration}
	_cancel_group_work(group)
	groups[group].job = "outsource"
	cards[tool_id].status = "active"
	cards[tool_id].total = duration
	cards[tool_id].remaining = duration
	_emit("outsource_start", {"source": tool_id, "owner": owner, "group": group, "ids": materials.work_ids.duplicate()})
	_refresh_card_views()
	return true

func _outsource_additions(group: int, reserved_work: Array = []) -> Dictionary:
	var works: Array = group_work(group).filter(func(id): return not reserved_work.has(id))
	var cash: Array = _group_type(group, "money")
	var funds := 0
	for id in cash: funds += available_cash_amount(int(id))
	var unit: int = config.integer("outsource", "cost_per_work")
	var count: int = mini(works.size(), funds / unit)
	var payments: Dictionary = {}
	var left := count * unit
	for id in cash:
		var take: int = mini(left, available_cash_amount(int(id)))
		if take > 0: payments[id] = take
		left -= take
		if left == 0: break
	return {"work_ids": works.slice(0, count), "payments": payments, "amount": count * unit}

func _sync_outsource_groups() -> void:
	# New ingredients join the current reading without restarting its clock.
	# Existing reservations have already been validated before extending them.
	for tool_id in outsourcing:
		var batch: Dictionary = outsourcing[tool_id]
		var additions := _outsource_additions(int(batch.group), batch.work_ids)
		batch.work_ids.append_array(additions.work_ids)
		for cash_id in additions.payments:
			batch.payments[cash_id] = int(batch.payments.get(cash_id, 0)) + int(additions.payments[cash_id])
		batch.amount += int(additions.amount)
	# Valid combinations start as soon as ingredients or the recovered tool
	# become available, including after a cancelled batch has been rebuilt.
	for tool_id in _cards_of_type("outsource"):
		var tool: Dictionary = cards[tool_id]
		if tool.type != "outsource" or tool.status != "ready": continue
		var group: int = int(tool.group)
		if not _accepts_function(group, "outsource") or group_work(group).is_empty(): continue
		if _outsource_additions(group).work_ids.is_empty(): continue
		_activate_outsource(int(tool_id), group)

func _outsource_batch_valid(tool_id: int) -> bool:
	if not outsourcing.has(tool_id) or not cards.has(tool_id): return false
	var batch: Dictionary = outsourcing[tool_id]
	var group: int = int(batch.group)
	if not groups.has(group) or int(cards[tool_id].group) != group: return false
	for id in batch.work_ids:
		if not cards.has(id) or cards[id].type != "work" or int(cards[id].group) != group:
			return false
	for id in batch.payments:
		if not cards.has(id) or cards[id].type != "money" or int(cards[id].group) != group or int(cards[id].amount) < int(batch.payments[id]):
			return false
	return true

func _cancel_outsource(tool_id: int) -> void:
	if not outsourcing.has(tool_id): return
	var batch: Dictionary = outsourcing[tool_id]
	outsourcing.erase(tool_id)
	if cards.has(tool_id):
		cards[tool_id].status = "ready"
		cards[tool_id].progress = 0.0
		cards[tool_id].remaining = 0.0
		cards[tool_id].total = 0.0
	if groups.has(batch.group): _sync_group_function(int(batch.group))
	_emit("outsource_cancel", {"source": tool_id, "owner": batch.owner, "group": batch.group})

func _validate_outsource_batches() -> void:
	for tool_id in outsourcing.keys():
		if not _outsource_batch_valid(int(tool_id)): _cancel_outsource(int(tool_id))

func _complete_outsource(tool_id: int) -> void:
	# Validate the entire current reservation before touching money or work; dismantling
	# it never yields partial work or consumes ingredients for an aborted job.
	if not _outsource_batch_valid(tool_id):
		_cancel_outsource(tool_id)
		return
	var batch: Dictionary = outsourcing[tool_id]
	outsourcing.erase(tool_id)
	for id in batch.payments:
		cards[id].amount -= int(batch.payments[id])
		if int(cards[id].amount) == 0: _consume(int(id))
	for id in batch.work_ids: _consume(int(id))
	_sync_group_function(int(batch.group))
	_recover(tool_id)
	_emit("outsource", {"source": tool_id, "owner": batch.owner, "group": batch.group,
		"ids": batch.work_ids, "spent": batch.amount, "amount": batch.work_ids.size()})

## Capacity concerns physical cards, not money amounts. Only this payment's
## fully consumed UIDs release space; another batch's promised payment cannot.
func _recruitment_net_growth(count: int, payments: Dictionary) -> int:
	var freed := 0
	for id in payments:
		if cards.has(id) and cards[id].type == "money" and int(payments[id]) > 0 \
				and int(payments[id]) == int(cards[id].amount): freed += 1
	return count - freed

func _recruitment_payments(cash: Array, available: Array, amount: int) -> Dictionary:
	var payments: Dictionary = {}
	var left := amount
	for index in cash.size():
		if left == 0: break
		var take := mini(left, int(available[index]))
		if take > 0: payments[int(cash[index])] = take
		left -= take
	return payments

func _recruitment_additions(group: int, boss_id: int = -1) -> Dictionary:
	var cash: Array = _group_type(group, "money")
	var available: Array = []
	var funds := 0
	for id in cash:
		var amount := available_cash_amount(int(id))
		available.append(amount)
		funds += amount
	var current: Dictionary = recruitment.get(boss_id, {})
	var existing_count := int(current.get("count", 0))
	var existing_payments: Dictionary = current.get("payments", {})
	var reserved_growth := 0
	for other in recruitment:
		if int(other) == boss_id: continue
		var batch: Dictionary = recruitment[other]
		reserved_growth += maxi(0, _recruitment_net_growth(int(batch.count), batch.payments))
	# Existing worlds may already exceed the allocation guard through ordinary
	# income. A non-growing transaction can still clean them up in several steps.
	var capacity := maxi(0, OffWorkConfig.MAX_CARD_ALLOCATION - cards.size() - reserved_growth)
	var unit: int = config.integer("recruitment", "cost_per_employee")
	var limit := maxi(0, mini(funds / unit, OffWorkConfig.MAX_CARD_ALLOCATION - existing_count))
	if limit == 0: return {"count": 0, "payments": {}, "amount": 0}
	var freed := existing_count - _recruitment_net_growth(existing_count, existing_payments)
	var maximum := _recruitment_payments(cash, available, limit * unit)
	var maximum_freed := freed
	for id in maximum:
		if int(existing_payments.get(id, 0)) + int(maximum[id]) == int(cards[id].amount): maximum_freed += 1
	# Ordinary unit-money payments usually shrink the world. Admit the maximum
	# immediately instead of walking thousands of employee thresholds per tick.
	if existing_count + limit - maximum_freed <= capacity:
		return {"count": limit, "payments": maximum, "amount": limit * unit}
	var count := 0
	var cash_index := 0
	var taken_from_card := 0
	# Feasibility is not monotone: spending five from a six-money wallet frees
	# nothing, but spending ten across that wallet and four unit cards frees five
	# UIDs. Visit every bounded employee threshold with one forward cash scan.
	for addition in range(1, limit + 1):
		var needed := unit
		while needed > 0 and cash_index < cash.size():
			var id: int = cash[cash_index]
			var take := mini(needed, int(available[cash_index]) - taken_from_card)
			needed -= take
			taken_from_card += take
			if take > 0 and int(existing_payments.get(id, 0)) + taken_from_card == int(cards[id].amount): freed += 1
			if taken_from_card == int(available[cash_index]):
				cash_index += 1
				taken_from_card = 0
		if existing_count + addition - freed <= capacity: count = addition
	var payments := _recruitment_payments(cash, available, count * unit)
	return {"count": count, "payments": payments, "amount": count * unit}

func _sync_recruitment_groups() -> void:
	if not config.cards.has("boss"): return
	for boss_id in recruitment:
		var batch: Dictionary = recruitment[boss_id]
		var additions := _recruitment_additions(int(batch.group), int(boss_id))
		batch.count += int(additions.count)
		batch.amount += int(additions.amount)
		for id in additions.payments: batch.payments[id] = int(batch.payments.get(id, 0)) + int(additions.payments[id])
	for boss_id in _cards_of_type("boss"):
		if cards[boss_id].type != "boss" or tasks.has(boss_id) or recruitment.has(boss_id): continue
		var group := int(cards[boss_id].group)
		if str(groups[group].job) != "work": continue
		var materials := _recruitment_additions(group, int(boss_id))
		if int(materials.count) == 0: continue
		var duration: float = config.number("recruitment", "seconds")
		var owner := int(cards[boss_id].owner)
		recruitment[boss_id] = {"owner": owner, "group": group, "payments": materials.payments,
			"count": materials.count, "amount": materials.amount, "total": duration, "remaining": duration}
		tasks[boss_id] = {"kind": "recruitment", "tool_id": boss_id, "work_id": -1, "group": group, "progress": 0.0}
		cards[boss_id].status = "active"
		cards[boss_id].total = duration
		cards[boss_id].remaining = duration
		_emit("recruitment_start", {"source": boss_id, "owner": owner, "group": group,
			"count": materials.count, "amount": materials.count, "spent": materials.amount})

func _recruitment_batch_valid(boss_id: int) -> bool:
	if not recruitment.has(boss_id) or not cards.has(boss_id) or cards[boss_id].type != "boss": return false
	var batch: Dictionary = recruitment[boss_id]
	var group := int(batch.group)
	if not groups.has(group) or int(cards[boss_id].group) != group: return false
	for id in batch.payments:
		if not cards.has(id) or cards[id].type != "money" or int(cards[id].group) != group or int(cards[id].amount) < int(batch.payments[id]):
			return false
	return true

func _cancel_recruitment(boss_id: int) -> void:
	if not recruitment.has(boss_id): return
	var batch: Dictionary = recruitment[boss_id]
	recruitment.erase(boss_id)
	if tasks.has(boss_id) and tasks[boss_id].kind == "recruitment": tasks.erase(boss_id)
	if cards.has(boss_id):
		cards[boss_id].status = "ready"
		cards[boss_id].total = 0.0
		cards[boss_id].remaining = 0.0
		cards[boss_id].progress = 0.0
	_emit("recruitment_cancel", {"source": boss_id, "owner": batch.owner, "group": batch.group,
		"count": batch.count, "amount": batch.count, "spent": 0})

func _validate_recruitment_batches() -> void:
	for boss_id in recruitment.keys():
		if not _recruitment_batch_valid(int(boss_id)): _cancel_recruitment(int(boss_id))

func _complete_recruitment(boss_id: int) -> void:
	if not _recruitment_batch_valid(boss_id):
		_cancel_recruitment(boss_id)
		return
	var batch: Dictionary = recruitment[boss_id]
	if int(batch.count) < 1 or int(batch.count) > OffWorkConfig.MAX_CARD_ALLOCATION \
			or _recruitment_net_growth(int(batch.count), batch.payments) > maxi(0, OffWorkConfig.MAX_CARD_ALLOCATION - cards.size()):
		_cancel_recruitment(boss_id)
		return
	recruitment.erase(boss_id)
	tasks.erase(boss_id)
	for id in batch.payments:
		cards[id].amount -= int(batch.payments[id])
		if int(cards[id].amount) == 0: _consume(int(id))
	cards[boss_id].status = "ready"
	cards[boss_id].total = 0.0
	cards[boss_id].remaining = 0.0
	cards[boss_id].progress = 0.0
	var destination := create_group(int(batch.owner))
	var employees: Array = []
	for _index in int(batch.count): employees.append(add_card("employee", int(batch.owner), destination))
	_emit("recruitment_complete", {"source": boss_id, "owner": batch.owner, "group": batch.group,
		"count": batch.count, "amount": batch.count, "spent": batch.amount, "ids": employees,
		"person_ids": employees, "person_group": destination})

## Explicit reconciliation remains available to importers/editor fixtures that
## change public records directly. Internal events already invalidate exactly
## when they mutate membership and must reuse the indexes built in that event.
func _sync_schedule(start_coffee := true) -> void:
	_invalidate_group_index()
	_reschedule(start_coffee)

func _reschedule(start_coffee := true) -> void:
	_eject_union_overtime()
	for group in groups: _sync_group_function(int(group))
	_validate_outsource_batches()
	_validate_recruitment_batches()
	_sync_meetings()
	var valid_coffee_batches := {}
	for person in tasks.keys():
		if not tasks.has(person): continue
		var task: Dictionary = tasks[person]
		var coffee_valid := true
		if task.kind == "coffee":
			var batch_owner := int(task.get("batch_owner", person))
			if not valid_coffee_batches.has(batch_owner):
				valid_coffee_batches[batch_owner] = _coffee_batch_valid(int(person), task)
			coffee_valid = bool(valid_coffee_batches[batch_owner])
		# Moving the complete batch with its reserved cups preserves its timer.
		if task.kind == "coffee" and coffee_valid:
			task.group = cards[person].group
			# The pair may leave its work behind. Keep that file's progress, but
			# release its reservation so the old group's coworkers can take it.
			if int(task.work_id) >= 0 and (not cards.has(task.work_id) or cards[task.work_id].group != task.group):
				task.work_id = -1
				task.resume_task = {}
		var invalid: bool = not cards.has(person) or not coffee_valid
		if not invalid:
			invalid = int(cards[person].group) != int(task.group)
			if task.kind == "work":
				invalid = invalid or not can_person_work(int(person))
		if task.kind == "work" or task.kind == "transfer":
			invalid = invalid or not cards.has(task.work_id)
			if cards.has(task.work_id):
				invalid = invalid or int(cards[task.work_id].group) != int(task.group)
		if task.kind != "work":
			invalid = invalid or not cards.has(task.tool_id)
			if cards.has(task.tool_id):
				invalid = invalid or int(cards[task.tool_id].group) != int(task.group)
		if invalid:
			if task.kind == "coffee": _cancel_coffee(int(person), task)
			else: tasks.erase(person)
	# Merging running batches keeps the destination's round. The incoming
	# batch releases its materials and waits for the next opening snapshot.
	for group in groups:
		var batch_owner := -1
		for person in group_people(int(group)):
			if not tasks.has(person) or tasks[person].kind != "coffee": continue
			var owner := int(tasks[person].get("batch_owner", person))
			if batch_owner >= 0 and batch_owner != owner:
				_cancel_coffee(int(person), tasks[person].duplicate(true))
			else: batch_owner = owner
	_finish_empty_batches()
	_sync_transfer_groups()
	_sync_outsource_groups()
	_sync_recruitment_groups()
	_restart_ready_meetings()
	_sync_slack_groups()
	# Work assignments are slots of one group batch. Only a work combination
	# assigns them; a meeting's idle colleagues must not run a second function.
	for person in tasks.keys():
		if tasks[person].kind == "work": tasks.erase(person)
	for group in groups:
		var works: Array = group_work(int(group))
		if works.is_empty():
			groups[group].erase("work_progress")
			continue
		if not groups[group].has("work_progress"):
			groups[group]["work_progress"] = float(cards[works[0]].progress)
		if not _accepts_function(int(group), "work"):
			continue
		var index := 0
		for person in group_people(int(group)):
			if tasks.has(person) or _is_paused(int(person)) or not can_person_work(int(person)):
				continue
			if index >= works.size(): break
			var count: int = config.work_batch_size(effective_work_kind(str(cards[person].type), int(group)), works.size() - index)
			tasks[person] = {"kind": "work", "group": group, "work_id": works[index],
				"work_ids": works.slice(index, index + count), "tool_id": -1, "progress": group_work_progress(int(group))}
			index += count
		var progress := group_work_progress(int(group))
		for work in works: cards[work].progress = progress
	if start_coffee: _sync_coffee_groups()
	# advance publishes views after the event loop. Intermediate schedules only
	# change task assignments; repeatedly publishing every card is redundant.
	if not _index_queries: _refresh_card_views()
	_rebuild_active_groups()
	_scheduled_config = _config_schedule_signature()
	_schedule_dirty = false

func _progress_time(delta: float) -> void:
	# Advance each production group exactly once, independent of its size.
	for group in _active_groups.work:
		var rate := group_work_rate(int(group))
		if rate <= 0.0: continue
		var progress := minf(1.0, group_work_progress(int(group)) + rate * delta)
		groups[group]["work_progress"] = progress
		for work in group_work(int(group)): cards[work].progress = progress
	for group in _active_groups.transfer:
		var rate := group_transfer_rate(int(group))
		if rate > 0.0: groups[group]["transfer_progress"] = minf(1.0, group_transfer_progress(int(group)) + rate * delta)
	for group in _active_groups.slack:
		var rate := group_slack_rate(int(group))
		if rate > 0.0: groups[group]["slack_progress"] = minf(1.0, group_slack_progress(int(group)) + rate * delta)
	for person in tasks:
		var task: Dictionary = tasks[person]
		if task.kind == "coffee" and int(task.get("batch_owner", person)) != int(person): continue
		if task.kind == "work":
			task.progress = group_work_progress(int(task.group))
		elif task.kind == "transfer":
			task.progress = group_transfer_progress(int(task.group))
		elif task.kind == "slack":
			task.progress = group_slack_progress(int(task.group))
		else:
			task.progress = minf(1.0, _task_progress(int(person)) + _task_rate(int(person)) * delta)
	for id in activity_card_ids():
		var card: Dictionary = cards[id]
		if _has_timer(card):
			card.remaining = maxf(0.0, float(card.remaining) - delta)
	for meeting in meetings.values():
		meeting.remaining = maxf(0.0, float(meeting.remaining) - delta)
	for batch in outsourcing.values():
		batch.remaining = maxf(0.0, float(batch.remaining) - delta)
	for flight in pending_strikes.values():
		flight.remaining = maxf(0.0, float(flight.remaining) - delta)
	for batch in recruitment.values():
		batch.remaining = maxf(0.0, float(batch.remaining) - delta)
	time += delta
	_conveyor_elapsed += delta
	conveyor_progress = _conveyor_elapsed / config.number("conveyor", "interval_seconds")

func _settle_due() -> void:
	var epsilon: float = config.number("simulation", "epsilon")
	# Resolve production before releasing timed states at the same instant.
	var completed_groups: Array = []
	for group in _active_groups.work:
		if group_work_progress(int(group)) >= 1.0 - epsilon and not group_work_participants(int(group)).is_empty():
			completed_groups.append(group)
	for group in completed_groups: _complete_work_group(int(group))
	var transfer_groups: Array = []
	for group in _active_groups.transfer:
		if group_transfer_progress(int(group)) >= 1.0 - epsilon and not group_transfer_participants(int(group)).is_empty(): transfer_groups.append(group)
	for group in transfer_groups: _complete_transfer_group(int(group))
	var slack_groups: Array = []
	for group in _active_groups.slack:
		if group_slack_progress(int(group)) >= 1.0 - epsilon and not group_slack_participants(int(group)).is_empty(): slack_groups.append(group)
	for group in slack_groups: _complete_slack_group(int(group))
	var completed: Array = []
	for person in tasks:
		if tasks[person].kind == "coffee" and int(tasks[person].get("batch_owner", person)) != int(person): continue
		if str(tasks[person].kind) not in ["meeting", "work", "transfer", "slack", "recruitment"] and _task_progress(int(person)) >= 1.0 - epsilon:
			completed.append(person)
	for person in completed:
		if tasks.has(person):
			_complete_task(int(person))
	for tool_id in meetings.keys():
		if float(meetings[tool_id].remaining) <= epsilon:
			_end_meeting(int(tool_id))
	for tool_id in outsourcing.keys():
		if float(outsourcing[tool_id].remaining) <= epsilon:
			_complete_outsource(int(tool_id))
	for boss_id in recruitment.keys():
		if float(recruitment[boss_id].remaining) <= epsilon: _complete_recruitment(int(boss_id))
	for tool_id in pending_strikes.keys():
		if float(pending_strikes[tool_id].remaining) <= epsilon: _resolve_strike(int(tool_id))
	for id in activity_card_ids():
		var card: Dictionary = cards[id]
		if _has_timer(card) and float(card.remaining) <= epsilon:
			_schedule_dirty = true
			if str(card.status) == "striking":
				_emit("strike_end", {"source": id, "person": id, "owner": card.owner, "group": card.group})
			if str(card.status) == "active":
				_recover(int(id))
			else:
				card.status = "ready"
				card.remaining = 0.0
				card.total = 0.0
	if _schedule_dirty: _finish_empty_batches()
	if _conveyor_elapsed >= config.number("conveyor", "interval_seconds") - epsilon:
		_conveyor_elapsed = 0.0
		conveyor_progress = 0.0
		offers.pop_front()
		var incoming := _new_offer()
		offers.append(incoming)
		_emit("conveyor", {"offer_id": incoming.id, "card_type": incoming.type})

func _task_progress(person: int) -> float:
	var task: Dictionary = tasks[person]
	if task.kind == "work":
		return group_work_progress(int(task.group))
	if task.kind == "transfer":
		return group_transfer_progress(int(task.group))
	if task.kind == "slack":
		return group_slack_progress(int(task.group))
	if task.kind == "recruitment" and recruitment.has(person):
		return 1.0 - float(recruitment[person].remaining) / float(recruitment[person].total)
	if task.kind == "meeting" and meetings.has(task.tool_id):
		return 1.0 - float(meetings[task.tool_id].remaining) / float(meetings[task.tool_id].total)
	if task.kind == "coffee":
		return float(tasks.get(int(task.get("batch_owner", person)), task).progress)
	return float(task.progress)

func _task_rate(person: int) -> float:
	if not cards.has(person) or _is_paused(person):
		return 0.0
	var task: Dictionary = tasks[person]
	var group: int = int(task.group)
	if task.kind == "work":
		return group_work_rate(group)
	if task.kind == "transfer":
		return group_transfer_rate(group)
	if task.kind == "slack":
		return group_slack_rate(group)
	if task.kind == "coffee":
		return 1.0 / float(task.total)
	return 0.0

func _complete_work_group(group: int) -> void:
	var participants := group_work_participants(group)
	if participants.is_empty(): return
	var completed: Array = []
	for person in participants:
		completed.append_array(tasks[person].work_ids)
		tasks.erase(person)
	# 清几份工作就赚几份钱，和是谁清的无关。
	var income: int = completed.size() * config.income_per_work()
	for work_id in completed:
		_consume(int(work_id))
	groups[group]["work_progress"] = 0.0
	for work in group_work(group): cards[work].progress = 0.0
	var owner: int = int(groups[group].owner)
	var money_ids: Array = _credit(owner, income)
	var money_id: int = int(money_ids[0]) if not money_ids.is_empty() else -1
	_emit("work_complete", {"source": int(participants[0]), "owner": owner, "group": group,
		"participants": participants, "ids": completed, "amount": income,
		"money_ids": money_ids, "money_id": money_id, "money_group": int(cards[money_id].group) if money_id >= 0 else -1})

func _complete_transfer_group(group: int) -> void:
	var participants := group_transfer_participants(group)
	if participants.is_empty(): return
	var tool: int = int(tasks[participants[0]].tool_id)
	var capacity := 0
	for person in participants: capacity += int(config.roles[cards[person].type].transfer_capacity)
	var works := _transfer_work(group).slice(0, capacity)
	if works.is_empty(): return
	var owner: int = int(groups[group].owner)
	var other := _opponent(owner)
	var destination := _transfer_destination(other)
	cards[tool].destination = destination
	for work in works:
		groups[group].cards.erase(work)
		cards[work].owner = other
		cards[work].group = destination
		groups[destination].cards.append(work)
	_invalidate_group_index()
	for person in tasks.keys():
		if tasks[person].kind == "transfer" and int(tasks[person].group) == group: tasks.erase(person)
	groups[group]["transfer_progress"] = 0.0
	_emit("transfer", {"source": tool, "owner": owner, "group": group, "participants": participants,
		"ids": works, "target_owner": other, "target_group": destination})

func _complete_task(person: int) -> void:
	if not tasks.has(person): return
	var task: Dictionary = tasks[person].duplicate(true)
	if task.kind != "coffee":
		tasks.erase(person)
		return
	if not _coffee_batch_valid(person, task):
		_cancel_coffee(person, task)
		return
	var snapshots := {}
	for member in _coffee_batch_members(person, task):
		snapshots[member] = tasks[member].duplicate(true)
	# All final personnel types change before any completion event is emitted.
	# No intermediate grade can work, earn income or enter another recipe.
	for member in snapshots:
		tasks.erase(member)
		cards[member].type = str(snapshots[member].to_type)
	_invalidate_group_index()
	for member in snapshots:
		for id in snapshots[member].coffee_ids: _consume(int(id))
	for member in snapshots:
		var current: Dictionary = snapshots[member]
		_restore_coffee_work(int(member), current)
		_emit("coffee_upgrade", {"source": current.tool_id, "owner": cards[member].owner,
			"group": int(current.group), "person": member, "targets": [member],
			"from_type": current.from_type, "to_type": cards[member].type,
			"batch_owner": current.get("batch_owner", member),
			"steps": current.get("steps", []).duplicate(true),
			"coffee_ids": current.coffee_ids.duplicate(), "amount": current.coffee_ids.size()})

func _complete_slack_group(group: int) -> void:
	var participants := group_slack_participants(group)
	if participants.is_empty(): return
	var owner: int = int(groups[group].owner)
	var destination := -1
	for gid in groups:
		if int(groups[gid].owner) == owner and not groups[gid].cards.is_empty() \
			and groups[gid].cards.all(func(id): return cards[id].type == "coffee"):
			destination = int(gid)
			break
	if destination < 0: destination = create_group(owner)
	var coffees: Array = []
	for person in participants:
		for _index in config.integer("slack", "coffee_per_person"):
			var coffee := add_card("coffee", owner, destination)
			coffees.append(coffee)
		tasks.erase(person)
	groups[group]["slack_progress"] = 0.0
	_emit("slack_complete", {"source": int(participants[0]), "owner": owner, "group": group,
		"participants": participants, "ids": coffees, "coffee_ids": coffees, "coffee_id": coffees[0],
		"coffee_group": destination, "amount": coffees.size()})

func _finish_empty_batches() -> void:
	for group in groups:
		_sync_group_function(int(group))

func _end_meeting(tool_id: int) -> void:
	_schedule_dirty = true
	if not meetings.has(tool_id): return
	var meeting: Dictionary = meetings[tool_id]
	meetings.erase(tool_id)
	var hosts: Array = meeting.get("hosts", [meeting.host])
	var tools: Array = meeting.get("tools", [tool_id])
	for person in hosts:
		if tasks.has(person) and tasks[person].kind == "meeting" and int(tasks[person].tool_id) == tool_id:
			tasks.erase(person)
	for tool in tools:
		if cards.has(tool): _recover(int(tool))
	_emit("meeting_end", {"source": tool_id, "host": meeting.host, "hosts": hosts.duplicate(),
		"tools": tools.duplicate(), "group": meeting.group, "targets": meeting.targets.duplicate()})
	if groups.has(meeting.group): _sync_group_function(int(meeting.group))

func _recover(tool_id: int) -> void:
	_schedule_dirty = true
	if not cards.has(tool_id):
		return
	var tool: Dictionary = cards[tool_id]
	tool.status = "recovering"
	tool.total = config.number(str(tool.type), "recovery_seconds")
	tool.remaining = tool.total
	revision += 1

func _has_timer(card: Dictionary) -> bool:
	return card.status in ["recovering", "striking"]

func is_meeting_target(person: int) -> bool:
	for meeting in meetings.values():
		if meeting.targets.has(person):
			return true
	return false

func is_striking(person: int) -> bool:
	return cards.has(person) and str(cards[person].status) == "striking"

func _is_paused(person: int) -> bool:
	return is_striking(person) or is_meeting_target(person)

func _available_people(group: int) -> Array:
	var result: Array = []
	for person in group_people(group):
		if not _is_paused(int(person)) and (not tasks.has(person) or tasks[person].kind == "work"):
			result.append(person)
	return result

func _cancel_group_work(group: int) -> void:
	for person in tasks.keys():
		if int(tasks[person].group) == group and tasks[person].kind == "work":
			tasks.erase(person)

func _refresh_card_views() -> void:
	var group_rates: Dictionary = {}
	var coffee_views: Dictionary = {}
	var coffee_views_ready := false
	for id in activity_card_ids():
		var card: Dictionary = cards[id]
		if config.is_person(str(card.type)):
			card.activity = "idle"
			card.paused = _is_paused(int(id))
			card.progress = 0.0
			card.rate_multiplier = 0.0
			if is_striking(int(id)):
				card.activity = "striking"
				continue
			if tasks.has(id):
				card.activity = tasks[id].kind
				card.progress = _task_progress(int(id))
				if tasks[id].kind == "recruitment":
					card.total = recruitment[id].total
					card.remaining = recruitment[id].remaining
				if tasks[id].kind == "work":
					var group: int = int(tasks[id].group)
					if not group_rates.has(group): group_rates[group] = group_work_rate(group)
					card.rate_multiplier = 0.0 if bool(card.paused) else float(group_rates[group]) * config.work_seconds()
				elif tasks[id].kind in ["transfer", "slack", "coffee"]:
					card.rate_multiplier = _task_rate(int(id)) * config.number(str(tasks[id].kind), "seconds")
		elif config.category(str(card.type)) in ["tool", "ingredient"]:
			card.paused = false
			if _has_timer(card) and float(card.total) > 0.0:
				card.progress = clampf(1.0 - float(card.remaining) / float(card.total), 0.0, 1.0)
			elif pending_strikes.has(id):
				card.remaining = pending_strikes[id].remaining
				card.progress = 1.0 - float(card.remaining) / float(card.total)
			elif outsourcing.has(id):
				card.remaining = outsourcing[id].remaining
				card.progress = 1.0 - float(card.remaining) / float(card.total)
			elif card.type == "meeting" and card.status == "active":
				var meeting := meeting_for_tool(int(id))
				if not meeting.is_empty():
					card.total = meeting.total
					card.remaining = meeting.remaining
					card.progress = 1.0 - float(card.remaining) / float(card.total)
			elif card.type == "transfer" and card.status == "active":
				card.progress = group_transfer_progress(int(card.group))
				card.remaining = (1.0 - float(card.progress)) * float(card.total)
				card.paused = group_transfer_participants(int(card.group)).is_empty()
			elif card.type == "slack" and card.status == "active":
				card.progress = group_slack_progress(int(card.group))
				card.remaining = (1.0 - float(card.progress)) * float(card.total)
				card.paused = group_slack_participants(int(card.group)).is_empty()
			elif card.status == "active" and card.type == "coffee":
				# Index ingredient views once for a many-person batch, rather than
				# scanning every personnel task separately for every coffee card.
				if not coffee_views_ready:
					for person in tasks:
						var task: Dictionary = tasks[person]
						if task.kind != "coffee": continue
						var view := {"progress": _task_progress(int(person)), "paused": _is_paused(int(person))}
						for ingredient in task.coffee_ids: coffee_views[ingredient] = view
					coffee_views_ready = true
				var view: Dictionary = coffee_views.get(id, {"progress": 1.0, "paused": false})
				card.progress = view.progress
				card.paused = view.paused
				card.remaining = (1.0 - float(card.progress)) * float(card.total)
			else:
				card.progress = 0.0

func _credit(owner: int, amount: int) -> Array:
	if amount <= 0:
		return []
	# 收入只进入纯现金堆；原现金被玩家拿去参加组合后，不再把钱塞进那组。
	# 每块钱都是独立可拆的真实卡牌；一次组结算仍只发一个包含整批 UID 的事件。
	var destination := -1
	var oldest := str(config.value("income", "destination_policy")) == "oldest_cash_pile"
	for gid in groups:
		if int(groups[gid].owner) != owner or groups[gid].cards.is_empty(): continue
		var pure := true
		for id in groups[gid].cards:
			if not cards.has(id) or cards[id].type != "money":
				pure = false
				break
		if not pure: continue
		if destination < 0 or (oldest and int(gid) < destination) or (not oldest and int(gid) > destination):
			destination = int(gid)
	if destination < 0: destination = create_group(owner)
	var money_ids: Array = []
	for _index in amount:
		money_ids.append(add_card("money", owner, destination))
	return money_ids

func _spend(owner: int, amount: int, payment_ids: Array = []) -> bool:
	# 原牌桌可指定一摞现金付款；金额足够才提交，不能暗中动用别摞。
	var candidates: Array = _owner_type(owner, "money") if payment_ids.is_empty() else payment_ids.duplicate()
	var seen: Dictionary = {}
	var available := 0
	for id in candidates:
		if seen.has(id) or not cards.has(id) or cards[id].type != "money" or int(cards[id].owner) != owner:
			return _fail("付款现金无效")
		seen[id] = true
		available += available_cash_amount(int(id))
	if amount < 0 or available < amount:
		return _fail("钱还不够")
	var left: int = amount
	for id in candidates:
		if left == 0: break
		var take: int = mini(left, available_cash_amount(int(id)))
		cards[id].amount -= take
		left -= take
		if int(cards[id].amount) == 0:
			_consume(int(id))
	_validate_outsource_batches()
	return true

func _consume(id: int) -> void:
	assert(cards.has(id))
	assert(str(cards[id].type) == "strike" or ["work", "money", "person", "ingredient"].has(config.category(str(cards[id].type))), "耐用工具不得被消耗")
	var indexed := _can_update_membership_index()
	var group: int = int(cards[id].group)
	if indexed: _unindex_card(id)
	if groups.has(group):
		groups[group].cards.erase(id)
	cards.erase(id)
	if indexed:
		_indexed_card_count = cards.size()
		_invalidate_group_layout([group])
	else:
		_invalidate_group_index()
	revision += 1

func _cleanup_groups() -> void:
	var removed: Array = []
	for group in groups.keys():
		if groups[group].cards.is_empty():
			groups.erase(group)
			removed.append(group)
	if not removed.is_empty(): _invalidate_group_layout(removed)

func _transfer_destination(owner: int) -> int:
	# All files in one shared settlement use the same destination. The next
	# cycle chooses again from current queues instead of retaining an empty one.
	if str(config.value("transfer", "destination_policy")) == "largest_work_queue":
		var best := -1
		var largest := 0
		var ordered: Array = groups.keys()
		ordered.sort()
		for group in ordered:
			if int(groups[group].owner) != owner:
				continue
			var count: int = group_work(int(group)).size()
			if count > largest:
				largest = count
				best = int(group)
		if best >= 0:
			return best
	return create_group(owner)

func _group_type(group: int, kind: String) -> Array:
	return _indexed_group(group).types.get(kind, []).duplicate()

func _owner_type(owner: int, kind: String) -> Array:
	_ensure_membership_index()
	return _owner_index.get(owner, {}).get("types", {}).get(kind, []).duplicate()

func _opponent(owner: int) -> int:
	for value in config.rules.simulation.owners:
		if int(value) != owner:
			return int(value)
	return owner

func resign(owner: int) -> bool:
	if winner >= 0 or owner not in [0, 1]: return false
	winner = 1 - owner
	_cancel_pending_strikes()
	revision += 1
	_emit("win", {"winner": winner, "owner": winner, "resigned": owner})
	return true

func _check_winner() -> void:
	if winner >= 0:
		return
	var cleared: Array = []
	for owner in config.rules.simulation.owners:
		if work_count(int(owner)) == 0:
			cleared.append(int(owner))
	if cleared.is_empty():
		return
	winner = int(cleared[0]) if cleared.size() == 1 else config.integer("simulation", "tie_winner")
	_cancel_pending_strikes()
	_emit("win", {"winner": winner, "owner": winner})

func _make_offer(kind: String) -> Dictionary:
	var offer: Dictionary = {"id": _next_offer, "type": kind, "price": int(config.cards[kind].price)}
	_next_offer += 1
	return offer

func _new_offer() -> Dictionary:
	_supply_count += 1
	if _supply_mode == LEGACY_SUPPLY: return _legacy_weighted_offer()
	var signature := _supply_signature()
	if _supply_bag.is_empty() or _supply_bag_signature != signature:
		_supply_bag.clear()
		var kinds: Array = config.rules.conveyor.pool.keys()
		kinds.sort()
		for kind in kinds:
			for _copy in int(config.rules.conveyor.pool[kind]): _supply_bag.append(str(kind))
		_supply_bag_signature = signature
		_shuffle_supply_bag()
	return _make_offer(str(_supply_bag.pop_front()))

func _supply_signature() -> String:
	var entries := []
	var kinds: Array = config.rules.conveyor.pool.keys()
	kinds.sort()
	for kind in kinds: entries.append([str(kind), int(config.rules.conveyor.pool[kind])])
	return JSON.stringify(entries)

func _shuffle_supply_bag() -> void:
	# Fisher–Yates uses this world's RNG, never Array.shuffle's global stream.
	for index in range(_supply_bag.size() - 1, 0, -1):
		var other := _rng.randi_range(0, index)
		var previous: Variant = _supply_bag[index]
		_supply_bag[index] = _supply_bag[other]
		_supply_bag[other] = previous

## Old recordings keep their original supply rule between keyframes. New
## matches always start with SHUFFLE_SUPPLY; this path is import-only.
func _legacy_weighted_offer() -> Dictionary:
	var probabilities: Dictionary = config.conveyor_probabilities()
	var choice := _rng.randf()
	var last_available := ""
	for kind in probabilities:
		var chance := float(probabilities[kind])
		if chance <= 0.0: continue
		last_available = str(kind)
		choice -= chance
		if choice <= 0.0:
			return _make_offer(str(kind))
	return _make_offer(last_available)

static func migrate_supply_snapshot(world: Dictionary) -> void:
	if not world.has("_supply_mode"): world._supply_mode = LEGACY_SUPPLY
	if not world.has("_supply_bag"): world._supply_bag = []
	if not world.has("_supply_bag_signature"): world._supply_bag_signature = ""

func valid_supply_snapshot(world: Dictionary) -> bool:
	if world.get("_supply_mode") not in [SHUFFLE_SUPPLY, LEGACY_SUPPLY]: return false
	if not world.get("_supply_bag") is Array or not world.get("_supply_bag_signature") is String: return false
	if world._supply_bag.size() > OffWorkConfig.MAX_CONVEYOR_BAG: return false
	if not world._supply_bag.all(func(kind): return kind is String and config.cards.has(kind)): return false
	if world._supply_mode == LEGACY_SUPPLY: return world._supply_bag.is_empty()
	# A changed live card table deliberately starts a new bag on the next draw.
	if world._supply_bag_signature != _supply_signature(): return true
	var counts := {}
	for kind in world._supply_bag:
		counts[kind] = int(counts.get(kind, 0)) + 1
		if int(counts[kind]) > int(config.rules.conveyor.pool.get(kind, 0)): return false
	return true

func _emit(kind: String, data: Dictionary) -> void:
	if _bot_branch: return
	var event: Dictionary = {"kind": kind, "time": time, "owner": -1, "group": -1, "source": -1, "ids": [], "targets": [], "amount": 0}
	event.merge(data, true)
	_events.append(event)

func _fail(message: String) -> bool:
	last_error = message
	return false
