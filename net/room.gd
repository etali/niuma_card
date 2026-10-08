# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name NetRoom
extends RefCounted

## 一个房间 = 一局棋 + 两个座位；连接管理留给 NetServer，回合次序交给 PhaseMachine。
##
## 为什么从服务器里拆出来：房间是**纯逻辑**的（收一条意图、吐一批要广播的消息），
## 里面没有一行 WebSocket。于是它能在无头测试里直接跑 ——
## 「同一串意图，单机路径和联网路径产出同一份状态哈希」那条判据
## （tests/test_net_parity.gd）
## 要的正是这个：不开端口就能比。
## tools/pvp_server.gd 只负责把字节搬进搬出。
##
## 权威在这里：state / applier / phase 都是服务器这份，客户端只有副本。
## 客户端发来的意图先过 PhaseMachine（轮到你吗）再过 IntentApply（合规吗），
## 两道都过才落地，然后把结果广播给双方

## 房间里的座位就是引擎的两个座位。先进来的人坐 PLAYER。
##
## 这个不对称是**引擎本来就有的**：draw_first 默认 PLAYER，
## action_first() 是它的反面。所以「先进来的人先抽卡」——
## 不是随机分座位，那样两局之间同一个人的体验会莫名其妙地变
const SEATS := [GameState.PLAYER, GameState.BOT]

var code := ""
var state: GameState
var applier: IntentApply
var phase: PhaseMachine

## seat -> peer id（0 = 空座）。断线时置 0 但**保留房间**，等重连
var occupants: Dictionary = {}
## seat -> 重连令牌。断线的人拿它证明「我是原来那个座位」，
## 否则第三个人连进来就能顶掉刚掉线的那位
var tokens: Dictionary = {}
var seq := 0

## 这一局结束后点了「再来一局」的座位。**两个都点齐才重开**（net/room.gd 的 rematch 投票与重开）。
##
## 为什么要投票而不是一方点了就重开：终局面板是玩家读战报的地方，
## 对手单方面重开会把它从屏幕上抽走 —— 那一刻他连自己为什么输都还没看完。
## 局间是这个游戏唯一的「非实时」时刻，等一下不花成本
var rematch_votes: Dictionary = {}
## 已经开过几局（第一局是 1）。发给客户端只为提示语里那个数
var game_num := 1

## seat → 那一侧最后一次声明的摞分组（形状见 Protocol.PILES）。
##
## 房间**只是记着**，一个字都不解释：它没有布局，也不知道 compact 是什么意思
## （handle_piles 那段说的就是这件事）。存下来只为一个用途 —— 有人重连进来时
## 回放两份：他自己那份（MY_PILES）和对手那份（FOE_PILES）。
##
## 为什么非得让服务器记：摞只活在客户端的 board.groups 里，是纯表现。
## 重连的人是一张空桌子，快照里没有摞（那不是状态）；而留下的那一位
## 也不会重发 —— 他的 _push_piles 是**比指纹去重**的（main.gd），
## 分组没变就一条都不发，于是「对手重连了」这件事在他那边不产生任何广播。
## 两头都不发，就只有服务器还留着这份东西
var piles: Dictionary = {}

var _rng := RandomNumberGenerator.new()

func _init(room_code: String, seed_value := 0) -> void:
	code = room_code
	_rng.randomize()
	state = GameState.new()
	if seed_value != 0:
		state.set_seed(seed_value)
	applier = IntentApply.new(state)
	for s in SEATS:
		occupants[s] = 0
		tokens[s] = _make_token()

func _make_token() -> String:
	return "%d-%d" % [_rng.randi(), Time.get_ticks_usec()]

# ---------- 入座 ----------

func free_seat() -> String:
	for s in SEATS:
		if int(occupants[s]) == 0:
			return s
	return ""

func full() -> bool:
	return free_seat() == ""

func started() -> bool:
	return phase != null

func seat_of(peer: int) -> String:
	for s in SEATS:
		if int(occupants[s]) == peer:
			return s
	return ""

## 令牌对得上的那个座位（重连用）。对不上返回 ""
func seat_for_token(token: String) -> String:
	if token == "":
		return ""
	for s in SEATS:
		if str(tokens[s]) == token:
			return s
	return ""

