# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 「开房间」这条路，**在真场景 + 真端口上**（需求 2、5）
##
## 分工：test_embedded_host 钉那个服务器本身（起得来、报的地址对、关得掉），
## test_launch_config 钉参数解析（纯函数），**这一条钉它们和场景层接上了没有**。
##
## 为什么必须单独有它 —— 这是 scenes/join_panel.gd 文件头那个教训的第二次：
## 当时 net/ 那一层全绿，而没有任何一处生产代码调 attach_net，
## 「联网功能」的实际状态是「测试里能跑，玩家点不到」。
## 这一次新增的三段（EmbeddedHost / LaunchConfig / apply_launch）会掉进同一个坑：
## 三个零件各自有判据、全绿，而
##   - main._process 里少一句 _host.poll()  → 对手连上了但握不完手，
##     **而主机这一侧一切正常**（他那边显示「服务器没让我入座」）
##   - _apply_launch_config 没被 _ready 调    → 网址里的参数静默失效，
##     玩家看到的是「链接没用」
## 两种都不报错。所以这条判据走的是真路径：真开端口、真连、真等 seated。
##
## 变异提示（都实跑确认过红，登记进 tools/mutate_check.py）：
##   1. main._process 里去掉 `_host.poll()`
##      → T2「对手连进来入座了」红（超时；主机侧毫无异常）
##   2. JoinPanel._on_host 里不调 _main.start_local_host()
##      → T1「开房间之后本机服务器在跑」红
##   3. JoinPanel.apply_launch 里 MODE_JOIN 那支不调 _on_connect
##      → T3「链接里带了地址房号就自己连」红
##   4. main._reset_session_flags 里去掉 stop_local_host()
##      → T4「退回单机局把服务器也收了」红（端口一直占着）
##   5. JoinPanel._on_host 里房间码为空时不现生一个
##      → T1「房间码空着也开得起来」红
##   6. start_local_host 忽略 want_port（永远 _host.start()）
##      → T5「指定端口就开在那个端口上」红

var _main: Node = null

func _initialize() -> void:
	print("=== 联网面板测试 ===")
	CardDB.ensure_loaded()
	_main = await boot_main()
	if _main == null:
		check(false, "场景起不来")
		finish()
		return
	await _t1_host()
	await _t2_foe_joins()
	await _t3_apply_launch()
	await _t4_stop_on_reset()
	await _t5_pinned_port()
	await _t6_handoff_after_release()
	finish()

# ---------- T1 开房间 ----------

var _panel: JoinPanel = null
var _solo_state: GameState = null
var _solo_pipe: Variant = null

