# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 认输（左下角那个按钮）
##
## 用户的原话是两句：「增加『认输』按钮，放在左下角」+「联网模式下，认输后，
## 弹出结算界面，可以选择进行下一局，双方都确认，则开启下一局」。
## 后面那半句**不是新东西** —— 双方确认开下一局就是已经落地的 rematch 协议
## （net/room.gd 的 rematch 投票与重开，tests/test_rematch.gd 钉着）。所以这一条判据要钉的是「认输
## 能不能真的把局面推到那个已有的终局面板上」，不是把 rematch 再验一遍。
##
## 五段，各钉一层：
##   T1 引擎：GameState.resign 定谁赢、战报和面板文案的视角分工
##   T2 裁决器：认输是客户端操作（能发），但不能替对手认，也不能认第二次
##   T3 场景层（单机）：按钮要两下才认，第一下只改字
##   T4 真 socket：**我**认输 → 对手那份状态里判他赢 → 双方投票开下一局
##   T5 真 socket：**他**认输 → 我这边自己弹出结算界面
##
## T4 和 T5 是两个方向，不能只留一个：面板在两侧是**两段不同的代码**弹的 ——
## 我认输时是 _on_resign_pressed 自己调 _show_game_over，他认输时靠
## _on_intent_applied 那个 OP_RESIGN 分支（_render_foe_resign）。
## 而 T4 一次都跑不到那条分支：is_foe_client_op 比的是 seat == foe_seat，
## T4 里认输的座位是我自己的
##
## 为什么这两节一定要过网线（不能像 T3 那样直接调 _on_resign_pressed）：
## 认输这条意图的收信人是**对手**。我这边的面板是我自己弹的，
## 就算 OP_RESIGN 一个字节都没发出去、就算 Intent.CLIENT_OPS 漏登记它，
## T3 照样全绿 —— 我这半边看不出区别。对手那边收不到才是症状，
## 而那要走 Server.poll → dispatch → _on_intent_applied 整条路
## （和 test_rematch T6 是同一个理由：字段白名单的洞只有过 decode 才看得见）
##
## 变异登记在 tools/mutate_check.py 第 23 节，七条，都实跑确认过红：
##   a. CLIENT_OPS 去掉 OP_RESIGN     → T2「认输是客户端操作」
##   b. winner = who（认输的那个赢）  → T1「认输的是**输**的那个」
##   c. 去掉 PhaseMachine 那道豁免    → T5「他那条认输走通了」
##      这条是实跑才发现的：光看 CLIENT_OPS 是通的，ALLOWED 那张
##      per-phase 白名单会把认输按 wrong_phase 拒掉
##   d. 第一下就发意图              → T3「第一下不认输」
##   e. 去掉 _render_foe_resign 那支 → T5「他认输之后我这边的结算界面自己弹出来了」
##   f. 战报硬编成一句话            → T1「那一行带着座位参数」
##   g. win_reason 写成带视角的      → T1「win_reason 视角中立」

const PORT_BASE := 47420
const A := GameState.PLAYER
const B := GameState.BOT

## 协程里要翻的标志位得是成员变量：lambda 捕获局部量是**按值**的
var _flag := false

func _initialize() -> void:
	print("=== 认输测试 ===")
	CardDB.ensure_loaded()
	_t1_engine_decides_winner()
	_t2_adjudicator_guards()
	await _t3_two_presses()
	await _t4_socket_foe_sees_panel_then_rematch()
	await _t5_socket_he_resigns_i_see_it()
	net_stop()
	finish()

# ---------- T1 引擎 ----------

