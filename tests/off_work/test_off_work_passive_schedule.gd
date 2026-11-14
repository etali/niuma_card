# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## A subclass deliberately keeps the complete old activation loop. Its only
## instrumentation observes calls; all world records still come from State.
class LegacyState extends OffWorkState:
	var schedules := 0
	var saw_deferred_activation := false
	func _reschedule(start_coffee := true) -> void:
		schedules += 1
		super._reschedule(start_coffee)
	func activate(tool_id: int, target_group: int = -1, target_card: int = -1) -> bool:
		saw_deferred_activation = saw_deferred_activation or _defer_passive_schedule
		return super.activate(tool_id, target_group, target_card)

class ConfigSubclass extends OffWorkConfig:
	pass

func _initialize() -> void:
	_ordinary_passives()
	_meeting_releases_coffee()
	_mixed_and_ejected_fallbacks()
	_invalid_and_public_activation()
	_config_subclass_fallback()
	finish()

func _fixture(legacy := false, config_subclass := false) -> OffWorkState:
	var config: OffWorkConfig = ConfigSubclass.new() if config_subclass else OffWorkConfig.new()
	config.rules.initial.groups = [{"work":64}, {"employee":1}, {"leader":1}, {"coffee":1}]
	config.rules.initial.money = 0
	config.rules.conveyor.pool = {"employee":1}
	var state: OffWorkState = LegacyState.new(config) if legacy else OffWorkState.new(config)
	state.new_game(932)
	state.move_cards([_id(state, "employee", 0)], _work(state, 0))
	return state

func _id(state: OffWorkState, kind: String, owner: int) -> int:
	return int(state._owner_type(owner, kind)[0])

func _work(state: OffWorkState, owner: int) -> int:
	return int(state.cards[_id(state, "work", owner)].group)

func _snapshot(state: OffWorkState) -> PackedByteArray:
	var values: Array = []
	for key in OffWorkState.WORLD_FIELDS: values.append(state.get(key))
	values.append_array([state._rng.seed, state._rng.state, state._events, state.last_error])
	return var_to_bytes(values)

func _equal(actual: OffWorkState, reference: OffWorkState, label: String) -> void:
	check(_snapshot(actual) == _snapshot(reference), label + " 公开状态/任务顺序/RNG/事件逐字等于原循环")
	check(not actual._defer_passive_schedule and not reference._defer_passive_schedule,
		label + " 返回后没有延迟排程标志残留")

func _tools(state: OffWorkState, kinds: Array, group := -1) -> Array:
	var ids: Array = []
	for kind in kinds: ids.append(state.add_card(str(kind), 0, group))
	return ids

func _ordinary_passives() -> void:
	for count in [1, 2, 3, 4, 8]:
		var actual := _fixture()
		var reference := _fixture(true) as LegacyState
		var kinds: Array = []
		for index in count: kinds.append("overtime")
		var ids := _tools(actual, kinds)
		var old_ids := _tools(reference, kinds)
		var before := reference.schedules
		var result := actual.move_cards(ids, _work(actual, 0))
		var old_result := reference.move_cards(old_ids, _work(reference, 0))
		check(result == old_result and reference.schedules - before == count + 1,
			"%d张加班的子类仍执行初始排程和每次原激活" % count)
		check(actual._can_batch_passive_activation(ids, result, 0) == (count >= 3),
			"仅至少三张合法被动牌满足合并前提 %d" % count)
		check(not reference.saw_deferred_activation, "State子类从不进入被动批次 %d" % count)
		_equal(actual, reference, "%d张加班" % count)
		var settled := _snapshot(actual)
		actual._reschedule()
		check(_snapshot(actual) == settled, "两轮后追加排程不再改变标准任务顺序 %d" % count)
		actual.advance(0.25)
		reference.advance(0.25)
		_equal(actual, reference, "%d张加班后真实推进" % count)
	var actual := _fixture()
	var reference := _fixture(true)
	var ids := _tools(actual, ["union", "union", "union"])
	var old_ids := _tools(reference, ["union", "union", "union"])
	actual.move_cards(ids, _work(actual, 0))
	reference.move_cards(old_ids, _work(reference, 0))
	check(actual._can_batch_passive_activation(ids, _work(actual, 0), 0), "纯工会被动牌也保留真实激活")
	_equal(actual, reference, "三张工会")

func _meeting_fixture(legacy: bool, count: int) -> Dictionary:
	var state := _fixture(legacy)
	var drinker := _id(state, "employee", 1)
	state.move_cards([_id(state, "coffee", 1)], int(state.cards[drinker].group))
	var host := _id(state, "leader", 0)
	var meeting := state.add_card("meeting", 0, int(state.cards[host].group))
	state.activate(meeting)
	var kinds: Array = []
	for index in count: kinds.append("overtime")
	return {"state":state, "host":host, "drinker":drinker, "meeting":meeting,
		"tools":_tools(state, kinds, int(state.cards[host].group))}

