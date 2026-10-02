# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 拖拽广播测试 —— 对手把牌拎起来，我这边看得见吗（scenes/main.gd 的拖拽广播与租约处理）
##
## 这一整条通道原先只在 tests/test_net_socket.gd 的 T6 里测过**中段**
## （客户端发 drag → 服务器转成 foe_drag → 另一个客户端收到）。两头都没有观察点：
## 发送端没有任何东西调 send_drag，接收端 foe_drag 信号一个听众都没有。
## 也就是说「转发通了但一张牌都不动」在测试里是全绿的。
##
## 这个文件钉的是两头：
##   T1 归一化坐标的算术（唯一有算术的一步，算错就是牌画到别人半区去了）
##   T2 回环：发送端排的字段直接喂给接收端，u/v 写反当场对不上
##   T3 租约挡住布局（不挡就是牌抽搐，scenes/main.gd 的拖拽广播与租约处理）
##   T4 乱序帧丢掉、cancel 收回租约
##   T5 超时（对方拖着牌掉线，没有它牌永远浮在半空）
##   T6 发送端：拎起来发一帧 pickup，拖着的时候节流发 move，松手发 cancel
##
## 判据都直接调 on_foe_drag / drag_packet，不经 socket ——
## socket 那一段 test_net_socket 已经测过，这里要问的是「场景层拿它干了什么」

## 记账用的假 net：**继承真的 NetTransport**，只把 send_drag 换成记一笔。
##
## 为什么不另写一个鸭子类型的桩：main._net 有类型（NetTransport），
## 塞个别的进去是运行时类型错误。为了能测而把那个类型放宽成 Object，
## 换来的是「谁都能塞进来」——代价比收益大。
## 继承来的这个不连 socket（net_transport.gd 的 `_init()` 只赋几个字段），
## 而 send_drag 在 socket 没 OPEN 时本来就直接 return —— 所以真货在这里
## 什么都观察不到，必须换掉这一个方法
class FakeNet extends NetTransport:
	var sent: Array = []
	func send_drag(phase_name: String, uids: Array, u := 0.0, v := 0.0) -> void:
		sent.append({ "phase": phase_name, "uids": uids, "u": u, "v": v })

## 远端拖拽的一帧。seq 自增：接收端要靠它丢乱序帧
var _seq := 0
func _frame(phase_name: String, uids: Array, u: float, v: float) -> Dictionary:
	_seq += 1
	return { "seq": _seq, "phase": phase_name, "uids": uids, "u": u, "v": v }

func _initialize() -> void:
	print("=== 拖拽广播测试 ===")
	var main: Node = await boot_main()
	_t1_uv_math(main)
	_t2_loopback(main)
	await _t3_lease_blocks_layout(main)
	await _t4_stale_and_cancel(main)
	await _t5_timeout(main)
	await _t6_sender(main)
	finish()

# ---------- T1 归一化坐标 ----------

## 判据不读 DRAG_FAR_Z 这类被测常量，读的是**布局自己那套边界**：
## 远侧半区的 z 区间在 settle_layout._free_spot 里写着 [-7.6, -1.8]。
## 两处取同一个数是这条判据的意义 —— 拖拽落点必须落在布局摆得出牌的地方
const FAR_Z_MIN := -7.6
const FAR_Z_MAX := -1.8
const NEAR_Z_MIN := 0.6
const NEAR_Z_MAX := 5.2

