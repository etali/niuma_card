# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 真开一个端口：NetServer + 两个 NetTransport，走完整的 WebSocket 往返。
##
## 和 test_net_parity / test_net_replay 分工不同 —— 那两条是**无端口**的
## （直接喂 NetRoom.handle_intent），钉的是「两条路径同态」和「状态 = f(种子, 意图)」。
## 这一条钉的是它们碰不到的那一段：`net/net_transport.gd` 整个文件。
## 握手、submit 的自泵帧、超时、seated 快照重建、关闭码 ——
## 在这条判据之前这些全靠人眼看，一行覆盖都没有。
##
## 为什么能在一个进程里起服务器：NetServer 是 RefCounted，谁 poll 都行。
## 早先服务器逻辑长在 tools/pvp_server.gd 里（`extends SceneTree`），
## 而**测试自己就是 SceneTree**，装不下第二个 —— 那时这条判据写不出来。
##
## 变异提示：**九条都实跑确认过红**，而且都登记进了 tools/mutate_check.py
## （第 5 项写的是这个文件 —— net/ 不在 TEST_FOR 里，省略会退到 test_engine.gd，
## 那边跑得过，等于没测）。所以这张单子不用手抄着跑，`mutate_check.py net_transport`
## 就是它。列在这里是为了让人在改这几处代码前先知道谁在盯着：
##   1. net_transport.poll() 里删掉 `_send(Protocol.join(...))`
##      → 「双方都入座了」红（握手不发，永远等不到 seated）
##   2. net_transport._next_frame() 末尾删掉 poll()
##      → 「submit 自己泵帧」红（挂在 await 上收不到回音，8 秒超时）
##   3. net_transport.submit 里的 `if _pending:` 改成 `if false:`
##      → 「上一条在飞时再发被拒」红
##   4. net_transport._on_packet 里的 4 字节分流改成 `if false:`
##      → 「peer id 握手包被认出来」红
##   5. net_transport._on_applied 里去掉 seat 判断（只剩 `if _pending:`）
##      → 「submit 拿回来的是自己那条」红（对手那条被当成自己的回音吞掉）
##   6. net/server.gd 的 _kick 里 `p.close(码, 原因)` 改成 `p.close()`
##      → 「拒连给了原因」红（关闭码退化成 1000，客户端只知道「连不上」）
##   7. net/protocol.gd 的 is_client_msg 改成 `return true`
##      → 「客户端伪造 seated 被拒」红
##   8. net/protocol.gd 的 clip_reason 直接返回原文
##      → 「截过的原因塞得进关闭帧」红（超 123 字节 close() 静默不干活）
##   9. net/protocol.gd 的 APPLIED 分支不过 restore_uids
##      → 「整个结果里没有 float uid」红
##
## 其中 2 和 4 起初都是 MISS，各自缺的是**观察点**而不是判据：
##   - 2：_keep_pumping 把正在 submit 的那个客户端也一起 poll 了，
##     等于替被测代码干了活。改成只摇服务器 + 旁观那一个才红。
##   - 4：peer_id 写了没人读。T1 现在判 peer_id != 0 —— 那是这个分流
##     唯一看得见的地方（认不出的后果是每连一次刷一屏 push_warning）。
## 「改坏了却全绿」十有八九是这一类：判据在，但没人观察得到。
##
## **这里不放「端到端几帧」那类延迟判据**，写过一条又删了，经过记在这儿
## 免得再写一遍：查「联机延迟很高」时加过一条 T9，判「一条 dragging 帧
## 一轮泵就到对面」（一轮 = 服务器 poll + 客户端各 poll + 过一帧）。
## 单跑稳过，进整套之后 6 次里红 4 次 —— 而且红的是「用了 2 轮」。
##
## 它不是被测代码的问题：本机回环的字节有没有在**同一轮**里落进服务器的
## socket 缓冲，是内核调度说了算的，整套跑的时候机器忙，就常常差那一下。
## 也就是说「一轮就到」压根不是这份代码保证的性质，那条判据从一开始就不成立。
## 想量延迟就单独写探针手工跑，别往回归套里放 —— 偶发红比没有判据更糟
## tools/mutate_check.py 要求基线先通过，偶发失败会使整轮变异检查无效。
##
## 那次排查真正的结论：传输层没有攒帧（`net_transport._send` 那段注释记着
## 「发完补一次 poll」为什么是零收益），延迟源在 `scenes/board.gd` 的广播节流上，
## 由 `tests/test_foe_drag.gd`「牌在动的时候每帧都发」盯着 —— 那条是本地的、
## 不过网、不看墙钟，所以稳。

