# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Replay = preload("res://engine/off_work_replay.gd")
const Session = preload("res://engine/off_work_session.gd")
const ProgressClock = preload("res://engine/off_work_progress_clock.gd")

func _initialize() -> void:
	_configuration()
	_instant_activation()
	_queue_and_shortage()
	_retired_tier_durations()
	_rejected_and_paused()
	_positive_duration()
	_snapshot_and_branch()
	finish()

func _state(seconds := 0.0, staff := {"employee": 1}) -> OffWorkState:
	var cfg := OffWorkConfig.new()
	cfg.rules.coffee.seconds = seconds
	cfg.rules.initial.groups = [staff.duplicate(), {"work": 200}]
	cfg.rules.initial.money = 0
	cfg.rules.bot.enabled = false
	var result := OffWorkState.new(cfg)
	result.new_game(20261113)
	result.drain_events()
	return result

func _ids(s: OffWorkState, kind: String, owner := 0) -> Array:
	return s.cards.keys().filter(func(uid): return s.cards[uid].type == kind and int(s.cards[uid].owner) == owner)

func _cups(s: OffWorkState, count: int, group := -1, owner := 0) -> Array:
	if group < 0: group = s.create_group(owner)
	var result := []
	for _i in count: result.append(s.add_card("coffee", owner, group))
	return result

func _coffee_events(s: OffWorkState) -> Array:
	return s.drain_events().filter(func(event): return event.kind in ["coffee_start", "coffee_upgrade"])

func _finite(value: Variant) -> bool:
	if value is float: return is_finite(value)
	if value is Dictionary:
		for entry in value.values():
			if not _finite(entry): return false
	if value is Array:
		for entry in value:
			if not _finite(entry): return false
	return true

func _safe(s: OffWorkState, label: String) -> void:
	check(s.tasks.values().all(func(task): return task.kind != "coffee" or float(task.total) > 0.0), label + "：无存活的 0 秒任务")
	check(_finite(s.cards) and _finite(s.tasks) and _finite(s.groups), label + "：状态及可见进度均为有限值")

func _configuration() -> void:
	var defaults := OffWorkConfig.new()
	check(defaults.number("coffee", "seconds") == 1.0 and defaults.number("slack", "seconds") == 14.0,
		"项目默认每批升级为 1 秒，生产咖啡仍为 14 秒")
	var cfg := OffWorkConfig.new()
	cfg.rules.coffee.seconds = 0.0
	check(cfg.validate() and cfg.coffee_batch_seconds() == 0.0 and cfg.coffee_seconds("workaholic") == 0.0, "共享真实 0 秒合法，兼容入口与批次入口一致")
	cfg = OffWorkConfig.new()
	cfg.rules.coffee.upgrades.grinder.seconds = 0.0
	check(cfg.validate() and cfg.coffee_seconds("grinder") == 1.0 and cfg.coffee_seconds("employee") == 1.0,
		"运行时遗留逐级 0 秒覆盖不再影响共享批次耗时")
	# The GDScript numeric parser rounds tiny decimal literals to zero; build
	# an actual positive subnormal to exercise reciprocal overflow instead.
	var tiny := PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0]).decode_double(0)
	check(tiny > 0.0, "溢出夹具是实际非零双精度数，不是被解析成 0 的字面量")
	for value in [-1.0, INF, NAN, tiny]:
		cfg = OffWorkConfig.new()
		cfg.rules.coffee.seconds = value
		check(not cfg.validate(), "共享耗时拒绝负值、非有限值及正速率溢出：%s" % value)
		var legacy := OffWorkConfig.new().balance_document()
		legacy.rules.coffee.upgrades.grinder.seconds = value
		legacy.rules.coffee.upgrades.employee.seconds = 0.0
		var original := var_to_bytes(legacy)
		var migrated := OffWorkConfig.new(legacy)
		check(migrated.errors.is_empty() and migrated.coffee_batch_seconds() == 1.0
			and migrated.coffee_seconds("grinder") == 1.0
			and not migrated.rules.coffee.upgrades.grinder.has("seconds")
			and not migrated.rules.coffee.upgrades.employee.has("seconds"),
			"读取旧卡表移除逐级耗时，仅保留共享批次时长：%s" % value)
		check(original == var_to_bytes(legacy), "旧耗时迁移仅改读取副本，原归档保持不变")
		check(migrated.rules.coffee.upgrades.grinder.cost == legacy.rules.coffee.upgrades.grinder.cost
			and migrated.rules.coffee.upgrades.grinder.to == legacy.rules.coffee.upgrades.grinder.to,
			"废弃逐级耗时不改变逐级材料用量或升级目标")
	cfg = OffWorkConfig.new()
	cfg.rules.coffee.seconds = 0.000001
	check(cfg.validate(), "可表示的极小正时长保持合法，不被当作 0 秒")
	cfg.rules.slack.seconds = 0.0
	check(not cfg.validate(), "允许即时升级不改变咖啡生产必须耗时的规则")

