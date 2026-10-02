# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 玩家等人时仍拿着原来的 AI 局；取消只是撤掉尚未开打的连接。
## 真 main + 真 socket，并把非空录像、手工布局和抽屉收放一起带过等待过程。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 联网等待保留 AI 对局 ===")
	for dpi in [1.0, 2.0]:
		var main: Node = await _boot_drawer(float(dpi))
		if not need(main != null, "%s倍DPI真实抽屉启动" % dpi):
			continue
		await _host_then_cancel(main, float(dpi))
		await _remote_then_cancel(main, float(dpi))
		await _waiting_geometry_failure(main, float(dpi))
		await _dispose(main)
	await _handoff_after_remote_action(false)
	await _handoff_after_remote_action(true)
	await _handoff_after_solo_resign_during_ai()
	finish()

func _boot_drawer(dpi: float) -> Node:
	paused = false
	root.size = Vector2i(roundi(1280 * dpi), roundi(800 * dpi))
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	main.drawer_ui_scale = dpi
	var old_seed := OS.get_environment("CARD_SEED")
	OS.set_environment("CARD_SEED", "42")
	root.add_child(main)
	if old_seed == "":
		OS.unset_environment("CARD_SEED")
	else:
		OS.set_environment("CARD_SEED", old_seed)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	_assert_booted(main)
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.sfx.set_muted(true)
	await _layout(main)
	return main

func _layout(main: Node) -> void:
	main.drawer_presentation.relayout()
	for i in 3:
		await process_frame
	main.drawer_presentation.relayout()
	await physics_frame

func _host_then_cancel(main: Node, dpi: float) -> void:
	var prefix := "%s倍DPI本机等待" % dpi
	# 先走真实购买，防止「偷偷重开成一副相同初始牌」也被当成保留成功。
	await _buy_one(main, "%s之前" % prefix)
	await settle()
	var original := _snapshot(main)
	check(not original["tape_steps"].is_empty(), "%s：进入等待前已经有牌局历史" % prefix)
	check(not original["groups"].is_empty(), "%s：进入等待前已经有玩家牌摞" % prefix)
	var panel: JoinPanel = main._open_join_panel()
	await _layout(main)
	panel._room_edit.text = "KEEP1"
	panel._on_host()
	if not need(main._host != null and main._host.running(), "%s：真正启动监听服务器" % prefix):
		panel._on_cancel()
		return
	var port: int = main.local_host_port()
	var seated := await _until(func():
		return is_instance_valid(panel) and panel._net != null and panel._net.my_seat != "")
	if not need(seated, "%s：主机自己完成真实握手并入座" % prefix):
		if is_instance_valid(panel):
			panel._on_cancel()
		return
	check(main._net == null and panel._waiting and panel._net.state().players.is_empty(),
		"%s：空房的连接留在等待面板，没有交给当前牌局" % prefix)
	_assert_preserved(main, original, "%s入座后" % prefix)
	await _layout(main)
	_check_waiting_ui(main, panel, dpi, prefix)
	# 等对手没有时限；10 秒只适用于尚未完成的服务器握手。
	var pending: NetTransport = panel._net
	panel._process(JoinPanel.SEAT_TIMEOUT_SEC * 3.0)
	check(panel._waiting and panel._net == pending and pending.my_seat != "",
		"%s：入座后超过握手超时仍等待，不误报服务器没让我入座" % prefix)
	check(panel._cancel_btn.visible and not panel._cancel_btn.disabled,
		"%s：长时间等待仍可取消" % prefix)
	await _collapse_restore(main, panel, prefix)
	_assert_preserved(main, original, "%s收放后" % prefix)
	panel._cancel_btn.pressed.emit()
	await process_frame
	check(not is_instance_valid(panel) and main._join_panel == null,
		"%s：真实取消按钮关闭等待面板" % prefix)
	check(main._host == null and main.local_host_port() == 0,
		"%s：取消释放本次服务器和监听端口" % prefix)
	_assert_preserved(main, original, "%s取消后" % prefix)
	var replacement := EmbeddedHost.new()
	var reopened: Dictionary = replacement.start(port, 1)
	check(bool(reopened["ok"]) and int(reopened.get("port", 0)) == port,
		"%s：取消后原端口能够立即重新监听" % prefix)
	replacement.stop()
	await _buy_one(main, "%s取消之后" % prefix)
	await settle()
	_assert_real_pick(main, "%s取消之后" % prefix)
	await settle()

