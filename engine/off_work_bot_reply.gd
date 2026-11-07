# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Compare one visible reply after each shortlisted action. The opponent can
## leave the table alone, buy available labour, or spend an existing strike.
## Keep the first-pass ranking intact unless the whole reply layer completes.
static func refine(game: RefCounted, seat: int, _policy: Dictionary, ctx: Dictionary, finalists: Array, deadline_usec: int) -> Dictionary:
	if ctx.is_empty() or finalists.is_empty() or Time.get_ticks_usec() >= deadline_usec: return {}
	var choices := finalists.duplicate()
	var wait := {"kind":"wait", "action":{"kind":"wait"}, "score":0.0, "reason":"维持当前生产"}
	# Waiting anchors the risk estimate. It can also beat a previously positive
	# action once its best opposing response has been considered.
	if not choices.any(func(item): return item.action.kind == "wait"):
		choices.append(wait)
	# Compare all choices at the same game time, stopping at the first
	# projected finish rather than pricing work after the race has ended.
	var horizon: float = ctx.horizon
	for player in 2:
		if ctx.throughput[player] > 0.0:
			horizon = minf(horizon, float(ctx.pending[player]) / float(ctx.throughput[player]))
	var baseline := _worst_reply(game, seat, ctx, wait.action, horizon, deadline_usec)
	if baseline.is_empty(): return {}
	var rows := []
	for candidate in choices:
		if Time.get_ticks_usec() >= deadline_usec: return {}
		var response := baseline
		if candidate.action.kind != "wait":
			response = _worst_reply(game, seat, ctx, candidate.action, horizon, deadline_usec)
			if response.is_empty(): return {}
		var row: Dictionary = candidate.duplicate()
		row.base_score = candidate.score
		row.reply = response.reason
		row.reply_loss = response.loss
		row.score = float(candidate.score) + float(baseline.loss) - float(response.loss)
		# Insert stably, preserving the static ranking when the replies tie.
		var index := 0
		while index < rows.size() and rows[index].score >= row.score: index += 1
		rows.insert(index,row)
	var winner: Dictionary = rows[0]
	var chosen: Dictionary = winner.action
	for row in rows: row.erase("action")
	if Time.get_ticks_usec() >= deadline_usec: return {}
	return {"action": chosen, "reason": "%s；预计最不利回应：%s" % [winner.reason, winner.reply],
		"candidates":rows, "depth":1, "evaluated":rows.size()}

static func _worst_reply(game: RefCounted, seat: int, ctx: Dictionary, action: Dictionary, horizon: float, deadline_usec: int) -> Dictionary:
	var worst := {"reason":"保持当前安排", "loss":0.0}
	var enemy := 1 - seat
	var remaining := maxf(0.0, horizon - float(ctx.period))
	var pending := maxf(0.0, float(ctx.pending[enemy]) - float(ctx.throughput[enemy]) * float(ctx.period))
	for offer in game.offers:
		if Time.get_ticks_usec() >= deadline_usec: return {}
		if offer.is_empty() or (action.kind == "buy" and offer.id == action.offer): continue
		if offer.price > ctx.funds[enemy] or not game.config.can_work(offer.type): continue
		var role: Dictionary = game.config.roles[offer.type]
		# Buying uses this opportunity; staffing a queue takes another action.
		var gain := minf(pending, floorf(remaining / float(role.work_seconds)) * float(role.work_capacity))
		if gain > worst.loss:
			worst = {"reason":"购入%s后派工" % game.config.cards[offer.type].name, "loss":gain}
	if not ctx.enemy_strike_ready: return worst

	# Only affected public group summaries are copied. Overtime, work and
	# staff that change groups can change the best target of the next strike.
	var changed := {}
	for id in action.get("ids", []):
		if Time.get_ticks_usec() >= deadline_usec: return {}
		var card: Dictionary = game.cards[id]
		if card.type not in ["work","overtime"] and not game.config.can_work(card.type): continue
		var source: int = card.group
		var target: int = action.get("group",-1)
		if source == target: continue
		_group_delta(ctx, changed, source, card, -1)
		if action.kind == "move":
			_group_delta(ctx, changed, target, card, 1)
	# Reallocate actual jobs only for changed stacks. The untouched summary
	# already reflects the live participants and their partial final batch.
	for gid in changed:
		if Time.get_ticks_usec() >= deadline_usec: return {}
		if not _assign_batch(game, changed[gid], deadline_usec): return {}
		_compare_strike(game, changed[gid], horizon, worst)
	for gid in ctx.groups:
		if Time.get_ticks_usec() >= deadline_usec: return {}
		var g: Dictionary = ctx.groups[gid]
		if g.owner == seat and not changed.has(gid): _compare_strike(game, g, horizon, worst)
	return worst

static func _compare_strike(game: RefCounted, g: Dictionary, horizon: float, worst: Dictionary) -> void:
	if g.job != "work" or g.n <= 0 or g.rate <= 0 or g.capacity <= 0: return
	var duration := minf(horizon, float(game.config.rules.strike.duration_seconds))
	# Ejection stops production but preserves the group's progress. Assume
	# immediate redeployment after recovery (optimistic for the defender).
	var loss := _completed(g,horizon) - _completed(g,horizon - duration)
	if loss > worst.loss:
		worst.reason = "对工作组 %d 发动罢工" % g.id if g.id >= 0 else "对新组发动罢工"
		worst.loss = loss

static func _completed(group: Dictionary, seconds: float) -> float:
	var cycles := floorf(float(group.progress) + seconds * float(group.rate) / float(group.capacity))
	return minf(float(group.n), cycles * float(group.capacity))

static func _group_delta(ctx: Dictionary, changed: Dictionary, gid: int, card: Dictionary, direction: int) -> void:
	if not changed.has(gid):
		var source: Dictionary = ctx.groups.get(gid, {})
		if not source.is_empty() and source.job != "work": return
		var copied: Dictionary = source.duplicate() if not source.is_empty() else {
			"id":gid, "job":"work", "n":0, "progress":0.0, "overtime":0, "staff":[]}
		copied.removed = {}
		copied.joined = []
		changed[gid] = copied
	var g: Dictionary = changed[gid]
	if card.type == "work":
		g.n += direction
	elif card.type == "overtime":
		g.overtime += direction
	elif direction < 0:
		g.removed[card.id] = true
	elif not card.paused:
		g.joined.append(card.id)

## Mirror OffWorkState's group scheduler: existing eligible personnel first,
## then arriving personnel. The shared clock averages only people who actually
## receive work, and the last worker can receive less than their capacity.
static func _assign_batch(game: RefCounted, g: Dictionary, deadline_usec: int) -> bool:
	var left: int = g.n
	var speed_sum := 0.0
	var count := 0
	for queue in [g.staff, g.joined]:
		for id in queue:
			if Time.get_ticks_usec() >= deadline_usec: return false
			if left <= 0: break
			if g.removed.has(id): continue
			var kind: String = game.cards[id].type
			left -= game.config.work_batch_size(kind,left)
			speed_sum += game.config.work_rate(kind,g.overtime)
			count += 1
	g.capacity = int(g.n) - left
	g.rate = speed_sum / maxi(1, count) * float(g.capacity)
	return true