const PORT_BASE := 47100
const A := GameState.PLAYER
const B := GameState.AI

func _initialize() -> void:
	print("=== 真 socket 联机测试 ===")
	CardDB.ensure_loaded()
	await _t1_handshake()
	await _t2_intent_roundtrip()
	await _t3_busy_and_offline()
	await _t4_bad_table_hash()
	await _t5_forged_message()
	await _t6_drag_forward()
	await _t7_foe_left()
	await _t8_uids_stay_int()
	net_stop()
	finish()

# ---------- 起服务器 / 起客户端 ----------
## 起服务器 + 两个客户端并等到双方入座。返回 [a, b]，失败返回 []
func _seated_pair(seed_value := 0, room := "TEST") -> Array:
	var pair: Array = await net_seated_pair(PORT_BASE, seed_value, room)
	if pair.is_empty():
		return []
	# 这个文件里「握手能走通」本身就是被测的东西（变异表第 1 条盯的就是它），
	# 所以成功也记一笔；其余文件的壳子只在失败时记
	check(true, "双方都入座了")
	return pair

# ---------- T1 握手 ----------

func _t1_handshake() -> void:
	print("\n-- T1 握手与开局快照 --")
	var pair := await _seated_pair(20260826)
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]

	check(a.my_seat == A and a.foe_seat == B, "先连的坐 %s（实为 %s）" % [A, a.my_seat])
	check(b.my_seat == B and b.foe_seat == A, "后连的坐 %s（实为 %s）" % [B, b.my_seat])
	check(a.resume_token != "" and b.resume_token != "", "两边都拿到了重连令牌")
	check(a.resume_token != b.resume_token, "两个座位的令牌不同")

	# 4 字节的 peer id 握手包被认出来了 —— 服务器用 WebSocketMultiplayerPeer，
	# 它握手完先塞一个 4 字节包过来，那是 MultiplayerPeer 自己的协议。
	# 认不出的话它会掉进「不是 JSON 对象」那条 push_warning：
	# 每连一次刷一屏，而真解不开的包就埋在那一屏里没人看了。
	# 这条判据是那个分流唯一的观察点 —— peer_id 除此之外没人读，
	# 没有它的话把分流删掉全套 67 条一条不红（实测）
	check(a.peer_id != 0 and b.peer_id != 0,
		"peer id 握手包被认出来（a=%d b=%d）" % [a.peer_id, b.peer_id])
	check(a.peer_id != b.peer_id, "两条连接的 peer id 不同")

	# 快照重建：seated 里带的是全量快照，客户端 StateCodec.restore 出来的
	# 状态要和服务器那份一致。先进来的那位收到的是**开局前**的空局面，
	# 满座之后服务器补发了一份 —— 这一条就在验那次补发
	var room: NetRoom = _srv.rooms["TEST"]
	var want := StateCodec.state_hash(room.state)
	check(StateCodec.state_hash(a.state()) == want, "先连那位的快照和服务器一致")
	check(StateCodec.state_hash(b.state()) == want, "后连那位的快照和服务器一致")
	check(a.state().players[A]["cards"].size() > 0, "客户端手上真有牌（%d 张）"
		% a.state().players[A]["cards"].size())

	# 阶段广播
	await net_until([a, b], func(): return a.phase() != "" and b.phase() != "")
	check(a.phase() == PhaseMachine.ACTION, "开局是行动阶段（实为 %s）" % a.phase())
	check(a.actor() == room.phase.actor, "行动方和服务器一致（%s）" % a.actor())
	check(a.my_turn() != b.my_turn(), "同一时刻只有一边轮到")
	check(a.online() and b.online(), "两边都在线")

	# 第三个人进来要被拒 —— 而且要拿到原因，不能只是「连不上」。
	#
	# 注意 got 是**改内容**而不是重新赋值：GDScript 的 lambda 按值捕获，
	# `got = {...}` 只改了 lambda 自己那份，外层永远看不到。
	# 这个坑让这条判据先报了一次假红（拒连日志明明打了，got 还是空的）
	var c := net_client("TEST")
	var got := { "code": "", "reason": "" }
	c.disconnected.connect(func(code, reason):
		got["code"] = code
		got["reason"] = reason)
	await net_until([a, b, c], func(): return got["code"] != "")
	check(got["code"] == Protocol.CLOSE_ROOM_FULL,
		"第三个人被拒且给了原因（%s：%s）" % [got["code"], got["reason"]])
	c.close()

	a.close()
	b.close()
	await net_pump([a, b], 3)

