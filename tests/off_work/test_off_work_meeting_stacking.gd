# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_configuration_and_hosts()
	_stacked_tools()
	_host_changes()
	_tool_changes_and_relocation()
	_unique_targets_and_busy_hosts()
	_cooldown_cannot_be_bypassed()
	_clock_steps()
	_forks_and_legacy_snapshot()
	_legacy_parallel_meetings()
	for failure in failures: printerr("FAIL ", failure)
	print("OFF_WORK_MEETING_STACKING: %d 通过 / %d 失败" % [checks - failures.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _world() -> OffWorkState:
	var cfg := OffWorkConfig.new()
	# Keep the initial fixture valid without adding workers to any test group.
	# These separate leaders are immune to meetings and never process work.
	cfg.rules.initial.groups = [{"work": 100}, {"leader": 1}]
	cfg.rules.initial.money = 0
	cfg.rules.bot.enabled = false
	cfg.rules.conveyor.interval_seconds = 1000.0
	var s := OffWorkState.new(cfg)
	s.new_game(20261114)
	check(s.config.errors.is_empty() and s.work_count(0) == 100 and s.work_count(1) == 100, "会议夹具满足真实开局配置要求")
	s.drain_events()
	return s

func _scene(kinds: Array, tool_count := 1, target_count := 20) -> OffWorkState:
	var s := _world()
	var target_group := s.create_group(1)
	for _i in target_count: s.add_card("employee", 1, target_group)
	var group := s.create_group(0)
	for kind in kinds: s.add_card(str(kind), 0, group)
	var tools: Array = []
	for _i in tool_count: tools.append(s.add_card("meeting", 0, group))
	check(s.activate(int(tools[0]), group), "真实操作启动开会组合")
	return s

func _meeting(s: OffWorkState) -> Dictionary:
	check(s.meetings.size() == 1, "同一组合只存在一场会议")
	return s.meetings.values()[0] if not s.meetings.is_empty() else {}

func _tools(s: OffWorkState, owner := 0) -> Array:
	return s._owner_type(owner, "meeting")

func _progress(meeting: Dictionary) -> float:
	return 1.0 - float(meeting.remaining) / float(meeting.total)

func _configuration_and_hosts() -> void:
	var cfg := OffWorkConfig.new()
	for kind in ["employee", "grinder", "workaholic", "work_emperor"]:
		check(cfg.meeting_capacity(kind) == 2, "%s默认贡献2个名额" % kind)
	check(cfg.meeting_capacity("leader") == 4, "领导默认贡献4个名额")
	for count in [1, 2, 3]:
		check(is_equal_approx(cfg.meeting_duration(count), cfg.number("meeting", "duration_seconds") * pow(1.2, count - 1)), "%d张开会牌按1.2倍叠加时长" % count)
	for row in [
		{"kinds":["employee"], "capacity":2},
		{"kinds":["grinder"], "capacity":2},
		{"kinds":["workaholic"], "capacity":2},
		{"kinds":["work_emperor"], "capacity":2},
		{"kinds":["leader"], "capacity":4},
		{"kinds":["leader", "leader"], "capacity":8},
		{"kinds":["employee", "leader"], "capacity":6}]:
		var s := _scene(row.kinds)
		var meeting := _meeting(s)
		check(meeting.hosts.size() == row.kinds.size() and meeting.targets.size() == row.capacity, "所有在场主持容量相加：%s" % str(row.kinds))
		check(meeting.hosts.has(meeting.host), "保留host作为主持列表中的兼容代表")
		check(meeting.hosts.all(func(id): return s.tasks.has(id) and s.tasks[id].kind == "meeting"), "每名主持都实际占用会议任务")
		check(meeting.targets.all(func(id): return s.is_meeting_target(id) and s.cards[id].paused), "每个名额对应真实被暂停的对方人员")
	var limited := _scene(["leader", "leader"], 1, 3)
	check(_meeting(limited).targets.size() == 3, "可用人员不足时只召集真实存在的人员")

func _stacked_tools() -> void:
	for count in [1, 2, 3]:
		var s := _scene(["employee", "leader"], count)
		s.config.rules.meeting.auto_repeat = false
		var meeting := _meeting(s)
		var tools := _tools(s)
		var duration: float = s.config.number("meeting", "duration_seconds") * pow(1.2, count - 1)
		check(meeting.tools.size() == count and meeting.targets.size() == 6, "增加开会牌只增加共享时长，不重复召集")
		check(is_equal_approx(meeting.total, duration), "会议记录使用叠加后总时长")
		check(tools.all(func(id): return s.cards[id].status == "active" and is_equal_approx(s.cards[id].total, duration)), "所有参与开会牌显示同一活动时长")
		s.advance(duration * 0.5)
		check(tools.all(func(id): return is_equal_approx(s.cards[id].progress, 0.5) and is_equal_approx(s.cards[id].remaining, duration * 0.5)), "多张工具共享同一半程进度：工具数%d time=%s remaining=%s total=%s progress=%s errors=%s" % [count, s.time, meeting.remaining, meeting.total, s.cards[tools[0]].progress, s.config.errors])
		s.advance(duration * 0.5)
		check(s.meetings.is_empty() and meeting.targets.all(func(id): return not s.is_meeting_target(id)), "共享期限到达后仅结束一次并释放所有目标")
		check(tools.all(func(id): return s.cards[id].status == "recovering" and is_equal_approx(s.cards[id].remaining, s.config.number("meeting", "recovery_seconds"))), "叠加时长不改变每张工具的冷却时间")
		var events := s.drain_events()
		check(events.filter(func(event): return event.kind == "meeting_start").size() == 1 and events.filter(func(event): return event.kind == "meeting_end").size() == 1, "多工具只产生一场会议的开始和结束事件")

func _host_changes() -> void:
	var s := _scene(["leader", "employee"])
	var meeting := _meeting(s)
	var group: int = meeting.group
	var original_hosts: Array = meeting.hosts.duplicate()
	var original_targets: Array = meeting.targets.duplicate()
	s.advance(3.0)
	var remaining: float = meeting.remaining
	var extra := s.add_card("leader", 0)
	check(s.move_cards([extra], group) == group, "新增领导可加入活动会议")
	meeting = _meeting(s)
	check(meeting.targets.size() == 10 and meeting.targets.slice(0, 6) == original_targets, "新增主持只补足新增名额并保留原目标顺序")
	check(is_equal_approx(meeting.remaining, remaining) and s.tasks[extra].kind == "meeting", "加入主持占用本人且不重置倒计时")
	var ten: Array = meeting.targets.duplicate()
	var leader: int = original_hosts.filter(func(id): return s.cards[id].type == "leader")[0]
	var employee: int = original_hosts.filter(func(id): return s.cards[id].type == "employee")[0]
	check(s.move_cards([leader], -1) >= 0, "原主持代表可以离开")
	meeting = _meeting(s)
	check(meeting.targets == ten.slice(0, 6) and meeting.hosts.has(meeting.host) and not meeting.hosts.has(leader), "主持减少按原顺序保留名额并更新兼容代表")
	check(ten.slice(6).all(func(id): return not s.is_meeting_target(id)), "超出容量的旧目标立即释放")
	s.move_cards([extra], -1)
	meeting = _meeting(s)
	check(meeting.targets == ten.slice(0, 2) and meeting.hosts == [employee], "仅剩员工主持时缩至2个名额")
	var tool: int = _tools(s)[0]
	s.move_cards([employee], -1)
	check(s.meetings.is_empty() and not s.tasks.has(employee), "最后一名主持离开立即散会")
	check(s.cards[tool].status == "recovering" and ten.all(func(id): return not s.is_meeting_target(id)), "散会释放所有目标并令工具冷却")

func _tool_changes_and_relocation() -> void:
	var s := _scene(["employee", "leader"])
	var meeting := _meeting(s)
	var first: int = _tools(s)[0]
	var group: int = meeting.group
	var targets: Array = meeting.targets.duplicate()
	s.advance(meeting.total * 0.25)
	var second := s.add_card("meeting", 0)
	s.move_cards([second], group)
	meeting = _meeting(s)
	check(meeting.tools.size() == 2 and is_equal_approx(meeting.total, 14.4) and is_equal_approx(_progress(meeting), 0.25), "加第二张牌按已进行25%%重新换算时长：time=%s remaining=%s total=%s" % [s.time, meeting.remaining, meeting.total])
	check(meeting.targets == targets, "加牌不重抽目标")
	s.advance(meeting.total * 0.25)
	var third := s.add_card("meeting", 0)
	s.move_cards([third], group)
	meeting = _meeting(s)
	check(is_equal_approx(meeting.total, 17.28) and is_equal_approx(_progress(meeting), 0.5), "加第三张牌仍保留已进行50%而非重置")
	s.move_cards([third], -1)
	meeting = _meeting(s)
	check(is_equal_approx(meeting.total, 14.4) and is_equal_approx(_progress(meeting), 0.5), "减牌按相同比例缩短剩余时间")
	check(s.cards[third].status == "recovering" and is_equal_approx(s.cards[third].remaining, 24.0), "参与过的分离工具立即进入完整冷却")
	s.move_cards([third], group)
	meeting = _meeting(s)
	check(not meeting.tools.has(third) and is_equal_approx(meeting.total, 14.4) and is_equal_approx(_progress(meeting), 0.5), "冷却中的工具放回原组不能再次延长当前会议")
	check(not s.activate(third, group) and is_equal_approx(s.cards[third].remaining, 24.0), "显式激活不能绕过分离工具的冷却")
	s.move_cards([first], -1)
	meeting = _meeting(s)
	check(s.meetings.has(second) and not s.meetings.has(first) and meeting.tools == [second], "主工具移走后留下工具成为兼容字典主键")
	check(is_equal_approx(meeting.total, 12.0) and is_equal_approx(_progress(meeting), 0.5) and meeting.targets == targets, "换主工具保留进行比例和原目标")
	check(meeting.hosts.all(func(id): return s.tasks[id].tool_id == second), "全部主持任务切换至仍在场的主工具")
	var before := var_to_bytes(s.meetings)
	check(s.move_cards(s.group_cards(group), -1) == group and var_to_bytes(s.meetings) == before, "整组移动仅更换桌面位置，不重置会议身份或时钟")
	s.move_cards([second], -1)
	check(s.meetings.is_empty() and s.cards[second].status == "recovering", "最后一张活动工具离开散会并冷却")
	check(targets.all(func(id): return not s.is_meeting_target(id)), "最后活动工具离开释放全部目标，留组冷却牌不能接管")

func _unique_targets_and_busy_hosts() -> void:
	var s := _scene(["employee", "employee"], 2)
	var first := _meeting(s)
	var group := s.create_group(0)
	var host := s.add_card("employee", 0, group)
	var tool := s.add_card("meeting", 0, group)
	check(s.activate(tool, group, host) and s.meetings.size() == 2, "另一个独立组合可以开另一场会")
	var picked: Array = []
	var hosts: Array = []
	for active in s.meetings.values():
		picked.append_array(active.targets)
		hosts.append_array(active.hosts)
	check(picked.size() == 6 and _unique(picked).size() == picked.size(), "同组多工具及两场会议之间均不重复召集")
	check(s.meeting_candidates(1).all(func(id): return not hosts.has(id)), "所有正在主持的员工均不能被对面召入")
	for _i in 4: s.add_card("employee", 0)
	var enemy_group := s.create_group(1)
	var enemy_host := s.add_card("leader", 1, enemy_group)
	var enemy_tool := s.add_card("meeting", 1, enemy_group)
	check(s.activate(enemy_tool, enemy_group, enemy_host), "对面可针对剩余闲置人员开会")
	check(s.meetings[enemy_tool].targets.all(func(id): return not hosts.has(id)) and hosts.all(func(id): return not s.is_meeting_target(id)), "真实对手会议不会抢走任何在场主持")
	check(first.hosts.all(func(id): return s.tasks[id].kind == "meeting"), "反向会议不破坏原多主持任务")

func _unique(values: Array) -> Array:
	var result: Array = []
	for value in values:
		if not result.has(value): result.append(value)
	return result

func _cooldown_cannot_be_bypassed() -> void:
	var s := _scene(["leader"], 2)
	var meeting := _meeting(s)
	var group: int = meeting.group
	var tools := _tools(s)
	s.advance(meeting.total)
	check(s.meetings.is_empty(), "冷却测试先完整结束一场会议")
	var fresh := s.add_card("meeting", 0)
	s.move_cards([fresh], group)
	check(s.meetings.is_empty() and not s.activate(fresh, group), "同组存在冷却工具时新牌不能立即再开会")
	s.advance(5.0)
	check(s.meetings.is_empty() and tools.all(func(id): return is_equal_approx(s.cards[id].remaining, 19.0)), "失败的新牌操作不重置或跳过原冷却")
	s.move_cards([tools[0]], -1)
	check(not s.activate(fresh, group) and s.meetings.is_empty(), "移走一张冷却牌但同组仍有冷却牌时仍不能绕过")
	s.advance(18.999)
	check(s.meetings.is_empty(), "距离既有冷却完成仍差一点时不重开")
	s.advance(0.001)
	meeting = _meeting(s)
	check(meeting.tools.has(fresh) and meeting.tools.has(tools[1]) and not meeting.tools.has(tools[0]), "冷却真正结束后在场两张工具共同开始下一轮")
	check(is_zero_approx(_progress(meeting)) and is_equal_approx(meeting.total, 14.4), "新的合法轮次从零开始并按当前工具数计时")

func _clock_steps() -> void:
	var coarse := _scene(["leader", "employee"], 3)
	var fine := _scene(["leader", "employee"], 3)
	coarse.advance(100.0)
	for _i in 1000: fine.advance(0.1)
	check(coarse.meetings.size() == fine.meetings.size(), "多牌开会反复冷却在粗细步长下场次数一致")
	for id in _tools(coarse):
		check(coarse.cards[id].status == fine.cards[id].status and is_equal_approx(coarse.cards[id].remaining, fine.cards[id].remaining) and is_equal_approx(coarse.cards[id].progress, fine.cards[id].progress), "每张叠加牌状态和进度不依赖帧长")
	var coarse_events := coarse.drain_events().filter(func(event): return event.kind in ["meeting_start", "meeting_end"])
	var fine_events := fine.drain_events().filter(func(event): return event.kind in ["meeting_start", "meeting_end"])
	check(coarse_events.size() == fine_events.size(), "粗细时钟产生相同数量的会议事件")
	for i in mini(coarse_events.size(), fine_events.size()):
		check(coarse_events[i].kind == fine_events[i].kind and coarse_events[i].targets == fine_events[i].targets and is_equal_approx(coarse_events[i].time, fine_events[i].time), "会议边界与有种子抽样在粗细时钟下完全对应")

func _forks_and_legacy_snapshot() -> void:
	var s := _scene(["leader", "employee"], 3)
	s.advance(2.0)
	var original := var_to_bytes(s.meetings)
	var branch := s.fork_for_bot(83)
	check(branch.meetings == s.meetings, "BOT复制携带全部主持、全部工具及共享时钟")
	branch.advance(1.0)
	check(var_to_bytes(s.meetings) == original and is_equal_approx(_meeting(branch).remaining, _meeting(s).remaining - 1.0), "复制后的结算不修改原会议")
	var child := branch.fork_search_node()
	check(child.meetings == branch.meetings, "搜索子节点继续保留同一多主持会议")
	var legacy_source := _scene(["leader"], 1)
	legacy_source.advance(2.0)
	var legacy := legacy_source.fork_for_bot(91)
	var primary: int = legacy.meetings.keys()[0]
	var snapshot: Dictionary = legacy.meetings[primary].duplicate(true)
	legacy.meetings[primary].erase("hosts")
	legacy.meetings[primary].erase("tools")
	legacy._sync_schedule()
	var restored := _meeting(legacy)
	check(restored.hosts == [snapshot.host] and restored.tools == [primary], "旧host单字段快照恢复为单主持单工具会议")
	check(restored.targets == snapshot.targets and is_equal_approx(restored.remaining, snapshot.remaining) and is_equal_approx(restored.total, snapshot.total), "旧快照恢复不重抽目标、不重置进度")
	legacy.advance(1.0)
	check(is_equal_approx(_meeting(legacy).remaining, snapshot.remaining - 1.0), "恢复后的旧会议继续使用真实共享时钟")

func _legacy_parallel_meetings() -> void:
	var s := _scene(["leader", "leader"], 2)
	var current := _meeting(s)
	var group: int = current.group
	var hosts: Array = current.hosts.duplicate()
	var tools: Array = current.tools.duplicate()
	var targets: Array = current.targets.duplicate()
	# Recreate the old save shape: two independent sessions in the same group,
	# each with only host and its own four targets, clock and primary tool key.
	s.meetings.clear()
	for i in 2:
		var remaining := 6.0 if i == 0 else 3.0
		s.meetings[tools[i]] = {"host":hosts[i], "group":group,
			"targets":targets.slice(i * 4, (i + 1) * 4), "total":12.0, "remaining":remaining}
		s.tasks[hosts[i]] = {"kind":"meeting", "tool_id":tools[i], "group":group,
			"work_id":-1, "progress":1.0 - remaining / 12.0}
		s.cards[tools[i]].total = 12.0
		s.cards[tools[i]].remaining = remaining
		s.cards[tools[i]].progress = 1.0 - remaining / 12.0
	s._sync_schedule()
	var merged := _meeting(s)
	var primary: int = s.meetings.keys()[0]
	check(merged.hosts.size() == 2 and hosts.all(func(id): return merged.hosts.has(id)) and merged.tools.size() == 2 and tools.all(func(id): return merged.tools.has(id)), "旧存档同组两场会议归并全部主持和工具")
	check(merged.targets.size() == 8 and _unique(merged.targets).size() == 8 and targets.all(func(id): return merged.targets.has(id)), "归并旧会议保留8名原目标且不重复")
	check(is_equal_approx(merged.total, 14.4) and is_equal_approx(merged.remaining, 3.6) and is_equal_approx(_progress(merged), 0.75), "归并采用较大75%进度并按双牌14.4秒换算，不刷新倒计时")
	check(hosts.all(func(id): return s.tasks[id].kind == "meeting" and s.tasks[id].tool_id == primary), "旧存档全部主持任务统一指向归并后的主工具")
	check(tools.all(func(id): return s.cards[id].status == "active" and is_equal_approx(s.cards[id].total, 14.4) and is_equal_approx(s.cards[id].remaining, 3.6) and is_equal_approx(s.cards[id].progress, 0.75)), "归并后两张牌实际显示同一共享进度")
