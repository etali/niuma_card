# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## Short-horizon forecasts use only public work rates, timers, queues and offers.
## Planning never copies or mutates WorkState, or samples its future market RNG.
const TRACE_LIMIT := 4
const MATERIAL_BATCH := 16
const WAIT := {"kind": "wait"}

var state: RefCounted
var owner: int
var policy: Dictionary
var deadline: int
var cancelled: Callable
var horizon: float
var period: float
var best: Dictionary
var best_score: float
var best_reason: String
var trace: Array
var evaluated: int
var expired: bool

# Per-decision observations, in the same insertion order as the live table.
var groups: Dictionary
var people: Array
var ready: Dictionary
var inventory: Dictionary
var cash_ids: Array
var funds: Array
var pending: Array
var throughput: Array
var workers: int
var producers: int
var supports: int
var destination: int
var specialist: int
var graduate: int
var opponent_workers: int
var enemy_strike_ready: bool
var enemy_reply_rate: float
var enemy_reply_offer: int
var cash_value: float
var shop_reason: String
var quick_move: Dictionary
var observed := false
# Group IDs are monotonic. Persist just a cursor and validated UID hints,
# independent of advancing game time or changes to unrelated stacks.
var _next_probe_group := 1
var _worker_hint := -1
var _work_hint := -1

func save_scan_hints() -> Dictionary:
	return {"next_group":_next_probe_group, "worker":_worker_hint, "work":_work_hint}

func restore_scan_hints(data: Dictionary) -> void:
	_next_probe_group = maxi(1, int(data.get("next_group",1)))
	_worker_hint = int(data.get("worker",-1))
	_work_hint = int(data.get("work",-1))

func choose(game: RefCounted, seat: int, settings: Dictionary, rng: RandomNumberGenerator, deadline_usec: int,
		cancel_check: Callable = Callable()) -> Dictionary:
	state = game
	owner = seat
	policy = settings
	deadline = deadline_usec
	cancelled = cancel_check
	best = WAIT
	best_score = 0.0
	best_reason = "保留现金和现有组合，等待下一次决策"
	evaluated = 0
	trace = []
	observed = false
	expired = false
	quick_move = {}
	shop_reason = "尚未评估购牌"
	if _open():
		_reset_observations()
		_opening_move()
		if _open() and _observe():
			observed = true
			_evaluate_actions(rng)
	var fallback := expired and evaluated <= 1
	if fallback and not quick_move.is_empty():
		best = quick_move
		best_reason = "从可见牌堆先取得派工动作"
	var summary := []
	for finalist in trace:
		var item: Dictionary = finalist.duplicate()
		item.erase("action")
		summary.append(item)
	return {"action": best, "finalists": trace, "diagnostics": {"reason": best_reason, "candidates": summary, "evaluated": evaluated,
		"fallback": fallback, "timed_out": expired,"shop_reason":shop_reason}}

## Valid during the same decision only; response search reads these public
## aggregates without rescanning the table or copying thousands of entities.
func forecast_context() -> Dictionary:
	if not observed: return {}
	return {"pending":pending,"throughput":throughput,"groups":groups,"funds":funds,
		"horizon":horizon,"period":period,"cash_value":cash_value,"owner":owner,"enemy_strike_ready":enemy_strike_ready}

func _open() -> bool:
	if Time.get_ticks_usec() < deadline and not (cancelled.is_valid() and cancelled.call()): return true
	expired = true
	return false

func _reset_observations() -> void:
	groups = {}
	people = []
	ready = {}
	inventory = {}
	cash_ids = []
	funds = [0, 0]
	pending = [0, 0]
	throughput = [0.0, 0.0]
	workers = 0
	producers = 0
	supports = 0
	specialist = -1
	graduate = -1
	opponent_workers = 0
	destination = -1
	enemy_reply_rate = 0.0
	enemy_strike_ready = false
	enemy_reply_offer = -1
	period = float(policy.think_seconds)
	horizon = maxf(3.0 * state.config.roles.employee.work_seconds, 2.0 * period)

