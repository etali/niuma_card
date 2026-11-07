# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	var config := OffWorkConfig.new()
	if not need(config.errors.is_empty(), "完整算法参数配置能够载入"):
		print(config.errors)
		finish()
		return
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/off_work_bot.json"))
	var defaults: Dictionary = document.compatibility.algorithm_defaults
	var specs := {}
	for knob in document.preferences.knobs:
		if defaults.has(knob.key): specs[knob.key] = knob
	check(not defaults.is_empty() and defaults.size() == specs.size(), "每个算法历史默认值都有公开可调规格")
	for key in defaults:
		var spec: Dictionary = specs[key]
		check(config.rules.bot[key] == document.bot[key], "%s 使用当前配置值" % key)
		check(config.bot_algorithm_defaults[key] == defaults[key], "%s 历史默认值来自配置" % key)
		for value in [spec.min, spec.max]:
			config.rules.bot[key] = value
			check(config.validate(), "%s 接受配置边界 %s" % [key,value])
		for value in [float(spec.min) - 1.0, float(spec.max) + 1.0, "1", null, INF, NAN]:
			config.rules.bot[key] = value
			check(not config.validate(), "%s 拒绝非法值 %s" % [key,value])
		if spec.kind == "int":
			config.rules.bot[key] = float(spec.min) + 0.5
			check(not config.validate(), "%s 拒绝非整数" % key)
		config.rules.bot[key] = document.bot[key]
	_test_archived_documents(config, document, defaults)
	_test_imported_schema(config, document, defaults)
	finish()

func _test_archived_documents(config: OffWorkConfig, document: Dictionary, defaults: Dictionary) -> void:
	var archived := document.duplicate(true)
	archived.erase("compatibility")
	for key in defaults: archived.bot.erase(key)
	archived.preferences.knobs = archived.preferences.knobs.filter(func(knob): return not defaults.has(knob.key))
	for budget_mode in ["ratio", "fixed", "legacy"]:
		var old := archived.duplicate(true)
		if budget_mode != "ratio": old.bot.erase("decision_budget_ratio")
		if budget_mode == "fixed": old.bot.decision_budget_ms = 7
		var original := JSON.stringify(old)
		var restored := OffWorkConfig.new(config.balance_document(), old)
		check(restored.errors.is_empty(), "%s 旧文档补齐算法后能通过校验" % budget_mode)
		var restored_specs := {}
		for spec in restored.bot_preferences.knobs: restored_specs[spec.key] = spec
		for key in defaults:
			check(restored.rules.bot[key] == defaults[key] and restored_specs.has(key), "%s 缺少%s时同时补齐数值与编辑规格" % [budget_mode,key])
		check(JSON.stringify(old) == original, "%s 归档输入没有被修改" % budget_mode)
		if budget_mode == "ratio":
			check(restored.rules.bot.decision_budget_ratio == document.bot.decision_budget_ratio and not restored.rules.bot.has("decision_budget_ms"), "比例预算原样保留")
		else:
			check(restored.rules.bot.decision_budget_ms == (7 if budget_mode == "fixed" else 12) and not restored.rules.bot.has("decision_budget_ratio"), "%s 预算不漂移" % budget_mode)

func _test_imported_schema(config: OffWorkConfig, document: Dictionary, defaults: Dictionary) -> void:
	var current := document.duplicate(true)
	current.bot.material_batch_limit = 32
	current.bot.tree_horizon_work_cycles = 7
	current.compatibility.algorithm_defaults.material_batch_limit = 999
	current.preferences.knobs = []
	var edited := OffWorkConfig.new(config.balance_document(), current)
	check(edited.errors.is_empty(), "新参数显式修改可以载入")
	check(edited.rules.bot.material_batch_limit == 32 and edited.rules.bot.tree_horizon_work_cycles == 7, "修改后的算法数值保持原值")
	check(edited.bot_algorithm_defaults.material_batch_limit == defaults.material_batch_limit, "导入文档不能修改历史默认值")
	var original := JSON.stringify(current)
	current.bot.erase("material_batch_limit")
	var old := OffWorkConfig.new(config.balance_document(), current)
	check(old.rules.bot.material_batch_limit == defaults.material_batch_limit, "缺失字段不借用导入文档篡改的历史默认值")
	current.bot.material_batch_limit = 32
	check(JSON.stringify(current) == original, "加载补齐未修改外部文档")
	current.bot.material_batch_limit = 0
	check(not OffWorkConfig.new(config.balance_document(), current).errors.is_empty(), "删除knobs不能绕过数值下限")
	current.preferences.knobs = [{"key":"material_batch_limit", "label":"自定义", "kind":"float", "min":-100, "max":1.0e30, "step":0.1}]
	current.bot.material_batch_limit = 1.5
	check(not OffWorkConfig.new(config.balance_document(), current).errors.is_empty(), "伪造knobs不能取消整数限制")
	current.bot.material_batch_limit = 100000000
	check(not OffWorkConfig.new(config.balance_document(), current).errors.is_empty(), "伪造knobs不能扩大边界")
