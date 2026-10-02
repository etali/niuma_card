# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 刻意不写 class_name：这是开发工具，不该占全局类名。
## main.gd 用 const DebugShot = preload(...) 引它

## 开发用截图钩子：CARD_SHOT=<路径>[,<秒>[,<动作>]] 时，等布局稳定后截真窗口再退出。
##
## 必须从游戏内截：外部 screencapture 抓的是当前前台窗口，而 Godot 启动后焦点
## 常被终端抢回去，抓到的是终端；-s 脚本模式的画幅也和真窗口不一致（卡宽差一倍多）。
##
## 动作用来抓交互态（悬停/双击这类靠鼠标触发的画面）：
##   facility:hover        检查市场设施牌的悬停说明
##   buy:<index>           真实购买一张市场卡，检查空槽与价签
##   hover:<def_id>[:<dz>]  把光标挪到该卡上，走真实的悬停代码路径
##   spread:<def_id>        用该核心卡凑一组摆好（摊开态），用来和 compact 对比占地
##   compact:<def_id>       同上，再执行一次双击收拢
##   merge:<n>[:def_id]     真实松手路径：收拢资源摞并到散卡，检查可见性
##   atkpile:<n>            给 AI 摞 n 张现金，进攻击模式点摞顶一下（验「点一摞扣一摞」）
##   settle:<n>[:<u>]       给玩家发 n 张现金（+ u 张用户）当本回合产出，走真实落位
##                          （验「每份 PILE_CHUNK 摞好、余数也摞」「现金一列用户一列」）
##   pawnat:<def_id>        把该卡拖到典当行当掉（验「现金摞在被当卡的原位、桌面不重排」）
##   tear:<n>[:<0..1>]      撕掉玩家区 n 张卡，在撕开过程的指定进度处抓拍
##                          （受击表现只有 TEAR_TIME 那么短，手动截抓不到中间帧）
##   offline:<notice/log>  触发对手断线，检查底栏指引与可复制的重连记录
##   lanlayout:compare  同一窗口先截输入态，再截等待态，检查布局是否跳动
##   lanwait:<host/cancel/collapsed>  等待面板、取消保留AI牌局及收起状态
##   result:<win/lose>[:collapsed/late/restore]  截取胜负提示与收放状态
##   edge:<top/bottom/left/right>:<open/close>  截取四边收放动画中间帧
##   record:<步数>        从 CARD_RECORD 指定的录像重放，检查真实记录的牌面显示
##   dragoverflow:<loose/group>  真实拖拽展开长列至底边，验证越界与松手合并
##   rulebook:<章节序号>   展开规则书并选择章节（从 0 开始）
##   panel:<名字>           展开右上角某块面板（PalettePanel / AIPanel）。
##                          两块面板默认都是收起的，展开态只有点过那个按钮才存在
##
## 这里刻意只读 main/Board 的成员、不复制它们的逻辑：截图要验的就是真实代码路径，
## 钩子里另写一套摆放/落位等于验了个假的。也因此调用了若干下划线成员。

var m: Node = null           # 场景控制器（scenes/main.gd）
var board: Board = null

## main 在 _ready 末尾调这一处。main 必须持有返回的实例：
## 本方法是协程，实例被回收会让 await 之后的代码不再执行
func run(main: Node) -> void:
	m = main
	board = main.board
	var benchmark_path := OS.get_environment("CARD_ENGINE_BENCH")
	if benchmark_path != "":
		await m.get_tree().process_frame
		var result: Dictionary = preload("res://scenes/engine_benchmark.gd").run()
		var file := FileAccess.open(benchmark_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(result, "  "))
		file.close()
		print("ENGINE_BENCH median_ms=", result["median_ms"], " output=", benchmark_path)
		m.get_tree().quit()
		return
	var spec := OS.get_environment("CARD_SHOT")
	if spec == "":
		return
	var parts := spec.split(",")
	var wait := float(parts[1]) if parts.size() > 1 else 2.5
	await m.get_tree().create_timer(wait).timeout
	if parts.size() > 2:
		await _action(parts[2])
	await RenderingServer.frame_post_draw
	var img := m.get_viewport().get_texture().get_image()
	img.save_png(parts[0])
	if m.drawer_presentation != null:
		var expanded: bool = m.drawer_window == null or m.drawer_window.is_expanded()
		print("DRAWER actual=", m.get_window().size, " expanded=", expanded,
			" mobile=", m.mobile_mode, " dpi_scale=", m.drawer_ui_scale, " pitch=", m.board.camera.rotation_degrees.x)
	print("CARD_SHOT -> %s (%dx%d)" % [parts[0], img.get_width(), img.get_height()])
	m.get_tree().quit()

