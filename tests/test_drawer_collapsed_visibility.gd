# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 不只检查收起那一刻：后台攻击、迟到的 show 和过渡回调都必须当帧不漏到入口。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 收起抽屉时牌桌界面可见性回归 ===")
	for hosted in [false, true]:
		var main := await _boot_drawer()
		var prefix := "主机后台运行" if hosted else "单机暂停"
		if hosted:
			# 这里只验证不停表分支；真实 socket 对手推进由 opponent_status 测试覆盖。
			main._host = EmbeddedHost.new()
		_check_attack_updates(main, prefix)
		_check_late_panels(main, prefix)
		_check_transitions(main, prefix)
		await _dispose(main)
	await _check_real_bot_attack()
	finish()

func _check_attack_updates(main: Node, prefix: String) -> void:
	var presentation: Node = main.drawer_presentation
	main.phase = main.PHASE_ATTACK
	main.board.attack_mode = true
	main.pipe.applier().pools_restore({main.my_seat: {CardDB.RES_CASH: 2, CardDB.RES_USER: 3}})
	main._show_attack_label("展开时的玩家攻击", true)
	check(_renders(main.lbl_attack) and _renders(main.attack_panel),
		"%s：展开牌桌显示攻击标签和攻击面板" % prefix)
	main.drawer_window.collapse_now()
	check(paused == (main._host == null), "%s：收起进入对应暂停分支" % prefix)
	_check_entry_only(main, prefix + "已有攻击收起")

	main.pipe.applier().pools_restore({main.my_seat: {CardDB.RES_CASH: 7, CardDB.RES_USER: 3}})
	main._show_attack_label("收起期间收到的新玩家攻击", true)
	main._refresh_attack_panel()
	check(main.lbl_attack.visible and main.attack_panel.visible,
		"%s：收起不会篡改攻击控件的当前业务可见状态" % prefix)
	check(not _renders(main.lbl_attack) and not _renders(main.attack_panel),
		"%s：后台 show 和刷新攻击面板后同帧仍不可渲染" % prefix)
	check(not main.table_hud.visible, "%s：整个牌桌 HUD 层保持隐藏" % prefix)
	main.drawer_window.pin()
	check(_renders(main.lbl_attack) and _renders(main.attack_panel)
		and main.lbl_attack.text == "收起期间收到的新玩家攻击"
		and "现金攻击 7" in main.attack_pool_text.text,
		"%s：展开显示后台更新后的攻击内容" % prefix)

	main.drawer_window.collapse_now()
	main.phase = main.PHASE_ACTION
	main.board.attack_mode = false
	main._hide_attack_label()
	main._refresh_attack_panel()
	main.drawer_window.pin()
	check(not _renders(main.lbl_attack) and not _renders(main.attack_panel),
		"%s：后台攻击结束后展开不恢复旧攻击提示" % prefix)

	main.drawer_window.collapse_now()
	main.phase = main.PHASE_ATTACK
	main._show_attack_label("收起后才开始的对手攻击", false)
	check(main.lbl_attack.visible and not _renders(main.lbl_attack),
		"%s：收起后才开始的对手攻击同帧不漏出" % prefix)
	main.board.attack_mode = true
	main._show_attack_label("收起期间交棒后的玩家攻击", true)
	main._refresh_attack_panel()
	_check_entry_only(main, prefix + "后台交棒")
	main.drawer_window.pin()
	check(_renders(main.lbl_attack) and _renders(main.attack_panel)
		and main.lbl_attack.text == "收起期间交棒后的玩家攻击",
		"%s：展开只显示交棒后的最新攻击状态" % prefix)
	main.phase = main.PHASE_ACTION
	main.board.attack_mode = false
	main._hide_attack_label()
	check(not presentation._handle.visible, "%s：展开后入口隐藏" % prefix)