# Read only the exposed ends of stacks to secure a legal opening move even
# when a huge pile would exhaust the budget during the full observation.
func _opening_move() -> void:
	if not _valid_worker_hint(_worker_hint): _worker_hint = -1
	if not _valid_work_hint(_work_hint): _work_hint = -1
	if _assemble_quick_move(): return
	var now := Time.get_ticks_usec()
	var stop_probe := now + maxi(10, (deadline-now) >> 2)
	var upper: int = state._next_group
	var limit := mini(192,upper-1)
	for _index in limit:
		if Time.get_ticks_usec() >= stop_probe: return
		if _next_probe_group >= upper: _next_probe_group = 1
		var gid := _next_probe_group
		_next_probe_group += 1
		if not state.groups.has(gid): continue
		var g: Dictionary = state.groups[gid]
		if g.owner != owner or g.job != "work" or g.cards.is_empty(): continue
		for id in [g.cards.front(),g.cards.back()]:
			if state.cards[id].type == "work": _work_hint = id
			elif _valid_worker_hint(id): _worker_hint = id
		if _assemble_quick_move(): return

func _valid_worker_hint(id: int) -> bool:
	if not state.cards.has(id): return false
	var card: Dictionary = state.cards[id]
	return card.owner == owner and state.config.can_work(card.type) and not card.paused and not state.tasks.has(id)

func _valid_work_hint(id: int) -> bool:
	if not state.cards.has(id): return false
	var card: Dictionary = state.cards[id]
	return card.owner == owner and card.type == "work" and state.groups[card.group].job == "work"

func _assemble_quick_move() -> bool:
	if _worker_hint < 0 or _work_hint < 0: return false
	var gid: int = state.cards[_work_hint].group
	if state.cards[_worker_hint].group == gid: return false
	quick_move = _move([_worker_hint],gid)
	return true

func _observe() -> bool:
	var reserved := {}
	for batch_id in state.outsourcing:
		if not _open(): return false
		var payments: Dictionary = state.outsourcing[batch_id].payments
		for wallet in payments:
			if not _open(): return false
			reserved[wallet] = int(reserved.get(wallet,0)) + int(payments[wallet])
	for gid in state.groups:
		if not _open(): return false
		var g: Dictionary = state.groups[gid]
		var ours: bool = g.owner == owner
		var row := {"id":gid, "owner":g.owner, "job":g.job, "n":0, "work":[], "people":0, "staff":[], "capacity":0.0, "participants":0,
			"rate":0.0, "progress":state.group_work_progress(gid), "transfer":0, "overtime":0, "cash":0, "slack":0, "income_rate":0.0}
		for id in g.cards:
			if not _open(): return false
			var c: Dictionary = state.cards[id]
			var kind: String = c.type
			if kind == "work":
				row.n += 1
				if row.work.size() < MATERIAL_BATCH: row.work.append(id)
				continue
			if kind == "money":
				# Surplus in a reserved wallet can pay for an offer; moving the
				# whole wallet would interrupt the outsourcing batch.
				var free := maxi(0,int(c.amount)-int(reserved.get(id,0)))
				row.cash += free
				funds[g.owner] += free
				if ours and free > 0 and not reserved.has(id) and cash_ids.size() < MATERIAL_BATCH:
					cash_ids.append(id)
				continue
			if not ours and kind == "strike" and c.status == "ready": enemy_strike_ready = true
			if ours: inventory[kind] = int(inventory.get(kind,0)) + 1
			if kind == "overtime": row.overtime += 1
			if kind == "slack": row.slack += 1
			if state.config.roles.has(kind):
				var role: Dictionary = state.config.roles[kind]
				var task: String = state.tasks.get(id,{}).get("kind","")
				if ours:
					people.append(id)
					workers += int(role.can_work)
					supports += int(not role.can_work)
					if not role.can_work and not c.paused and task.is_empty(): specialist = id
				if c.paused: continue
				if role.can_work and task in ["","work"]: row.staff.append(id)
				row.people += 1
				if not ours and role.can_work and role.can_be_meeting_target: opponent_workers += 1
				if task == "work":
					var assigned: int = state.tasks[id].work_ids.size()
					row.capacity += assigned
					row.participants += 1
					row.rate += 1.0 / float(role.work_seconds)
					row.income_rate += assigned * state.config.income_per_work(kind)
					if ours: producers += 1
				elif task == "transfer":
					row.transfer += int(role.transfer_capacity)
			elif ours and c.status == "ready":
				if not ready.has(kind): ready[kind] = []
				ready[kind].append(id)
		var speed := pow(float(state.config.rules.overtime.speed_multiplier), int(row.overtime))
		# WorkState uses one shared batch clock: average participant speed
		# times the total assigned work, including a partial final batch.
		var cycle_rate: float = float(row.rate) * speed / maxi(1,row.participants)
		row.rate = cycle_rate * float(row.capacity)
		row.income_rate *= cycle_rate
		if row.job == "transfer":
			row.capacity = row.transfer
			row.progress = state.group_transfer_progress(gid)
			row.rate = float(row.transfer) / float(state.config.rules.transfer.seconds)
		pending[g.owner] += row.n
		throughput[g.owner] += row.rate
		groups[gid] = row
		if ours and row.n > 0 and row.job == "work":
			if destination < 0 or _load(row) > _load(groups[destination]): destination = gid
	return true