## 截图前施加一个交互动作（见类注释的动作表）
func _action(spec: String) -> void:
	var bits := spec.split(":")
	if bits.size() < 2:
		return
	if bits[0] == "actionguard":
		await _check_action_guard(bits[1])
		return
	if bits[0] == "dragoverflow":
		await _check_drag_overflow(bits[1] == "group")
		return
	if bits[0] == "drawercheck" and m.drawer_window != null:
		await _drawer_position_check(bits[1])
		return
	if bits[0] == "rulebook" and m.drawer_presentation != null:
		await _expand_panel("Rulebook")
		m.drawer_presentation._rulebook.select_section(int(bits[1]))
		var demo: Node = m.drawer_presentation._rulebook.demo
		if bits.size() > 2:
			demo.select_example(int(bits[2]))
		for i in 3:
			await m.get_tree().process_frame
		if bits.size() > 3:
			await m.get_tree().create_timer(float(bits[3])).timeout
		if is_instance_valid(demo._stage.result_panel):
			var panel: PanelContainer = demo._stage.result_panel
			print("DEMO_RESULT viewport=", demo._viewport.size, " panel=", panel.size, " minimum=", panel.get_combined_minimum_size(), " scale=", demo._stage._result_view["layer"].scale)
		return
	if bits[0] in ["replay", "replayui"] and bits.size() >= 2:
		var tree: SceneTree = m.get_tree()
		# 原场景会被真正释放，截图钩子由根持有直到截图完成。
		tree.root.set_meta("replay_shot", self)
		var loaded: Dictionary
		if bits[0] == "replayui":
			m.drawer_presentation._menu.get_popup().id_pressed.emit(8)
			await tree.process_frame
			m._replay_picker._path_edit.text = bits[1]
			m._replay_picker.find_child("ReplayLoad", true, false).pressed.emit()
			loaded = {"ok": not m._replay_picker.visible}
			print("REPLAY_PICKER ", m._replay_picker._status.text)
		else:
			loaded = m._load_replay(bits[1])
		print("REPLAY_LOAD ", loaded.get("ok", false))
		if not loaded.get("ok", false):
			return
		for i in 8:
			await tree.process_frame
		for child in tree.root.get_children():
			if child is Node3D and child.get("replay_session") != null:
				m = child
				board = m.board
				break
		print("REPLAY_PINNED ", m.drawer_window.is_pinned())
		# 自动截图期间保持展开，保留真实钉住状态供日志断言。
		m.drawer_window.set_process(false)
		m.drawer_window.activate_handle()
		if bits.size() > 2:
			var trace := OS.get_environment("CARD_REPLAY_TRACE") == "1"
			await tree.create_timer(0.4).timeout
			for step in int(bits[2]):
				var watched: Dictionary = m.entities.duplicate() if trace else {}
				var seen := {}
				if trace:
					# 真实GUI按下/释放各一次；之后仅观察动画，不再发输入。
					var point: Vector2 = m.btn_pass.get_global_rect().get_center()
					var motion := InputEventMouseMotion.new()
					motion.position = point
					m.get_viewport().push_input(motion)
					for pressed in [true, false]:
						var click := InputEventMouseButton.new()
						click.button_index = MOUSE_BUTTON_LEFT
						click.position = point
						click.pressed = pressed
						m.get_viewport().push_input(click)
						await tree.process_frame
				else:
					m.btn_pass.pressed.emit()
				while m._replay_busy:
					for uid in watched:
						if seen.has(uid) or not is_instance_valid(watched[uid]):
							continue
						var card: CardEntity = watched[uid]
						if card._visual_retired:
							seen[uid] = true
							print("REPLAY_TEAR click=", step + 1, " uid=", uid,
								" points=", m.pipe.applier().pools(m.my_seat).get(CardDB.RES_CASH, 0),
								" foe_cash=", m.state.resource_count(m.foe_seat, CardDB.RES_CASH))
					await tree.process_frame
				print("REPLAY_STEP ", m.replay_session.cursor, " entities=", m.entities.size())
				if trace:
					print("REPLAY_CLICK ", step + 1, " action=", m.replay_session.action_cursor,
						" tears=", seen.size(), " points=", m.pipe.applier().pools(m.my_seat).get(CardDB.RES_CASH, 0),
						" foe_cash=", m.state.resource_count(m.foe_seat, CardDB.RES_CASH))
		if bits.size() > 3:
			for step in int(bits[3]):
				m._replay_previous_button.pressed.emit()
				await tree.process_frame
				print("REPLAY_PREVIOUS ", m.replay_session.cursor)
		await tree.create_timer(0.7).timeout
		return
	if bits[0] == "facility" and m.drawer_presentation != null:
		m.drawer_presentation.set_process(false)
		board.set_process(false)
		var at: Vector2 = board.camera.unproject_position(m._pawn_position())
		m.drawer_presentation.show_facility_detail(at)
		await m.get_tree().process_frame
		return
	if bits[0] == "buy":
		var result: Dictionary = await m._try_buy(int(bits[1]))
		print("BUY_SHOT ", result)
		await m.get_tree().create_timer(0.8, true).timeout
		return
	if bits[0] == "record":
		var loaded := Tape.load_from(OS.get_environment("CARD_RECORD"))
		if not loaded.get("ok", false):
			push_error("截图录像读取失败：%s" % loaded.get("reason", ""))
			return
		var replay := Tape.replay(loaded["tape"], int(bits[1]))
		print("RECORD ", Tape.verdict(replay))
		if not replay["ok"]:
			return
		print("RECORD_EVALUATION score=", AIPlan.score(replay["state"], m.my_seat),
			" foe_production_net=", preload("res://engine/ai_evaluation.gd").capacity(replay["state"], m.foe_seat))
		m.state = replay["state"]
		m._rebuild_pipe()
		m._respawn_all()
		m._update_hud()
		board.set_process(false)
		await m.get_tree().create_timer(0.5, true).timeout
		for card in m.state.players[m.foe_seat]["cards"]:
			var entity: CardEntity = m.entities[card["uid"]]
			if int(CardDB.get_def(entity.def_id).get("recipe_n", 0)) > 0:
				print("RECORD_RECIPE ", entity.def_id, " uid=", entity.uid, " progress=", entity.recipe_progress_text())
		return
	if bits[0] == "edge" and m.drawer_window != null:
		var drawer: DrawerWindow = m.drawer_window
		drawer.set_anchor_edge(bits[1])
		await m.get_tree().create_timer(0.15, true).timeout
		var full := drawer._rect_for(true)
		drawer.collapse_now()
		var opening := bits.size() > 2 and bits[2] == "open"
		if opening:
			await m.get_tree().create_timer(0.20, true).timeout
			drawer.expand()
		var tween := drawer._transition_tween
		tween.pause()
		tween.custom_step((DrawerWindow.EXPAND_DURATION if opening else DrawerWindow.COLLAPSE_DURATION) * 0.20)
		for i in 3:
			await m.get_tree().process_frame
		print("EDGE ", bits[1], " opening=", opening, " full=", full,
			" actual=", drawer._geometry, " snapshot=", drawer._cover.size,
			" offset=", drawer._cover.position)
		return
	if bits[0] == "merge":
		await _merge_pile(int(bits[1]), bits[2] if bits.size() > 2 else "pinshaoshao")
		return
	if bits[0] == "offline":
		# 文档示例地址，不建立网络连接；仍走场景实际的断线与记录路径。
		var net := NetTransport.new("ws://192.0.2.17:48432", "UI-RECONNECT")
		net.close()
		m._net = net
		m._foe_remote = true
		m._on_foe_left_drag()
		if bits[1] == "log":
			await _expand_panel("MsgLog")
		await m.get_tree().process_frame
		return
	if bits[0] == "lanlayout":
		var panel: JoinPanel = m._open_join_panel()
		for i in 3:
			await m.get_tree().process_frame
		await RenderingServer.frame_post_draw
		var path := OS.get_environment("CARD_SHOT").split(",")[0].get_basename() + "-before.png"
		m.get_viewport().get_texture().get_image().save_png(path)
		var before := panel._panel.get_global_rect()
		var address_before := panel._url_edit.get_global_rect()
		var cancel_before := panel._cancel_btn.get_global_rect()
		panel._host_btn.pressed.emit()
		await m.get_tree().create_timer(0.6, true).timeout
		print("LAN_LAYOUT panel_before=", before, " panel_after=", panel._panel.get_global_rect(),
			" address_before=", address_before, " address_after=", panel._url_edit.get_global_rect(),
			" cancel_before=", cancel_before, " cancel_after=", panel._cancel_btn.get_global_rect())
		return
	if bits[0] == "lanwait":
		var old_state: GameState = m.state
		var old_pipe: Transport = m.pipe
		var panel: JoinPanel = m._open_join_panel()
		panel._on_host()
		await m.get_tree().create_timer(0.6, true).timeout
		print("LAN_WAIT pending=", panel.has_pending_connection(), " seated=", panel._net.my_seat if panel._net else "",
			" preserved=", m.state == old_state and m.pipe == old_pipe, " net_started=", m._net != null)
		if bits[1] == "cancel":
			panel._on_cancel()
			await m.get_tree().process_frame
			print("LAN_CANCEL preserved=", m.state == old_state and m.pipe == old_pipe, " host_closed=", m._host == null)
		elif bits[1] == "collapsed":
			m.drawer_window.collapse_now()
			await m.get_tree().create_timer(0.25, true).timeout
			print("LAN_WAIT_COLLAPSED visible=", panel.visible)
		return
	if bits[0] == "result":
		var collapsed := bits.size() > 2 and bits[2] in ["collapsed", "late", "restore"]
		var late := bits.size() > 2 and bits[2] == "late"
		if late and m.drawer_window != null:
			m.drawer_window.collapse_now()
			await m.get_tree().create_timer(0.25, true).timeout
		m.state.winner = m.my_seat if bits[1] == "win" else m.foe_seat
		m.state.win_reason = "对手资金归零" if bits[1] == "win" else "你的公司资金归零"
		m._show_game_over()
		await m.get_tree().create_timer(0.15, true).timeout
		if collapsed and not late and m.drawer_window != null:
			m.drawer_window.collapse_now()
			await m.get_tree().create_timer(0.25, true).timeout
		if ("restore" in bits) and m.drawer_window != null:
			m.drawer_window.activate_handle()
			await m.get_tree().create_timer(0.45, true).timeout
		var layer: CanvasLayer = m.game_over_panel.get_parent().get_parent()
		print("RESULT visible=", layer.visible, " size=", m.game_over_panel.size)
		return
	if bits[0] == "entry" and m.drawer_window != null:
		m.drawer_window.start_collapsed()
		m.drawer_window.set_process(false)
		await m.get_tree().process_frame
		m.drawer_presentation._handle.set_hovered(bits[1] == "hover")
		if bits[1] == "click":
			m.drawer_presentation._handle.activated.emit()
			await m.get_tree().create_timer(0.45, true).timeout
		elif bits[1] == "hover":
			await m.get_tree().create_timer(0.5, true).timeout
		else:
			await m.get_tree().create_timer(3.0, true).timeout
		return
	if bits[0] == "first" and m.drawer_presentation != null:
		m.state.draw_first = m.foe_seat
		m._update_hud()
		m.drawer_presentation.relayout()
		await m.get_tree().process_frame
		return
	if bits[0] == "panelcollapse" and m.drawer_presentation != null:
		await _expand_panel(bits[1])
		m.drawer_window.collapse_now()
		await m.get_tree().create_timer(0.2, true).timeout
		print("PANEL_COLLAPSE expanded=", m.drawer_window.is_expanded(),
			" utility_visible=", m.drawer_presentation._utility.visible)
		return
	if bits[0] == "edges" and m.drawer_presentation != null:
		var targets: Array = []
		for card in board.cards:
			if is_instance_valid(card) and card.draggable and not card.is_market and card.def_id == "cash":
				targets.append(card)
				if targets.size() == 3:
					break
		var requests := [Vector3(-1000, 0.05, 3.2), Vector3(1000, 0.05, 3.2), Vector3(0, 0.05, 1000)]
		for i in targets.size():
			var card: CardEntity = targets[i]
			board._detach_from_group(card)
			board._stop_move(card, false)
			m._cancel_fly(card)
			card.freeze = true
			card.global_position = board.clamp_player_position(requests[i])
		await m.get_tree().create_timer(0.35).timeout
		return
	if bits[0] == "atkpile":
		await _attack_pile(int(bits[1]))
		return
	if bits[0] == "settle":
		# settle:<现金数>[:<用户数>]，第三段省略则只发现金
		await _settle_pile(int(bits[1]), int(bits[2]) if bits.size() > 2 else 0)
		return
	if bits[0] == "pawnat":
		await _pawn(bits[1])
		return
	if bits[0] == "tear":
		# tear:<n>[:<抓拍时刻占撕开总时长的比例>]，默认撕到一半时抓
		await _tear(int(bits[1]), float(bits[2]) if bits.size() > 2 else 0.5)
		return
	if bits[0] == "angle" and m.drawer_presentation != null:
		await _expand_panel("UI")
		m.drawer_presentation.set_perspective_angle(float(bits[1]))
		await m.get_tree().create_timer(0.3).timeout
		return
	if bits[0] == "panel":
		await _expand_panel(bits[1])
		return
	# spread/compact 要玩家自己的卡：这两条要组队并双击，而 toggle_compact
	# 直接拒掉货架卡。不能像 hover 那样随便抓一张同名的（抓到货架那张就静默失效）
	var need_own := bits[0] in ["spread", "compact"]
	var target: CardEntity = null
	for c in board.cards:
		if not is_instance_valid(c) or c.def_id != bits[1]:
			continue
		if need_own and (c.is_market or not c.draggable):
			continue
		target = c
		break
	if target == null:
		# 货架是随机抽的，指定的卡未必在场：直接造一张放到玩家区，
		# 否则每次验证都要靠运气等它出现
		target = m._spawn_entity({ "uid": DEBUG_UID_SPAWN, "def_id": bits[1] },
			Vector3(0, 0.2, m.PLAYER_ZONE_Z + 1.0), true)
		target.freeze = true
		await m.get_tree().process_frame
	match bits[0]:
		"hover":
			await _hover(target, float(bits[2]) if bits.size() > 2 else INF)
		"spread", "compact":
			await _group(target, bits[0] == "compact")