func _instant_activation() -> void:
	var s := _state()
	var person: int = _ids(s, "employee")[0]
	var group: int = s.cards[person].group
	# Eight cups also test that the final unaffordable/no-next-tier attempt
	# cannot replace the successful public activation's empty last_error.
	var cups := _cups(s, 8, group)
	var clock := s.time
	var rng_state := s._rng.state
	var offers := s.offers.duplicate(true)
	check(s.activate(int(cups[0]), group, person), "直接使用咖啡成功")
	check(s.cards[person].type == "work_emperor" and _ids(s, "coffee") == [cups[7]],
		"同一批合计消耗 1+2+4 杯直接升到卷帝，恰好留下第八杯")
	check(s.last_error.is_empty(), "后续无可升级人员不会污染首次成功命令")
	check(s.time == clock and s._rng.state == rng_state and s.offers == offers,
		"即时升级不推进世界时间、随机数或购牌轮询")
	var events := _coffee_events(s)
	check(events.map(func(event): return event.kind) == ["coffee_start", "coffee_upgrade"],
		"跨级整批只产生一次开始与一次最终完成事件")
	check(events.all(func(event): return event.time == clock) and events.filter(func(event): return event.kind == "coffee_upgrade").map(func(event): return event.amount) == [7],
		"批次完成时间不推进，单次最终事件记录全部七杯消耗")
	check(s.cards[person].activity == "idle" and s.cards[person].progress == 0.0 and ProgressClock.remaining(s, person, "coffee", 0.0) < 0.0,
		"即时结束后人员不残留喝咖啡进度条或倒计时")
	_safe(s, "直接即时升级")

func _queue_and_shortage() -> void:
	var s := _state(0.0, {"employee": 2, "grinder": 1, "workaholic": 1})
	var people := _ids(s, "employee")
	var grinder: int = _ids(s, "grinder")[0]
	var high: int = _ids(s, "workaholic")[0]
	var group: int = s.cards[high].group
	check(s.move_cards(_cups(s, 8), group) == group, "拖动整摞咖啡在移牌命令内立即结算")
	var events := _coffee_events(s).filter(func(event): return event.kind == "coffee_upgrade")
	check(events.map(func(event): return event.person) == [high, grinder, people[0], people[1]] and events.map(func(event): return event.amount) == [4, 2, 1, 1],
		"多名不同等级人员仍按最高可支付等级及组内稳定顺序升级")
	check(_ids(s, "coffee").is_empty() and s.tasks.is_empty() and s.time == 0.0, "整批同时完成且不虚增材料、时钟或任务")
	_safe(s, "多人混合等级")
	var short := _state(0.0, {"grinder": 1})
	var worker: int = _ids(short, "grinder")[0]
	var team: int = short.cards[worker].group
	var cup: int = _cups(short, 1, team)[0]
	check(not short.activate(cup, team) and short.cards.has(cup) and short.cards[worker].type == "grinder", "不足两杯时仍拒绝升级且不消费材料")
	check(short.move_cards(_cups(short, 1), team) == team and short.cards[worker].type == "workaholic" and _ids(short, "coffee").is_empty(),
		"补足材料的同一命令立即完成整批，不等下一帧")
	# A large instant batch must finish without a recursive per-tier drain.
	var large := _state(0.0, {"employee": 96})
	var workers := _ids(large, "employee")
	var destination: int = large.cards[workers[0]].group
	large.move_cards(_cups(large, workers.size() * 7), destination)
	check(workers.all(func(uid): return large.cards[uid].type == "work_emperor") and _ids(large, "coffee").is_empty(),
		"96 人各跨三级的整批升级一次完成，不受递归深度或逐帧限制")
	_safe(large, "大队列")