func _t1_host() -> void:
	print("\n--- T1 开房间 ---")
	check(_main.has_method("start_local_host"),
		"main 有 start_local_host —— 面板靠它开服务器（所有权在 main："
		+ "面板在双方到齐后 queue_free，服务器不能跟着没）")
	_panel = _main._open_join_panel()
	check(_panel != null, "面板开出来了")
	await process_frame        # 等 _ready 建完控件
	check(_panel._host_btn != null,
		"桌面版画了「等待对局」按钮 —— 网页版这一个不画（浏览器开不了监听端口）")

	# 预填的地址：**有局域网地址就填真的那个**。
	# 填 127.0.0.1 的话，对面照着默认值按下去连的是它自己
	#（用户原话「局域网功能入口的地址默认用真实IP地址，
	# 否则用"127.0.0.1"只能本地连本地」）。
	# 判据按 lan_ips() 分两支 —— 没插网线时列表是空的，那时预填回环才是对的，
	# 硬要求真 IP 会让这条在没有网络的机器上假红
	var ips := EmbeddedHost.lan_ips()
	var prefilled := _panel._url_edit.text
	if ips.is_empty():
		check(prefilled == JoinPanel.DEFAULT_URL,
			"没有局域网地址时兜底填回环（%s）—— 同机双开确实只能连回环" % prefilled)
	else:
		check(not prefilled.contains("127.0.0.1"),
			"预填的不是回环（%s）—— 本机有局域网地址 %s" % [prefilled, str(ips)])
		check(EmbeddedHost.lan_urls(EmbeddedHost.DEFAULT_PORT).has(prefilled),
			"预填的就是 lan_urls 报出来的那个之一（%s）" % prefilled)
	check(LaunchConfig.normalize_url(prefilled) != "",
		"预填的地址本身合法（normalize 认它）")
	# 空表那一支单独判：开发机上 lan_ips() 从来不空，走不到这里。
	# 直接喂一张空表 —— 没有网络的机器上要兜底成回环，不能给空地址
	# （空地址会把「同机双开」这条路也断掉）
	check(JoinPanel.default_url([] as Array[String]) == JoinPanel.DEFAULT_URL,
		"没有局域网地址时兜底成回环（%s）"
			% JoinPanel.default_url([] as Array[String]))
	check(JoinPanel.default_url(["10.1.2.3"] as Array[String])
			== "ws://10.1.2.3:%d" % EmbeddedHost.DEFAULT_PORT,
		"有地址时用列表里第一个（%s）"
			% JoinPanel.default_url(["10.1.2.3"] as Array[String]))

	# 房间码**空着**就开：自己开房时房号是给对面报的，
	# 逼玩家先想一个只是多一步（而且想出来的多半是撞号的 "1234"）
	_solo_state = _main.state
	_solo_pipe = _main.pipe
	_panel._room_edit.text = ""
	_panel._on_host()
	check(_main._host != null and _main._host.running(),
		"开房间之后本机服务器在跑")
	check(Protocol.valid_room(_panel._room_edit.text),
		"房间码空着也开得起来（现生了 %s）" % _panel._room_edit.text)
	var share_urls := EmbeddedHost.lan_urls(_main.local_host_port())
	var expected_url: String = share_urls[0] if not share_urls.is_empty() else _main._host.url()
	check(_panel._url_edit.text == expected_url,
		"地址栏原位显示优先局域网IP及服务器真开成的端口（%s / %s）"
			% [_panel._url_edit.text, expected_url])
	check(_panel._net.url == _main._host.url(),
		"主机自己的连接仍走真实监听端口的回环地址，不依赖局域网网卡")
	check(_panel._hosting, "面板知道这一次是自己开的房")
	# 第二个人到齐后面板才交出连接并释放；先记下房号给 T2 使用。
	_room = _panel._room_edit.text

	# 主机侧自己也要入座 —— 「开房间」= 起服务器 + 照常连自己。
	# 主机不因为服务器在同一个进程里而少走任何一步（同一条 NetTransport）
	var seated := await _until(func():
		return is_instance_valid(_panel) and _panel._net != null \
			and _panel._net.my_seat != ""
	, 300)
	check(seated, "主机侧自己入座了（座位 %s）"
		% (_panel._net.my_seat if is_instance_valid(_panel) and _panel._net else "无"))
	check(_main._net == null, "只有一个人时连接留在面板，尚未切成联网局")
	check(_main.state == _solo_state, "等待对手时保留原 BOT 局的 state")
	check(_main.pipe == _solo_pipe, "等待对手时保留原 BOT 局的 pipe")
	check(is_instance_valid(_panel) and _panel.visible and _panel._waiting,
		"入座后等待面板继续显示，可以查看地址和取消")

var _room := ""

# ---------- T2 对手连进来 ----------

## 这一条钉的是 main._process 里那句 _host.poll()。
##
## 少了它的症状**只在对手那一侧**看得见：他的 socket 连上了、join 发出去了，
## 而服务器没人泵，包卡在缓冲里 —— 他等 10 秒然后看到「服务器没让我入座」，
## 而主机这一侧屏幕上写着「等对手进来」，一条错不报。
## 所以这里不自己泵服务器（那等于替被测代码干活），只泵对手那条连接
func _t2_foe_joins() -> void:
	print("\n--- T2 对手连进来 ---")
	if _main._host == null or not _main._host.running():
		check(false, "T2 需要 T1 开好的房")
		return
	# 房间码故意用**小写** —— 对手是照着念的/贴的，大小写不该分成两间
	var foe := NetTransport.new(_main._host.url(), _room.to_lower())
	foe.connect_to_server()
	var seated := await _until(func():
		foe.poll()
		return foe.my_seat != ""
	, 600)
	check(seated, "对手连进来入座了（座位 %s）—— 服务器是 main._process 泵的"
		% foe.my_seat)
	check(_main._host.server.room_count() == 1,
		"大小写不同的房间码进了同一间（房间数 %d）；分成两间的症状是"
			% _main._host.server.room_count()
		+ "「两个人都在等对手」，而两边都觉得自己填对了")
	var started := await _until(func():
		foe.poll()
		return _main._net != null and _main._net_table_drawn
	, 600)
	check(started, "第二位真正到齐并发牌后，主机才切换为联网对局")
	if started:
		check(_main._net.my_seat != foe.my_seat,
			"主机和对手坐的不是同一个座位（%s / %s）"
				% [_main._net.my_seat, foe.my_seat])
		check(_main.state == _main._net.state() and _main.state != _solo_state,
			"正式开局后主机使用服务器发下来的局面")
		check(_main.pipe == _main._net and _main.pipe != _solo_pipe,
			"正式开局后主机的操作管道切为同一条网络连接")
		check(_main.state.players.has(_main.my_seat)
			and _main.state.players.has(_main.foe_seat), "切换时双方已经发牌")
		check(_main._join_panel == null, "正式开局后移除等待面板")
	foe.close()
	for i in 4:
		foe.poll()
		await process_frame

