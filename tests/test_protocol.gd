# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 协议信封本身（net/protocol.gd）
##
## 这条判据存在的理由是一个**已经发生过**的 bug：`from_dict` 是个逐类型的
## 字段白名单，rematch_state / rematch_start 登记进了 REQUIRED、构造函数也写了，
## 就是漏了 `match` 里那两个 case —— 于是 decode 出来的 msg 里
## **连 votes 这个键都不存在**，不报错、不告警。症状出现在两跳之外
## （面板停在「等对手…」），而且发生在信号回调里，连测试都不失败
## （memory: decode-whitelist-drops-payload / callback-script-error-doesnt-fail-test）
##
## 所以 T1 的写法是刻意的：**样本表从 REQUIRED 自己长出来**，不是我手抄一份类型清单。
## 手抄的清单和被测代码是两份，将来加第 14 个消息类型时我会漏掉同一处两次
## （REQUIRED 和 match 是两处，这就是当初漏的形状）；从 REQUIRED 遍历的话，
## 新类型没进 SAMPLES 就直接报「这个类型没有样本」，进了而 match 漏了就报丢字段。
## 判据因此对**还没写出来的类型**也有效 —— 这是它和 test_rematch 里
## 那几条针对具体字段的判据的分工
##
## 分节：
##   T1 每个登记过的类型：构造 → encode → decode，一个字段都不许少
##   T2 形状校验：坏 JSON / 不是对象 / 未知类型 / 缺字段，四种都要**拒**而不是崩
##   T3 uid 掰回 int（JSON 的数字全是 double，float 键一律查不中）
##   T4 客户端白名单：能发的只有那四条
##   T5 房号归一化与校验
##   T6 关闭帧的原因截断
##
## 变异提示（**都实跑确认过红**，并登记进 tools/mutate_check.py）：
##   1. from_dict 里去掉 `for f in REQUIRED[t]` 那圈缺字段校验
##      → T2「缺字段要拒」红
##   2. from_dict 开头的 `REQUIRED.has(t)` 改成 `true` → T2「未知类型要拒」红
##   3. decode 里把 `j.parse(text) != OK` 改成永假（但**保留 parse 调用**）
##      → T2「坏 JSON 的原因里带了解析器给的位置」红。
##      注意不能把整句换掉：连 parse 都不跑的话每条消息都解不开（红 28 条），
##      那测的不是这道拦。而保留 parse 时下游 `is Dictionary` 会兜住，
##      所以唯一的观察点是 reason 那句话 —— 见 T2 里那段注释
##   4. restore_uids 里去掉 UID_LIST_FIELDS 那圈 → T3「uids 掰回了 int」红
##   5. is_client_msg 改成恒 true → T4「服务器消息不许客户端发」红
##   （REMATCH_STATE / REMATCH_START 那两个 match 分支的变异登记在
##     test_rematch.gd 名下，见那个文件头 9/10 —— T1 也抓得住，
##     但一条变异只记一个关键字，取先跑到的那个）

## 每个类型的样本。**键必须和 REQUIRED 的键完全对上** —— T1 头一条就是查这个。
## 值取「过一趟 JSON 会变形」的那种：uid 用整数（会变 float）、
## 座位名用真常量（收方要拿它和 my_seat 做 == 比较）
const SEAT_A := "player"
const SEAT_B := "ai"

## 使用真实快照验证递归结构；协议负责在任何客户端状态被替换之前拒绝坏字段。
static func _fake_snapshot() -> Dictionary:
	var state := GameState.new()
	state.set_seed(7)
	state.new_game()
	state.round_num = 7
	return StateCodec.snapshot(state)


func _initialize() -> void:
	print("=== 协议信封（net/protocol.gd）测试 ===")
	_t1_every_type_survives_a_roundtrip()
	_t2_shape_checks_reject_not_crash()
	_t3_uids_come_back_as_int()
	_t4_client_whitelist()
	_t5_room_codes()
	_t6_close_reason_clip()
	_t7_pile_anchor()
	finish()


