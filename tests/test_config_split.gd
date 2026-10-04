# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const UI_TEMP := "user://test_split_ui.json"
const AI_TEMP := "user://test_split_ai.json"
const CARDS_TEMP := "user://test_split_legacy_cards.json"

func _initialize() -> void:
	print("=== 展示 / 规则 / AI 配置隔离 ===")
	var cards := _json("res://data/cards.json")
	var ui := _json("res://data/ui.json")
	var ai := _json("res://data/ai.json")
	check(not cards.has("_ai") and not cards.has("_sim") and not cards.has("_sfx"),
		"cards.json 不再重复保存 AI、模拟和音效参数")
	check(not cards["_game"].has("res_labels"), "资源名称移出牌局规则源文件")
	check(not FileAccess.file_exists("res://data/palette.json"), "旧仓库配色文件已迁走")
	check(ui.has("defaults") and ui.has("palette") and ui.has("resource_labels") and ui.has("sfx"),
		"UI 默认、配色、资源名和音效均有独立配置段")
	check(not ai.has("behavior") and ai.has("simulation") and ai.has("search"),
		"AI 配置只保存当前搜索和模拟参数")

	CardDB.reset()
	check(CardDB.load_from(CardDB.BUILTIN_PATH), "拆分后内置卡表可加载")
	check(CardDB.sim_rules() == ai["simulation"], "模拟器参数逐键等于磁盘配置")
	check(CardDB.sfx_rules() == ui["sfx"], "音效动作和文件逐键等于 UI 配置")
	check(CardDB.res_label("cash") == ui["resource_labels"]["cash"], "资源名从 UI 配置进入牌面")
	check(Palette.DEFAULTS == ui["palette"], "配色兜底直接取 UI 配置，代码无第二份色板")

	var editable_slots: Array = []
	for item in Palette._plate_items():
		if item["slot"] not in editable_slots:
			editable_slots.append(item["slot"])
	check(editable_slots.size() == 8 and "_说明" not in editable_slots and "plate_t2" not in editable_slots,
		"八种功能底板可调，说明文字与不再使用的等级槽位不生成控件")

	# 三类外置文件可以独立覆盖；不用写项目根目录或真正的玩家偏好文件。
	_write(UI_TEMP, {"defaults": {"window_fraction": 0.85},
		"palette": {"hud": {"player": "#123456"}},
		"resource_labels": {"cash": "测试资金"},
		"sfx": {"actions": {"card_pickup": {"db": -13.0}}}})
	_write(AI_TEMP, {"simulation": {"max_rounds": 9}, "search": {"default_strength": 0.2}})
	var prior_ui := UIConfig._source
	var prior_ai := AIConfig._source
	var prior_palette := Palette._cfg.duplicate(true)
	var prior_loaded := Palette._loaded
	CardDB.reset()
	UIConfig._source = UI_TEMP
	AIConfig._source = AI_TEMP
	check(CardDB.load_from(CardDB.BUILTIN_PATH), "不改 cards.json 也能加载外置 UI 和 AI")
	check(UIConfig.read_defaults()["window_fraction"] == 0.85
		and UIConfig.read_defaults()["perspective_angle"] == ui["defaults"]["perspective_angle"],
		"外置 UI 默认覆盖，未提供的角度继承内置配置")
	check(CardDB.res_label("cash") == "测试资金" and CardDB.res_label("user") == ui["resource_labels"]["user"],
		"外置资源名称支持逐键覆盖")
	var pickup: Dictionary = CardDB.sfx_rules()["actions"]["card_pickup"]
	check(pickup["db"] == -13.0 and pickup["sound"] == ui["sfx"]["actions"]["card_pickup"]["sound"],
		"外置音量覆盖仍保留原音效映射")
	check(CardDB.sim_rules()["max_rounds"] == 9 and AISearch.default_strength() == 0.2,
		"外置 AI 的模拟上限和搜索默认值实际生效")
	Palette._loaded = false
	var user_hud: Dictionary = Palette.read_json(Palette.USER_PATH).get("hud", {})
	check(Palette.get_string("hud", "player") == user_hud.get("player", "#123456"),
		"配色从 ui.json 加载，已有玩家偏好仍能覆盖")
	var changed := UIConfig.read_section("palette")
	changed["hud"]["player"] = "#FFFFFF"
	check(UIConfig.read_section("palette")["hud"]["player"] == "#123456",
		"配置返回深拷贝，调用方不会污染后续默认色")

	# 旧策略段被忽略，规则指纹不因策略参数变化；其他历史展示覆盖仍可加载。
	var rules_hash := StateCodec.table_hash()
	var legacy := cards.duplicate(true)
	legacy["_ai"] = {"seat_value": 16.0}
	legacy["_sim"] = {"max_rounds": 11}
	_write(CARDS_TEMP, legacy)
	check(CardDB.load_from(CARDS_TEMP), "旧单文件配置继续可加载")
	check(CardDB.sim_rules()["max_rounds"] == 11, "旧模拟上限仍可覆盖")
	check(StateCodec.table_hash() == rules_hash, "旧 _ai 和模拟参数不改变游戏规则指纹")
	legacy["_game"]["res_labels"] = {"cash": "旧资源名称"}
	legacy["_sfx"] = {"actions": {"card_pickup": {"db": -17.0}}}
	_write(CARDS_TEMP, legacy)
	check(CardDB.load_from(CARDS_TEMP), "旧展示覆盖仍可加载")
	check(CardDB.res_label("cash") == "旧资源名称" and CardDB.sfx_rules()["actions"]["card_pickup"]["db"] == -17.0,
		"旧资源名和音效覆盖仍然有效")
	check(CardDB.sfx_rules()["actions"]["card_pickup"]["sound"] == pickup["sound"],
		"旧格式局部音效覆盖也不会抹掉同一动作的 sound")

	_write(AI_TEMP, {"simulation": {"max_rounds": 13}})
	_write(UI_TEMP, {"resource_labels": {"cash": "重载资金"}})
	CardDB.reset()
	UIConfig._source = UI_TEMP
	AIConfig._source = AI_TEMP
	CardDB.ensure_loaded()
	check(CardDB.sim_rules()["max_rounds"] == 13 and CardDB.res_label("cash") == "重载资金",
		"CardDB.reset 重读修改后的独立配置，不会继续使用旧缓存")

	UIConfig._source = prior_ui
	AIConfig._source = prior_ai
	Palette._cfg = prior_palette
	Palette._loaded = prior_loaded
	for path in [UI_TEMP, AI_TEMP, CARDS_TEMP]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	UIConfig.reset_cache()
	AIConfig.reset_cache()
	CardDB.reset()
	CardDB.ensure_loaded()
	finish()

func _json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _write(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()
