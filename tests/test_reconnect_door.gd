# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 断线之后那道「回去的路」（scenes/main.gd 的 _offer_reconnect）。
##
## 被测的是**入口的可达性**，不是网络：打到一半网断了的人，屏幕上还有没有
## 一个能点的东西。这件事没有测的时候坏过一次 —— btn_net 是 begin_net_game
## 藏掉的，而放回来的那一半只长在「退房」上，于是掉线的人一个出路都没有。
##
## 三条路分开测，因为它们各自会**静默**地坏掉：
##   T1 进过房间的人断线 → 门开（坏了的话：一句红字 + 一桌点不动的牌）
##   T2 压根没连上过     → 门不开（坏了的话：局中那个入口被顶亮，见 T2 注释）
##   T3 _offer_reconnect 自己把该填的填上（坏了的话：门开着但里面是空的）
func _initialize() -> void:
	print("=== 断线重连入口测试 ===")
	await _t1_door_opens_after_real_session()
	await _t2_door_shut_when_never_connected()
	await _t3_offer_fills_the_panel()
	await _t4_details_live_in_log()
	await _t5_refuse_my_own_room()
	await _t6_guard_is_actually_wired()
	await _t7_drawer_reconnect_guidance()
	await _t8_notice_projection_bounds()
	finish()


## 走 _on_net_down 那条**真路**（不是直接调 _offer_reconnect）：
## 这一条要证的是「断线这件事能走到开门」，中间那几个分支也算被测的一部分。
##
## code 取 "protocol"：它**不在** main.TAKEOVER_CODES（只有 closed / no_server）里，
## 于是 _can_take_over_host 恒假、接管那一段整段跳过，落到下面那条 fatal 路上。
## 换成 no_server 的话要先想办法让接管失败，那测的就是另一件事了
func _t1_door_opens_after_real_session() -> void:
	print("\n-- T1 进过房间的人断线，门要开 --")
	var main: Node = await boot_main()
	var takeover: Array = main.TAKEOVER_CODES
	check(not ("protocol" in takeover),
		"protocol 不在接管白名单里 —— 这一条测的是接管**之外**那条路")

	var c := NetTransport.new("ws://127.0.0.1:1", "TD1")
	# **马上关掉**。这条 socket 指向一个没人听的端口，留着的话 main._process
	# 每帧 poll 它，它自己冒一条 disconnected("no_server") 出来 ——
	# 那个码在 TAKEOVER_CODES 里，于是接管被触发、真开一个服务器，
	# 判据就跟着那条不请自来的断线一起飘。
	# 这里要测的是「_on_net_down 被调到之后怎么办」，socket 本身不参与
	c.close()
	c.my_seat = "player"
	c.foe_seat = "bot"
	# 「曾经连上过」：他进过房间，服务器那边有他的座位和令牌
	c.ever_open = true
	main._net = c
	# 局中的样子：入口是藏着的（begin_net_game 干的），这里直接摆出来，
	# 免得整局跑一遍 —— 这一条要看的是断线之后它有没有被放回来
	main.btn_net.visible = false

	var reason := "两边 cards.json 不一样（ws://192.0.2.25:48001 / TD1）"
	var count_before: int = main.msg_log.total()
	await main._on_net_down("protocol", reason)
	check(main.msg_log.total() == count_before + 1, "一次客户端断线只记一条完整说明")
	check(main.msg_log.plain_text().contains(reason)
		and main.msg_log.plain_text().contains(c.url), "记录保留完整断线原因和原连接地址")
	_check_brief_status(main, "TD1", false)
	check(not main.lbl_msg.text.contains("48001") and not main.lbl_msg.tooltip_text.contains("48001"),
		"外部原因即使含地址，也不会漏进状态栏或悬停文字")

	check(main.btn_net.visible, "联网入口回来了 —— 他现在有东西可点")
	check(not main.btn_net.disabled, "而且点得动（光可见不够，灰的一样走不了）")
	check(main._reconnect_room == "TD1",
		"房间码替他填好了（%s）—— 那间房还在，drop_peer 只把座位置 0"
		% main._reconnect_room)
	check(main._reconnect_hint != "", "配了一句话，告诉他地址要去问谁")
	# 顺带确认 fatal 那两句照旧做了：门开着不等于这一局还能走
	check(main.board.input_locked, "牌还是锁着的 —— 门开了不代表这局能接着打")


