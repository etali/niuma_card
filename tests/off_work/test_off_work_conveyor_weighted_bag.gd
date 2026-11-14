# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Session = preload("res://engine/off_work_session.gd")
const Slots = preload("res://engine/shift_slot.gd")
const Replay = preload("res://engine/off_work_replay.gd")
const Live = preload("res://engine/off_work_bot_live.gd")
const BAG_FIELDS := ["_supply_bag", "_supply_bag_signature", "_supply_mode"]

class TestBoard extends Node:
	var _origin_by_gid := {}
	var _compact_by_gid := {}
	var group_overrides := {}
	var _spawned_by_owner := {}
	var _opening_counts := {}
	func sync_state(_state: OffWorkState) -> void: pass

class TestHud extends RefCounted:
	var _manual_paused := true

class TestHost extends Node:
	var state: OffWorkState
	var bot: OffWorkBot
	var board := TestBoard.new()
	var hud := TestHud.new()
	var replay := Replay.new()
	var _active_config := ""
	func _init() -> void: add_child(board)
	func _present(_event: Dictionary) -> void: pass
	func _update_hud() -> void: pass

func _initialize() -> void: _run.call_deferred()

func _world(pool := {"employee":3,"coffee":2,"strike":1,"boss":0}, seed_value := 618, slots := 2) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.conveyor.pool = pool.duplicate()
	config.rules.conveyor.slots = slots
	config.rules.conveyor.interval_seconds = 1.0
	config.rules.initial.groups = [{"work":100},{"employee":1}]
	config.rules.initial.money = 0
	var world := OffWorkState.new(config)
	world.new_game(seed_value)
	world.drain_events()
	return world

func _draw(world: OffWorkState, count: int) -> Array:
	var sequence := []
	for index in count: sequence.append(world._new_offer().duplicate(true))
	return sequence

func _types(offers: Array) -> Array:
	return offers.map(func(offer): return str(offer.type))

func _counts(kinds: Array) -> Dictionary:
	var result := {}
	for kind in kinds: result[kind] = int(result.get(kind,0))+1
	return result

func _clone_exact(source: OffWorkState) -> OffWorkState:
	var restored := OffWorkState.new(source.config)
	for key in Session.STATE_FIELDS:
		var value: Variant = source.get(key)
		restored.set(key,value.duplicate(true) if value is Array or value is Dictionary else value)
	restored._rng.state = source._rng.state
	return restored

func _frame(entry: Dictionary, time: float) -> Dictionary:
	var bytes := var_to_bytes(entry)
	return {"t":time,"size":bytes.size(),"data":Marshalls.raw_to_base64(bytes.compress(FileAccess.COMPRESSION_ZSTD))}

func _run() -> void:
	_exact_bags_and_seed_order()
	_live_pool_change_and_snapshot_validation()
	_forks_preserve_composition_without_private_order()
	_hypothetical_child_continuity()
	_recorded_live_branch_privacy()
	_session_roundtrip_and_legacy_migration()
	_replay_midframe_continuity()
	_legacy_replay_sampling()
	finish()

func _exact_bags_and_seed_order() -> void:
	var one := _world()
	var same := _world()
	var different := _world({"employee":3,"coffee":2,"strike":1,"boss":0},619)
	var sequence: Array = one.offers.duplicate(true)+_draw(one,28)
	check(sequence == same.offers+_draw(same,28), "同seed保持完整供牌序列与offer编号稳定")
	check(_types(sequence) != _types(different.offers+_draw(different,28)), "不同seed改变洗牌次序")
	for offset in range(0,30,6):
		check(_counts(_types(sequence.slice(offset,offset+6))) == {"employee":3,"coffee":2,"strike":1},
			"开局槽和后续供牌共同组成第%d袋，计数精确且零权重boss不出现" % (offset/6+1))
	check(one._supply_bag.is_empty(), "袋最后一张抽完后剩余数组为空")
	var next: Dictionary = one._new_offer()
	check(one._supply_bag.size() == 5 and _counts([str(next.type)]+one._supply_bag) == {"employee":3,"coffee":2,"strike":1},
		"下一张才装入并洗匀完整新袋，没有重抽或丢牌")
	check(BAG_FIELDS.all(func(field): return field in OffWorkState.WORLD_FIELDS), "权威快照保存袋剩余序列、池签名和供牌版本")
	check(one._supply_mode == "shuffle_bag_v1", "新局明确使用整袋洗牌模式")

