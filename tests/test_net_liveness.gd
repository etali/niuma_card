# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 判活：心跳（Protocol.PING / PONG，v6）和它撑起来的那两件事 ——
## 「对面那个服务器其实已经没了」和「座位被一个死连接占着」。
##
## 这一条是从玩家那句报告倒推出来的：**「我作为主机断开后，无法重连，
## 对手处也没有自动建立新的服务端以等待我接入」**。查下去发现接管那条路
## （main._can_take_over_host）本身是好的，坏在它等的那个信号永远不来。
##
## 起因是 TCP **保序但不保活**。实测（当时写了两条一次性探针，量完就删了，
## 结论记在 Protocol.PING 那段注释里）：
##   - 主机**进程被 kill** → 操作系统替它关 fd，对手 0.00 秒收到 no_server ✔
##   - 主机**网络断了 / 机器睡了**（进程还活着）→ 6 秒过去 socket 还是
##     STATE_OPEN，disconnected 一条都没发 ✘
## 也就是说旧代码只覆盖了「进程走了」那一半 —— 而那一半恰好是
## tests/test_host_takeover.gd 验的那一半（它直接 emit disconnected）。
## 于是接管功能「有测试、也真能用」，同时玩家报的那个场景一次都过不去。
##
## **为什么这一条必须用墙钟**（回归套里少见，其余判据一律不看时间）：
## 判死的定义就是「过了多少秒还没有回音」，没有时间就没有这个性质。
## 所以这里把两个阈值调小（NetTransport.silent_sec / NetServer.peer_silent_sec，
## 那两处的注释写了为什么它们是 var 而不是 const）——
## 跑的是同一段代码、同一条路径，只是把秒表拨快。
## 换成「注入一个假时钟」的话，真跑时那条路就没人验了。
##
## 判死之后接管那一段（no_server → _take_over_host）不在这里验：
## 那是 tests/test_host_takeover.gd 的活，两边的接缝是**那个码**——
## T3 钉的就是「判死发出来的码正好在接管白名单里」

const PORT_BASE := 47300

func _initialize() -> void:
	print("=== 判活（心跳）测试 ===")
	CardDB.ensure_loaded()
	await _t1_ping_pong()
	await _t2_pong_before_join()
	await _t3_silent_server_declared_dead()
	await _t4_server_sweeps_silent_peer()
	await _t5_sweep_frees_seat()
	net_stop()
	finish()

# ---------- 起服务器 / 起客户端 ----------

## 判活这一整个文件的客户端都要把两个墙钟量压小：生产默认是心跳 3 秒、
## 判死 10 秒，照那个跑一条判据就得等十几秒墙钟。压到 0.05 / 0.4 之后
## 判据的形状不变（还是「几个心跳间隔之后该判死」），只是间隔短了。
## **这两个数是判据的一部分**，_pump_for 里那些毫秒数都是按 silent=0.4 折算的
func _live_client(room := "TEST") -> NetTransport:
	return net_client(room, "", 0.05, 0.4)

func _seated_pair(room := "TEST") -> Array:
	# 判活这一路要压小 ping/silent（不然一条判据就得等十秒墙钟），
	# 所以传自己那个工厂进去，不用默认的 net_client
	return await net_seated_pair(PORT_BASE, 20260829, room, _live_client)

# ---------- T1 一去一回 ----------

func _t1_ping_pong() -> void:
	print("\n-- T1 ping 发出去、pong 回得来 --")
	var pair := await _seated_pair()
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]

	# rtt_ms 是 pong 唯一的**观察点**：判活那一笔（_seen_at）记在 _on_text
	# 最外面，任何消息都会记 —— 也就是说「pong 根本没回」和「pong 回了」
	# 在 _seen_at 上分不开（seated、phase、applied 全都能顶替它）。
	# 量出延迟这件事只有 PONG 那个分支干，所以判它
	if need(await net_until([a, b], func(): return a.rtt_ms >= 0),
		"客户端量到了往返延迟（rtt_ms=%d）—— 服务器回了 pong" % a.rtt_ms):
		check(a.rtt_ms < 2000,
			"延迟是个像样的数（%d 毫秒）—— 大得离谱说明 at 没原样带回来" % a.rtt_ms)

	# 两边**各自**判活。只有一边发心跳的话，另一边到点照样判死自己那条 ——
	# 症状是「打着打着一方被踹出去，而对面什么都没发生」
	check(await net_until([a, b], func(): return b.rtt_ms >= 0),
		"另一边也量到了（rtt_ms=%d）—— 心跳不是单向的" % b.rtt_ms)

	# 心跳**不该把连接判死**：ping 一直有回音，_seen_at 一直在往前走。
	# 这一条是反向判据（防「阈值算反了」那类改动：把 >= 写成 <=
	# 会让一条好连接每帧都判死，而 T3 那种正向判据照样绿）
	var down: Array = []
	a.disconnected.connect(func(c: String, r: String): down.append([c, r]))
	await net_pump_for([a, b], 500)   # ≈ 10 个心跳间隔，远超 silent_sec(0.4)
	check(down.is_empty(),
		"有回音的连接不会被判死（实为 %d 条断线）—— 收到东西要记 _seen_at"
			% down.size())
	net_stop()

