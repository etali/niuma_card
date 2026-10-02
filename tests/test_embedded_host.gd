# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 游戏进程**自己**开的那个服务器（net/embedded_host.gd）
##
## 钉的是「开房间」这条路：以前要先去命令行起一个无头专服
## （或者双击一个 shell 脚本），现在游戏自己起一个、自己连回来。
##
## 为什么值得单独一条判据：这一层做的事看着只有三行（new / start / poll），
## 而它替掉的那个 shell 脚本里藏着一个**两份写死的数** ——
## 脚本发现 8910 被占会顺延到 8911，而客户端那个默认地址不跟着变，
## 症状是「服务器开着，游戏说连不上」。所以这里要钉的不是「能开端口」，
## 是「**开成的那个端口就是 url() 报出来的那个**」。
##
## 和 test_net_socket 的分工：那条钉 net_transport.gd 的收发（八个场景），
## 这条只钉「进程内那个服务器起得来、报的地址连得上、关得掉」。
##
## 变异提示（都实跑确认过红，登记进 tools/mutate_check.py）：
##   1. EmbeddedHost.url() 里 `port` 换成 DEFAULT_PORT
##      → T2「报出来的地址连得上」红（顺延之后报的是没开的那个端口）
##   2. EmbeddedHost.start 里去掉开头那句 stop()
##      → T3「重开一次不会漏掉旧的那个」红（旧服务器还占着端口）
##   3. EmbeddedHost.stop 里不置 server = null
##      → T4「关掉之后 running() 为假」红

const PORT_BASE := 47300

## 这个文件的服务器是 EmbeddedHost 而不是 NetServer（前者包着后者），所以不走
## net_boot —— 起法本身就是被测的东西（T1 验它报的端口是真开成的那个）。
## 起完之后赋给 _srv，好让脚手架的 net_pump / net_stop 也管得着它：
## 两个类都有 poll() 和 stop()，net_pump 问的是方法在不在，不是类型
var _host: EmbeddedHost = null

func _initialize() -> void:
	print("=== 进程内服务器测试 ===")
	CardDB.ensure_loaded()
	await _t1_start()
	await _t2_self_connect()
	await _t3_restart()
	_t4_stop()
	_t5_lan()
	_t6_takeover_port()
	net_stop()
	finish()
# ---------- T1 起得来 ----------

func _t1_start() -> void:
	print("\n--- T1 起服务器 ---")
	net_stop()
	_host = EmbeddedHost.new()
	_srv = _host
	var r: Dictionary = _host.start(PORT_BASE)
	check(bool(r["ok"]), "端口开起来了（%s）" % str(r.get("reason", "")))
	if not r["ok"]:
		return
	check(_host.running(), "running() 为真")
	check(int(r["port"]) == _host.port, "返回的端口和 host.port 是同一个")
	# 顺延是为了「上一次跑剩的 TIME_WAIT 占着」这种情况。**报出来的必须是真开成的那个**：
	# 那个 shell 脚本当年顺延成功反而更糟，因为客户端那个地址是另一份写死的数
	check(_host.url() == "ws://127.0.0.1:%d" % _host.port,
		"url() 报的是真开成的那个端口（实为 %s，端口 %d）" % [_host.url(), _host.port])

# ---------- T2 自己连自己 ----------

## 这一条是「开房间」那个按钮的全部内容：起服务器 → 照它报的地址连回来 → 入座。
##
## 桌面版主机侧走的就是这条路 —— **和客户端侧同一条**
## （NetTransport → net/server.gd → net/room.gd），
## 主机不因为「服务器在自己进程里」而少走任何一步。
## 少了这条判据，「开房间」可能在起了服务器之后根本没连上，
## 而画面上显示的是「等对手进来」—— 一个永远等不到的等待
func _t2_self_connect() -> void:
	print("\n--- T2 自己连自己 ---")
	if _host == null or not _host.running():
		check(false, "T2 需要 T1 的服务器")
		return
	var me := NetTransport.new(_host.url(), "MYROOM")
	me.connect_to_server()
	var seated := await net_until([me], func(): return me.my_seat != "")
	check(seated, "主机侧自己入座了（座位 %s）" % me.my_seat)
	# 对手从「局域网那个地址」连进来 —— 这里用回环代打（同一个服务器），
	# 钉的是「第二个人进得来、两边开局」
	var foe := NetTransport.new(_host.url(), "myroom")
	foe.connect_to_server()
	var both := await net_until([me, foe],
		func(): return me.my_seat != "" and foe.my_seat != "")
	check(both, "对手也入座了（座位 %s）" % foe.my_seat)
	check(me.my_seat != foe.my_seat and foe.my_seat != "",
		"两人坐的不是同一个座位（%s / %s）" % [me.my_seat, foe.my_seat])
	# 房间码大小写不敏感：对手填的是小写 "myroom"，进的必须是同一间。
	# 分成两间的症状是「两个人都在等对手」，而两边都觉得自己填对了
	check(_host.server.room_count() == 1,
		"大小写不同的房间码进了同一间（房间数 %d）" % _host.server.room_count())
	me.close()
	foe.close()
	await net_pump([me, foe], 4)

# ---------- T3 重开 ----------

func _t3_restart() -> void:
	print("\n--- T3 重开 ---")
	if _host == null:
		check(false, "T3 需要 T1 的服务器")
		return
	var old := _host.port
	var r: Dictionary = _host.start(PORT_BASE)
	check(bool(r["ok"]), "重开一次也起得来")
	# 旧的那个要先关掉，否则它占着端口 —— 顺延之后新端口是另一个数，
	# 而玩家可能已经把旧地址报给对手了
	check(int(r["port"]) == old,
		"重开落在同一个端口 %d（实为 %d）—— 说明旧的那个真关了" % [old, int(r["port"])])