## T1：每个登记过的类型都要能原样过一趟 encode/decode。
## 这一节是那个白名单洞的通用判据
func _t1_every_type_survives_a_roundtrip() -> void:
	print("\n--- T1 每个类型的往返 ---")
	var snap := _fake_snapshot()
	# 用构造函数造，不是手写字典：这样「构造函数少写一个字段」也在判据里
	var samples := {
		Protocol.JOIN: Protocol.join("ab12", "deadbeef", "tok-1"),
		Protocol.INTENT: Protocol.intent(Intent.buy(SEAT_A, 2)),
		Protocol.DRAG: Protocol.drag(9, Protocol.DRAG_MOVE, [60, 61], 0.25, 0.75),
		# 两摞而不是一摞：嵌一层的数组过 JSON 之后每个 uid 都是 double，
		# 而收方拿它们当字典键用（见 Protocol 里 PILES/FOE_PILES 那段）。
		# 一摞的样本测不出「只掰了第一摞」这种错
		Protocol.PILES: Protocol.piles([[60, 61], [62]]),
		Protocol.REMATCH: Protocol.rematch(),
		Protocol.SEATED: Protocol.seated(SEAT_A, SEAT_B, snap, "tok-2"),
		Protocol.APPLIED: Protocol.applied({ "ok": true, "op": Intent.OP_BUY, "new_uid": 60, "market_idx": 0, "removed_uids": [] }, 3, snap),
		Protocol.REJECTED: Protocol.rejected("short", "现金不足"),
		Protocol.FOE_DRAG: Protocol.foe_drag(
			Protocol.drag(9, Protocol.DRAG_PICKUP, [60], 0.5, 0.5)),
		Protocol.FOE_PILES: Protocol.foe_piles(Protocol.piles([[60, 61], [62]])),
		# 两摞，理由同 PILES 那条：uid 过 JSON 变 double，而收方拿它们查
		# main.entities（见 scenes/main.gd 的 on_my_piles）。一摞的样本测不出「只掰了第一摞」
		Protocol.MY_PILES: Protocol.my_piles([[60, 61], [62]]),
		Protocol.PHASE: Protocol.phase("action", SEAT_B),
		Protocol.FOE_LEFT: Protocol.foe_left(),
		Protocol.FOE_BACK: Protocol.foe_back(),
		Protocol.CLOSED: Protocol.closed(Protocol.CLOSE_ROOM_FULL, "房间满了"),
		Protocol.REMATCH_STATE: Protocol.rematch_state([SEAT_A]),
		Protocol.REMATCH_START: Protocol.rematch_start(SEAT_B, SEAT_A, snap),
		# 心跳（net/net_transport.gd 的心跳与超时处理）。at 取一个**大到超出 32 位**的数：
		# Time.get_ticks_msec() 在跑了几十天的机器上就是这个量级，
		# 而它过一趟 JSON 是 double —— 掰不回 int 的话 rtt 会算出个负数
		Protocol.PING: Protocol.ping(4294967496),
		Protocol.PONG: Protocol.pong(4294967496),
	}

	# 先查样本表自己是不是全的。少一个类型的话下面整圈就静默跳过它 ——
	# 那正是「判据看着绿，其实没测」的形状
	for t in Protocol.REQUIRED.keys():
		check(samples.has(t),
			"类型 %s 有样本 —— 没有的话它的往返一次都没跑过，"
				% str(t)
			+ "而 from_dict 的 match 漏了它是**静默丢载荷**")
	check(samples.size() == Protocol.REQUIRED.size(),
		"样本数和登记数一致（%d / %d）：多出来的是已经删掉的类型"
			% [samples.size(), Protocol.REQUIRED.size()])

	for t in Protocol.REQUIRED.keys():
		if not samples.has(t):
			continue
		var sent: Dictionary = samples[t]
		var got: Dictionary = Protocol.decode(Protocol.encode(sent))
		var ok := bool(got.get("ok", false))
		check(ok, "%s 过得去 decode（%s）" % [str(t), str(got.get("reason", ""))])
		if not ok:
			continue
		var msg: Dictionary = got["msg"]
		check(str(msg.get("t", "")) == str(t),
			"%s 的类型没变（实为 %s）" % [str(t), str(msg.get("t", ""))])
		# **核心那条**：发出去的键一个都不能在收方消失。
		# 白名单漏一个 case 的话，这里报的就是「少了 votes」而不是某处崩溃
		for f in sent.keys():
			check(msg.has(f),
				"%s 的字段 %s 活着回来了 —— from_dict 是字段白名单，"
					% [str(t), str(f)]
				+ "match 里漏了分支就把整个载荷静默丢掉")
		# 必填字段还要**值**也对得上（有键但被清成空的照样是错）
		for f in Protocol.REQUIRED[t]:
			if not msg.has(f):
				continue
			check(_same(sent[f], msg[f]),
				"%s 的 %s 值也没变（发 %s / 收 %s）"
					% [str(t), str(f), str(sent[f]), str(msg[f])])

	# 快照要**深**着回来：只判「有 snapshot 这个键」的话，
	# 把它换成 {} 的错测不出来 —— 而那个错的症状是「画面停在开局」
	var seated: Dictionary = Protocol.decode(
		Protocol.encode(Protocol.seated(SEAT_A, SEAT_B, snap, "t")))["msg"]
	var snap_back: Dictionary = seated["snapshot"]
	check(int(snap_back.get("round_num", 0)) == 7,
		"快照里层也回来了（round_num=%s）" % str(snap_back.get("round_num", "缺")))
	check((snap_back.get("players", {}) as Dictionary).has(SEAT_A),
		"快照里的座位键也回来了 —— 这一层 decode 不该看懂它，只该原样带过")