func _t1_uv_math(main: Node) -> void:
	print("\n--- T1 归一化坐标 ---")
	# 三个角落都得落在对手半区里。u/v 越界要被钳住（协议那头也钳，两道都要有）
	for uv in [Vector2(0.0, 0.0), Vector2(0.5, 0.5), Vector2(1.0, 1.0),
			Vector2(-3.0, 9.0)]:
		var p: Vector3 = main.foe_drag_point(uv.x, uv.y)
		check(p.z >= FAR_Z_MIN - 0.001 and p.z <= FAR_Z_MAX + 0.001,
			"u/v=(%.1f,%.1f) 落在对手半区的 z 区间内（z=%.2f）" % [uv.x, uv.y, p.z])
		check(p.z < NEAR_Z_MIN,
			"u/v=(%.1f,%.1f) 不落在我这半边（z=%.2f 在 %.1f 之外）"
				% [uv.x, uv.y, p.z, NEAR_Z_MIN])
	# v 单调递增：v 大 = 更靠近购牌区（往我这边来）。反了的话对手把牌往前推，
	# 我看到的是往后退 —— 一个不报错、只是读起来别扭的 bug
	check(main.foe_drag_point(0.5, 0.9).z > main.foe_drag_point(0.5, 0.1).z,
		"v 越大越靠近购牌区（对手往前推，我看到的也是往前）")
	# u 单调递增，且不镜像：两侧的现金锚都在左
	check(main.foe_drag_point(0.9, 0.5).x > main.foe_drag_point(0.1, 0.5).x,
		"u 越大越靠右（x 不镜像，两侧现金锚同在左）")
	# 牌得抬起来：贴着桌面画就看不出「在他手上」
	check(main.foe_drag_point(0.5, 0.5).y > 0.5,
		"对手拖着的牌离桌（y=%.2f）" % main.foe_drag_point(0.5, 0.5).y)

	# 发送端：我这半边的 z 映到 [0,1]，两端都取得到
	check(absf(main.my_drag_uv(Vector3(0, 1.2, NEAR_Z_MIN)).y - 0.0) < 0.001,
		"我这边最靠购牌区那条边 → v=0")
	check(absf(main.my_drag_uv(Vector3(0, 1.2, NEAR_Z_MAX)).y - 1.0) < 0.001,
		"我这边最靠镜头那条边 → v=1")
	# 越界钳住：拖到桌外（购买/典当动作会把牌拖过购牌区）不能发出 v<0
	var uv_out: Vector2 = main.my_drag_uv(Vector3(0, 1.2, -3.0))
	check(uv_out.y >= 0.0 and uv_out.y <= 1.0,
		"拖过购牌区时 v 被钳在 [0,1]（v=%.2f）" % uv_out.y)

# ---------- T2 回环 ----------

## 发送端排好的那份 packet，补个 seq 直接喂给接收端。
##
## 这条判据的对象是**两端对同一个字段的理解**：drag_packet 把 x 放进 u，
## on_foe_drag 就必须把 u 读成 x。写反了 u/v 之后 T1 那几条还是全绿的
## （foe_drag_point 自己没错），只有回环才对不上
func _t2_loopback(main: Node) -> void:
	print("\n--- T2 发送端字段安排 ---")
	# 取点要让 u 和 v **落在 0.5 两侧**：两个都大于 0.5 的点上，
	# u/v 互换之后判据照样全绿（实测过 —— (6.0, 5.1) 算出 u=0.83/v=0.98，
	# 换过来还是两个都 >0.5）。这里取左后方：x 偏左 → u<0.5，z 靠镜头 → v>0.5
	var at := Vector3(-6.0, 1.2, NEAR_Z_MAX - 0.1)
	var p: Dictionary = main.drag_packet(Protocol.DRAG_MOVE, [1, 2], at)
	check(p["phase"] == Protocol.DRAG_MOVE and (p["uids"] as Array).size() == 2,
		"packet 带着 phase 和 uids")
	check(p["u"] < 0.5, "拖到左边 → u<0.5（u=%.2f）" % p["u"])
	check(p["v"] > 0.5, "拖到靠镜头那头 → v>0.5（v=%.2f）" % p["v"])
	# 对手那边照这份 packet 画出来的点：x 同侧（不镜像），v 大 = 靠购牌区
	var there: Vector3 = main.foe_drag_point(p["u"], p["v"])
	check(there.x < 0.0, "对手屏幕上也在左边（x=%.2f）" % there.x)
	check(there.z > (FAR_Z_MIN + FAR_Z_MAX) / 2.0,
		"我往前推，对手看到的也是靠购牌区那半截（z=%.2f）" % there.z)

