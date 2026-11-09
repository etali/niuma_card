# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## A shared executable prefix: real commands, real event clocks and public
## quotes. Recipe and purchase continuations use the same branch lifecycle.
const Actions = preload("res://engine/off_work_bot_actions.gd")
const Budget = preload("res://engine/off_work_bot_budget.gd")

var source: OffWorkState
var owner := 0
var policy: Dictionary
var until := -1
var cancelled: Callable
var period := 1.0
var horizon := 1800.0
var next_actions: Array
var complete := true

func _open() -> bool:
	if (until >= 0 and Time.get_ticks_usec() >= until) or (cancelled.is_valid() and cancelled.call()): complete = false
	return complete

func _cursor(world: OffWorkState, previous: Dictionary = {}) -> Dictionary:
	if not _open(): return {}
	if until >= 0 and until-Time.get_ticks_usec() <= Budget.fork_cost(world)+Budget.release_cost(world):
		complete = false
		return {}
	var branch := world.fork_search_node() if world._bot_branch else world.fork_for_bot(hash(["production_chain",owner,world.time,world._next_card,world._next_offer]))
	return {"world":branch,"next":float(next_actions[owner]) if previous.is_empty() else float(previous.next),
		"commands":[] if previous.is_empty() else previous.commands.duplicate(true),
		"replies":[] if previous.is_empty() else previous.get("replies",[]).duplicate(true),
		"purchases":{} if previous.is_empty() else previous.purchases.duplicate(true)}

func _advance(cursor: Dictionary, at: float) -> bool:
	if not _open() or cursor.world.winner >= 0 or at > horizon: return false
	var delta := maxf(0.0,source.time+at-float(cursor.world.time))
	if delta > 0.0 and not cursor.world.advance_for_search(delta,until,cancelled):
		complete = false
		return false
	cursor.world.mask_search_market(source._next_offer)
	return _open() and cursor.world.winner < 0

func _slot(cursor: Dictionary) -> bool:
	return _advance(cursor,float(cursor.next))

func _command(cursor: Dictionary, action: Dictionary) -> bool:
	if not _slot(cursor): return false
	if not _apply(cursor,owner,action): return false
	cursor.next = float(cursor.world.time)-source.time+period
	return _open()

func _reply(cursor: Dictionary, actor: int, action: Dictionary, at: float) -> bool:
	if not _advance(cursor,at): return false
	return _apply(cursor,actor,action)

func _apply(cursor: Dictionary, actor: int, action: Dictionary) -> bool:
	var price := 0
	if action.kind == "buy":
		for offer in cursor.world.offers:
			if not offer.is_empty() and int(offer.id) == int(action.offer): price = int(offer.price)
	if not Actions.apply_search_action(cursor.world,actor,action): return false
	var at: float = cursor.world.time-source.time
	var command := {"at":at,"action":action.duplicate(true)}
	if actor == owner: cursor.commands.append(command)
	else: cursor.replies.append(command)
	if action.kind == "buy": cursor.purchases[int(action.offer)] = {"at":at,"owner":actor,"price":price}
	return _open()

func _plan(cursor: Dictionary, kind: String, person := -1) -> Dictionary:
	var elapsed: float = cursor.world.time-source.time
	var future := []
	for side in 2:
		var next := float(cursor.next) if side == owner else float(next_actions[side])
		if side != owner and not cursor.replies.is_empty(): next = maxf(next,float(cursor.replies[-1].at)+period)
		if next < elapsed: next += ceili((elapsed-next)/period)*period
		future.append(maxf(0.0,next-elapsed))
	return {"world":cursor.world,"owner":owner,"person":person,"elapsed":elapsed,
		"next_actions":future,"commands":cursor.commands,"replies":cursor.replies,"purchases":cursor.purchases,
		"complete":true,"kind":kind}

func _quote_exists(world: OffWorkState, id: int) -> bool:
	return world.offers.any(func(offer): return not offer.is_empty() and int(offer.id) == id)
