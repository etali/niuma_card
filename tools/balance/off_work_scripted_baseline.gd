# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Independent deterministic opponent using only the current visible table.
## No training replay, UID whitelist, market RNG, future offers or seed policy.
## Production investment has no personnel/copy cap; legal material moves are
## never truncated. One real command is executed per declared action interval.
var state: OffWorkState
var owner: int
var _policy: Dictionary
var _next_think := INF
var decision_serial := 0
var last_decision := {}
var _started := false

func _init(world: OffWorkState, seat: int, policy: Dictionary, _seed := 0) -> void:
	state = world
	owner = seat
	_policy = policy.duplicate(true)

func start() -> void:
	_started = true
	_next_think = state.time + float(_policy.first_action_seconds)

func next_action_time() -> float:
	return _next_think if _started else INF

func decide_action(_deadline := -1, _cancelled := Callable(), _tree := true, publish := Callable()) -> Dictionary:
	var started := Time.get_ticks_usec()
	var action := _choose()
	last_decision = {"kind":action.kind, "reason":action.get("reason", "脚本等待"), "elapsed_us":Time.get_ticks_usec() - started,
		"cutoff":false, "fallback":false, "overrun":false, "algorithm":"scripted_race_v1"}
	if publish.is_valid(): publish.call(action, last_decision)
	return action

func commit_action(action: Dictionary, report: Dictionary) -> bool:
	var applied := false
	match action.kind:
		"wait": applied = true
		"move": applied = state.move_cards(action.ids, action.group, action.get("person", -1)) >= 0
		"buy": applied = state.buy(action.offer, owner) >= 0
		"activate": applied = state.activate(action.tool, action.group)
	last_decision = report
	last_decision.applied = applied
	if applied: decision_serial += 1
	return applied

func _choose() -> Dictionary:
	var destination := _workplace()
	var outsource := _finish_outsource()
	if not outsource.is_empty(): return outsource
	if destination >= 0:
		var idle := []
		for id in state.cards:
			var card: Dictionary = state.cards[id]
			if card.owner != owner or card.group == destination: continue
			if state.can_person_work(id) and not state.is_striking(id) and not state.is_meeting_target(id) and not state.tasks.has(id):
				idle.append(id)
		if not idle.is_empty(): return _move(idle, destination, "一次合组全部可返岗人员")
		var extra_work := []
		for gid in state.groups:
			if gid != destination and state.groups[gid].owner == owner and state.group_people(gid).is_empty() \
				and str(state.groups[gid].get("function", "")) in ["", "work"]:
				extra_work.append_array(state.group_work(gid))
		if not extra_work.is_empty(): return _move(extra_work, destination, "合并全部闲置工作材料")
		var overtime := []
		for id in state._owner_type(owner, "overtime"):
			if state.cards[id].group != destination and not state.group_has_union(destination): overtime.append(id)
		if not overtime.is_empty(): return _move(overtime, destination, "加班按规则累乘，不设四张上限")
	# The declared bulk-production capability uses a discrete batch reference.
	# Normal growth/overtime opponents retain their original investment policy.
	if str(_policy.mode) == "production":
		var batch_purchase := _production_purchase(destination)
		if not batch_purchase.is_empty(): return batch_purchase
	var strike := _strike()
	if not strike.is_empty(): return strike
	var coffee := _coffee(destination)
	if not coffee.is_empty(): return coffee
	var purchase := _purchase(destination)
	return purchase if not purchase.is_empty() else {"kind":"wait", "reason":"当前公开牌面没有能及时回本的操作"}

func _production_purchase(destination: int) -> Dictionary:
	if destination < 0: return {}
	var works := state.group_work(destination).size()
	var capacity := 0
	for person in state.group_work_participants(destination):
		capacity += state.config.work_batch_size(state.effective_work_kind(str(state.cards[person].type), destination), works)
	if capacity <= 0 or works <= capacity: return {}
	var batches := ceili(float(works) / capacity)
	var funds := state.available_money(owner)
	var selected := {}
	var best := 0.0
	for offer in state.offers:
		if offer.is_empty() or int(offer.price) > funds: continue
		var kind: String = offer.type
		if not state.config.can_work(kind) or not state.config.can_purchase(kind) or not state.can_acquire(kind, owner): continue
		var additional: int = state.config.work_batch_size(state.effective_work_kind(kind, destination), works)
		var saved := batches - ceili(float(works) / (capacity + additional))
		var score := float(saved) / maxf(1.0, float(offer.price))
		if score > best:
			best = score
			selected = {"kind":"buy", "offer":offer.id, "card_type":kind, "reason":"独立生产能力参考：采购当前公开人员使剩余工作少一批完成"}
	return selected

func _workplace() -> int:
	var selected := -1
	var largest := -1.0
	for gid in state.groups:
		var group: Dictionary = state.groups[gid]
		if group.owner != owner or str(group.get("function", "")) not in ["", "work"]: continue
		var work := state.group_work(gid).size()
		if work == 0: continue
		var score := work + state.group_people(gid).size() * 2.0
		if score > largest:
			largest = score
			selected = gid
	return selected

func _throughput(seat: int) -> float:
	var rate := 0.0
	for gid in state.groups:
		if state.groups[gid].owner == seat:
			rate += state.group_work_rate(gid) * state.group_work_participants(gid).size()
	return rate