# ---------- T2 意图往返 ----------

func _t2_intent_roundtrip() -> void:
	print("\n-- T2 意图往返：submit 等回音 --")
	var pair := await _seated_pair(4242)
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	await net_until([a, b], func(): return a.actor() != "")
	var room: NetRoom = _srv.rooms["TEST"]

	# 轮到谁就让谁买。**先连的不一定先行动** —— action_first() 是
	# draw_first 的反面，判据不该假设这个方向
	var first: NetTransport = a if a.my_turn() else b
	var second: NetTransport = b if a.my_turn() else a

	# 对手那条 applied 要走信号（不是被当成自己的回音吞掉）
	var foe_saw: Array = []
	second.applied.connect(func(r): foe_saw.append(r))

	var before := StateCodec.state_hash(room.state)
	# 这一句是这条判据的核心：submit 是 coroutine，挂在自己的 _next_frame 上。
	# 而 _next_frame 除了等帧还**自己 poll 一次** —— 没有那一下，
	# 唤醒它的回音就永远收不到（场景层忘了调 poll 时的表现是按钮全灰）
	var pumping := true
	# 只摇服务器 + 旁观那个。**first 不进去** —— 它要靠 _next_frame 自己那下 poll
	_keep_pumping([second], func(): return pumping)
	var r: Dictionary = await first.submit(Intent.buy(first.my_seat, 0))
	pumping = false
	check(r.get("ok", false), "买卡落地了（submit 自己泵帧；%s）" % r.get("reason", ""))
	check(int(r.get("seq", -1)) != -1 or r.has("new_uid"), "回音带着落地结果")

	await net_pump([a, b], 4)
	# 比哈希而不是数手牌张数：买卡是**花现金**换一张产出卡，
	# 张数是降的（30 → 21）。第一版写成「张数变多了」，报的红是判据自己错
	check(StateCodec.state_hash(room.state) != before, "服务器那份状态真的变了")
	check(room.state.find_card(first.my_seat, int(r.get("new_uid", -1))) != null,
		"买到的那张进了服务器那份手牌（uid=%s）" % r.get("new_uid", "?"))
	var mine_ops: Array = []
	for e in foe_saw:
		mine_ops.append(str((e as Dictionary).get("op", "?")))
	check(foe_saw.size() > 0, "对手的动作走 applied 信号（收到 %d 条：%s）" % [
		foe_saw.size(), ", ".join(mine_ops)])
	var saw_buy := false
	for e in foe_saw:
		if str((e as Dictionary).get("op", "")) == Intent.OP_BUY:
			saw_buy = true
	check(saw_buy, "对手看到的是那条买卡")

	# 不轮到你的时候发意图 → 被拒，而且报的是次序而不是规则
	pumping = true
	_keep_pumping([first], func(): return pumping)   # 发的是 second，它不进去
	var bad: Dictionary = await second.submit(Intent.buy(second.my_seat, 0))
	pumping = false
	check(not bad.get("ok", true), "不轮到你时买卡被拒")
	check(str(bad.get("code", "")) == "not_your_turn",
		"报的是次序（%s）" % bad.get("code", ""))

	# 在飞的时候来了**对手**那条 applied：不能当成自己的回音吞掉。
	#
	# 为什么直接喂 _on_text 而不摆一个真局面：真跑的时候两条 applied
	# 谁先到取决于服务器的处理次序，摆不出稳定的局面 —— 而这条判据要么稳要么不写。
	# 喂进去的是一条完整的协议消息，走的还是 _on_text 那条路，
	# 只有「谁发的」是假的。放在 T2 最后，因为 action_done 会把回合让出去。
	#
	# 少了座位判断的话：submit 返回的是对手那条结果，
	# 于是自己这边照对手的落地去演 —— 两边从此画的不是同一局，而且不报错
	var mine: Array = []
	_in_flight(first, Intent.action_done(first.my_seat), mine)
	first._on_text(Protocol.encode(Protocol.applied({
		"ok": true, "op": Intent.OP_BUY, "seat": second.my_seat,
		"new_uid": 999, "market_idx": 0, "removed_uids": [] }, 99)))
	check(mine.is_empty(), "对手那条不算自己的回音（submit 还在等）")
	await net_pump([a, b], 8)
	if need(not mine.is_empty(), "自己那条最后还是回来了"):
		var got: Dictionary = mine[0]
		check(str(got.get("seat", "")) == first.my_seat,
			"submit 拿回来的是自己那条（seat=%s）" % got.get("seat", ""))
		check(str(got.get("op", "")) == Intent.OP_ACTION_DONE,
			"而且是自己发的那个 op（%s）" % got.get("op", ""))

	a.close()
	b.close()
	await net_pump([a, b], 3)