# ---------- T3 启动参数直接进 ----------

func _t3_apply_launch() -> void:
	print("\n--- T3 启动参数直接进 ---")
	# 先退回单机局，把上一节那条连接和服务器都收掉
	_main._reset_session_flags()
	_main.state = GameState.new()
	_main.state.new_game()
	_main._rebuild_pipe()
	_main._sync_round()
	await process_frame

	# 起一个「别人的服务器」，然后照网址里那份参数自己连上去 ——
	# 网页版走的就是这条路（LaunchConfig.current 里参数来自 window.location.search）
	var host := EmbeddedHost.new()
	var r: Dictionary = host.start(47400)
	if not need(bool(r["ok"]), "起一个对照服务器"):
		return
	var cfg: Dictionary = LaunchConfig.parse(
		LaunchConfig.parse_query("?server=%s&room=link1" % host.url()))
	check(str(cfg["mode"]) == LaunchConfig.MODE_JOIN, "这份参数是「加入」模式")

	var panel: JoinPanel = _main._open_join_panel()
	await process_frame
	var solo_state: GameState = _main.state
	var solo_pipe: Variant = _main.pipe
	panel.apply_launch(cfg)
	check(panel._url_edit.text == host.url(), "地址填好了")
	check(panel._room_edit.text == "LINK1",
		"房号填好了并归一化成大写（实为 %s）" % panel._room_edit.text)
	check(panel._waiting and panel._form.visible and panel._title.text == "局域网对战",
		"客户端自动加入在原表单内显示等待状态，保持同一标题")
	check(not panel._url_edit.editable and panel._url_edit.selecting_enabled
		and not panel._url_copy.disabled,
		"原地址框进入只读状态，仍能选择和复制")
	check(panel._url_edit.text == host.url(), "原地址框保留真实 IP 和端口")
	check(panel._room_edit.text == "LINK1" and not panel._room_edit.editable
		and not panel._room_copy.disabled, "原房间码行显示同一房号并可复制")
	# 关键：**不用点任何按钮**。链接的意思就是「进去」
	var seated := await _until(func():
		host.poll()
		return is_instance_valid(panel) and panel._net != null \
			and panel._net.my_seat != ""
	, 600)
	check(seated, "链接里带了地址房号就自己连上并入座了 —— 不用点任何按钮")
	if seated:
		check(panel._net.room == "LINK1",
			"进的是链接里那一间（实为 %s）" % panel._net.room)
	check(_main._net == null and _main.state == solo_state and _main.pipe == solo_pipe,
		"链接进入空房也保留 BOT 对局，在等待面板内等对手")
	panel._on_cancel()
	await process_frame
	check(not is_instance_valid(panel), "链接自动加入后仍能取消并关闭等待面板")
	check(_main._net == null and _main.state == solo_state and _main.pipe == solo_pipe,
		"取消加入后继续原 BOT 对局，不重建局面和管道")
	check(host.running(), "取消加入只关闭自己的连接，不关闭对方服务器")
	# 网页版开不了房，界面据此少画一个按钮。这一条钉的是「那个判断存在」——
	# 无头桌面环境下它必须为真，否则连桌面版都点不到「开房间」
	check(LaunchConfig.can_host(), "桌面版 can_host 为真")
	_main._reset_session_flags()
	host.stop()
	await process_frame

# ---------- T4 退回单机局要把服务器收掉 ----------

func _t4_stop_on_reset() -> void:
	print("\n--- T4 退房时收服务器 ---")
	var r: Dictionary = _main.start_local_host()
	if not need(bool(r["ok"]), "再开一次房"):
		return
	var port := int(r["port"])
	check(_main.local_host_port() == port, "local_host_port 报的是真端口")
	# 重复开不该顺延：玩家可能已经把上一个地址报给对手了
	var again: Dictionary = _main.start_local_host()
	check(int(again["port"]) == port,
		"已经开着就直接报同一个地址（%d / %d）" % [port, int(again["port"])])
	_main._reset_session_flags()
	check(_main._host == null,
		"退回单机局把服务器也收了 —— 留着的话端口一直占着，"
		+ "下次开房顺延到另一个端口，而玩家还在照旧地址叫对手连")
	check(_main.local_host_port() == 0, "端口归零")
	# 收完还能再开（同一个端口空出来了）
	var third: Dictionary = _main.start_local_host()
	check(bool(third["ok"]) and int(third["port"]) == port,
		"收完能在同一个端口再开（实为 %s）" % str(third.get("port", "失败")))
	_main.stop_local_host()

