# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const TEMP_PATH := "user://test_bot_config_sections.json"
func _initialize() -> void:
	OnWorkCardDB.ensure_loaded()
	var search := OnWorkBOTConfig.read_section("search")
	check(OnWorkBOTConfig.read_section("search", "res://data/bot.json") == search, "旧上班内置路径读取当前 BOT 配置")
	check(OffWorkConfig.FILES.bot == OnWorkBOTConfig.ConfigData.bundled_path("res://data/off_work_ai.json"),
		"旧下班内置路径定位到当前 BOT 配置")
	check(OnWorkBOTConfig.read_section("behavior").is_empty() and not search.has("ladder"), "旧策略配置和阶梯已移除")
	check(OnWorkBOTSearch.default_model() == "bot" and OnWorkBOTSearch.default_strength() == search["default_strength"], "默认实现/强度来自配置")
	check(OnWorkBOTSearch.PRESETS == search["presets"], "命名强度与配置一致")
	var f := FileAccess.open(TEMP_PATH,FileAccess.WRITE)
	f.store_string(JSON.stringify({"search":{"default_strength":0.23,"bot":{"buy_beam":[[0,2],[0.5,5],[1,8]],"engine_horizon":4.5}}}))
	f.close()
	var old := OnWorkBOTConfig._source
	OnWorkBOTConfig._source = TEMP_PATH
	var cfg := OnWorkBOTSearch.from_strength(0.5)
	check(cfg.get_knob("buy_beam") == 8 and cfg.get_knob("engine_horizon") == 4.5, "外置配置覆盖预算端点与浮点系数")
	check(cfg.get_knob("node_budget") == search["bot"]["node_budget"], "未提供参数沿用内置配置")
	check(OnWorkBOTSearch.default_strength() == 0.23, "外置默认强度生效")
	var copy := OnWorkBOTConfig.read_section("search")
	copy["bot"]["buy_beam"][0][1] = 999
	check(OnWorkBOTSearch.from_strength(0).get_knob("buy_beam") == 8, "外置配置返回深副本")
	var hash1 := OnWorkStateCodec.table_hash()
	cfg.apply_override("node_budget",50)
	check(OnWorkStateCodec.table_hash() == hash1, "BOT配置与规则指纹独立")
	_write_external({"default_model":"bot","bot":{"compute_budget":240000}})
	check(OnWorkBOTSearch.from_strength(1).get_knob("compute_budget") == 240000,"外置计算上限生效")

	OnWorkBOTConfig._source = old
	OnWorkBOTConfig.reset_cache()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_PATH))
	finish()

func _write_external(search: Dictionary) -> void:
	var file := FileAccess.open(TEMP_PATH,FileAccess.WRITE)
	file.store_string(JSON.stringify({"search":search}))
	file.close()
	OnWorkBOTConfig.reset_cache()
	OnWorkBOTConfig._source = TEMP_PATH