## 裸 socket 连上服务器（不走 NetTransport）。
## 手搓包才能测「客户端不可能发出来的东西」：假 table_hash、伪造的 seated、
## 不是 JSON 的字节。用 NetTransport 发不出这些 —— 它算的哈希是对的
func _raw() -> WebSocketPeer:
	var raw := WebSocketPeer.new()
	raw.connect_to_url("ws://127.0.0.1:%d" % _port)
	return raw

## 泵到裸 socket 连上
func _raw_open(raw: WebSocketPeer) -> bool:
	return await net_until([], func():
		raw.poll()
		return raw.get_ready_state() == WebSocketPeer.STATE_OPEN)

## 泵到裸 socket 上收到一条 t == want 的消息，返回它（超时返回 {}）。
##
## 4 字节的包要跳过：那是 WebSocketMultiplayerPeer 的 peer id 握手，
## 不是我们的消息（net_transport.gd 的 _on_packet 里同一条分流）
func _raw_wait(raw: WebSocketPeer, want: String) -> Dictionary:
	var box: Dictionary = {}
	await net_until([], func():
		if _srv != null:
			_srv.poll()
		raw.poll()
		while raw.get_available_packet_count() > 0:
			var pkt := raw.get_packet()
			if pkt.size() == 4 or pkt.is_empty() or pkt[0] != 0x7b:
				continue
			var dec: Dictionary = Protocol.decode(pkt.get_string_from_utf8())
			if dec["ok"] and str(dec["msg"]["t"]) == want:
				# 改内容，不是 box = dec["msg"]：lambda 按值捕获，
				# 重新赋值外层看不到（这个坑让 T1/T4/T5 一共报了 5 条假红）
				box.merge(dec["msg"], true)
		return not box.is_empty())
	return box

## 泵到裸 socket 被关掉，返回 { code, reason } —— **从关闭帧里取**，
## 不是等一条 closed 消息。
##
## 为什么不等消息：第一版就是那么写的，本地跑得过，但在变异跑里偶发红。
## 探针量到根因 —— 服务器 put_packet 之后断线，客户端只要晚 poll 一帧，
## 读到的就是「状态=CLOSED，包数=0」，排队的入站包随关闭一起丢了。
## 关闭码是握手的一部分，晚多久都还在。
## 认不出的码返回 code=""，判据会以「没给原因」的形态红
func _raw_closed(raw: WebSocketPeer) -> Dictionary:
	await net_until([], func():
		if _srv != null:
			_srv.poll()
		raw.poll()
		# 包要读掉：不读的话入站缓冲满了会影响关闭握手
		while raw.get_available_packet_count() > 0:
			raw.get_packet()
		return raw.get_ready_state() == WebSocketPeer.STATE_CLOSED)
	return {
		"code": Protocol.close_code_name(raw.get_close_code()),
		"reason": raw.get_close_reason(),
		"num": raw.get_close_code(),
	}

## 后台发一条意图，结果 append 进 box。
## 存在的理由见调用处：GDScript 存不住没跑完的 coroutine
func _in_flight(c: NetTransport, it: Dictionary, box: Array) -> void:
	box.append(await c.submit(it))