## 钩子自造卡用的 uid：真实发牌从 1 递增，这个量级不会撞上
const DEBUG_UID_SPAWN := 99001
const DEBUG_UID_BUFF := 99002

func _merge_pile(count: int, target_id: String) -> void:
	board.set_process(false)
	var members: Array = []
	for data in m.state.players[m.my_seat]["cards"]:
		if data["def_id"] == CardDB.unit_id(CardDB.RES_CASH) and members.size() < count:
			members.append(m.entities[data["uid"]])
	for card: CardEntity in members:
		board._detach_from_group(card)
		board._stop_move(card)
		card.freeze = true
	var source := board.make_group(members.duplicate(), true)
	board.groups.append(source)
	board._layout_group(source, Vector3(-3.7, 0.05, 3.0))
	var state_card: Dictionary = m.state.add_card(m.my_seat, target_id)
	var target: CardEntity = m._spawn_entity(state_card, Vector3(0.4, 0.05, 3.0), true)
	target.freeze = true
	await m.get_tree().create_timer(0.4).timeout
	await m.get_tree().physics_frame
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = board.camera.unproject_position(members[0].global_position)
	board._reset_click_track()
	board._unhandled_input(press)
	var delta := Vector3(target.global_position.x - members[0].global_position.x,
		Board.DRAG_HEIGHT - members[-1].global_position.y,
		target.global_position.z - members[0].global_position.z)
	for card in board._drag_cards:
		card.global_position += delta
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = board.camera.unproject_position(target.global_position)
	board._unhandled_input(release)
	await m.get_tree().create_timer(0.5).timeout
	await m.get_tree().physics_frame
	var group: Variant = board.group_of(target)
	var lowest := INF
	for card in members + [target]:
		lowest = minf(lowest, card.global_position.y - CardEntity.CARD_SIZE.y / 2.0)
	print("MERGE count=", group["cards"].size() if group else 0, " lowest=", lowest,
		" core_hit=", board._pick_card(board.camera.unproject_position(target.global_position)) == target)