func _load(row: Dictionary) -> float:
	return float(row.n) / maxf(1.0, float(row.people))

func _evaluate_actions(rng: RandomNumberGenerator) -> void:
	# Cash has diminishing utility once the next visible purchase is affordable.
	var employee_price: float = state.config.cards.employee.price
	cash_value = minf(0.4, 1.0 / maxf(1.0, employee_price)) / (1.0 + float(funds[owner]) / maxf(1.0, 2.0 * employee_price))
	var enemy := 1 - owner
	for offer in state.offers:
		if not _open(): return
		if offer.is_empty() or offer.price > funds[enemy] or not state.config.can_work(offer.type): continue
		var role: Dictionary = state.config.roles[offer.type]
		var rate := float(role.work_capacity) / float(role.work_seconds)
		if rate > enemy_reply_rate:
			enemy_reply_rate = rate
			enemy_reply_offer = offer.id
	var best_recipe := -INF
	for id in people:
		if not _open(): return
		var person: Dictionary = state.cards[id]
		if person.paused or state.tasks.get(id,{}).get("kind","") not in ["", "work"]: continue
		var recipe: Dictionary = state.config.coffee_upgrade(person.type)
		if recipe.is_empty(): continue
		var value := _upgrade_gain(person.type,recipe) / maxi(1,int(recipe.cost) - int(inventory.get("coffee",0)))
		if value > best_recipe:
			best_recipe = value
			graduate = id
	# WAIT is a real candidate and remains executable with a zero time budget.
	_offer(WAIT, 0.0, "维持当前生产并保留购牌资金")
	if _open(): _production()
	if _open():
		if rng.randf() < float(policy.buy_chance):
			_shop()
		else:
			shop_reason = "本次购牌概率未触发"
	if _open(): _tools()

func _worker_gain(kind: String) -> float:
	var role: Dictionary = state.config.roles[kind]
	var rate := float(role.work_capacity) / float(role.work_seconds)
	return minf(float(pending[owner]), horizon * rate) * (1.0 + cash_value * state.config.income_per_work(kind))

func _production() -> void:
	var staffed := -1
	var backlog := -1
	for gid in groups:
		if not _open(): return
		var row: Dictionary = groups[gid]
		if row.owner != owner or row.n == 0: continue
		if row.job == "work" and row.rate > 0.0: staffed = gid
		if backlog < 0 or row.n > groups[backlog].n: backlog = gid
	if destination < 0 and backlog < 0: return
	var considered_workers := {}
	for id in people:
		if not _open(): return
		var c: Dictionary = state.cards[id]
		if c.paused or not state.config.can_work(c.type): continue
		var task: String = state.tasks.get(id,{}).get("kind","")
		if task not in ["", "transfer", "slack"]: continue
		if task != "" and producers > 0: continue
		# Unoccupied staff of identical rank are interchangeable. Avoid
		# filling all finalists with different UIDs for the same assignment.
		var worker_key := "%s/%s" % [c.type, task]
		if considered_workers.has(worker_key): continue
		considered_workers[worker_key] = true
		if destination >= 0:
			_staffing_targets(id,c)
		elif producers == 0 and backlog >= 0:
			var batch := [id]
			batch.append_array(groups[backlog].work)
			_offer(_move(batch,-1), _worker_gain(c.type), "从停滞的组合中分出人员和工作，恢复生产")
	if staffed < 0: return
	for gid in groups:
		if not _open(): return
		var row: Dictionary = groups[gid]
		if gid != staffed and row.owner == owner and row.job == "work" and row.n > 0 and row.people == 0:
			var extra := minf(row.work.size(), maxf(0.0, groups[staffed].rate * horizon - float(groups[staffed].n)))
			_offer(_move(row.work,staffed), extra, "将待办补入会在预测期内清空的工作组")