## 起一个后台协程，条件成立前一直泵服务器 + clients。
##
## submit 是 coroutine：await 它的时候**这个函数停住了**，没人再调 _pump ——
## 而服务器需要有人 poll 才会处理包。客户端自己会在 _next_frame 里 poll 自己，
## 但服务器不会自己动。所以要有一条独立的线在旁边摇服务器。
##
## **正在 submit 的那个客户端不能进 clients**：进了就是这里替它 poll，
## 于是「submit 自己泵帧」那条判据测的是这个 helper，不是被测代码 ——
## 实测把 _next_frame 末尾的 poll() 删掉，全套 67 条一条不红。
## 现在只摇服务器和旁观的那一个，submit 必须靠自己那下 poll 才收得到回音
func _keep_pumping(clients: Array, cond: Callable) -> void:
	while cond.call():
		if _srv != null:
			_srv.poll()
		for c in clients:
			(c as NetTransport).poll()
		await physics_frame

# ---------- T3 在飞 / 离线 ----------

func _t3_busy_and_offline() -> void:
	print("\n-- T3 一次只许一条在飞；没连上就别发 --")
	# 没连服务器就发：要立刻拿到 offline，不能挂在 await 上等超时。
	# 挂住的表现是界面全灰 8 秒，那比报错糟糕得多
	var lone := NetTransport.new("ws://127.0.0.1:1/nope", "TEST")
	var r0: Dictionary = await lone.submit(Intent.action_done(A))
	check(not r0.get("ok", true) and str(r0.get("code", "")) == "offline",
		"没连上就发意图 → offline（%s）" % r0.get("code", ""))

	var pair := await _seated_pair(777)
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	await net_until([a, b], func(): return a.actor() != "")
	var first: NetTransport = a if a.my_turn() else b

	# 一条在飞的时候再发一条 → busy。**不排队**：排队会让第二次点击
	# 在几百毫秒后突然生效，手感上像误触
	# GDScript 不让把没跑完的 coroutine 存进变量（`var f := x.submit(...)` 是解析错误），
	# 所以另起一条：_in_flight 在后台 await，把结果写进 box。
	# 这个测试要的正是「两条同时在飞」，没有别的写法能造出这个局面
	var box: Array = []
	var pumping := true
	_keep_pumping([b if first == a else a], func(): return pumping)   # first 不进去
	# 中间**不能插 _pump**：本地环回一帧就能跑完一整个往返，
	# 泵一下上一条就已经落地了，_pending 早回落 —— 于是造不出「两条同时在飞」。
	# submit 在第一个 await 之前是同步的（包已发出、_pending 已立起），
	# 所以 _in_flight 返回时局面就已经到位了
	_in_flight(first, Intent.buy(first.my_seat, 0), box)
	var busy: Dictionary = await first.submit(Intent.action_done(first.my_seat))
	check(not busy.get("ok", true) and str(busy.get("code", "")) == "busy",
		"上一条在飞时再发被拒（%s）" % busy.get("code", ""))
	await net_until([a, b], func(): return not box.is_empty())
	pumping = false
	if need(not box.is_empty(), "在飞那条有了结果"):
		check((box[0] as Dictionary).get("ok", false),
			"在飞那条自己照样落地了（%s）" % (box[0] as Dictionary).get("reason", ""))

	# 断线之后：online() 要翻，submit 要报 offline 而不是超时
	a.close()
	b.close()
	await net_pump([a, b], 6)
	check(not a.online(), "close 之后 online() 是假")

	net_stop()

# ---------- T4 卡表哈希 ----------