func _t1_engine_decides_winner() -> void:
	print("\n-- T1 引擎判胜负 --")
	var s := GameState.new()
	s.new_game()
	var log_before: int = s.log.size()

	var r: Dictionary = s.resign(A)
	check(bool(r.get("ok", false)), "A 认输这一步成了（%s）" % str(r.get("reason", "")))
	check(s.winner == B,
		"认输的是**输**的那个（A 认输 → winner=%s）：写成 who 的话点了认输反而赢了"
			% s.winner)
	check(str(r.get("winner", "")) == B, "返回值里也带着赢家（%s）" % str(r.get("winner", "")))

	# 战报要说清是谁认的 —— 认输不动任何资源，前后两行之间看不出发生过什么
	check(s.log.size() == log_before + 1, "写了一行战报（%d → %d）"
		% [log_before, s.log.size()])
	var last: Dictionary = s.log[s.log.size() - 1]
	check((last.get("args", []) as Array).size() == 1,
		"那一行带着座位参数 —— 硬编成「对手认输了」的话，"
		+ "认输的人自己看到的也是这句（args=%s）" % str(last.get("args", [])))
	# 同一行日志，两个视角念出来不一样。这是 render_entry 的活，这里只验它真的分岔
	var seen_a := s.render_entry(last, A)
	var seen_b := s.render_entry(last, B)
	check(seen_a != seen_b,
		"两个视角念出来不同（A 看「%s」/ B 看「%s」）" % [seen_a, seen_b])
	check(seen_a.contains("你"), "认输的那位看到的是「你」（%s）" % seen_a)
	check(seen_b.contains("对手"), "另一位看到的是「对手」（%s）" % seen_b)

	# win_reason 是裸字符串，state_codec 原样传给对端，谁都不会再翻译它一次
	check(not s.win_reason.contains("你") and not s.win_reason.contains("对手"),
		"win_reason 视角中立（%s）—— 带「你」的话对端读到的是反的" % s.win_reason)
	check(s.win_reason != "", "但它不是空的：终局面板那行原因要显示它")

	# 认第二次：防重复战报，同 check_victory 开头那道
	var again: Dictionary = s.resign(A)
	check(not bool(again.get("ok", true)), "已经结束了就不能再认")
	check(s.winner == B, "而且赢家没被第二次认输改掉（%s）" % s.winner)
	check(s.log.size() == log_before + 1, "也没多写一行战报（%d）" % s.log.size())

	# 不存在的座位。**要另起一份**：上面那份 winner 已经落了，
	# 而 resign 里 winner 那道拦在座位之前，拿它试的话报的是 game_over，
	# 「座位不存在」这条压根没走到
	var s2 := GameState.new()
	s2.new_game()
	var bad: Dictionary = s2.resign("nobody")
	check(not bool(bad.get("ok", true)), "不存在的座位认不了输")
	check(str(bad.get("code", "")) == "bad_seat",
		"拒的码是 bad_seat（实为 %s）" % str(bad.get("code", "")))
	check(s2.winner == "", "而且没把谁判成赢家（%s）" % s2.winner)

# ---------- T2 裁决器 ----------