func _remote_then_cancel(main: Node, dpi: float) -> void:
	var prefix := "%s倍DPI加入空房" % dpi
	var host := EmbeddedHost.new()
	if not need(bool(host.start(48180, 12)["ok"]), "%s：外部服务器启动" % prefix):
		return
	var original := _snapshot(main)
	var panel: JoinPanel = main._open_join_panel()
	await _layout(main)
	panel._room_edit.text = "KEEP2"
	panel._url_edit.text = host.url()
	panel._on_connect()
	# 在握手完成之前立即收起；客户端仍由面板 poll，不能因单机暂停而停住。
	main.drawer_window.collapse_now()
	check(not panel.visible and not main.drawer_window.is_expanded(),
		"%s：握手期间等待窗口随抽屉隐藏" % prefix)
	check(not paused, "%s：尚未交接的远端连接使收起后的握手继续运行" % prefix)
	var seated := await _until(func():
		host.poll()
		return is_instance_valid(panel) and panel._net != null and panel._net.my_seat != "")
	check(seated, "%s：抽屉收起期间仍完成真实远端握手" % prefix)
	if not seated:
		paused = false
		main.drawer_window.pin()
		if is_instance_valid(panel):
			panel._on_cancel()
		host.stop()
		return
	check(not panel.visible and main._net == null,
		"%s：入座消息不会让等待层漏到抽屉入口外或替换单机局" % prefix)
	_assert_preserved(main, original, "%s隐藏入座后" % prefix)
	main.drawer_window.pin()
	await _layout(main)
	check(panel.visible and panel._waiting and panel._cancel_btn.visible,
		"%s：展开恢复同一个可取消的等待界面" % prefix)
	_check_waiting_ui(main, panel, dpi, prefix)
	panel._cancel_btn.pressed.emit()
	await process_frame
	check(not is_instance_valid(panel) and host.running(),
		"%s：取消只关闭本次客户端，不关闭对方服务器" % prefix)
	_assert_preserved(main, original, "%s取消后" % prefix)
	host.stop()

