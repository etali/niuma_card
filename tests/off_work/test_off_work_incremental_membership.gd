# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

class LegacyState extends OffWorkState:
	pass

class ConfigSubclass extends OffWorkConfig:
	pass

func _initialize() -> void:
	_hot_add_consume()
	_layout_is_separate()
	_cold_restore_and_config()
	_polymorphic_fallbacks()
	_dictionary_order()
	_real_upgrade_and_transfer()
	_real_settlement_parity()
	_cancellation_boundaries()
	finish()

func _state(legacy := false, custom_config := false) -> OffWorkState:
	var config: OffWorkConfig = ConfigSubclass.new() if custom_config else OffWorkConfig.new()
	config.rules.initial.groups = [{"work":64, "employee":2}, {"leader":1}]
	config.rules.initial.money = 0
	config.rules.conveyor.pool = {"employee":1}
	var state: OffWorkState = LegacyState.new(config) if legacy else OffWorkState.new(config)
	state.new_game(941)
	return state

func _group(state: OffWorkState, owner := 0) -> int:
	return int(state.cards[state._owner_type(owner, "work")[0]].group)

func _snapshot(state: OffWorkState) -> PackedByteArray:
	var values: Array = []
	for key in OffWorkState.WORLD_FIELDS: values.append(state.get(key))
	values.append_array([state._rng.seed, state._rng.state, state._events, state.last_error])
	return var_to_bytes(values)

func _assert_indexes(state: OffWorkState, label: String) -> void:
	var expected_types := {}
	var expected_people: Array = []
	var expected_activity: Array = []
	var owners := {}
	# Independent oracle: public records in their original dictionary order.
	for id in state.cards:
		var card: Dictionary = state.cards[id]
		var kind := str(card.type)
		var owner := int(card.owner)
		if not expected_types.has(kind): expected_types[kind] = []
		expected_types[kind].append(id)
		if not owners.has(owner): owners[owner] = {"types":{}, "people":[], "activity":[]}
		if not owners[owner].types.has(kind): owners[owner].types[kind] = []
		owners[owner].types[kind].append(id)
		var category: String = state.config.category(kind)
		if category == "person":
			expected_people.append(id)
			owners[owner].people.append(id)
		if category in ["person", "tool", "ingredient"]:
			expected_activity.append(id)
			owners[owner].activity.append(id)
	var before := _snapshot(state)
	state._ensure_membership_index()
	check(state._type_index == expected_types and state._owner_index == owners
		and state._people_ids == expected_people and state._activity_ids == expected_activity,
		label + " 全局索引精确覆盖真实牌且保留字典插入顺序")
	for owner in [0, 1]:
		var expected: Dictionary = owners.get(owner, {"types":{}, "people":[], "activity":[]})
		check(state.activity_card_ids(owner) == expected.activity and state.people_count(owner) == expected.people.size()
			and state.work_count(owner) == expected.types.get("work", []).size(), label + " 公开计数/动态列表 %d" % owner)
		for kind in state.config.cards:
			check(state._owner_type(owner, str(kind)) == expected.types.get(kind, []), label + " 所有者种类列表 %d/%s" % [owner, kind])
	for group in state.groups:
		var works: Array = []
		for id in state.groups[group].cards:
			if state.cards[id].type == "work": works.append(id)
		check(state.group_work(int(group)) == works, label + " 组布局保持自己的顺序 %d" % group)
	check(_snapshot(state) == before, label + " 查询不改变公开世界/RNG/事件")

func _hot_add_consume() -> void:
	var state := _state()
	state._ensure_membership_index()
	var work_array: Array = state._type_index.work
	var people_array: Array = state._people_ids
	var other_group := _group(state, 1)
	var other_layout: Dictionary = state._indexed_group(other_group)
	var generation := state.membership_version()
	var cash_group := state.create_group(0)
	var cash: Array = []
	for index in 32:
		cash.append(state.add_card("money", 0, cash_group))
		check(state.money(0) == index + 1 and is_same(work_array, state._type_index.work),
			"逐块真实工资增量入表，不重扫工作牌 %d" % index)
	check(is_same(people_array, state._people_ids) and is_same(other_layout, state._indexed_group(other_group))
		and state.membership_version() > generation, "新增工资保留无关全局数组/组布局并推进失效令牌")
	_assert_indexes(state, "工资全部入表")
	var iteration_copy := state._owner_type(0, "money")
	for id in iteration_copy: state._consume(int(id))
	check(iteration_copy == cash and state.money(0) == 0 and not state._type_index.has("money")
		and not state._owner_index[0].types.has("money"), "付款遍历副本不会跳牌，末张删除清掉空种类桶")
	check(is_same(work_array, state._type_index.work), "逐张消费不重建无关工作数组")
	var person := state.add_card("grinder", 0)
	check(state._people_ids.back() == person and state.activity_card_ids().back() == person, "新人员按字典尾部进入动态索引")
	state._consume(person)
	var strike := state.add_card("strike", 0)
	check(state.activity_card_ids().has(strike) and not state._people_ids.has(strike), "新工具只进入动态活动列表")
	state._consume(strike)
	_assert_indexes(state, "工资/人员/工具消费后")