## 让一个连接入座。token 非空且对得上就是**重连**（回原座位），
## 否则占一个空位。返回 { ok, seat } 或 { ok=false, code, reason }
func seat_peer(peer: int, token := "") -> Dictionary:
	var existing := seat_of(peer)
	if existing != "":
		return { "ok": true, "seat": existing, "resumed": true }
	var resumed := seat_for_token(token)
	if resumed != "":
		# 重连不看座位是否被占：占着的只可能是自己（令牌是一对一的），
		# 或者是一个已经掉线但服务器还没收到断开通知的旧连接
		occupants[resumed] = peer
		return { "ok": true, "seat": resumed, "resumed": true }
	var s := free_seat()
	if s == "":
		return Protocol.err(Protocol.CLOSE_ROOM_FULL, "房间 %s 已经满了" % code)
	occupants[s] = peer
	return { "ok": true, "seat": s, "resumed": false }

## 连接断开：座位置空但**不删房间**（scenes/main.gd 的 _offer_reconnect / _on_net_down：没有隐藏信息，重连很便宜）。
## 令牌留着，原来那个人拿它能回来
func drop_peer(peer: int) -> String:
	var s := seat_of(peer)
	if s != "":
		occupants[s] = 0
		# 掉线**撤票**。留着的后果是这一票会记在座位上而不是人身上：
		# 投了票的人走掉之后，另一位一点就直接开新局 —— 而他等的那个人不在了，
		# 新局第一个对手回合停在等一条永远不来的 action_done（scenes/main.gd 的 _offer_reconnect / _on_net_down 处理的断线状态）。
		# 重连回来的人自己再点一次就是了：终局面板本来就还在他屏幕上
		rematch_votes.erase(s)
	return s

func empty() -> bool:
	for s in SEATS:
		if int(occupants[s]) != 0:
			return false
	return true

## 两个座位都坐满了 → 开局。已经开过就不再开（重连不该重开一局）
func start_if_ready() -> bool:
	if started() or not full():
		return false
	state.new_game()
	phase = PhaseMachine.new(state)
	return true

## 拿一份**别处跑到一半**的对局把这间房填上（主机易位，scenes/main.gd 的 _take_over_host）。
##
## 用在原主机进程走了、留下的那一位自己开服接管的时候：他手里那份状态
## 是权威那份的副本（每一步都经原服务器落地过），于是「接管」就是
## 把这份副本装进一间新房，而不是重开一局。
##
## 三件事一起做，少一件都不行：
##   - state + pools —— 池子不在 GameState 上（见 snapshot() 那段说明）。
##     漏了它攻击回合会**整段被跳过**而不报错
##   - phase —— 先建 PhaseMachine 再 adopt。建的那一下会 reset_for_round
##     （回到行动阶段、先手先动），照着走等于把打到一半的回合退回开头；
##     adopt 把它按住在真实的那一步上
##   - my_token —— 接管的人**必须坐回原座**。快照里的牌是按座位名存的，
##     坐错位等于两个人的牌当场对调。手法是把他原来那串令牌**种进**
##     tokens 里，让他走的还是普通重连那条路（seat_peer 的 resumed 支），
##     而不是给接管另开一条入座路径
##
## started() 从这一刻起为真，所以后进来的那位不会触发 start_if_ready ——
## 那正是要的：他要拿的是这份打到一半的快照，不是新发的一手牌
func adopt(snap: Dictionary, phase_name: String, actor_seat: String,
		my_seat: String, my_token: String) -> void:
	StateCodec.restore(state, snap)
	applier.pools_restore(snap.get("pools", {}))
	phase = PhaseMachine.new(state)
	phase.adopt(phase_name, actor_seat)
	if my_seat != "" and my_token != "" and tokens.has(my_seat):
		tokens[my_seat] = my_token

# ---------- 再来一局（net/room.gd 的 rematch 投票与重开） ----------

## 一个座位点了「再来一局」。返回要广播的消息列表。
##
## 三道拦：不在座位上、局还没结束、已经投过。中间那道是要紧的 ——
## 局中收到 rematch 就重开等于**任何一方随时能掀桌**，
## 而它长得像个正常操作（客户端只要发一条空消息）。
## 所以「什么时候能投」由服务器判，不由客户端的按钮可见性判：
## 按钮藏起来只是让人点不到，不是让人发不出
func handle_rematch(peer: int) -> Array:
	var seat := seat_of(peer)
	if seat == "":
		return [_to(peer, Protocol.rejected("no_seat", "你不在这个房间的座位上"))]
	if state.winner == "":
		return [_to(peer, Protocol.rejected("not_over", "这一局还没结束"))]
	if bool(rematch_votes.get(seat, false)):
		return [_to(peer, Protocol.rejected("already_voted", "你已经点过再来一局了"))]
	rematch_votes[seat] = true
	# 进度先广播出去：对手要立刻看到「对手想再来一局」，
	# 而不是等他自己也点了才知道有人在等他
	var out: Array = [_all(Protocol.rematch_state(voted_seats()))]
	if voted_seats().size() < SEATS.size():
		return out
	out.append_array(reset_for_rematch())
	return out

