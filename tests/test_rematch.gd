# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 「再来一局」（net/room.gd 的 rematch 投票与重开）
##
## 这条路径上每一处漏做的症状都**不报错**，这也是它要单独一条判据的理由：
## 桌子摆得好好的、按钮亮着、日志干净，就是一步也走不了。
## 四层各钉一段：
##   T1 引擎：GameState.new_game() 同一个对象调第二次是不是干净的一局
##   T2 房间：三道拦（不在座、局没完、投过了）+ 掉线撤票
##   T3 房间：一票只广播进度、两票才真重开（先手轮换、弹药池清空）
##   T4 客户端：rematch_start 要清收件箱、换座位、覆盖状态
##   T5 场景层：连接留着而一次性量清掉
##   T6 真 socket：整条投票从按钮走到两边桌子重开，中间过一趟网线。
##      上面五节各自只验一层的**接缝里侧**：T2/T3 直接调 room 的方法，
##      T4/T5 直接喂 JSON 文本。没人验过「客户端 send 出去的东西
##      服务器认不认」——  这一段是唯一走 Server.poll → dispatch 的
##
## 为什么 T1 排在最前：它是下面三段的地基。带着上一局的 winner 进新局，
## IntentApply._decide 和 PhaseMachine.check 开头那两道 game_over 护栏
## 会把**每一条**意图静默拒掉 —— 而 T2/T3/T4 全都要发意图才能验
## （memory: game-over-guard-voids-late-sections 说的是同一个形状）
##
## 变异提示（**都实跑确认过红**，并登记进 tools/mutate_check.py）：
##   1. game_state.new_game 里去掉 `winner = ""`
##      → T1「第二局能走意图」红（不是「winner 非空」红：那只是症状的表面，
##        判据要落在「拒不拒意图」上，那才是玩家看到的东西）
##   2. game_state.new_game 里去掉 `combos.clear()`
##      → T1「第二局组合表是空的」红
##   3. game_state.new_game 里把 `_uid` 也清成 0
##      → T1「uid 接着发号」红（撞号在联网局里是静默的错）
##   4. room.reset_for_rematch 里去掉 `applier.pools_restore({})`
##      → T3「新局双方都没装弹」红（不清的话新局第一次装弹撞 already_armed，
##        那一方整个攻击阶段静默跳过；memory: adjudicator-state-not-in-codec）
##   5. room.reset_for_rematch 里把 `GameState.opponent(state.draw_first)`
##      改成 `state.draw_first` → T3「先手在局间轮换」红
##   6. room.handle_rematch 里去掉 `state.winner == ""` 那道拦
##      → T2「局中不能投票」红（这一条是要紧的：局中能投等于任何一方随时掀桌）
##   7. room.drop_peer 里去掉 `rematch_votes.erase(s)`
##      → T2「掉线撤票」红
##   8. net_transport._on_rematch_start 里去掉 `_inbox.clear()`
##      → T4「新局的收件箱是空的」红
##   9. protocol.from_dict 里去掉 REMATCH_STATE 那个 match 分支
##      → T4「rematch_state 转成了信号」红（T6 也红，但它先在 _until 上超时退出，
##        走不到自己那条判据，所以登记的关键字取 T4 那条）
##  10. 同上，去掉 REMATCH_START 分支 → T4「座位按服务器给的换了」红
##      9/10 是那个字段白名单洞的原样复现，它头一版真是这么漏的。
##      抓得住它的是**喂 JSON 文本**的那几节 —— 走 _on_text 就走 decode；
##      直接拿 Protocol.rematch_state(...) 的返回值判字段的写法看不见它

const A := GameState.PLAYER
const B := GameState.AI

func _initialize() -> void:
	print("=== 再来一局（rematch）测试 ===")
	CardDB.ensure_loaded()
	_t1_new_game_is_a_real_reset()
	_t2_vote_guards()
	_t3_two_votes_reset()
	await _t4_client_adopts_new_game()
	await _t5_scene_keeps_connection()
	await _t6_socket_roundtrip()
	net_stop()
	finish()

# ---------- T1 new_game 必须是真复位 ----------