# ---------- T3 租约挡住布局 ----------

## 对手的一张闲置卡：租约要挡的就是这种牌（每步之后 _layout_ai_idle 都摆它）
func _a_foe_card(main: Node) -> int:
	for c in main.state.players[main.foe_seat]["cards"]:
		if main.entities.has(c["uid"]) and is_instance_valid(main.entities[c["uid"]]):
			return int(c["uid"])
	return -1

func _t3_lease_blocks_layout(main: Node) -> void:
	print("\n--- T3 租约挡住布局 ---")
	var uid := _a_foe_card(main)
	check(uid >= 0, "对手场上有牌可拖（uid=%d）" % uid)
	if uid < 0:
		return
	check(not main.is_drag_leased(uid), "开局这张牌没被租约占着")
	main.on_foe_drag(_frame(Protocol.DRAG_PICKUP, [uid], 0.3, 0.4))
	check(main.is_drag_leased(uid), "收到 pickup 之后这张牌归网络驱动")
	var want: Vector3 = main.foe_drag_point(0.3, 0.4)
	var e: CardEntity = main.entities[uid]
	check(e.global_position.distance_to(want) < 0.6,
		"牌摆到了 pickup 那一帧的位置（差 %.2f）" % e.global_position.distance_to(want))

	# 布局跑一趟：租约在，它必须绕开这张牌。
	# 这是整条租约存在的理由 —— AI 每一步之后都调这个函数
	main.layout._layout_ai_idle()
	await ai_moves_landed(main)
	check(e.global_position.distance_to(want) < 0.6,
		"布局跑过一趟之后牌还在半空（差 %.2f）" % e.global_position.distance_to(want))
	check(main.is_drag_leased(uid), "布局没有偷偷收走租约")

	# 反面：租约放掉之后布局要把它摆回去，否则牌永远浮着
	main.on_foe_drag(_frame(Protocol.DRAG_CANCEL, [uid], 0.3, 0.4))
	check(not main.is_drag_leased(uid), "cancel 之后租约收回")
	await ai_moves_landed(main)
	check(e.global_position.distance_to(want) > 0.6,
		"松手之后布局把牌摆回去了（离半空那点 %.2f）"
			% e.global_position.distance_to(want))
	check(absf(e.rotation_degrees.z) < 0.001,
		"歪着拎的倾斜清掉了（不然它会斜着躺在摞里，z=%.2f）" % e.rotation_degrees.z)

# ---------- T4 乱序帧 / cancel ----------

func _t4_stale_and_cancel(main: Node) -> void:
	print("\n--- T4 乱序帧丢掉 ---")
	var uid := _a_foe_card(main)
	if uid < 0:
		return
	var e: CardEntity = main.entities[uid]
	# 手工排 seq：拎起来是 10，然后来一帧 20，再来一帧**迟到的 15**
	main.on_foe_drag({ "seq": 10, "phase": Protocol.DRAG_PICKUP,
		"uids": [uid], "u": 0.2, "v": 0.2 })
	main.on_foe_drag({ "seq": 20, "phase": Protocol.DRAG_MOVE,
		"uids": [uid], "u": 0.8, "v": 0.8 })
	var at20: Vector3 = e.global_position
	check(at20.distance_to(main.foe_drag_point(0.8, 0.8)) < 0.6,
		"第 20 帧摆到位")
	main.on_foe_drag({ "seq": 15, "phase": Protocol.DRAG_MOVE,
		"uids": [uid], "u": 0.1, "v": 0.1 })
	check(e.global_position.distance_to(at20) < 0.001,
		"迟到的第 15 帧被丢掉了（不丢就是牌被拽回去，看着是抽搐）")
	# 新的一帧照收：丢的判据是「比上一帧旧」，不是「一律丢」
	main.on_foe_drag({ "seq": 21, "phase": Protocol.DRAG_MOVE,
		"uids": [uid], "u": 0.1, "v": 0.1 })
	check(e.global_position.distance_to(main.foe_drag_point(0.1, 0.1)) < 0.6,
		"第 21 帧照收（不是把 move 一律丢掉）")
	# cancel 必须收得到，哪怕它的 seq 比记着的那个小：
	# 收不到 cancel 的后果是牌一直浮着，比抖一下严重得多
	main.on_foe_drag({ "seq": 3, "phase": Protocol.DRAG_CANCEL,
		"uids": [uid], "u": 0.0, "v": 0.0 })
	check(not main.is_drag_leased(uid),
		"seq 落后的 cancel 也收（丢了它牌就永远浮着）")
	await ai_moves_landed(main)