func _t4_bad_table_hash() -> void:
	print("\n-- T4 卡表不一致要拒连，并说清原因 --")
	if not net_boot(PORT_BASE):
		return
	# 手搓一个 join：客户端那份 table_hash 是 StateCodec 算的，
	# 改不了 —— 所以直接用一个裸 socket 发一份假的。
	# 这条判据验证 StateCodec.table_hash() 的握手保护：
	# 两份不同的 cards.json 会让两个人玩不同价格的同一个游戏，且不报错
	var raw := _raw()
	if not need(await _raw_open(raw), "裸 socket 连上了"):
		net_stop()
		return
	raw.send_text(Protocol.encode(Protocol.join("TEST", "deadbeef")))

	var why := await _raw_closed(raw)
	if need(why["code"] != "", "拒连给了原因（不是干脆断线）"):
		check(why["code"] == Protocol.CLOSE_TABLE_MISMATCH,
			"原因是卡表不一致（%s：%s）" % [why["code"], why["reason"]])
		check(str(why["reason"]).contains("cards.json"),
			"原因里说了是哪份文件（%s）" % why["reason"])
	check(_srv.room_count() == 0, "被拒的连接没留下空房间")

	# 房间码不合法也要拒，而且和卡表不一致分开成码：
	# 一个要玩家改码，一个要玩家换 cards.json，做的事完全不同。
	#
	# 「不合法」现在只剩两种（字母数字随便用，见 net/protocol.gd）：
	# 归一化成空的、和超长的。这里用**超长**的那种 —— 它是服务器侧的护栏：
	# 房间码进 rooms 当字典键，不设上限的话一条 join 就能开出一个几兆长键的房间。
	# 这条判据以前喂的是 "TOOLONG"（七位），而放宽字母表之后那是个**合法**房号 ——
	# 判据于是变成「合法房号被拒」，红得对
	var raw2 := _raw()
	await _raw_open(raw2)
	var over_long := ""
	for i in Protocol.ROOM_MAX_LEN + 1:
		over_long += "A"
	raw2.send_text(Protocol.encode({
		"t": Protocol.JOIN, "version": Protocol.VERSION,
		"room": over_long, "table_hash": StateCodec.table_hash() }))
	var bad_room := await _raw_closed(raw2)
	check(bad_room["code"] == Protocol.CLOSE_BAD_ROOM,
		"房间码不合法单独成码（%s）" % bad_room["code"])

	# 协议版本不一致也是单独一条：数值天天改，形状很少改，
	# 混成一条的话每次调平衡都会把所有客户端顶掉
	var raw3 := _raw()
	await _raw_open(raw3)
	raw3.send_text(Protocol.encode({
		"t": Protocol.JOIN, "version": Protocol.VERSION + 99,
		"room": "TEST", "table_hash": StateCodec.table_hash() }))
	var bad_ver := await _raw_closed(raw3)
	check(bad_ver["code"] == Protocol.CLOSE_VERSION,
		"协议版本不一致单独成码（%s）" % bad_ver["code"])

	# 原因**一定要塞得进关闭帧**：超 123 字节 close() 会静默什么都不做，
	# 连接挂在 OPEN 上不断 —— 玩家看到的是「连上了但什么也没发生」。
	# 上面三条能读到原因就已经证明没踩到；这里再钉一次截断本身，
	# 因为它是「以后有人给原因加一句话」时唯一的兜底
	var clipped := Protocol.clip_reason("测".repeat(200))
	check(clipped.to_utf8_buffer().size() <= Protocol.CLOSE_REASON_MAX,
		"截过的原因塞得进关闭帧（%d 字节）" % clipped.to_utf8_buffer().size())
	# 按字符边界截，不是按字节 —— 劈开半个汉字的字符串同样会让 close() 失败
	check(clipped.length() * 3 == clipped.to_utf8_buffer().size(),
		"截在字符边界上（%d 字 / %d 字节）" % [
			clipped.length(), clipped.to_utf8_buffer().size()])
	net_stop()

# ---------- T5 伪造消息 ----------

func _t5_forged_message() -> void:
	print("\n-- T5 客户端发不了服务器的那几种消息 --")
	if not net_boot(PORT_BASE):
		return
	var raw := _raw()
	if not need(await _raw_open(raw), "裸 socket 连上了"):
		net_stop()
		return
	raw.send_text(Protocol.encode(Protocol.join("TEST", StateCodec.table_hash())))
	var seated := await _raw_wait(raw, Protocol.SEATED)
	if not need(not seated.is_empty(), "裸 socket 也能正常入座（对照组）"):
		net_stop()
		return

	# 伪造一份 seated：挡不住的话，一个改过的客户端能给对手发假快照 ——
	# 而对手会照着画，两边从此看到不同的牌，且没有任何一处报错
	raw.send_text(Protocol.encode(Protocol.seated(A, B, StateCodec.snapshot(GameState.new()), "stolen")))
	var rej := await _raw_wait(raw, Protocol.REJECTED)
	check(str(rej.get("code", "")) == "not_client_msg",
		"客户端伪造 seated 被拒（%s）" % rej.get("code", ""))

	# 读不懂的包也要拒，而不是崩
	raw.send_text("这不是 JSON")
	var rej2 := await _raw_wait(raw, Protocol.REJECTED)
	check(str(rej2.get("code", "")) == "bad_json",
		"读不懂的包被拒且服务器还活着（%s）" % rej2.get("code", ""))
	check(_srv.room_count() == 1, "服务器没被这两条包搞死（房间还在）")

	# 还没进房间就发意图：要报 no_room 而不是在某个 null 上崩
	var raw2 := _raw()
	await _raw_open(raw2)
	raw2.send_text(Protocol.encode(Protocol.intent(Intent.action_done(A))))
	var rej3 := await _raw_wait(raw2, Protocol.REJECTED)
	check(str(rej3.get("code", "")) == "no_room",
		"没进房间就发意图被拒（%s）" % rej3.get("code", ""))
	net_stop()

