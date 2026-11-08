extends "res://tests/harness.gd"

const Session = preload("res://engine/off_work_session.gd")
const Slots = preload("res://engine/shift_slot.gd")
class RestoredTable extends Node:
	var state: OffWorkState
	var bot: OffWorkBot
	var replay = preload("res://engine/off_work_replay.gd").new()

func state() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 3, "work": 50}]
	config.rules.initial.money = 0
	var result := OffWorkState.new(config)
	result.new_game(41)
	return result

func _initialize() -> void:
	_work_keeps_its_function()
	_meeting_holds_during_cooldown()
	_tool_waits_and_merge_direction()
	_outsource_cooldown()
	_saved_lock_and_legacy_snapshot()
	finish()

func _work_keeps_its_function() -> void:
	for kind in ["meeting", "transfer", "slack", "outsource"]:
		var s := state()
		var cash := s.add_card("money", 0, 1)
		s.cards[cash].amount = 3
		s.advance(2.0)
		var tool := s.add_card(kind, 0)
		s.move_cards([tool], 1)
		check(s.groups[1].function == "work" and s.cards[tool].status == "ready", "工作组合不被后来加入的%s切换" % kind)
		check(not s.activate(tool, 1), "手动发动%s也不能绕过已有工作功能" % kind)
		s.advance(1.0)
		check(is_equal_approx(s.group_work_progress(1), 0.3) and s.group_work_participants(1).size() == 3,
			"加入%s后原工作进度和三名参与者保持" % kind)

func _meeting_holds_during_cooldown() -> void:
	var s := state()
	var meeting := s.add_card("meeting", 0)
	var group: int = s.cards[meeting].group
	s.move_cards(s.group_people(1), group)
	s.move_cards(s.group_work(1), group)
	check(s.meetings.has(meeting) and s.groups[group].function == "meeting", "先成立会议组合再补工作仍然开会")
	check(s.group_work_participants(group).is_empty() and is_zero_approx(s.group_work_rate(group)), "主持之外的人员也不在同组同时工作")
	s.advance(12.0)
	check(s.cards[meeting].status == "recovering" and s.groups[group].function == "meeting", "散会冷却仍保留会议功能")
	s.advance(24.0)
	check(s.meetings.has(meeting) and s.work_count(0) == 50 and s.money(0) == 0, "会议自动续开且整个周期没有普通工作收入")
	s.move_cards([meeting], -1)
	check(s.groups[group].function == "work" and s.group_work_participants(group).size() == 3, "移走会议牌后才恢复三人工作")
	s.advance(10.0)
	check(s.work_count(0) == 47 and s.money(0) == 3, "恢复工作后正常按整批结算一次")

func _tool_waits_and_merge_direction() -> void:
	var s := state()
	var transfer := s.add_card("transfer", 0)
	var group: int = s.cards[transfer].group
	s.move_cards(s.group_cards(1), group)
	var work := s.group_work(group)
	s.move_cards(work, -1)
	check(s.groups[group].function == "transfer" and s.cards[transfer].status == "ready", "甩锅暂时缺料仍保留功能")
	var slack := s.add_card("slack", 0)
	s.move_cards([slack], group)
	check(s.cards[slack].status == "ready" and s.group_slack_participants(group).is_empty(), "缺料期间加入摸鱼不接管甩锅组合")
	s.move_cards(work, group)
	check(s.group_transfer_participants(group).size() == 3 and s.group_work_participants(group).is_empty(), "补回工作继续原甩锅功能")
	var worker := s.add_card("employee", 0)
	var workplace: int = s.cards[worker].group
	s.add_card("work", 0, workplace)
	s.advance(1.0)
	s.move_cards(s.group_cards(group), workplace)
	check(s.groups[workplace].function == "work" and s.cards[transfer].status == "ready" and s.cards[slack].status == "ready",
		"整组并入已有工作组时保留目标组的功能")
	s.move_cards(s.group_work(workplace), -1)
	check(s.groups[workplace].function == "slack", "拆掉原工作后剩余有效工具组合才可启动")

func _outsource_cooldown() -> void:
	var s := state()
	var outsource := s.add_card("outsource", 0)
	var group: int = s.cards[outsource].group
	var cash := s.add_card("money", 0, group)
	s.cards[cash].amount = 2
	s.move_cards(s.group_cards(1), group)
	s.advance(10.0)
	check(s.cards[outsource].status == "recovering" and s.groups[group].function == "outsource", "外包读满后冷却继续锁定外包功能")
	s.advance(5.0)
	check(s.work_count(0) == 48 and s.money(0) == 0 and s.group_work_participants(group).is_empty(), "外包冷却时同组员工不能接着普通工作")
	s.move_cards([outsource], -1)
	check(s.groups[group].function == "work" and s.group_work_participants(group).size() == 3, "移走外包牌后恢复工作")

func _saved_lock_and_legacy_snapshot() -> void:
	var s := state()
	var meeting := s.add_card("meeting", 0)
	var group: int = s.cards[meeting].group
	s.move_cards(s.group_cards(1), group)
	s.advance(12.0)
	var copy := s.fork_for_bot(88)
	check(copy.groups[group].function == "meeting" and copy.groups == s.groups, "搜索分支和序列化的groups保留功能锁")
	copy.groups[group].erase("function")
	copy.groups[group].job = "work" # Legacy snapshots released the job at cooldown.
	copy._sync_schedule()
	check(copy.groups[group].function == "meeting" and copy.group_work_participants(group).is_empty(), "旧冷却存档根据仍在场的会议牌恢复锁")
	check(s.groups[group].function == "meeting" and s.cards[meeting].status == "recovering", "迁移分支不改变真实牌局")
	copy.groups[group].erase("function")
	copy.groups[group].job = "work"
	var world := {}
	for key in Session.STATE_FIELDS: world[key] = copy.get(key)
	var layout := {}
	for key in Session.BOARD_FIELDS: layout[key] = {}
	var saved := {"world": world, "layout": layout, "balance": copy.config.balance_document(),
		"bot": {"bot": copy.config.rules.bot, "preferences": copy.config.bot_preferences},
		"rng": copy._rng.state, "bot_rng": 43, "bot_started": false, "bot_next": 0.0,
		"paused": true, "replay_frames": []}
	check(Slots.save(Slots.OFF_WORK, saved), "旧功能快照写入实际会话存档")
	var bytes := FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK))
	var restored := RestoredTable.new()
	check(not Session.read_session(restored).is_empty() and restored.state.groups[group].function == "meeting",
		"暂停存档加载在展示首帧前恢复会议锁")
	check(restored.state.time == copy.time and restored.state.group_work_participants(group).is_empty()
		and restored.state.drain_events().is_empty(), "存档迁移不推进时间、不产生工作或重播事件")
	check(FileAccess.get_file_as_bytes(Slots.path(Slots.OFF_WORK)) == bytes, "读取迁移不覆写原存档文件")
	restored.free()