func _hover(target: CardEntity, dz: float) -> void:
	if m.drawer_presentation != null:
		m.drawer_presentation.set_process(false)
		board.set_process(false)
		var at: Vector2 = board.camera.unproject_position(target.global_position)
		m.drawer_presentation.show_card_detail(target, at)
		await m.get_tree().process_frame
		print("TOOLTIP ", target.def_id, " extent=", m.drawer_presentation._detail.size)
		return
	# warp_mouse 要窗口有焦点才生效（截图时焦点常被终端抢走），
	# 所以直接走 Board 的悬停显示分支，文案和定位与真悬停同一条代码。
	# 必须先停掉 Board._process：它每帧按真实鼠标位置重算，会立刻把说明藏回去
	board.set_process(false)
	# dz 给光标相对卡中心的纵向偏移（hover:<def_id>:<dz>），用来验证
	# 「说明跟着光标上下走」：真实鼠标要窗口有焦点，截图时抓不到
	var az: float = target.global_position.z + dz if dz != INF else INF
	board._show_desc(board.hover_desc_text(target.def_id), target, az)
	await m.get_tree().process_frame
	if board.camera == null:
		return
	var dp: Vector2 = board.camera.unproject_position(board._desc.global_position)
	print("DESC_NODE @ %d,%d" % [dp.x, dp.y])
	var dl := board._desc as Label3D
	if dl:
		var ts: Vector2 = dl.font.get_multiline_string_size(
			dl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, dl.font_size)
		print("DESC_TEXT %s" % dl.text.replace("\n", " ⏎ "))
		print("DESC_行数 %d 文本框 %.0f×%.0f px 宽 %.2f 格" % [
			dl.text.split("\n").size(), ts.x, ts.y, ts.x * dl.pixel_size])

func _group(target: CardEntity, compact: bool) -> void:
	var g: Variant = await _build_group(target)
	if g == null:
		return
	if compact:
		board.toggle_compact(target)
	await m.get_tree().create_timer(0.6).timeout
	# 报出侧边清单各节点的屏幕坐标：验证「不铺衬底 / 数字不糊」要去数那几十个
	# 像素，在 3200×1800 里靠肉眼找这一小块很不靠谱
	var gg: Variant = board.group_of(target)
	if gg == null or board.camera == null:
		return
	for nd in gg.get("side", []):
		if nd != null and is_instance_valid(nd):
			var sp: Vector2 = board.camera.unproject_position(nd.global_position)
			print("SIDE_NODE %s @ %d,%d" % [nd.get_class(), sp.x, sp.y])

