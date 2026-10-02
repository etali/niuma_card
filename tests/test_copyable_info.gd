# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 三处「玩家要拿走的信息」：左上角资源牌子、录像路径、对手该填的地址。
##
## 这三条本来是同一个毛病的三种形态 —— **信息画在画面上就以为交付完了**。
## 画在画面上的字选不中、复制不了，会淡出，还会压在牌面上。而这三样恰恰都是
## 要带出游戏去用的：路径要粘到 Finder，地址要念给另一台机器上的人
## （用户原话「当前保存路径的提示是直接渲染到画面，这个不合适」、
## 「断网后提示对方连接的IP和端口要在『局域网对战』tab中可见，并且，可以选中复制」）。
##
## 为什么每一条都单独判 —— 三种坏法都**不报错、也不掉断言**：
##   T1 资源面板 mouse_filter 设成 STOP → 面板盖住的那块牌区点不动，
##      而画面上没有任何东西暗示那儿有一层玻璃
##   T2 路径回到 lbl_msg → 看着一切正常，2.6 秒后消失，且从来选不中
##   T3 分享地址那一块不立 → 接管成功、这一局没丢，而对手永远收不到新地址
##   T4 只读态没禁连接按钮 → 点一下「加入对局」把自己正驮着这局的服务器关掉
##
## 变异提示（都实跑确认过红，登记进 tools/mutate_check.py）见各节注释

func _initialize() -> void:
	print("=== 可复制信息测试 ===")
	CardDB.ensure_loaded()
	await _t1_res_panel()
	await _t2_save_path_is_copyable()
	await _t3_share_addr_in_lan_panel()
	await _t4_readonly_panel_cannot_start_second_link()
	finish()


