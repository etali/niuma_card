# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends RefCounted

## 确定性计算额度。子额度只收紧父额度；实际工作逐层扣费，未用额度不预扣。
## 操作类别是跨机器稳定的算法单位，不是 CPU 指令数或毫秒。
var limit: int
var requested_limit: int
var used := 0
var blocked := false
var parent: RefCounted
var categories: Dictionary = {}
## 子账共享有界失败日志，不保存状态/回调引用。一个子账只记录首次失败。
var task_gate: RefCounted
var label := "round"
var location: Dictionary = {}
var failure_log: Dictionary = {"events":[],"count":0,"seen":{}}
var _failure_recorded := false
const MAX_FAILURE_EVENTS := 512

func _init(amount: int, ancestor: RefCounted = null) -> void:
	limit = maxi(0,amount)
	requested_limit = limit
	parent = ancestor
	if parent != null:
		failure_log = parent.failure_log
		location = parent.location.duplicate()
		task_gate = parent.task_gate

func remaining() -> int:
	var amount := maxi(0,limit-used)
	return mini(amount,parent.remaining()) if parent != null else amount

func stopped() -> bool:
	if blocked: return true
	if limit-used <= 0:
		_record_failure(0,"checkpoint",location)
		return true
	return parent != null and parent.stopped()

func can_spend(amount: int) -> bool:
	return not blocked and amount <= remaining() and (parent == null or parent.can_spend(amount))

func spend(amount := 1, category := "expansion", at: Dictionary = {}) -> bool:
	amount = maxi(1,amount)
	if not can_spend(amount):
		var limiting = self
		while limiting.parent != null and not limiting.parent.can_spend(amount):
			limiting = limiting.parent
		limiting._record_failure(amount,category,at if not at.is_empty() else location,self)
		blocked = true
		return false
	if parent == null and task_gate != null and not task_gate.charge(amount,category,at):
		blocked = true
		return false
	if parent != null and not parent.spend(amount,category,at):
		blocked = true
		return false
	used += amount
	categories[category] = int(categories.get(category,0))+amount
	return true

func scope(amount: int, scope_label := "local", at: Dictionary = {}) -> RefCounted:
	var child = get_script().new(mini(maxi(0,amount),remaining()),self)
	child.label = scope_label
	child.requested_limit = maxi(0,amount)
	child.location.merge(at,true)
	return child

func _record_failure(amount: int, category: String, at: Dictionary, caller = null) -> void:
	if _failure_recorded: return
	_failure_recorded = true
	var path: Array = []
	var meter = caller if caller != null else self
	while meter != null:
		path.push_front({"scope":meter.label,"limit":meter.limit,"requested_limit":meter.requested_limit,"used":meter.used,
			"remaining":maxi(0,meter.limit-meter.used)})
		meter = meter.parent
	var event := {"kind":"compute","scope":label,"limit":limit,"requested_limit":requested_limit,"used":used,
		"remaining":maxi(0,limit-used),"requested":amount,"category":category,
		"location":at.duplicate(true),"path":path}
	_append_failure(event)

func _append_failure(event: Dictionary) -> void:
	failure_log["count"] += 1
	if failure_log["events"].size() < MAX_FAILURE_EVENTS:
		failure_log["events"].append(event)

## 节点计数器与计算账本分开，二者都记录触发位置。
static func counter_failure(p: Dictionary, counter: String, remaining: int, requested := 1) -> void:
	var meter = p.get("_compute")
	if meter == null: return
	var at: Dictionary = p.get("_diagnostic_location",meter.location)
	var key := str([meter.get_instance_id(),counter,at])
	if meter.failure_log["seen"].has(key): return
	meter.failure_log["seen"][key] = true
	meter._append_failure({"kind":"nodes","scope":counter,"remaining":remaining,
		"limit":p.get("_counter_limits",{}).get(counter,null),
		"requested":requested,"location":at.duplicate(true),"compute_scope":meter.label,
		"compute_limit":meter.limit,"compute_used":meter.used})

static func charge(p: Dictionary, amount := 1, category := "expansion") -> bool:
	var probe: Callable = p.get("_cancelled",Callable())
	if probe.is_valid() and probe.call(): return false
	var meter = p.get("_compute")
	return meter == null or meter.spend(amount,category,p.get("_diagnostic_location",meter.location))

static func checker(p: Dictionary, category: String) -> Callable:
	# 不捕获含_context的整个参数字典，避免缓存上下文与回调形成引用环。
	var runtime := {}
	for key in ["_compute","_cancelled","_diagnostic_location"]:
		if p.has(key): runtime[key] = p[key]
	return func() -> bool: return charge(runtime,1,category)

static func state_cost(state: GameState) -> int:
	var size := state.market.size()+state.combos.size()+1
	for who in state.players: size += state.players[who]["cards"].size()
	return size
