# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Economy = preload("res://engine/off_work_bot_economy.gd")

func _initialize() -> void:
	_single_card_pools()
	_integer_bag_weights()
	_legacy_document()
	_invalid_weights()
	finish()

func _world(pool: Dictionary, seed_value := 7913) -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.conveyor.pool = pool.duplicate()
	config.rules.initial.groups = [{"employee": 1, "work": 100}]
	var state := OffWorkState.new(config)
	state.new_game(seed_value)
	return state

func _single_card_pools() -> void:
	var config := OffWorkConfig.new()
	check(not config.rules.conveyor.has("employee_every") and not config.rules.conveyor.has("opening"), "正式卡表不再包含固定员工或固定开局覆盖项")
	for kind in config.cards:
		if not config.can_purchase(str(kind)): continue
		var state := _world({kind: 1})
		check(state.last_error.is_empty() and state.offers.size() == state.config.rules.conveyor.slots, str(kind) + " 单牌权重池可正常开局")
		check(state.offers.all(func(offer): return offer.type == kind), str(kind) + " 的全部开局槽均按唯一正权重生成")
		state.advance(16.0)
		check(state.offers.all(func(offer): return offer.type == kind), str(kind) + " 的后续补牌没有额外固定员工或其他牌")
		check(is_equal_approx(Economy.expected_supply_wait(state.config, str(kind)), state.config.rules.conveyor.interval_seconds), str(kind) + " 单牌池的 BOT 到货估计与实际刷新间隔相同")
	var state := _world({"employee": 0, "outsource": 1})
	check(state.offers.all(func(offer): return offer.type == "outsource"), "员工零权重在开局也不会出现")
	state.advance(30.0)
	check(state.offers.all(func(offer): return offer.type == "outsource"), "员工零权重在跨越多个补牌周期后仍不出现")
	check(not is_finite(Economy.expected_supply_wait(state.config, "employee")), "BOT 不虚构零权重员工供应")
	state.config.cards.employee.purchasable = false
	state.config.rules.conveyor.pool.erase("employee")
	check(state.config.validate(), "不再强制可购买员工，剩余合法正权重牌池可独立供牌")

func _integer_bag_weights() -> void:
	var state := _world({"employee":0, "coffee":1, "outsource":3})
	var sequence := []
	for offer in state.offers: sequence.append(str(offer.type))
	while sequence.size() < 24: sequence.append(str(state._new_offer().type))
	for start in range(0,24,4):
		var bag: Array = sequence.slice(start,start+4)
		check(bag.count("coffee") == 1 and bag.count("outsource") == 3,
			"每权重1对应一张实体牌，第%d袋精确含咖啡1张/外包3张" % (start/4+1))
	var doubled := _world({"employee":0, "coffee":2, "outsource":6})
	var doubled_sequence := []
	for offer in doubled.offers: doubled_sequence.append(str(offer.type))
	while doubled_sequence.size() < 24: doubled_sequence.append(str(doubled._new_offer().type))
	for start in range(0,24,8):
		var bag: Array = doubled_sequence.slice(start,start+8)
		check(bag.count("coffee") == 2 and bag.count("outsource") == 6,
			"权重翻倍构造8张新袋，而非每次独立按同比概率抽样")

	check(is_equal_approx(Economy.expected_supply_wait(state.config, "outsource"), 2.0 / 0.75), "BOT 按共享配额比例估计长期供应间隔")
	check(is_equal_approx(Economy.expected_supply_wait(state.config, "outsource"), Economy.expected_supply_wait(doubled.config, "outsource")), "BOT 长期供应估计不受配额整体同比扩大影响")
	check(not is_finite(Economy.expected_supply_wait(state.config, "grinder")), "升级专属牌仍不能被供应预测当作可购买商品")

func _legacy_document() -> void:
	var document := OffWorkConfig.new().balance_document()
	document.rules.conveyor.pool = {"strike":1}
	document.rules.conveyor.employee_every = 1
	document.rules.conveyor.opening = ["employee", "coffee", "overtime", "meeting", "leader", "transfer"]
	var original := var_to_bytes(document)
	var config := OffWorkConfig.new(document)
	check(config.errors.is_empty(), "旧卡表仍可载入并迁移废弃的补牌选项")
	check(var_to_bytes(document) == original, "载入迁移不改写调用者或磁盘上的旧文档")
	check(not config.rules.conveyor.has("employee_every") and not config.rules.conveyor.has("opening"), "旧参数在载入后的配置中被移除")
	check(not config.balance_document().rules.conveyor.has("employee_every") and not config.balance_document().rules.conveyor.has("opening"), "重新导出只有权重供牌参数")
	var state := OffWorkState.new(config)
	state.new_game(7913)
	check(state.offers.all(func(offer): return offer.type == "strike"), "旧固定开局不再覆盖新局权重")
	state.advance(16.0)
	check(state.offers.all(func(offer): return offer.type == "strike"), "旧每张补员工不再覆盖后续权重")
	config.rules.conveyor.employee_every = 1
	config.rules.conveyor.opening = ["employee"]
	check(not config.balance_document().rules.conveyor.has("opening") and not config.balance_document().rules.conveyor.has("employee_every"), "导出也剔除外部调用残留的废弃字段")

func _invalid_weights() -> void:
	for pool in [{}, {"employee":0}, {"employee":-1, "coffee":1}, {"coffee":0.01,"outsource":0.03}, {"employee":1.5}, {"employee":INF}, {"employee":NAN}, {"employee":1e308,"coffee":1e308}, {"grinder":1}, {"work":1}, {"money":1}]:
		var config := OffWorkConfig.new()
		config.rules.conveyor.pool = pool
		check(not config.validate() and "\n".join(config.errors).contains("conveyor.pool"), "非法、不可购或全零权重被拒绝：" + str(pool))