## 认输走的是同一条管道，所以它要过同一套校验。这一节钉三件：
## 能发（不被 not_client_op 拒）、不能替对手认（wrong_seat）、
## 结束之后认不了（game_over 那道护栏，它管所有操作）
func _t2_adjudicator_guards() -> void:
	print("\n-- T2 裁决器 --")
	check(Intent.is_client_op(Intent.OP_RESIGN),
		"认输是客户端操作 —— 不登记的话服务器按「客户端想推进阶段」拒掉，"
		+ "而认输本来就是玩家的决定")
	check(Intent.SEAT_OPS.has(Intent.OP_RESIGN),
		"而且是带座位的操作：不登记就跳过「有这个座位吗」那道校验")
	check(Intent.REQUIRED_FIELDS.has(Intent.OP_RESIGN),
		"登记进 REQUIRED_FIELDS —— from_dict 拿它当**操作码白名单**，"
		+ "漏了就是整条 bad_op（参见 net/protocol.gd 的 REQUIRED 类型白名单）")

	# 过一趟编解码：联网时认输是文本进文本出的
	var enc := Intent.encode(Intent.resign(A))
	var dec: Dictionary = Intent.decode(enc)
	if need(bool(dec.get("ok", false)), "认输意图过得了编解码（%s）"
			% str(dec.get("reason", ""))):
		check(str((dec["intent"] as Dictionary)["op"]) == Intent.OP_RESIGN,
			"解出来还是 resign")
		check(str((dec["intent"] as Dictionary)["seat"]) == A,
			"座位也在（seat 是**认输的那个**，不是赢的那个："
			+ "写成赢家的话这条意图自称是对手发的，撞 wrong_seat）")

	var s := GameState.new()
	s.new_game()
	var ap := IntentApply.new(s)

	# 冒充：from_seat 是连接自带的身份，seat 是包里自称的
	var fake: Dictionary = ap.apply(Intent.resign(B), A)
	check(not bool(fake.get("ok", true)), "不能替对手认输")
	check(str(fake.get("code", "")) == "wrong_seat",
		"而且拒的码是 wrong_seat（实为 %s）—— 替对手认输 = 单方面宣布自己赢了"
			% str(fake.get("code", "")))
	check(s.winner == "", "被拒之后局面没动（winner=%s）" % s.winner)

	# 真认
	var ok: Dictionary = ap.apply(Intent.resign(A), A)
	check(bool(ok.get("ok", false)), "自己认自己的输走得通（%s）"
		% str(ok.get("reason", "")))
	check(str(ok.get("op", "")) == Intent.OP_RESIGN, "结果里带着 op（对手侧靠它分支）")
	check(str(ok.get("seat", "")) == A,
		"也带着座位 —— 对手侧的 is_foe_client_op 拿它认「这是他做的」")
	check(s.winner == B, "赢家落地了（%s）" % s.winner)

	# 结束之后：那道 game_over 护栏管所有操作，认输也一样
	var late: Dictionary = ap.apply(Intent.resign(B), B)
	check(not bool(late.get("ok", true)), "已经结束了，另一位也认不了")
	check(str(late.get("code", "")) == "game_over",
		"拒的码是 game_over（实为 %s）" % str(late.get("code", "")))

# ---------- T3 场景层：两下才认 ----------

## 单机局，不开服务器。钉的是按钮本身的行为：
## 第一下**不认**（只改字），第二下才真的把局面推到终局。
##
## 为什么值一条判据：这个按钮和联网入口同在左下角、同样 150×44，
## 而认输没有撤回。一下就认的话手滑一次整局没了
func _t3_two_presses() -> void:
	print("\n-- T3 两下才认 --")
	var main: Node = await boot_main()
	if not need(main.btn_resign != null, "左下角有这个按钮"):
		main.queue_free()
		return
	check(main.btn_resign.text == main.TXT_RESIGN,
		"按钮上写着「%s」（实为「%s」）" % [main.TXT_RESIGN, main.btn_resign.text])
	# 「放在左下角」：锚点和 btn_net 同一套，位置在它上面
	check(main.btn_resign.anchor_left == 0.0 and main.btn_resign.anchor_top == 1.0,
		"锚在左下角（anchor=%s,%s）" % [main.btn_resign.anchor_left,
			main.btn_resign.anchor_top])
	check(main.btn_resign.position.y < main.btn_net.position.y,
		"摞在联网入口上面（认输 y=%s / 联网 y=%s）"
			% [main.btn_resign.position.y, main.btn_net.position.y])
	check(not main.btn_resign.disabled, "局中点得动")

	# 第一下：只改字，**不认**
	main._on_resign_pressed()
	await physics_frame
	check(main.state.winner == "",
		"第一下不认输（winner=%s）—— 一下就认的话手滑一次整局没了" % main.state.winner)
	check(main._resign_armed, "但它记住了「点过一下」")
	check(main.btn_resign.text == main.TXT_RESIGN_SURE,
		"按钮改成了「%s」（实为「%s」）：改完的按钮自己就是那个确认框"
			% [main.TXT_RESIGN_SURE, main.btn_resign.text])
	check(main.phase != main.PHASE_OVER, "而且没进终局（%s）" % main.phase)

	# 第二下：真认
	await main._on_resign_pressed()
	await settle()
	check(main.state.winner == main.foe_seat,
		"第二下认了，对手判胜（winner=%s / 我坐 %s）" % [main.state.winner, main.my_seat])
	check(main.phase == main.PHASE_OVER, "进终局了（%s）" % main.phase)
	check(main.game_over_panel != null and is_instance_valid(main.game_over_panel),
		"结算界面弹出来了")
	check(main.btn_resign.disabled,
		"按钮跟着灰掉 —— 点得动却什么都不发生的按钮，和「卡住了」分不开")
	check(main.btn_resign.text == main.TXT_RESIGN,
		"字也回到「%s」（实为「%s」）" % [main.TXT_RESIGN, main.btn_resign.text])

	# 单机局的终局面板上不该有 rematch 那一行：那需要对手也点
	check(main._rematch_btn == null, "单机局没有「再来一局」那个按钮（它要对手也投票）")

	# 复位要把按钮放回来。上一局就是认输结束的话，不放的话新局认不了输
	main._reset_session_flags()
	check(not main.btn_resign.disabled, "重开之后按钮又点得动了")
	check(not main._resign_armed, "而且不是停在「已经点过一下」的状态")

	main.queue_free()
	await physics_frame