## 单机局的「再战一局」是换一个 GameState，所以第一版 new_game 只清了 players
## 就够用。联网的 rematch 不能换对象（场景层、IntentApply、NetTransport
## 三处都持着同一份引用），于是这个函数必须自己复位。
##
## 判据全部落在**后果**上而不是字段值上：比如 winner 那条判的是
## 「第二局能不能走一条意图」，不是「winner 是不是空串」。
## 判字段值的写法在「winner 清了但别的残留还在」时会绿，
## 而玩家看到的是同一个症状（一步也走不了）
func _t1_new_game_is_a_real_reset() -> void:
	print("\n-- T1 new_game 是真复位 --")
	var s := GameState.new()
	s.set_seed(20260826)
	s.new_game()
	var uid_after_first: int = s.peek_uid()
	var market_first: Array = s.market.duplicate()

	# 把第一局跑成「结束了的一局」：造一个组合、推几个回合、定下胜负
	s.buy(A, 0)
	var uids: Array = _unit_uids(s, A, CardDB.RES_CASH, 3)
	uids.append(int(s.add_card(A, "ditui")["uid"]))
	s.create_combo(A, uids)
	s.round_num = 7
	s.winner = A
	s.win_reason = "测试造的终局"
	check(not s.combos.is_empty() and not s.log.is_empty(), "第一局确实攒下了状态")

	s.new_game()

	# 最狠的那一条：护栏在两处，判的是「意图走不走得通」
	var ap := IntentApply.new(s)
	var r: Dictionary = ap.apply(Intent.buy(s.action_first(), 0), s.action_first())
	check(bool(r.get("ok", false)),
		"第二局能走意图（%s）—— 带着上一局的 winner 进来的话这里被静默拒掉"
			% str(r.get("reason", "")))
	# check 收的是 op **字符串**，放行时返回空字典（不是 {ok:true}）
	var pm := PhaseMachine.new(s)
	var gate: Dictionary = pm.check(s.action_first(), Intent.OP_BUY)
	check(gate.is_empty(), "第二局的次序闸门也放行（%s）—— PhaseMachine 开头"
		% str(gate.get("code", "")) + "那道 game_over 护栏和 IntentApply 那道是两处")

	check(s.winner == "" and s.win_reason == "", "winner/win_reason 清了")
	# 买卡不推回合，所以这里应当还是第 1 回合。
	# 漏清的话新局从「第 7 回合」开始，战报和 HUD 全串
	check(s.round_num == 1, "回合数回到 1（实为 %d）" % s.round_num)
	check(s.combos.is_empty(),
		"第二局组合表是空的（实为 %d 个）—— 上一局的组合带着上一局的 uid 进来，"
			% s.combos.size()
		+ "而 uid 是重新发号的：结算时按 uid 找卡，找到的是另外几张")
	check(not s.log.is_empty() and s.log.size() < 20,
		"战报也是新局的（%d 条，只有开局那几句）" % s.log.size())

	# _uid 和 _rng 故意不清 —— 两条反向判据
	check(s.peek_uid() > uid_after_first,
		"uid 接着发号（第一局末 %d → 第二局 %d）：撞号在联网局里是静默的错"
			% [uid_after_first, s.peek_uid()])
	check(s.market != market_first or market_first.is_empty(),
		"随机流接着走 —— 新局是另一副牌，不是重播（旧 %s / 新 %s）"
			% [str(market_first), str(s.market)])

	# first 参数：留空沿用当前值，给了就换
	var s2 := GameState.new()
	s2.set_seed(1)
	s2.new_game()
	check(s2.draw_first == A, "单机局照旧从 PLAYER 开（%s）" % s2.draw_first)
	s2.new_game(B)
	check(s2.draw_first == B, "传了先手就换（%s）" % s2.draw_first)
	s2.new_game()
	check(s2.draw_first == B, "留空 = 沿用当前值，不悄悄改回默认（%s）" % s2.draw_first)