## 压根没连上过的那一种（ever_open 为假）。
##
## 这是**真踩过的回归**：没有这条守卫的话，tests/test_rematch.gd T5 那条
## 「联网入口没被放回来（还在局里）」会红 —— 它造的连接指向 ws://127.0.0.1:1，
## 没人听，于是 settle 里那条 disconnected 打进来、门被顶开，
## 而 begin_net_game 刚把入口藏起来。
##
## 为什么**不该**开：没连上过就没有可回去的地方 —— 座位、令牌都不存在，
## 那个房间码服务器从没认过，拿它去重连只会撞上同一个连不上。
## 而且那种情形下联网面板本来就在屏幕上（begin_net_game 一次都没跑过），
## 该说话的是面板自己那句拒连原因
func _t2_door_shut_when_never_connected() -> void:
	print("\n-- T2 没连上过，门不开 --")
	var main: Node = await boot_main()
	var c := NetTransport.new("ws://127.0.0.1:1", "TD2")
	# 同 T1：关掉，别让这条空连接自己冒出一条 disconnected 来抢戏
	c.close()
	c.my_seat = "player"
	c.foe_seat = "bot"
	check(not c.ever_open, "这条连接从来没通过（ever_open 默认假）")
	main._net = c
	main.btn_net.visible = false

	await main._on_net_down("protocol", "连不上")

	check(not main.btn_net.visible,
		"入口照旧藏着 —— 没连上过的话没有「回去」可言，该说话的是面板")
	check(main._reconnect_room == "",
		"也没攒下房间码（攒了的话下次进面板会填一个服务器没认过的码）")


## _offer_reconnect 自己。T1 走的是整条断线路，这一条只盯它把状态摆对没有 ——
## 主机那一侧（_arm_reconnect_offer）也调它，而那条路等 20 秒，测不起
func _t3_offer_fills_the_panel() -> void:
	print("\n-- T3 门自己要填对 --")
	var main: Node = await boot_main()
	main.btn_net.visible = false
	main.btn_net.disabled = true

	main._offer_reconnect("TD3", "对手还没回来")

	check(main.btn_net.visible and not main.btn_net.disabled,
		"可见 + 点得动两件事都做了")
	check(main._reconnect_room == "TD3", "房间码存下来了")
	check(main._reconnect_hint == "对手还没回来", "那句话也存下来了")
	check(main.msg_log.plain_text().contains("对手还没回来")
		and main.msg_log.plain_text().contains("TD3"), "主动重连说明和房间码进入记录")
	_check_brief_status(main, "TD3", false)