# ---------- T5 超时 ----------

func _t5_timeout(main: Node) -> void:
	print("\n--- T5 租约超时 ---")
	var uid := _a_foe_card(main)
	if uid < 0:
		return
	var e: CardEntity = main.entities[uid]
	main.on_foe_drag(_frame(Protocol.DRAG_PICKUP, [uid], 0.5, 0.5))
	check(main.is_drag_leased(uid), "拎起来了")
	var held: Vector3 = main.foe_drag_point(0.5, 0.5)
	# 一帧的时间不该到期：到期判据写成恒真的话，对手拖一下牌就被抢回去
	main._tick_drag_lease(0.05)
	check(main.is_drag_leased(uid), "才过 0.05s，租约还在（不是一 tick 就收）")
	# 到期这一趟走**真实帧**，不手工喂 delta：手工喂的话
	# 「_process 里那一句 _tick_drag_lease(delta) 被删掉」这条变异没人看得见 ——
	# 超时逻辑写对了但没接上时钟，对方掉线牌照样永远浮着。
	# 等多久由 DRAG_LEASE_TIMEOUT 折算（这是同步不是判据，判据在下面两条）
	var cap := int(ceil(main.DRAG_LEASE_TIMEOUT * 3.0
		/ (1.0 / float(maxi(Engine.physics_ticks_per_second, 1)))))
	while cap > 0 and main.is_drag_leased(uid):
		await physics_frame
		cap -= 1
	check(not main.is_drag_leased(uid),
		"收不到 dragging 帧，租约自己到期（对方拖着牌掉线时靠这条）")
	# 等的是摆放补间本身，不是墙钟：这条判据读的是落点，等不够就读到出发点
	await ai_moves_landed(main)
	# 判据是「离开了半空那一点」，不是「y 小于某个数」：
	# 摞里的牌沿层高台阶叠着（Board.ladder_y），摞得高的那张落定后 y 也有 0.9,
	# 拿一个绝对高度当判据会把正常的摞判成没落地
	check(e.global_position.distance_to(held) > 0.6,
		"到期之后牌被摆回布局里（离半空那点 %.2f，没有一直浮着）"
			% e.global_position.distance_to(held))

# ---------- T6 发送端 ----------

## 我这边一张能拖的牌。开局理牌把散卡全编进了摞（_group_pile），
## 所以这里先拆一张出来 —— 判据要的是「一张手上的牌」，不是「一摞」
func _a_my_card(main: Node) -> CardEntity:
	for c in main.board.cards:
		if is_instance_valid(c) and c.draggable and not c.is_market:
			if main.board.group_of(c) != null:
				main.board._detach_from_group(c)
			return c
	return null