func _retired_tier_durations() -> void:
	var s := _state()
	s.config.rules.coffee.upgrades.employee.seconds = 2.0
	s.config.rules.coffee.upgrades.grinder.seconds = 3.0
	s.config.rules.coffee.upgrades.workaholic.seconds = 4.0
	var person: int = _ids(s, "employee")[0]
	var group: int = s.cards[person].group
	s.move_cards(_cups(s, 7), group)
	check(s.cards[person].type == "work_emperor" and _ids(s, "coffee").is_empty() and not s.tasks.has(person),
		"共享 0 秒时旧逐级正时长不再把同批升级拆成阶段")
	var instant := _coffee_events(s).filter(func(event): return event.kind == "coffee_upgrade")
	check(instant.size() == 1 and instant[0].time == 0.0 and instant[0].amount == 7,
		"废弃覆盖不额外生成中间等级事件")
	_safe(s, "共享 0 秒忽略旧覆盖")
	var coarse := _state(5.0)
	var fine := _state(5.0)
	for world in [coarse, fine]:
		world.config.rules.coffee.upgrades.employee.seconds = 0.0
		world.config.rules.coffee.upgrades.grinder.seconds = 20.0
		world.config.rules.coffee.upgrades.workaholic.seconds = 0.0
		var employee: int = _ids(world, "employee")[0]
		world.move_cards(_cups(world, 7), int(world.cards[employee].group))
		check(world.cards[employee].type == "employee" and world.tasks[employee].to_type == "work_emperor"
			and world.tasks[employee].total == 5.0 and _ids(world, "coffee").size() == 7,
			"共享 5 秒预定最终等级，旧逐级零秒和正时长都不提前改变原人员")
	coarse.advance(5.0)
	for _i in 50: fine.advance(0.1)
	for world in [coarse, fine]:
		check(_ids(world, "work_emperor").size() == 1 and _ids(world, "coffee").is_empty(), "共享 5 秒批次在粗细时钟下都完整升级")
		var completed := _coffee_events(world).filter(func(event): return event.kind == "coffee_upgrade")
		check(completed.size() == 1 and is_equal_approx(completed[0].time, 5.0) and completed[0].amount == 7,
			"正时长跨级批次在原 5 秒边界只产生一个最终完成事件")
		_safe(world, "共享 5 秒忽略逐级覆盖")