## 普通主机只收到 foe_left，不经过接管；地址也必须进可复制的提示记录。
## 牌区保留离线标记，底栏提示去哪里查看，均不得夹带 IP、端口或房间码。
func _t4_details_live_in_log() -> void:
	print("\n-- T4 断线资料只进记录，牌桌保留离线状态 --")
	var main: Node = await boot_main()
	var r: Dictionary = main.start_local_host_takeover()
	if not need(r.get("ok", false), "测试自己开得出端口（%s）" % r.get("reason", "")):
		main.queue_free()
		return
	var port := int(r["port"])
	var c := NetTransport.new(main._host.url(), "TD4")
	c.close()
	c.my_seat = "player"
	c.foe_seat = "bot"
	main._net = c
	var count_before: int = main.msg_log.total()
	main._on_foe_left_drag()
	var txt: String = str(main._foe_offline_lbl.text)
	check(txt == "对手断开", "3D牌区只显示对手断开，不放地址与房间码")
	var recorded: String = main.msg_log.plain_text()
	check(recorded.contains(main._host_where_text()) and recorded.contains(str(port)),
		"提示记录保留完整当前连接地址及实际端口 %d" % port)
	check(recorded.contains("TD4"), "房间码和地址一起进入记录")
	check(main.msg_log._body.selection_enabled and main.msg_log._body.shortcut_keys_enabled,
		"记录允许选中文本并快捷复制")
	check(main.msg_log.total() == count_before + 1, "普通主机一次掉线只记录一次详情")
	_check_brief_status(main, "TD4", false)
	check(not main.lbl_msg.text.contains(str(port)) and not main.lbl_msg.tooltip_text.contains(str(port)),
		"实际端口不进入底栏或悬停文字")
	var generation: int = main._foe_gone_gen
	main._on_foe_left_drag()
	main._show_foe_offline_notice(true)
	check(main.msg_log.total() == count_before + 1 and main._foe_gone_gen == generation,
		"重复离场或绘制不会刷记录，也不会重复安排延迟重连提示")
	var lbl: Node = main._foe_offline_lbl
	check(int(lbl.outline_size) <= int(float(lbl.font_size) * 0.12), "离线标记保持实心描边")
	main._foe_offline_block("打对手的牌")
	check(main.lbl_msg.text.contains("打对手的牌"), "阻止攻击仍说明当前操作为何不能执行")
	_check_brief_status(main, "TD4", false)
	main._on_foe_back()
	check(main._foe_offline_lbl == null and main.lbl_msg.text == "对手回来了", "重连后清除离线标记和等待提示")
	check(main.msg_log.plain_text().contains("TD4"), "对手回来后原重连详情仍可翻查")
	main.stop_local_host()
	main.queue_free()


## 回来那位填了**自己**那间房的地址 → 当场拦住，别让他走一趟网络。
##
## 什么时候会出现「自己那间房」：进程**没走、只是网断了**那一档
## （主机那一侧的连接走回环，网断了它照样活着，我自己那个服务器也照样在跑）。
## 于是玩家照旧填自己那个老地址：连上了、坐下了（令牌还在），
## 然后 main._on_net_joined 里那句 _clear_old_session_for_reconnect
## 把 stop_local_host 跑了 —— **把他刚连上的那个服务器关掉**。
## 屏幕上是「连上了又断了」，一条错都没有，而他会说「密码是对的啊」
##
## 而这一节里**两个方向都要判**：拦住自己那间房，同时**不许**拦住
## 同端口的别人那台机器 —— 后者是端口改成默认之后新长出来的假阳性
func _t5_refuse_my_own_room() -> void:
	print("\n-- T5 不许连自己那间房 --")
	var main: Node = await boot_main()
	var r: Dictionary = main.start_local_host_takeover()
	if not r.get("ok", false):
		check(false, "测试自己开得出端口（%s）" % r.get("reason", ""))
		main.queue_free()
		return
	var port := int(r["port"])
	var panel := JoinPanel.new()
	main.add_child(panel)
	panel.bind(main)

	check(panel._is_my_own_host("ws://127.0.0.1:%d" % port),
		"127.0.0.1 那个写法认得出来")
	# 三种写法通到**同一个进程**，所以主机名那一栏要认三类而不是比字符串
	check(panel._is_my_own_host("ws://localhost:%d" % port),
		"localhost 那个写法也认得出来")
	# normalize_url 对已经带 ws:// 的原样返回，所以尾巴上可能有斜杠
	check(panel._is_my_own_host("ws://127.0.0.1:%d/" % port),
		"带尾巴斜杠的也认得出来 —— 拿 ends_with 比字符串会漏掉这种")
	check(not panel._is_my_own_host("ws://127.0.0.1:%d" % (port + 1)),
		"别的端口不算 —— 拦错了的话对手报的新地址反而进不去")

	# **同端口 + 别人的机器 = 不许拦**。这一条是端口从随机改成默认
	# （EmbeddedHost.start_takeover）之后新长出来的假阳性：
	# 「我开着 8910」和「对手也开着 8910」从巧合变成了常态，
	# 只比端口的话对手报来的那一行会被当成我自己那间房拦掉 ——
	# 而那正是他唯一能连的地址。拦错比漏拦更难查（漏拦是「连上又断」，
	# 拦错是「照他说的填却根本不让我连」）
	#
	# 192.0.2.x 是 RFC 5737 留给文档用的段，保证不会是本机地址
	check(not panel._is_my_own_host("ws://192.0.2.7:%d" % port),
		"同一个端口但是别人那台机器 —— 不拦（这是对手接管后唯一能连的地址）")
	for ip in EmbeddedHost.lan_ips():
		check(panel._is_my_own_host("ws://%s:%d" % [ip, port]),
			"我自己那个局域网地址 %s 照旧认得出来 —— 报给对手的就是这一行，" % ip
			+ "玩家很可能抄回到自己的输入框里")
		break

	main.stop_local_host()
	check(not panel._is_my_own_host("ws://127.0.0.1:%d" % port),
		"我没在开房时一律不拦（local_host_port 归零）")

	panel.queue_free()
	main.queue_free()


