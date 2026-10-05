# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const TEMP_PATH := "user://test_bot_config_sections.json"
func _initialize() -> void:
	CardDB.ensure_loaded()
	var search := BOTConfig.read_section("search")
	check(BOTConfig.read_section("behavior").is_empty() and not search.has("ladder"), "旧策略配置和阶梯已移除")
	check(BOTSearch.default_model() == "bot" and BOTSearch.default_strength() == search["default_strength"], "默认实现/强度来自配置")
	check(BOTSearch.PRESETS == search["presets"], "命名强度与配置一致")
	var f := FileAccess.open(TEMP_PATH,FileAccess.WRITE)
	f.store_string(JSON.stringify({"search":{"default_strength":0.23,"bot":{"buy_beam":[[0,2],[0.5,5],[1,8]],"engine_horizon":4.5}}}))
	f.close()
	var old := BOTConfig._source
	BOTConfig._source = TEMP_PATH
	var cfg := BOTSearch.from_strength(0.5)
	check(cfg.get_knob("buy_beam") == 8 and cfg.get_knob("engine_horizon") == 4.5, "外置配置覆盖预算端点与浮点系数")
	check(cfg.get_knob("node_budget") == search["bot"]["node_budget"], "未提供参数沿用内置配置")
	check(BOTSearch.default_strength() == 0.23, "外置默认强度生效")
	var copy := BOTConfig.read_section("search")
	copy["bot"]["buy_beam"][0][1] = 999
	check(BOTSearch.from_strength(0).get_knob("buy_beam") == 8, "外置配置返回深副本")
	var hash1 := StateCodec.table_hash()
	cfg.apply_override("node_budget",50)
	check(StateCodec.table_hash() == hash1, "BOT配置与规则指纹独立")
	_write_external({"default_model":"bot","bot":{"compute_budget":240000}})
	check(BOTSearch.from_strength(1).get_knob("compute_budget") == 240000,"外置计算上限生效")

	BOTConfig._source = old
	BOTConfig.reset_cache()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))
	finish()

func _write_external(search: Dictionary) -> void:
	var file := FileAccess.open(TEMP_PATH,FileAccess.WRITE)
	file.store_string(JSON.stringify({"search":search}))
	file.close()
	BOTConfig.reset_cache()
	BOTConfig._source = TEMP_PATH
