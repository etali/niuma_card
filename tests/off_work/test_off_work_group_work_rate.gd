# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const WORKERS := ["employee", "grinder", "workaholic", "work_emperor"]

class KindRateConfig extends OffWorkConfig:
	func work_rate(kind: String, overtime_count: int) -> float:
		var ordinary: float = super.work_rate(kind, overtime_count)
		return ordinary * 2.0 if kind == "grinder" else ordinary

class DurationConfig extends OffWorkConfig:
	func work_seconds() -> float:
		return 3.0

class DifferentKindState extends OffWorkState:
	func effective_work_kind(kind: String, group: int) -> String:
		return "leader" if kind == "grinder" else super.effective_work_kind(kind, group)

## The public constructor accepts a RefCounted config, not only ConfigSource.
## This adapter supplies the query interface used by group_work_rate.
class DuckConfig extends RefCounted:
	var delegate: OffWorkConfig
	var calls: Array = []
	func category(kind: String) -> String:
		return delegate.category(kind)
	func is_person(kind: String) -> bool:
		return delegate.is_person(kind)
	func can_work(kind: String) -> bool:
		return delegate.can_work(kind)
	func work_rate(kind: String, overtime_count: int) -> float:
		calls.append(kind)
		return delegate.work_rate(kind, overtime_count) * (3.0 if kind == "grinder" else 1.0)

func _initialize() -> void:
	_standard_exact_rates()
	_participant_boundaries()
	_union_boundaries()
	_polymorphic_configs()
	_polymorphic_state()
	finish()

func _configure(config: OffWorkConfig, count: int, duration := 10.0, multiplier := 1.2,
		overtime := 0, works := 512) -> void:
	var pile := {"work":works, "leader":1, "boss":1}
	for index in count:
		var kind: String = WORKERS[index % WORKERS.size()]
		pile[kind] = int(pile.get(kind, 0)) + 1
	if overtime > 0: pile.overtime = overtime
	config.cards.work.work_seconds = duration
	config.rules.overtime.speed_multiplier = multiplier
	config.rules.initial.groups = [pile]
	config.rules.initial.money = 0
	config.rules.conveyor.pool = {"employee":1}

func _world(count: int, duration := 10.0, multiplier := 1.2, overtime := 0, works := 512) -> OffWorkState:
	var config := OffWorkConfig.new()
	_configure(config, count, duration, multiplier, overtime, works)
	var state := OffWorkState.new(config)
	state.new_game(921)
	return state

func _group(state: OffWorkState) -> int:
	return int(state.cards[state._owner_type(0, "work")[0]].group)

## The pre-optimization implementation is the floating-point reference.
func _legacy_rate(state: OffWorkState, group: int) -> float:
	var participants := state.group_work_participants(group)
	if participants.is_empty(): return 0.0
	var rate := 0.0
	var overtime := state._group_type(group, "overtime").size()
	for person in participants:
		rate += state.config.work_rate(state.effective_work_kind(str(state.cards[person].type), group), overtime)
	return rate / float(participants.size())

func _snapshot(state: OffWorkState) -> PackedByteArray:
	var values: Array = []
	for key in OffWorkState.WORLD_FIELDS: values.append(state.get(key))
	values.append_array([state._rng.seed, state._rng.state, state._events, state.last_error])
	return var_to_bytes(values)

func _exact(state: OffWorkState, group: int, label: String) -> void:
	var before := _snapshot(state)
	var expected := _legacy_rate(state, group)
	var actual := state.group_work_rate(group)
	check(var_to_bytes(actual) == var_to_bytes(expected), label + " 保留原逐次浮点累加结果")
	check(_snapshot(state) == before, label + " 不改变公开状态、RNG或事件")

