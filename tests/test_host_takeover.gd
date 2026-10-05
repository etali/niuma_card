# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 主机易位（scenes/main.gd 的 _take_over_host）：
## 开房那一位的进程走了，剩下的这位**自己开服接管**，对局不丢，
## 房间码不变，报一个局域网地址和一个随机端口出来等对手连回来。
##
## 八段，各钉一层：
##   T1 引擎：PhaseMachine.adopt —— `_done` 是从 (phase, actor) 推出来的
##   T2 网络：NetRoom.adopt —— 状态 + 池子 + 阶段 + 令牌，四样一起
##   T3 场景（真 socket）：主机死 → 我这边自己成主机，桌子**不重摆**
##   T4 真 socket：对手拿原来那串码连回来，坐回原座，拿到打到一半的局面
##   T5 真 socket：接管落在**攻击阶段**（次序最脆的一段，多一层 next_attacker）
##   T6 真 socket：接管落在「桌子摆了、第一个行动阶段还没开」那个窗口
##   T7 真 socket：接管出来的房里走完认输 → 两边投票 → 下一局
##   T8 真 socket：原主机**整个进程重来**（令牌一起没了）也进得来、拿得到局面
##
## 为什么 T3/T4 一定要过真 socket：这条路上每一个坑都在**跨进程那一侧** ——
## 快照里没有阶段（阶段是 PhaseMachine 的量）、池子不在 GameState 上、
## 座位错了两个人的牌当场对调。这三样在同进程里直接调 adopt 全都看不出来
## （对象都在手边，字段随便读），只有真的走一遍
## 「关掉服务器 → 开一个新的 → 让对端重新 join → 解码那份快照」才现形

const PORT_BASE := 8990   ## 和 test_resign（8970 段）、test_foe_offline 错开

var _flag := false

func _initialize() -> void:
	print("=== 主机易位测试 ===")
	await _t1_phase_adopt()
	await _t2_room_adopt()
	await _t3_socket_i_become_host()
	await _t4_socket_foe_reconnects()
	await _t5_socket_takeover_mid_attack()
	await _t6_socket_takeover_before_action_opened()
	await _t7_socket_rematch_in_adopted_room()
	await _t8_socket_fresh_process_comes_back()
	net_stop()
	finish()

# ---------- T1 引擎：阶段接管，_done 是推出来的 ----------

## adopt 只收 phase 和 actor，`_done` 自己推。这一节钉的就是「推得对」。
##
## 为什么值得单独一节：这是整条路上**唯一一处不是搬运而是推理**的地方。
## 别处都是「把 A 的值放到 B」，错了一眼看得出；这里错的话症状是
## 「接管之后我还能再行动一次」（`_done` 空着 → already_done 那道门开着），
## 而它只在**先手已经收手、后手正在动**的那一小段时间里出现 ——
## 接管发生在别的时刻的话怎么试都试不出来
func _t1_phase_adopt() -> void:
	print("\n-- T1 引擎：PhaseMachine.adopt --")
	var s := GameState.new()
	var order: Array = s.action_order()
	var first := str(order[0])
	var second := str(order[1])

	# actor 停在**先手**：谁都还没收手
	var p1 := PhaseMachine.new(s)
	p1.adopt(PhaseMachine.ACTION, first)
	check(p1.phase == PhaseMachine.ACTION, "阶段搬过来了（%s）" % p1.phase)
	check(p1.actor == first, "行动方搬过来了（%s）" % p1.actor)
	check(p1.check(first, Intent.OP_BUY).is_empty(),
		"先手还能买（他还没收手）")

	# actor 停在**后手**：先手收过手了，且仅先手
	var p2 := PhaseMachine.new(s)
	p2.adopt(PhaseMachine.ACTION, second)
	check(p2.check(second, Intent.OP_BUY).is_empty(), "后手能买（轮到他）")
	# 这一节的核心两条。判的是 `_done` 而**不是** check(first, ...) ——
	# 后者拦得住先手靠的是 actor 那道门（actor 是后手，先手怎么都过不去），
	# 和 `_done` 推没推对一点关系没有：把推导整段删掉那条断言照样绿。
	# `_done` 唯一的读者是 mark_done / is_done，判据就得落在它们身上
	check(p2.is_done(first),
		"先手那格标着收过手了 —— `_done` 是从 actor 推出来的（它不在快照里）")
	check(not p2.is_done(second), "后手那格没标（他正在动）")
	# 推错的真实症状在这一条上：后手收手时 mark_done 该回 true（两个都完事，
	# 阶段结束）。`_done` 空着的话它回 false **并且把 actor 拨回先手** ——
	# 玩家看到的是「接管之后先手在同一个行动阶段里又动了一次」
	check(p2.mark_done(second),
		"后手一收手这个行动阶段就结束了 —— 回 false 的话 actor 被拨回先手，"
		+ "他在同一个行动阶段里又能动一次")
	check(p2.actor != first,
		"actor 没被拨回先手（实为 %s）" % p2.actor)

	# 攻击阶段同构
	var p3 := PhaseMachine.new(s)
	p3.adopt(PhaseMachine.ATTACK, second)
	check(p3.phase == PhaseMachine.ATTACK, "攻击阶段也搬得动（%s）" % p3.phase)
	check(p3.check(second, Intent.OP_ATTACK).is_empty(), "轮到他开火")

	# 没有 actor 的两个阶段：不能因为 actor 是空串就崩，也不该推出任何 _done
	var p4 := PhaseMachine.new(s)
	p4.adopt(PhaseMachine.OVER, "")
	check(p4.phase == PhaseMachine.OVER, "终局阶段搬得动，空 actor 不崩")

	# 反过来的一条：adopt **不能**走 reset_for_round 那条路。
	# 走了的话不管传什么进来都会回到「行动阶段 + 先手先动」
	var p5 := PhaseMachine.new(s)
	p5.adopt(PhaseMachine.ATTACK, second)
	check(not (p5.phase == PhaseMachine.ACTION and p5.actor == first),
		"接管没把回合退回开头 —— 退回去的话打到一半的攻击回合会从头再来一遍")