func _unit_uids(s: GameState, who: String, res: String, n: int) -> Array:
	var out: Array = []
	for c in s.players[who]["cards"]:
		if out.size() >= n:
			break
		if bool(c.get("locked", false)):
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind", "") == CardDB.KIND_UNIT and def.get("res", "") == res:
			out.append(int(c["uid"]))
	return out

# ---------- 房间小工具 ----------

func _room(seed_value := 4242) -> NetRoom:
	var r := NetRoom.new("TEST", seed_value)
	r.seat_peer(1)
	r.seat_peer(2)
	r.start_if_ready()
	return r

func _peer_of(r: NetRoom, seat: String) -> int:
	return int(r.occupants[seat])

## 房间吐的消息列表 → 拒绝码（"" = 没被拒）
func _reject_code(out: Array) -> String:
	for item in out:
		var m: Dictionary = (item as Dictionary)["msg"]
		if str(m.get("t", "")) == Protocol.REJECTED:
			return str(m.get("code", "rejected"))
	return ""

## 列表里某个类型的消息，按到达次序
func _msgs_of(out: Array, t: String) -> Array:
	var got: Array = []
	for item in out:
		var m: Dictionary = (item as Dictionary)["msg"]
		if str(m.get("t", "")) == t:
			got.append(item)
	return got

## 把局面推成「结束了的一局」。直接写 winner 而不是真打到分出胜负：
## 这几条判据钉的是投票，不是胜负判定（那由 test_full_game 盯着）
func _finish_game(r: NetRoom) -> void:
	r.state.winner = A
	r.state.win_reason = "测试造的终局"

# ---------- T2 三道拦 + 掉线撤票 ----------

## 「什么时候能投」必须由服务器判，不由客户端的按钮可见性判：
## 按钮藏起来只是让人点不到，不是让人发不出。
## 中间那道（局还没结束）是要紧的 —— 局中收到 rematch 就重开
## 等于任何一方随时能掀桌，而它长得像个正常操作（一条空消息）
func _t2_vote_guards() -> void:
	print("\n-- T2 投票的三道拦 --")
	var r := _room()

	# 不在座位上
	check(_reject_code(r.handle_rematch(999)) == "no_seat", "不在座位上不能投票")

	# 局还没结束
	check(_reject_code(r.handle_rematch(1)) == "not_over", "局中不能投票（不许掀桌）")
	check(r.rematch_votes.is_empty(), "被拒的票没记下")
	check(r.state.round_num >= 1 and r.state.winner == "", "而且局面没被这次投票动过")

	# 结束了才收
	_finish_game(r)
	var first := r.handle_rematch(1)
	check(_reject_code(first) == "", "终局之后能投票")
	check(r.voted_seats().size() == 1, "记下了一票（%s）" % str(r.voted_seats()))

	# 同一个人投两次
	check(_reject_code(r.handle_rematch(1)) == "already_voted", "同一座位不能投两次")
	check(r.voted_seats().size() == 1, "重复票没被重复记（%s）" % str(r.voted_seats()))

	# 一票只广播进度，**不重开**
	var st := _msgs_of(first, Protocol.REMATCH_STATE)
	check(st.size() == 1, "一票广播一条 rematch_state（%d 条）" % st.size())
	check(int((st[0] as Dictionary)["to"]) == 0, "而且是广播给两边（to=0）")
	check(_msgs_of(first, Protocol.REMATCH_START).is_empty(),
		"一票不许开新局（对手还没点，终局面板会被从他屏幕上抽走）")
	check(r.state.winner != "", "一票之后局面还是终局")
	check(r.game_num == 1, "一票之后局数没加（%d）" % r.game_num)

	# votes 是**按 SEATS 的次序**的名单，不是字典键序
	var votes: Array = ((st[0] as Dictionary)["msg"] as Dictionary)["votes"]
	check(votes.size() == 1 and str(votes[0]) == r.seat_of(1),
		"名单里是投票那个座位（%s）" % str(votes))

	# 掉线撤票：票记在人身上，不在座位上
	var r2 := _room()
	_finish_game(r2)
	r2.handle_rematch(1)
	check(r2.voted_seats().size() == 1, "先投一票")
	r2.drop_peer(1)
	check(r2.voted_seats().is_empty(), "掉线撤票 —— 留着的话另一位一点就开新局，"
		+ "而他等的那个人不在了，新局第一个对手回合停在等一条永远不来的 action_done")