# ---------- T6 拖拽转发 ----------

func _t6_drag_forward() -> void:
	print("\n-- T6 拖拽帧转给对手 --")
	var pair := await _seated_pair(31337)
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	var seen: Array = []
	b.foe_drag.connect(func(m): seen.append(m))

	a.send_drag(Protocol.DRAG_PICKUP, [3, 7], 0.25, 0.5)
	a.send_drag(Protocol.DRAG_MOVE, [3, 7], 0.6, 0.7)
	await net_until([a, b], func(): return seen.size() >= 2)
	if need(seen.size() >= 2, "对手收到了两帧拖拽（实收 %d）" % seen.size()):
		var m0: Dictionary = seen[0]
		var m1: Dictionary = seen[1]
		check(str(m0["phase"]) == Protocol.DRAG_PICKUP, "第一帧是拿起")
		check(m0["uids"] == [3, 7], "拖的是哪几张传过去了（%s）" % [m0["uids"]])
		check(int(m1["seq"]) > int(m0["seq"]),
			"帧序号递增（%d → %d）" % [int(m0["seq"]), int(m1["seq"])])
		check(absf(float(m1["u"]) - 0.6) < 0.001 and absf(float(m1["v"]) - 0.7) < 0.001,
			"归一化坐标原样转发（%.2f, %.2f）" % [float(m1["u"]), float(m1["v"])])

	# 自己发的不该回到自己身上
	var self_seen: Array = []
	a.foe_drag.connect(func(m): self_seen.append(m))
	a.send_drag(Protocol.DRAG_MOVE, [3], 0.1, 0.1)
	await net_pump([a, b], 10)
	check(self_seen.is_empty(), "自己的拖拽不回弹给自己（收到 %d）" % self_seen.size())

	a.close()
	b.close()
	await net_pump([a, b], 3)
	net_stop()

# ---------- T7 对手掉线 ----------

func _t7_foe_left() -> void:
	print("\n-- T7 对手掉线：房间留着等重连 --")
	var pair := await _seated_pair(555)
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	var seat_b := b.my_seat
	var token_b := b.resume_token
	var left := [false]
	a.foe_left.connect(func(): left[0] = true)

	b.close()
	await net_until([a], func(): return left[0])
	check(left[0], "对手掉线时我收到通知")
	# 房间**不删**（scenes/main.gd 的 _offer_reconnect / _on_net_down）：没有隐藏信息，重连很便宜。
	# 删了的话一方刷新页面就把局面弄丢了
	check(_srv.room_count() == 1, "对手掉线后房间还在")
	var room: NetRoom = _srv.rooms["TEST"]
	var hash_before := StateCodec.state_hash(room.state)
	check(int(room.occupants[seat_b]) == 0, "那个座位空出来了")

	# 拿令牌重连 → 回原座位，而且局面没变
	var b2 := net_client("TEST", token_b)
	await net_until([a, b2], func(): return b2.my_seat != "")
	check(b2.my_seat == seat_b, "带令牌重连回到原座位（%s）" % b2.my_seat)
	check(StateCodec.state_hash(room.state) == hash_before, "重连没重开一局")
	check(StateCodec.state_hash(b2.state()) == hash_before, "重连拿到的是当前局面")

	a.close()
	b2.close()
	await net_pump([a, b2], 4)
	net_stop()

# ---------- T8 uid 过一趟网络还是 int ----------