func _eta() -> float:
	return state.work_count(owner) / maxf(0.01, _throughput(owner))

func _move(ids: Array, group: int, reason: String) -> Dictionary:
	return {"kind":"move", "ids":ids, "group":group, "reason":reason}

func _finish_outsource() -> Dictionary:
	for batch in state.outsourcing.values():
		if int(batch.owner) == owner: return {}
	var tools: Array = state._owner_type(owner, "outsource").filter(func(id): return state.cards[id].status == "ready")
	if tools.is_empty(): return {}
	var cost: int = state.config.integer("outsource", "cost_per_work")
	var count := mini(state.work_count(owner), state.available_money(owner) / cost)
	var duration: float = state.config.number("outsource", "seconds")
	if count <= 0 or _eta() <= duration: return {}
	# Cashing out every remaining document is always considered. Mid-game
	# batches need enough scale to justify moving production away from staff.
	if count < state.work_count(owner) and (count < 20 or str(_policy.mode) != "outsource"): return {}
	var works: Array = state._owner_type(owner, "work").filter(func(id):
		return str(state.groups[state.cards[id].group].get("function", "")) in ["", "work", "outsource"])
	count = mini(count, works.size())
	if count <= 0: return {}
	var payment := []
	var funds := 0
	for id in state._owner_type(owner, "money"):
		if state.available_cash_amount(id) <= 0: continue
		payment.append(id)
		funds += state.available_cash_amount(id)
		if funds >= count * cost: break
	var ids: Array = [tools[0]]
	ids.append_array(works.slice(0, count))
	ids.append_array(payment)
	return _move(ids, -1, "按真实可用资金外包大批材料或最后一批，不设十六张上限")

func _strike() -> Dictionary:
	var tools: Array = state._owner_type(owner, "strike").filter(func(id): return state.cards[id].status == "ready")
	if tools.is_empty(): return {}
	var best := -1
	var rate := 0.0
	for gid in state.groups:
		if not state.can_strike_group(gid, owner): continue
		var blocked := state.group_work_rate(gid) * state.group_work_participants(gid).size()
		if blocked > rate:
			rate = blocked
			best = gid
	return {"kind":"activate", "tool":tools[0], "group":best, "reason":"罢工当前产能最高的合法对手组合"} if best >= 0 else {}

func _coffee(destination: int) -> Dictionary:
	if destination < 0 or state.group_work_participants(destination).size() < 2 or _eta() < 30.0: return {}
	var coffee: Array = state._owner_type(owner, "coffee").filter(func(id): return state.cards[id].status == "ready")
	if coffee.is_empty(): return {}
	# Avoid repeatedly removing staff while an earlier upgrade is still reading.
	for person in state.tasks:
		if state.tasks[person].kind == "coffee" and state.cards[person].owner == owner: return {}
	for person in state.group_work_participants(destination):
		var recipe: Dictionary = state.config.coffee_upgrade(str(state.cards[person].type))
		if recipe.is_empty() or coffee.size() < int(recipe.cost): continue
		var ids: Array = [person]
		ids.append_array(coffee.slice(0, int(recipe.cost)))
		return _move(ids, -1, "独立升级一名人员后批量返岗，增加后续工资")
	return {}

func _purchase(destination: int) -> Dictionary:
	var funds := state.available_money(owner)
	var rate := _throughput(owner)
	var eta := _eta()
	var overtime_count := 0
	if destination >= 0:
		for id in state.group_tools(destination):
			if state.cards[id].type == "overtime": overtime_count += 1
	var best := {}
	var best_score := 0.0
	for offer in state.offers:
		if offer.is_empty() or int(offer.price) > funds: continue
		var kind: String = offer.type
		if not state.config.can_purchase(kind) or not state.can_acquire(kind, owner): continue
		var gain := 0.0
		if state.config.can_work(kind):
			gain = state.config.work_rate(kind, overtime_count)
		elif kind == "overtime" and destination >= 0 and not state.group_has_union(destination):
			gain = rate * (state.config.number("overtime", "speed_multiplier") - 1.0)
		var saved := eta - state.work_count(owner) / maxf(0.01, rate + gain) if gain > 0 else 0.0
		var score := saved / maxf(1.0, float(offer.price))
		if kind == "strike" and state._owner_type(owner, "strike").is_empty() and eta > 15.0:
			score = _throughput(1 - owner) * state.config.number("strike", "duration_seconds") / maxf(1.0, rate) / maxf(1.0, float(offer.price))
		if kind == "coffee" and state._owner_type(owner, "coffee").is_empty() and eta > 50.0 and funds < 40:
			score = 1.0
		if kind == "outsource" and state._owner_type(owner, "outsource").is_empty() and eta > state.config.number("outsource", "seconds") + 2.0:
			var batch := mini(state.work_count(owner), (funds - int(offer.price)) / state.config.integer("outsource", "cost_per_work"))
			if batch >= 20 or batch == state.work_count(owner): score = batch / maxf(1.0, rate) / maxf(1.0, float(offer.price))
		if str(_policy.mode) == "overtime" and kind == "overtime": score *= 1.4
		if saved > 0.0 and saved <= float(_policy.think_seconds): score = 0.0
		if score > best_score:
			best_score = score
			best = {"kind":"buy", "offer":offer.id, "card_type":kind, "reason":"比较当前产能的完工收益与购买成本，持续投资"}
	return best
