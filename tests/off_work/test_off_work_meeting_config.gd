# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	var defaults := OffWorkConfig.new()
	check(defaults.errors.is_empty(), "新会议默认卡表通过校验")
	for kind in defaults.roles:
		var capacity := 4 if kind == "leader" else 2
		check(defaults.meeting_capacity(kind) == capacity, "%s 的默认主持名额为 %d" % [kind, capacity])
	check(not defaults.can_be_meeting_target("boss") and not defaults.roles.boss.can_be_strike_target,
		"老板主持容量变化不改变自身开会与罢工免疫")
	check(defaults.meeting_duration(0) == 0.0 and defaults.meeting_duration(-1) == 0.0, "无开会牌时没有会议持续时间")
	check(defaults.meeting_duration(1) == 12.0, "一张开会仍为12秒")
	check(is_equal_approx(defaults.meeting_duration(2), 14.4), "第二张开会只将持续时间乘1.2")
	check(is_equal_approx(defaults.meeting_duration(3), 17.28), "第三张开会继续叠乘时长")
	check(defaults.number("meeting", "recovery_seconds") == 24.0, "叠牌时长不改默认冷却参数")
	check(is_finite(defaults.meeting_duration(4096)) and defaults.meeting_duration(4096) > 0.0,
		"4096张默认开会不会产生无限计时")
	var document := defaults.balance_document()
	document.rules.meeting.duration_multiplier = 1.5
	document.rules.meeting.duration_seconds = 10.0
	document.rules.meeting.recovery_seconds = 7.0
	document.roles.grinder.meeting_multiplier = 3.0
	var custom := OffWorkConfig.new(document)
	check(custom.errors.is_empty() and custom.meeting_duration(3) == 22.5, "自定义倍率和基础时长共同计算")
	check(custom.meeting_capacity("grinder") == 6 and custom.number("meeting", "recovery_seconds") == 7.0,
		"自定义主持名额和冷却仍保持独立可调")
	for value in [0.0, 0.99, -1, INF, NAN, true, "1.2"]:
		var bad := defaults.balance_document()
		bad.rules.meeting.duration_multiplier = value
		var rejected := OffWorkConfig.new(bad)
		check(not rejected.errors.is_empty() and "\n".join(rejected.errors).contains("meeting.duration_multiplier"),
			"非法时长倍率有字段定位错误：" + str(value))
	var legacy := defaults.balance_document()
	legacy.rules.meeting.erase("duration_multiplier")
	legacy.roles.grinder.meeting_multiplier = 0.5
	var original := var_to_bytes(legacy)
	var restored := OffWorkConfig.new(legacy)
	check(restored.errors.is_empty() and restored.rules.meeting.duration_multiplier == 1.0, "旧表缺失倍率时保留无时长叠加行为")
	check(restored.meeting_duration(4096) == 12.0 and restored.meeting_capacity("grinder") == 1,
		"旧表的时长和自定义主持倍率不被新默认值覆盖")
	check(original == var_to_bytes(legacy), "迁移仅作用于副本，原表不改写")
	var normalized := restored.balance_document()
	check(OffWorkConfig.normalize_balance_document(normalized) == normalized, "新字段迁移可重复执行")
	var extreme := defaults.balance_document()
	extreme.rules.meeting.duration_seconds = 1.0e-300
	var tiny := OffWorkConfig.new(extreme)
	var scaled := tiny.meeting_duration(4096)
	check(tiny.errors.is_empty() and is_finite(scaled) and scaled > 1.0 and scaled < 1.0e100,
		"中间倍率溢出时仍保留可表示的最终时长，不错误提前饱和")
	OffWorkCardDB.configure(defaults)
	for kind in defaults.roles:
		var description := str(OffWorkCardDB.get_def(kind).description)
		check(description.contains("提供 %d 个参会名额" % defaults.meeting_capacity(kind)) and description.contains("多人主持时名额累加"),
			"%s卡面显示实际主持名额与累加规则" % kind)
	var meeting_description := str(OffWorkCardDB.get_def("meeting").description)
	check(meeting_description.contains("时长乘 1.2") and meeting_description.contains("不增加名额") and meeting_description.contains("冷却不叠加"),
		"开会卡面展示时长叠加与人数、冷却边界")
	check(not meeting_description.contains("{duration_multiplier}"), "卡面新时长倍率占位符正确展开")
	finish()
