# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const CardConfigClass = preload("res://engine/card_config.gd")
const NetServerClass = preload("res://net/server.gd")

func _initialize() -> void:
	var had_pref := FileAccess.file_exists(CardConfigClass.PREF_PATH)
	var previous_pref := FileAccess.get_file_as_string(CardConfigClass.PREF_PATH) if had_pref else ""
	var base_path := "res://data/cards.json"
	var base := JSON.parse_string(FileAccess.get_file_as_string(base_path)) as Dictionary
	var temp_path := "user://test-custom-cards.json"
	var custom := base.duplicate(true)
	custom["yunketang"]["output_n"] = int(custom["yunketang"]["output_n"]) + 1
	var f := FileAccess.open(temp_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(custom))
	f.close()
	var valid := CardConfigClass.validate_file(temp_path)
	check(bool(valid.get("ok", false)), "完整自定义卡表通过校验")
	var selected := CardConfigClass.select(temp_path)
	check(bool(selected.get("ok", false)), "保存自定义卡表路径")
	var applied := CardConfigClass.apply_solo()
	check(bool(applied.get("ok", false)) and int(CardDB.get_def("yunketang")["output_n"]) == int(custom["yunketang"]["output_n"]), "单机应用自定义卡表")
	var defaulted := CardConfigClass.apply_default()
	check(bool(defaulted.get("ok", false)) and CardDB.loaded_from == CardConfigClass.DEFAULT_PATH, "恢复默认卡表")
	CardDB.load_from(temp_path)
	var server := NetServerClass.new()
	var server_result := server.start(18973)
	check(bool(server_result.get("ok", false)) and CardDB.loaded_from == CardConfigClass.DEFAULT_PATH, "联网服务器强制默认卡表")
	server.stop()
	var invalid := custom.duplicate(true)
	invalid["_game"]["win_cash"] = int(invalid["_game"]["win_cash"]) + 1
	f = FileAccess.open(temp_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(invalid))
	f.close()
	check(not CardConfigClass.validate_file(temp_path).get("ok", false), "禁止修改固定胜负规则")
	var pawn_custom := base.duplicate(true)
	pawn_custom["yunketang"]["pawn"] = 0
	pawn_custom["jiaolv"]["pawn"] = 11
	for id in pawn_custom:
		if pawn_custom[id] is Dictionary and pawn_custom[id].get("kind") == CardDB.KIND_LEGEND:
			pawn_custom[id]["pawn"] = 19
	_write_cards(temp_path, pawn_custom)
	check(CardConfigClass.validate_file(temp_path).get("ok", false), "普通卡、升级卡、传说卡出售价格均可覆盖且允许零")
	check(CardDB.load_from(temp_path) and CardDB.pawn_value("yunketang") == 0 and CardDB.pawn_value("jiaolv") == 11,
		"覆盖出售价格通过既有 CardDB 加载并实际生效")
	var state := GameState.new()
	state.new_game()
	var zero_card := state.add_card(GameState.PLAYER, "yunketang")
	var zero_sale := state.pawn(GameState.PLAYER, [zero_card["uid"]])
	check(not zero_sale.get("ok", true) and "出售价格为 0" in str(zero_sale.get("reason", "")),
		"零出售价格拒绝出售并准确说明原因")
	for bad in [-1, 0.5, "3", true, 2147483648]:
		pawn_custom["yunketang"]["pawn"] = bad
		_write_cards(temp_path, pawn_custom)
		check(not CardConfigClass.validate_file(temp_path).get("ok", false), "拒绝非法出售价格：%s" % str(bad))
	pawn_custom = base.duplicate(true)
	pawn_custom["cash"]["pawn"] = 2
	_write_cards(temp_path, pawn_custom)
	check(not CardConfigClass.validate_file(temp_path).get("ok", false), "资源卡不能增加出售价格覆盖")
	CardConfigClass.clear_selection()
	CardConfigClass.apply_default()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
	if had_pref:
		var pref := FileAccess.open(CardConfigClass.PREF_PATH, FileAccess.WRITE)
		pref.store_string(previous_pref)
		pref.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CardConfigClass.PREF_PATH))
	finish()

func _write_cards(path: String, cards: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(cards))
	file.close()