func _live_pool_change_and_snapshot_validation() -> void:
	var world := _world()
	var signature := world._supply_bag_signature
	world.config.rules.conveyor.pool = {"coffee":2,"boss":0}
	var offer: Dictionary = world._new_offer()
	check(offer.type == "coffee" and world._supply_bag == ["coffee"] and world._supply_bag_signature != signature,
		"实时换卡表时下一次供牌重建匹配新整数配额的牌袋")
	var host := TestHost.new()
	host.state = world
	host.replay.record(host,[],true)
	var entry: Dictionary = Replay.decode_frame(host.replay.frames[0],world)
	if not need(not entry.is_empty(), "当前合法半袋录像快照可解码"):
		host.free()
		return
	var bad_values := [
		{"_supply_mode":"unknown_version"},
		{"_supply_bag":"coffee"},
		{"_supply_bag":["not_a_card"]},
		{"_supply_bag":["coffee","coffee","coffee"]},
		{"_supply_bag":["boss"]},
		{"_supply_bag_signature":123}]
	for changes in bad_values:
		var damaged: Dictionary = entry.duplicate(true)
		damaged.world.merge(changes,true)
		check(Replay.decode_frame(_frame(damaged,world.time),world).is_empty(),
			"录像拒绝非法供牌模式/类型/余量，损坏字段="+str(changes))
	host.free()

func _forks_preserve_composition_without_private_order() -> void:
	var source := _world({"employee":4,"coffee":3,"strike":2},771,2)
	source._new_offer()
	var before := var_to_bytes([source._supply_bag,source._rng.state,source._supply_bag_signature,source._supply_count])
	var reordered := _clone_exact(source)
	reordered._supply_bag.sort()
	if reordered._supply_bag == source._supply_bag:
		reordered._supply_bag.reverse()
	check(reordered._supply_bag != source._supply_bag, "隐私夹具确实改变真人隐藏袋排列")
	reordered._rng.state = source._rng.state ^ 92731
	var first := source.fork_for_bot(104729)
	var same_public := reordered.fork_for_bot(104729)
	check(first._supply_bag == same_public._supply_bag and first._rng.state == same_public._rng.state,
		"同公开剩余组成与scenario seed下，改变真人隐藏顺序/RNG不影响假设袋")
	check(_counts(first._supply_bag) == _counts(source._supply_bag), "假设分支保留当前袋已公开消耗后的精确剩余组成")
	check(first._supply_bag.size() == 6, "fork不会无视本袋已抽三张而重装九张整袋")
	check(_draw(first,24) == _draw(same_public,24), "真人隐藏剩余次序不能通过本袋或后续新袋泄漏到BOT")
	check(before == var_to_bytes([source._supply_bag,source._rng.state,source._supply_bag_signature,source._supply_count]),
		"创建和推进假设分支不消耗真人袋或随机流")
	var orders := {}
	for scenario_seed in [11,23,47,101]:
		var branch := source.fork_for_bot(scenario_seed)
		orders[str(branch._supply_bag)] = true
		check(_counts(branch._supply_bag) == _counts(source._supply_bag), "不同scenario只改变排列，不改变公开余量")
	check(orders.size() > 1, "不同假设seed能采样不同剩余排列")
	var isolated := source.fork_for_bot(73,true)
	check(_counts(isolated._supply_bag) == _counts(source._supply_bag) and isolated.config != source.config,
		"隔离配置分支同样遵守剩余袋组成")