# ---------- T2 网络层：房间接管 ----------

## NetRoom.adopt 一次要做四件事（状态 / 池子 / 阶段 / 令牌），这一节四件各一条。
##
## 池子那条最值得看：它**不是 GameState 的字段**（在 IntentApply 上），
## 于是 StateCodec.snapshot 不管它，漏搬不报错 ——
## 症状是攻击回合整段被跳过（池子空 → 没人有点数可打）
func _t2_room_adopt() -> void:
	print("\n-- T2 网络层：NetRoom.adopt --")
	# 先造一份「打到一半」的局：随便动几个能看出来的量
	var src := NetRoom.new("SRC", 20260829)
	src.state.round_num = 7
	src.state.log_msg("这一行是上一局留下的")
	var log_len: int = src.state.log.size()

	var order: Array = src.state.action_order()
	var first := str(order[0])
	var second := str(order[1])
	# 池子里**必须真有点数**。空池的话「搬过来了」这条判据恒真
	# （两边都是 0 条，相等），把 pools_restore 整句删掉照样绿 ——
	# 而池子漏搬的真实症状正是「池子是空的」，判据和 bug 长得一模一样
	src.applier.seed_pool_for_test(first, 5, 3)
	var snap: Dictionary = StateCodec.snapshot(src.state)
	snap["pools"] = src.applier.pools_snapshot()

	var dst := NetRoom.new("SRC", 20260829)   # 房间码原样：用户说「保持密码不变」
	var seat := first
	dst.adopt(snap, PhaseMachine.ATTACK, second, seat, "TOKEN-OLD")

	check(dst.state.round_num == 7,
		"状态搬过来了（第 %d 回合 ← 7）" % dst.state.round_num)
	check(dst.state.log.size() == log_len,
		"战报也在（%d 行 ← %d）—— 复盘要靠它" % [dst.state.log.size(), log_len])
	check(dst.applier.armed(first),
		"池子搬过来了 —— 它不在 GameState 上（是裁决器的成员），"
		+ "漏搬的话 pool_empty 当场为真，攻击回合整段被跳过而且不报错")
	var moved: Dictionary = dst.applier.pools(first)
	check(int(moved.get(CardDB.RES_CASH, -1)) == 5
		and int(moved.get(CardDB.RES_USER, -1)) == 3,
		"池子里的点数也是原来那些（现金 %s / 用户 %s ← 5 / 3）"
			% [str(moved.get(CardDB.RES_CASH, "?")), str(moved.get(CardDB.RES_USER, "?"))])
	check(dst.phase != null and dst.phase.phase == PhaseMachine.ATTACK,
		"阶段按住在真实那一步上（%s ← attack）" % str(dst.phase.phase))
	check(str(dst.phase.actor) == second, "行动方也是（%s）" % str(dst.phase.actor))
	check(str(dst.tokens.get(seat, "")) == "TOKEN-OLD",
		"接管者原来那串令牌种进去了 —— 凭它才坐得回原座，"
		+ "坐错位的话两个人的牌当场对调（快照里的牌按座位名存）")
	check(dst.started(),
		"这间房算「已开局」—— 不算的话后进来那位会触发 start_if_ready，"
		+ "拿到的是新发的一手牌而不是这份打到一半的快照")

	# 令牌只种接管者那一个，对手那份必须**留着房间自己发的**：
	# 对手手里的令牌是原主机发给他的，和这间新房无关 ——
	# 拿接管者的令牌覆盖他那份，他重连时 token 对不上，会被当成新人
	var foe_token := str(dst.tokens.get(second, ""))
	check(foe_token != "" and foe_token != "TOKEN-OLD",
		"对手那格还是这间房自己那串（不是被接管者的令牌盖掉）")

# ---------- T3 场景层：主机死了，我顶上 ----------

