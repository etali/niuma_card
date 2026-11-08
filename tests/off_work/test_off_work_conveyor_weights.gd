# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Economy = preload("res://engine/off_work_bot_economy.gd")

func _initialize() -> void:
	_single_card_pools()
	_relative_weights()
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
		var state := _world({kind: 0.01})
		check(state.last_error.is_empty() and state.offers.size() == state.config.rules.conveyor.slots, str(kind) + " 单牌权重池可正常开局")
		check(state.offers.all(func(offer): return offer.type == kind), str(kind) + " 的全部开局槽均按唯一正权重生成")
		state.advance(16.0)
		check(state.offers.all(func(offer): return offer.type == kind), str(kind) + " 的后续补牌没有额外固定员工或其他牌")
		check(is_equal_approx(Economy.expected_supply_wait(state.config, str(kind)), state.config.rules.conveyor.interval_seconds), str(kind) + " 单牌池的 BOT 到货估计与实际刷新间隔相同")
	var state := _world({"employee": 0, "outsource": 0.25})
	check(state.offers.all(func(offer): return offer.type == "outsource"), "员工零权重在开局也不会出现")
	state.advance(30.0)
	check(state.offers.all(func(offer): return offer.type == "outsource"), "员工零权重在跨越多个补牌周期后仍不出现")
	check(not is_finite(Economy.expected_supply_wait(state.config, "employee")), "BOT 不虚构零权重员工供应")
	state.config.cards.employee.purchasable = false
	state.config.rules.conveyor.pool.erase("employee")
	check(state.config.validate(), "不再强制可购买员工，剩余合法正权重牌池可独立供牌")

func _relative_weights() -> void:
	var fractional := _world({"employee":0, "coffee":0.01, "outsource":0.03})
	var scaled := _world({"employee":0, "coffee":1, "outsource":3})
	var same_sequence := fractional.offers == scaled.offers
	var counts := {"coffee":0, "outsource":0}
	for index in 6000:
		var first := fractional._new_offer()
		var second := scaled._new_offer()
		same_sequence = same_sequence and first == second
		counts[first.type] += 1
	check(same_sequence, "等比例缩放全部权重保持同种子开局与后续抽样序列一致")
	check(absf(float(counts.coffee) / 6000.0 - 0.25) < 0.025, "固定种子6000次加权抽取接近1:3比例，无固定员工混入")
	check(is_equal_approx(Economy.expected_supply_wait(fractional.config, "outsource"), 2.0 / 0.75), "BOT 按真实权重总和归一化，总和小于1也不会低估到货概率")
	check(is_equal_approx(Economy.expected_supply_wait(fractional.config, "outsource"), Economy.expected_supply_wait(scaled.config, "outsource")), "BOT 供应估计同样不受整体权重缩放影响")
	check(not is_finite(Economy.expected_supply_wait(fractional.config, "grinder")), "升级专属牌仍不能被供应预测当作可购买商品")

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
	for pool in [{}, {"employee":0}, {"employee":-1, "coffee":1}, {"employee":INF}, {"employee":NAN}, {"employee":1e308,"coffee":1e308}, {"grinder":1}, {"work":1}, {"money":1}]:
		var config := OffWorkConfig.new()
		config.rules.conveyor.pool = pool
		check(not config.validate() and "\n".join(config.errors).contains("conveyor.pool"), "非法、不可购或全零权重被拒绝：" + str(pool))