# Estimate how much additional work the next batches can actually cover.
# Equivalent stacks give the opponent the same options; evaluate one of each
# shape so an exposed busy stack and a safer separate stack can both advance.
func _staffing_targets(id: int, card: Dictionary) -> void:
	var seen := {}
	var role: Dictionary = state.config.roles[card.type]
	for gid in groups:
		if not _open(): return
		var g: Dictionary = groups[gid]
		if g.owner != owner or g.job != "work" or g.n <= g.capacity or gid == card.group: continue
		var extra := minf(role.work_capacity,g.n-g.capacity)
		var key := hash([g.people,g.capacity,g.rate,g.overtime,g.progress,g.n])
		if seen.has(key): continue
		seen[key] = true
		var joined: float = state.config.work_rate(card.type,g.overtime)
		var cycle: float = g.rate/g.capacity if g.capacity > 0 else 0.0
		var new_cycle: float = (cycle * g.participants + joined) / (g.participants+1)
		var old_files := minf(g.n, floorf(g.progress + horizon*cycle) * g.capacity)
		var new_files := minf(g.n, floorf(g.progress + horizon*new_cycle) * (g.capacity+extra))
		# Fractional progress distinguishes very long, incomplete cycles.
		var partial := minf(g.n, (g.progress+horizon*new_cycle)*(g.capacity+extra)) - minf(g.n,(g.progress+horizon*cycle)*g.capacity)
		var gain: float = (0.9*(new_files-old_files) + 0.1*partial) * (1.0 + cash_value*state.config.income_per_work(card.type))
		_offer(_move([id],gid),gain,"派工至 %d 组，比较该组的工作量、批次进度和合组后的产速" % gid)

func _move(ids: Array, gid: int, person := -1) -> Dictionary:
	return {"kind":"move","ids":ids,"group":gid,"person":person}

func _activate(id: int, gid: int, person := -1) -> Dictionary:
	return {"kind":"activate","tool":id,"group":gid,"person":person}

func _offer(action: Dictionary, score: float, reason: String) -> void:
	if not _open() or not is_finite(score): return
	evaluated += 1
	var item := {"kind":action.kind,"action":action,"score":score,"reason":reason}
	for key in ["offer","tool","group","card_type"]:
		if action.has(key): item[key] = action[key]
	if score > best_score:
		best = action
		best_score = score
		best_reason = reason
	var index := 0
	while index < trace.size() and trace[index].score >= item.score: index += 1
	if index < TRACE_LIMIT:
		trace.insert(index,item)
		if trace.size() > TRACE_LIMIT: trace.pop_back()

func apply_action(game: RefCounted, seat: int, action: Dictionary) -> bool:
	match action.kind:
		"wait": return true
		"move": return game.move_cards(action.ids,action.group,action.get("person",-1)) >= 0
		"activate": return game.activate(action.tool,action.group,action.get("person",-1))
		"buy": return game.buy(action.offer,seat) >= 0
		"dismiss": return game.dismiss_people(action.ids,seat)
	return false