## 观察点全在我这个场景里：主机进程走了之后我这边要**自动**变成主机，
## 而桌上的牌一张都不许动。
##
## 「牌不许动」是这一节最要紧的一条，也是 _take_over_host 不走
## begin_net_game 的唯一理由：那条路会 _draw_net_table → _respawn_all，
## 而 _respawn_all 用 _rand_pos 重排位置。局面一个字节没变，
## 但玩家看到的是「所有牌当场跳到别处」—— 他会以为这一局被重置了
func _t3_socket_i_become_host() -> void:
	print("\n-- T3 场景层：主机死了我顶上 --")
	var got: Array = await _seated_scene("TKO3", 20260829)
	if got.is_empty():
		return
	var main: Node = got[0]
	var a: NetTransport = got[1]
	var b: NetTransport = got[2]

	if not await net_until([a, b], func(): return main.phase == PhaseMachine.ACTION):
		check(false, "开局进了行动阶段（实为 %s）" % str(main.phase))
		main.queue_free()
		return

	# 在局面上留个记号，好在 T4 里认出「接管过来的就是这一份」
	_server_room().state.round_num = 5
	await _broadcast_authority([a, b])
	var seat_before: String = main.my_seat
	var foe_before: String = main.foe_seat
	var cards_before: int = main.entities.size()
	var phase_before: String = str(main.phase)
	# 位置要**等牌落定之后**才记，不能等固定帧数。联网局的桌子是 _draw_net_table
	# 摆的，摆出来那一下每张牌都在补间里飞（_respawn_all → _fly_from），
	# 而 boot_main 等的是**单机局**的开局补间 —— 它在 begin_net_game **之前**
	# 就调完了（harness.gd 的 `net_seated_scene()`），那会儿联网这批补间还没生出来，等谁都没用。
	# 不等就记的话，下面「牌一张都没跳位」量到的是补间自己飞完的位移
	# （实测 60 张里 55 张在动，最大 15.35），和接管一点关系都没有
	var pos_before: Dictionary = await _settled_pos([a, b], main)
	if not need(not pos_before.is_empty(), "牌落定了（拿它当位置基线）"):
		main.queue_free()
		return

	check(main._host == null, "此刻服务器不在我这个进程里（前提：我是纯客户端）")

	# 主机进程走了。真的把服务器关掉 —— 关的那一下客户端收到关闭帧，
	# 走 _emit_closed → disconnected("closed") → _on_net_down
	net_stop()
	# 等的是**接管全程走完**（新连接入座了），不是 `_host != null`。
	# 后者在开出端口那一刻就成立，而那时候接管才走到一半：
	# 房还没 adopt、新连接还没 join。拿它当等待条件的话下面每一条
	# 判的都是「接管进行到一半」的状态，而那不是任何玩家会看到的状态
	if not await net_until([a, b], func():
			return main._net != null and main._net != a \
				and main._net.my_seat != "", 6700):
		check(false, "主机断开之后我这边自己接管了（_host=%s / 新连接座位=%s）"
			% [str(main._host),
				str(main._net.my_seat) if main._net != null else "无"])
		main.queue_free()
		return
	check(main._host != null and main._host.running(),
		"主机断开之后我这边自己开出了服务器 —— 没有这一条的话这一局就到此为止了")

	# 端口只有两种合法结果：默认那个（先试的，见 EmbeddedHost.start_takeover）
	# 或者随机段里的一个（默认被占时的退路）。
	# **中间那一档是错的** —— 8911..8921 那种顺延出来的号既不是「两边都知道的
	# 那个数」，又不像随机端口那样一眼看出「得去问」，玩家会照默认地址填 8910，
	# 撞在对面那个半死的房上。哪一档由这台机器上 8910 空不空决定（不可控），
	# 所以这里判「不在中间那一档」，而「优先默认」那条由
	# tests/test_embedded_host.gd T6 单独钉（那边端口占用状态是自己摆的）
	var port: int = main._host.port
	check(port == EmbeddedHost.DEFAULT_PORT
		or (port >= EmbeddedHost.RANDOM_PORT_LO
			and port <= EmbeddedHost.RANDOM_PORT_HI),
		"端口是默认那个或者随机段里的一个（实为 %d）—— 顺延出来的 %d..%d 最糟："
			% [port, EmbeddedHost.DEFAULT_PORT + 1,
				EmbeddedHost.DEFAULT_PORT + EmbeddedHost.PORT_TRIES - 1]
		+ "玩家照默认地址填，撞的是对面那半个死掉的房")

	# 用户那句「不能是 localhost 的 IP，因为别人无法连接」
	var urls: Array = EmbeddedHost.lan_urls(port)
	var loopback := false
	for u in urls:
		if str(u).find("127.0.0.1") >= 0 or str(u).find("localhost") >= 0:
			loopback = true
	check(not loopback, "报给对手的地址里没有回环地址（%s）—— 报 127.0.0.1 的话"
		% str(urls) + "对手照着填，连的是他自己那台机器")

	# 局面**没有丢**，而且座位没变
	check(main.my_seat == seat_before,
		"座位没变（%s ← %s）" % [main.my_seat, seat_before])
	check(main.foe_seat == foe_before, "对手座位也没变（%s）" % main.foe_seat)
	check(main.state.round_num == 5,
		"局面还是那一份（第 %d 回合 ← 5）—— 重开一局的话这里是 1"
			% main.state.round_num)
	check(main.state.winner == "", "局还在打（winner=%s）" % str(main.state.winner))
	check(str(main.phase) == phase_before,
		"阶段没退回开头（%s ← %s）" % [str(main.phase), phase_before])

	# 桌子**没重摆**。这是不走 begin_net_game 的那条判据
	check(main.entities.size() == cards_before,
		"桌上牌数没变（%d ← %d）" % [main.entities.size(), cards_before])
	var moved := 0
	for uid in pos_before:
		if main.entities.has(uid):
			var e = main.entities[uid]
			if is_instance_valid(e) and e.global_position.distance_to(
					pos_before[uid]) > 0.01:
				moved += 1
	check(moved == 0, "牌一张都没跳位（跳了 %d 张）—— 走 begin_net_game 的话"
		% moved + "会 _respawn_all 重排，玩家以为这一局被重置了")

	# 管道真的换到新连接上了（不换的话下一条意图发给一个已经死掉的服务器，
	# 卡满 8 秒超时才回一句 timeout）
	check(main._net != null and main._net != a, "管道换到新连接上了")
	check(main._net != null and main._net.my_seat == seat_before,
		"新连接坐的是原座（%s）" % str(main._net.my_seat if main._net else ""))
	check(main.pipe == main._net, "pipe 也跟着换了")
	check(main._net != null and main._net.applied.is_connected(main._on_intent_applied),
		"applied 接到新连接上了 —— 不接的话对手做什么我这边一个像素都不变")
	check(not a.applied.is_connected(main._on_intent_applied),
		"旧连接的 applied 摘掉了 —— 不摘的话同一步演两遍")
	check(not a.disconnected.is_connected(main._on_net_down),
		"旧连接的 disconnected 也摘了 —— 不摘的话它稍后那条关闭通知会打回来，"
		+ "刚接管成功就被自己锁死")

	# 对手此刻不在：提示要挂上，针对他的行为要拦掉（走 scenes/main.gd 的 _offer_reconnect / _on_net_down 的提示与输入拦截）
	check(not main._foe_online, "标成了对手不在线")
	check(main._foe_gone(), "「对手掉线」那道门关着了")

	# 输入没被锁死 —— 用户那句「如果本回合是自己行为则继续行动」
	check(not main.board.input_locked,
		"输入没锁 —— 锁了的话接管的意义就没了（保住了局面，但一步也走不了）")

	b.close()
	main.queue_free()
	await physics_frame