func _layout_is_separate() -> void:
	var state := _state()
	state._ensure_membership_index()
	var global_work: Array = state._type_index.work
	var other := _group(state, 1)
	var untouched: Dictionary = state._indexed_group(other)
	var own := _group(state)
	var source: Dictionary = state._indexed_group(own)
	var person: int = state._owner_type(0, "employee")[0]
	var generation := state.membership_version()
	var destination := state.create_group(0)
	check(is_same(global_work, state._type_index.work), "新增空组不影响全局索引热度")
	state.move_cards([person], destination)
	check(is_same(global_work, state._type_index.work) and is_same(untouched, state._indexed_group(other))
		and not is_same(source, state._indexed_group(own)), "搬牌仅使来源/目标布局失效")
	state.move_cards([person], own)
	check(not state.groups.has(destination) and is_same(global_work, state._type_index.work)
		and state.membership_version() > generation, "清理空组不重建全局索引且布局变更可见")
	_assert_indexes(state, "搬牌及空组清理")
	var overtime := state.add_card("overtime", 0, own)
	var union := state.add_card("union", 0)
	state.move_cards([union], own)
	check(int(state.cards[overtime].group) != own and state._owner_type(0, "overtime") == [overtime], "工会弹牌只改组位置不改全局归属")
	_assert_indexes(state, "工会弹牌")
	var strike := state.add_card("strike", 0)
	check(state.deliver_strike(strike, other), "对无工会的目标真实送达罢工")
	_assert_indexes(state, "罢工拆人及消耗工具")

func _cold_restore_and_config() -> void:
	var state := _state()
	state._invalidate_group_index()
	state.add_card("money", 0)
	check(state._indexed_card_count == -1 and state._owner_index.is_empty(), "冷缓存新增牌不为增量提前建表")
	_assert_indexes(state, "冷缓存按需重建")
	var saved := {}
	for key in OffWorkState.WORLD_FIELDS:
		var value: Variant = state.get(key)
		saved[key] = value.duplicate(true) if value is Dictionary or value is Array else value
	var person: int = state._owner_type(0, "employee")[0]
	state.move_cards([person], -1)
	var generation := state.membership_version()
	for key in OffWorkState.WORLD_FIELDS: state.set(key, saved[key])
	state._invalidate_group_index()
	check(state.membership_version() > generation, "同数量/同revision还原仍显式推进失效令牌")
	_assert_indexes(state, "同实例还原")
	var work_array: Array = state._type_index.work
	state.config.cards.work.work_seconds = 7.5
	state.add_card("money", 0)
	check(state._indexed_card_count == -1, "公开增量前检测到Config变更则完整失效")
	_assert_indexes(state, "Config变化后重建")
	check(not is_same(work_array, state._type_index.work), "Config变化不偷偷复用旧全局数组")
	state.advance(0.1)
	_assert_indexes(state, "Config新周期真实推进")
	var before := _snapshot(state)
	var branch := state.fork_for_bot(942)
	check(branch._owner_index.is_empty() and branch._membership_index.is_empty() and branch._indexed_card_count == -1,
		"BOT分支不复制任何全局或布局缓存")
	branch.add_card("money", 0)
	_assert_indexes(branch, "独立BOT分支")
	check(_snapshot(state) == before, "分支增量不修改源世界")
	state.new_game(943)
	_assert_indexes(state, "重用实例新开局")

func _polymorphic_fallbacks() -> void:
	for spec in [[true, false], [false, true]]:
		var state := _state(bool(spec[0]), bool(spec[1]))
		state._ensure_membership_index()
		var old: Array = state._type_index.work
		state.add_card("money", 0)
		check(state._indexed_card_count == -1 and state._owner_index.is_empty(), "State/Config子类保留完整失效 %s" % [spec])
		_assert_indexes(state, "多态回退 %s" % [spec])
		check(not is_same(old, state._type_index.work), "多态回退真实重建而非增量 %s" % [spec])