func _check_late_panels(main: Node, prefix: String) -> void:
	var presentation: Node = main.drawer_presentation
	main.drawer_window.collapse_now()
	main.save_notice.show_saved("/tmp/drawer-first.record", 12)
	check(not main.save_notice.visible, "%s：收起后保存成功通知同帧隐藏" % prefix)
	main.save_notice.show_failed("/tmp/drawer-latest", "测试失败原因")
	check(not main.save_notice.visible, "%s：已隐藏通知再次 show 同帧仍隐藏" % prefix)
	main.drawer_window.pin()
	check(main.save_notice.visible and main.save_notice._title.text == "录像存不下来"
		and main.save_notice._path_edit.text == "/tmp/drawer-latest",
		"%s：展开恢复通知的最新结果和路径" % prefix)
	main.save_notice._on_close()

	main.drawer_window.collapse_now()
	if not main.msg_log.expanded():
		main.msg_log._toggle_body()
	main.msg_log.append("收起期间新增的提示记录", Color.WHITE, main.state.round_num)
	main.msg_log.show()
	check(not main.msg_log.visible, "%s：独立 CanvasLayer 的提示记录 show 同帧被隐藏" % prefix)
	main.drawer_window.pin()
	check(main.msg_log.visible and "收起期间新增的提示记录" in main.msg_log.plain_text(),
		"%s：展开恢复记录及后台追加内容" % prefix)
	presentation.close_panels()

	main.drawer_window.collapse_now()
	presentation._open_utility(3)
	check(not presentation._utility.visible, "%s：收起期间新打开选项页同帧隐藏" % prefix)
	presentation._open_utility(presentation.UTILITY_RULEBOOK)
	check(not presentation._utility.visible, "%s：收起期间切到规则书同帧隐藏" % prefix)
	var rulebook: Control = presentation._rulebook
	main.drawer_window.pin()
	check(presentation._utility.visible and presentation._utility_title.text == TutorialCatalog.ui("hub.title")
		and presentation._rulebook == rulebook,
		"%s：展开保留最新选项页和原有内容实例" % prefix)
	main.drawer_window.collapse_now()
	presentation.close_panels()
	main.drawer_window.pin()
	check(not presentation._utility.visible,
		"%s：收起期间显式关闭的选项页不会展开复活" % prefix)

	main.drawer_window.collapse_now()
	var join: JoinPanel = main._open_join_panel()
	check(not join.visible and presentation._suspended_panels.has(join),
		"%s：收起期间新建联网表单入树同帧隐藏并登记恢复" % prefix)
	join._room_edit.text = "LATEST"
	join.show()
	check(not join.visible, "%s：联网表单再次 show 同帧仍隐藏" % prefix)
	main.drawer_window.pin()
	check(join.visible and join._room_edit.text == "LATEST",
		"%s：展开恢复同一个联网表单及输入" % prefix)
	join._on_cancel()

	main.drawer_window.collapse_now()
	presentation.show_card_detail(main.board.cards[0], Vector2(100, 100))
	check(not presentation._detail.visible, "%s：迟到的卡牌详情同帧隐藏" % prefix)
	presentation.show_facility_detail(Vector2(100, 100))
	check(not presentation._detail.visible, "%s：迟到的典当详情同帧隐藏" % prefix)
	_check_entry_only(main, prefix + "迟到面板")
	main.drawer_window.pin()
	check(not presentation._detail.visible, "%s：展开不恢复已经失效的悬停详情" % prefix)

func _check_transitions(main: Node, prefix: String) -> void:
	# headless 会同步完成几何变化；直接观察真实 transition_started 信号内的中间态。
	var inspect := func(expanding: bool):
		var context := "%s%s过渡中" % [prefix, "展开" if expanding else "收起"]
		check(main.drawer_window.is_transitioning(), "%s：在过渡信号内检查" % context)
		main._show_attack_label("过渡期间的攻击回调", true)
		main.save_notice.show_saved("/tmp/transition.record", 1)
		main.drawer_presentation._open_utility(3)
		check(not _renders(main.lbl_attack) and not _renders(main.attack_panel)
			and not main.save_notice.visible and not main.drawer_presentation._utility.visible,
			"%s：攻击和迟到面板同帧均不漏出" % context)
	main.drawer_window.transition_started.connect(inspect)
	main.drawer_window.collapse_now()
	main.drawer_window.pin()
	main.drawer_window.transition_started.disconnect(inspect)
	check(main.save_notice.visible and main.drawer_presentation._utility.visible,
		"%s：过渡完成后恢复最新请求显示的面板" % prefix)
	main.save_notice._on_close()
	main.drawer_presentation.close_panels()
	main._hide_attack_label()