## 同一块tab从填写、握手、等待到连接失败，只改变内容和可用状态。
## 用实际Control矩形捕捉同帧切换以及Container下一帧重排；1x/2x均验。
func _waiting_geometry_failure(main: Node, dpi: float) -> void:
	var context := "%s倍DPI等待布局" % dpi
	var panel: JoinPanel = main._open_join_panel()
	await _layout(main)
	var before := _geometry_snapshot(panel)
	panel._host_btn.pressed.emit()
	_check_geometry(panel, before, "%s点击同帧" % context)
	var seated := await _until(func():
		return is_instance_valid(panel) and panel._net != null and panel._net.my_seat != "")
	if not need(seated, "%s：通过真实按钮开房并完成入座" % context):
		panel._on_cancel()
		return
	await _layout(main)
	_check_geometry(panel, before, "%s真实握手后" % context)
	for status in ["等待对手加入…", "对手已就绪，完成当前行动后进入联机对局。",
			"服务器没让我入座（10 秒）—— 地址和端口对吗？对面开着房间吗？"]:
		panel._say(status, Palette.get_color("card", "body"))
		await _layout(main)
		_check_geometry(panel, before, "%s提示变更：%s" % [context, status])
	# 检查复制成功回执的较长文字也不挤动字段；这里不覆盖玩家系统剪贴板。
	panel._url_copy.text = "已复制 ✓"
	panel._room_copy.text = "已复制 ✓"
	await _layout(main)
	_check_geometry(panel, before, "%s复制回执" % context)
	main.stop_local_host()
	check(await _until(func(): return is_instance_valid(panel) and not panel._waiting),
		"%s：服务器真正关闭后收到断线并恢复可编辑状态" % context)
	await _layout(main)
	_check_geometry(panel, before, "%s连接失败恢复表单后" % context)
	check(panel._form.visible and panel._url_edit.editable and panel._room_edit.editable
		and not panel._host_btn.disabled and not panel._btn.disabled
		and panel._cancel_btn.text == "单机继续" and panel._status.text != "",
		"%s：错误原位显示，保留重试和继续原AI局的入口" % context)

	var large_font := panel._url_edit.get_theme_font_size("font_size")
	var original_window := root.size
	root.size = Vector2i(roundi(1080 * dpi), roundi(720 * dpi))
	await _layout(main)
	var resized := _geometry_snapshot(panel)
	var surface: Rect2 = resized["外框"]["rect"]
	check(Rect2(Vector2.ZERO, Vector2(root.size)).grow(1.0).encloses(surface)
		and surface.size.x < (before["外框"]["rect"] as Rect2).size.x
		and panel._url_edit.get_theme_font_size("font_size") < large_font,
		"%s：缩小窗口时面板和原生字号仍随窗口自适应" % context)
	panel._host_btn.pressed.emit()
	_check_geometry(panel, resized, "%s缩窗后再等的同帧" % context)
	await _layout(main)
	_check_geometry(panel, resized, "%s缩窗后再等的重排帧" % context)
	panel._cancel_btn.pressed.emit()
	await process_frame
	root.size = original_window
	await _layout(main)

func _geometry_snapshot(panel: JoinPanel) -> Dictionary:
	var controls := {
		"外框": panel._panel, "标题": panel._title, "说明": panel._intro,
		"地址": panel._url_edit, "复制地址": panel._url_copy,
		"房间码": panel._room_edit, "复制房号": panel._room_copy,
		"提示": panel._status, "等待按钮": panel._host_btn,
		"加入按钮": panel._btn, "取消按钮": panel._cancel_btn,
	}
	var snapshot := {}
	for label in controls:
		var control: Control = controls[label]
		snapshot[label] = {"node": control, "rect": control.get_global_rect()}
	return snapshot

func _check_geometry(panel: JoinPanel, before: Dictionary, context: String) -> void:
	var current := _geometry_snapshot(panel)
	var moved: Array[String] = []
	var replaced: Array[String] = []
	for label in before:
		var old: Dictionary = before[label]
		var now: Dictionary = current[label]
		if old["node"] != now["node"] or not now["node"].is_visible_in_tree():
			replaced.append(label)
		var old_rect: Rect2 = old["rect"]
		var new_rect: Rect2 = now["rect"]
		var position_delta := (new_rect.position - old_rect.position).abs()
		var size_delta := (new_rect.size - old_rect.size).abs()
		if maxf(maxf(position_delta.x, position_delta.y), maxf(size_delta.x, size_delta.y)) > 1.0:
			moved.append("%s %s→%s" % [label, old_rect, new_rect])
	check(replaced.is_empty(), "%s：沿用全部原控件且保持可见%s" % [context,
		"" if replaced.is_empty() else "（改变：%s）" % ", ".join(replaced)])
	check(moved.is_empty(), "%s：外框及各行位置尺寸偏差不超过1px%s" % [context,
		"" if moved.is_empty() else "（位移：%s）" % ", ".join(moved)])