## 撕开动画的抓拍：把玩家区几张卡撕掉，等到撕开过程的 at 处（0..1）停下截图
func _tear(n: int, at: float) -> void:
	var victims: Array = []
	for c in board.cards:
		if not is_instance_valid(c) or c.is_market or not c.draggable:
			continue
		victims.append(c)
		if victims.size() >= maxi(n, 1):
			break
	# 撕之前先把它们摊到镜头中间一排，免得摞在一起看不清撕口
	var x0 := -float(victims.size() - 1) * 1.5 / 2.0
	for i in victims.size():
		var c: CardEntity = victims[i]
		board.drop_card(c)
		c.freeze = true
		c.position = Vector3(x0 + i * 1.5, 0.05, m.PLAYER_ZONE_Z - 1.0)
	await m.get_tree().create_timer(0.3).timeout
	var tracked: Array = []      # [卡, [左片, 右片]]，抓拍时报它们的屏幕位置
	for c in victims:
		m.entities.erase(c.uid)
		# 两片是 Node3D 容器（里面装旋转好的半卡网格），不是 MeshInstance3D
		var before: Array = c.get_children()
		m._tear_out(c, Vector3(0, 0, 1.0))
		var halves: Array = []
		for kid in c.get_children():
			if before.has(kid) or not (kid is Node3D):
				continue
			if kid.get_child_count() > 0 and kid.get_child(0) is MeshInstance3D:
				halves.append(kid)
		tracked.append([c, halves])
	await m.get_tree().create_timer(m.TEAR_TIME * clampf(at, 0.0, 1.0)).timeout
	print("TEAR 撕了 %d 张，抓拍于 %.0f%%（撕开总时长 %.2fs）" % [
		victims.size(), at * 100.0, m.TEAR_TIME])
	for t in tracked:
		_report_halves(t[0], t[1])

func _report_halves(c: CardEntity, halves: Array) -> void:
	if not is_instance_valid(c) or halves.size() != 2:
		print("  TEARHALF 卡已释放或没撕成两片")
		return
	var line := "  TEARHALF"
	for h in halves:
		if not is_instance_valid(h):
			continue
		var mat := (h.get_child(0) as MeshInstance3D).material_override as ShaderMaterial
		var sp := Vector2.ZERO
		if board.camera:
			sp = board.camera.unproject_position(h.global_position)
		# 撕口是横的，屏幕上分开的是纵坐标，所以这里报 y 和绕 x 的翻转角
		line += " [片 side=%.0f 屏幕 %d,%d fade=%.2f 翻 %.1f° 图标=%s]" % [
			mat.get_shader_parameter("side"), sp.x, sp.y,
			float(mat.get_shader_parameter("fade")), h.rotation_degrees.x,
			"有" if float(mat.get_shader_parameter("has_icon")) > 0.5 else "无"]
	print(line)

## 给 AI 摞 n 张现金，然后在攻击模式下点摞顶那张一次。
## 「点一摞扣一摞」只在真窗口里才验得完整（摞的位置、侧边张数、飞出动画都要眼看），
## 而进攻击模式要等整轮结算，靠不上；这里直接把玩家的点数池摆好走同一个入口
func _attack_pile(n: int) -> void:
	var state: GameState = m.state
	state.players[GameState.AI]["cards"].clear()
	state.combos = state.combos.filter(func(c): return c["owner"] != GameState.AI)
	for i in maxi(n, 1):
		state.add_card(GameState.AI, CardDB.unit_id(CardDB.RES_CASH))
	m._sync_entities()
	m.layout._layout_ai_zone()
	await m.get_tree().create_timer(0.5).timeout
	var key: String = ""
	for k in m.layout._ai_pile_uids:
		if not (m.layout._ai_pile_uids[k] as Array).is_empty():
			key = str(k)
	if key == "":
		print("ATK_PILE 没摞出来")
		return
	var uids: Array = m.layout._ai_pile_uids[key]
	print("ATK_PILE 摞 %s 共 %d 张，点数池 现金×%d" % [key, uids.size(), n - 2])
	m.phase = m.PHASE_ATTACK
	board.attack_mode = true
	m._attack_pools = { CardDB.RES_CASH: maxi(n - 2, 0), CardDB.RES_USER: 0 }
	m._refresh_attack_targets()
	var top: int = uids[0]
	if not m.entities.has(top):
		print("ATK_PILE 摞顶没实体")
		return
	if board.camera:
		var sp: Vector2 = board.camera.unproject_position(m.entities[top].global_position)
		print("ATK_PILE 摞顶屏幕坐标 %d,%d（×2 = 像素）" % [sp.x, sp.y])
	await m._on_attack_clicked(m.entities[top])
	await m.get_tree().create_timer(0.8).timeout
	print("ATK_PILE 扣完剩 %d 张，池剩 现金×%d" % [
		state.resource_count(GameState.AI, CardDB.RES_CASH),
		m._attack_pools[CardDB.RES_CASH]])
	for k in m.layout._ai_pile_uids:
		print("ATK_PILE 摞 %s 现登记 %d 张" % [k, (m.layout._ai_pile_uids[k] as Array).size()])