# ---------- T5 指定端口就开在那个端口上 ----------

## 这一条钉的是「报出去的那个数 = 真监听的那个数」，指定端口那一支。
##
## 启动脚本开两份游戏时，第一份拿 `--host --port=8910`，第二份拿
## `--server=ws://127.0.0.1:8910` —— **8910 这个数是脚本报出去的**。
## 主机侧如果无视 want_port（在默认端口开）或者占用时顺延（在 8911 开），
## 症状都是同一句：第一份写着「等对手进来」，第二份连不上，两边都不报错。
## 所以指定端口时 tries=1：宁可当场说「端口被占」，也不要开在另一个数上
const T5_PORT := 47411

func _t5_pinned_port() -> void:
	print("\n--- T5 指定端口 ---")
	_main._reset_session_flags()
	await process_frame

	var r: Dictionary = _main.start_local_host(T5_PORT)
	if not need(bool(r["ok"]), "在指定端口开得起来（%s）"
			% str(r.get("reason", ""))):
		return
	check(int(r["port"]) == T5_PORT,
		"开在**要的那个端口**上（要 %d，实为 %d）—— 无视这个参数的症状是"
			% [T5_PORT, int(r["port"])]
		+ "「脚本报 8910，服务器开在别处」，第二份游戏连不上")
	check(str(r["url"]) == "ws://127.0.0.1:%d" % T5_PORT,
		"报出来的地址就是那个端口（%s）" % str(r["url"]))
	_main.stop_local_host()

	# 端口被别人占着：指定端口**不顺延**，当场失败。
	# 顺延在这一支上更糟 —— 它「成功」了，而对手手里那个数指向没人听的端口
	var squatter := EmbeddedHost.new()
	if not need(bool(squatter.start(T5_PORT, 1)["ok"]), "先占住那个端口"):
		return
	var blocked: Dictionary = _main.start_local_host(T5_PORT)
	check(not blocked["ok"],
		"端口被占就当场报错，不顺延到 %d（实为 %s）"
			% [T5_PORT + 1, str(blocked.get("port", "失败"))])
	check(_main._host == null, "开不起来就不留下半个 host")
	squatter.stop()

	# 走完整条路：启动参数 → apply_launch → _on_host(port)。
	# 中间任何一环把端口丢了（apply_launch 不读 cfg["port"]、_on_host 不往下传），
	# 表现都是「服务器开在 8910」而这里要的是 T5_PORT
	var cfg: Dictionary = LaunchConfig.parse(
		LaunchConfig.parse_flags(["--host", "--room=pin1",
			"--port=%d" % T5_PORT]))
	check(str(cfg["mode"]) == LaunchConfig.MODE_HOST, "这份参数是「开房」模式")
	check(int(cfg["port"]) == T5_PORT, "端口解析出来了（%d）" % int(cfg["port"]))
	var panel: JoinPanel = _main._open_join_panel()
	await process_frame
	panel.apply_launch(cfg)
	check(_main.local_host_port() == T5_PORT,
		"--port= 一路传到了服务器（实为 %d）—— 断在中间的症状是"
			% _main.local_host_port()
		+ "「脚本把第一份的端口报给了第二份，而第一份开在 8910」")
	var seated := await _until(func():
		return is_instance_valid(panel) and panel._net != null \
			and panel._net.my_seat != ""
	, 400)
	check(seated, "开房的人自己也入座了")
	check(_main._net == null, "指定端口启动也先在等待面板里等对手")
	panel._on_cancel()
	await process_frame
	check(_main._host == null and _main.local_host_port() == 0,
		"取消指定端口的等待，同时关闭本次服务器并释放端口")
	_main._reset_session_flags()
	await process_frame

# ---------- T6 抓牌期间延迟交接 ----------