## 两位已到齐，但本机旧AI行动尚未结束。远端可以先行动；
## 这些消息不能在面板持有连接时被提前消费、丢掉负责推进次序的信号。
func _handoff_after_remote_action(resign: bool) -> void:
	var context := "延迟交接期间对手%s" % ("认输" if resign else "完成行动")
	var main: Node = await _boot_drawer(1.0)
	if not net_boot(48250, 42):
		await _dispose(main)
		return
	var remote: NetTransport = net_client("RESIGN" if resign else "EARLY")
	if not need(await net_until([remote], func(): return remote.my_seat != ""),
		"%s：远端先开好真实房间" % context):
		remote.close()
		net_stop()
		await _dispose(main)
		return
	check(remote.my_seat == GameState.PLAYER, "%s：远端拿到本局先手座位" % context)
	var original := _snapshot(main)
	# 只保持与真实AI思考相同的交接门，实际连接/入座/行动消息均走真实socket。
	main._thinking = true
	var panel: JoinPanel = main._open_join_panel()
	panel._url_edit.text = remote.url
	panel._room_edit.text = remote.room
	panel._on_connect()
	var ready := await net_until([remote], func():
		return is_instance_valid(panel) and panel._net != null \
			and panel._net.has_dealt_state() and panel._net.phase() == PhaseMachine.ACTION)
	if not need(ready, "%s：双方已发牌，但本机仍停在旧行动交接门" % context):
		main._thinking = false
		if is_instance_valid(panel):
			panel._on_cancel()
		remote.close()
		net_stop()
		await _dispose(main)
		return
	var pending: NetTransport = panel._net
	var pumping_done := [false]
	net_pump_until([remote], func(): return pumping_done[0])
	var intent: Dictionary = Intent.resign(remote.my_seat) if resign else Intent.action_done(remote.my_seat)
	var response: Dictionary = await remote.submit(intent, remote.my_seat)
	pumping_done[0] = true
	check(bool(response.get("ok", false)), "%s：远端操作被真实服务器接受" % context)
	var advanced := await net_until([remote], func():
		return pending.phase() == PhaseMachine.OVER if resign else pending.actor() == pending.my_seat)
	check(advanced, "%s：候选连接已经收到了操作后的阶段" % context)
	_assert_preserved(main, original, "%s尚未交接时" % context)
	check(is_instance_valid(panel) and panel._waiting, "%s：等待界面仍可以取消" % context)
	main._thinking = false
	var handed_off := await net_until([remote], func(): return main._net == pending)
	check(handed_off and main.pipe == pending and main.state == pending.state(),
		"%s：旧行动结束后接管同一条候选连接" % context)
	if resign:
		var shown := await net_until([remote], func(): return main.game_over_panel != null)
		check(shown and main.state.winner == main.my_seat and main.phase == main.PHASE_OVER,
			"%s：补上已到达的认输结果，显示胜利而非卡在灰按钮" % context)
	else:
		var my_turn := await net_until([remote], func():
			return main._actor == main.my_seat and not main.board.input_locked and not main.btn_pass.disabled)
		check(my_turn and main.phase == main.PHASE_ACTION,
			"%s：补上已到达的完成行动，正确轮到自己而非永远等待对手" % context)
	main._reset_session_flags()
	remote.close()
	net_stop()
	await _dispose(main)