## 已投票的座位，**按 SEATS 的次序**。次序固定是为了让它能进判据：
## 拿 Dictionary 的键序当返回值的话，同一份投票在两次运行里可能顺序不同
func voted_seats() -> Array:
	var out: Array = []
	for s in SEATS:
		if bool(rematch_votes.get(s, false)):
			out.append(s)
	return out

## 双方都点齐 → 真的重开。
##
## **复用同一个 GameState**（不 new 一个）：applier 持着它、
## 两个客户端各自的副本也是按「覆盖进已有对象」的语义在同步的
## （StateCodec.restore）。换对象要把 applier 一起重建，而那份 applier
## 上还挂着弹药池 —— 也就是说「换对象」这条路要重建的东西比看起来多。
## 于是干净的一局由 GameState.new_game() 自己保证（见那个函数的说明）。
##
## **先手在局间轮换**：抽卡先手默认 PLAYER，而房间里先进来的人坐 PLAYER
## （见 SEATS 那段）—— 不轮换的话同一个人局局先抽，那是一局定终身的不对称，
## 而 rematch 恰好是它唯一会被看见的场合（单机局对手是 BOT，没人计较）。
## 传的是「这一局先手的对手」，和 end_round 里那句 `draw_first = opponent(draw_first)`
## 是同一个语义，只是跨局那一跳没人替它做
##
## 弹药池要清：它是上一局攻击阶段的中间量，跟着 applier 活着
## （memory: adjudicator-state-not-in-codec）。不清的话新局第一次装弹会被
## already_armed 拦掉，那一方整个攻击阶段静默跳过
##
## 记着的摞也要清（见 piles 那段）：新局是一手新牌，上一局那些 uid
## 一个都不在场上了。不清的话双方在新局一开始就各收到一份回放，
## 里面全是查不着的 uid —— 收方虽然会静默跳过（_bot_piles 逐个查 state），
## 但下一次 _push_piles 的去重指纹是拿**我这边的实况**算的，
## 于是那份垃圾会一直留在服务器里，直到有人真的摞了一摞
func reset_for_rematch() -> Array:
	rematch_votes.clear()
	game_num += 1
	piles.clear()
	applier.pools_restore({})
	state.new_game(GameState.opponent(state.draw_first))
	phase = PhaseMachine.new(state)
	var out: Array = []
	# 按座位分别发：每个人要收到**自己**那份 my_seat/foe_seat
	for s in SEATS:
		var p := int(occupants[s])
		if p != 0:
			out.append(_to(p, Protocol.rematch_start(
				s, GameState.opponent(s), snapshot())))
	out.append(_all(Protocol.phase(phase.phase, phase.actor)))
	_stamp_recovery(out)
	return out

# ---------- 意图落地 ----------

## 客户端发来一条意图。返回要广播的消息列表：
##   [{ to: peer|0, msg: {...} }]，to = 0 表示广播给房里所有人
##
## 两道校验的次序是**先次序后规则**：不轮到你的时候，钱够不够根本不该被算 ——
## 那等于在对方回合里替你试算，而试算的结果（比如「靶已不在场上」）
## 会泄露一点对方刚做了什么的时序信息
func handle_intent(peer: int, raw: Dictionary) -> Array:
	var seat := seat_of(peer)
	if seat == "":
		return [_to(peer, Protocol.rejected("no_seat", "你不在这个房间的座位上"))]
	if not started():
		return [_to(peer, Protocol.rejected("not_started", "对手还没进来"))]
	var dec: Dictionary = Intent.from_dict(raw)
	if not dec["ok"]:
		return [_to(peer, Protocol.rejected(dec["code"], dec["reason"]))]
	var it: Dictionary = dec["intent"]
	var op: String = it["op"]

	var gate: Dictionary = phase.check(seat, op)
	if not gate.is_empty():
		return [_to(peer, Protocol.rejected(gate["code"], gate["reason"]))]

	# from_seat 传 seat（连接自带的身份），不是包里自称的那个：
	# 冒充校验在 IntentApply 里，靠的就是这两个不相等
	var r: Dictionary = applier.apply(it, seat)
	if not r.get("ok", false):
		return [_to(peer, Protocol.rejected(str(r.get("code", "rejected")),
			str(r.get("reason", ""))))]
	var out: Array = [_applied(r)]
	out.append_array(_advance(seat, op))
	_stamp_recovery(out)
	return out