## 两个值过一趟 JSON 之后算不算「没变」。
## 数字要按值比（int 出去 float 回来是**预期**的，掰回 int 是 restore_uids 的活，
## 那由 T3 单独判），容器递归比
static func _same(a, b) -> bool:
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a.keys():
			if not b.has(k) or not _same(a[k], b[k]):
				return false
		return true
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	return a == b


## T2：形状不对要**拒包**，不是崩。
## 服务器上「收到读不懂的包」是家常事（版本不对、有人拿 curl 戳），
## 每来一个崩一次或者刷一屏回溯都不行
func _t2_shape_checks_reject_not_crash() -> void:
	print("\n--- T2 形状校验 ---")
	var bad := Protocol.decode("{ 这不是 JSON")
	check(not bool(bad.get("ok", true)), "坏 JSON 要拒")
	check(str(bad.get("code", "")) == "bad_json",
		"坏 JSON 的码是 bad_json（实为 %s）" % str(bad.get("code", "")))
	# 原因里要带**解析器给的那句话**，不能只是「不是一个 JSON 对象」。
	# 这条判据看着像在挑字眼，其实它是那道 parse 检查的**唯一**观察点：
	# 解析失败时 j.data 是 null，所以就算去掉 `j.parse() != OK` 那道拦，
	# 下一道 `is Dictionary` 照样会拒 —— 拒是拒了，可原因退化成
	# 「消息不是一个 JSON 对象」，而那句话对着一个手搓包毫无用处
	# （memory: equivalent-mutation-is-a-sixth-miss 说的就是这种下游兜住的形状）。
	# 服务器上「收到读不懂的包」是家常事，原因里有没有位置
	# 决定了排查要不要再去抓一次包
	var why := str(bad.get("reason", ""))
	check(why.contains("合法 JSON"),
		"坏 JSON 的原因说的是解析失败（实为「%s」）" % why)
	check(why.contains("行") or why.contains("字符") or why.contains("character"),
		"坏 JSON 的原因里带了解析器给的位置/说明（实为「%s」）—— " % why
		+ "少了它就得为一个手搓包再去开一遍抓包")

	check(not bool(Protocol.decode("[1,2,3]").get("ok", true)),
		"顶层是数组也要拒（JSON 合法但不是消息）")
	check(not bool(Protocol.decode('"just a string"').get("ok", true)),
		"顶层是字符串也要拒")

	var unknown := Protocol.decode(JSON.stringify({ "t": "no_such_type", "x": 1 }))
	check(not bool(unknown.get("ok", true)), "未知类型要拒")
	check(str(unknown.get("code", "")) == "bad_type",
		"未知类型的码是 bad_type（实为 %s）" % str(unknown.get("code", "")))

	# 缺字段：拿每个类型的必填清单逐个试，一样从 REQUIRED 长出来
	var missing_checked := 0
	for t in Protocol.REQUIRED.keys():
		var req: Array = Protocol.REQUIRED[t]
		if req.is_empty():
			continue  # rematch / foe_left / foe_back 没有必填字段，跳过是对的
		var d := { "t": t }
		# 只给第一个必填字段之外的（也就是**故意少**第一个）
		for i in range(1, req.size()):
			d[req[i]] = ""
		var r := Protocol.decode(JSON.stringify(d))
		check(not bool(r.get("ok", true)),
			"%s 少了必填字段 %s 要拒" % [str(t), str(req[0])])
		check(str(r.get("code", "")) == "missing_field",
			"%s 缺字段的码是 missing_field（实为 %s）"
				% [str(t), str(r.get("code", ""))])
		missing_checked += 1
	check(missing_checked >= 9,
		"缺字段这一圈真的跑过（%d 个类型有必填字段）—— " % missing_checked
		+ "REQUIRED 全空的话上面整圈是空转")

	# snapshot 不是对象：这条要单独判。一路传到 StateCodec.restore 的话，
	# 它在 d.get("players", {}) 上把整局清空 —— 空桌子，一条错都不报
	for t in [Protocol.SEATED, Protocol.REMATCH_START]:
		var r := Protocol.decode(JSON.stringify({
			"t": t, "my_seat": SEAT_A, "foe_seat": SEAT_B, "snapshot": "不是对象" }))
		check(not bool(r.get("ok", true)),
			"%s 的 snapshot 不是对象要拒 —— 放过去的话 StateCodec.restore "
				% str(t)
			+ "会把整局清成空桌子")
		check(str(r.get("code", "")) == "bad_snapshot",
			"%s 的坏快照码是 bad_snapshot（实为 %s）" % [str(t), str(r.get("code", ""))])