## 上面那条测的是「认不认得出来」，这一条测的是**接线** ——
## `_on_connect` 到底有没有去问。拆掉那个 if 的话 T5 照旧全绿，
## 而玩家又会走回那条「连上了又断了」的老路
func _t6_guard_is_actually_wired() -> void:
	print("\n-- T6 那道拦真的接在按钮上 --")
	var main: Node = await boot_main()
	var r: Dictionary = main.start_local_host_takeover()
	if not r.get("ok", false):
		check(false, "测试自己开得出端口（%s）" % r.get("reason", ""))
		main.queue_free()
		return
	var panel := JoinPanel.new()
	main.add_child(panel)
	panel.bind(main)
	panel._room_edit.text = "TD6"
	panel._url_edit.text = "ws://127.0.0.1:%d" % int(r["port"])

	panel._on_connect()

	# 一条连接都不该开出去。**这是这条判据的要点**：
	# 开出去的那一版功能上「也会失败」，只是失败得晚、而且报的是别的话
	check(panel._net == null, "一条连接都没开出去 —— 当场拦住，不走一趟网络")
	check(not panel._waiting, "也没进等待态（进了的话按钮灰着，得等超时才活)")
	check(str(panel._status.text).contains("你自己"),
		"说的是「这是你自己那间房」而不是一句「连不上」（实为「%s」）"
		% str(panel._status.text).replace("\n", " "))

	main.stop_local_host()
	panel.queue_free()
	main.queue_free()


## 抽屉入口藏在“选项”里，文字必须给完整路径；真实延迟到期后说明可查。
func _t7_drawer_reconnect_guidance() -> void:
	print("\n-- T7 抽屉给完整查看路径，延迟重连说明写进记录 --")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	await settle()
	_assert_booted(main)
	var c := NetTransport.new("ws://192.0.2.17:48432", "TD7")
	c.close()
	main._net = c
	main._on_foe_left_drag()
	_check_brief_status(main, "TD7", true)
	var count_before: int = main.msg_log.total()
	# 等生产侧的20秒定时器真正到期；TEST_SPEED=5时为约4秒墙钟。
	await create_timer(20.2, false).timeout
	check(main.msg_log.total() == count_before + 1, "延迟只新增一条主动重连说明")
	var recorded: String = main.msg_log.plain_text()
	check(recorded.contains("对手还没回来") and recorded.contains("他现在多半自己开了房"),
		"真实延迟路径记录可能主机易位的处理说明")
	check(recorded.contains("TD7") and recorded.contains(c.url), "延迟说明保留原房间码和连接地址")
	_check_brief_status(main, "TD7", true)
	main._foe_offline_block("打对手的牌")
	_check_brief_status(main, "TD7", true)
	main._on_foe_back()
	main.queue_free()


func _check_brief_status(main: Node, room: String, drawer: bool) -> void:
	var entry := "选项 → 提示记录" if drawer else "提示记录"
	var text: String = main.lbl_msg.text
	check(text.contains("重连说明见「%s」" % entry), "常驻状态给出正确的提示记录入口")
	check(not text.contains("ws://") and not text.contains(room)
		and not main.lbl_msg.tooltip_text.contains("ws://") and not main.lbl_msg.tooltip_text.contains(room),
		"底栏和tooltip都不显示连接地址或房间码")
	check(not text.contains("\n") and text.length() < 70, "底栏保持简短单行")