# ---------- T4 对手连回来 ----------

## 接管只完成了一半：房开着，还得对手真的连得进来、坐得回原座、
## 拿到的是**打到一半的那份**局面。
##
## 这一节里对手是**拿着令牌**回来的（他那条连接的对象还在测试手里）。
## 而真实那条路上主机那个进程整个走了、令牌只在内存里所以一起没了 ——
## 那时候走的是 seat_peer 里 free_seat 那一支，由 T8 单独钉
##
## 这一节钉的三样全都只在跨进程那一侧现形：
##   房间码不变    —— 用户原话「保持密码不变」。对手手里那串码不用改
##   坐回原座      —— 快照里的牌按座位名存，坐错位等于两个人的牌当场对调
##   补一条 phase  —— seated 里没有阶段，快照里也没有（阶段是 PhaseMachine
##                    的量）。不补的话他的 _phase 是空串：连上了、牌摆好了，
##                    但场景层那些 `phase != PHASE_ACTION` 的门全关着，
##                    一步都走不了而且不报错
func _t4_socket_foe_reconnects() -> void:
	print("\n-- T4 对手连回来 --")
	var got: Array = await _seated_scene("TKO4", 20260829)
	if got.is_empty():
		return
	var main: Node = got[0]
	var a: NetTransport = got[1]
	var b: NetTransport = got[2]

	if not await net_until([a, b], func(): return main.phase == PhaseMachine.ACTION):
		check(false, "开局进了行动阶段（实为 %s）" % str(main.phase))
		main.queue_free()
		return

	# 对手那位手里的东西：座位 + 令牌。接管之后他就靠这两样回来
	var foe_seat: String = b.my_seat
	var foe_token: String = b.resume_token
	if not need(foe_token != "", "对手手里有重连令牌（seated 里带回来的）"):
		main.queue_free()
		return
	_server_room().state.round_num = 6   # 记号必须来自服务器，展示副本不是接管权威。
	await _broadcast_authority([a, b])
	var cards_expected: int = main.state.players[foe_seat]["hand"].size() \
		if main.state.players[foe_seat].has("hand") else -1

	# 主机死 → 我接管。等的是**接管全程走完**（新连接入座了），同 T3 ——
	# 不是 `_host != null`。后者在 EmbeddedHost 一 new 出来就成立
	# （main.gd 的 `start_local_host()`），那一刻房还没 adopt、主机自己那条新连接也还没 join，
	# occupants 里一个座位都没占（adopt 只种令牌，不占座）。
	#
	# 拿它当条件的话下面那个 `c` 会和主机**抢同一个空位**：free_seat 按 SEATS
	# 顺序派第一个空的（room.gd 的 `free_seat()`），主机随后凭种进去的令牌走 resumed 支
	# 把它抢回来 —— 而那一支**不看座位是否被占**（room.gd 的 `seat_peer()`），
	# 于是两个人都落在 player 上。60Hz 下同进程握手总是先赢所以一直没露头，
	# 把物理频率抬上去（TEST_SPEED=5 → 300Hz）之后物理帧便宜了五倍、
	# socket 往返还是墙钟，这就成了掷硬币：实测三跑给出 77/8、81/3、82/2
	net_stop()
	b.close()
	if not await net_until([a], func():
			return main._net != null and main._net != a \
				and main._net.my_seat != "", 6700):
		check(false, "我这边接管出了服务器并且自己坐进去了（_host=%s / 新连接座位=%s）"
			% [str(main._host),
				str(main._net.my_seat) if main._net != null else "无"])
		main.queue_free()
		return
	var host_url: String = main._host.url()

	# 对手拿**原来那串房间码**连回来（用户：保持密码不变）
	var c := NetTransport.new(host_url, "TKO4")
	c.resume_token = foe_token
	c.connect_to_server()
	if not await net_until([main._net, c], func(): return c.my_seat != "", 6700):
		check(false, "对手连回来并且入座了（seat=%s）" % str(c.my_seat))
		c.close()
		main.queue_free()
		return
	check(c.my_seat == foe_seat,
		"坐回原座（%s ← %s）—— 坐错位的话快照里两个人的牌当场对调"
			% [c.my_seat, foe_seat])
	check(c.foe_seat == main.my_seat,
		"对手位也对上了（%s ← %s）" % [c.foe_seat, main.my_seat])

	# 拿到的是打到一半那份，不是新发的一手牌
	check(c.state().round_num == 6,
		"拿到的是打到一半那份（第 %d 回合 ← 6）—— 新发一手牌的话这里是 1"
			% c.state().round_num)
	if cards_expected >= 0:
		check(c.state().players[foe_seat]["hand"].size() == cards_expected,
			"他手里的牌数也对（%d ← %d）"
				% [c.state().players[foe_seat]["hand"].size(), cards_expected])

	# 阶段要补上。这一条是**服务器 _on_join 那条补发**钉的：
	# 不补的话他的 _phase 是空串，一步都走不了而且不报错
	if not await net_until([main._net, c], func(): return c.phase() != "", 3300):
		check(false, "服务器给重连的这位补了一条 phase（实为「%s」）" % c.phase())
	check(c.phase() != "", "服务器给重连的这位补了一条 phase（%s）—— "
		% c.phase() + "不补的话他连上了、牌也摆好了，但场景层那些"
		+ "「不是行动阶段就别动」的门全关着，一步都走不了而且不报错")
	check(c.actor() != "", "行动方也报了（%s）" % c.actor())

	# 我这边要看得出他回来了：提示摘掉、拦门打开
	if not await net_until([main._net, c], func(): return main._foe_online, 3300):
		check(false, "他回来之后提示摘掉了（_foe_online=%s）" % str(main._foe_online))
	check(main._foe_online, "他回来之后提示摘掉了")
	check(not main._foe_gone(), "针对他的那道拦门也打开了")

	c.close()
	main.queue_free()
	await physics_frame