func _hypothetical_child_continuity() -> void:
	var source := _world({"employee":4,"coffee":3,"strike":2},771,2)
	var hypothetical := source.fork_for_bot(313)
	_draw(hypothetical,2)
	var child := hypothetical.fork_search_node()
	check(child._supply_bag == hypothetical._supply_bag and child._rng.state == hypothetical._rng.state,
		"搜索子节点保留父节点自己的假设剩余次序与RNG位置")
	check(_draw(child,30) == _draw(hypothetical,30), "子分支跨多个新袋继续与父假设世界相同，不重新洗当前袋")

func _recorded_live_branch_privacy() -> void:
	var source := _world({"employee":4,"coffee":4,"strike":4},9137,2)
	source._supply_bag.sort()
	var changed := _clone_exact(source)
	changed._supply_bag.reverse()
	changed._rng.state = source._rng.state ^ 7131
	check(changed._supply_bag != source._supply_bag, "录像后台隐私夹具确实具有不同隐藏次序")
	var source_before := var_to_bytes([source._supply_bag,source._rng.state,source.offers])
	var jobs := []
	for observation in [source,changed]:
		var host := TestHost.new()
		host.state = observation
		host.replay.record(host,[],true)
		var job := Live.Search.new()
		job.world = OffWorkState.new(observation.config)
		job.world._bot_branch = true
		job.world._rng.seed = 104729
		job.frame = host.replay.frames[0]
		job.visible_offer_end = observation._next_offer
		job.visible_card_end = observation._next_card
		job.visible_group_end = observation._next_group
		job.due = observation.time+2.25
		job.deadline = Time.get_ticks_usec()+1000000
		job.worker = OffWorkBot.new(job.world,1,{"decision_budget_ms":1},318)
		job.run()
		check(is_equal_approx(job.world.time,job.due), "真实frozen-frame入口先解码再预测到行动点")
		var packet: Dictionary = job.latest()
		check(not packet.is_empty() and Time.get_ticks_usec() < job.deadline, "1ms紧急worker在后台硬截止之前发布首步")
		if not packet.is_empty(): check(job.uses_observed_entities(packet.action), "录像后台发布首步只引用初始已观察实体")
		check(job.world.offers.all(func(offer): return offer.is_empty() or int(offer.id) < job.visible_offer_end),
			"后台预测出的未来报价仍被遮蔽")
		jobs.append(job)
		host.free()
	check(jobs[0].world._supply_bag == jobs[1].world._supply_bag and jobs[0].world._rng.state == jobs[1].world._rng.state,
		"改变录像真实余袋排列及私有RNG不改变后台预测后的假设余袋")
	check(_draw(jobs[0].world,24) == _draw(jobs[1].world,24), "frozen-frame路径的后续供牌不泄露真人未见次序")
	check(source_before == var_to_bytes([source._supply_bag,source._rng.state,source.offers]),
		"录像后台预测不消费源观察的余袋、报价或随机流")
	var expired := Live.Search.new()
	expired.deadline = Time.get_ticks_usec()-1
	expired.run()
	check(expired.latest().is_empty(), "已经过期的后台任务不解码或发布任何结果")