func _standard_exact_rates() -> void:
	# Twenty-four legal configurations, with non-binary decimal durations,
	# mixed employee tiers and group sizes that expose accumulation rounding.
	var specs := [[1.01, 0, 1], [1.01, 1, 2], [1.2, 1, 3],
		[1.2, 7, 7], [1.5, 3, 31], [1.5, 31, 127]]
	for duration in [0.0001, 7.5, 10.0, 17.3]:
		for spec in specs:
			var state := _world(int(spec[2]), duration, float(spec[0]), int(spec[1]))
			if not state.config.errors.is_empty():
				check(false, "速率夹具配置必须合法：" + str(state.config.errors))
				continue
			var group := _group(state)
			check(state.config.errors.is_empty() and state.group_work_participants(group).size() == int(spec[2]),
				"合法混合人员夹具保留全部参与者 %s/%s" % [duration, spec])
			_exact(state, group, "共享周期 %s/%s" % [duration, spec])
	var rounding := _world(3)
	var group := _group(rounding)
	var single: float = rounding.config.work_rate("employee", 0)
	check(var_to_bytes(_legacy_rate(rounding, group)) != var_to_bytes(single),
		"三人十秒夹具能检测直接返回单人速率造成的舍入变化")
	_exact(rounding, group, "三人十秒舍入边界")

func _participant_boundaries() -> void:
	var idle := _world(0)
	check(idle.group_work_participants(_group(idle)).is_empty() and idle.group_work_rate(_group(idle)) == 0.0,
		"只有领导和老板的组没有普通工作速率")
	_exact(idle, _group(idle), "无参与者")
	_exact(idle, -1, "不存在的组")
	var short := _world(7, 10.0, 1.2, 0, 1)
	var group := _group(short)
	check(short.group_work_participants(group).size() == 1, "一份尾工只分配一个真实工作槽")
	_exact(short, group, "人员多于尾工")
	var paused := _world(3)
	group = _group(paused)
	var strike := paused.add_card("strike", 1)
	check(paused.deliver_strike(strike, group), "真实送达罢工移走当前工作参与者")
	check(paused.group_work_participants(group).is_empty(), "罢工后的旧工作组没有参与者")
	_exact(paused, group, "罢工参与者边界")

func _union_boundaries() -> void:
	var state := _world(7, 7.5, 1.5, 3)
	var group := _group(state)
	var union := state.add_card("union", 0)
	check(state.move_cards([union], group) == group and state._group_type(group, "overtime").is_empty(),
		"工会按真实规则移走加班牌并保留原人员类型")
	_exact(state, group, "工会统一有效角色")
	state.config.roles.employee.can_work = false
	state._sync_schedule()
	check(not state.group_work_participants(group).is_empty() and state.group_work_rate(group) == 0.0,
		"高级人员可工作而工会目标角色不可工作时全组速率仍为零")
	_exact(state, group, "工会目标角色不可工作")

func _polymorphic_configs() -> void:
	var config := KindRateConfig.new()
	_configure(config, 3)
	var state := OffWorkState.new(config)
	state.new_game(922)
	var group := _group(state)
	check(config.get_script() != OffWorkState.ConfigSource and config.work_rate("grinder", 0) != config.work_rate("employee", 0),
		"Config子类夹具为不同角色提供不同速率")
	_exact(state, group, "Config子类逐人覆写")
	var duration := DurationConfig.new()
	_configure(duration, 7)
	state = OffWorkState.new(duration)
	state.new_game(923)
	_exact(state, _group(state), "Config子类覆写共享时长")
	state = _world(3)
	group = _group(state)
	var duck := DuckConfig.new()
	duck.delegate = state.config as OffWorkConfig
	state.config = duck
	var expected := _legacy_rate(state, group)
	duck.calls.clear()
	var actual := state.group_work_rate(group)
	var kinds := state.group_work_participants(group).map(func(person): return str(state.cards[person].type))
	check(var_to_bytes(actual) == var_to_bytes(expected) and duck.calls == kinds,
		"RefCounted配置适配器仍按参与者原顺序逐人调用速率")

func _polymorphic_state() -> void:
	var config := OffWorkConfig.new()
	_configure(config, 3)
	var state := DifferentKindState.new(config)
	state.new_game(924)
	var group := _group(state)
	check(state.get_script() != OffWorkState and state.effective_work_kind("grinder", group) == "leader",
		"State子类可独立覆写人员的有效工作角色")
	check(state.group_work_participants(group).size() == 3 and state.group_work_rate(group) < config.work_rate("employee", 0),
		"State覆写后不能把首人的速率套给全部参与者")
	_exact(state, group, "State子类逐人覆写")
