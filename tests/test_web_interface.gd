# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const BrowserFiles = preload("res://scenes/web_files.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280, 800)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_web_layout = true
	root.add_child(main)
	_booted = main
	await settle()
	check(main.web_mode and not main.mobile_mode and main.drawer_window == null,
		"桌面Web使用独立平台模式，不创建原生抽屉或伪装触屏")
	check(main.drawer_presentation != null and main._uses_fitted_table(), "Web复用完整牌桌展示")
	var pane: Node = main.drawer_presentation
	check(pane._handle == null and pane._pin == null, "Web不创建依赖原生窗口的拉手和钉住控件")
	check(pane._rulebook_button != null and pane._sound_button != null, "Web提供规则书和声音入口")
	var menu: PopupMenu = pane._menu.get_popup()
	check(menu.get_item_index(8) >= 0 and menu.get_item_index(9) >= 0 and menu.get_item_index(4) < 0,
		"Web菜单提供读入录像和卡牌配置，隐藏桌面入口大小")
	pane._rulebook_button.pressed.emit()
	check(pane._utility.visible and pane._rulebook != null, "Web规则书按钮打开共享规则内容")
	pane.close_panels()

	var original_state: GameState = main.state
	var original_rules := StateCodec.table_hash()
	menu.id_pressed.emit(9)
	var choose := _button(pane, "选择 cards.json")
	main.web_files.request_backend = func(callback): callback.call(["bad.json", "{", ""])
	choose.pressed.emit()
	check(pane._card_config_status.text.contains("JSON") and main.state == original_state
		and StateCodec.table_hash() == original_rules, "浏览器导入损坏JSON明确失败并保留原局规则")
	var custom: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CardConfig.DEFAULT_PATH))
	custom["yunketang"]["price"] += 1
	main.web_files.request_backend = func(callback): callback.call(["cards.json", JSON.stringify(custom), ""])
	choose.pressed.emit()
	check(CardConfig.selected_path().ends_with("cards.json") and pane._card_config_path.text == "cards.json"
		and not main.find_child("CardConfigFileDialog", true, false),
		"Web导入走浏览器文件内容，持久存储配置而非创建原生路径对话框")
	check(main.state == original_state and StateCodec.table_hash() == original_rules, "导入选择不会热换当前牌局规则")
	_button(pane, "应用并重开").pressed.emit()
	await process_frame
	check(main.state != original_state and StateCodec.table_hash() != original_rules,
		"真实菜单应用导入配置后开始使用新规则的新局")
	menu.id_pressed.emit(9)
	check(pane._card_config_status.text == "当前生效：cards.json",
		"Web当前生效文案保留文件名，隐藏userfs内部目录与导入内容哈希")
	pane.close_panels()

	var exported: Array = []
	main.web_files.download_backend = func(bytes, filename, mime):
		exported.append({"text": bytes.get_string_from_utf8(), "filename": filename, "mime": mime})
		return true
	menu.id_pressed.emit(5)
	_button(pane, "下载当前录像").pressed.emit()
	check(exported.size() == 1 and exported[0]["filename"].ends_with(".json")
		and exported[0]["mime"] == "application/json", "Web存录像菜单发出真实JSON下载内容与文件名")
	check(not main.save_notice.visible and main.lbl_msg.text.contains("下载"), "Web下载提示不冒充可访问的本地文件路径")
	var payload: Dictionary = JSON.parse_string(exported[0]["text"])
	check(Tape.from_dict(payload).get("ok", false), "浏览器下载内容符合正式录像格式")
	main.web_files.request_backend = func(callback): callback.call(["replay.json", exported[0]["text"], ""])
	menu.id_pressed.emit(8)
	for i in 5:
		await process_frame
	main = _current_main()
	_booted = main
	check(main != null and main.replay_session != null and main.web_mode and main.drawer_window == null,
		"下载录像可经浏览器导入入口真正切换为Web回放场景")
	await _check_replay_settings(main)
	main.btn_resign.pressed.emit()
	for i in 5:
		await process_frame
	main = _current_main()
	check(main != null and main.replay_session == null and main.web_mode and main.drawer_presentation != null,
		"退出回放后仍使用Web共享界面并恢复正常新局")
	_check_file_boundaries()
	finish()

func _button(pane: Node, text: String) -> Button:
	for button in pane._utility_body.find_children("*", "Button", true, false):
		if button.text == text:
			return button
	return null

func _current_main() -> Node:
	for child in root.get_children():
		if child is Node3D and child.get("board") != null:
			return child
	return null

func _check_replay_settings(main: Node) -> void:
	var pane: Node = main.drawer_presentation
	pane._menu.get_popup().id_pressed.emit(9)
	var state: GameState = main.state
	var fingerprint := StateCodec.state_hash(state)
	var rules := StateCodec.table_hash()
	var selection := CardConfig.selected_path()
	check(_button(pane, "选择 cards.json").disabled and _button(pane, "使用默认").disabled
		and _button(pane, "应用并重开").disabled and pane._card_config_status.text.contains("退出录像"),
		"真实录像菜单禁用三个配置操作，并明确说明退出录像后再修改")
	# UI禁用之外保留业务入口保护，防快捷路径或迟到文件选择回调绕过。
	check(not main.choose_card_config(CardConfig.DEFAULT_PATH).get("ok", true)
		and not main.clear_card_config().get("ok", true)
		and not main.apply_selected_card_config().get("ok", true), "回放期间配置业务入口均明确拒绝")
	_button(pane, "应用并重开").pressed.emit()
	check(main.state == state and main.state == main.replay_session.state
		and StateCodec.state_hash(state) == fingerprint and StateCodec.table_hash() == rules
		and CardConfig.selected_path() == selection and main.board.input_locked
		and main.btn_pass.text == "录像下一步", "配置操作不会让回放状态、规则、输入锁或按钮混入新局")
	pane.close_panels()

func _check_file_boundaries() -> void:
	var bridge := BrowserFiles.new()
	root.add_child(bridge)
	var pending: Array = []
	var results: Array = []
	bridge.request_backend = func(callback): pending.append(callback)
	bridge.request_json(func(result): results.append(result))
	bridge.request_json(func(result): results.append(result))
	check(results.size() == 1 and not results[0].get("ok", true), "已有文件选择时不会覆盖等待回调")
	pending[0].call(["", "", "cancelled"])
	check(results.size() == 2 and results[1].get("cancelled", false), "取消浏览器选择正常释放等待状态")
	var first := BrowserFiles.import_json("cards.json", "{\"a\":1}")
	var second := BrowserFiles.import_json("cards.json", "{\"a\":2}")
	check(first["path"] != second["path"] and FileAccess.get_file_as_string(first["path"]).contains("1"),
		"重复导入同名不同内容不会覆盖仍被选择的旧配置")
	check(not BrowserFiles.import_json("bad.txt", "{}").get("ok", true)
		and not BrowserFiles.import_json("bad.json", "[]").get("ok", true), "拒绝错误扩展名与非对象文件")