## uid 从网上回来必须还是 int，不能是 60.0。
##
## 这条不是洁癖。JSON 的数字全是 double，值又相等（60 == 60.0 为真），
## 所以 find_card 照样找得到 —— 末态哈希也抓不到（StateCodec.canon 故意把
## 整值 float 印成整数）。它只炸在**拿 uid 当字典键**的地方：
## 实测 { 60: x }.has(60.0) = false，[60].has(60.0) = false。
## 而 scenes/main.gd 的 _commit_buy 就是 `entities.has(u)`，
## 拖拽买是 `paid.has(c.uid)` —— 联网局里付掉的现金卡不被吸走、
## 还被当成「多付的」退回来，等于白拿一张牌，单机局完全正常。
##
## 所以这里扫**整个结果**而不是只看 new_uid：Protocol.restore_uids 是一张
## 白名单，新增 uid 类字段忘了登记的话，只有扫一遍才报得出来
func _t8_uids_stay_int() -> void:
	print("\n-- T8 uid 过一趟网络还是 int --")
	var pair := await _seated_pair(777)
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	await net_until([a, b], func(): return a.actor() != "")
	var first: NetTransport = a if a.my_turn() else b

	var pumping := true
	_keep_pumping([b if first == a else a], func(): return pumping)   # first 不进去
	var r: Dictionary = await first.submit(Intent.buy(first.my_seat, 0))
	pumping = false
	if not need(r.get("ok", false), "买到了（%s）" % r.get("reason", "")):
		net_stop()
		return

	check(typeof(r.get("new_uid", 0.0)) == TYPE_INT,
		"new_uid 是 int（实为 %s）" % type_string(typeof(r.get("new_uid", 0.0))))
	for u in r.get("removed_uids", []):
		check(typeof(u) == TYPE_INT,
			"removed_uids 里是 int（实为 %s）" % type_string(typeof(u)))
		break

	# 拿它当字典键真的查得中 —— 这才是 main.gd 的用法
	var ents := {}
	ents[int(r["new_uid"])] = "卡实体"
	check(ents.has(r["new_uid"]), "new_uid 当字典键查得中（main.gd 的 entities 用法）")

	var bad: Array = []
	_scan_uid_floats(r, "result", bad)
	check(bad.is_empty(), "整个结果里没有 float uid（%s）" % (
		"、".join(bad) if not bad.is_empty() else "干净"))

	a.close()
	b.close()
	await net_pump([a, b], 3)
	net_stop()

## 名字里**不带 uid 却装着 uid** 的字段。
##
## 这张表是补丁，不是设计：扫描器按字段名找 uid，白名单也按字段名登记 ——
## 两道网织法相同，于是同一个字眼能一次漏两道。`removed` 就是这么漏的
## （`GameState.apply_attack` 的回执，一串被打掉的 uid），
## 症状见 net/protocol.gd 的 UID_LIST_FIELDS 那段注释。
##
## 新增这类字段时**两处都要登记**：这里，和 Protocol.UID_LIST_FIELDS
const UID_BEARING_NAMES := ["removed"]

## 递归找「装着 uid 但值是 float」的字段，路径记进 bad。
##
## 判据有两条：名字里带 uid，或者名字在 UID_BEARING_NAMES 里 ——
## 后者是给 `removed` 这种「名字不带 uid」的字段留的门
func _scan_uid_floats(v, path: String, bad: Array) -> void:
	if v is Dictionary:
		for k in (v as Dictionary):
			_scan_uid_floats((v as Dictionary)[k], "%s.%s" % [path, k], bad)
	elif v is Array:
		for i in (v as Array).size():
			_scan_uid_floats((v as Array)[i], "%s[%d]" % [path, i], bad)
	elif typeof(v) == TYPE_FLOAT and _path_bears_uid(path):
		bad.append("%s=%s" % [path, v])

## 这条路径上的值是不是 uid。数组下标要剥掉再比名字：
## `result.removed[0]` 的字段名是 `removed`，不是 `removed[0]`
func _path_bears_uid(path: String) -> bool:
	var low := path.to_lower()
	if low.contains("uid"):
		return true
	for seg in low.split("."):
		var name := str(seg)
		var br := name.find("[")
		if br >= 0:
			name = name.substr(0, br)
		if UID_BEARING_NAMES.has(name):
			return true
	return false