## AI已经结束搜索，但正在「买一张后停半拍」时仍有旧局协程。
## 此刻认输不能因phase=OVER就立即交接，否则旧协程会给新联网局提前换手。
func _handoff_after_solo_resign_during_ai() -> void:
	var context := "本机AI买卡节拍中认输再交接"
	var main: Node = await _boot_drawer(1.0)
	if not net_boot(48270, 42):
		await _dispose(main)
		return
	var remote: NetTransport = net_client("MIDAI")
	if not need(await net_until([remote], func(): return remote.my_seat != ""),
		"%s：远端真实入座并持有先手" % context):
		remote.close()
		net_stop()
		await _dispose(main)
		return
	var solo_state: GameState = main.state
	var original_market_size: int = solo_state.market.size()
	# 不替换AI决策或节拍：从玩家「完成行动」真实驱动AI进入买卡步骤。
	main._on_action_done()
	var panel: JoinPanel = main._open_join_panel()
	panel._url_edit.text = remote.url
	panel._room_edit.text = remote.room
	panel._on_connect()
	var ready := await net_until([remote], func():
		return is_instance_valid(panel) and panel._net != null \
			and panel._net.has_dealt_state() and panel._net.phase() != "")
	if not need(ready, "%s：旧AI行动中联机双方已完成发牌" % context):
		if is_instance_valid(panel):
			panel._on_cancel()
		remote.close()
		net_stop()
		await _dispose(main)
		return
	var pending: NetTransport = panel._net
	var in_beat := await net_until([remote], func():
		return main._net == null and main.state == solo_state and not main._thinking \
			and main.phase == main.PHASE_ACTION and main._actor == main.foe_seat \
			and main.state.market.size() < original_market_size
	, 15000)
	if not need(in_beat, "%s：真正买掉至少一张卡，搜索已停而旧行动尚未结束" % context):
		if is_instance_valid(panel):
			panel._on_cancel()
		main._reset_session_flags()
		remote.close()
		net_stop()
		await _dispose(main)
		return
	main._on_resign_pressed()
	main._on_resign_pressed()
	check(main.phase == main.PHASE_OVER and solo_state.winner == main.foe_seat,
		"%s：两次真实认输操作已经结束旧AI局" % context)
	check(not main.can_start_pending_net_game() and main._net == null,
		"%s：搜索线程虽已空闲，仍等完整旧行动协程结束后交接" % context)
	var transferred := await net_until([remote], func(): return main._net == pending, 10000)
	check(transferred and main.state == pending.state() and main.state != solo_state,
		"%s：旧流程自然结束后再进入正式联网局" % context)
	# 先等旧买卡节拍本应恢复的那段时间过去，再确认不会迟到地重开后手。
	await net_pump_for([remote], 900)
	check(main.state.winner == "" and main.game_over_panel == null,
		"%s：旧胜负层不留在新局里" % context)
	check(main.my_seat == GameState.AI and main._actor == remote.my_seat
		and pending.actor() == remote.my_seat and main.board.input_locked and main.btn_pass.disabled,
		"%s：服务器仍是远端先手，旧AI协程不能给本机后手提前解锁" % context)
	main._reset_session_flags()
	remote.close()
	net_stop()
	await _dispose(main)

func _snapshot(main: Node) -> Dictionary:
	var positions := {}
	for card: CardEntity in main.board.cards:
		if is_instance_valid(card):
			positions[card] = card.global_position
	var groups: Array = []
	for group in main.board.groups:
		groups.append({"cards": group["cards"].duplicate(),
			"label": group.get("label"), "compact": group.get("compact", false)})
	return {
		"state": main.state, "hash": StateCodec.state_hash(main.state), "pipe": main.pipe,
		"tape": main.tape, "tape_head": main.tape.head.duplicate(true),
		"tape_steps": main.tape.steps.duplicate(true), "tape_applier": main.tape._applier,
		"entities": main.entities.duplicate(), "market": main.market_cards.duplicate(),
		"positions": positions, "groups": groups,
		"phase": main.phase, "actor": main._actor, "locked": main.board.input_locked,
	}

func _assert_preserved(main: Node, before: Dictionary, context: String) -> void:
	check(main._net == null and main.state == before["state"]
		and StateCodec.state_hash(main.state) == before["hash"],
		"%s：保留同一个 AI 局面及其完整状态" % context)
	check(main.pipe == before["pipe"] and main.tape == before["tape"]
		and main.tape._applier == before["tape_applier"],
		"%s：保留原操作管道和录像裁决器连接" % context)
	check(main.tape.head == before["tape_head"] and main.tape.steps == before["tape_steps"],
		"%s：录像起点及已录步骤没有清空或替换" % context)
	check(main.entities == before["entities"] and main.market_cards == before["market"],
		"%s：玩家、对手、市场卡牌实体没有被删除重建" % context)
	var positions_intact := true
	for card in before["positions"]:
		if not is_instance_valid(card) or card.global_position.distance_to(before["positions"][card]) > 0.001:
			positions_intact = false
	check(positions_intact, "%s：牌桌上已有卡牌的位置保持不变" % context)
	var groups_intact: bool = main.board.groups.size() == before["groups"].size()
	if groups_intact:
		for i in main.board.groups.size():
			var old: Dictionary = before["groups"][i]
			var current: Dictionary = main.board.groups[i]
			groups_intact = groups_intact and current["cards"] == old["cards"] \
				and current.get("label") == old["label"] and current.get("compact", false) == old["compact"]
	check(groups_intact, "%s：已有编组、收拢状态和右侧清单没有重建" % context)
	check(main.phase == before["phase"] and main._actor == before["actor"]
		and main.board.input_locked == before["locked"],
		"%s：保留行动阶段、行动方和原业务锁" % context)