func _t6_sender(main: Node) -> void:
	print("\n--- T6 发送端广播 ---")
	var board: Board = main.board
	var c := _a_my_card(main)
	check(c != null, "我这边有一张能拖的散卡")
	if c == null:
		return
	var got: Array = []
	board.drag_broadcast.connect(func(ph: String, uids: Array, at: Vector3) -> void:
		got.append({ "phase": ph, "uids": uids, "at": at }))

	var grab := c.global_position
	board._on_card_clicked(c)
	# _tick_drag_broadcast 挂在 _process 上，等一帧它才跑
	await process_frame
	await process_frame
	var picks: Array = got.filter(func(g): return g["phase"] == Protocol.DRAG_PICKUP)
	check(picks.size() == 1, "拎起来发了一帧 pickup（发了 %d 帧）" % picks.size())
	if picks.size() >= 1:
		check((picks[0]["uids"] as Array).has(c.uid),
			"pickup 带着手上这张的 uid")
		# 报的是那张牌**桌面上**的位置。y 不进判据 —— 接收端的高度是
		# foe_drag_point 自己定的（一律 DRAG_HEIGHT），发多少都不看，
		# 所以这里只钉 x/z。pickup 不节流：晚 50ms 发就是对手侧晚 50ms 抬手
		var at: Vector3 = picks[0]["at"]
		check(absf(at.x - grab.x) < 0.001 and absf(at.z - grab.z) < 0.001,
			"pickup 报的是手上这张牌的桌面位置（x/z）")

	# 拖着**不动**也持续发（对手要看得到牌停在哪儿，而且收方那条租约要靠它续，
	# 见 main.DRAG_LEASE_TIMEOUT），但这一路要节流：坐标一样的帧发出去纯浪费
	got.clear()
	var frames := 30
	for i in frames:
		await process_frame
	var moves: int = got.filter(func(g): return g["phase"] == Protocol.DRAG_MOVE).size()
	check(moves >= 1, "拖着不动也持续广播（%d 帧里发了 %d 次）" % [frames, moves])
	check(moves < frames, "停着不动那一路有节流，不是每帧一发（%d < %d）"
		% [moves, frames])

	# **动了就当帧发**，不攒。这一条是延迟问题修回来的：原先是一个 0.05 的
	# 无条件节流（~20Hz），而收方是硬写位置的（main._move_foe_drag 没有插值）——
	# 60fps 的屏幕上那张牌每 3 帧才动一次，看起来就是一格一格地跳。
	# 量到的往返只有 16ms，所以这 50ms 才是玩家感觉到的那个「延迟」。
	#
	# 判「每一帧都发」而不是「发得比原来多」：后者在节流间隔被改小
	# （比如 0.05 → 0.03）时也会绿，而那仍然是攒帧
	got.clear()
	var held: CardEntity = board._drag_cards[0]
	var anchor := held.global_position
	var moved := 0
	# 位移写**绝对量**不写 `+=`：_process 每帧会把手上这摞按鼠标位置重写一遍
	# （board.gd 的 `_process()`），headless 下鼠标不动，`+=` 挪出去的那点当帧就被抹回原处，
	# 于是每帧的坐标都一样，看起来像是节流没解掉
	for i in 10:
		if not is_instance_valid(held):
			break
		held.global_position = anchor + Vector3(0.1 * float(i + 1), 0, 0)
		moved += 1
		await process_frame
	var m2: int = got.filter(func(g): return g["phase"] == Protocol.DRAG_MOVE).size()
	check(m2 >= moved, "牌在动的时候每帧都发（动了 %d 帧，发了 %d 次）" % [moved, m2])

	# 松手：不管走哪条出口，都要有一帧「放下了」——
	# 漏掉的后果是对手那边的牌永远浮在半空，而本地一切正常
	got.clear()
	board.cancel_drag()
	await process_frame
	await process_frame
	var cancels: int = got.filter(
		func(g): return g["phase"] == Protocol.DRAG_CANCEL).size()
	check(cancels == 1, "松手发了一帧 cancel（发了 %d 帧）" % cancels)
	# 手上空了就不该再发：空转的 dragging 帧会让对手侧的租约一直不到期
	got.clear()
	for i in 5:
		await process_frame
	check(got.is_empty(), "手上没牌了就不再广播（多发了 %d 帧）" % got.size())
	await _t7_out_the_wire(main, c)

# ---------- T7 一路发到 net 层 ----------