# ---------- T4 关得掉 ----------

func _t4_stop() -> void:
	print("\n--- T4 关服务器 ---")
	if _host == null:
		check(false, "T4 需要服务器")
		return
	_host.stop()
	check(not _host.running(), "关掉之后 running() 为假")
	check(_host.port == 0, "端口归零 —— 界面据此知道没在开房")
	_host.stop()
	check(true, "关两次不炸（退出房间和重开一局都会调它）")

# ---------- T5 报给对手的地址 ----------

func _t5_lan() -> void:
	print("\n--- T5 报给对手的地址 ---")
	# 可能是空的（没连网），所以判的是**形状**而不是「有几个」
	for u in EmbeddedHost.lan_urls(8910):
		check(u.begins_with("ws://") and u.ends_with(":8910"),
			"局域网地址是完整的 ws:// 地址：%s" % u)
	for ip in EmbeddedHost.lan_ips():
		check(not ip.contains(":"), "滤掉了 IPv6（%s）—— 那种地址填进输入框太容易错" % ip)
		check(not ip.begins_with("127."), "滤掉了回环（%s）—— 回环单独报" % ip)
		check(not ip.begins_with("169.254."),
			"滤掉了 link-local（%s）—— 报出来会让人以为能用" % ip)
	check(true, "局域网地址共 %d 个（可以是 0，没连网时就是空的）"
		% EmbeddedHost.lan_urls(8910).size())

# ---------- T6 接管开房的端口：先默认，占了才随机 ----------

## `start_takeover()` 的取舍：**优先那个两边都已经知道的数**。
##
## 为什么这条判据值得单独存在 —— 它钉的是用户报的那个坑的根：
## 头一版接管一律开随机端口，于是主机进程走了之后，回来那位手里只有房间码，
## 端口号只长在接管方屏幕上（用户原话「输入相同的密码还是连不上」）。
## 而默认端口是面板默认地址里那个数（JoinPanel.DEFAULT_URL）：
## 同机双开时他地址一栏一个字都不用改。
##
## 两支都要判，而且**都得是确定的**，所以端口占用状态由这一节自己摆：
##   8910 空着 —— 必须落在 8910。落别处就等于「玩家得去问」
##   8910 占着 —— 必须落到随机段，**不许顺延到 8911**：
##                顺延成功比失败更糟，8911 既不是那个大家都知道的数，
##                又不像随机端口那样一眼看出「得问」
##
## 8910 本身可能被这台机器上**别的东西**占着（另一局游戏、别的程序）。
## 那种情况下头一支判不了，于是跳过它而不是红 —— 但要说出来，
## 「跳过了」和「过了」在输出里不能长一个样
func _t6_takeover_port() -> void:
	print("\n--- T6 接管开房的端口 ---")
	net_stop()

	# 先看 8910 到底空不空：占着的话头一支没法判
	var probe := NetServer.new()
	var probe_r: Dictionary = probe.start(EmbeddedHost.DEFAULT_PORT)
	var default_free: bool = bool(probe_r["ok"])
	probe.stop()

	if default_free:
		_host = EmbeddedHost.new()
		_srv = _host
		var r: Dictionary = _host.start_takeover()
		check(r["ok"] and int(r["port"]) == EmbeddedHost.DEFAULT_PORT,
			"默认端口空着就开在默认端口（%d ← %d）—— 开别处的话回来那位"
				% [int(r.get("port", -1)), EmbeddedHost.DEFAULT_PORT]
			+ "手里只有房间码，端口号只在我屏幕上，他照默认地址填就是连不上")
		check(_host.url().ends_with(":%d" % EmbeddedHost.DEFAULT_PORT),
			"报出来的地址也是那个端口（%s）" % _host.url())
		net_stop()
	else:
		check(true, "跳过「默认端口空着」那一支 —— 这台机器上 %d 被别的东西占着"
			% EmbeddedHost.DEFAULT_PORT)

	# 占着 8910，再让接管开一次：必须退到随机段，不许顺延
	var squatter := NetServer.new()
	var sq: Dictionary = squatter.start(EmbeddedHost.DEFAULT_PORT)
	if not sq["ok"]:
		check(true, "跳过「默认端口被占」那一支 —— 占不上 %d（%s）"
			% [EmbeddedHost.DEFAULT_PORT, str(sq.get("reason", ""))])
		return
	_host = EmbeddedHost.new()
	_srv = _host
	var r2: Dictionary = _host.start_takeover()
	check(r2["ok"], "默认端口被占的时候照旧开得出房（%s）"
		% str(r2.get("reason", "")))
	var p2 := int(r2.get("port", -1))
	check(p2 >= EmbeddedHost.RANDOM_PORT_LO and p2 <= EmbeddedHost.RANDOM_PORT_HI,
		"退到随机段（%d ∈ [%d, %d]）" % [p2,
			EmbeddedHost.RANDOM_PORT_LO, EmbeddedHost.RANDOM_PORT_HI])
	check(p2 > EmbeddedHost.DEFAULT_PORT + EmbeddedHost.PORT_TRIES
		or p2 < EmbeddedHost.DEFAULT_PORT,
		"**没有顺延到 %d..%d**（实为 %d）—— 顺延成功比失败更糟："
			% [EmbeddedHost.DEFAULT_PORT + 1,
				EmbeddedHost.DEFAULT_PORT + EmbeddedHost.PORT_TRIES - 1, p2]
		+ "那个号既不是两边都知道的数，又不像随机端口那样一眼看出「得去问」")
	net_stop()
	squatter.stop()

# ---------- 泵 ----------