func _check_waiting_ui(main: Node, panel: JoinPanel, dpi: float, context: String) -> void:
	check(panel._form.visible and panel._title.text == "局域网对战"
		and panel._cancel_btn.text == "取消",
		"%s：在同一表单展示等待状态，原位按钮明确可以取消" % context)
	check(panel._btn.disabled and (panel._host_btn == null or panel._host_btn.disabled),
		"%s：等待期间保留连接按钮位置并禁用重复连接" % context)
	var surface: Control = panel.get_child(0).get_child(0)
	var bounds := Rect2(Vector2.ZERO, Vector2(root.size)).grow(1.0)
	check(bounds.encloses(surface.get_global_rect()), "%s：等待窗口完整落在当前游戏窗口内" % context)
	check(not main.board._interaction_is_blocked() and main._drawer_can_collapse(),
		"%s：等待窗口不阻塞牌桌和自动收起" % context)
	var ink := Palette.semantic("ink", Palette.get_color("card", "body"))
	var theme_ok := true
	var readable := true
	var unscaled := panel.scale.is_equal_approx(Vector2.ONE)
	var controls: Array[Control] = []
	_collect_text(panel._form, controls)
	for control in controls:
		unscaled = unscaled and control.get_global_transform_with_canvas().get_scale().is_equal_approx(Vector2.ONE)
		readable = readable and control.get_theme_font_size("font_size") >= roundi(17 * dpi * 0.85)
		if control is Button:
			var style: StyleBox = control.get_theme_stylebox("normal")
			var ink_color := control.get_theme_color("font_color")
			theme_ok = theme_ok and style is StyleBoxFlat and _contrast(ink_color, (style as StyleBoxFlat).bg_color) >= 3.0
		if control is LineEdit:
			var edit_ink := control.get_theme_color("font_uneditable_color")
			theme_ok = theme_ok and edit_ink.a > 0.9
	check(not controls.is_empty() and theme_ok, "%s：等待文字、只读地址和按钮沿用当前工具页主题" % context)
	check(readable and unscaled, "%s：等待内容使用随DPI变化的清晰原生字号" % context)
	var cancel_style: StyleBoxFlat = panel._cancel_btn.get_theme_stylebox("normal")
	var tab_style: StyleBox = main.drawer_presentation._pin.get_theme_stylebox("normal")
	check(tab_style is StyleBoxEmpty
		and panel._cancel_btn.get_theme_font_size("font_size") == main.drawer_presentation._pin.get_theme_font_size("font_size"),
		"%s：当前钉子图标按钮无外边框且字号体系仍与工具页一致" % context)
	var url := panel._url_edit.text
	check(not panel._url_edit.editable and panel._url_edit.selecting_enabled
		and panel._url_edit.shortcut_keys_enabled and LaunchConfig.normalize_url(url) == url,
		"%s：原地址行只读可选择，复制值是纯连接地址" % context)
	check(not panel._url_copy.disabled and panel._url_copy.pressed.get_connections().size() > 0,
		"%s：原地址行复制按钮绑定了实际处理函数" % context)
	var expected: Array = EmbeddedHost.lan_urls(main.local_host_port()) if panel._hosting else [url]
	if expected.is_empty():
		expected.append(panel._net.url)
	check(url == expected[0], "%s：原地址行报出优先局域网IP与真实监听端口" % context)
	check(panel._room_edit.text == panel._net.room and not panel._room_edit.editable
		and panel._room_edit.selecting_enabled and panel._room_edit.shortcut_keys_enabled,
		"%s：原房间码行保留房号并可选择复制" % context)
	check(not panel._room_copy.disabled and panel._room_copy.pressed.get_connections().size() > 0,
		"%s：原房间码行也有已绑定的复制按钮" % context)