# ---------- T3 两票齐了才真重开 ----------

func _t3_two_votes_reset() -> void:
	print("\n-- T3 两票齐了 --")
	var r := _room(777)
	# 造点残留：组合、回合数、弹药池 —— 三样各有一条判据
	var uids: Array = _unit_uids(r.state, A, CardDB.RES_CASH, 3)
	uids.append(int(r.state.add_card(A, "ditui")["uid"]))
	r.state.create_combo(A, uids)
	r.state.round_num = 5
	r.applier.seed_pool_for_test(A, 9, 4)
	r.applier.seed_pool_for_test(B, 3, 1)
	check(r.applier.armed(A) and r.applier.armed(B), "两边都造了弹药池")
	var uid_before: int = r.state.peek_uid()
	var first_before: String = r.state.draw_first
	_finish_game(r)

	r.handle_rematch(_peer_of(r, A))
	var out: Array = r.handle_rematch(_peer_of(r, B))
	check(_reject_code(out) == "", "第二票也收下了")

	# 每人一份自己的 rematch_start（座位会变，不能广播同一条）
	var starts := _msgs_of(out, Protocol.REMATCH_START)
	if not need(starts.size() == 2, "两个座位各收到一条 rematch_start（%d 条）"
			% starts.size()):
		return
	var seen := {}
	for item in starts:
		var d: Dictionary = item
		var m: Dictionary = d["msg"]
		var to := int(d["to"])
		check(to != 0, "rematch_start 是点对点发的（不是广播）")
		var mine := str(m["my_seat"])
		seen[mine] = true
		check(r.seat_of(to) == mine,
			"发给 %d 的那条写的是他自己的座位（%s / 实占 %s）"
				% [to, mine, r.seat_of(to)])
		check(str(m["foe_seat"]) == GameState.opponent(mine), "对手座位跟着对")
		check((m["snapshot"] as Dictionary).has("pools"), "带的是全量快照（含池子）")
	check(seen.size() == 2, "两条写的是两个不同的座位（%s）" % str(seen.keys()))

	# 阶段广播：新局的第一个行动阶段由服务器这条 phase 开
	var ph := _msgs_of(out, Protocol.PHASE)
	check(ph.size() == 1, "跟着广播了一条 phase（%d 条）" % ph.size())
	if not ph.is_empty():
		check(str(((ph[0] as Dictionary)["msg"] as Dictionary)["phase"])
			== PhaseMachine.ACTION, "而且是行动阶段")

	# 真的是干净的一局吗
	check(r.state.winner == "", "新局没带着上一局的 winner")
	check(r.state.round_num == 1, "回合数回到 1（实为 %d）" % r.state.round_num)
	check(r.state.combos.is_empty(), "组合表清了（%d 个）" % r.state.combos.size())
	check(r.rematch_votes.is_empty(), "票也清了 —— 不清的话下一局终局时一点就开第三局")
	check(r.game_num == 2, "局数加到 2（%d）" % r.game_num)
	check(r.state.peek_uid() > uid_before, "uid 接着发号（%d → %d）"
		% [uid_before, r.state.peek_uid()])

	# 弹药池：跟着 applier 活着，StateCodec 看不见它
	check(not r.applier.armed(A) and not r.applier.armed(B),
		"新局双方都没装弹 —— 不清的话新局第一次装弹撞 already_armed，"
		+ "那一方整个攻击阶段静默跳过")

	# 先手轮换
	check(r.state.draw_first == GameState.opponent(first_before),
		"先手在局间轮换（%s → %s）：房间里先进来的人坐 PLAYER，"
		% [first_before, r.state.draw_first]
		+ "不轮换的话同一个人局局先抽")

	# 新局真能走：次序闸门也跟着换了新的（phase 是重建的那个）
	var actor: String = r.phase.actor
	check(_reject_code(r.handle_intent(_peer_of(r, actor), Intent.buy(actor, 0))) == "",
		"新局第一条意图走得通（%s 买卡）" % actor)

	# 再打一局再投，先手要再翻回来
	_finish_game(r)
	var f2: String = r.state.draw_first
	r.handle_rematch(_peer_of(r, A))
	r.handle_rematch(_peer_of(r, B))
	check(r.state.draw_first == GameState.opponent(f2),
		"第三局又翻回来（%s → %s）" % [f2, r.state.draw_first])
	check(r.game_num == 3, "局数到 3（%d）" % r.game_num)