## T3：uid 要掰回 int。
## 60 == 60.0 为真，所以 find_card 照样找得到 —— 这条能潜很久。
## 它炸在拿 uid 当字典键和 Array.has 的地方（memory: json-turns-uids-into-float-keys）
func _t3_uids_come_back_as_int() -> void:
	print("\n--- T3 uid 掰回 int ---")
	var result := {
		"ok": true, "op": "buy", "new_uid": 60, "market_idx": 0,
		"pay_uids": [61, 62], "removed_uids": [63],
		# 攻击回执里被打掉的那几张。名字里没有 uid，装的却是 uid ——
		# 白名单和 test_net_socket 的扫描器都按字段名织网，所以它一次漏了两道
		"removed": [66, 67],
		"target": { "kind": "card", "res": "cash", "core_uid": 64, "uids": [65] },
	}
	var got := Protocol.decode(Protocol.encode(Protocol.applied(result, 1)))
	check(bool(got.get("ok", false)), "applied 过得去 decode")
	var r: Dictionary = (got["msg"] as Dictionary)["result"]

	check(typeof(r["new_uid"]) == TYPE_INT,
		"new_uid 掰回了 int（实为 %s）—— float 键查不中的后果是"
			% type_string(typeof(r["new_uid"]))
		+ "付掉的卡不被吸走还被当成多付的退回：**联网局白拿一张牌**")
	check(typeof((r["pay_uids"] as Array)[0]) == TYPE_INT,
		"uids 掰回了 int（实为 %s）"
			% type_string(typeof((r["pay_uids"] as Array)[0])))
	check(typeof((r["removed_uids"] as Array)[0]) == TYPE_INT,
		"removed_uids 也掰了")
	# attack 的回执用的是 `removed`（不带 uid 字样）。漏掉这一条的后果不是
	# 找不着卡 —— 60 == 60.0 为真，find_card 照样找得到 —— 而是
	# _animate_removed 里 `entities.has(u)` 一张都查不中：不撕、返回 0.0，
	# 那几张挂到结算才被 _sync_entities 的兜底路径收走。
	# 玩家看到的是「响了一声、红框没了、牌还在原地」
	check(typeof((r["removed"] as Array)[0]) == TYPE_INT,
		"attack 的 removed 也掰了（实为 %s）—— 名字里没 uid 字样，"
			% type_string(typeof((r["removed"] as Array)[0]))
		+ "漏登记的话受击的卡当场不撕，一直挂到攻击阶段结束")
	check(Array(r["removed"]) == [66, 67],
		"removed 掰完值还是那两个（%s）" % str(r["removed"]))
	var tgt: Dictionary = r["target"]
	check(typeof(tgt["core_uid"]) == TYPE_INT,
		"嵌套一层的 target.core_uid 也掰了 —— attack 的结果里带着打的是哪个组合")
	check(typeof((tgt["uids"] as Array)[0]) == TYPE_INT, "target.uids 也掰了")

	# 值也不能在掰的过程里变
	check(int(r["new_uid"]) == 60 and Array(r["pay_uids"]) == [61, 62],
		"掰完值还是那几个（%s / %s）" % [str(r["new_uid"]), str(r["pay_uids"])])

	# 不该动的字段别动：整值 float 一律转 int 会把本该是 float 的量变成整数除法
	var f: Dictionary = Protocol.decode(Protocol.encode(
		Protocol.drag(1, Protocol.DRAG_MOVE, [60], 0.5, 2.0)))["msg"]
	check(typeof(f["v"]) == TYPE_FLOAT,
		"坐标 v=2.0 还是 float（实为 %s）—— 「整值 float 一律转 int」"
			% type_string(typeof(f["v"]))
		+ "会在这里换出一个更难找的 bug")
	check(typeof((f["uids"] as Array)[0]) == TYPE_INT, "而 drag 的 uids 是 int")