# ---------- T2 还没进房间就该回 pong ----------

## 判活要比房间早。这一条盯的是 server._on_text 里 PING 那个分支
## **没走 _dispatch**（不看他进没进房间）：一条连上了还没入座的连接
## 也该量得出往返 —— 面板上那句「连不上」和「连上了但房间满」
## 是两种完全不同的处境，而在这条判据之前它们在屏幕上长得一样
func _t2_pong_before_join() -> void:
	print("\n-- T2 没入座也回 pong --")
	if not net_boot(PORT_BASE):
		return
	var c := _live_client("NOJOIN")
	# **把 join 按住**：_sent_join 预置成 true，于是 poll 进 STATE_OPEN 之后
	# 那句 _send(Protocol.join(...)) 不会执行，而心跳照发 ——
	# 这正是要测的那个状态「连上了、还没进房间」。
	#
	# 动私有量是有意的：从外面造不出这个状态。原先试的是
	# 「让第三个人撞 room_full，再看他被拒之前有没有量到往返」，
	# 那条**偶发红** —— join 和第一条 ping 是同一批发出去的，
	# 服务器在同一次 poll 里先读到 join 就先把他踢了，pong 没机会回。
	# 判据不该去赛跑
	c._sent_join = true

	if not need(await net_until([c], func(): return c.rtt_ms >= 0),
		"没入座的连接也量到了往返（rtt_ms=%d）—— ping 不该先过房间那道，"
			% c.rtt_ms
		+ "交给 _dispatch 的话它换回来的是一条 no_room"):
		net_stop()
		return
	# 真的没进房间 —— 上面那条量到的往返不是「其实已经入座了」换来的
	check(c.my_seat == "", "他确实还没入座（座位「%s」）" % c.my_seat)
	check(_srv.room_count() == 0,
		"服务器一间房都没开（实为 %d 间）—— ping 不该顺手把人放进房间"
			% _srv.room_count())
	net_stop()

# ---------- T3 服务器不说话了 ----------

## 玩家那句「对手处也没有自动建立新的服务端」的**正主**。
##
## 造的场景就是他遇到的那个：服务器还在、socket 还开着，只是**不再 poll**
## （= 主机那台机器网断了 / 睡了，进程没退）。这时候
##   - 一个字节都不会来
##   - socket 停在 STATE_OPEN，get_close_code() 没有值
## 旧代码在这里是**彻底沉默**的：等多久都不发 disconnected。
##
## 判据分两层，第二层才是接得上接管那条路的：
##   1. 到点了要发 disconnected —— 症状层（不发的话玩家停在「对手忽然不动了」）
##   2. 那个码要**正好在 main.TAKEOVER_CODES 里** —— 这是两个文件之间的接缝。
##      发一个新造的码（比如 "silent"）功能上「也算宣告了断线」，
##      而接管白名单认不出它 —— 于是留下的那位收到一条红字提示、
##      没有人开新房，玩家看到的和什么都不做**一模一样**
func _t3_silent_server_declared_dead() -> void:
	print("\n-- T3 服务器没回音 → 判死 --")
	var pair := await _seated_pair()
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	var down: Array = []
	a.disconnected.connect(func(c: String, r: String): down.append([c, r]))

	# 「主机的网断了」：服务器对象留着（不 stop —— stop 会让操作系统发关闭帧,
	# 那是 kill 进程那条已经能测的路），只是**再没有人替它 poll**。
	# 于是 a 发出去的 ping 落在内核缓冲里，永远没人读
	var frozen: NetServer = _srv
	_srv = null
	await net_pump_for([a, b], 900)   # silent_sec = 0.4 秒，留足两倍多

	if need(not down.is_empty(),
		"服务器沉默 %.1f 秒后客户端自己判死（实为 %d 条）—— TCP 保序但不保活，"
			% [a.silent_sec, down.size()]
		+ "socket 会一直停在 STATE_OPEN，没人告诉你对端已经没了"):
		var code: String = down[0][0]
		# 白名单从 main 那边取，不在这儿抄一份常量 ——
		# 抄的话两边各改一处就再也对不上，而这条判据照样绿
		var takeover: Array = load("res://scenes/main.gd").TAKEOVER_CODES
		check(code in takeover,
			"判死用的码在接管白名单里（%s ∈ %s）—— 不在的话 _can_take_over_host "
				% [code, str(takeover)]
			+ "认不出它：留下那位收到一句红字，而没有人去开新房")
		check(str(down[0][1]).find("回音") >= 0,
			"断线原因说得出人话（实为「%s」）—— 这句会原样显示给玩家"
				% str(down[0][1]))
	frozen.stop()