## T1 左上角那块半透明面板。
##
## 判的是三件事，各挡一种真实坏法：**在树里**（不然三行字回到裸浮在画面上）、
## **半透明**（实心的话把底下对手的明牌挡死，而明牌是玩法的一部分）、
## **不吃鼠标**（STOP 的话它盖住的那块对手牌区点不动）。
##
## 变异提示：
##   - `pc.mouse_filter = IGNORE` 改成 STOP → 「面板不吃鼠标事件」红
##   - `sb.bg_color` 的 alpha 改成 1.0     → 「半透明」红
func _t1_res_panel() -> void:
	print("\n-- T1 左上角资源面板 --")
	var main: Node = await boot_main()
	if not need(main != null, "场景起得来"):
		return

	var pc: PanelContainer = null
	for c in main.find_children("ResPanel", "PanelContainer", true, false):
		pc = c
		break
	if not need(pc != null and pc.is_inside_tree(),
		"资源面板在场景树里（三行读数有背景，不是裸浮在 3D 画面上）"):
		main.queue_free()
		return

	# 三个 Label 都在这块面板底下。**认父子关系**而不是认坐标：
	# 坐标相等可能只是巧合（面板在 (16,12)，原先那三行也在 (24,…)），
	# 而「进了同一个容器」才是「有背景」这件事本身
	for pair in [["回合", main.lbl_round], ["我方读数", main.lbl_player_res],
			["对手读数", main.lbl_ai_res]]:
		var lbl: Label = pair[1]
		check(lbl != null and pc.is_ancestor_of(lbl),
			"%s那一行在面板里（不然它没有背景）" % pair[0])

	var sb: StyleBox = pc.get_theme_stylebox("panel")
	if need(sb is StyleBoxFlat, "面板有自己的底（StyleBoxFlat）"):
		var a: float = (sb as StyleBoxFlat).bg_color.a
		# 两头都钉：太透就等于没有背景（白字压白牌照旧读不出来），
		# 太实就把底下对手的明牌挡死 —— 而看得见对手阵型是玩法的一部分
		# 背景样式来自 scenes/main.gd 的 _setup_res_panel。
		check(a >= 0.90,
			"固定顶部信息区有稳定可读的底色（alpha=%.2f）" % a)

	# **不吃鼠标**。取牌是 board.gd 在 _unhandled_input 里打射线做的，
	# Control 吃掉的事件根本到不了那儿。这块面板盖的正是对手牌区的投影
	check(pc.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"面板不吃鼠标事件（IGNORE）—— STOP 的话它盖住的那块牌区点不动")
	for ch in pc.get_children():
		if ch is Control:
			check((ch as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"子节点 %s 也不吃（漏一层就等于整块都吃）" % ch.get_class())
	for l in [main.lbl_round, main.lbl_player_res, main.lbl_ai_res]:
		check((l as Label).mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"读数 Label 也是 IGNORE")

	# 读数照旧写得出来（面板换了摆法，_update_hud 那一侧不该受影响）
	main._update_hud()
	check(main.lbl_player_res.text.contains("你的公司"),
		"我方读数照旧在写（实为「%s」）" % main.lbl_player_res.text)
	check(main.lbl_ai_res.text.contains("对手公司"),
		"对手读数照旧在写（实为「%s」）" % main.lbl_ai_res.text)
	# 折行开着：那两行会长到 40 字（「⚠ 付完归零，整组会作废」那个形态），
	# 不折行的话面板横过去压到右上角那两块面板底下
	for l in [main.lbl_player_res, main.lbl_ai_res]:
		check((l as Label).autowrap_mode != TextServer.AUTOWRAP_OFF,
			"读数会折行 —— 「付完归零」那个形态长到 40 字")
	main.queue_free()


## T2 录像路径：进的是**选得中的输入框**，不是那条会淡出的提示。
##
## 变异提示：
##   - _save_replay 里把 save_notice.show_saved 换回 _show_message
##     → 「路径进了 save_notice」红
##   - SaveNotice 里 `_path_edit.selecting_enabled = true` 改成 false
##     → 「选得中」红
func _t2_save_path_is_copyable() -> void:
	print("\n-- T2 录像路径要抄得走 --")
	var main: Node = await boot_main()
	if not need(main != null, "场景起得来"):
		return
	var notice: SaveNotice = main.save_notice
	if not need(notice != null and notice.is_inside_tree(),
		"报路径那块面板在树里"):
		main.queue_free()
		return
	check(not notice.visible, "没存过之前它是收着的（不占屏幕）")

	main.lbl_msg.text = ""
	main._save_replay()
	await settle()
	if not need(notice.visible, "存完之后面板立起来了"):
		main.queue_free()
		return

	var shown: String = notice._path_edit.text
	check(shown.begins_with("/"),
		"框里是**绝对**路径（实为「%s」）—— `~` 在各平台展开成什么不一样，"
			% shown
		+ "只念一句「存在 ~/.niumapai_record 里」玩家还得自己拼一遍")
	check(shown.ends_with(".json") and shown.begins_with(Tape.path_dir() + "/"),
		"看着像那份录像的路径（实为「%s」）" % shown)
	# 那份文件**真在那儿**。光有一行字不算 —— 路径拼错了它照样显示得好看
	check(FileAccess.file_exists(shown),
		"这个路径下真有文件（不是拼出来好看的一行字）")

	# 选得中、抄得走。三样都显式判：LineEdit 只要有一样关着就抄不走，
	# 而关着的样子和开着的一模一样
	var pe: LineEdit = notice._path_edit
	check(not pe.editable, "只读（不许玩家改这行字 —— 改了就不是那份文件的路径了）")
	check(pe.selecting_enabled, "选得中 —— 这是这块面板存在的理由")
	check(pe.shortcut_keys_enabled, "Ctrl-C 走得通")

	# 复制按钮给回执：剪贴板看不见，不改文案玩家会连按几次
	var was: String = notice._copy_btn.text
	notice._copy_btn.emit_signal("pressed")
	check(notice._copy_btn.text != was,
		"按完复制按钮换文案（回执；原「%s」现「%s」）" % [was, notice._copy_btn.text])

	# **路径不再走那条会淡出的提示**。这一条是用户那句原话的落点：
	# lbl_msg 停 2.6 秒就淡掉，而一条绝对路径读完就不止 2.6 秒
	check(not main.lbl_msg.text.contains(shown),
		"路径没再写进那条会淡出的提示（实为「%s」）" % main.lbl_msg.text)

	# 关得掉，而且关了不影响这一局（存录像从来不打断对局）
	notice._on_close()
	check(not notice.visible, "「知道了」收得起来")
	check(main.tape.recording(), "收起面板不影响这一局还在录")

	# 这一节真往测试录像目录写了一份，扫完就删 —— 留着的话目录里
	# 会攒下每次跑测试的残渣，而那个目录玩家也在用
	DirAccess.remove_absolute(shown)
	main.queue_free()


## T3 断线接管之后，对手该填的地址要在「局域网对战」里看得见、抄得走。
##
## 走的是真接管路径的**后半段**（_show_waiting_as_host）：前半段要真起两个
## 进程互相 kill，这一节盯的是「地址有没有落到面板上」。
##
## 变异提示：
##   - _show_waiting_as_host 里去掉 prefill/_reconnect_share 那几句
##     → 「面板上立着分享地址」红
##   - JoinPanel.show_share 里 addr 非空也 return（永不立）
##     → 同上
##   - _show_waiting_as_host 里不放回 btn_net
##     → 「入口按钮回来了」红（面板根本打不开，地址没有落点）
func _t3_share_addr_in_lan_panel() -> void:
	print("\n-- T3 接管之后地址要在面板上 --")
	var main: Node = await boot_main()
	if not need(main != null, "场景起得来"):
		return
	var r: Dictionary = main.start_local_host_takeover()
	if not need(r.get("ok", false),
		"测试自己开得出端口（%s）" % r.get("reason", "")):
		main.queue_free()
		return
	var port := int(r["port"])
	# 局中的样子：入口按钮是 begin_net_game 藏掉的
	main.btn_net.visible = false

	var count_before: int = main.msg_log.total()
	main._show_waiting_as_host("TC3")
	check(main.msg_log.total() == count_before + 1, "一次接管成功只新增一条完整重连记录")
	check(main.msg_log.plain_text().contains(main._host_where_text())
		and main.msg_log.plain_text().contains("TC3"), "提示记录保留当前真实地址与房间码")
	check(main.msg_log._body.selection_enabled and main.msg_log._body.shortcut_keys_enabled,
		"记录里的接管信息可以选择并复制")
	for text in [main.lbl_msg.text, main.lbl_msg.tooltip_text]:
		check(text.contains("提示记录") and not text.contains("ws://")
			and not text.contains(str(port)) and not text.contains("TC3"),
			"接管后的底栏与tooltip只显示状态和入口指引")

	check(main.btn_net.visible and not main.btn_net.disabled,
		"入口按钮回来了 —— 藏着的话这个地址没有第二个落点")
	check(main._reconnect_share.contains(str(port)),
		"存下来的分享地址里有端口 %d（实为「%s」）" % [port, main._reconnect_share])
	check(main._reconnect_room == "TC3", "房间码也存下来了")

	# 打开面板，地址要**立在上面**且选得中
	var panel: JoinPanel = main._open_join_panel()
	await process_frame
	if not need(panel != null, "面板开得出来"):
		main.stop_local_host()
		main.queue_free()
		return
	check(panel.share_visible(), "面板上立着分享地址那一块")
	var addr := panel.share_text()
	check(addr.contains(str(port)),
		"框里那行有端口 %d（实为「%s」）" % [port, addr])
	check(addr == main._reconnect_share,
		"面板上那行就是 main 存的那行（不是另拼一份 —— 两处各拼一遍早晚分叉）")
	var se: LineEdit = panel._share_edit
	check(not se.editable, "只读")
	check(se.selecting_enabled, "选得中 —— 用户那句「可以选中复制」")
	check(se.shortcut_keys_enabled, "Ctrl-C 走得通")
	var was: String = panel._share_copy.text
	panel._share_copy.emit_signal("pressed")
	check(panel._share_copy.text != was,
		"复制按钮给回执（原「%s」现「%s」）" % [was, panel._share_copy.text])
	# 房间码和地址在同一块里：那两样是一起念给对手的
	check(panel._share_label.text.contains("TC3"),
		"标题里带房间码（实为「%s」）—— 分两处放的话抄完地址还要回头找房号"
			% panel._share_label.text)

	# 反过来：本机没开房的时候这一块**不立**（摆个空框比不摆更难懂）
	panel.show_share("")
	check(not panel.share_visible(), "地址为空就收起这一块")

	main.stop_local_host()
	main.queue_free()


## T4 这一局还活着的时候打开面板 → 只读：两颗连接按钮禁着、桌面不锁。
##
## 为什么非要有这道闸门：接管之后我**放回了** btn_net（T3 那一条），
## 于是局中第一次有了「面板能打开而连接还活着」这种组合。这时候点「加入对局」
## 会 emit joined → main._on_net_joined → _clear_old_session_for_reconnect
## → stop_local_host —— **把我自己正驮着这一局的服务器关掉**。
## 屏幕上看着是「点开个面板，牌桌就废了」，一条错都不报。
##
## 变异提示：
##   - JoinPanel._ready 里去掉 `_btn.disabled = true` 那一支 → 「加入按钮禁着」红
##   - bind 里只读态也锁桌面（去掉那句 return）      → 「桌面没被锁」红
func _t4_readonly_panel_cannot_start_second_link() -> void:
	print("\n-- T4 局中打开面板是只读的 --")
	var main: Node = await boot_main_seated(GameState.PLAYER, GameState.AI)
	if not need(main != null, "带座位的场景起得来"):
		return
	# 造一条**活着**的连接。net_live() 认的是 online()，
	# 而 online() 要 socket 真处于 OPEN —— 所以这里真起一个服务器连上去
	if not need(net_boot(29610), "测试服务器起得来"):
		main.queue_free()
		return
	var c: NetTransport = net_client("TC4")
	var ok := await net_until([c], func(): return c.online(), 4000)
	if not need(ok, "连上了（online）"):
		net_stop()
		main.queue_free()
		return
	main._net = c
	check(main.net_live(), "main 认这一局是活的（前提）")

	main.board.input_locked = false
	var panel := JoinPanel.new()
	panel.bind(main)
	main.add_child(panel)
	await process_frame

	check(panel._btn.disabled,
		"「加入对局」禁着 —— 局中连出第二条会把自己这局的服务器关掉")
	if panel._host_btn != null:
		check(panel._host_btn.disabled, "「等待对局」也禁着")
	check(not main.board.input_locked,
		"桌面**没被锁** —— 这一局还在打，而这次开面板只是来抄地址的")

	# 关掉之后这一局还在（那颗按钮此刻不是「放弃联网」）
	panel._on_cancel()
	await process_frame
	check(main.net_live(), "关掉面板这一局还活着")
	check(not main.board.input_locked, "关掉之后桌面照旧没锁")

	# 反过来：连接不活的时候（断线之后重连那条路）按钮**必须**是活的 ——
	# 只看 `_net != null` 的话掉线的人反而被拦住不许重连，
	# 而那正是这个面板要救的人
	c.close()
	check(not main.net_live(), "连接关掉之后 net_live 为假")
	var panel2 := JoinPanel.new()
	panel2.bind(main)
	main.add_child(panel2)
	await process_frame
	check(not panel2._btn.disabled,
		"断线之后「加入对局」点得动 —— 这条路正是为掉线的人留的")
	panel2._on_cancel()
	await process_frame

	net_stop()
	main.queue_free()