func _shop() -> void:
	var reserve: int = policy.min_reserve
	var direct := 0
	var financing := 0
	var short_cash := 0
	shop_reason = "已检查的市场牌均不符合采购种类或持有量设置"
	for offer in state.offers:
		if not _open(): return
		if offer.is_empty(): continue
		var kind: String = offer.type
		if not policy.purchase_priority.has(kind): continue
		if not state.config.can_purchase(kind): continue
		var rank: int = policy.purchase_priority.find(kind)
		if state.config.roles.has(kind):
			if people.size() >= policy.desired_people: continue
			if not state.config.can_work(kind) and supports >= policy.max_support_people: continue
		else:
			var limit: int = policy.max_card_copies.get(kind,policy.max_tool_copies)
			if kind == "coffee":
				if graduate < 0: continue
				limit = maxi(limit, int(state.config.coffee_upgrade(state.cards[graduate].type).cost))
			if int(inventory.get(kind,0)) >= limit: continue
		var value := _market_gain(kind)
		var score := value - float(offer.price) * cash_value
		# Supply order breaks near-ties but cannot dominate productive value.
		score *= 1.0 + 0.05 / float(1 + rank)
		if int(funds[owner]) - int(offer.price) >= reserve:
			direct += 1
			_offer({"kind":"buy","offer":offer.id,"card_type":kind},score,
				"比较买入%s的预测产出与现金成本" % state.config.cards[kind].name)
		else:
			short_cash += 1
			if score > 0.0:
				var previous := evaluated
				_finance(offer,score)
				financing += evaluated - previous
		shop_reason = "已比较 %d 个可直接购买和 %d 个开除筹资方案；%d 张牌受可用现金或留存门槛限制" % [direct,financing,short_cash]

func _finance(offer: Dictionary, purchase_gain: float) -> void:
	if people.size() <= int(state.config.rules.fire.minimum_people): return
	# The purchase requires a second decision. Do not sell for a card that
	# will leave before then, or a contested card the rival can already buy.
	if int(offer.id) == enemy_reply_offer: return
	var slot: int = state.offers.find(offer)
	var lifetime := (slot + 1.0 - float(state.conveyor_progress)) * float(state.config.rules.conveyor.interval_seconds)
	if lifetime <= period: return
	for id in people:
		if not _open(): return
		var person: Dictionary = state.cards[id]
		if person.paused or state.tasks.get(id,{}).get("kind","") in ["coffee","meeting"]: continue
		var refund: int = state.config.cards[person.type].refund
		if refund <= 0 or funds[owner] + refund - policy.min_reserve < offer.price: continue
		if state.config.can_work(person.type) and workers <= maxi(1,int(policy.production_reserve_people)): continue
		var loss := _worker_gain(person.type) if state.config.can_work(person.type) else 0.5
		var score := purchase_gain * maxf(0.0,1.0-period/horizon) - loss
		_offer({"kind":"dismiss","ids":[id],"offer":offer.id,"card_type":offer.type},score,
			"开除%s可回收%d现金，为下一次购入%s筹资" % [state.config.cards[person.type].name, refund, state.config.cards[offer.type].name])

func _market_gain(kind: String) -> float:
	if state.config.can_work(kind): return _worker_gain(kind) * maxf(0.0,1.0-period/horizon)
	if kind == "coffee":
		if graduate < 0: return 0.0
		var before: String = state.cards[graduate].type
		var recipe: Dictionary = state.config.coffee_upgrade(before)
		return _upgrade_gain(before,recipe) / float(maxi(1,int(recipe.cost)-int(inventory.get("coffee",0))))
	if kind == "overtime": return maxf(0.0,float(throughput[owner])*horizon*(float(state.config.rules.overtime.speed_multiplier)-1.0))
	if kind == "strike":
		return minf(float(pending[1-owner]), throughput[1-owner] * minf(horizon,float(state.config.rules.strike.duration_seconds)))
	if kind == "outsource":
		var unit: int = state.config.rules.outsource.cost_per_work
		var surplus := maxf(0.0, float(funds[owner]) - float(state.config.cards[kind].price))
		return minf(float(pending[owner]),surplus/unit) * maxf(0.0,1.0-float(state.config.rules.outsource.seconds)/horizon)
	if kind == "transfer": return minf(float(pending[owner]),float(policy.transfer_batch_size)) * (1.0 if supports > 0 else 0.1)
	if kind == "meeting": return _meeting_gain() if specialist >= 0 or workers > int(policy.production_reserve_people) else 0.0
	if kind == "slack": return _market_gain("coffee") if specialist >= 0 and graduate >= 0 else 0.0
	if state.config.is_person(kind) and not state.config.can_work(kind):
		var synergy: bool = inventory.has("meeting") or inventory.has("slack") or inventory.has("transfer")
		return _meeting_gain() if synergy else 0.3
	return 0.0