# ---------- T5 攻击阶段接管：打到一半的那一轮不能重来 ----------

## T3/T4 都落在行动阶段。这一节把接管挪到**攻击阶段**，因为那是次序最脆的
## 一段：行动阶段的「谁没收手」靠 `_done`（推得出来），而攻击阶段还多一层
## next_attacker 的换手，两者都得从 (phase, actor) 那两个量重建
##
## 阶段是**直接改服务器那两个字段**摆出来的，不走真意图。理由是
## NetRoom._arm_current：装出来是空池就立刻换手（room.gd 的 `_arm_current()`），
## 而开局谁都没编攻击组合 —— 走真 action_done 的话服务器一口气
## 穿过攻击阶段结算完回到下一回合的行动阶段，压根停不在 ATTACK 上。
## 用 begin_attack() 而不是 adopt() 摆：拿 adopt 当 adopt 的前提是循环论证
##
## 判据落在**次序**上而不是「打出多少点」：后者要弹药、要目标、要点数，
## 一条规则不满足就红，而红的原因和接管无关。attack_done 是
## ALLOWED[ATTACK] 里的纯次序操作，不动任何资源 ——
## 它过不过，就是这一轮攻击还在不在
func _t5_socket_takeover_mid_attack() -> void:
	print("\n-- T5 攻击阶段接管 --")
	var got: Array = await _seated_scene("TKO5", 20260829)
	if got.is_empty():
		return
	var main: Node = got[0]
	var a: NetTransport = got[1]
	var b: NetTransport = got[2]
	var room := _server_room()
	if not need(room != null, "服务器开出了房间"):
		main.queue_free()
		return
	if not await net_until([a, b], func(): return main.phase == PhaseMachine.ACTION):
		check(false, "开局进了行动阶段（实为 %s）" % str(main.phase))
		main.queue_free()
		return

	# 服务器摆到攻击阶段，然后**广播出去** —— 接管读的是客户端那份缓存
	# （old.phase()，net_transport.gd 的 `_on_text()` 存进 `_phase` 的那个），不是服务器这份。
	# 不广播的话接管带过去的还是 action，这一节要钉的东西整个绕过去了
	room.phase.begin_attack()
	room.applier.pools_restore({room.phase.actor: {CardDB.RES_CASH: 0, CardDB.RES_USER: 2, "_lock_batch": ""}})
	await _broadcast_authority([a, b])
	var attacker_before: String = room.phase.actor
	var round_before: int = room.state.round_num
	if not need(attacker_before != "", "服务器进了攻击阶段，有个正在攻击的座位"):
		main.queue_free()
		return
	_srv._send_to(room.peers(),
		Protocol.phase(PhaseMachine.ATTACK, attacker_before))
	if not await net_until([a, b], func(): return a.phase() == PhaseMachine.ATTACK, 5000):
		check(false, "我这条连接也收到了攻击阶段（实为「%s」）" % a.phase())
		main.queue_free()
		return

	# 主机死 → 接管
	net_stop()
	if not await net_until([a, b], func():
			return main._net != null and main._net != a \
				and main._net.my_seat != "", 6700):
		check(false, "攻击阶段掉主机之后我这边接管了")
		main.queue_free()
		return

	var adopted := _host_room(main)
	if not need(adopted != null, "接管出来的房在那儿"):
		main.queue_free()
		return
	check(adopted.phase.phase == PhaseMachine.ATTACK,
		"接管之后还在攻击阶段（%s ← attack）—— 退回行动阶段的话"
			% str(adopted.phase.phase)
		+ "这一轮攻击会从头再打一遍，而弹药已经花掉了")
	check(str(adopted.phase.actor) == attacker_before,
		"正在攻击的还是那一位（%s ← %s）"
			% [str(adopted.phase.actor), attacker_before])
	check(adopted.state.round_num == round_before,
		"回合数没动（%d ← %d）" % [adopted.state.round_num, round_before])

	# 这一轮攻击还打得下去：轮到的那位收得了手，另一位插不进来
	check(adopted.phase.check(attacker_before, Intent.OP_ATTACK_DONE).is_empty(),
		"轮到的那位还能收手 —— 这一轮攻击是活的")
	var blocked: Dictionary = adopted.phase.check(
		adopted.state.opponent(attacker_before), Intent.OP_ATTACK_DONE)
	check(not blocked.is_empty(), "另一位插不进来（次序没丢）")
	check(str(blocked.get("code", "")) == "not_your_turn",
		"（拦他的码是 not_your_turn，实为 %s）" % str(blocked.get("code", "")))

	b.close()
	main.queue_free()
	await physics_frame