## T4：客户端能发的是白名单。
## 忘了登记新消息只会「发不出去」，不会「客户端能伪造 seated」
func _t4_client_whitelist() -> void:
	print("\n--- T4 客户端白名单 ---")
	for t in [Protocol.JOIN, Protocol.INTENT, Protocol.DRAG, Protocol.REMATCH]:
		check(Protocol.is_client_msg(t), "客户端能发 %s" % str(t))
	for t in [Protocol.SEATED, Protocol.APPLIED, Protocol.PHASE,
			Protocol.REMATCH_STATE, Protocol.REMATCH_START, Protocol.CLOSED]:
		check(not Protocol.is_client_msg(t),
			"服务器消息不许客户端发：%s —— 放过去等于让客户端自己发牌" % str(t))
	# 白名单里的每一条都得是真类型（写错字符串的话它永远发不出去，且不报错）
	for t in Protocol.CLIENT_MSGS:
		check(Protocol.REQUIRED.has(t),
			"白名单里的 %s 是个登记过的类型" % str(t))


## T7：摞的位置（u/v）在信封里的规矩。
##
## 这一节钉的是**「没说」和「说了 0」不能混**。位置是可选字段：
## 老形状的包（`[uid...]`）、单机局、测试里图省事的 send_piles([[1,2]]) 都不带它，
## 而收方靠「有没有这两个键」决定照发方说的摆、还是走整行居中那条老路
## （settle_layout._layout_ai_zone）。缺键补成 0.0 的话，那些包会全被
## 当成「这一摞在桌子左后角」—— 一屏的摞挤到一个点上，而且不报错。
##
## 钳位也在这里：收方拿 u/v 直接 lerp 到桌面坐标上，伪造包送个 u=50
## 就能把牌画到桌外面去（同 drag 那条，收发两道都钳）
func _t7_pile_anchor() -> void:
	print("\n--- T7 摞的位置 ---")
	# 带位置的：两个键都活着回来，而且**是 float**（掰 int 那一趟不能顺手把
	# 0.25 变成 0 —— 那是「桌子最左边」，牌会贴着左边缘摆）
	var one: Array = Protocol.pile_lists([
		{ "uids": [60, 61], "compact": false, "u": 0.25, "v": 0.75 }])
	check(one.size() == 1 and (one[0] as Dictionary).has("u")
			and (one[0] as Dictionary).has("v"),
		"说了位置的摞，u/v 两个键都留着（实为 %s）" % str(one))
	if one.size() == 1:
		var d := one[0] as Dictionary
		check(is_equal_approx(float(d.get("u", -1.0)), 0.25)
				and is_equal_approx(float(d.get("v", -1.0)), 0.75),
			"位置的值没变（实为 u=%s v=%s）" % [str(d.get("u")), str(d.get("v"))])
		check(typeof(d.get("u")) == TYPE_FLOAT,
			"u 是 float 而不是 int（实为 %s）—— 掰成 int 就只剩桌子两条边"
				% type_string(typeof(d.get("u"))))

	# **没说位置的不许补键**。这一条是整节的重点：补上去等于替发方声明
	# 「这一摞在 (0,0)」，而那是桌角一个真实的点
	for sample in [[60, 61], { "uids": [60, 61], "compact": true }]:
		var out: Array = Protocol.pile_lists([sample])
		check(out.size() == 1 and not (out[0] as Dictionary).has("u")
				and not (out[0] as Dictionary).has("v"),
			"没说位置就不出 u/v 键（%s → %s）" % [str(sample), str(out)])

	# 只给一半：按没说算。半个坐标没有意义，而补另一半同样是编造位置
	for half in [{ "uids": [60], "u": 0.5 }, { "uids": [60], "v": 0.5 }]:
		var out: Array = Protocol.pile_lists([half])
		check(out.size() == 1 and not (out[0] as Dictionary).has("u")
				and not (out[0] as Dictionary).has("v"),
			"只给半个坐标按没说算（%s → %s）" % [str(half), str(out)])

	# 钳位：越界的送进来要被夹回 [0,1]
	var wild: Array = Protocol.pile_lists([
		{ "uids": [60], "u": 50.0, "v": -9.0 }])
	if wild.size() == 1:
		var d := wild[0] as Dictionary
		check(float(d.get("u", -1.0)) == 1.0 and float(d.get("v", -1.0)) == 0.0,
			"越界的 u/v 钳回 [0,1]（实为 u=%s v=%s）—— 不钳的话伪造包"
				% [str(d.get("u")), str(d.get("v"))]
			+ "能把牌画到我这半边、画到公共区的牌上")

	# 过一趟真信封：piles 里的位置得活着到对面。构造 + encode/decode 全走一遍，
	# 因为 from_dict 是**字段白名单** —— piles 那一支只挑它认识的键重排，
	# 漏了 u/v 的话位置在转发时被静默吃掉（这正是 VERSION 升到 3 的理由）
	var env := Protocol.decode(Protocol.encode(Protocol.piles([
		{ "uids": [60, 61], "compact": true, "u": 0.3, "v": 0.6 }])))
	check(bool(env.get("ok", false)), "带位置的 piles 过得去 decode")
	if bool(env.get("ok", false)):
		var ps: Array = (env["msg"] as Dictionary).get("piles", [])
		check(ps.size() == 1 and (ps[0] as Dictionary).has("u")
				and (ps[0] as Dictionary).has("v"),
			"位置过完信封还在（实为 %s）" % str(ps))
		if ps.size() == 1:
			var d := ps[0] as Dictionary
			check(is_equal_approx(float(d.get("u", -1.0)), 0.3)
					and is_equal_approx(float(d.get("v", -1.0)), 0.6),
				"过完信封位置的值也没变（实为 u=%s v=%s）"
					% [str(d.get("u")), str(d.get("v"))])

	# 版本号必须跟着形状走。piles 多带一个字段而服务器要原样转 ——
	# v2 的服务器会把 u/v 挑掉，两端都不报错，而症状和「从来没有过位置」
	# 一模一样。所以这条不是形式主义：它是**唯一**能分辨两者的东西
	check(Protocol.VERSION >= 3,
		"协议版本至少 3（实为 %d）—— piles 带上位置之后必须升版本，"
			% Protocol.VERSION
		+ "否则新客户端连老服务器时位置被静默吃掉")


