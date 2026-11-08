# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Actions = preload("res://engine/off_work_bot_actions.gd")
var compared := 0
var successful_kinds := {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_market_and_ownership()
	_work_union_and_dismissal()
	_coffee_and_function_locks()
	_meeting_transfer_and_slack()
	_outsource_and_recruitment()
	_strike_flight_and_defence()
	_scope_and_failure_boundaries()
	for kind in ["wait", "buy", "move", "activate", "dismiss"]:
		check(successful_kinds.has(kind), "真实成功动作覆盖 " + kind)
	print("OFF_WORK_SEARCH_ACTION_INDEX %d action pairs" % compared)
	finish()

func _state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work":120},{"employee":2}]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(834)
	return state

func _add(state: OffWorkState, kind: String, count := 1, group := -1, owner := 0) -> Array:
	var ids := []
	if group < 0: group = state.create_group(owner)
	for i in count: ids.append(state.add_card(kind, owner, group))
	return ids

func _cash(state: OffWorkState, amount: int, group := -1) -> int:
	var id: int = _add(state, "money", 1, group)[0]
	state.cards[id].amount = amount
	return id

func _work(state: OffWorkState, owner := 0) -> int:
	return int(state.cards[state._owner_type(owner, "work")[0]].group)

func _staff(state: OffWorkState, owner := 0) -> Array:
	var ids := state._owner_type(owner, "employee")
	state.move_cards(ids, _work(state, owner))
	return ids

func _snapshot(state: OffWorkState) -> PackedByteArray:
	var fields := []
	for key in OffWorkState.WORLD_FIELDS: fields.append(state.get(key))
	fields.append_array([state._rng.seed, state._rng.state, state.last_error, state._events,
		state.config.rules, state.config.cards, state.config.roles])
	return var_to_bytes(fields)

func _equal(left: OffWorkState, right: OffWorkState, label: String) -> void:
	var differences := []
	for key in OffWorkState.WORLD_FIELDS:
		if var_to_bytes(left.get(key)) != var_to_bytes(right.get(key)): differences.append(key)
	check(_snapshot(left) == _snapshot(right), label + " 全字段/RNG/事件/错误一致 " + str(differences))

## The reference calls the same entry point as live play, with its normal scan
## queries and refreshes. Both isolated worlds start on the identical RNG stream.
func _compare(state: OffWorkState, action: Dictionary, expected: Variant, label: String, owner := 0) -> OffWorkState:
	var before := _snapshot(state)
	var plain := state.fork_for_bot(951)
	var indexed := state.fork_for_bot(951)
	# A leftover index must not survive either side of the scoped command.
	for gid in indexed.groups: indexed._indexed_group(gid)
	var ordinary := Actions.apply_action(plain, owner, action)
	var optimized := Actions.apply_search_action(indexed, owner, action)
	compared += 1
	check((expected == null or ordinary == expected) and optimized == ordinary, label + " 返回值与实际合法性一致")
	_equal(plain, indexed, label + " 执行动作后")
	check(not indexed._search_queries and not indexed._index_queries and indexed._group_index.is_empty(),
		label + " 恢复查询标记并清空缓存")
	check(_snapshot(state) == before, label + " 不改原局")
	if ordinary: successful_kinds[action.kind] = true
	var immediate := plain.fork_search_node()
	immediate.last_error = plain.last_error
	immediate._events = plain._events.duplicate(true)
	# Cross work/coffee, strike flight, meeting, recruitment/outsource and supply
	# boundaries through the actual event engine, not an estimated continuation.
	for seconds in [0.37, 5.0, 20.0, 40.0]:
		plain.advance(seconds)
		indexed.advance(seconds)
		_equal(plain, indexed, label + " 再推进 %.2f 秒" % seconds)
	return immediate

func _generated(state: OffWorkState, label: String) -> void:
	var proposals := Actions.generate(state, 0, {}, Time.get_ticks_usec() + 2000000)
	check(proposals.complete, label + " 完整枚举实际候选")
	for action in proposals.actions:
		# Proposals can be rejected by authoritative rules (e.g. an already
		# active transfer). Search must preserve those false results as well.
		_compare(state, action, null, label + " " + str(action.get("intent", action.kind)))

func _market_and_ownership() -> void:
	var state := _state()
	_cash(state, 30)
	state.offers = [state._make_offer("employee"), state._make_offer("boss"), state._make_offer("union")]
	_generated(state, "开局购买/生产")
	var bought := _compare(state, {"kind":"buy", "offer":state.offers[0].id}, true, "购买员工")
	check(bought._owner_type(0, "employee").size() == 3, "购买确实增加员工")
	_compare(bought, {"kind":"buy", "offer":state.offers[0].id}, false, "已售商品")
	_compare(state, {"kind":"buy", "offer":-1}, false, "不存在商品")
	_compare(state, {"kind":"move", "ids":state._owner_type(1,"employee"), "group":_work(state)}, false, "对方员工")
	_compare(state, {"kind":"move", "ids":[float(state._owner_type(0,"employee")[0])]}, false, "非整数标识")
	var boss: int = _add(state, "boss")[0]
	_compare(state, {"kind":"buy", "offer":state.offers[1].id}, false, "重复老板")
	_compare(state, {"kind":"dismiss", "ids":[boss]}, true, "解雇老板")
	var poor := _state()
	poor.offers = [poor._make_offer("employee")]
	_compare(poor, {"kind":"buy", "offer":poor.offers[0].id}, false, "现金不足")

func _work_union_and_dismissal() -> void:
	var state := _state()
	var staff := _staff(state)
	var group := _work(state)
	var overtime := _add(state, "overtime", 3, group)
	state.advance(2.0)
	var protection: int = _add(state, "union")[0]
	_generated(state, "工作进度与工会")
	var protected := _compare(state, {"kind":"move", "ids":[protection], "group":group}, true, "工会驱逐加班")
	check(protected.group_has_union(group) and overtime.all(func(id): return protected.cards[id].group != group), "全部加班真正离开工会组")
	_compare(protected, {"kind":"move", "ids":[overtime[0]], "group":group}, false, "工会拒绝加班")
	_compare(protected, {"kind":"move", "ids":[protection]}, true, "移除工会恢复速度")
	_compare(state, {"kind":"dismiss", "ids":[staff[0]]}, true, "解雇正在工作的员工")
	_compare(state, {"kind":"dismiss", "ids":staff}, true, "默认允许解雇全部员工")
	state.config.rules.fire.minimum_people = 1
	_compare(state, {"kind":"dismiss", "ids":staff}, false, "配置保留人数后拒绝解雇全部员工")
	_compare(state, {"kind":"activate", "tool":overtime[0]}, true, "显式同步加班")
	_compare(state, {"kind":"move", "ids":state.group_cards(group), "group":group}, true, "整组原位移动")

func _coffee_and_function_locks() -> void:
	var state := _state()
	var staff := _staff(state)
	var cups := _add(state, "coffee", 4)
	state.advance(2.0)
	_generated(state, "工作与咖啡候选")
	var brewing := _compare(state, {"kind":"move", "ids":[staff[0]] + cups}, true, "独立咖啡升级")
	check(brewing.tasks.get(staff[0], {}).get("kind") == "coffee", "咖啡真实进入升级任务")
	_compare(brewing, {"kind":"move", "ids":[cups[0]]}, true, "取消咖啡释放材料")
	_compare(brewing, {"kind":"dismiss", "ids":[staff[0]]}, true, "升级中解雇")
	brewing.advance(5.0)
	check(brewing.cards[staff[0]].type == "grinder", "真实咖啡结算改变人员类型")
	_generated(brewing, "升级后缓存类型")
	var meeting: int = _add(state, "meeting")[0]
	var locked := _compare(state, {"kind":"move", "ids":[meeting], "group":_work(state)}, true, "工作中添会议")
	check(locked.groups[_work(locked)].function == "work", "工作锁不被闲置会议抢占")
	_compare(locked, {"kind":"activate", "tool":meeting}, false, "工作锁拒绝会议激活")

func _meeting_transfer_and_slack() -> void:
	var state := _state()
	_staff(state, 1)
	var host: int = _add(state, "leader")[0]
	var meeting: int = _add(state, "meeting", 1, state.cards[host].group)[0]
	var active := _compare(state, {"kind":"activate", "tool":meeting}, true, "会议随机选目标")
	check(active.meetings.has(meeting), "会议确实开始并使用相同随机流")
	_compare(active, {"kind":"activate", "tool":meeting}, false, "会议重复激活")
	var victim: int = active.meetings[meeting].targets[0]
	_compare(active, {"kind":"move", "ids":[victim]}, false, "会议目标不能移走", 1)
	active.advance(12.0)
	_compare(active, {"kind":"move", "ids":[active._owner_type(0,"work")[0]], "group":active.cards[meeting].group}, true, "冷却会议加工作")
	var person: int = state._owner_type(0,"employee")[0]
	for kind in ["transfer", "slack"]:
		var tool: int = _add(state, kind)[0]
		var ids := [person, tool]
		if kind == "transfer": ids.append_array(state._owner_type(0,"work").slice(0, 8))
		var started := _compare(state, {"kind":"move", "ids":ids}, true, kind + " 独立组自动激活")
		check(started.groups[started.cards[tool].group].function == kind, kind + " 真正获得主功能")
		_generated(started, kind + " 活动中候选")
		_compare(started, {"kind":"move", "ids":[tool]}, true, kind + " 移除主功能")

func _outsource_and_recruitment() -> void:
	var state := _state()
	var tool: int = _add(state, "outsource")[0]
	var wallet := _cash(state, 15)
	var materials: Array = state._owner_type(0, "work").slice(0, 8)
	var batch := _compare(state, {"kind":"move", "ids":[tool, wallet] + materials}, true, "外包预留资金")
	check(batch.outsourcing.has(tool) and batch.reserved_money(0) > 0, "外包确实预留材料和资金")
	_generated(batch, "外包进行中补料与消费")
	_compare(batch, {"kind":"move", "ids":[wallet]}, true, "外包移走钱包取消")
	var extra := _cash(batch, 4)
	_compare(batch, {"kind":"move", "ids":[extra] + batch._owner_type(0,"work").slice(8, 12), "group":batch.cards[tool].group}, true, "外包中途补料")
	var boss: int = _add(state, "boss")[0]
	var funds := _cash(state, 21)
	var hiring := _compare(state, {"kind":"move", "ids":[funds], "group":state.cards[boss].group}, true, "老板批量招聘")
	check(hiring.recruitment.get(boss, {}).get("count") == 4, "老板确实一次预留四名员工")
	_generated(hiring, "招聘中购买/调度")
	_compare(hiring, {"kind":"move", "ids":[funds]}, true, "移钱取消招聘")
	_compare(hiring, {"kind":"dismiss", "ids":[boss]}, true, "解雇老板取消招聘")
	var extra_funds := _cash(hiring, 5)
	_compare(hiring, {"kind":"move", "ids":[extra_funds], "group":hiring.cards[boss].group}, true, "招聘进行中追加一人")
	hiring.advance(10.0)
	check(hiring._owner_type(0,"employee").size() == 6, "真实招聘结算新增四人")
	_generated(hiring, "新员工产生后")

func _strike_flight_and_defence() -> void:
	var state := _state()
	var victims := _staff(state, 1)
	var target := _work(state, 1)
	var strike: int = _add(state, "strike")[0]
	var flight := _compare(state, {"kind":"activate", "tool":strike, "group":target}, true, "罢工真实飞行")
	check(flight.pending_strikes.has(strike), "罢工保留真实飞行而非立即落地")
	_compare(flight, {"kind":"activate", "tool":strike, "group":target}, false, "飞行中拒绝重复激活")
	_compare(flight, {"kind":"move", "ids":[strike]}, false, "飞行中拒绝移动")
	var protection: int = _add(flight, "union", 1, -1, 1)[0]
	_compare(flight, {"kind":"move", "ids":[protection], "group":target}, true, "飞行中工会防守", 1)
	_compare(flight, {"kind":"move", "ids":victims}, true, "飞行中人员撤离", 1)
	flight.advance(1.2)
	check(victims.all(func(id): return flight.is_striking(id)), "真实罢工命中后全部人员停工")
	_compare(flight, {"kind":"move", "ids":victims, "group":target}, false, "停工时拒绝返岗", 1)
	flight.advance(20.0)
	_compare(flight, {"kind":"move", "ids":victims, "group":target}, true, "停工结束批量返岗", 1)
	state.config.rules.strike.flight_seconds = 0.0
	var instant := _compare(state, {"kind":"activate", "tool":strike, "group":target}, true, "零飞行配置同一动作内驱离人员")
	check(not instant.cards.has(strike) and victims.all(func(id): return instant.is_striking(id)), "零飞行路径真实消耗罢工并改变分组")

func _scope_and_failure_boundaries() -> void:
	var state := _state()
	var before := _snapshot(state)
	check(not Actions.apply_search_action(state, 0, {"kind":"move", "ids":state._owner_type(0,"employee"), "group":_work(state)}), "模拟入口拒绝正式世界")
	check(_snapshot(state) == before and not state._search_queries and state._group_index.is_empty(), "拒绝正式世界不会修改状态或标记")
	for action in [{"kind":"unknown"}, {"kind":"move", "ids":[]}, {"kind":"activate", "tool":-1}, {"kind":"dismiss", "ids":[-1]}]:
		_compare(state, action, false, "失败动作 " + action.kind)
	var branch := state.fork_for_bot(1)
	branch._search_queries = true
	branch._indexed_group(_work(branch))
	check(Actions.apply_search_action(branch, 0, {"kind":"wait"}) and branch._search_queries and branch._group_index.is_empty(), "成功恢复此前已开启的查询范围并清除缓存")
	check(not Actions.apply_search_action(branch, 0, {"kind":"unknown"}) and branch._search_queries and branch._group_index.is_empty(), "失败同样恢复此前查询范围")
	branch._index_queries = true
	check(Actions.apply_search_action(branch, 0, {"kind":"wait"}) and branch._index_queries and branch._search_queries, "独立搜索标记不会关闭已有事件查询范围")
	state.winner = 1
	_compare(state, {"kind":"wait"}, true, "结束后等待")
	_compare(state, {"kind":"move", "ids":state._owner_type(0,"employee")}, false, "结束后拒绝动作")