# ---------- T4 真 socket：对手看得见，然后双方开下一局 ----------

## 这一节是整条判据的重心，也是唯一能抓住「认输没发出去」的一节。
##
## 场景坐 A 座，B 座挂一条光秃秃的连接当对手。**观察点在 B 那一侧**：
## A 点了认输之后，B 那份状态里的 winner 要变、而且要变成 A 的对手（也就是 B 自己）。
## 我这边的面板是我自己弹的，所以我这边全绿证明不了任何事
##
## 然后接上 rematch：这是用户那句「可以选择进行下一局，双方都确认，则开启下一局」。
## 它本来就通（test_rematch T6），这里要验的是**认输结束的局也算「结束」**——
## room.handle_rematch 那道 `state.winner == ""` 拦看的是同一个字段，
## 认输落地的 winner 和冲线落地的 winner 必须一样算数
func _t4_socket_foe_sees_panel_then_rematch() -> void:
	print("\n-- T4 过网线：对手看得见 --")
	var got: Array = await _seated_scene("RSGN", 20260829)
	if got.is_empty():
		return
	var main: Node = got[0]
	var b: NetTransport = got[2]
	var a: NetTransport = main._net
	var room := _server_room()
	if not need(room != null, "服务器开出了房间"):
		main.queue_free()
		return

	check(main.state.winner == "" and b.state().winner == "",
		"开局两边都没有胜负（我 %s / 他 %s）"
			% [str(main.state.winner), str(b.state().winner)])
	var mine: String = main.my_seat
	var his: String = main.foe_seat

	# B 那一侧要能看到「对手认输了」这条落地结果。用 applied 信号数，
	# 而不是只看 winner：winner 是快照带的，就算 OP_RESIGN 那个分支不存在也会变
	var his_ops: Array = []
	b.applied.connect(func(r): his_ops.append(str((r as Dictionary).get("op", ""))))

	# 认输：走真按钮，两下。第一下只改字
	main._on_resign_pressed()
	await net_pump([a, b], 4)
	check(main.state.winner == "", "第一下还没认（winner=%s）" % main.state.winner)

	# 第二下真发。submit 是协程且只泵自己，服务器得有人摇
	_flag = false
	net_pump_until([a, b], func(): return _flag)
	await main._on_resign_pressed()
	_flag = true
	await net_pump([a, b], 6)

	# 服务器那份先落地 —— 它是权威
	check(room.state.winner == his,
		"服务器判他赢（winner=%s / 应为 %s）：认输的是我" % [str(room.state.winner), his])

	# 然后是**对手那一侧**。这三条是这一节存在的理由
	if not await net_until([a, b], func(): return b.state().winner != ""):
		check(false, "对手那份状态收到了胜负（winner=%s）" % str(b.state().winner))
		main.queue_free()
		return
	check(b.state().winner == b.my_seat,
		"他那份写的是他自己赢（winner=%s / 他坐 %s）" % [str(b.state().winner), b.my_seat])
	check(his_ops.has(Intent.OP_RESIGN),
		"而且他收到的是一条 resign（收到的是 %s）—— CLIENT_OPS 漏登记的话"
			% str(his_ops)
		+ "服务器按 not_client_op 拒掉，我这边面板照弹，两边各看一局")
	check(b.state().win_reason != "", "原因那行也传过去了（%s）" % b.state().win_reason)
	check(not b.state().win_reason.contains("你"),
		"而且它视角中立（%s）—— 带「你」的话赢的那位读到的是反的"
			% b.state().win_reason)

	# 我这边：结算界面 + rematch 那一行（联网局才有）
	check(main.phase == main.PHASE_OVER, "我这边进终局了（%s）" % main.phase)
	check(main.game_over_panel != null and is_instance_valid(main.game_over_panel),
		"结算界面弹出来了")
	if not need(main._rematch_btn != null, "面板上有「再来一局」（联网局才有这一行）"):
		main.queue_free()
		return
	check(main._rematch_btn.text == "再来一局",
		"按钮上写着「再来一局」（实为「%s」）" % main._rematch_btn.text)

	# 「双方都确认，则开启下一局」。我这边点按钮，他那边走 request_rematch
	var round_before: int = room.state.round_num
	room.state.round_num = 4   # 推离第 1 回合，否则下面拿 1 和 1 比
	# 收新局通知要用**数组**装，不能用 `var started := false` 那种局部 bool：
	# GDScript 的 lambda 捕获局部量是按值的，赋值改的是 lambda 自己那份，
	# 外面永远是 false。症状是「信号明明发了，判据说没收到」
	var started: Array = []
	main._rematch_btn.pressed.emit()
	await net_pump([a, b], 6)
	check(room.voted_seats().size() == 1,
		"我这一票记下了（%s）—— 认输结束的局也算「结束」，"
			% str(room.voted_seats())
		+ "不算的话 handle_rematch 那道 not_over 会把票拒掉")
	check(room.state.winner != "", "一票之后还是终局（没被单方面重开）")

	b.rematch_started.connect(func(m, f): started.append([m, f]))
	b.request_rematch()
	if not await net_until([a, b], func(): return not started.is_empty()):
		check(false, "两票齐了，他那边收到了新局通知")
		main.queue_free()
		return
	check(str(started[0][0]) == b.my_seat,
		"双方都确认 → 开了下一局（他那条写的是他自己的座位 %s）" % str(started[0][0]))
	check(room.state.winner == "" and room.state.round_num == 1,
		"新局是干净的（第 %d 回合 ← 上一局第 4，winner=%s）"
			% [room.state.round_num, str(room.state.winner)])
	check(round_before >= 1, "（上一局起始回合 %d，只为让上面那句不是拿 1 比 1）"
		% round_before)

	# 新局里认输按钮要活过来 —— 上一局就是认输结束的，不复位的话新局认不了输
	await net_until([a, b], func(): return not main.btn_resign.disabled)
	check(not main.btn_resign.disabled,
		"新局里认输按钮又点得动了 —— 不复位的话按钮上还写着上一局那句「%s」"
			% main.TXT_RESIGN_SURE)
	check(main.btn_resign.text == main.TXT_RESIGN,
		"字也回到「%s」（实为「%s」）" % [main.TXT_RESIGN, main.btn_resign.text])
	check(main.state.winner == "", "我这份也是新局（winner=%s）" % str(main.state.winner))

	a.close()
	b.close()
	await net_pump([a, b], 4)
	main.queue_free()
	await physics_frame