func _t5_room_codes() -> void:
	print("\n--- T5 房号 ---")
	check(Protocol.normalize_room(" ab23 ") == "AB23",
		"房号去空格转大写（实为 %s）" % Protocol.normalize_room(" ab23 "))
	check(Protocol.normalize_room("ab23") == Protocol.normalize_room("AB23"),
		"大小写不敏感 —— 玩家是照着念的，不该因为大小写进不去同一间")
	check(Protocol.normalize_room("AB-23") == "AB23",
		"连字符也吃掉 —— 玩家会照着念的节奏打（实为 %s）"
			% Protocol.normalize_room("AB-23"))
	check(Protocol.valid_room("AB23"), "四位字母数字是合法房号")
	check(not Protocol.valid_room(""), "空房号不合法")

	# 规矩只剩「字母数字 + 长度上限」。**长度不再固定 4 位**：
	# 房间码按 Protocol.valid_room 的字符规则校验，"OK" 和
	# "OURSECRETROOM" 都该收下 —— 卡在一个固定长度上的输入框，
	# 玩家看到的是「我填的码没错，服务器说房号不合法」
	for code in ["A", "OK", "AB2", "AB234", "LILI", "ROOM1", "OO00IL"]:
		check(Protocol.valid_room(code),
			"字母数字的 %s 是合法房号 —— 玩家自己起的密码不该被字母表挡住" % code)
	# 0/1/I/L/O 现在**在**字母表里。它们当初被排掉是为了「念给对面听」，
	# 而那个理由只对生成的码成立：玩家打 "LILI" 时归一化会把四个字符全丢掉，
	# 剩一个空串，于是服务器报 bad_room —— 报的是一个完全正常的输入
	for ch in "01ILO":
		check(Protocol.ROOM_ALPHABET.contains(ch),
			"字母表含 %s —— 排掉它等于把玩家打的正常字符静默丢成空串" % ch)
	check(Protocol.normalize_room("A0B1") == "A0B1",
		"字母数字一个不丢（实为 %s）" % Protocol.normalize_room("A0B1"))

	# 上限还是要有：房间码进 rooms 字典当键（net/server.gd），
	# 不设上限的话一条 join 就能开出一个几兆长键的房间
	var too_long := ""
	for i in Protocol.ROOM_MAX_LEN + 1:
		too_long += "A"
	check(not Protocol.valid_room(too_long),
		"超 %d 位不合法 —— 房号是字典键，得有护栏" % Protocol.ROOM_MAX_LEN)

	# 生成用的字母表**另算**：随机码要念给对面听，那时才需要避开易混字符
	for ch in "01ILO":
		check(not Protocol.ROOM_GEN_ALPHABET.contains(ch),
			"生成字母表避开易混字符 %s —— 随机码是念出来的" % ch)

	# join 自己就归一化，省得两侧各归一化一次还归得不一样
	var j := Protocol.join(" ab23 ")
	check(str(j["room"]) == "AB23", "join 里就归一化了（实为 %s）" % str(j["room"]))

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260826
	for i in 20:
		var code := Protocol.make_room_code(rng)
		check(Protocol.valid_room(code), "生成的房号 %s 自己是合法的" % code)


