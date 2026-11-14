# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Session = preload("res://engine/off_work_session.gd")
const Slots = preload("res://engine/shift_slot.gd")
const Replay = preload("res://engine/off_work_replay.gd")

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

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	OS.set_environment("CARD_DATA_DIR", OS.get_cache_dir().path_join("niuma-tests/coffee-batches-%d" % OS.get_process_id()))
	_configuration()
	_one_person_full_recipe()
	_allocation_and_shared_clock()
	_late_materials()
	_late_personnel()
	_cancel_and_move()
	_merge_running_batches()
	_zero_and_configured_duration()
	_clock_steps()
	_fork_session_and_replay()
	_legacy_single_stage()
	for failure in failures: printerr("FAIL ", failure)
	print("OFF_WORK_COFFEE_BATCHES: %d 通过 / %d 失败" % [checks - failures.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _world(seconds := 1.0) -> OffWorkState:
	var cfg := OffWorkConfig.new()
	cfg.rules.initial.groups = [{"work": 100}, {"leader": 1}]
	cfg.rules.initial.money = 0
	cfg.rules.bot.enabled = false
	cfg.rules.coffee.seconds = seconds
	cfg.rules.conveyor.interval_seconds = 1000.0
	var s := OffWorkState.new(cfg)
	s.new_game(20261115)
	check(s.config.errors.is_empty() and s.work_count(0) == 100, "咖啡夹具满足真实开局配置要求")
	s.drain_events()
	return s

func _cups(s: OffWorkState, count: int) -> Array:
	var group := s.create_group(0)
	var cups: Array = []
	for _i in count: cups.append(s.add_card("coffee", 0, group))
	return cups

func _batch(kinds: Array, count: int, seconds := 1.0) -> Dictionary:
	var s := _world(seconds)
	var group := s.create_group(0)
	var people: Array = []
	for kind in kinds: people.append(s.add_card(str(kind), 0, group))
	var cups := _cups(s, count)
	check(s.move_cards(cups, group) == group, "真实拖入全部咖啡开启一批升级")
	return {"world":s, "group":group, "people":people, "cups":cups}

func _events(s: OffWorkState) -> Array:
	return s.drain_events().filter(func(event): return event.kind == "coffee_upgrade")

func _configuration() -> void:
	var defaults := OffWorkConfig.new()
	check(defaults.number("coffee", "seconds") == 1.0 and defaults.coffee_batch_seconds() == 1.0, "默认统一每批升级耗时1秒")
	var document := defaults.balance_document()
	document.rules.coffee.seconds = 2.5
	document.rules.coffee.upgrades.employee.seconds = 9.0
	document.rules.coffee.upgrades.grinder.seconds = 0.0
	var before := var_to_bytes(document)
	var loaded := OffWorkConfig.new(document)
	check(loaded.errors.is_empty() and var_to_bytes(document) == before, "载入旧逐级耗时配置不修改调用方文档")
	check(loaded.rules.coffee.upgrades.values().all(func(recipe): return not recipe.has("seconds")), "规范配置删除旧逐级耗时字段")
	for kind in ["employee", "grinder", "workaholic"]:
		check(loaded.coffee_seconds(kind) == 2.5 and loaded.coffee_batch_seconds() == 2.5, "所有等级兼容接口都读取同一每批耗时")
	loaded.rules.coffee.seconds = 0.0
	check(loaded.validate() and loaded.coffee_batch_seconds() == 0.0, "每批0秒仍是合法即时结算")

func _one_person_full_recipe() -> void:
	var row := _batch(["employee"], 8)
	var s: OffWorkState = row.world
	var person: int = row.people[0]
	var task: Dictionary = s.tasks[person]
	check(task.from_type == "employee" and task.to_type == "work_emperor" and task.coffee_ids.size() == 7, "开轮预计算员工7杯直达最高级并冻结累计配额")
	check(task.batch_owner == person and task.batch_members == [person] and task.total == 1.0, "单人多级只读一轮1秒进度")
	check(s.cards[person].type == "employee" and row.cups.all(func(id): return s.cards.has(id)), "开轮只预留材料，不提前改等级或消耗咖啡")
	s.advance(0.5)
	check(s.cards[person].type == "employee" and is_equal_approx(s.cards[person].progress, 0.5), "半轮时仍保留原等级并显示共享半程进度")
	check(task.coffee_ids.all(func(id): return s.cards[id].status == "active" and is_equal_approx(s.cards[id].progress, 0.5)), "全部累计配额材料显示同一进度")
	s.advance(0.499)
	check(s.cards[person].type == "employee" and row.cups.all(func(id): return s.cards.has(id)), "截止前不产生中间等级或提前消耗")
	s.advance(0.001)
	check(s.cards[person].type == "work_emperor" and s._owner_type(0, "coffee").size() == 1 and not s.tasks.has(person), "一轮结束同时达到最高级并仅消耗7杯")
	var events := _events(s)
	check(events.size() == 1 and events[0].from_type == "employee" and events[0].to_type == "work_emperor" and events[0].amount == 7, "单人多级只在最终结算发一次真实升级事件")

func _allocation_and_shared_clock() -> void:
	var row := _batch(["employee", "employee", "employee"], 4, 2.0)
	var s: OffWorkState = row.world
	var people: Array = row.people
	check(s.tasks[people[0]].to_type == "workaholic" and s.tasks[people[0]].coffee_ids.size() == 3, "同级按组顺序先选第一人，虚拟升级后继续优先最高可升级等级")
	check(s.tasks[people[1]].to_type == "grinder" and s.tasks[people[1]].coffee_ids.size() == 1 and not s.tasks.has(people[2]), "剩余1杯分给第二人，不虚构第三人升级")
	var owner: int = s.tasks[people[0]].batch_owner
	check(s.tasks[people[1]].batch_owner == owner and not s.tasks[people[1]].has("batch_members")
		and s.tasks[owner].batch_members == s._coffee_batch_members(people[1], s.tasks[people[1]]), "所有获配人员引用同一个批次owner和唯一成员表")
	s.advance(1.0)
	check(people.all(func(id): return s.cards[id].type == "employee"), "多人员批次中途无人提前升级")
	check([people[0], people[1]].all(func(id): return is_equal_approx(s.cards[id].progress, 0.5)), "两名获配人员在2秒批次中共享半程进度")
	s.advance(1.0)
	check(s.cards[people[0]].type == "workaholic" and s.cards[people[1]].type == "grinder" and s.cards[people[2]].type == "employee", "所有获配结果同一时刻结算，不按人数和级数累加")
	var events := _events(s)
	check(events.size() == 2 and events.all(func(event): return is_equal_approx(event.time, 2.0)) and s._owner_type(0, "coffee").is_empty(), "两人结算时间一致且4杯只消耗一次")
	var mixed := _batch(["employee", "grinder", "workaholic"], 7)
	var ms: OffWorkState = mixed.world
	check(ms.tasks[mixed.people[2]].to_type == "work_emperor" and ms.tasks[mixed.people[2]].coffee_ids.size() == 4, "混合等级优先为原肝帝分配4杯")
	check(ms.tasks[mixed.people[1]].to_type == "workaholic" and ms.tasks[mixed.people[1]].coffee_ids.size() == 2 and ms.tasks[mixed.people[0]].coffee_ids.size() == 1, "剩余预算沿原最高可升级优先规则分给卷王和员工")
	ms.advance(1.0)
	check(mixed.people.map(func(id): return ms.cards[id].type) == ["grinder", "workaholic", "work_emperor"], "混合等级三人一轮同时兑现预分配结果")

func _late_materials() -> void:
	var row := _batch(["employee"], 1)
	var s: OffWorkState = row.world
	var person: int = row.people[0]
	s.advance(0.4)
	var frozen: Dictionary = s.tasks[person].duplicate(true)
	var late := _cups(s, 6)
	s.move_cards(late, row.group)
	check(s.tasks[person].to_type == "grinder" and s.tasks[person].coffee_ids == frozen.coffee_ids and is_equal_approx(s.tasks[person].progress, 0.4), "中途6杯不扩展或重置已冻结的一杯批次")
	check(late.all(func(id): return s.cards[id].status == "ready"), "中途咖啡保持未预留直到下一轮")
	s.advance(0.6)
	check(s.cards[person].type == "grinder" and s.tasks[person].to_type == "work_emperor" and s.tasks[person].coffee_ids.size() == 6 and is_zero_approx(s.tasks[person].progress), "原轮完成后才用迟到咖啡开启新的一整轮")
	s.advance(0.999)
	check(s.cards[person].type == "grinder", "下一轮同样必须完整读条")
	s.advance(0.001)
	check(s.cards[person].type == "work_emperor" and s._owner_type(0, "coffee").is_empty(), "迟到材料在第二轮统一结算")

func _late_personnel() -> void:
	var row := _batch(["employee"], 1)
	var s: OffWorkState = row.world
	var first: int = row.people[0]
	s.advance(0.4)
	var late := s.add_card("employee", 0)
	var cups := _cups(s, 1)
	s.move_cards([late] + cups, row.group)
	check(not s.tasks.has(late) and s.tasks[first].batch_members == [first] and s.tasks[first].coffee_ids == row.cups, "中途新人员不进入原轮成员和配额")
	s.advance(0.6)
	check(s.cards[first].type == "grinder" and s.cards[late].type == "employee" and s.tasks[late].batch_members == [late] and is_zero_approx(s.tasks[late].progress), "第一轮结束后新人员才按剩余资源开轮")
	s.advance(1.0)
	check(s.cards[late].type == "grinder" and s._owner_type(0, "coffee").is_empty(), "迟到人员在自己的下一轮升级")

func _cancel_and_move() -> void:
	var row := _batch(["employee", "employee"], 2, 2.0)
	var s: OffWorkState = row.world
	s.advance(0.5)
	var batch: Array = row.people + row.cups
	var destination := s.create_group(0)
	check(s.move_cards(batch, destination) == destination, "完整本批人员和所有预留材料可一起换组")
	check(row.people.all(func(id): return s.tasks[id].group == destination and is_equal_approx(s._task_progress(int(id)), 0.25) and is_equal_approx(s.cards[id].progress, 0.25)), "完整批次搬组保留共享进度")
	s.advance(0.5)
	s.move_cards([row.people[0]], -1)
	check(row.people.all(func(id): return s.cards[id].type == "employee") and row.cups.all(func(id): return s.cards.has(id)), "移走一名批次成员取消整批，不提前结算任何人或材料")
	check(not s.tasks.has(row.people[0]) and s.tasks[row.people[1]].batch_members == [row.people[1]] and is_zero_approx(s.tasks[row.people[1]].progress), "剩余成员只能以释放后的资源从零开新轮")
	var release := _batch(["employee", "employee"], 2, 2.0)
	var rs: OffWorkState = release.world
	rs.advance(0.5)
	rs.move_cards(release.cups, -1)
	check(release.people.all(func(id): return not rs.tasks.has(id) and rs.cards[id].type == "employee"), "移走预留咖啡取消整批成员任务")
	check(release.cups.all(func(id): return rs.cards[id].status == "ready" and is_zero_approx(rs.cards[id].progress)), "取消批次释放全部预留材料并清空进度")
	rs.advance(5.0)
	check(release.cups.all(func(id): return rs.cards.has(id)) and _events(rs).is_empty(), "取消的批次没有延迟结算或重复消费")

func _merge_running_batches() -> void:
	var row := _batch(["employee"], 1, 2.0)
	var s: OffWorkState = row.world
	var first: int = row.people[0]
	s.advance(0.4)
	var second := s.add_card("employee", 0)
	var cups := _cups(s, 1)
	s.move_cards(cups, s.cards[second].group)
	s.advance(0.4)
	check(s.move_cards([second] + cups, row.group) == row.group, "两个进行中的批次可按真实拖动合组")
	check(s.tasks[first].batch_members == [first] and is_equal_approx(s.tasks[first].progress, 0.4), "合组保留目标组原批次进度和成员")
	check(not s.tasks.has(second) and s.cards[cups[0]].status == "ready", "被搬入批次取消并释放材料，等待目标组下一轮")
	s.advance(1.2)
	check(s.cards[first].type == "grinder" and s.cards[second].type == "employee" and is_zero_approx(s.tasks[second].progress), "原目标批次先完成，后来成员从下一轮零进度开始")
	s.advance(2.0)
	check(s.cards[second].type == "grinder" and s._owner_type(0, "coffee").is_empty(), "合组两轮分别消费各自一杯且不提前升级")

func _zero_and_configured_duration() -> void:
	var instant := _batch(["employee", "employee"], 14, 0.0)
	var s: OffWorkState = instant.world
	check(instant.people.all(func(id): return s.cards[id].type == "work_emperor") and s._owner_type(0, "coffee").is_empty(), "0秒一次完成多人全级批次并消费14杯")
	check(s.tasks.values().all(func(task): return task.kind != "coffee") and is_zero_approx(s.time), "即时批次不留下零时长任务也不推进时钟")
	check(_events(s).size() == 2, "即时多人批次每人仅一次最终结算")
	var custom := _batch(["employee", "employee"], 14, 3.0)
	var cs: OffWorkState = custom.world
	cs.advance(2.999)
	check(custom.people.all(func(id): return cs.cards[id].type == "employee"), "自定义3秒批次截止前全部保持原等级")
	cs.advance(0.001)
	check(custom.people.all(func(id): return cs.cards[id].type == "work_emperor") and cs.time == 3.0, "两人共六级升级仍只花配置的3秒")

func _clock_steps() -> void:
	var coarse := _batch(["employee", "employee", "employee"], 4, 2.0)
	var fine := _batch(["employee", "employee", "employee"], 4, 2.0)
	coarse.world.advance(2.0)
	for _i in 20: fine.world.advance(0.1)
	check(coarse.people.map(func(id): return coarse.world.cards[id].type) == fine.people.map(func(id): return fine.world.cards[id].type), "粗细时钟获得相同多人最终等级")
	check(coarse.world._owner_type(0, "coffee") == fine.world._owner_type(0, "coffee"), "粗细时钟消费相同材料集合")
	var a := _events(coarse.world)
	var b := _events(fine.world)
	check(a.size() == b.size() and a.size() == 2, "粗细时钟每名获配成员恰好一次结算")
	for i in mini(a.size(), b.size()):
		check(a[i].person == b[i].person and a[i].to_type == b[i].to_type and a[i].coffee_ids == b[i].coffee_ids and is_equal_approx(a[i].time, b[i].time), "事件顺序、配额和结算时刻不依赖帧长")

func _fork_session_and_replay() -> void:
	var row := _batch(["employee", "employee"], 14, 2.0)
	var s: OffWorkState = row.world
	s.advance(0.75)
	var frozen := var_to_bytes(s.tasks)
	var branch := s.fork_for_bot(81)
	check(branch.tasks == s.tasks, "BOT复制完整保留冻结配额、批次成员和共享owner")
	branch.advance(1.25)
	check(row.people.all(func(id): return branch.cards[id].type == "work_emperor") and var_to_bytes(s.tasks) == frozen, "BOT分支完成全批而原场景进度不变")
	var host := TestHost.new()
	host.state = s
	host.bot = OffWorkBot.new(s, 1)
	check(Session.save_session(host), "真实存档入口保存进行中的多人批次")
	var loaded := TestHost.new()
	var saved := Session.read_session(loaded)
	check(not saved.is_empty() and loaded.state.tasks == s.tasks, "存档恢复原样保留每人最终等级及配额")
	if not saved.is_empty():
		loaded.state.advance(1.25)
		check(row.people.all(func(id): return loaded.state.cards[id].type == "work_emperor") and loaded.state._owner_type(0, "coffee").is_empty(), "存档恢复后只等待本轮剩余时间并统一消费")
	host.replay.record(host, [], true)
	var playback := OffWorkState.new(OffWorkConfig.new(s.config.balance_document()))
	var decoded := Replay.decode_frame(host.replay.frames[0], playback)
	check(not decoded.is_empty() and decoded.world.tasks == s.tasks, "真实录像关键帧完整保存进行中的批次任务")
	if not decoded.is_empty():
		for key in Session.STATE_FIELDS: playback.set(key, decoded.world[key])
		playback._rng.state = decoded.rng
		playback.advance(1.25)
		check(row.people.all(func(id): return playback.cards[id].type == "work_emperor") and playback._owner_type(0, "coffee").is_empty(), "录像关键帧按同一规则时钟恢复批次最终结果")
	check(var_to_bytes(s.tasks) == frozen, "存档与录像读取都没有修改原场景批次")
	host.free()
	loaded.free()

func _legacy_single_stage() -> void:
	var row := _batch(["employee"], 1, 5.0)
	var s: OffWorkState = row.world
	var person: int = row.people[0]
	s.advance(2.0)
	s.tasks[person].erase("batch_owner")
	s.tasks[person].erase("batch_members")
	s.config.rules.coffee.seconds = 1.0
	var extra := _cups(s, 6)
	s.move_cards(extra, row.group)
	check(not s.tasks[person].has("batch_owner") and s.tasks[person].to_type == "grinder" and s.tasks[person].total == 5.0, "旧无batch字段单阶段任务继续原目标和原5秒时长")
	s.advance(2.999)
	check(s.cards[person].type == "employee" and row.cups.all(func(id): return s.cards.has(id)), "旧任务不因新默认或额外材料提前完成")
	s.advance(0.001)
	check(s.cards[person].type == "grinder" and s.tasks[person].has("batch_owner") and s.tasks[person].to_type == "work_emperor" and s.tasks[person].total == 1.0, "旧单阶段完成后才用剩余材料切入新的1秒整批规则")
	s.advance(1.0)
	check(s.cards[person].type == "work_emperor" and s._owner_type(0, "coffee").is_empty(), "旧存档后续批次与新规则正常衔接")