## 一个意图可能同步完成装弹、全部产出、收尾和下一回合。
## 每个回执都携带本批最终检查点：TCP 在任意包后断开也不会留下半个结算事务。
func recovery_checkpoint() -> Dictionary:
	if not started(): return {}
	return {"snapshot": snapshot(), "phase": phase.phase, "actor": phase.actor, "seq": seq}

func _stamp_recovery(out: Array) -> void:
	var checkpoint := recovery_checkpoint()
	for item in out:
		if item["msg"]["t"] in [Protocol.APPLIED, Protocol.REMATCH_START]:
			item["msg"]["recovery"] = checkpoint
		elif item["msg"]["t"] == Protocol.PHASE:
			# 阶段消息也归属整批事务，恢复后才能识别其中迟到的中间阶段。
			item["msg"]["seq"] = seq

func phase_msg() -> Dictionary:
	return Protocol.phase(phase.phase, phase.actor, seq)

## 落地成功之后推进阶段。
##
## 这些 await 不了的事情（产出结算要逐组演出）在 C1 里怎么办：
## 服务器**只发 phase，不替客户端演出**。它把状态推到位、广播新阶段，
## 两端各自按自己的节奏放动画 —— 动画长度不影响状态，因为状态早就定了。
## 客户端只消费裁决结果，演出快慢不会改变服务端状态。
func _advance(seat: String, op: String) -> Array:
	var out: Array = []
	match op:
		Intent.OP_ACTION_DONE:
			if phase.mark_done(seat):
				out.append_array(_run_attack_and_settle())
			else:
				out.append(_all(Protocol.phase(phase.phase, phase.actor)))
		Intent.OP_ATTACK_DONE:
			out.append_array(_after_attack_turn())
		Intent.OP_ATTACK:
			if state.winner != "":
				# 致胜后 ATTACK_DONE 已被 game_over 拒绝，不能再等收手来收尾。
				# 客户端会在撕牌演出后消费 FINALIZE；缺失时要白等一个超时窗口。
				out.append(_applied(applier.apply(Intent.finalize())))
	if state.winner != "":
		phase.begin_over()
		out.append(_all(Protocol.phase(PhaseMachine.OVER, state.winner)))
	return out

## 双方行动完毕 → 攻击阶段，先手先攻。
## 装弹以**服务器身份**提交（from_seat 空）：arm 不是客户端能发的操作
func _run_attack_and_settle() -> Array:
	var out: Array = []
	phase.begin_attack()
	out.append_array(_arm_current())
	return out

## 给当前攻击方装弹。装出来是空池（没编攻击组合）就直接换手 ——
## 否则那一方会卡在「等你点选」而它一个点数都没有
func _arm_current() -> Array:
	var out: Array = []
	var r: Dictionary = applier.apply(Intent.arm_attacks(phase.actor))
	out.append(_applied(r))
	if bool(r.get("empty", true)):
		out.append_array(_after_attack_turn())
	else:
		out.append(_all(Protocol.phase(phase.phase, phase.actor)))
	return out

## 一方攻击完毕：换手，或者两边都打完 → 结算
func _after_attack_turn() -> Array:
	var out: Array = []
	phase.mark_done(phase.actor)
	if state.winner == "" and phase.next_attacker():
		out.append_array(_arm_current())
		return out
	out.append_array(_settle())
	return out

## 产出结算 + 收尾 + 开新回合。
##
## 逐组发 produce 而不是一步跑完：客户端要在每组之间插演出
## （scenes/main.gd 的 _resolve_combo_visual）。次序必须和
## Transport.run_settle 一致 —— 那是 tests/test_intent.gd 的同构判据在比的东西
func _settle() -> Array:
	var out: Array = []
	phase.begin_settling()
	out.append(_all(Protocol.phase(PhaseMachine.SETTLING, "")))
	# 清零即胜：攻击阶段已经打出胜负时**跳过产出**。
	# 这个 if 不是优化，是对齐 —— Settle.run 和 Transport.run_round 都是
	# `if winner == "": produce`。少了它，联网局会在赢定之后多发一轮产出，
	# 而单机局不发：两条路径从此哈希不等（tests/test_net_parity.gd 的 T2 就在比这个）
	if state.winner == "":
		var n: int = applier.production_count()
		for i in n:
			var r: Dictionary = applier.apply(Intent.produce(i))
			out.append(_applied(r))
	var fin: Dictionary = applier.apply(Intent.finalize())
	out.append(_applied(fin))
	if state.winner != "":
		return out
	var nr: Dictionary = applier.apply(Intent.next_round())
	out.append(_applied(nr))
	phase.reset_for_round()
	out.append(_all(Protocol.phase(phase.phase, phase.actor)))
	return out