func _dictionary_order() -> void:
	var state := _state()
	var moved: int = state._owner_type(0, "employee")[0]
	var card: Dictionary = state.cards[moved]
	state.cards.erase(moved)
	state.cards[moved] = card
	state._invalidate_group_index()
	_assert_indexes(state, "导入非UID排序的字典")
	var added := state.add_card("employee", 0)
	check(state._owner_type(0, "employee").slice(-2) == [moved, added], "增量尾插不按UID重排导入顺序")
	state._consume(moved)
	_assert_indexes(state, "非UID顺序中稳定删除")

func _real_upgrade_and_transfer() -> void:
	var state := _state()
	var person: int = state._owner_type(0, "employee")[0]
	state.move_cards([person])
	var coffee := state.add_card("coffee", 0)
	state.move_cards([coffee], int(state.cards[person].group))
	state.advance(state.config.coffee_seconds("employee"))
	check(state.cards[person].type == "grinder", "真实咖啡事件改变人员类型")
	_assert_indexes(state, "类型升级完整失效后重建")
	var tool := state.add_card("transfer", 0)
	var source := _group(state)
	var works := state.group_work(source).slice(0, 2)
	state.move_cards([person] + works, int(state.cards[tool].group))
	state.advance(state.config.number("transfer", "seconds"))
	check(works.any(func(id): return state.cards.has(id) and int(state.cards[id].owner) == 1), "真实甩锅事件改变工作归属")
	_assert_indexes(state, "所有者转移完整失效后重建")

func _real_settlement_parity() -> void:
	var actual := _state()
	var reference := _state(true)
	for seconds in [0.1, 0.2, 9.7, 10.0, 0.3]:
		actual.advance(seconds)
		reference.advance(seconds)
		check(_snapshot(actual) == _snapshot(reference), "真实整批消费/工资与全重建世界逐字一致 %.2f" % seconds)
		_assert_indexes(actual, "真实工资 %.2f" % seconds)

func _cancellation_boundaries() -> void:
	var state := _state()
	state._bot_branch = true
	state._ensure_membership_index()
	var original_work: Array = state._type_index.work
	var token := preload("res://engine/bot_cancellation.gd").new()
	check(state._read_only_cancel_probe(token.is_cancelled)
		and not state._read_only_cancel_probe(token.is_cancelled.bind(1))
		and not state._read_only_cancel_probe(func(): return false), "只放行精确已知无绑定只读取消令牌")
	check(state.advance_for_search(10.0, Time.get_ticks_usec() + 10000000, token.is_cancelled)
		and is_same(original_work, state._type_index.work), "真实只读令牌下工资结算仍增量维护工作数组")
	_assert_indexes(state, "只读令牌结算后")
	token.request()
	var before := _snapshot(state)
	check(not state.advance_for_search(1.0, Time.get_ticks_usec() + 10000000, token.is_cancelled)
		and _snapshot(state) == before and not state._inside_membership_callback,
		"真实取消令牌立即停止且不改变世界")

	var custom := _state()
	custom._bot_branch = true
	var group := _group(custom)
	var person: int = custom._owner_type(0, "employee")[0]
	var callback := func() -> bool:
		custom.cards[person].type = "grinder"
		custom.cards[person].owner = 1
		custom.config.cards.strike.category = "person"
		custom.add_card("money", 0, group)
		check(custom._indexed_card_count == -1, "自定义回调内直接改类型/归属后新增仍完整失效")
		_assert_indexes(custom, "回调内完整失效重建")
		var cash := custom.add_card("money", 0, group)
		check(custom._indexed_card_count == -1, "回调内部重建不能提前放开增量")
		custom._ensure_membership_index()
		custom._consume(cash)
		check(custom._indexed_card_count == -1, "回调内部消费也保留完整失效")
		return true
	check(not custom.advance_for_search(1.0, Time.get_ticks_usec() + 10000000, callback)
		and not custom._inside_membership_callback and not custom._incremental_membership_safe,
		"任意回调返回后直到下一次完整失效仍禁用增量")
	_assert_indexes(custom, "自定义回调返回后")
	custom.add_card("money", 0, group)
	check(custom._indexed_card_count == -1 and custom._incremental_membership_safe,
		"回调后的首个结构变化完整失效并恢复后续增量资格")
	_assert_indexes(custom, "回调后的完整失效")
	custom.advance(0.001)
	custom._ensure_membership_index()
	var work: Array = custom._type_index.work
	custom.add_card("money", 0, group)
	check(is_same(work, custom._type_index.work), "显式边界恢复后再次增量维护")