# ---------- T4 服务器这一侧的兜底 ----------

## 反方向：**客户端**不说话了（他的网断了），服务器要发现。
##
## 为什么服务器也得判 —— 座位是服务器在记的（NetRoom.occupants）。
## 那条 socket 停在 STATE_OPEN，服务器不知道人已经没了，于是
## 留下的那一位收不到 foe_left：屏幕上「对手忽然不动了」，
## 而那和「他在想」「他在翻牌」分不开（scenes/main.gd 的 _offer_reconnect / _on_net_down 的断线提示没有触发）
func _t4_server_sweeps_silent_peer() -> void:
	print("\n-- T4 客户端没声音 → 服务器按掉线处理 --")
	var pair := await _seated_pair()
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	_srv.peer_silent_sec = 0.4
	_srv.sweep_every_sec = 0.05

	# 计数用**数组**而不是 int。GDScript 的 lambda 捕获局部变量是**按值**的：
	# `var n := 0` + `func(): n += 1` 加的是闭包自己那一份，外面那个永远是 0 ——
	# 判据于是恒红，而且红得像被测代码没干活（这一条真踩过，查了一轮服务器）。
	# 数组是把**引用**复制进去，改内容外面看得见
	var left: Array = []
	a.foe_left.connect(func(): left.append(1))
	# b「的网断了」：不再替他 poll（他那条 socket 还开着，只是没人发也没人收）。
	# **a 要继续泵** —— 判活是服务器扫出来的，而服务器只在 poll 里扫
	await net_pump_for([a], 900)

	check(not left.is_empty(),
		"服务器扫出了没声音的连接，留下那位收到 foe_left（实为 %d 次）—— "
			% left.size()
		+ "少了这一步他看到的是「对手忽然不动了」，和「对手在想」分不开")
	# 扫的是**沉默**的那一个，不是「所有人」。少了这条判据的话，
	# 把阈值判反（把没超时的也踢）能全绿：a 自己也会收到 foe_left
	check(a.my_seat != "" and a.online(),
		"还在说话的那一位没被牵连（座位 %s，连接 %s）—— 扫的是沉默的那条"
			% [a.my_seat, "开着" if a.online() else "已关"])
	net_stop()

# ---------- T5 座位要真腾出来 ----------

## 玩家那句「**无法重连**」的一种真实成因，而且它只在这条判据下才现形。
##
## 场景：他的网断了 → 进程重启（或者干脆换了台机器）→ 手里那串
## 重连令牌没了（令牌只在内存里）。他再连回来走的是 free_seat 那条路
## （NetRoom._on_join 里「没令牌 → 找空座」），而**座位从来没腾空过**：
## 服务器手里那条死 socket 一直算他在座。于是他拿到的是 room_full ——
## 一间他自己的房间，把他自己挡在门外。
##
## 判的是「重连拿到座位」而不是「occupants 变了 0」：
## 后者是实现细节，前者是玩家碰得到的那一面
func _t5_sweep_frees_seat() -> void:
	print("\n-- T5 扫掉死连接之后座位能坐回去 --")
	var pair := await _seated_pair("SEAT")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	var gone_seat: String = b.my_seat
	_srv.peer_silent_sec = 0.4
	_srv.sweep_every_sec = 0.05

	# b 的网断了（不再 poll 他），等服务器扫掉
	await net_pump_for([a], 900)

	# 换一个**没有令牌**的新客户端去坐 —— 这就是「进程重启过」的样子。
	# 有令牌那条路走的是 NetRoom.resume，跟座位空不空无关，测不到这个坑
	var c := _live_client("SEAT")
	# 等的是「坐上了」**或者**「被拒了」。不能拿 online() 当「被拒」的信号 ——
	# 它在握手期间（STATE_CONNECTING）也是 false，那样这个条件一进来就成立，
	# 判据变成「还没连上就说没坐上」，恒红
	var refused: Array = []
	c.disconnected.connect(func(code: String, _r: String): refused.append(code))
	var done := await net_until([a, c],
		func(): return c.my_seat != "" or not refused.is_empty())
	if need(done and c.my_seat != "",
		"重启之后（手里没有令牌）能坐回去 —— 座位 %s"
			% (c.my_seat if c.my_seat != "" else "没坐上")):
		check(c.my_seat == gone_seat,
			"坐回的是原来那个座位（%s，走前是 %s）" % [c.my_seat, gone_seat])
	else:
		# 这一支就是玩家报的那个症状，把它原样说出来。
		# 把拒连码带上：room_full 正是「座位没腾空」那种坏法的指纹
		check(false, "没坐上（%s）—— 死连接还占着座位，一间自己的房把自己挡在门外"
			% (str(refused[0]) if not refused.is_empty() else "一直没有回应"))
	check(a.online(), "留下那位这一路没被断开")
	net_stop()