# ---------- 拖拽转发 ----------

## 拖拽帧原样转给对手：服务器不重算坐标，它没有布局。
## 不校验 uids 归属：这是**展示**通道，看错了只是画错一下，
## 而拦下来要按 seq 补一帧，代价远大于收益。真正动状态的是对应的 intent
func handle_drag(peer: int, msg: Dictionary) -> Array:
	var seat := seat_of(peer)
	if seat == "":
		return []
	var foe := int(occupants.get(GameState.opponent(seat), 0))
	if foe == 0:
		return []
	return [_to(foe, Protocol.foe_drag(msg))]

## 摞分组转发。和 handle_drag 一样是**纯转发**：不进 applier、不动 state、
## 不问阶段 —— 摞是表现，不是玩法（见 Protocol.PILES）。
##
## 所以也不校验「这几张是不是你的牌」：转过去之后收方按自己那份 state
## 逐个 uid 查（settle_layout._bot_piles 只认对手名下、且有实体的卡），
## 编造别人的 uid 最多让自己那份分组里多一条查不着的记录。
## 这条纪律和服务器权威不冲突 —— 权威管的是牌和钱，那些一律走 intent
## 记一笔**再**转发。存那一下在 foe == 0 的判断**之前** ——
## 对手不在场时照样要存：这正是最要紧的那一刻（对手掉线了，
## 而我还在挪我的摞），不存的话他重连回来看到的是掉线**之前**那份摆放
func handle_piles(peer: int, msg: Dictionary) -> Array:
	var seat := seat_of(peer)
	if seat == "":
		return []
	piles[seat] = Protocol.pile_lists(msg.get("piles", []))
	var foe := int(occupants.get(GameState.opponent(seat), 0))
	if foe == 0:
		return []
	return [_to(foe, Protocol.foe_piles(msg))]

## 某一侧声明过的摞。没声明过（或者新局刚清过）返回空数组
func piles_of(seat: String) -> Array:
	var v = piles.get(seat, [])
	return v if v is Array else []

# ---------- 消息封装 ----------

func _all(msg: Dictionary) -> Dictionary:
	return { "to": 0, "msg": msg }

## 一条落地结果 → 一条广播。**seq 自增和快照都在这里**，五个调用点
## （意图落地、装弹、逐组产出、收尾、开新回合）一个都不许自己拼。
##
## 为什么收成一个函数：快照是客户端唯一的状态来源（见 Protocol.applied），
## 漏一处的症状是「客户端某一步之后画面就停在上一步」——
## 比如只有 produce 漏了，那客户端的结算演出全是照旧局面演的，
## 而且**不报错**。五个 `Protocol.applied(r, seq)` 散着写，
## 将来加第六个阶段推进的人不会知道还要带快照
func _applied(r: Dictionary) -> Dictionary:
	seq += 1
	return _all(Protocol.applied(r, seq, snapshot()))

func _to(peer: int, msg: Dictionary) -> Dictionary:
	return { "to": peer, "msg": msg }

## 客户端要复现「服务器现在是什么样」需要的全部东西。
##
## 比 StateCodec.snapshot 多一个 pools：点数池是**裁决器的成员**不是状态的字段
## （见 engine/intent_apply.gd 的 pools_snapshot）。少了它，客户端装弹之后
## pool_empty() 当场为真，攻击回合被整段跳过而不报错。
##
## 为什么 seated 和 applied 走同一个函数：它们的收方是同一段代码
## （NetTransport._adopt）。分开拼的话「重连时池子是空的」会成为一个
## 只在攻击阶段中途掉线才复现的 bug —— 那是最难被人碰上、
## 也最难在测试里想到要造的局面
func snapshot() -> Dictionary:
	var snap: Dictionary = StateCodec.snapshot(state)
	snap["pools"] = applier.pools_snapshot()
	return snap

## 入座后发给这一位的 seated。快照包含 StateCodec 状态及裁决器的攻击池。
func seated_msg(seat: String) -> Dictionary:
	var msg := Protocol.seated(seat, GameState.opponent(seat),
		snapshot(), str(tokens[seat]))
	if started(): msg["recovery"] = recovery_checkpoint()
	return msg

func peers() -> Array:
	var out: Array = []
	for s in SEATS:
		var p := int(occupants[s])
		if p != 0:
			out.append(p)
	return out
