# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _document(pool: Dictionary, legacy := false) -> Dictionary:
	var document := OffWorkConfig.new().balance_document()
	document.rules.conveyor.pool = pool.duplicate()
	if legacy: document.rules.conveyor.erase("draw_mode")
	return document

func _initialize() -> void:
	var defaults := OffWorkConfig.new()
	check(defaults.errors.is_empty(), "正式卡表通过牌袋校验")
	check(defaults.rules.conveyor.draw_mode == "shuffle_bag_v1", "正式卡表声明整袋洗牌模式")
	var expected := {"employee":4,"leader":1,"overtime":2,"coffee":2,"transfer":2,"meeting":2,"slack":1,"outsource":1,"strike":1,"union":1,"boss":1}
	check(defaults.rules.conveyor.pool.size() == expected.size() and expected.keys().all(func(kind): return defaults.rules.conveyor.pool.get(kind) == expected[kind]), "改供牌算法保留既有整数张数")
	check(OffWorkConfig.new(_document({"employee":4096})).errors.is_empty(), "4096 张整袋上限合法")
	for pool in [{}, {"employee":0}, {"employee":4096,"coffee":1}, {"employee":0.125,"coffee":1.75}, {"employee":-1,"coffee":2}, {"employee":NAN}, {"employee":INF}, {"employee":true}, {"employee":"2"}, {"work":1}, {"grinder":1}]:
		var config := OffWorkConfig.new(_document(pool))
		check(not config.errors.is_empty() and "\n".join(config.errors).contains("conveyor.pool"), "新牌袋拒绝非法张数："+str(pool))
	var wrong_mode := _document({"employee":1})
	wrong_mode.rules.conveyor.draw_mode = "weighted_v0"
	check(not OffWorkConfig.new(wrong_mode).errors.is_empty(), "新卡表不能通过版本字段启用旧的独立抽样算法")
	for example in [
		{"input":{"employee":2,"coffee":2},"expected":{"employee":2,"coffee":2}},
		{"input":{"employee":0.125,"coffee":1.75,"boss":0},"expected":{"employee":1,"coffee":14,"boss":0}},
		{"input":{"coffee":0.375},"expected":{"coffee":1}},
		{"input":{"employee":0.01,"coffee":0.03},"expected":{"employee":1,"coffee":3}},
		{"input":{"employee":1.0/3.0,"coffee":2.0/3.0},"expected":{"employee":1,"coffee":2}}]:
		var legacy := _document(example.input, true)
		var before := var_to_bytes(legacy)
		var config := OffWorkConfig.new(legacy)
		check(config.errors.is_empty() and config.rules.conveyor.pool == example.expected, "旧池以最简比例迁移，原整数池保持轮长："+str(example.input))
		check(var_to_bytes(legacy) == before, "读取旧牌袋不修改传入档案")
		var normalized := config.balance_document()
		check(OffWorkConfig.normalize_balance_document(normalized) == normalized, "再次读取新整数牌袋保持幂等")
	for pool in [{"employee":0.000000001,"coffee":1.5}, {"employee":0.5000000001,"coffee":0.5}]:
		var legacy := _document(pool, true)
		var before := var_to_bytes(legacy)
		check(not OffWorkConfig.new(legacy).errors.is_empty(), "无法在有限牌袋精确表示的旧比例被拒绝，不能丢稀有牌或近似舍入")
		check(var_to_bytes(legacy) == before, "失败迁移也保留旧档案原值")
	finish()