# ---------- T5 反方向：**他**认输，我这边要弹面板 ----------

## T4 是「我认输」，观察点在对手那一侧。这一节是反的：**他**认输，
## 观察点在我这个场景里。两条都要，因为走的是两段完全不同的代码 ——
## 我认输时面板是 _on_resign_pressed 自己调 _show_game_over 弹的；
## 他认输时得靠 _on_intent_applied 里那个 OP_RESIGN 分支
## （_render_foe_resign），而那条分支在 T4 里一次都没跑到：
## is_foe_client_op 比的是 seat == foe_seat，T4 里认输的座位是我自己的
##
## 而且这一侧的漏做是**静默**的：他认了输，服务器落地了，我这份状态也跟着
## 变成了终局（快照是权威那份的副本），但屏幕上什么都不发生 ——
## 输入还开着、按钮还亮着，而我发出去的每一条意图都会被 game_over 拒掉。
## 玩家看到的是「牌能拖，但一步也走不了，也没人告诉我为什么」
##
## 为什么要**落在我的行动阶段**认：这是 _render_foe_resign 自己弹面板
## （而不是像典当冲线那样交给驱动方）的唯一理由。我的行动阶段里没有任何
## 循环在盯 state.winner —— 代码就停在等我按按钮那一步。交给驱动方的话，
## 症状是「对手认输了，我这边毫无反应，直到我点了完成行动才突然弹出面板」
func _t5_socket_he_resigns_i_see_it() -> void:
	print("\n-- T5 反方向：他认输 --")
	var got: Array = await _seated_scene("RSG5", 20260829)
	if got.is_empty():
		return
	var main: Node = got[0]
	var b: NetTransport = got[2]
	var a: NetTransport = main._net
	var room := _server_room()
	if not need(room != null, "服务器开出了房间"):
		main.queue_free()
		return

	# 前提：现在是**我的**行动阶段，输入开着。这一条不是判据是前提 ——
	# 不成立的话下面那句「面板自己弹出来了」钉的是别的事
	if not await net_until([a, b], func(): return main.phase == PhaseMachine.ACTION):
		check(false, "开局进了行动阶段（实为 %s）" % str(main.phase))
		main.queue_free()
		return
	check(main.game_over_panel == null, "此刻还没有终局面板（前提）")
	check(main.state.winner == "", "此刻也还没有胜负（前提）")

	# 他认输。submit 是协程且只泵自己，服务器得有人摇
	_flag = false
	net_pump_until([a, b], func(): return _flag)
	var r: Dictionary = await b.submit(Intent.resign(b.my_seat))
	_flag = true
	check(bool(r.get("ok", false)), "他那条认输走通了（%s）" % str(r.get("reason", "")))

	# 观察点全在我这个场景里
	if not await net_until([a, b], func(): return main.game_over_panel != null):
		check(false, "他认输之后我这边的结算界面自己弹出来了（winner=%s / phase=%s）"
			% [str(main.state.winner), str(main.phase)])
		main.queue_free()
		return
	check(is_instance_valid(main.game_over_panel),
		"他认输之后我这边的结算界面自己弹出来了 —— 没有这一条的话"
		+ "屏幕上什么都不发生，而我发出去的每条意图都被 game_over 拒掉")
	check(main.phase == main.PHASE_OVER, "我这边也进了终局（%s）" % main.phase)
	check(main.state.winner == main.my_seat,
		"而且判的是我赢（winner=%s / 我坐 %s）：他认的输" % [
			str(main.state.winner), main.my_seat])
	check(main.board.input_locked,
		"输入锁上了 —— 面板背后的牌不该还能拖")
	check(main.btn_resign.disabled, "认输按钮也灰了（局已经结束了）")

	a.close()
	b.close()
	await net_pump([a, b], 4)
	main.queue_free()
	await physics_frame

# ---------- 真服务器的小工具（同 test_foe_offline，端口段错开） ----------
func _server_room() -> NetRoom:
	for code in _srv.rooms:
		return _srv.rooms[code]
	return null
## 一份真场景坐 A 座 + 一条光秃秃的连接替对手收发（同 test_foe_offline）
func _seated_scene(room_code := "TEST", seed_value := 0) -> Array:
	return await net_seated_scene(PORT_BASE, seed_value, room_code)