# ---------- T4 客户端接住新局 ----------

## 不开端口：这一段钉的是收到 rematch_start 之后客户端**自己**要做的四件事。
## 收件箱那条是最贵的一条 —— 里面攒着上一局的 applied，不清的话新局
## 第一次 await pipe.arm() 会立刻拿到上一局排在队头的那条，
## 于是场景层按上一局的结果演新局的攻击阶段，而状态早已是新局的
func _t4_client_adopts_new_game() -> void:
	print("\n-- T4 客户端接住新局 --")
	var c := NetTransport.new("ws://127.0.0.1:1", "TR4")   # 不连，只用收包逻辑
	c.my_seat = A
	c.foe_seat = B

	# 造上一局的残留：队里压着两条服务器操作 + 一条在飞的意图
	var old := NetRoom.new("OLD", 1)
	old.state.round_num = 6
	c._on_text(JSON.stringify(Protocol.applied(
		{ "ok": true, "op": Intent.OP_ARM, "seat": A, "empty": true, "pools": {"cash": 0, "user": 0} }, 1, old.snapshot())))
	c._on_text(JSON.stringify(Protocol.applied(
		{ "ok": true, "op": Intent.OP_FINALIZE, "seat": A }, 2, old.snapshot())))
	c._pending = true
	check(c._inbox.size() == 2, "队里压着上一局的两条（%d）" % c._inbox.size())

	# 服务器那边开了新局，座位换了
	var r := _room(20260826)
	_finish_game(r)
	r.handle_rematch(_peer_of(r, A))
	var out: Array = r.handle_rematch(_peer_of(r, B))
	var mine := ""
	var start_msg: Dictionary = {}
	for item in _msgs_of(out, Protocol.REMATCH_START):
		var m: Dictionary = (item as Dictionary)["msg"]
		if str(m["my_seat"]) == B:      # 故意取**另一个**座位那条，验换座位
			start_msg = m
			mine = B
	if not need(not start_msg.is_empty(), "取到了 B 那条 rematch_start"):
		return

	var fired: Array = []
	c.rematch_started.connect(func(a2, b2): fired.append([a2, b2]))
	c._on_text(JSON.stringify(start_msg))

	check(c._inbox.is_empty(), "新局的收件箱是空的（还剩 %d 条）" % c._inbox.size())
	check(not c._pending, "在飞的那条落地了 —— 留着 true 的话新局第一条 submit "
		+ "一进来就撞上「一次只允许一条在飞」")
	check(c.my_seat == B and c.foe_seat == A,
		"座位按服务器给的换了（%s/%s）" % [c.my_seat, c.foe_seat])
	check(fired.size() == 1, "发了一次 rematch_started（%d 次）" % fired.size())
	if not fired.is_empty():
		check(str(fired[0][0]) == B, "信号带的是新座位（%s）" % str(fired[0][0]))
	check(c.state().round_num == 1,
		"状态覆盖成新局了（第 %d 回合）" % c.state().round_num)
	check(c.state().winner == "", "客户端那份也没带着 winner")
	check(c.state().combos.is_empty(), "客户端那份组合表也是空的")

	# 投票进度的信号
	var votes: Array = []
	c.rematch_voted.connect(func(v): votes.append(v))
	c._on_text(JSON.stringify(Protocol.rematch_state([A])))
	check(votes.size() == 1 and (votes[0] as Array).has(A),
		"rematch_state 转成了信号（%s）" % str(votes))

	# request_rematch 在断了的连接上要静默 —— 那个按钮点了没反应，
	# 比弹一句「连接已断」好（断线本身已经报过一次了）
	c.request_rematch()
	check(true, "断了的连接上投票不崩")
	c.close()
	await physics_frame