func _collect_text(node: Node, out: Array[Control]) -> void:
	if node is Control and not node.is_visible_in_tree():
		return
	if node is Label or node is Button or node is LineEdit:
		out.append(node)
	for child in node.get_children():
		_collect_text(child, out)

func _collapse_restore(main: Node, panel: JoinPanel, context: String) -> void:
	var pending: NetTransport = panel._net
	var children: Array = panel._form.get_children()
	main.drawer_window.collapse_now()
	check(not main.drawer_window.is_expanded() and not panel.visible,
		"%s：收起时等待层完全隐藏，不留在抽屉入口外" % context)
	check(not paused and panel._net == pending and panel._waiting,
		"%s：收起后保留等待连接并继续联网轮询" % context)
	main.drawer_window.pin()
	await _layout(main)
	check(panel.visible and panel._net == pending and panel._form.get_children() == children,
		"%s：展开恢复原等待界面、内容和连接" % context)

func _buy_one(main: Node, context: String) -> void:
	var choice := -1
	var price := 2147483647
	var cash: int = main.state.resource_count(main.my_seat, CardDB.RES_CASH)
	for i in main.state.market.size():
		var candidate: int = CardDB.get_def(main.state.market[i]).get("price", -1)
		if candidate >= 0 and candidate < cash and candidate < price:
			choice = i
			price = candidate
	if not need(choice >= 0, "%s：当前局里有真正买得起的卡" % context):
		return
	var before: int = main.tape.size()
	var result: Dictionary = await main._try_buy(choice)
	check(bool(result["ok"]) and main.state.resource_count(main.my_seat, CardDB.RES_CASH) == cash - price,
		"%s：通过原管道真正买卡并扣除现金" % context)
	check(main.tape.size() == before + 1 and main.entities.has(result.get("new_uid", -1)),
		"%s：新购卡落在牌桌，录像继续追加本局步骤" % context)

func _assert_real_pick(main: Node, context: String) -> void:
	var board: Board = main.board
	var point := Vector2.INF
	var target: CardEntity = null
	for entity in board.cards:
		if not is_instance_valid(entity) or not entity.visible or not entity.draggable or entity.is_market:
			continue
		for offset in [Vector3.ZERO, Vector3(-0.3, 0.045, -0.5), Vector3(0.3, 0.045, 0.5)]:
			var candidate := board.camera.unproject_position(entity.to_global(offset))
			if not main.drawer_presentation.content_rect().has_point(candidate):
				continue
			var picked := board._pick_card(candidate)
			if picked != null and picked.draggable and not picked.is_market:
				target = picked
				point = candidate
				break
		if target != null:
			break
	if not need(target != null, "%s：取消之后射线仍能找到实际可操作的牌" % context):
		return
	board._reset_click_track()
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	event.pressed = true
	board._unhandled_input(event)
	check(target in board._drag_cards, "%s：真实鼠标入口还能抓起原牌局的牌" % context)
	event = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	event.pressed = false
	board._unhandled_input(event)
	check(board._drag_cards.is_empty(), "%s：松手正常完成拖牌" % context)
	board._reset_click_track()

func _until(condition: Callable, ms := 4000) -> bool:
	var deadline := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await process_frame
	return condition.call()

func _linear(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)

func _contrast(ink: Color, surface: Color) -> float:
	var a := 0.2126 * _linear(ink.r) + 0.7152 * _linear(ink.g) + 0.0722 * _linear(ink.b)
	var b := 0.2126 * _linear(surface.r) + 0.7152 * _linear(surface.g) + 0.0722 * _linear(surface.b)
	return (maxf(a, b) + 0.05) / (minf(a, b) + 0.05)

func _dispose(main: Node) -> void:
	paused = false
	if main.sfx:
		main.sfx.set_muted(true)
	main.queue_free()
	await process_frame
	await process_frame
