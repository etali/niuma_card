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
	f.store_string(JSON.stringify({"search":{"default_strength":0.23,"ai":{"buy_beam":[2,5],"engine_horizon":4.5}}}))
	f.close()
	var old := AIConfig._source
	AIConfig._source = TEMP_PATH
	var cfg := AISearch.from_strength(1)
	check(cfg.get_knob("buy_beam") == 5 and cfg.get_knob("engine_horizon") == 4.5, "外置配置覆盖预算端点与浮点系数")
	check(cfg.get_knob("node_budget") == search["ai"]["node_budget"][1], "未提供参数沿用内置配置")
	check(AISearch.default_strength() == 0.23, "外置默认强度生效")
	var copy := AIConfig.read_section("search")
	copy["ai"]["buy_beam"][0] = 999
	check(AISearch.from_strength(0).get_knob("buy_beam") == 2, "外置配置返回深副本")
	var hash1 := StateCodec.table_hash()
	cfg.apply_override("node_budget",50)
	check(StateCodec.table_hash() == hash1, "AI配置与规则指纹独立")
	_write_external({"default_model":"v2","default_strength":0.31,
		"v2":{"buy_beam":[3,7],"engine_horizon":3.5}})
	var migrated := AIConfig.read_section("search")
	check(migrated.get("default_model") == "ai" and not migrated.has("v2"),
		"旧外置默认模型与v2参数段迁移为ai，不保留旧键")
	var migrated_config := AISearch.from_strength(1)
	check(migrated_config.model == "ai" and migrated_config.get_knob("buy_beam") == 7
		and migrated_config.get_knob("engine_horizon") == 3.5 and AISearch.default_strength() == 0.31,
		"旧外置配置在合并内置默认前迁移，保留预算、浮点参数与默认强度")
	check(migrated_config.get_knob("node_budget") == search["ai"]["node_budget"][1],
		"旧外置配置缺失参数仍由当前内置AI补齐")
	_write_external({"default_model":"v2","ai":{"buy_beam":[4,6]},
		"v2":{"buy_beam":[1,2],"engine_horizon":9.0}})
	var explicit_config := AISearch.from_strength(1)
	check(explicit_config.get_knob("buy_beam") == 6
		and explicit_config.get_knob("engine_horizon") == AIConfig.builtin_section("search")["ai"]["engine_horizon"],
		"新旧参数段同时存在时仅使用显式ai段，不从旧v2混入覆盖")
	check(not AIConfig.read_section("search").has("v2") and AISearch.default_model() == "ai",
		"双键配置解析后只提供当前模型和参数段")
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