func _upgrade_gain(kind: String, recipe: Dictionary) -> float:
	var next: String = recipe.to
	var delay: float = state.config.coffee_seconds(kind)
	var lost_work: float = minf(_worker_gain(kind), delay * state.config.work_rate(kind,0) * state.config.roles[kind].work_capacity)
	var saving := _worker_gain(next) - _worker_gain(kind) - lost_work
	# Finance future buying with income from the higher tier; promotion
	# becomes attractive only while enough ordinary work remains to use it.
	var income: int = state.config.income_per_work(next) - state.config.income_per_work(kind)
	var future_files := minf(pending[owner], horizon * 2.0 * state.config.work_rate(next,0))
	var option := maxf(0.0,float(income)) * future_files * cash_value
	if not state.config.coffee_upgrade(next).is_empty(): option += minf(1.0,float(pending[owner]) / 10.0)
	return maxf(0.0,saving + option)

func _meeting_gain() -> float:
	if opponent_workers <= 0: return 0.0
	return minf(float(pending[1-owner]),float(throughput[1-owner]) * minf(horizon,float(state.config.rules.meeting.duration_seconds)))

func _tools() -> void:
	for kind in policy.tool_priority:
		if not _open(): return
		if not ready.has(kind): continue
		# Ready copies on different stacks can have different costs. A loose
		# overtime card is useful even when an earlier copy is already in use.
		var visited := {}
		for id in ready[kind]:
			if not _open(): return
			var gid: int = state.cards[id].group
			if visited.has(gid): continue
			visited[gid] = true
			_tool(kind,id)
			if kind in ["coffee","strike"]: break

func _tool(kind: String, id: int) -> void:
	var c: Dictionary = state.cards[id]
	match kind:
		"strike": _strike(id)
		"meeting": _meeting(id)
		"coffee": _coffee(id)
		"outsource": _outsource(id)
		"transfer": _transfer(id)
		"slack":
			if specialist < 0 or graduate < 0: return
			var gid: int = state.cards[specialist].group
			var benefit := _market_gain("coffee")
			if groups[gid].rate > 0.0 and groups[gid].people > 1:
				_offer(_move([specialist],-1),benefit*0.75,"调出辅助人员，为摸鱼产咖啡准备")
			elif gid != c.group:
				_offer(_move([id],gid),benefit,"用辅助人员产咖啡，保留在岗产能")
		"overtime":
			for gid in groups:
				if not _open(): return
				var g: Dictionary = groups[gid]
				if g.owner != owner or gid == c.group or g.job != "work" or g.rate <= 0: continue
				var old: Dictionary = groups[c.group]
				var multiplier: float = state.config.rules.overtime.speed_multiplier
				var gain := minf(float(g.n),g.rate*horizon*multiplier)-minf(float(g.n),g.rate*horizon)
				var loss := minf(float(old.n),old.rate*horizon)-minf(float(old.n),old.rate*horizon/multiplier)
				_offer(_move([id],gid), gain-loss, "加速在岗人员，扣除原组移走加班牌的损失")

func _strike(id: int) -> void:
	var duration: float = minf(horizon,state.config.rules.strike.duration_seconds)
	for gid in groups:
		if not _open(): return
		var g: Dictionary = groups[gid]
		if g.owner == owner or g.people == 0: continue
		# Ejecting people delays the next settlement. The group's progress
		# survives; a funded outsourcing batch can even finish unattended.
		var lost := 0.0
		if g.capacity > 0.0 and g.rate > 0.0:
			var cycles := floorf(g.progress + duration * float(g.rate) / float(g.capacity))
			lost = minf(float(g.n),cycles * float(g.capacity))
			if g.job == "transfer": lost *= 2.0
			if g.n == pending[1-owner] and lost >= g.n: lost += 1.0
		elif g.job == "slack" and g.slack > 0:
			lost = float(g.people) * state.config.slack_rate(g.slack) * duration
		if lost > 0.0: _offer(_activate(id,gid),lost,"按该组即将完成的工作及停工时长选择罢工目标")