## 从「玩家拎起一张牌」一路走到「net.send_drag 被调用」。
##
## T6 听的是 board 那个信号，它在 main 有没有接上这条线的两种情况下都绿 ——
## 少了 _ready 里那句 connect，对手侧一帧都收不到，而本地一切正常。
## 这一条把 main 那一段也串进来：判据是**假 net 收到了什么**
func _t7_out_the_wire(main: Node, c: CardEntity) -> void:
	print("\n--- T7 一路发到 net 层 ---")
	var fake := FakeNet.new()
	main.attach_net(fake)
	check(not main._foe_is_ai(),
		"attach_net 之后本地不再驱动对手（对面是人）")

	# 收：从**信号**发一帧进来，不直接调 on_foe_drag ——
	# 前面几节都是直接调的，那样「attach_net 里漏了这句 connect」没人看得见
	# （对手侧一帧都收不到，而我拖牌他照样看得到，症状只在联网局里出现）
	var foe := _a_foe_card(main)
	if foe >= 0:
		fake.foe_drag.emit({ "seq": 900, "phase": Protocol.DRAG_PICKUP,
			"uids": [foe], "u": 0.4, "v": 0.6 })
		check(main.is_drag_leased(foe),
			"net 层那个信号真的接到了 on_foe_drag 上")
		fake.foe_drag.emit({ "seq": 901, "phase": Protocol.DRAG_CANCEL,
			"uids": [foe], "u": 0.4, "v": 0.6 })
		await ai_moves_landed(main)

	main.board._on_card_clicked(c)
	await process_frame
	await process_frame
	check(fake.sent.size() >= 1,
		"拎起来这一下发到了 net 层（发了 %d 条）" % fake.sent.size())
	if fake.sent.is_empty():
		main.board.cancel_drag()
		return
	var first: Dictionary = fake.sent[0]
	check(first["phase"] == Protocol.DRAG_PICKUP,
		"第一条是 pickup（收到的是 %s）" % first["phase"])
	check((first["uids"] as Array).has(c.uid), "带着手上那张的 uid")
	check(first["u"] >= 0.0 and first["u"] <= 1.0
			and first["v"] >= 0.0 and first["v"] <= 1.0,
		"发出去的是归一化坐标（u=%.2f v=%.2f）" % [first["u"], first["v"]])
	# 松手那一帧也要发到 net 层：漏了它对手侧的牌就等 2 秒超时才落下
	fake.sent.clear()
	main.board.cancel_drag()
	await process_frame
	await process_frame
	var last_phases: Array = fake.sent.map(func(s): return s["phase"])
	check(last_phases.has(Protocol.DRAG_CANCEL),
		"松手这一下也发到了 net 层（收到 %s）" % str(last_phases))

	# 换一条连接：seq 的号是**每条连接**从 1 开始发的（NetTransport._drag_seq），
	# 而上面刚收过 seq=901。这一节验的是「水位每次拎牌重置」——
	# pickup 不受水位管、且它自己会把水位写成自己的 seq，所以 seq=1 的 pickup
	# 进得来，紧跟着 seq=2 的 move 以它为基准也进得来。
	# 少了那条豁免，新连接的每一帧都小于旧水位、全被丢掉 ——
	# 症状是「对手拎起牌和松手都看得见，中间那段不动」，两边都不报错
	var fake2 := FakeNet.new()
	main.attach_net(fake2)
	var foe2 := _a_foe_card(main)
	if foe2 >= 0:
		fake2.foe_drag.emit({ "seq": 1, "phase": Protocol.DRAG_PICKUP,
			"uids": [foe2], "u": 0.1, "v": 0.1 })
		var e: CardEntity = main.entities[foe2]
		fake2.foe_drag.emit({ "seq": 2, "phase": Protocol.DRAG_MOVE,
			"uids": [foe2], "u": 0.9, "v": 0.9 })
		var want: Vector3 = main.foe_drag_point(0.9, 0.9)
		check(absf(e.global_position.x - want.x) < 0.01,
			"新连接的低 seq 没被上一条连接的水位丢掉（x=%.2f 应为 %.2f）"
				% [e.global_position.x, want.x])
		fake2.foe_drag.emit({ "seq": 3, "phase": Protocol.DRAG_CANCEL,
			"uids": [foe2], "u": 0.9, "v": 0.9 })
		await ai_moves_landed(main)