func _meeting_releases_coffee() -> void:
	for count in [3, 4, 8]:
		var current := _meeting_fixture(false, count)
		var old := _meeting_fixture(true, count)
		var actual: OffWorkState = current.state
		var reference: OffWorkState = old.state
		check(actual.is_meeting_target(current.drinker) and not actual.tasks.has(current.drinker),
			"跨组夹具先由真实会议取消对方咖啡 %d" % count)
		_equal(actual, reference, "移动主持人前 %d" % count)
		actual.move_cards([current.host] + current.tools, _work(actual, 0))
		reference.move_cards([old.host] + old.tools, _work(reference, 0))
		check(not actual.meetings.has(current.meeting) and actual.tasks.has(current.drinker)
			and actual.tasks[current.drinker].kind == "coffee", "主持人离开后真实散会并重启咖啡 %d" % count)
		var worker := _id(actual, "employee", 0)
		check(actual.tasks.keys().find(current.drinker) < actual.tasks.keys().find(worker),
			"第二轮重建把work任务放到新coffee之后，不能压成一轮 %d" % count)
		_equal(actual, reference, "跨组咖啡重启 %d" % count)
		var settled := _snapshot(actual)
		actual._reschedule()
		check(_snapshot(actual) == settled, "跨组咖啡重启后第三轮排程幂等 %d" % count)
		for seconds in [0.25, 5.0, 7.0]:
			actual.advance(seconds)
			reference.advance(seconds)
			_equal(actual, reference, "跨组咖啡后续 %d/%.2f" % [count, seconds])

func _mixed_and_ejected_fallbacks() -> void:
	for kinds in [["overtime", "coffee", "overtime", "overtime"],
		["overtime", "union", "overtime", "overtime"],
		["overtime", "meeting", "overtime", "overtime"]]:
		var actual := _fixture()
		var reference := _fixture(true)
		var target := int(actual.cards[_id(actual, "leader", 0)].group) if kinds.has("meeting") else _work(actual, 0)
		var old_target := int(reference.cards[_id(reference, "leader", 0)].group) if kinds.has("meeting") else _work(reference, 0)
		var ids := _tools(actual, kinds)
		var old_ids := _tools(reference, kinds)
		actual.move_cards(ids, target)
		reference.move_cards(old_ids, old_target)
		check(not actual._can_batch_passive_activation(ids, target, 0), "混合功能或被工会弹出的候选保留原循环 %s" % [kinds])
		_equal(actual, reference, "混合/弹出 %s" % [kinds])
		actual.advance(0.25)
		reference.advance(0.25)
		_equal(actual, reference, "混合/弹出后推进 %s" % [kinds])

func _invalid_and_public_activation() -> void:
	var actual := _fixture()
	var reference := _fixture(true)
	var ids := _tools(actual, ["overtime", "overtime", "overtime"])
	var old_ids := _tools(reference, ["overtime", "overtime", "overtime"])
	for target in [_work(actual, 1), 999999]:
		check(actual.move_cards(ids, target) == reference.move_cards(old_ids, target), "非法目标返回值不变")
		_equal(actual, reference, "非法目标 %d" % target)
	actual.move_cards(ids, _work(actual, 0))
	reference.move_cards(old_ids, _work(reference, 0))
	var person := actual.add_card("employee", 0)
	var old_person := reference.add_card("employee", 0)
	actual.add_card("coffee", 0, int(actual.cards[person].group))
	reference.add_card("coffee", 0, int(reference.cards[old_person].group))
	check(actual.activate(ids[0], _work(actual, 0)) == reference.activate(old_ids[0], _work(reference, 0)),
		"批次之后公开单次激活仍执行原完整排程")
	check(actual.tasks.has(person) and actual.tasks[person].kind == "coffee", "公开单次激活能启动新咖啡，延迟标志已复位")
	_equal(actual, reference, "批次后的公开激活")

func _config_subclass_fallback() -> void:
	var actual := _fixture(false, true)
	var reference := _fixture(true, true)
	var ids := _tools(actual, ["overtime", "overtime", "overtime", "overtime"])
	var old_ids := _tools(reference, ["overtime", "overtime", "overtime", "overtime"])
	actual.move_cards(ids, _work(actual, 0))
	reference.move_cards(old_ids, _work(reference, 0))
	check(not actual._can_batch_passive_activation(ids, _work(actual, 0), 0), "Config子类保留全部原被动激活")
	_equal(actual, reference, "Config子类回退")