func _session_roundtrip_and_legacy_migration() -> void:
	var host := TestHost.new()
	host.state = _world({"employee":4,"coffee":3,"strike":2},201,2)
	host.state.advance(2.5)
	host.bot = OffWorkBot.new(host.state,1)
	check(Session.save_session(host), "真实Session入口保存半袋局面")
	var bytes := FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK))
	var restored := TestHost.new()
	var saved: Dictionary = Session.read_session(restored)
	if need(not saved.is_empty(), "真实Session入口恢复半袋局面"):
		check(_draw(restored.state,30) == _draw(_clone_exact(host.state),30), "存档恢复后当前袋及后续新袋序列完全连续")
		check(FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK)) == bytes, "只读恢复不重写原存档")
	var legacy: Dictionary = Slots.load_slot(Slots.OFF_WORK)
	for key in BAG_FIELDS: legacy.world.erase(key)
	check(Slots.save(Slots.OFF_WORK,legacy), "写入不含新袋字段的旧存档夹具")
	var old := TestHost.new()
	var loaded: Dictionary = Session.read_session(old)
	if need(not loaded.is_empty(), "旧存档缺少新字段时仍可恢复"):
		check(old.state._supply_mode == "weighted_v0", "旧存档继续按次独立抽样，不能悄悄切新袋")
		_assert_legacy_sequence(old.state,"旧存档")
		old.state.new_game(201)
		check(old.state._supply_mode == "shuffle_bag_v1", "旧存档另开新局时切换整袋机制")
	host.free(); restored.free(); old.free()

func _replay_midframe_continuity() -> void:
	var host := TestHost.new()
	host.state = _world({"employee":4,"coffee":3,"strike":2},841,2)
	host.state.advance(2.5)
	host.replay.record(host,[],true)
	var midpoint := _clone_exact(host.state)
	host.state.advance(20.0)
	host.replay.record(host,[],true)
	var viewer := TestHost.new()
	var json_document: Dictionary = JSON.parse_string(JSON.stringify(host.state.config.balance_document()))
	viewer.state = OffWorkState.new(OffWorkConfig.new(json_document))
	check(viewer.state._supply_signature() == host.state._supply_signature(),
		"整数配额经录像JSON变成数值类型后仍具有同一规范池签名")
	var replay := Replay.new()
	replay.playing = true
	replay.playback = JSON.parse_string(JSON.stringify(host.replay.frames))
	replay.clock = 2.5
	replay.advance(viewer,11.25)
	midpoint.advance(11.25)
	check(viewer.state.offers == midpoint.offers and viewer.state._supply_bag == midpoint._supply_bag
		and viewer.state._rng.state == midpoint._rng.state, "录像从半袋关键帧推进跨袋，真实市场与余袋/RNG逐项连续")
	check(_draw(viewer.state,24) == _draw(midpoint,24), "录像帧间续抽后续整袋也不漂移")
	host.free(); viewer.free()

func _legacy_replay_sampling() -> void:
	var host := TestHost.new()
	host.state = _world()
	host.state.advance(1.5)
	host.replay.record(host,[],true)
	var raw: Dictionary = Replay.decode_frame(host.replay.frames[0],host.state)
	for key in BAG_FIELDS: raw.world.erase(key)
	var legacy := _frame(raw,host.state.time)
	var view := OffWorkState.new(host.state.config)
	var migrated: Dictionary = Replay.decode_frame(legacy,view)
	if need(not migrated.is_empty(), "旧录像不含新袋字段的帧仍可解码"):
		for key in Session.STATE_FIELDS: view.set(key,migrated.world[key])
		view._rng.state = migrated.rng
		check(view._supply_mode == "weighted_v0", "旧录像保留原独立加权抽样模式")
		_assert_legacy_sequence(view,"旧录像")
	host.free()

func _assert_legacy_sequence(world: OffWorkState, label: String) -> void:
	var reference_rng := RandomNumberGenerator.new()
	reference_rng.state = world._rng.state
	var probabilities: Dictionary = world.config.conveyor_probabilities()
	var expected := []
	for index in 30:
		var choice := reference_rng.randf()
		var selected := ""
		for kind in probabilities:
			var chance := float(probabilities[kind])
			if chance <= 0.0: continue
			selected = str(kind)
			choice -= chance
			if choice <= 0.0: break
		expected.append(selected)
	check(_types(_draw(world,30)) == expected and world._rng.state == reference_rng.state,
		label+"迁移后逐张复现旧randf累计概率算法及随机流位置")
