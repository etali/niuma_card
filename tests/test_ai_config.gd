# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const TEMP_PATH := "user://test_ai_config_sections.json"
func _initialize() -> void:
	CardDB.ensure_loaded()
	var search := AIConfig.read_section("search")
	check(AIConfig.read_section("behavior").is_empty() and not search.has("ladder"), "旧策略配置和阶梯已移除")
	check(AISearch.default_model() == "ai" and AISearch.default_strength() == search["default_strength"], "默认实现/强度来自配置")
	check(AISearch.PRESETS == search["presets"], "命名强度与配置一致")
	var f := FileAccess.open(TEMP_PATH,FileAccess.WRITE)
	f.store_string(JSON.stringify({"search":{"default_strength":0.23,"ai":{"buy_beam":[[0,2],[0.5,5],[1,8]],"engine_horizon":4.5}}}))
	f.close()
	var old := AIConfig._source
	AIConfig._source = TEMP_PATH
	var cfg := AISearch.from_strength(0.5)
	check(cfg.get_knob("buy_beam") == 8 and cfg.get_knob("engine_horizon") == 4.5, "外置配置覆盖预算端点与浮点系数")
	check(cfg.get_knob("node_budget") == search["ai"]["node_budget"], "未提供参数沿用内置配置")
	check(AISearch.default_strength() == 0.23, "外置默认强度生效")
	var copy := AIConfig.read_section("search")
	copy["ai"]["buy_beam"][0][1] = 999
	check(AISearch.from_strength(0).get_knob("buy_beam") == 8, "外置配置返回深副本")
	var hash1 := StateCodec.table_hash()
	cfg.apply_override("node_budget",50)
	check(StateCodec.table_hash() == hash1, "AI配置与规则指纹独立")
	_write_external({"default_model":"ai","ai":{"compute_budget":240000}})
	check(AISearch.from_strength(1).get_knob("compute_budget") == 240000,"外置计算上限生效")

	AIConfig._source = old
	AIConfig.reset_cache()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))
	finish()

func _write_external(search: Dictionary) -> void:
	var file := FileAccess.open(TEMP_PATH,FileAccess.WRITE)
	file.store_string(JSON.stringify({"search":search}))
	file.close()
	AIConfig.reset_cache()
	AIConfig._source = TEMP_PATH