# ---------- T6 摆桌到开阶段之间那个窗口 ----------

## 桌子是 _on_net_seated 摆的，第一个行动阶段是**另一条消息**
## （Protocol.phase）开的。两条通常同一帧到，但主机进程被 kill 的时刻
## 不受任何人控制。卡在中间那几帧接管的话，此后**没有任何人**会去开这个阶段：
##   _on_net_seated 开头那道 `if _net_table_drawn: return` 把新连接的 seated 挡了
##   _on_net_phase 是一次性的（_net_phase_seen），而服务器不会为一个
##     已经入座的人再广播一次
##
## 症状还是那句熟悉的：连上了、牌摆好了、按钮全灰、一条错都不报。
## 窗口窄不是理由 —— 它的代价是整局卡死，而玩家的恢复手段只有重启游戏
##
## 用 _net_phase_seen = false 回到那一刻（同 test_net_client 的手法）：
## 桌子已经摆好，而「第一个行动阶段认过了」这个标记还没立起来
func _t6_socket_takeover_before_action_opened() -> void:
	print("\n-- T6 摆桌到开阶段之间接管 --")
	var got: Array = await _seated_scene("TKO6", 20260829)
	if got.is_empty():
		return
	var main: Node = got[0]
	var a: NetTransport = got[1]
	var b: NetTransport = got[2]

	if not await net_until([a, b], func(): return main.entities.size() > 0):
		check(false, "桌子摆出来了")
		main.queue_free()
		return
	# 回到「桌子摆好了、阶段还没认」那一刻
	main._net_phase_seen = false
	main.board.input_locked = true
	main.btn_pass.disabled = true
	check(not main._net_phase_seen, "前提：阶段还没认过")
	check(main._net_table_drawn, "前提：桌子已经摆好了")

	net_stop()
	if not await net_until([a, b], func():
			return main._net != null and main._net != a \
				and main._net.my_seat != "", 6700):
		check(false, "接管走完了")
		main.queue_free()
		return

	# 本节的核心判据：接管**自己**要把阶段补开，不能等一条不会再来的广播
	if not await net_until([main._net], func(): return main._net_phase_seen, 3300):
		check(false, "接管之后阶段自己补开了（_net_phase_seen=%s）"
			% str(main._net_phase_seen))
	check(main._net_phase_seen,
		"接管之后阶段自己补开了 —— 靠 phase_changed 信号等不来："
		+ "服务器不会为一个已经入座的人再广播一次，"
		+ "而 _on_net_seated 那道「桌子摆过就不再摆」把新连接的 seated 也挡了")
	check(main.phase == PhaseMachine.ACTION,
		"进了行动阶段（%s）" % str(main.phase))
	# 轮到我的话按钮得活过来；不轮到我则该写着「对手行动中」——
	# 两种都不是「全灰」，而全灰正是这一节要挡的那个症状
	if str(main._net.actor()) == main.my_seat:
		check(not main.board.input_locked, "轮到我，输入开了")
		check(not main.btn_pass.disabled, "结束回合按钮也点得动了")
	else:
		check(main.btn_pass.text == main.TXT_BOT_ACTING,
			"轮到对手，按钮上写着「%s」（实为「%s」）"
				% [main.TXT_BOT_ACTING, main.btn_pass.text])

	b.close()
	main.queue_free()
	await physics_frame

# ---------- T7 接管出来的房里走完认输 → 再战一局 ----------

