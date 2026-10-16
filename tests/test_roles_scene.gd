# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

## 开局角色在真实牌桌上的判据（README.md §「2.12 角色」）：
## 底栏角色按钮与上弹的角色面板、应用并重开、再战一局沿用、读数里的角色短名、
## 本方卡面按角色念数而对手不念、拖「给我」买牌、专属卡拖去典当的提示。
##
## 变异提示：
##   main._new_solo_state 不读 RolePref                → 第 2 组「应用后坐上该角色」红
##   _on_restart 改回 GameState.new()                    → 第 2 组「再战一局沿用」红
##   TableActions.spawn_card 不调 apply_rule_mods        → 第 4 组「本方墨团」红
##   Board._group_progress 改回读卡面 recipe_n           → 第 4 组「编组进度」红
##   Board.card_mods 不看 draggable                      → 第 4 组「对手的牌念原值」红

var main: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 开局角色：牌桌集成 ===\n")
	RolePref.reload()
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "启动正式牌桌"):
		finish()
		return
	main.drawer_presentation._learning_invitation.hide()
	await test_role_page()
	await test_apply_and_restart()
	await test_grab_on_table()
	await test_role_badges()
	await test_special_pawn()
	RolePref.select(Roles.DEFAULT)
	finish()

func _role_with(key: String) -> String:
	for id in Roles.ids():
		if not Roles.get_def(id).get(key, {}).is_empty() or (key == "start_cards" and not Roles.start_cards(id).is_empty()):
			return id
	return ""

func _role_with_card(kind: String) -> String:
	for id in Roles.ids():
		for def_id in Roles.start_cards(id):
			if CardDB.special_type(def_id) == kind:
				return id
	return ""

func _entity_of(def_id: String) -> CardEntity:
	for c in main.state.players[main.my_seat]["cards"]:
		if c["def_id"] == def_id and main.entities.has(c["uid"]):
			return main.entities[c["uid"]]
	return null


