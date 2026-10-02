# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 规则书从运行时配置生成，走真实抽屉入口验证阅读与收放。
## 数值变更仅替换进程内字典，结束前恢复，不写玩家的持久配置。
const SECTION_IDS := ["victory", "purchase", "combos", "attack", "pawn", "buffs"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 选项规则书与配置联动回归 ===")
	CardDB.ensure_loaded()
	var content: Script = load("res://scenes/rulebook_content.gd")
	if not need(content != null and content.can_instantiate(), "规则书数据模型可加载"):
		finish()
		return
	_check_configuration(content)
	for config in [[Vector2i(1280, 800), 1.0], [Vector2i(960, 600), 1.0], [Vector2i(1920, 1200), 2.0]]:
		var viewport_size: Vector2i = config[0]
		var dpi: float = config[1]
		var context := "%dx%d@%sx" % [viewport_size.x, viewport_size.y, str(dpi)]
		var main: Node = await _boot_drawer(viewport_size, dpi)
		await _check_rulebook(main, context)
		await _dispose(main)
	finish()

func _section(sections: Array, id: String) -> Dictionary:
	for section: Dictionary in sections:
		if str(section.get("id", "")) == id:
			return section
	return {}

## 只查看用户会读到的字符串，不让字典中的数字元数据代替实际说明通过判据。
func _text(value: Variant) -> String:
	if value is String:
		return value
	var parts: PackedStringArray = []
	if value is Array:
		for item in value:
			parts.append(_text(item))
	elif value is Dictionary:
		for key in value:
			if key not in ["id", "def_id", "kind", "source_id", "target_id"]:
				parts.append(_text(value[key]))
	return "\n".join(parts)

func _card_text(value: Variant, def_id: String) -> String:
	var parts: PackedStringArray = []
	if value is Dictionary:
		if str(value.get("def_id", "")) == def_id:
			parts.append(_text(value))
		for item in value.values():
			parts.append(_card_text(item, def_id))
	elif value is Array:
		for item in value:
			parts.append(_card_text(item, def_id))
	return "\n".join(parts)

func _has_number(text: String, number: String) -> bool:
	var regex := RegEx.new()
	regex.compile("(^|[^0-9.])" + number.replace(".", "\\.") + "(?:\\.0+)?([^0-9.]|$)")
	return regex.search(text) != null

func _check_configuration(content: Script) -> void:
	var original_game := CardDB.GAME
	var original_cards := CardDB.CARDS
	var original_upgrade := CardDB.UPGRADE
	var baseline: Array = content.sections()
	var baseline_combos := _text(_section(baseline, "combos"))
	check("同名或异名均可" in baseline_combos and "T1 与 T2 不得混合" in baseline_combos,
		"规则书明确传说可异名但必须同档")
	check("张数必须精确" in baseline_combos and "资源、Buff、攻击卡或传说卡" in baseline_combos,
		"规则书列明精确张数与禁止夹杂的类别")
	check("普通升级必须使用路线指定的同名 T1 卡" in baseline_combos
		and "不能混合不同卡名" not in baseline_combos, "普通升级保留同名要求，不误用于传说合成")
	check(baseline.size() == SECTION_IDS.size(), "规则书包含输赢、组合合成、攻击、典当、BUFF六章")
	for i in mini(baseline.size(), SECTION_IDS.size()):
		var section: Dictionary = baseline[i]
		check(str(section.get("id", "")) == SECTION_IDS[i]
			and not str(section.get("title", "")).is_empty()
			and not section.get("blocks", []).is_empty(), "第%d章有稳定标识、标题与可视内容" % (i + 1))

	CardDB.GAME = original_game.duplicate(true)
	CardDB.CARDS = original_cards.duplicate(true)
	CardDB.UPGRADE = original_upgrade.duplicate(true)
	CardDB.GAME["win_cash"] = 137
	CardDB.GAME["start_cash"] = 29
	CardDB.GAME["start_user"] = 31
	CardDB.GAME["market_size"] = 11
	var victory := _text(_section(content.sections(), "victory"))
	check(_has_number(victory, "137"), "资金胜利线跟随GAME.win_cash即时变化")
	check(_has_number(victory, "29") and _has_number(victory, "31") and _has_number(victory, "11"),
		"开局资源与公共区卡位数均跟随配置")

	CardDB.CARDS["yunketang"]["recipe_n"] = 41
	CardDB.CARDS["yunketang"]["output_n"] = 43
	var combos: Dictionary = _section(content.sections(), "combos")
	var recipe := _card_text(combos, "yunketang")
	check(_has_number(recipe, "41") and _has_number(recipe, "43"),
		"同一张产品卡的配方消耗与产出来自当前卡表")

	CardDB.GAME["attack_cost_per_card"] = 59
	CardDB.CARDS["butie"]["recipe_n"] = 37
	CardDB.CARDS["butie"]["attack_n"] = 47
	var attack: Dictionary = _section(content.sections(), "attack")
	check(_has_number(_text(attack), "59"), "每张目标卡的攻击消耗跟随GAME.attack_cost_per_card")
	var attack_card := _card_text(attack, "butie")
	check(_has_number(attack_card, "37") and _has_number(attack_card, "47"),
		"攻击卡配方与攻击量来自当前卡表")

	CardDB.GAME["buff_mult"]["output_x2"] = 113
	CardDB.GAME["buff_mult"]["attack_x2"] = 127
	var buffs := _text(_section(content.sections(), "buffs"))
	check("入组立即保护" in buffs and "这一回合尚不提供保护" not in buffs
		and "从下一回合起" not in buffs, "规则书明确防御入组立即保护且无首回合等待说明")
	check(_has_number(buffs, "113") and _has_number(buffs, "127"),
		"BUFF产出与攻击倍率跟随GAME.buff_mult")

	CardDB.GAME["pawn_rate"] = 61.0
	CardDB.GAME["pawn_user"] = 67
	CardDB.CARDS["dujiaoshou"]["pawn"] = 173
	var pawn := _text(_section(content.sections(), "pawn"))
	check(_has_number(pawn, "61") and _has_number(pawn, "67") and _has_number(pawn, "173"),
		"典当折价、用户回收和传说固定回收价均跟随配置")

	# 改同档T1折算路线与传说档位；只检查实际可达路线，不复制合成算法。
	for route: Dictionary in CardDB.UPGRADE["routes"]:
		if route.get("kind", "") == CardDB.KIND_PRODUCT and int(route.get("tier", -1)) == 1 \
			and route.get("key", "") == "dup_key":
			route["per"] = 3
	CardDB.CARDS["dujiaoshou"]["upgrade_dup_n"] = 5
	var paths: Array = content.upgrade_paths("yunketang")
	var changed_route := false
	for path: Dictionary in paths:
		if str(path.get("target_id", "")) == "dujiaoshou" and int(path.get("count", 0)) == 15 and not path["same_name"]:
			changed_route = true
	check(changed_route, "传说合成路线联动UPGRADE折算率和卡表张数，材料标为可异名")
	combos = _section(content.sections(), "combos")
	check(_has_number(_text(combos), "15"), "变更后的合成张数进入可见规则文字")

	CardDB.GAME = original_game
	CardDB.CARDS = original_cards
	CardDB.UPGRADE = original_upgrade
	check(content.sections() == baseline, "恢复内存配置后规则书完整恢复且不残留缓存")

func _boot_drawer(viewport_size: Vector2i, dpi: float) -> Node:
	paused = false
	root.size = viewport_size
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	main.drawer_ui_scale = dpi
	root.add_child(main)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.board.input_locked = false
	main.sfx.set_muted(true)
	await _layout(main)
	return main

func _layout(main: Node) -> void:
	main.drawer_presentation.relayout()
	for i in 3:
		await process_frame
	main.drawer_presentation.relayout()
	await process_frame

func _check_rulebook(main: Node, context: String) -> void:
	var presentation: Node = main.drawer_presentation
	var menu: MenuButton = presentation._menu
	var popup := menu.get_popup()
	check(menu.text.is_empty() and menu.find_child("IconGlyph", true, false) != null and menu.tooltip_text == "选项", "%s：选项入口使用齿轮线稿图标" % context)
	check(menu.get_meta("drawer_icon_button", false) and menu.get_theme_stylebox("normal") is StyleBoxEmpty, "%s：齿轮按钮无外边框" % context)
	check(popup.get_item_index(7) == -1 and popup.get_item_index(8) >= 0,
		"%s：选项提供读入录像，规则书移到主操作旁" % context)
	var existing := {0: "配色", 1: "AI 强度", 2: "提示记录", 3: "UI",
		4: "入口大小", 5: "存录像", 6: "局域网对战", 8: "读入录像", 9: "卡牌配置"}
	var old_routes_intact := popup.get_item_count() == existing.size()
	for id in existing:
		var index := popup.get_item_index(id)
		old_routes_intact = old_routes_intact and index >= 0 and popup.get_item_text(index) == existing[id]
	check(old_routes_intact, "%s：原有工具页名称与业务ID保持可达" % context)
	presentation._rulebook_button.pressed.emit()
	await _layout(main)
	var book: Control = presentation.get("_rulebook")
	if not need(is_instance_valid(book), "%s：选项入口创建并绑定规则书视图" % context):
		return
	var rulebook_button: Button = presentation._rulebook_button
	check(rulebook_button.get_parent() == main.btn_pass.get_parent()
		and rulebook_button.get_index() == main.btn_pass.get_index() - 1,
		"%s：规则书位于完成行动左侧" % context)
	check(presentation.find_child("OptionTabs", true, false) == null,
		"%s：所有选项页都没有重复页签导航" % context)
	check(presentation.panels_open() and presentation._utility_title.text == "规则书",
		"%s：真实工具面板显示规则书标题" % context)
	check(book.sections.size() == SECTION_IDS.size() and book.section_buttons.size() == SECTION_IDS.size()
		and book.current_section == 0, "%s：默认打开输赢章并提供全部章节导航" % context)
	check(not main.board._interaction_is_blocked() and main._drawer_can_collapse(),
		"%s：阅读规则不阻止牌桌交互与抽屉收起" % context)
	var scroll: ScrollContainer = book.find_child("RulebookScroll", true, false)
	var page: VBoxContainer = book.find_child("SectionContent", true, false)
	if not need(scroll != null and page != null, "%s：章节正文使用可滚动阅读区" % context):
		return
	for i in SECTION_IDS.size():
		var button: Button = book.section_buttons[i]
		button.pressed.emit()
		await _layout(main)
		check(book.current_section == i and button.button_pressed,
			"%s：点击第%d章切换真实牌桌演示" % [context, i + 1])
		_check_bounds(presentation._utility, "%s第%d章面板" % [context, i + 1])
		_check_bounds(book, "%s第%d章规则视图" % [context, i + 1])
		check(book.demo._stage.board != null and book.demo._viewport.own_world_3d,
			"%s：演示使用隔离的真实3D牌桌" % context)
		check(page.get_child_count() == 1 and page.get_child(0) == book.demo,
			"%s：规则书没有配方文字区块或展开按钮" % context)
	for button: Button in book.section_buttons:
		_check_bounds(button, "%s章节导航%s" % [context, button.text])
		check(button.is_visible_in_tree(), "%s：规则书自身章节导航保持可见" % context)
	book.select_section(1)
	await _layout(main)
	scroll.scroll_vertical = ceili(scroll.get_v_scroll_bar().max_value)
	await process_frame
	var previous_scroll := scroll.scroll_vertical
	main.drawer_window.collapse_now()
	check(not presentation._utility.visible and not main.drawer_window.is_expanded(),
		"%s：收起抽屉同步隐藏规则书" % context)
	main.drawer_window.pin()
	await _layout(main)
	check(presentation.get("_rulebook") == book and presentation._utility.is_visible_in_tree()
		and book.current_section == 1 and scroll.scroll_vertical == previous_scroll,
		"%s：展开恢复同一本规则书、章节与滚动位置" % context)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	main._input(escape)
	await process_frame
	check(not presentation.panels_open() and main.drawer_window.is_expanded(),
		"%s：Esc关闭规则书且保持抽屉展开" % context)
	presentation._open_utility(0)
	await _layout(main)
	check(rulebook_button.is_visible_in_tree(), "%s：规则书独立入口始终可达" % context)
	rulebook_button.pressed.emit()
	await _layout(main)
	check(presentation._utility_title.text == "规则书" and is_instance_valid(presentation.get("_rulebook"))
		and presentation.find_child("OptionTabs", true, false) == null, "%s：规则书没有重复选项入口" % context)
	presentation.close_panels()

func _check_bounds(control: Control, context: String) -> void:
	check(Rect2(Vector2.ZERO, Vector2(root.size)).grow(1.0).encloses(control.get_global_rect()),
		"%s：完整留在当前窗口内" % context)

func _dispose(main: Node) -> void:
	paused = false
	main.queue_free()
	for i in 3:
		await process_frame