## 造 n 张现金 + n_user 张用户当「本回合产出」，走 _stack_settled 的真实落位。
## 打印摆之前/之后的坐标，用来核对「桌上原有的卡一张没挪」「每份 PILE_CHUNK 摞好」
## 「现金一列、用户一列」
func _settle_pile(n: int, n_user: int = 0) -> void:
	var state: GameState = m.state
	# AI 也发一批同种资源：验「相同资源不摞两坨」要有足够多的闲置卡
	for i in 18:
		state.add_card(GameState.AI, CardDB.unit_id(CardDB.RES_CASH))
	for i in 14:
		state.add_card(GameState.AI, CardDB.unit_id(CardDB.RES_USER))
	m._sync_entities()
	m.layout._layout_ai_idle()
	await m.get_tree().create_timer(0.6).timeout
	var keys := {}
	for g in m.layout._ai_piles():
		keys[str(g.get("key", "?"))] = int(g["cards"].size())
	var kl: Array = []
	for k in keys:
		kl.append("%s×%d" % [k, keys[k]])
	kl.sort()
	print("AI 摞 %d 坨：%s" % [keys.size(), ", ".join(kl)])

	var before := {}
	for uid in m.entities:
		if is_instance_valid(m.entities[uid]):
			before[uid] = m.entities[uid].global_position
	for i in maxi(n, 1):
		state.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH))
	for i in maxi(n_user, 0):
		state.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_USER))
	# 和 _run_settle 同样开到货窗口：不开的话产出牌是就地生成的，
	# 钩子就走不到「从组合中心飞进左侧带」这条真实路径
	m.layout.begin_arrivals()
	m._sync_entities(Vector3(3.0, 0.05, 2.0))
	await m.get_tree().create_timer(0.4).timeout
	m.layout.end_arrivals()
	m.layout._stack_settled(before)
	await m.get_tree().create_timer(0.8).timeout
	var moved := 0
	for uid in before:
		if m.entities.has(uid) and is_instance_valid(m.entities[uid]) \
			and m.entities[uid].global_position.distance_to(before[uid]) > 0.05:
			moved += 1
	print("SETTLE 产出 现金×%d 用户×%d；原有 %d 张里挪了 %d 张" % [
		n, n_user, before.size(), moved])
	for g in board.groups:
		if not g.get("compact", false):
			continue
		var o: Vector3 = board._group_origin(g)
		var sp := Vector2.ZERO
		if board.camera:
			sp = board.camera.unproject_position(o)
		# 摞里是哪种资源：结算摞是纯资源摞，取第一张的 def_id 即可
		var res := str(CardDB.get_def(g["cards"][0].def_id).get("res", "?"))
		print("SETTLE 摞 %s×%d @ (%.2f, %.2f) 屏幕 %d,%d" % [
			res, g["cards"].size(), o.x, o.z, sp.x, sp.y])
	_report_loose()

## 「左侧少于 PILE_CHUNK 张则不摞」的另一半：散着的必须压在门槛以下
func _report_loose() -> void:
	var loose := {}
	var spots: Array = []
	for c in m.state.players[GameState.PLAYER]["cards"]:
		if not m.entities.has(c["uid"]):
			continue
		var e: CardEntity = m.entities[c["uid"]]
		if not is_instance_valid(e) or not m.layout._in_settle_zone(e):
			continue
		var d: Dictionary = CardDB.get_def(c["def_id"])
		if d.get("kind") != CardDB.KIND_UNIT or board.group_of(e) != null:
			continue
		var r := str(d.get("res", "?"))
		loose[r] = int(loose.get(r, 0)) + 1
		spots.append("SETTLE 散牌 %s @ (%.2f, %.2f)" % [
			r, e.global_position.x, e.global_position.z])
	var ll: Array = []
	for r in loose:
		ll.append("%s×%d" % [r, loose[r]])
	ll.sort()
	print("SETTLE 左侧散着 %s（门槛 %d，超了就该摞）" % [
		"无" if ll.is_empty() else ", ".join(ll), m.PILE_CHUNK])
	for s in spots:
		print(s)

## 把玩家手里某张卡当掉，验「现金摞在原位、桌面不重排」
func _pawn(def_id: String) -> void:
	var target: CardEntity = null
	for c in board.cards:
		if is_instance_valid(c) and c.def_id == def_id and not c.is_market and c.draggable:
			target = c
			break
	if target == null:
		var nc: Dictionary = m.state.add_card(GameState.PLAYER, def_id)
		target = m._spawn_entity(nc, Vector3(2.0, 0.05, 3.2), true)
		await m.get_tree().create_timer(0.4).timeout
	var spot: Vector3 = target.global_position
	var before := {}
	for uid in m.entities:
		if is_instance_valid(m.entities[uid]) and uid != target.uid:
			before[uid] = m.entities[uid].global_position
	print("PAWN 「%s」在 (%.2f, %.2f)，典当价 %d" % [
		CardDB.card_name(def_id), spot.x, spot.z, CardDB.pawn_value(def_id)])
	await m._on_dropped_on_pawn([target])
	await m.get_tree().create_timer(0.9).timeout
	var moved := 0
	for uid in before:
		if m.entities.has(uid) and is_instance_valid(m.entities[uid]) \
			and m.entities[uid].global_position.distance_to(before[uid]) > 0.05:
			moved += 1
	print("PAWN 原有 %d 张里挪了 %d 张" % [before.size(), moved])
	var span: float = m.layout.COMPACT_SPAN
	for g in board.groups:
		if not g.get("compact", false):
			continue
		var o: Vector3 = board._group_origin(g)
		# 摞从 o 往 +z 长，所以「摞在不在原位」要拿中心去量，不是第一张
		var ctr: Vector3 = o + Vector3(0, 0, span * (g["cards"].size() - 1) / 2.0)
		print("PAWN 摞 %d 张 z=%.2f~%.2f 中心 (%.2f, %.2f)，离原位 %.2f" % [
			g["cards"].size(), o.z, o.z + span * (g["cards"].size() - 1),
			ctr.x, ctr.z, Vector2(ctr.x - spot.x, ctr.z - spot.z).length()])