## 四步单独都测过（接管 T3 / 重连 T4 / 认输 test_resign / 投票 test_resign），
## 串起来没测过。而这四步是真实会发生的一条顺序：
## 主机掉 → 我接管 → 对手连回来 → 有人认输 → 两边投票开下一局
##
## 值得单独一节的理由：接管出来的房里那份 state 是 **restore 进去的**，
## 而 reset_for_rematch 要在它上面轮换 draw_first、清 winner、重发牌。
## 「新造的房」和「灌进来的房」在这一步上有没有差别，只有真跑一遍才知道
func _t7_socket_rematch_in_adopted_room() -> void:
	print("\n-- T7 接管出来的房里再战一局 --")
	var got: Array = await _seated_scene("TKO7", 20260829)
	if got.is_empty():
		return
	var main: Node = got[0]
	var a: NetTransport = got[1]
	var b: NetTransport = got[2]

	if not await net_until([a, b], func(): return main.phase == PhaseMachine.ACTION):
		check(false, "开局进了行动阶段（实为 %s）" % str(main.phase))
		main.queue_free()
		return
	var foe_seat: String = b.my_seat
	var foe_token: String = b.resume_token
	if not need(foe_token != "", "对手手里有重连令牌"):
		main.queue_free()
		return

	# 主机死 → 我接管 → 对手连回来
	net_stop()
	b.close()
	if not await net_until([a], func():
			return main._net != null and main._net != a \
				and main._net.my_seat != "", 6700):
		check(false, "接管走完了")
		main.queue_free()
		return
	var c := NetTransport.new(main._host.url(), "TKO7")
	c.resume_token = foe_token
	c.connect_to_server()
	if not await net_until([main._net, c], func(): return c.my_seat != "", 6700):
		check(false, "对手连回来并入座了")
		c.close()
		main.queue_free()
		return
	check(c.my_seat == foe_seat, "坐回原座（%s）" % c.my_seat)

	var adopted := _host_room(main)
	if not need(adopted != null, "接管出来的房在那儿"):
		c.close()
		main.queue_free()
		return
	adopted.state.round_num = 4   # 推离第 1 回合，否则下面拿 1 和 1 比

	# 他认输
	_flag = false
	net_pump_until([main._net, c], func(): return _flag)
	var r: Dictionary = await c.submit(Intent.resign(c.my_seat))
	_flag = true
	check(bool(r.get("ok", false)),
		"接管出来的房里认得了输（%s）" % str(r.get("reason", "")))
	if not await net_until([main._net, c], func(): return main.game_over_panel != null):
		check(false, "我这边弹出了结算界面（winner=%s）" % str(main.state.winner))
		c.close()
		main.queue_free()
		return
	check(main.state.winner == main.my_seat,
		"判的是我赢（%s）" % str(main.state.winner))

	# 两边投票 → 下一局
	if not need(main._rematch_btn != null, "面板上有「再来一局」"):
		c.close()
		main.queue_free()
		return
	var started: Array = []
	c.rematch_started.connect(func(m, f): started.append([m, f]))
	main._rematch_btn.pressed.emit()
	await net_pump([main._net, c], 6)
	check(adopted.voted_seats().size() == 1,
		"我这一票记下了（%s）" % str(adopted.voted_seats()))
	c.request_rematch()
	if not await net_until([main._net, c], func(): return not started.is_empty(), 6700):
		check(false, "两票齐了，他那边收到了新局通知")
		c.close()
		main.queue_free()
		return
	check(adopted.state.winner == "" and adopted.state.round_num == 1,
		"接管出来的房也开得了干净的下一局（第 %d 回合 ← 上一局第 4，winner=「%s」）"
			% [adopted.state.round_num, str(adopted.state.winner)])
	check(str(started[0][0]) == c.my_seat,
		"他那条新局通知写的是他自己的座位（%s）" % str(started[0][0]))

	c.close()
	main.queue_free()
	await physics_frame

# ---------- T8 原主机整个进程重来 ----------