func _check_real_bot_attack() -> void:
	var main := await _boot_drawer()
	var core := ""
	var cost := 2147483647
	for id in CardDB.all_cards():
		var definition: Dictionary = CardDB.get_def(id)
		if (definition.get("kind") == CardDB.KIND_ATTACK
				and definition.get("recipe_res") == CardDB.RES_USER
				and definition.get("attack_res") == CardDB.RES_CASH
				and int(definition.get("recipe_n", 0)) < cost):
			core = str(id)
			cost = int(definition["recipe_n"])
	if not need(core != "", "真实 BOT 攻击夹具从配置找到攻击现金的组合"):
		await _dispose(main)
		return
	var damage := int(CardDB.get_def(core)["attack_n"])
	main.state.market.clear()
	main.state.combos.clear()
	for who in [main.my_seat, main.foe_seat]:
		main.state.players[who]["cards"].clear()
		var uids: Array = [main.state.add_card(who, core)["uid"]]
		for i in cost:
			uids.append(main.state.add_card(who, "user")["uid"])
		for i in damage + 2:
			main.state.add_card(who, "cash")
		check(main.state.create_combo(who, uids).get("ok", false), "%s建立真实攻击组合" % who)
	main.state.draw_first = main.foe_seat
	main._respawn_all()
	main._run_attacks()
	main.drawer_window.collapse_now()
	var leaked := false
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline and not (main.board.attack_mode and paused):
		leaked = leaked or _renders(main.lbl_attack) or _renders(main.attack_panel)
		await process_frame
	check(main.board.attack_mode and paused, "BOT真实攻击完毕并交棒给收起状态的玩家")
	check(main.state.resource_count(main.my_seat, CardDB.RES_CASH) == 2,
		"收起期间真实攻击按配置扣除了现金")
	check(not leaked and not _renders(main.lbl_attack) and not _renders(main.attack_panel),
		"BOT攻击到玩家攻击的后台协程全程没有泄漏攻击提示")
	_check_entry_only(main, "真实BOT交棒")
	main.drawer_window.pin()
	check(_renders(main.lbl_attack) and _renders(main.attack_panel)
		and main.TXT_ATTACK_MINE in main.lbl_attack.text,
		"真实交棒后展开显示当前玩家攻击提示")
	await _dispose(main)

func _check_entry_only(main: Node, prefix: String) -> void:
	var presentation: Node = main.drawer_presentation
	check(_renders(presentation._handle), "%s：入口图案保留显示" % prefix)
	var leaked: Array[String] = []
	for node in [presentation._header, presentation._footer, presentation._utility,
			presentation._detail, main.lbl_attack, main.attack_panel, main.hud_panel,
			main.btn_pass, main.btn_resign, main.btn_net, main.msg_log, main.save_notice]:
		if is_instance_valid(node) and _renders(node):
			leaked.append(str(node.name))
	check(leaked.is_empty(), "%s：透明入口没有任何牌桌控件漏出%s" % [prefix, leaked])

func _renders(node: Node) -> bool:
	if node is CanvasLayer:
		return node.visible
	if not node is CanvasItem or not node.is_visible_in_tree():
		return false
	# CanvasLayer 的 visible 不会改变后代 CanvasItem 的 visible_in_tree；
	# 嵌套 CanvasLayer 又独立绘制，因此判最近的画布，而不是任意父级画布。
	var ancestor := node.get_parent()
	while ancestor != null:
		if ancestor is CanvasLayer:
			return ancestor.visible
		ancestor = ancestor.get_parent()
	return true

func _boot_drawer() -> Node:
	paused = false
	root.size = Vector2i(1280, 900)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.sfx.set_muted(true)
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	return main

func _dispose(main: Node) -> void:
	paused = false
	main._host = null
	main.sfx.set_muted(true)
	main.queue_free()
	for i in 3:
		await process_frame