## 给 core 凑齐配方材料并组成一组（摊开态摆好）。
## 双击的效果要在「一摞牌」上才看得出来，靠随机牌面等不到
func _build_group(core: CardEntity):
	var def: Dictionary = CardDB.get_def(core.def_id)
	var res := str(def.get("recipe_res", ""))
	var need := int(def.get("recipe_n", 0))
	if need <= 0:
		return null
	var members: Array = [core]
	for c in board.cards:
		if members.size() > need:
			break
		if not is_instance_valid(c) or c == core or c.is_market or not c.draggable:
			continue
		var d: Dictionary = CardDB.get_def(c.def_id)
		if d.get("kind") != CardDB.KIND_UNIT or d.get("res") != res:
			continue
		board._detach_from_group(c)
		members.append(c)
	# 加一张 buff，用来核对收拢后它排在核心卡之后（第二张），
	# 以及侧边清单会不会给 buff 单开一行
	var buff := _any_buff()
	if buff == null:
		return null
	board._detach_from_group(buff)
	members.append(buff)
	board._detach_from_group(core)
	core.global_position = Vector3(-1.0, 0.05, m.PLAYER_ZONE_Z - 1.2)
	var g := board.make_group(members)
	board.groups.append(g)
	board._layout_group(g)
	await m.get_tree().create_timer(0.4).timeout
	return g

## 场上任意一张 Buff 卡；没有就造一张。
## Buff 卡要花钱买，开局场上没有，不造这条验证永远跑不到。
## 造哪一张不重要（只用来占组里那个位置），取卡表里第一张 Buff——
## 写死某个 def_id 会在改卡表时静默失效
## 展开右上角的某块面板。走它自己的 _on_toggle（面板的展开是个协程：
## 要等一帧让子控件结算尺寸再重算高度），所以这里也 await 到它做完
func _expand_panel(which: String) -> void:
	if m.drawer_presentation != null:
		var panels := { "PalettePanel": 0, "AIPanel": 1, "MsgLog": 2, "UI": 3, "WindowRatio": 3, "EntrySize": 4, "Record": 5, "Rulebook": 7 }
		if which == "JoinPanel":
			m._open_join_panel()
		elif panels.has(which):
			m.drawer_presentation._open_utility(panels[which])
		else:
			print("未知抽屉面板：", which)
		for i in 3:
			await m.get_tree().process_frame
		m.drawer_presentation._relayout_utility()
		return
	var panel: Node = null
	for c in m.get_children():
		if c is CanvasLayer:
			panel = c.get_node_or_null(which)
			if panel != null:
				break
	if panel == null:
		print("找不到面板 %s（认得 PalettePanel / AIPanel）" % which)
		return
	await panel._on_toggle()
	await m.get_tree().process_frame


func _any_buff() -> CardEntity:
	for c in board.cards:
		if is_instance_valid(c) and not c.is_market and c.draggable \
			and CardDB.get_def(c.def_id).get("kind") == CardDB.KIND_BUFF:
			return c
	for def_id in CardDB.all_cards():
		if CardDB.get_def(def_id).get("kind") != CardDB.KIND_BUFF:
			continue
		return m._spawn_entity({ "uid": DEBUG_UID_BUFF, "def_id": def_id },
			Vector3(0, 0.2, m.PLAYER_ZONE_Z + 1.0), true)
	print("卡表里没有 Buff 卡，spread/compact 抓不了")
	return null

## 真实窗口收放的牌位回归：只观察游戏的位置，禁止在探针里保存再写回。
func _drawer_position_check(mode: String) -> void:
	var tree: SceneTree = m.get_tree()
	if mode in ["left", "right", "top", "bottom"]:
		m.drawer_window.set_anchor_edge(mode)
	if mode in ["loose", "left", "right", "top", "bottom"]:
		var card: CardEntity = board.groups[0]["cards"][0]
		board._detach_from_group(card)
		board._stop_move(card, false)
		card.position = Vector3(-5, 0.2, 4)
		card.freeze = false
	if mode == "edge":
		var group: Dictionary = board.groups[0]
		board._layout_group(group, Vector3(-100, 0.05, 4.5))
	await tree.create_timer(0.8, true).timeout
	var before := {}
	for card in board.cards:
		if is_instance_valid(card):
			before[card.uid] = card.position
	var bounds := board.player_bounds
	var projection := board.camera.get_camera_projection()
	var content: Rect2 = m.drawer_presentation.content_rect()
	var total_moved := 0
	if OS.get_environment("CARD_DRAWER_TRACE") == "1":
		m.get_viewport().size_changed.connect(func():
			print("DRAWER_RESIZE actual=",m.get_viewport().get_visible_rect().size,
				" stored=",m.drawer_presentation._viewport_pixels,
				" expanded=",m.drawer_window.is_expanded(),
				" collapsed_ui=",m.drawer_presentation._collapsed,
				" transition=",m.drawer_window.is_transitioning()))
	print("DRAWER_POS_BEFORE bounds=", bounds, " pending=", board._playable_bounds_pending,
		" viewport=", m.get_viewport().get_visible_rect(), " content=", content)
	for cycle in 3:
		m.drawer_window.collapse_now()
		await tree.create_timer(0.5, true).timeout
		m.drawer_window.activate_handle()
		await tree.create_timer(0.8, true).timeout
		var changed := 0
		for card in board.cards:
			if is_instance_valid(card) and before.has(card.uid) and card.position.distance_to(before[card.uid]) > 0.001:
				changed += 1
				print("DRAWER_CARD_MOVED cycle=",cycle," uid=",card.uid," before=",before[card.uid]," after=",card.position)
		total_moved += changed
		print("DRAWER_POS_AFTER cycle=",cycle," changed=",changed," bounds=",board.player_bounds,
			" viewport=", m.get_viewport().get_visible_rect(), " content=", m.drawer_presentation.content_rect(),
			" projection_same=", projection == board.camera.get_camera_projection())
	if total_moved > 0:
		push_error("抽屉收放改变了卡牌位置")

