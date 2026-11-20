# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 规则：任何人员牌，清掉几份工作就赚几份工作的钱。人员牌上只有「每批处理量」一个数，
## 没有单独的收入倍率；一份工作值多少钱只写在工作牌上，默认 1。
const Evaluation = preload("res://engine/off_work_bot_evaluator.gd")
const WORKERS := ["employee", "grinder", "workaholic", "work_emperor"]
const PERSONNEL := ["employee", "leader", "grinder", "workaholic", "work_emperor", "boss"]

func _initialize() -> void:
	_default_table()
	_every_worker_alone()
	_mixed_groups_and_short_queues()
	_any_capacity_any_person()
	_price_of_one_work()
	_legacy_tables_fold_into_capacity()
	_recorded_tables()
	_previews_and_forecasts()
	OffWorkCardDB.configure(OffWorkConfig.new())
	finish()

func _state(contents: Dictionary, config: OffWorkConfig = null) -> OffWorkState:
	if config == null: config = OffWorkConfig.new()
	config.rules.initial.groups = [contents]
	config.rules.initial.money = 0
	var state := OffWorkState.new(config)
	state.new_game(4107)
	state.offers.clear()
	state.drain_events()
	return state

func _work_group(state: OffWorkState) -> int:
	return int(state.cards[state._owner_type(0, "work")[0]].group)

## Advances batch by batch and checks every settlement of owner 0.
func _settlements(state: OffWorkState, seconds: float, label: String, price := 1) -> Array:
	var started_work := state.work_count(0)
	var started_money := state.money(0)
	var seen: Array = []
	var left := seconds
	while left > 0.0 and state.winner < 0:
		var step := minf(left, 0.5)
		state.advance(step)
		left -= step
		for event in state.drain_events():
			if str(event.kind) != "work_complete" or int(event.owner) != 0: continue
			seen.append(event)
			check(int(event.amount) == event.ids.size() * price and event.money_ids.size() == int(event.amount),
				"%s：一次结算清 %d 份、赚 %d 钱" % [label, event.ids.size(), int(event.amount)])
	check(not seen.is_empty(), label + "：确实发生过结算")
	check(state.money(0) - started_money == (started_work - state.work_count(0)) * price,
		"%s：累计赚到的钱等于累计清掉的工作" % label)
	return seen

func _default_table() -> void:
	var config := OffWorkConfig.new()
	check(config.errors.is_empty() and config.income_per_work() == 1, "默认卡表有效，一份工作值 1 钱")
	OffWorkCardDB.configure(config)
	for kind in PERSONNEL:
		check(not config.roles[kind].has("work_income_multiplier"), kind + " 没有收入倍率字段")
		var definition := OffWorkCardDB.get_def(kind)
		if config.can_work(kind):
			var capacity := int(config.roles[kind].work_capacity)
			check(int(definition.recipe_n) == capacity and int(definition.output_n) == capacity,
				"%s 牌面：消耗 %d 份工作，产出 %d 份金钱" % [kind, capacity, capacity])
			check(str(definition.description).contains("最多处理 %d 份工作，赚 %d 钱" % [capacity, capacity]),
				kind + " 的说明写的是同一个数")
		else:
			check(not definition.has("recipe_n") and not definition.has("output_n"), kind + " 不处理工作，牌面不标消耗和产出")
	check(WORKERS.map(func(kind): return int(config.roles[kind].work_capacity)) == [1, 2, 4, 8],
		"默认四级每批处理 1、2、4、8 份")

func _every_worker_alone() -> void:
	for kind in WORKERS:
		for overtime in [0, 2]:
			for protected in [false, true]:
				var state := _state({kind: 1, "work": 200})
				var group := _work_group(state)
				for _i in overtime: state.add_card("overtime", 0, group)
				if protected: state.move_cards([state.add_card("union", 0)], group)
				var label := "%s%s%s" % [kind, "＋%d 加班" % overtime if overtime > 0 and not protected else "", "＋工会" if protected else ""]
				var events := _settlements(state, 31.0, label)
				var expected := 1 if protected else int(state.config.roles[kind].work_capacity)
				check(events.all(func(event): return event.ids.size() == expected), "%s：每批清 %d 份" % [label, expected])