func _t6_close_reason_clip() -> void:
	print("\n--- T6 关闭帧原因截断 ---")
	var long := ""
	for i in 200:
		long += "长"
	var clipped := Protocol.clip_reason(long)
	check(clipped.to_utf8_buffer().size() <= Protocol.CLOSE_REASON_MAX,
		"截过的原因塞得进关闭帧（%d 字节 / 上限 %d）—— 超了的话"
			% [clipped.to_utf8_buffer().size(), Protocol.CLOSE_REASON_MAX]
		+ "整个关闭帧发不出去，玩家看到的是「连接断了」而没有原因")
	check(clipped.length() > 0, "截完还剩下点东西")
	check(Protocol.clip_reason("短的") == "短的", "够短的原样不动")
	# 码要能翻回名字：客户端按码决定「重试」还是「让玩家去更新」
	check(Protocol.close_code_name(4003) == Protocol.CLOSE_ROOM_FULL,
		"4003 翻成 room_full（实为 %s）" % Protocol.close_code_name(4003))
	check(Protocol.close_code_name(4002) == Protocol.CLOSE_VERSION,
		"4002 翻成 bad_version")
	# 1000 是正常关闭，**故意**不在表里：认不出就返回 ""，
	# 让收方走「网络断了」那条路而不是编一个我们的码出来
	check(Protocol.close_code_name(1000) == "",
		"认不出的关闭码返回空（1000 是正常关闭，不是我们发的）")
	# 表里每个码都要能翻回去（写重了的话有一个永远翻不出来）
	for name in Protocol.CLOSE_CODES:
		check(Protocol.close_code_name(int(Protocol.CLOSE_CODES[name])) == name,
			"%s 的码翻得回来" % str(name))