func test_role_page() -> void:
	print("【1】底栏的角色按钮")
	check(main.state.role_of(main.my_seat) == Roles.DEFAULT, "首次启动坐默认角色")
	check(main.lbl_player_res.text.begins_with("你的公司 · "), "默认角色的读数不带角色短名：%s" % main.lbl_player_res.text)
	var page: Node = main.drawer_presentation
	if not need(page != null, "抽屉界面存在"):
		return
	var popup_menu: PopupMenu = page._menu.get_popup()
	var in_options := false
	for i in popup_menu.item_count:
		in_options = in_options or popup_menu.get_item_text(i) == "角色"
	check(not in_options, "选项菜单里不再有角色页")
	var button: Button = page._role_button
	var rulebook: Button = page._rulebook_button
	if not need(button != null and button.is_visible_in_tree(), "底栏有角色按钮"):
		return
	check(button.text == Roles.tag(Roles.DEFAULT) and not button.disabled, "默认显示短名「%s」且可点" % button.text)
	check(button.get_parent() == rulebook.get_parent() and button.get_index() == rulebook.get_index() - 1
		and button.get_global_rect().end.x <= rulebook.get_global_rect().position.x,
		"紧挨在「怎么玩」左边")
	check(button.tooltip_text == "", "按钮不挂原生长提示（角色效果在弹出面板里看）")
	button.pressed.emit()
	await process_frame
	var popup: PopupPanel = page._role_popup
	check(popup.visible and page.panels_open(), "点击弹出角色面板")
	var choices: Array = popup.find_child("RoleChoices", true, false).get_children()
	check(choices.size() == Roles.ids().size(), "面板里是全部 %d 个角色" % Roles.ids().size())
	var names: Array = choices.map(func(b): return b.text)
	check(names == Roles.ids().map(func(id): return Roles.role_name(id)), "按配置顺序列出：%s" % "、".join(names))
	check(choices[0].button_pressed and choices.slice(1).all(func(b): return not b.button_pressed), "当前角色是选中态")
	var title: Label = page._role_detail_title
	var detail: Label = page._role_detail_text
	check(title.text == Roles.role_name(Roles.DEFAULT) and detail.text.contains(Roles.describe(Roles.DEFAULT)[0]),
		"说明区默认讲当前角色")
	var boss_id: String = Roles.ids()[1]
	choices[1].mouse_entered.emit()
	check(title.text == Roles.role_name(boss_id) and detail.text.contains(Roles.describe(boss_id)[1]),
		"悬停一项，说明区换成它的效果：%s" % detail.text.replace("\n", " / "))
	# 样式与抽屉其他面板一致：同一底色、同一套字号令牌，不用原生 tooltip 的小字
	var frame: StyleBoxFlat = popup.get_theme_stylebox("panel")
	var utility_frame: StyleBoxFlat = page._utility.get_theme_stylebox("panel")
	check(frame.bg_color.is_equal_approx(utility_frame.bg_color) and frame.border_color.is_equal_approx(utility_frame.border_color),
		"面板底色和描边与设置页相同")
	var body_size: int = page._responsive_font(page.UI_FONT_BODY)
	check(detail.get_theme_font_size("font_size") == body_size and title.get_theme_font_size("font_size") > body_size
		and choices[0].get_theme_font_size("font_size") == rulebook.get_theme_font_size("font_size"),
		"说明用正文字号 %d、标题更大，角色按钮与底栏按钮同字号" % body_size)
	var top: float = button.get_screen_position().y
	check(popup.position.y + popup.size.y <= top + 0.5 and popup.position.y >= 0,
		"面板向上弹出，底边不压住按钮（面板 %d..%d，按钮顶 %.0f）" % [popup.position.y, popup.position.y + popup.size.y, top])
	# 逐个悬停：每个角色的说明都放得下，面板也不跟着变大小
	var panel_size := popup.size
	var fits_all := true
	var most_lines := 0
	for b in choices:
		b.mouse_entered.emit()
		await process_frame
		most_lines = maxi(most_lines, detail.get_line_count())
		fits_all = fits_all and detail.get_line_count() * detail.get_line_height() <= detail.size.y + 1.0
	check(fits_all and popup.size == panel_size,
		"每个角色的说明都完整放进说明区，悬停切换时面板不变大小（最多 %d 行）" % most_lines)
	var hr := _role_with("recipe_mult")
	var hr_button: Button = popup.find_child("Role_" + hr, true, false)
	hr_button.pressed.emit()
	await settle()
	check(not popup.visible and main.state.role_of(main.my_seat) == hr and RolePref.selected() == hr,
		"选中后收起面板，开新单机局并坐上该角色")
	check(button.text == Roles.tag(hr), "按钮变成「%s」" % button.text)
	check(main.lbl_msg.text.contains(Roles.role_name(hr)), "底栏提示切换结果：%s" % main.lbl_msg.text)
	button.pressed.emit()
	await process_frame
	hr_button = popup.find_child("Role_" + hr, true, false)
	check(hr_button.button_pressed and page._role_detail_title.text == Roles.role_name(hr),
		"再打开面板时选中态和说明都在新角色上")
	var before: GameState = main.state
	hr_button.pressed.emit()
	await settle()
	check(main.state == before and not popup.visible, "选当前角色只收起面板，不重开")
	button.pressed.emit()
	await process_frame
	page.close_panels()
	check(not popup.visible, "关闭面板时收起角色面板")
	# 教程换上教学局面（双方默认角色）：按钮仍念玩家自己的角色，但锁住不让切
	if need(page.start_tutorial("income"), "开始教程"):
		await settle()
		check(button.disabled and button.text == Roles.tag(hr) and not button.is_visible_in_tree(),
			"教程中按钮锁住并让出底栏位置（显示「%s」）" % button.text)
		button.pressed.emit()
		await process_frame
		check(not popup.visible, "教程中点击不弹列表")
		page.finish_tutorial()
		await settle()
		check(not button.disabled and button.is_visible_in_tree() and button.text == Roles.tag(hr)
			and main.state.role_of(main.my_seat) == hr, "教程结束后回到原局，按钮恢复可点")
	# 竖屏（游戏只按横屏设计，Web 被竖着拿时兜底）：底栏放不下就藏起按钮，改由选项菜单打开同一个面板
	var wide := root.size
	root.min_size = Vector2i.ZERO
	root.size = Vector2i(390, 844)
	await relayout_drawer(main)
	var screen := Rect2(Vector2.ZERO, Vector2(root.size)).grow(1)
	var options: PopupMenu = page._menu.get_popup()
	var item := options.get_item_index(page.UTILITY_ROLE)
	check(not button.is_visible_in_tree() and item >= 0 and options.get_item_text(item) == "角色：" + Roles.tag(hr),
		"窄屏底栏放不下：按钮让位，选项菜单出现「%s」" % (options.get_item_text(item) if item >= 0 else "（无）"))
	var footer_fits := true
	for control in page._footer.find_children("*", "Button", true, false):
		if control.is_visible_in_tree():
			footer_fits = footer_fits and screen.encloses(control.get_global_rect())
	check(footer_fits, "窄屏底栏按钮都在屏幕内")
	options.id_pressed.emit(page.UTILITY_ROLE)
	await process_frame
	check(popup.visible and screen.encloses(Rect2(popup.position, popup.size)), "从选项菜单打开角色面板，整张在屏幕内")
	# 窄屏可能并排也可能上下排（取决于角色名多长），判据只看结果：放得下、说明不被截断
	var narrow_text: Label = page._role_detail_text
	var narrow_ok := true
	for b in popup.find_child("RoleChoices", true, false).get_children():
		b.mouse_entered.emit()
		await process_frame
		narrow_ok = narrow_ok and narrow_text.get_line_count() * narrow_text.get_line_height() <= narrow_text.size.y + 1.0 \
			and screen.encloses(Rect2(popup.position, popup.size))
	check(narrow_ok, "窄屏每个角色的说明都完整显示，面板不出屏（面板 %s）" % Rect2(popup.position, popup.size))
	page.close_panels()
	page.close_panels()
	# 主流横屏手机：短名下每个角色的按钮都留在底栏（最长的「产品经理」也放得下）
	root.size = Vector2i(667, 375)
	# 按按钮实际字体量宽度挑最宽的短名：「BOSS」和「产品经理」字数相同，中文更宽
	var font: Font = button.get_theme_font("font")
	var font_size: int = button.get_theme_font_size("font_size")
	var longest: String = Roles.DEFAULT
	for id in Roles.ids():
		if font.get_string_size(Roles.tag(id), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x \
				> font.get_string_size(Roles.tag(longest), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x:
			longest = id
	main.apply_role(longest)
	await settle()
	await relayout_drawer(main)
	check(button.is_visible_in_tree() and button.text == Roles.tag(longest)
		and Rect2(Vector2.ZERO, Vector2(root.size)).grow(1).encloses(main.btn_pass.get_global_rect())
		and page._menu.get_popup().get_item_index(page.UTILITY_ROLE) < 0,
		"667×375 横屏：最长的短名「%s」也留在底栏，「完成行动」仍在屏幕内" % button.text)
	main.apply_role(hr)
	await settle()
	# 横屏手机：高度不够一列竖排，角色按钮改成两列
	root.size = Vector2i(844, 390)
	await relayout_drawer(main)
	button.pressed.emit()
	await process_frame
	var screen_low := Rect2(Vector2.ZERO, Vector2(root.size)).grow(1)
	check(popup.visible and screen_low.encloses(Rect2(popup.position, popup.size))
		and popup.position.y + popup.size.y <= button.get_screen_position().y + 0.5
		and popup.find_child("RoleChoices", true, false).columns == 2,
		"横屏手机：角色按钮排两列，面板在按钮上方且整张在屏幕内（面板 %s，按钮顶 %.0f，%d 列，%s）" % [
			Rect2(popup.position, popup.size), button.get_screen_position().y,
			popup.find_child("RoleChoices", true, false).columns, popup.find_child("RolePicker", true, false).get_class()])
	page.close_panels()
	root.size = wide
	await relayout_drawer(main)
	check(button.is_visible_in_tree() and page._menu.get_popup().get_item_index(page.UTILITY_ROLE) < 0,
		"宽屏恢复底栏按钮，选项菜单里的替身入口撤掉")


func test_apply_and_restart() -> void:
	print("\n【2】应用并重开 / 再战一局")
	var boss := _role_with_card(CardDB.SPECIAL_GRAB)
	var before: GameState = main.state
	var r: Dictionary = main.apply_role(boss)
	await settle()
	check(r.get("ok", false) and main.state != before, "应用后开新单机局：%s" % r.get("reason", ""))
	check(main.state.role_of(main.my_seat) == boss and RolePref.selected() == boss, "应用后坐上该角色，选择存进偏好")
	check(main.state.role_of(main.foe_seat) == Roles.DEFAULT, "对手仍是默认角色")
	check(main.lbl_player_res.text.contains("（%s）" % Roles.tag(boss)), "读数带角色短名：%s" % main.lbl_player_res.text)
	# 抽屉布局把旧资源卡换成首行读数，资源卡节点在那里已经释放
	if is_instance_valid(main.hud_player_card):
		check(main.hud_player_card.title.text.contains(Roles.tag(boss)), "资源卡标题带角色短名")
	main._on_restart()
	await settle()
	check(main.state.role_of(main.my_seat) == boss, "再战一局沿用同一角色")
	check(main.role_info()["active"] == boss and not main.role_info()["network_locked"], "角色页读数：这一局的角色、单机未锁")


func test_grab_on_table() -> void:
	print("\n【3】拖「给我」到购牌区")
	var grab: CardEntity = null
	for c in main.state.players[main.my_seat]["cards"]:
		if CardDB.special_type(c["def_id"]) == CardDB.SPECIAL_GRAB:
			grab = main.entities.get(c["uid"])
	if not need(grab != null and main.phase == main.PHASE_ACTION and main._actor == main.my_seat, "「给我」在桌上，轮到本方行动"):
		return
	check(grab.effect_text() == "" and grab.label.text == CardDB.card_name(grab.def_id), "「给我」有卡面")
	var market: CardEntity = main.market_cards[0]
	var target: String = market.def_id
	var cash: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
	var market_size: int = main.state.market.size()
	var grab_uid := grab.uid
	main.board._detach_from_group(grab)
	await main._on_dropped_on_market([grab], market)
	await settle()
	check(main.state.market.size() == market_size - 1 and not market.is_market and market.draggable,
		"商品「%s」归本方" % CardDB.card_name(target))
	check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == cash, "不花现金")
	check(not main.entities.has(grab_uid) and main.state.find_card(main.my_seat, grab_uid).is_empty(), "「给我」用完即离场")


func test_role_badges() -> void:
	print("\n【4】本方卡面按角色念数")
	var hr := _role_with("recipe_mult")
	main.apply_role(hr)
	await settle()
	var mods: Dictionary = main.state.combo_mods(main.my_seat)
	var core := ""
	for id in CardDB.all_cards():
		var d := CardDB.get_def(str(id))
		if d.get("kind") == CardDB.KIND_PRODUCT and d.get("recipe_res") == CardDB.RES_USER and ComboRules.recipe_need(d, mods) < int(d["recipe_n"]):
			core = str(id)
			break
	var def := CardDB.get_def(core)
	var need := ComboRules.recipe_need(def, mods)
	var mine: CardEntity = main._spawn_entity(main.state.add_card(main.my_seat, core), Vector3(-2, 0.05, 3.0), true)
	var theirs: CardEntity = main._spawn_entity(main.state.add_card(main.foe_seat, core), Vector3(2, 0.05, -3.0), false)
	check(mine.recipe_progress_text() == "0/%d" % need, "本方墨团写改后的需求 0/%d（卡面 %d）" % [need, def["recipe_n"]])
	check(theirs.recipe_progress_text() == "0/%d" % int(def["recipe_n"]), "对手的牌念卡面原值")
	check(main.board.hover_desc_text(core, main.board.card_mods(mine)).contains("×%d" % need)
		and main.board.hover_desc_text(core, main.board.card_mods(theirs)).contains("×%d" % int(def["recipe_n"])),
		"悬停说明同样按主人念数")
	var users: Array = []
	for c in main.state.players[main.my_seat]["cards"]:
		if c["def_id"] == CardDB.unit_id(CardDB.RES_USER) and users.size() < need and main.entities.has(c["uid"]):
			users.append(main.entities[c["uid"]])
	for c in [mine] + users:
		main.board._detach_from_group(c)
	var group: Dictionary = main.board.make_group([mine] + users)
	main.board.groups.append(group)
	main.board.refresh_group(group, Vector3(-2, 0.05, 3.0))
	check(mine.recipe_progress_text() == "%d/%d" % [need, need] and bool(group["was_valid"]),
		"编组进度：%d 张用户就凑满（%s）" % [need, mine.recipe_progress_text()])
	check(main.state.pending_pay(main.my_seat, [{"uids": group["cards"].map(func(c): return c.uid)}]) == 0
		and int(main.state.user_deployment(main.my_seat, [{"uids": group["cards"].map(func(c): return c.uid)}])["on_duty"]) == need,
		"在岗席位按改后的需求算")


func test_special_pawn() -> void:
	print("\n【5】专属卡拖去典当")
	var pm := _role_with_card(CardDB.SPECIAL_IDEA)
	main.apply_role(pm)
	await settle()
	var idea: CardEntity = null
	for c in main.state.players[main.my_seat]["cards"]:
		if CardDB.special_type(c["def_id"]) == CardDB.SPECIAL_IDEA:
			idea = main.entities.get(c["uid"])
	if not need(idea != null, "Idea 在桌上"):
		return
	main.board._detach_from_group(idea)
	await main._on_dropped_on_pawn([idea])
	await settle()
	check(main.lbl_msg.text.contains("不能典当") and not main.lbl_msg.text.contains("现金"), "提示专属卡不能典当：%s" % main.lbl_msg.text)
	check(main.entities.has(idea.uid) and not main.state.find_card(main.my_seat, idea.uid).is_empty(), "Idea 退回桌上")