func _coffee(id: int) -> void:
	for target in people:
		if not _open(): return
		var person: Dictionary = state.cards[target]
		if person.paused or state.tasks.get(target,{}).get("kind","") not in ["", "work"]: continue
		if groups[person.group].job not in ["work","meeting"]: continue
		var recipe: Dictionary = state.config.coffee_upgrade(person.type)
		if recipe.is_empty() or ready.coffee.size() < recipe.cost: continue
		var cups: Array = []
		for i in int(recipe.cost):
			if not _open(): return
			cups.append(ready.coffee[i])
		var command := _move(cups,person.group,target)
		if int(recipe.cost) == 1 and state.cards[id].group == person.group:
			command = _activate(id,person.group,target)
		_offer(command,_upgrade_gain(person.type,recipe),"比较每名可晋升人员的产能收益、收入与晋升停工成本")

func _meeting(id: int) -> void:
	var expected := _meeting_gain()
	if expected <= 0.0: return
	for person in people:
		if not _open(): return
		var c: Dictionary = state.cards[person]
		if c.paused or state.tasks.get(person,{}).get("kind","") not in ["", "work"]: continue
		var productive: bool = state.config.can_work(c.type)
		if productive and producers <= int(policy.production_reserve_people): continue
		var gain := expected * minf(1.0,float(state.config.meeting_capacity(c.type))/maxi(1,opponent_workers))
		if productive: gain -= _worker_gain(c.type) * minf(1.0,float(state.config.rules.meeting.duration_seconds)/horizon)
		var gid: int = c.group
		if groups[gid].job != "work": continue
		var action := _activate(id,gid,person) if state.cards[id].group == gid else _move([id],gid,person)
		_offer(action,gain,"预计参会对手的停工损失，扣除己方主持人停工成本")

func _outsource(id: int) -> void:
	if destination < 0 or cash_ids.is_empty(): return
	var g: Dictionary = groups[destination]
	var sec: float = state.config.rules.outsource.seconds
	var unit: int = state.config.rules.outsource.cost_per_work
	var count := minf(float(g.n),floorf(float(funds[owner])/unit))
	var gain := count * (1.0-cash_value*unit) - minf(g.n,float(g.rate)*sec)
	if g.cash >= unit and state.cards[id].group == destination:
		_offer(_activate(id,destination),gain,"支付当前组现金外包，扣除暂停的正常生产")
	elif state.cards[id].group != destination:
		_offer(_move([id],destination),gain*0.70,"将外包牌放入有足够工作的组")
	else:
		var incoming: Array = []
		for cid in cash_ids:
			if state.cards[cid].group != destination: incoming.append(cid)
		if not incoming.is_empty():
			_offer(_move(incoming,destination),gain*0.85,"向外包组补入可动用资金")

func _transfer(id: int) -> void:
	var gid: int = state.cards[id].group
	var g: Dictionary = groups[gid]
	if destination < 0: return
	var target: Dictionary = groups[destination]
	var batch := mini(int(policy.transfer_batch_size), target.n-1)
	if batch <= 0: return
	# Keep at least one work and ordinary production available while feeding
	# a transfer group. Avoid reversible all-transfer loops on both seats.
	var amount := mini(batch,MATERIAL_BATCH)
	var gain := 2.0 * minf(float(amount),horizon/float(state.config.rules.transfer.seconds))
	if g.job == "work" and g.rate > 0.0 and g.people > 0:
		_offer(_move([id],-1),gain*0.3,"拆出甩锅工具，保留原组生产")
	elif g.people == 0:
		if specialist >= 0: _offer(_move([specialist],gid),gain*0.6,"由辅助人员负责甩锅")
	elif g.n == 0:
		_offer(_move(target.work.slice(0,amount),gid),gain*0.8,"保留普通工作并给甩锅组补料")
	elif g.job == "work":
		_offer(_activate(id,gid),gain,"启动已有人员与材料的甩锅组合")