func _mixed_groups_and_short_queues() -> void:
	var everyone := {"employee": 1, "grinder": 1, "workaholic": 1, "work_emperor": 1, "leader": 1, "work": 26}
	var state := _state(everyone)
	state.move_cards([state.add_card("boss", 0)], _work_group(state))
	var events := _settlements(state, 25.0, "六种人员同组")
	check(events.size() == 2 and events[0].ids.size() == 15 and events[0].participants.size() == 4,
		"领导和老板不清工作也不分钱，四级一批清 15 份")
	check(events[1].ids.size() == 11 and state.work_count(0) == 0, "最后一批只剩 11 份，就只清 11 份、赚 11 钱")
	for count in [1, 3, 7]:
		var short := _state({"work_emperor": 1, "work": count})
		_settlements(short, 11.0, "打工皇帝面前只有 %d 份" % count)
		check(short.work_count(0) == 0 and short.money(0) == count, "不够一批时不多赚：%d 份换 %d 钱" % [count, count])

func _any_capacity_any_person() -> void:
	var config := OffWorkConfig.new()
	var capacities := {"employee": 3, "grinder": 5, "workaholic": 7, "work_emperor": 9, "leader": 2}
	for kind in capacities: config.roles[kind].work_capacity = capacities[kind]
	# 卡表若让领导也处理工作，它同样清几份赚几份。
	config.roles.leader.can_work = true
	check(config.validate(), "任意每批处理量都是合法卡表")
	var state := _state({"employee": 1, "grinder": 1, "workaholic": 1, "work_emperor": 1, "leader": 1, "work": 300}, config)
	var events := _settlements(state, 35.0, "自定处理量 3、5、7、9、2")
	check(events.all(func(event): return event.ids.size() == 26 and event.participants.size() == 5), "五人每批合计清 26 份")
	for kind in capacities:
		var alone := OffWorkConfig.new()
		alone.roles[kind].work_capacity = capacities[kind]
		if kind == "leader": alone.roles.leader.can_work = true
		var single := _state({kind: 1, "work": 100}, alone)
		_settlements(single, 21.0, "%s 处理量 %d" % [kind, capacities[kind]])
		check(100 - single.work_count(0) == 2 * int(capacities[kind]), "%s 两批清 %d 份" % [kind, 2 * int(capacities[kind])])

func _price_of_one_work() -> void:
	# 工作牌可以把一份工作定成别的价钱；它对所有人员一视同仁。
	var config := OffWorkConfig.new()
	config.cards.work.income = 3
	check(config.validate() and config.income_per_work() == 3, "一份工作的价钱只由工作牌决定")
	OffWorkCardDB.configure(config)
	for kind in WORKERS:
		var definition := OffWorkCardDB.get_def(kind)
		check(int(definition.output_n) == 3 * int(definition.recipe_n), kind + " 牌面产出按工作牌的价钱折算")
		var priced := OffWorkConfig.new()
		priced.cards.work.income = 3
		_settlements(_state({kind: 1, "work": 100}, priced), 11.0, "%s，一份工作 3 钱" % kind, 3)
	OffWorkCardDB.configure(OffWorkConfig.new())

func _legacy_document(pairs: Dictionary) -> Dictionary:
	var document: Dictionary = OffWorkConfig.new().balance_document()
	for kind in PERSONNEL:
		document.roles[kind].work_income_multiplier = 1.0
	for kind in pairs:
		document.roles[kind].work_capacity = pairs[kind][0]
		document.roles[kind].work_income_multiplier = pairs[kind][1]
	return document