## 实包按钮输入验证：演示夹具只布置牌，判定、震动、声音均走正式完成行动入口。
func _check_action_guard(mode: String) -> void:
	var target := ""
	for id in CardDB.all_cards():
		var def := CardDB.get_def(id)
		if def.get("kind") == CardDB.KIND_PRODUCT and def.get("recipe_res") == CardDB.RES_CASH:
			target = id
			break
	assert(target != "")
	m.state.players[m.my_seat]["cards"].clear()
	m.state.combos.clear()
	m.state.draw_first = m.my_seat
	m.state.add_card(m.my_seat, CardDB.unit_id(CardDB.RES_USER))
	var uids: Array = [m.state.add_card(m.my_seat, target)["uid"]]
	for i in int(CardDB.get_def(target)["recipe_n"]):
		uids.append(m.state.add_card(m.my_seat, CardDB.unit_id(CardDB.RES_CASH))["uid"])
	m._rebuild_pipe()
	m._respawn_all()
	m.phase = m.PHASE_ACTION
	m._actor = m.my_seat
	m.board.input_locked = false
	m._set_button(m.TXT_ACTION_DONE, m._on_action_done)
	var cards: Array = []
	for uid in uids:
		var card: CardEntity = m.entities[uid]
		m.board._detach_from_group(card)
		cards.append(card)
	var group: Dictionary = m.board.make_group(cards, true)
	m.board.groups.append(group)
	m.board._layout_group(group, Vector3(0, 0.05, 3.8))
	await m.get_tree().create_timer(0.8).timeout
	var before := StateCodec.state_hash(m.state)
	var steps: int = m.tape.size()
	var slot: int = m.sfx._next
	var point: Vector2 = m.btn_pass.get_global_rect().get_center()
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.position = point
		click.pressed = pressed
		m.get_viewport().push_input(click)
		await m.get_tree().process_frame
	await m.get_tree().create_timer(0.06).timeout
	var denied: bool = m.phase == m.PHASE_ACTION and m._actor == m.my_seat and not m.board.input_locked and not m.btn_pass.disabled
	var same: bool = StateCodec.state_hash(m.state) == before and m.tape.size() == steps
	var sound: bool = m.sfx._players[slot].stream == m.sfx._streams[Sfx.action("deny")["sound"]] and m.sfx._next != slot
	print("ACTION_GUARD denied=",denied," unchanged=",same," deny_sound=",sound," rotation=",m.btn_pass.rotation)
	assert(denied and same and sound and absf(m.btn_pass.rotation) > 0.001)
	if mode == "resume":
		await m.get_tree().create_timer(0.4).timeout
		m.board._remove_group(group)
		await m._on_action_done()
		print("ACTION_GUARD_RESUME actor=",m._actor," passed=",m.tape.steps.any(func(e): return e["intent"]["op"] == Intent.OP_ACTION_DONE))

## 实包使用真实鼠标投影和 Board._process；夹具只准备牌，不手动改拖拽中的位置。
func _check_drag_overflow(grouped: bool) -> void:
	var tree: SceneTree = m.get_tree()
	m.drawer_window.set_process(false)
	m.drawer_window.animations_enabled = false
	m.drawer_window.activate_handle()
	await tree.create_timer(0.3).timeout
	board.set_process(false)
	board.input_locked = false
	m.set_foe_remote(true)
	m._clear_table()
	await tree.process_frame
	for who in [m.my_seat, m.foe_seat]:
		m.state.players[who]["cards"].clear()
	m.state.combos.clear()
	var target_at: Vector3 = board.clamp_player_position(Vector3(0, 0.05, 1000))
	var targets: Array = []
	var members: Array = []
	for batch in [targets, members]:
		var is_target := is_same(batch, targets)
		var count := (2 if grouped else 1) if is_target else 10
		var at := target_at if is_target else Vector3(-4, 0.05, 2.2)
		for i in count:
			var record: Dictionary = m.state.add_card(m.my_seat, CardDB.unit_id(CardDB.RES_CASH))
			batch.append(m._spawn_entity(record, at, true))
		if count > 1:
			var group: Dictionary = board.make_group(batch.duplicate(), is_target)
			board.groups.append(group)
			board._layout_group(group, at)
	await tree.create_timer(0.4).timeout
	var pick: Vector2 = board.camera.unproject_position(members[0].position + Vector3(0, 0.04, -0.65))
	# 主窗口的鼠标投影读取系统光标，push_input 只投递事件不会移动光标。
	var old_mouse := DisplayServer.mouse_get_position()
	m.get_window().grab_focus()
	m.get_viewport().warp_mouse(pick)
	await tree.process_frame
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pick
	board._unhandled_input(press)
	assert(board._drag_cards.size() == members.size(), "实包未抓到展开组的首牌")
	var requested: Vector3 = board.screen_position_clamper.call(Vector3(0, Board.DRAG_HEIGHT, target_at.z), [])
	var pointer := board.camera.unproject_position(requested - Vector3(board._grab_offset.x, 0, board._grab_offset.z))
	m.get_viewport().warp_mouse(pointer)
	await tree.process_frame
	board._process(0.016)
	var held: Vector3 = members[0].position
	var follows := Vector2(held.x, held.z).distance_to(Vector2(requested.x, requested.z)) < 0.05
	var content: Rect2 = m.drawer_presentation.content_rect()
	var tail: Vector2 = board.camera.unproject_position(members.back().position + Vector3(0, 0.04, 0.8))
	var overflow := tail.y > content.end.y
	await RenderingServer.frame_post_draw
	var path := OS.get_environment("CARD_SHOT").split(",")[0]
	m.get_viewport().get_texture().get_image().save_png(path.get_basename() + "-held.png")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = pointer
	board._unhandled_input(release)
	await tree.create_timer(0.4).timeout
	var joined: Variant = board.group_of(targets[0])
	var merged: bool = joined != null and joined["cards"].size() == members.size() + targets.size()
	var visible := true
	for card in members + targets:
		for x in [-0.6, 0.6]:
			for z in [-0.8, 0.8]:
				visible = visible and content.has_point(board.camera.unproject_position(card.position + Vector3(x, 0.04, z)))
	DisplayServer.warp_mouse(old_mouse)
	print("DRAG_OVERFLOW follows=", follows, " tail_outside=", overflow, " merged=", merged, " landed_visible=", visible)
	assert(follows and overflow and merged and visible, "展开牌组拖拽/底部合并不符合预期")