## 用户描述的那条路，**原样**：「主机断开的情况下，进程相当于就是关闭了，
## 不再存活，接下来就得靠客机复现局面，启动服务器等待主机重新连接」。
##
## 和 T4 差在**一样东西**：那边对手是拿着令牌回来的（他那条连接的对象
## 还在测试手里），而进程真的走了的话令牌一起没了 ——
## 它只在内存里（NetTransport.resume_token，seated 那一刻发下来的）。
## 于是他回来时是一条**空令牌**的新连接，走的是 seat_peer 里
## seat_for_token 落空 → free_seat 那一支。
##
## 这一节钉的就是那一支在**接管出来的房**里也成立。为什么它可能不成立：
## adopt() 只往 tokens 里种回接管者自己那一串（room.gd 的 `adopt()`），
## 另一个座位的令牌是新房自己生的一串谁也不知道的东西 ——
## 空令牌能不能坐进去，全看 free_seat 那时候还剩不剩一个空位。
## 剩不剩取决于 adopt 之后 occupants 的状态，而那件事**没有任何判据碰过**：
## T4/T5/T6/T7 四节全都带着令牌回来，走的是另一支。
##
## 坏起来的样子：他填对了地址和房间码，服务器回一条「房间满了」
## （free_seat 返回空 → CLOSE_ROOM_FULL），而房里明明只坐着一个人。
## 玩家看到的还是那句「密码是对的啊，连不上」
func _t8_socket_fresh_process_comes_back() -> void:
	print("\n-- T8 原主机整个进程重来 --")
	var got: Array = await _seated_scene("TKO8", 20260829)
	if got.is_empty():
		return
	var main: Node = got[0]
	var a: NetTransport = got[1]
	var b: NetTransport = got[2]

	if not await net_until([a, b], func(): return main.phase == PhaseMachine.ACTION):
		check(false, "开局进了行动阶段（实为 %s）" % str(main.phase))
		main.queue_free()
		return
	var foe_seat: String = b.my_seat
	_server_room().state.round_num = 9
	await _broadcast_authority([a, b])

	# 主机那个进程走了：服务器停 + 他那条连接没了。
	# **令牌不留** —— 这就是「进程重来」和 T4 那条「他还拿着令牌」的全部差别
	net_stop()
	b.close()
	# 同 T4：等接管**全程**走完。这一节尤其不能只等 `_host != null` ——
	# 底下判的就是「剩下的空位正好是他的」，而主机自己那个座位要等它
	# 那条新连接 join 才占上（adopt 只种令牌）。没占上的话 free_seat
	# 派给他的是 SEATS 第一个，也就是主机自己那个座位
	if not await net_until([a], func():
			return main._net != null and main._net != a \
				and main._net.my_seat != "", 6700):
		check(false, "我这边接管出了服务器并且自己坐进去了（_host=%s / 新连接座位=%s）"
			% [str(main._host),
				str(main._net.my_seat) if main._net != null else "无"])
		main.queue_free()
		return
	var host_url: String = main._host.url()

	# 他重启之后手里剩下的东西：地址 + 房间码。令牌一栏是空的
	var c := NetTransport.new(host_url, "TKO8")
	check(c.resume_token == "", "新进程手里没有令牌（前提：它只在内存里）")
	c.connect_to_server()
	if not await net_until([main._net, c], func(): return c.my_seat != "", 6700):
		check(false, "空令牌的新连接也进得来（seat=%s）—— 进不来的话服务器回的是"
			% str(c.my_seat) + "「房间满了」，而房里只坐着一个人")
		c.close()
		main.queue_free()
		return
	check(c.my_seat != "", "空令牌的新连接进来了并且入座了（%s）" % c.my_seat)
	check(c.my_seat == foe_seat,
		"坐的还是他原来那个座位（%s ← %s）—— 接管者自己那个座位被 adopt 占着，"
			% [c.my_seat, foe_seat]
		+ "剩下的空位正好是他的；坐错的话快照里两个人的牌当场对调")
	check(c.my_seat != main.my_seat,
		"没和我坐同一个位置（我 %s / 他 %s）" % [main.my_seat, c.my_seat])

	# 局面要是**打到一半那份**，不是新发的一手牌
	check(c.state().round_num == 9,
		"拿到的是打到一半那份（第 %d 回合 ← 9）—— 新发一手牌的话这里是 1"
			% c.state().round_num)
	if not await net_until([main._net, c], func(): return c.phase() != "", 3300):
		check(false, "服务器给他补了一条 phase（实为「%s」）" % c.phase())
	check(c.phase() != "", "阶段也补上了（%s）—— 不补的话他连上了、牌摆好了，"
		% c.phase() + "而场景层那些「不是行动阶段就别动」的门全关着")

	# 他还拿到一串**新令牌**：这一局往后他再掉线就走普通重连那条路了
	check(c.resume_token != "", "新座位给了他一串新令牌（往后掉线走普通重连）")

	# 我这边要看得出他回来了
	if not await net_until([main._net, c], func(): return main._foe_online, 3300):
		check(false, "他回来之后提示摘掉了（_foe_online=%s）" % str(main._foe_online))
	check(main._foe_online, "他回来之后提示摘掉了")
	check(not main._foe_gone(), "针对他的那道拦门也打开了")

	c.close()
	main.queue_free()
	await physics_frame

# ---------- 真服务器的小工具（同 test_resign，端口段错开） ----------
func _server_room() -> NetRoom:
	if _srv == null:
		return null
	for code in _srv.rooms:
		return _srv.rooms[code]
	return null

## 测试局面也经真实服务器发来；只修改客户端展示状态不能成为恢复证据。
func _broadcast_authority(clients: Array) -> void:
	var room := _server_room()
	for peer in room.peers():
		_srv._send_one(peer, room.seated_msg(room.seat_of(peer)))
	await net_pump(clients, 8)

## 接管之后那间房 —— 它在 **main 自己开的**那个服务器里。
## 不能拿 _server_room()：那一个找的是测试起的服务器，而它已经被 _stop 关了
func _host_room(main: Node) -> NetRoom:
	if main._host == null or main._host.server == null:
		return null
	for code in main._host.server.rooms:
		return main._host.server.rooms[code]
	return null
## 等桌上的牌都不动了，返回那一刻的位置表（uid → global_position）。
##
## 判据是「连着 STILL_FRAMES 帧一动不动」而不是「等固定帧数」：
## 后者要么等不够（补间还在飞，量到的位移是补间自己的）、
## 要么白等一大截，而牌数和补间时长都会随改动变
func _settled_pos(clients: Array, main: Node, frames := 400) -> Dictionary:
	const STILL_FRAMES := 8
	var last: Dictionary = {}
	var still := 0
	for i in frames:
		var now: Dictionary = {}
		for uid in main.entities:
			if is_instance_valid(main.entities[uid]):
				now[uid] = main.entities[uid].global_position
		var same: bool = now.size() == last.size() and not now.is_empty()
		if same:
			for uid in now:
				if not last.has(uid) or now[uid].distance_to(last[uid]) > 0.001:
					same = false
					break
		still = still + 1 if same else 0
		last = now
		if still >= STILL_FRAMES:
			return last
		await net_pump(clients)
	return {}

## 一份真场景坐 A 座 + 一条光秃秃的连接替对手收发（同 test_resign）
func _seated_scene(room_code := "TEST", seed_value := 0) -> Array:
	return await net_seated_scene(PORT_BASE, seed_value, room_code)
