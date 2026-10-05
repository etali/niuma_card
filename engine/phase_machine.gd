# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name PhaseMachine
extends RefCounted

## 「现在轮到谁、能做什么」的唯一权威（net/server.gd、net/room.gd 与 engine/phase_machine.gd的前提）
##
## 为什么必须单独一份：今天这件事只由 `board.input_locked` 和
## `scenes/main.gd` 里的 `if phase != PHASE_ACTION or _actor != my_seat` 拦着 ——
## 那是**表现层**在拦。联网之后对手是另一个进程，它不受我这边的按钮禁用约束，
## 一个改过的客户端可以在对方回合里发 buy。
##
## 但也不能把阶段塞进 IntentApply 就算完：那样单机局的 `_drive_bot_action`
## （以服务器身份提交对手的意图）会被自己的阶段判定拦掉。所以分层是
##   IntentApply  = 这一步**合不合规则**（钱够不够、卡是不是你的）
##   PhaseMachine = 这一步**轮不轮到你**（次序）
## 服务器两道都过，单机局的界面读同一份次序来决定按钮亮不亮 ——
## 一份次序，两处读，不是两套判定。
##
## 阶段名和 scenes/main.gd 的 PHASE_* 逐字一致（那边改成引用这里的常量），
## 两处各写一套字符串就会出现「服务器说 attack、界面认 attacking」

const ACTION := "action"       ## 行动阶段：买卡 / 典当 / 组卡，先后手轮流
const ATTACK := "attack"       ## 攻击阶段：装弹 + 点选，先后手各一轮
const SETTLING := "settling"   ## 产出结算（没有玩家输入）
const OVER := "over"

## 每个阶段里，**当前行动方**发得起的客户端操作。
## 是白名单：以后加操作忘了登记只会「发不出去」，不会「能在对方回合里做」
const ALLOWED := {
	ACTION: [Intent.OP_BUY, Intent.OP_PAWN, Intent.OP_COMBO, Intent.OP_ACTION_DONE],
	ATTACK: [Intent.OP_ATTACK, Intent.OP_ATTACK_DONE],
	SETTLING: [],
	OVER: [],
}

var state: GameState
var phase := ACTION
## 当前行动方。ACTION 阶段是买卡的那个人，ATTACK 阶段是正在点选的那个人
var actor := GameState.PLAYER
## 本阶段已经收手的座位。ACTION 用它判断「双方都行动完了吗」
var _done: Dictionary = {}

func _init(s: GameState) -> void:
	state = s
	reset_for_round()

## 回合开始：进行动阶段，先手方先动。
## 先手取 state.action_first()（引擎的量，不是这里另存一份）——
## 抽卡先手和行动先手是反的，两处各算一次必然有一处算错
func reset_for_round() -> void:
	phase = ACTION
	actor = state.action_first()
	_done.clear()

## 接管一份别人的次序（主机易位用，scenes/main.gd 的 _take_over_host）。
##
## 只收 phase 和 actor 两个量，**`_done` 是推出来的不是传过来的**。
## 这不是偷懒 —— 它真的能推，而且推得出的那份就是唯一那份：
##
##   mark_done 一置某座就**立刻**把 actor 挪到对面（ACTION 那支的
##   `actor = foe`），所以「actor 停在谁身上」和「谁已经收手」是一一对应的：
##     actor == 先手 → 谁都还没收手（先手收手的话 actor 早就是后手了）
##     actor == 后手 → 先手收过手了，且仅先手
##   ATTACK 同构（next_attacker 换手的前提就是 mark_done 过第一位）
##   SETTLING / OVER 没有 actor，_done 在那两个阶段也没有读者
##
## 于是协议不用动。**要动的话代价是 Protocol.VERSION 再跳一版**
## （net/protocol.gd 的兼容性边界：消息形状变更需更新版本），而跳版会把所有旧客户端拒在门外 ——
## 为一个推得出来的量付这个代价不值。反过来说，哪天 mark_done 改成
## 「收手了但 actor 不动」，这个函数**必须跟着改**：那时候两者才真的独立了
func adopt(p: String, who: String) -> void:
	phase = p
	actor = who
	_done.clear()
	if (p == ACTION or p == ATTACK) and who != "":
		var order: Array = state.action_order()
		if order.size() == 2 and who == str(order[1]):
			_done[str(order[0])] = true

# ---------- 判定 ----------

## 这个座位现在发得起这条意图吗。返回 {} = 可以，否则 {code, reason}。
##
## 只判次序，不判规则 —— 钱够不够是 IntentApply 的事（见文件头分层）
func check(seat: String, op: String) -> Dictionary:
	if state.winner != "":
		return Intent.err("game_over", "这局已经结束了")
	if not Intent.is_client_op(op):
		return Intent.err("not_client_op", "阶段推进不由客户端发起")
	# 认输**不受次序管**。它上面那两道还是要过（结束了就认不了、
	# 而且它得是个客户端操作），下面那三道一道都不适用：
	#
	#   ALLOWED  —— 认输在哪个阶段都成立。登记进四个阶段的白名单也能通，
	#     但那读起来像「认输是一种行动」，而它恰恰是**放弃**行动
	#   actor    —— 对手行动时最想认输（我这半边正干等着）。拦掉的话
	#     玩家得先等对面走完一轮才认得了，而他可能压根不在了
	#   _done    —— 已经收手了也能认。收手是「这一阶段我没别的要做」，
	#     不是「我这一回合不许再有别的想法」
	#
	# 换句话说：认输不推进次序，它把次序整个作废（IntentApply 那边落地 winner
	# 之后，PhaseMachine.check 开头那道 game_over 会拦下**所有**后续意图）
	if op == Intent.OP_RESIGN:
		return {}
	var allowed: Array = ALLOWED.get(phase, [])
	if not allowed.has(op):
		return Intent.err("wrong_phase", "%s 阶段不能做这个（%s）" % [label(phase), op])
	if seat != actor:
		return Intent.err("not_your_turn", "现在轮到 %s 行动" % actor)
	if _done.get(seat, false):
		return Intent.err("already_done", "你这一阶段已经收手了")
	return {}

# ---------- 推进 ----------

## 某座位在本阶段收手。返回 true 表示**这一阶段结束了**（双方都收手），
## 调用方（服务器 / 场景层）据此推进到下一阶段。
##
## 不在这里自动跳阶段：进攻击阶段要先装弹、要演出，那些有副作用，
## 得由驱动方按自己的节奏做。这里只回答「够不够两个人都完事了」
func mark_done(seat: String) -> bool:
	_done[seat] = true
	if phase == ACTION:
		# 行动阶段是轮流的：先手收手 → 换后手，两个都收手 → 阶段结束
		var foe := GameState.opponent(seat)
		if _done.get(foe, false):
			return true
		actor = foe
		return false
	return true

func is_done(seat: String) -> bool:
	return _done.get(seat, false)

## 进攻击阶段，由 first 先攻
func begin_attack() -> void:
	phase = ATTACK
	_done.clear()
	actor = state.action_order()[0]

## 攻击阶段换手。返回 false 表示两边都打完了
func next_attacker() -> bool:
	var order: Array = state.action_order()
	if actor == order[0] and not _done.get(order[1], false):
		actor = order[1]
		return true
	return false

func begin_settling() -> void:
	phase = SETTLING
	actor = ""
	_done.clear()

func begin_over() -> void:
	phase = OVER
	actor = ""

# ---------- 展示 ----------

static func label(p: String) -> String:
	match p:
		ACTION: return "行动阶段"
		ATTACK: return "攻击阶段"
		SETTLING: return "结算中"
		OVER: return "终局"
	return p