# ---------- T5 场景层：连接留着，一次性量清掉 ----------

## 和 _on_restart 的差别只有三样，但每一样都是必需的（见 main._on_rematch_started）。
## 这一节钉两样能在无服务器下验的：keep_net 不动连接、_net_phase_seen 跟着清
func _t5_scene_keeps_connection() -> void:
	print("\n-- T5 场景层留着连接 --")
	var main: Node = await boot_main()
	var c := NetTransport.new("ws://127.0.0.1:1", "TR5")
	c.my_seat = A
	c.foe_seat = B
	# **必须先喂一份快照**：客户端那份 GameState 是空的（连 players 都没有键），
	# 而 begin_net_game 里的 _respawn_all 头一件事就是遍历 state.players[my_seat]。
	# 真实路径上这一步由 seated 带着快照做掉，测试里少了它就崩在摆桌子上 ——
	# 而崩在那里的后果是 begin_net_game 后半段（藏联网入口、灰按钮）一句都没跑，
	# 于是后面那几条判据报的是「入口没藏」，跟 rematch 一点关系都没有
	var seed_room := _room(20260826)
	c._on_text(JSON.stringify(seed_room.seated_msg(A)))
	main.begin_net_game(c)
	await settle()
	check(main.entities.size() > 0, "桌子摆出来了（%d 张）" % main.entities.size())
	check(main._net == c, "装上了这条连接")

	main._net_phase_seen = true
	main._foe_action_done = true
	main._reset_session_flags(true)
	check(main._net == c, "keep_net 不动连接 —— 断了就没有对手了")
	check(not main._net_phase_seen,
		"一次性量跟着清 —— 不清的话新局双方都是灰按钮，谁也动不了")
	check(not main._foe_action_done, "对手收手标记也清了")
	check(not main.btn_net.visible, "联网入口没被放回来（还在局里）")

	# 不带参数那条照旧断连接、退回单机局
	main._reset_session_flags()
	check(main.my_seat == GameState.PLAYER and main.foe_seat == GameState.AI,
		"不带 keep_net 就退回单机那一对座位（%s/%s）" % [main.my_seat, main.foe_seat])
	check(main.btn_net.visible, "联网入口放回来了")

	main.queue_free()
	await physics_frame

# ---------- T6 真 socket 走一遍整条投票 ----------