func _legacy_tables_fold_into_capacity() -> void:
	# 以前的默认卡表：每批都是 1 份，升级只涨每份收入。
	var old_default := _legacy_document({"employee": [1.0, 1.0], "grinder": [1.0, 2.0], "workaholic": [1.0, 4.0], "work_emperor": [1.0, 8.0]})
	var untouched := var_to_bytes(old_default)
	var config := OffWorkConfig.new(old_default)
	check(config.errors.is_empty(), "带收入倍率的旧卡表仍能读入：" + "；".join(config.errors))
	check(var_to_bytes(old_default) == untouched, "读入不改动传入的旧卡表")
	check(WORKERS.map(func(kind): return int(config.roles[kind].work_capacity)) == [1, 2, 4, 8],
		"旧倍率并入每批处理量：原来 1 份赚 4 钱的肝帝，现在 4 份赚 4 钱")
	check(PERSONNEL.all(func(kind): return not config.roles[kind].has("work_income_multiplier")), "读入后不再有收入倍率")
	check(typeof(config.roles.workaholic.work_capacity) == TYPE_FLOAT, "合并后的数值类型与旧卡表一致")
	var exported := config.balance_document()
	check(PERSONNEL.all(func(kind): return not exported.roles[kind].has("work_income_multiplier")), "导出的卡表没有收入倍率")
	check(var_to_bytes(OffWorkConfig.normalize_balance_document(exported)) == var_to_bytes(exported), "再读一遍不会重复合并")
	for kind in WORKERS:
		_settlements(_state({kind: 1, "work": 100}, OffWorkConfig.new(old_default)), 11.0, "旧卡表的 " + kind)
	var both := OffWorkConfig.new(_legacy_document({"work_emperor": [2.0, 4.0], "grinder": [3, 2]}))
	check(both.errors.is_empty() and int(both.roles.work_emperor.work_capacity) == 8 and int(both.roles.grinder.work_capacity) == 6,
		"处理量和倍率都大于 1 时按原来的收入合并：2 份各 4 钱变成 8 份 8 钱")
	check(typeof(both.roles.grinder.work_capacity) == TYPE_INT, "整数卡表合并后仍是整数")
	for invalid in [0.0, -1.0, 1.5, "2", null]:
		var document := _legacy_document({})
		document.roles.grinder.work_income_multiplier = invalid
		check(not OffWorkConfig.new(document).errors.is_empty(), "无效的旧倍率 %s 仍被拒绝" % str(invalid))
	var stray := OffWorkConfig.new()
	stray.roles.grinder["work_income_multiplier"] = 2
	check(not stray.validate() and stray.errors.any(func(message): return message.contains("work_income_multiplier")),
		"在已读入的卡表上再塞收入倍率会被校验拒绝")

func _recorded_tables() -> void:
	var expected := {
		"recorded_growth_20261109.json": [1, 2, 4, 8],
		"off_work_growth_market_choice_20261110.json": [1, 2, 4, 8],
		"production_stall_1001.json": [1, 2, 4, 8],
	}
	for name in expected:
		var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/off_work/fixtures/" + name))
		var config := OffWorkConfig.new(document.cards)
		check(config.errors.is_empty(), name + " 里的录像卡表仍能读入")
		if not config.errors.is_empty(): continue
		check(WORKERS.map(func(kind): return int(config.roles[kind].work_capacity)) == expected[name],
			name + " 的四级人员读入后每批处理 1、2、4、8 份")
		_settlements(_state({"employee": 1, "grinder": 1, "workaholic": 1, "work_emperor": 1, "work": 60}, config), 21.0, name)

func _previews_and_forecasts() -> void:
	OffWorkCardDB.configure(OffWorkConfig.new())
	for work in [1, 2, 6, 15, 40]:
		for protected in [false, true]:
			var cards: Array = PERSONNEL.map(func(kind): return {"type": kind})
			for _i in work: cards.append({"type": "work"})
			if protected: cards.append({"type": "union"})
			var preview := OffWorkComboRules.evaluate(cards)
			check(bool(preview.valid) and preview.type == "production" and int(preview.output_n) == int(preview.recipe_pay_n),
				"组合预览：%d 份工作%s，消耗 %d 份、产出 %d 钱" % [work, "＋工会" if protected else "", int(preview.recipe_pay_n), int(preview.output_n)])
			check(int(preview.recipe_pay_n) == mini(work, 4 if protected else 15), "组合预览的消耗量按实际处理量封顶")
	for kind in WORKERS:
		var state := _state({kind: 1, "work": 40})
		var value: Dictionary = Evaluation.new().evaluate_current(state, 0, state.config.rules.bot, -1, [0.0, 1.0])
		check(value.complete and is_equal_approx(float(value.detail.sides[0].income), 40.0),
			"BOT 预测 %s 清完 40 份工作正好赚 40 钱" % kind)
