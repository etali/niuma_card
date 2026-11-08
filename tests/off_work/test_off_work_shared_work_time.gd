# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const Economy = preload("res://engine/off_work_bot_economy.gd")
const WORKERS := ["employee", "grinder", "workaholic", "work_emperor"]

func _initialize() -> void:
	_shared_production_clock()
	_forecast_uses_real_rates()
	_migration()
	_invalid_duration()
	_shared_distribution()
	finish()

func _shared_production_clock() -> void:
	var defaults := OffWorkConfig.new()
	check(defaults.work_seconds() == 10.0 and defaults.roles.values().all(func(role): return not role.has("work_seconds")), "正式工作牌统一配置10秒，人员不再各有工作时长")
	for kind in WORKERS:
		for overtime in [0, 1, 2]:
			var config := OffWorkConfig.new()
			config.cards.work.work_seconds = 7.5
			config.rules.initial.groups = [{kind:1, "work":40, "overtime":overtime}]
			config.rules.initial.money = 0
			config.rules.conveyor.pool = {"employee":1}
			var state := OffWorkState.new(config)
			state.new_game(741)
			var person: int = state._owner_type(0, kind)[0]
			var group: int = state.cards[person].group
			var duration := 7.5 / pow(float(config.rules.overtime.speed_multiplier), overtime)
			check(is_equal_approx(config.work_rate(kind, overtime), 1.0/duration)
				and is_equal_approx(state.group_work_rate(group), 1.0/duration), "%s/%d张加班共用工作牌时间及真实倍率" % [kind, overtime])
			state.advance(duration - 0.001)
			check(state.work_count(0) == 40 and state.money(0) == 0, "%s/%d张加班在同一截止时刻前未结算" % [kind, overtime])
			state.advance(0.001)
			check(state.work_count(0) == 40 - int(config.roles[kind].work_capacity)
				and state.money(0) == config.income_per_work(kind) * int(config.roles[kind].work_capacity), "%s/%d张加班在共享周期结束后保留本级处理量和收益" % [kind, overtime])
			check(is_equal_approx(state.cards[person].rate_multiplier, config.overtime_multiplier(overtime)), "卡面速度倍率与统一加班倍率相同")
	for kind in ["leader", "boss"]:
		check(not defaults.can_work(kind) and defaults.work_rate(kind, 0) == 0.0 and defaults.work_rate(kind, 2) == 0.0, kind + "仍不能工作，加班不会改变资格")
	defaults.cards.work.work_seconds = 7.5
	OffWorkCardDB.configure(defaults)
	for kind in WORKERS:
		check(str(OffWorkCardDB.CARDS[kind].description).contains("7.5 秒"), kind + "卡牌说明读取工作牌的共享时间")

func _forecast_uses_real_rates() -> void:
	var config := OffWorkConfig.new()
	config.cards.work.work_seconds = 8.0
	config.rules.overtime.speed_multiplier = 1.5
	var evaluation := Evaluation.new()
	evaluation._config = config
	for kind in WORKERS:
		var unit: Dictionary = evaluation._unit(kind, 1, false, false)
		check(is_equal_approx(unit.speed, config.work_rate(kind, 0)), kind + "的BOT基础速度调用真实规则接口")
		for overtime in [0, 1, 2]:
			var group: Dictionary = evaluation._group("work", 40, 0.0, overtime)
			group.workers = {kind:unit}
			var stats: Dictionary = evaluation._stats(group)
			check(is_equal_approx(stats.rate, config.work_rate(kind, overtime)), "%s/%d张加班的BOT预测与真实工作速率一致" % [kind, overtime])
	var saturated := config.overtime_multiplier(4096)
	check(is_finite(saturated) and saturated >= config.overtime_multiplier(4095), "大量加班只在浮点表示极限饱和，倍率保持有限单调")
	var extreme: Dictionary = evaluation._group("work", 40, 0.0, 4096)
	extreme.workers = {"employee":evaluation._unit("employee", 1, false, false)}
	check(is_equal_approx(evaluation._stats(extreme).rate, config.work_rate("employee", 4096)), "极值倍率也不再使用BOT独有的指数裁剪")
	config.cards.work.work_seconds = 0.0001
	check(config.validate() and is_equal_approx(evaluation._unit("employee", 1, false, false).speed, config.work_rate("employee", 0)), "合法短周期不会在BOT侧被独立钳制成另一套速度")

func _migration() -> void:
	var legacy := OffWorkConfig.new().balance_document()
	legacy.cards.work.erase("work_seconds")
	for kind in legacy.roles: legacy.roles[kind].work_seconds = 2.0
	legacy.roles.employee.work_seconds = 12.0
	var original := var_to_bytes(legacy)
	var migrated := OffWorkConfig.new(legacy)
	check(migrated.errors.is_empty() and migrated.work_seconds() == 12.0, "旧卡表使用普通员工原工作时长作为共享值")
	check(WORKERS.all(func(kind): return is_equal_approx(migrated.work_rate(kind, 0), 1.0/12.0)), "旧高级员工异速字段不再产生第二套规则")
	check(migrated.roles.values().all(func(role): return not role.has("work_seconds")), "载入后删除所有人员的旧时长字段")
	check(var_to_bytes(legacy) == original, "兼容迁移不改写输入原文档")
	legacy.cards.work.work_seconds = 6.0
	var current := OffWorkConfig.new(legacy)
	check(current.work_seconds() == 6.0 and current.roles.values().all(func(role): return not role.has("work_seconds")), "工作牌显式新字段优先于旧员工值")
	var saved := current.balance_document()
	check(saved.cards.work.work_seconds == 6.0 and saved.roles.values().all(func(role): return not role.has("work_seconds")), "导出仅保留工作牌的共享时长")

func _invalid_duration() -> void:
	for invalid in [0, -1, "10", null, NAN, INF, 1e-309]:
		var config := OffWorkConfig.new()
		config.cards.work.work_seconds = invalid
		check(not config.validate(), "非法工作时长或溢出速率明确拒绝：" + str(invalid))
	var missing := OffWorkConfig.new().balance_document()
	missing.cards.work.erase("work_seconds")
	check(not OffWorkConfig.new(missing).errors.is_empty(), "新旧字段都缺失时拒绝，不静默补默认时间")

func _shared_distribution() -> void:
	var config := OffWorkConfig.new()
	config.rules.conveyor.pool = {"employee":0, "coffee":0.01, "outsource":0.03}
	var chances := config.conveyor_probabilities()
	check(chances == {"employee":0.0, "coffee":0.25, "outsource":0.75}, "游戏与BOT共用权重概率归一化接口")
	check(is_equal_approx(Economy.expected_supply_wait(config, "outsource"), config.rules.conveyor.interval_seconds / chances.outsource), "BOT到货等待直接采用共享概率")
	check(not is_finite(Economy.expected_supply_wait(config, "employee")), "共享零概率不会被BOT补成保底员工")
	OffWorkCardDB.configure(config)
	check(OffWorkCardDB.CARDS.coffee.weight == 0.01, "共享卡牌展示保留小数权重而非截成零")