## 第二位到齐后，seated 和首阶段 phase 会在同一次 poll 里到达。
## 抓着旧牌时不能拆掉当前对局；松手后又不能等一条服务器不会重发的 phase。
## 这里实际抓起并松开玩家卡，不直接篡改 safe gate 的布尔量。
func _t6_handoff_after_release() -> void:
	print("\n--- T6 抓牌松手后接入已就绪的对局 ---")
	# 此处只验抓牌与联网时序，避免测试结束时拾取音效仍在播放。
	_main.sfx.set_muted(true)
	_main._on_restart()
	await settle()
	if not need(_main.phase == _main.PHASE_ACTION and _main._actor == _main.my_seat
		and not _main.board.input_locked, "当前 BOT 局处于玩家可操作的行动阶段"):
		return
	var solo_state: GameState = _main.state
	var solo_pipe: Variant = _main.pipe
	var panel: JoinPanel = _main._open_join_panel()
	await process_frame
	panel._room_edit.text = "HOLD6"
	panel._on_host()
	if not need(await _until(func():
		return is_instance_valid(panel) and panel._net != null and panel._net.my_seat != ""
	, 600), "主机已入座，等待第二位对手"):
		panel._on_cancel()
		return

	var board: Board = _main.board
	var target: CardEntity = null
	var click_point := Vector2.INF
	# 查实际碰撞射线，避免靠直接写 _drag_cards 伪造抓牌状态。
	for card in board.cards:
		if not is_instance_valid(card) or not card.visible or not card.draggable or card.is_market:
			continue
		for offset in [Vector3.ZERO, Vector3(-0.3, 0, -0.5), Vector3(0.3, 0, 0.5)]:
			var point := board.camera.unproject_position(card.to_global(offset + Vector3(0, 0.045, 0)))
			var picked := board._pick_card(point)
			if picked != null and picked.draggable and not picked.is_market:
				target = picked
				click_point = point
				break
		if target != null:
			break
	if not need(target != null, "真实射线找到可抓取的玩家卡"):
		panel._on_cancel()
		return
	board._reset_click_track()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = click_point
	press.pressed = true
	board._unhandled_input(press)
	if not need(target in board._drag_cards and target.dragging,
		"真实按下事件已经抓起玩家卡"):
		panel._on_cancel()
		return

	var candidate: NetTransport = panel._net
	var foe := NetTransport.new(_main._host.url(), "HOLD6")
	foe.connect_to_server()
	var ready := await _until(func():
		foe.poll()
		return candidate.has_dealt_state() and candidate.phase() == PhaseMachine.ACTION
	, 600)
	check(ready, "抓牌期间第二位已到齐，候选连接收齐双座位快照和首阶段 phase")
	check(_main._net == null and _main.state == solo_state and _main.pipe == solo_pipe,
		"即便联网已就绪，抓着牌时仍保留原 BOT 局和操作管道")
	check(is_instance_valid(panel) and panel.visible and panel._waiting,
		"延迟交接期间等待面板继续显示，可取消")
	check(target in board._drag_cards and target.dragging,
		"对手加入不会中断当前抓牌或删除手中实体")

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = click_point
	release.pressed = false
	board._unhandled_input(release)
	check(board._drag_cards.is_empty(), "真实松手事件结束抓牌")
	var started := await _until(func():
		foe.poll()
		return _main._net == candidate and _main._net_table_drawn
	, 600)
	check(started, "松手后自动接入已经就绪的同一条连接")
	if started:
		check(_main.state == candidate.state() and _main.pipe == candidate,
			"延迟交接后局面和管道一起切到权威连接")
		check(_main._net_phase_seen and _main.phase == _main.PHASE_ACTION,
			"补读已经缓存的 phase，网络首阶段确实启动")
		var my_action := candidate.actor() == candidate.my_seat
		check(_main._actor == candidate.actor(), "延迟交接后行动座位与服务器一致")
		check(_main.btn_pass.disabled == not my_action
			and board.input_locked == not my_action,
			"延迟交接后的按钮与牌桌可操作状态符合服务器的行动座位")
		check(_main.btn_pass.text == (_main.TXT_ACTION_DONE if my_action else _main.TXT_BOT_ACTING),
			"延迟交接后按钮显示当前行动，而非停在等服务器")
	foe.close()
	if is_instance_valid(panel):
		panel._on_cancel()
	_main._reset_session_flags()
	await process_frame

# ---------- 工具 ----------

## 泵到 cond 成立。**用 process_frame 而不是 physics_frame**：
## main._process 挂在空闲帧上（_host.poll 和 _net.poll 都在那里），
## 而这一条判据的全部意思就是「那句 poll 在跑」
func _until(cond: Callable, frames := 240) -> bool:
	for i in frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()