## 根据真实字形AABB投影判读离线标记，不能只验中心点还在视口里。
## 同一场景连续改变窗口和透视角，证明标记会随相机保持完整可见。
func _t8_notice_projection_bounds() -> void:
	print("\n-- T8 离线标记避开顶栏，并留在对手托盘中央 --")
	var cases := [
		[Vector2i(1024, 768), 1.0],
		[Vector2i(1320, 800), 1.0],
		[Vector2i(1920, 1200), 1.0],
		[Vector2i(2048, 1241), 1.57],
		[Vector2i(2560, 1600), 2.0],
	]
	for drawer in [false, true]:
		root.size = Vector2i(1920, 1200)
		root.content_scale_size = Vector2i.ZERO
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		var main: Node = load("res://scenes/main.tscn").instantiate()
		main.force_drawer_layout = drawer
		root.add_child(main)
		_booted = main
		await settle()
		_assert_booted(main)
		main.sfx.set_muted(true)
		main._show_foe_offline_notice(true)
		await process_frame
		var label: Label3D = main._foe_offline_lbl
		var log_before: int = main.msg_log.total()
		for spec in cases:
			root.size = spec[0]
			main.drawer_ui_scale = spec[1]
			var angles := [45.0, 60.0, 80.0] if drawer else [71.0]
			for angle in angles:
				if drawer:
					main.drawer_presentation.set_perspective_angle(angle)
				else:
					main._position_table_hud()
				for frame in 3:
					await process_frame
				var camera: Camera3D = main.board.camera
				var projected := _project_geometry(camera, label)
				var header: Rect2 = main.drawer_presentation._header.get_global_rect() if drawer else main.table_hud_rect()
				var content: Rect2 = main.drawer_presentation.content_rect() if drawer else main.table_content_rect()
				var tray: MeshInstance3D = main.get_node("FoeZoneTray")
				var tray_rect := _project_geometry(camera, tray)
				var tag := "%s %dx%d@%.2fx/%d°" % ["抽屉" if drawer else "横屏", spec[0].x, spec[0].y, spec[1], angle]
				check(projected.has_area() and content.encloses(projected), tag + " 离线字形完整投影在内容区内")
				check(not header.intersects(projected) and projected.position.y >= header.end.y + 4.0,
					tag + " 全部字形避开实际顶部栏，并留出间隙")
				check(tray_rect.encloses(projected), tag + " 离线标记完整位于对手托盘内")
				check(absf(projected.get_center().x - tray_rect.get_center().x) < 1.0,
					tag + " 标记保持对手区横向居中")
				check(projected.size.x < tray_rect.size.x * 0.18 and projected.size.y < tray_rect.size.y * 0.38,
					tag + " 标记保持紧凑，不占据大片牌区（宽%.1f%%/高%.1f%%）" % [projected.size.x / tray_rect.size.x * 100, projected.size.y / tray_rect.size.y * 100])
				var overlaps_card := false
				for card: CardEntity in main.entities.values():
					if not main.state.find_card(main.foe_seat, card.uid).is_empty():
						overlaps_card = overlaps_card or projected.intersects(_project_geometry(camera, card._plate))
				check(not overlaps_card, tag + " 中央标记不遮住两侧初始资源摞")
		check(main.msg_log.total() == log_before, "窗口/角度变化只改变投影，不重复添加断线记录")
		main._show_foe_offline_notice(false)
		main.queue_free()
		for frame in 3:
			await process_frame


func _project_geometry(camera: Camera3D, geometry: GeometryInstance3D) -> Rect2:
	var bounds := geometry.get_aabb()
	var result := Rect2()
	var first := true
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				var pixel := camera.unproject_position(geometry.to_global(Vector3(x, y, z)))
				result = Rect2(pixel, Vector2.ZERO) if first else result.expand(pixel)
				first = false
	return result