## 上面五节全是**直接喂**（房间的返回值、客户端的 _on_text），一条都没过网线。
## 这一节要过 —— 因为 Protocol.from_dict 是个**字段白名单**：
## REQUIRED 登记了、构造函数写了、上面那些判据全绿，而 REMATCH_STATE 和
## REMATCH_START 头一版**没有 match 分支**，于是过一趟 decode 之后
## votes 和 my_seat 都被静默丢掉。症状是「点了没反应」，没有任何一行报错。
## T4 那节喂的是 `Protocol.rematch_state(...)` 的**返回值**，不是解码后的，
## 所以它照样绿 —— 这一节是那个洞唯一的证人
func _t6_socket_roundtrip() -> void:
	print("\n-- T6 真 socket 走一遍 --")
	var pair := await _seated_pair(20260826, "TRMT")
	if pair.is_empty():
		return
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	check(true, "双方都入座了（%s / %s）" % [a.my_seat, b.my_seat])
	var room := _server_room()
	if not need(room != null, "服务器开出了房间"):
		return

	# 两边都记下收到的投票进度和新局通知
	var votes_a: Array = []
	var votes_b: Array = []
	var started_a: Array = []
	var started_b: Array = []
	a.rematch_voted.connect(func(v): votes_a.append(v))
	b.rematch_voted.connect(func(v): votes_b.append(v))
	a.rematch_started.connect(func(m, f): started_a.append([m, f]))
	b.rematch_started.connect(func(m, f): started_b.append([m, f]))

	# 局中投票要被拒（这一条也过网线：拦在服务器，不在按钮可见性上）
	var rejected: Array = []
	a.rejected.connect(func(r): rejected.append(r))
	a.request_rematch()
	await net_pump([a, b], 8)
	check(rejected.size() >= 1 and str((rejected[0] as Dictionary).get("code", ""))
		== "not_over", "局中投票被服务器拒了（%s）" % str(rejected))
	check(votes_a.is_empty() and votes_b.is_empty(), "被拒的票没广播出去")

	# **先把上一局推离第 1 回合**：不推的话下面那句「新局是第 1 回合」
	# 是拿 1 和 1 比 —— 复位漏掉了它照样绿
	# （memory: earlier-section-zeroes-the-assertion 是同一个形状）
	room.state.round_num = 4
	_finish_game(room)
	var first_before: String = room.state.draw_first
	var round_before: int = room.state.round_num
	check(round_before == 4, "上一局停在第 %d 回合（判据要它 ≠ 1）" % round_before)

	# A 先投：**两边**都要收到进度（对手那侧的按钮也要变字）
	a.request_rematch()
	if not await net_until([a, b], func(): return not votes_b.is_empty()):
		check(false, "对手侧收到了投票进度（a=%s b=%s）" % [str(votes_a), str(votes_b)])
		return
	check(not votes_a.is_empty(), "自己也收到了一份（两侧同一条广播）")
	var v: Array = votes_b[votes_b.size() - 1]
	check(v.size() == 1 and str(v[0]) == a.my_seat,
		"名单里是 A 的座位（%s）—— 过 decode 之后 votes 还在" % str(v))
	check(started_a.is_empty() and started_b.is_empty(), "一票还没开新局")

	# B 也投：新局开起来
	b.request_rematch()
	if not await net_until([a, b], func():
			return not started_a.is_empty() and not started_b.is_empty()):
		check(false, "两边都收到了新局通知（a=%d b=%d）"
			% [started_a.size(), started_b.size()])
		return
	check(true, "两票齐了，两边都收到 rematch_start")
	check(str(started_a[0][0]) == a.my_seat and str(started_b[0][0]) == b.my_seat,
		"各自收到的是自己的座位（%s / %s）" % [str(started_a[0][0]), str(started_b[0][0])])
	check(str(started_a[0][0]) != str(started_b[0][0]), "而且两人不同座")

	# 服务器和两个客户端三份状态都得是新局
	check(room.state.winner == "" and room.state.round_num == 1,
		"服务器那份是新局（第 %d 回合 ← 上一局第 %d，winner=%s）"
			% [room.state.round_num, round_before, str(room.state.winner)])
	for c in [a, b]:
		var t: NetTransport = c
		check(t.state().winner == "" and t.state().round_num == 1,
			"%s 那份也是新局（第 %d 回合）" % [t.my_seat, t.state().round_num])
		check((t.state().players[t.my_seat]["cards"] as Array).size() > 0,
			"%s 手里有开局的牌（%d 张）" % [t.my_seat,
				(t.state().players[t.my_seat]["cards"] as Array).size()])
	check(room.state.draw_first == GameState.opponent(first_before),
		"先手轮换（%s → %s）" % [first_before, room.state.draw_first])

	# 新局真能走一步：这是「重开了」和「重开了但走不动」的分界
	var actor: String = room.phase.actor
	var mover: NetTransport = a if a.my_seat == actor else b
	var done := false
	net_pump_until([a, b], func(): return done)
	var r: Dictionary = await mover.submit(Intent.buy(actor, 0))
	done = true
	check(bool(r.get("ok", false)), "新局第一条意图过网线走通了（%s：%s）"
		% [actor, str(r.get("reason", ""))])

	a.close()
	b.close()
	await net_pump([a, b], 4)

# ---------- 真服务器的小工具（与 test_net_client 同法，端口段错开） ----------

const PORT_BASE := 47300

## submit 是协程且自己泵帧，但它只泵自己 —— 服务器得有人摇。
## 起一个并行的泵：submit 挂在 await 上时这个循环还在跑
func _seated_pair(seed_value := 0, room := "TEST") -> Array:
	return await net_seated_pair(PORT_BASE, seed_value, room)

func _server_room() -> NetRoom:
	for code in _srv.rooms:
		return _srv.rooms[code]
	return null