func _rejected_and_paused() -> void:
	var s := _state()
	var worker: int = _ids(s, "employee")[0]
	var work: int = _ids(s, "work")[0]
	var group: int = s.cards[work].group
	s.move_cards([worker], group)
	var cup: int = _cups(s, 1, group)[0]
	check(not s.activate(cup, group, worker) and s.cards[worker].type == "employee" and s.cards.has(cup),
		"即时升级仍拒绝有工作牌的组，不绕过组合规则")
	var paused := _state()
	worker = _ids(paused, "employee")[0]
	group = paused.cards[worker].group
	var leader := paused.add_card("leader", 1)
	var meeting := paused.add_card("meeting", 1, int(paused.cards[leader].group))
	check(paused.activate(meeting) and paused.is_meeting_target(worker), "真实对方会议暂停待升级人员")
	cup = _cups(paused, 1, group)[0]
	check(not paused.activate(cup, group, worker) and paused.cards.has(cup) and paused.cards[worker].type == "employee",
		"被会议暂停的人员不能用 0 秒升级穿过暂停")
	paused.advance(paused.config.number("meeting", "duration_seconds"))
	check(paused.cards[worker].type == "grinder" and not paused.cards.has(cup) and not paused.tasks.has(worker),
		"会议结束的同一时刻，合法队列立即完成升级")
	_safe(paused, "会议恢复")
	var striking := _state()
	worker = _ids(striking, "employee")[0]
	group = striking.cards[worker].group
	striking.cards[worker].status = "striking"
	cup = _cups(striking, 1, group)[0]
	check(not striking.activate(cup, group, worker) and striking.cards.has(cup), "罢工状态同样不能立即升级")

func _positive_duration() -> void:
	for seconds in [5.0, 0.000001]:
		var s := _state(seconds)
		var person: int = _ids(s, "employee")[0]
		var group: int = s.cards[person].group
		var cup: int = _cups(s, 1, group)[0]
		check(s.activate(cup, group) and s.cards[person].type == "employee" and s.cards.has(cup) and s.tasks[person].total == seconds,
			"任何正时长（包括小值）仍创建真实任务，不被 epsilon 变成即时升级")
		check(_coffee_events(s).map(func(event): return event.kind) == ["coffee_start"], "正时长激活只发原开始事件")
		s.advance(seconds)
		var events := _coffee_events(s)
		check(s.cards[person].type == "grinder" and not s.cards.has(cup) and events.size() == 1 and events[0].kind == "coffee_upgrade" and is_equal_approx(events[0].time, seconds),
			"正时长仅在原截止时间消费一杯并完成一级")
		_safe(s, "正时长保持")

func _snapshot_and_branch() -> void:
	var live := _state()
	var person: int = _ids(live, "employee")[0]
	var group: int = live.cards[person].group
	var cups := _cups(live, 7)
	var branch := live.fork_for_bot(177)
	var rng_state := branch._rng.state
	branch.move_cards(cups, group)
	check(branch.cards[person].type == "work_emperor" and branch._rng.state == rng_state and branch.time == live.time,
		"搜索分支使用同一即时规则，不推进抽牌随机数或时钟")
	check(live.cards[person].type == "employee" and cups.all(func(uid): return live.cards.has(uid)), "分支结算不影响真实世界的人员和材料")
	live.move_cards(cups, group)
	var document: Dictionary = JSON.parse_string(JSON.stringify(live.config.balance_document()))
	var loaded := OffWorkConfig.new(document)
	check(loaded.errors.is_empty() and loaded.coffee_seconds("employee") == 0.0, "录像卡表经 JSON 往返仍合法保留精确 0 秒")
	var world := {}
	for key in Session.STATE_FIELDS: world[key] = live.get(key)
	var layout := {}
	for key in Session.BOARD_FIELDS: layout[key] = {}
	var entry := {"world": world, "rng": live._rng.state, "layout": layout, "events": live.drain_events()}
	var payload := var_to_bytes(entry)
	var frame := {"t": live.time, "size": payload.size(), "data": Marshalls.raw_to_base64(payload.compress(FileAccess.COMPRESSION_ZSTD))}
	var decoded := Replay.decode_frame(frame, OffWorkState.new(loaded))
	check(not decoded.is_empty() and decoded.world.cards[person].type == "work_emperor" and decoded.world.tasks.is_empty(),
		"原录像编码格式可读取即时升级后世界，不包含未完成 0 秒任务")
	check(not decoded.is_empty() and decoded.events.filter(func(event): return event.kind == "coffee_upgrade").size() == 1,
		"录像帧保留跨越三级的单个最终升级事件")
	_safe(live, "录像后世界")
