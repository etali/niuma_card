# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 回归测试：重开一局之后的两个 bug + 买到的牌看不见
##
## 【bug 2】第二局买不了卡、进下一回合崩溃。
## 根因是一处**引用换了、另一处没换**：`_on_restart` 里 `state = GameState.new()`
## 换掉了场景层那份状态，但意图管道（`pipe`/`IntentApply`）是在 `_ready` 里
## 拿着**上一局那份 state** 建的，重开时没有重建。于是：
##   - 上一局的 state 里 `winner != ""`，`IntentApply.apply` 那条
##     「已分胜负后只放 finalize 过」把每一条意图都挡了 → 第二局什么都做不了
##   - 崩溃点在结算：`n_combos` 从**旧** state 数（`pipe.applier().production_count()`），
##     而 `_resolve_combo_visual` 用 `Settle.ordered_production_combos(state)[idx]`
##     读的是**新** state → 旧局有组合、新局没有时下标越界
##
## 为什么这两个症状看着毫不相干却是同一个根因：管道是**唯一**的写入口，
## 它指错了状态就等于「所有玩家输入都写进一个没人看的状态」。
## 界面读 `main.state`（新的、正确的），所以画面全对 —— 这才是它难查的地方。
##
## 【bug 1】买到的牌不可见，在那个位置又能凑成组合、然后就可见了。
## `_free_spot` 拿 `global_position` 当占用判据，而**飞行中的牌还在出发点**
## （memory: settle-runs-mid-flight 的同一个形状）。买卡飞 0.35s，这期间
## 任何一处再问落点都会把同一个坑再许诺一次 → 两张牌完全重合，
## 后面那张把前面那张整个盖住。凑成组合时 `_layout_group` 把它们摊开，
## 被盖住的那张就「又出现了」——牌一直在，只是被压着
##
## 【bug 3】补间活过了它动画的那张牌（T7）。和 bug 2 是同一个形状：
## 补间是 **main** 建的（`create_tween()` 挂在调用它的节点上），动画的却是**卡**。
## 卡被 `_clear_table` 收掉之后补间照样跑完，回调对着一个已释放的引用赋值。
## 修法是 `bind_node(卡)` —— 绑的节点没了，补间跟着停。
##
## 怎么发现的：`--host --port=N` 配 `--server=...` 两个无头进程实测联机，
## 两边各刷 8 条 `Lambda capture at index 0 was freed` + 8 条 SCRIPT ERROR。
## 当时的脚本只数断言行、只 grep `[FAIL]`，满屏报错仍被当成「全绿」。
## 现在 runner 会检查引擎错误日志，本测试同时验证重开后的具体行为。
##
## 变异提示（实跑确认过红，登记进 tools/mutate_check.py）：
##   摘掉 `_spawn_market_card` / `_delayed_flyout` 里任一处 bind_node → T7 红

## 假连接：只为把 main 变成「联网局」，一个包都不发。
## NetTransport._init 不建 socket 连接（connect_to_server 才建），所以 new 出来
## 就能用；send_drag 覆盖掉是为了别真的往 socket 上写
class FakeNet extends NetTransport:
	var sent: Array = []
	func send_drag(phase_name: String, uids: Array, _u := 0.0, _v := 0.0) -> void:
		sent.append({ "phase": phase_name, "uids": uids })

func _initialize() -> void:
	print("=== 重开一局 / 买卡落点 测试 ===")
	var main: Node = await boot_main()

	await _t1_pipe_follows_state(main)
	await _t2_second_game_can_buy(main)
	await _t3_no_overlap_spots(main)
	await _t4_wraps_to_empty_row(main)
	await _t5_saturated_gives_different_spots(main)
	await _t6_inflight_card_holds_its_dest(main)
	await _t7_no_tween_outlives_its_card(main)

	finish()

# ---------- T1 管道跟着 state 换 ----------

func _t1_pipe_follows_state(main: Node) -> void:
	print("\n--- T1 重开之后管道指向新 state ---")
	var old_state: GameState = main.state
	check(main.pipe.applier().state == old_state,
		"开局时管道和场景层是同一份 state")

	# 埋几个「一局之内有效」的量，验它们不会活过重开。
	# uid 跨局重用，所以租约里留着的号在新局对应的是**另外几张牌**
	var leased: Array = []
	for uid in main.entities:
		leased.append(uid)
		if leased.size() >= 3:
			break
	main._lease_foe_cards(leased)
	check(leased.is_empty() or main.is_drag_leased(leased[0]), "重开前租约是立着的")
	main._foe_action_done = true
	main._foe_combo_shown = 4
	# 接一条假连接，把这一局变成「联网局」。这是跨局残留量里最狠的一个：
	# 「再战一局」只重开**本机**，对手那边还停在他自己的终局面板上
	# —— 协议里没有 rematch（net/room.gd 的 rematch 投票与重开），没人通知他
	var fake := FakeNet.new()
	main.attach_net(fake)
	check(not main._foe_is_ai(), "重开前对手是远端的人")

	# 直接把上一局判成结束，走真的重开路径
	old_state.winner = GameState.PLAYER
	main._show_game_over()
	main._on_restart()
	await physics_frame

	# 连接不许活过重开。带着它进新局的话，新局第一个对手回合会停在
	# _await_foe_action 里等一条永远不来的 action_done —— 不报错、不崩，
	# 就是**再也不动了**（比 bug 2 更难查：bug 2 至少崩了一下）。
	# 判据取「对手回到本地 AI」而不是「_net 是 null」：前者是症状
	check(main._foe_is_ai(),
		"重开退回单机局，对手由本地 AI 驱动（否则新局会卡在等对手行动）")
	# 信号也得摘掉。留着的话上一局那条连接还能往新局的桌面上塞拖拽帧
	check(not fake.foe_drag.is_connected(main.on_foe_drag),
		"上一局那条连接的 foe_drag 摘掉了（否则它还能往新局桌面塞牌）")
	var foe_uid := -1
	for uid in main.entities:
		if not main.entities[uid].draggable:
			foe_uid = uid
			break
	if foe_uid >= 0:
		fake.foe_drag.emit({ "seq": 1, "phase": Protocol.DRAG_PICKUP,
			"uids": [foe_uid], "u": 0.5, "v": 0.5 })
		check(not main.is_drag_leased(foe_uid),
			"上一局的连接发帧过来，新局的牌不受影响（uid %d）" % foe_uid)

	# 发的那头也不许漏。上面那条「对手回到本地 AI」只管 _foe_remote ——
	# 光把它置回 false、_net 还留着的话，卡不会卡（本地 AI 接手了），
	# 但我在新局里每拖一下牌都往那条**已经没人听**的连接上发一帧。
	# 真 socket 上是往关掉的连接写，联网局里那是「玩了半局才发现对面早走了」
	fake.sent.clear()
	var mine := -1
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if e.draggable and not e.is_market:
			mine = uid
			break
	if mine >= 0:
		main.board._on_card_clicked(main.entities[mine])
		await process_frame
		await process_frame
		main.board.cancel_drag()
		await process_frame
		check(fake.sent.is_empty(),
			"新局里拖牌不再往上一局那条连接上发（漏了 %d 帧 %s）" % [
				fake.sent.size(),
				str(fake.sent.map(func(s: Dictionary) -> String: return s["phase"]))])

	check(main.state != old_state, "重开换了一份新 state")
	# 这一条是整个 bug 的判据：管道**必须**跟着换。
	# 不换的话下面 T2 那些意图全会被旧 state 的 winner 挡掉
	check(main.pipe.applier().state == main.state,
		"管道的 applier 指向新 state（不是上一局那份）")
	check(main.state.winner == "", "新局没有胜者")

	# 点数池也不许留：上一局攻击阶段装的弹，在第二局第一个攻击阶段
	# 会让「还没装弹就点得起靶」，那是白拿一轮攻击
	check(main.pipe.applier().pools(main.my_seat)[CardDB.RES_CASH] == 0
			and main.pipe.applier().pools(main.my_seat)[CardDB.RES_USER] == 0,
		"新局的点数池是空的")

	# 跨局残留量。判据取「新局的牌里没有一张被租着」而不是「字典是空的」——
	# 前者是症状（布局绕开这张牌、2 秒后还弹一句「对手那边没动静」），
	# 后者只是实现。uid 重用是这条判据成立的前提：留着的号在新局有对应的牌
	var still_leased := -1
	for uid in main.entities:
		if main.is_drag_leased(uid):
			still_leased = uid
	check(still_leased < 0,
		"新局没有牌背着上一局的拖拽租约（uid %d）" % still_leased)
	check(not main._foe_action_done,
		"上一局那条 action_done 没活到新局（否则对手第一个行动阶段一帧就过）")
	check(main._foe_combo_shown == 0, "对手组合计数归零")

# ---------- T2 第二局能买卡、能推进 ----------

func _t2_second_game_can_buy(main: Node) -> void:
	print("\n--- T2 第二局的玩家输入真的落地 ---")
	var r: Dictionary = await main._try_buy(0)
	# 管道指着旧 state 时这里返回的是 {ok:false, code:"game_over"}
	check(r.get("ok", false), "第二局买得成（code=%s）" % r.get("code", ""))
	if r.get("ok", false):
		# 判据取「这张卡在新 state 里找得到」，不数总张数 ——
		# 买卡是付掉 price 张换 1 张，总数是**减少**的
		check(not main.state.find_card(main.my_seat, r["new_uid"]).is_empty(),
			"买到的卡进了**新** state（不是上一局那份）")
		check(main.entities.has(r["new_uid"]), "买到的卡有实体")
	await create_timer(0.45).timeout

	# 组合也要能建：和买卡是同一条管道，但走的是另一个 op
	var combo_r: Dictionary = await _try_a_combo(main)
	check(combo_r.get("ok", false) or combo_r.get("code", "") != "game_over",
		"组卡这条 op 也没被上一局的胜负挡掉（code=%s）" % combo_r.get("code", ""))

	# 结算不许越界。判据取「两边数出来的组合数一样」——
	# 崩溃现场就是这两个数不一致（一个数旧 state、一个数新 state）
	var n_pipe: int = main.pipe.applier().production_count()
	var n_scene: int = Settle.ordered_production_combos(main.state).size()
	check(n_pipe == n_scene,
		"管道和场景层数出同样多的产出组合（%d vs %d）" % [n_pipe, n_scene])

## 凑一个组合出来。凑不出就返回空 —— T2 那条判据只关心「有没有被 game_over 挡」
func _try_a_combo(main: Node) -> Dictionary:
	for c in main.state.market:
		pass
	var cash: Array = []
	for c in main.state.players[main.my_seat]["cards"]:
		if CardDB.get_def(c["def_id"]).get("res") == CardDB.RES_CASH:
			cash.append(c["uid"])
	if cash.size() < 2:
		return {}
	return await main.pipe.submit(
		Intent.create_combo(main.my_seat, cash.slice(0, 2)), main.my_seat)

# ---------- T3 落点不重合 ----------

## 两张牌位置完全重合 = 后面那张把前面那张整个盖住，看着就是「买到的牌不见了」。
## 判据取水平距离：y 上差一点（ladder）是正常的摞，x/z 都撞上才是压死
const OVERLAP_EPS := 0.35

func _t3_no_overlap_spots(main: Node) -> void:
	print("\n--- T3 买卡落点不和飞行中的牌重合 ---")
	# 先把钱补足。判据是「两张牌重不重合」，不该顺带依赖前面几节花掉多少 ——
	# 靠开局余款的话，T2 多买一张这一节就报「买到 1 张」，
	# 而那个红是缺钱不是缺位（memory: earlier-section-zeroes-the-assertion 的近亲）
	for i in 20:
		main.state.add_card(main.my_seat, "cash")
	main._sync_entities()
	await arrivals_landed(main)

	# 连着买两张：第一张飞 0.35s，第二张在这期间问落点。
	# 这就是「牌不可见」的现场 —— 不等它落地
	var uids: Array = []
	for i in 2:
		if main.state.market.is_empty():
			break
		var r: Dictionary = await main._try_buy(0)
		if r.get("ok", false):
			uids.append(r["new_uid"])
		else:
			print("    第 %d 次买失败：%s / %s" % [i, r.get("code", "?"), r.get("reason", "?")])
		await physics_frame   # 只等一帧：第一张还在飞
	check(uids.size() == 2, "连着买到两张（买到 %d 张）" % uids.size())
	if uids.size() < 2:
		return

	# 目标位置在补间里，不在 position 上。等落地再量
	await create_timer(0.5).timeout
	for i in 10:
		await physics_frame

	var a: CardEntity = main.entities[uids[0]]
	var b: CardEntity = main.entities[uids[1]]
	check(is_instance_valid(a) and is_instance_valid(b), "两张都还在")
	if not (is_instance_valid(a) and is_instance_valid(b)):
		return
	var dx: float = absf(a.global_position.x - b.global_position.x)
	var dz: float = absf(a.global_position.z - b.global_position.z)
	check(dx > OVERLAP_EPS or dz > OVERLAP_EPS,
		"两张买到的牌没压在一起（dx=%.2f dz=%.2f）" % [dx, dz])

	# 全桌扫一遍：不许有任何两张非组合内的牌完全重合。
	# 只查散牌 —— 组合内的牌本来就是叠着摆的
	var loose: Array = []
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if is_instance_valid(e) and not e.is_market and main.board.group_of(e) == null:
			loose.append(e)
	var worst := 999.0
	var pair := ""
	for i in loose.size():
		for j in range(i + 1, loose.size()):
			var p: CardEntity = loose[i]
			var q: CardEntity = loose[j]
			var d: float = maxf(absf(p.global_position.x - q.global_position.x),
				absf(p.global_position.z - q.global_position.z))
			if d < worst:
				worst = d
				pair = "%d/%d" % [p.uid, q.uid]
	check(loose.size() < 2 or worst > OVERLAP_EPS,
		"桌面 %d 张散牌两两不重合（最近的一对 %s 距 %.2f）" % [loose.size(), pair, worst])

# ---------- T4~T6 _free_spot 本身（拿一份合成台面直接问） ----------

const SettleLayout = preload("res://scenes/settle_layout.gd")

## 造一份**只装我摆的那几张**的 layout：entities 是 main.entities 的引用，
## 直接往真台面上塞占位卡会污染后面的小节；换成自己一份字典，
## _free_spot 就只看得见这一批（它只读 entities 和 _main.my_seat）
func _probe_layout(main: Node, at: Array) -> Node:
	var lay: Node = SettleLayout.new()
	main.add_child(lay)
	lay.bind(main)
	var fake := {}
	var uid := 90000
	for p in at:
		var e := CardEntity.new()
		e.setup(uid, "cash_1")
		e.position = p
		lay.add_child(e)      # 挂上树 global_position 才等于 position
		fake[uid] = e
		uid += 1
	lay.entities = fake
	return lay

## 铺满一行（x 从 -8.5 到 8.5，步长 1.7 —— 和 _free_spot 的滑移同一个步长，
## 所以这一行上每一个候选点都撞）
func _fill_row(at: Array, z: float) -> void:
	var x := -8.5
	while x <= 8.5:
		at.append(Vector3(x, 0.2, z))
		x += 1.7

func _t4_wraps_to_empty_row(main: Node) -> void:
	print("\n--- T4 换行绕回另一头，不钉在边上 ---")
	# 买卡的锚点 z 是 PLAYER_ZONE_Z + 1.6 = 3.4，近侧区间 [0.6, 5.2]。
	# 把 3.4 / 4.5 / 5.2 三行铺满，0.6 这行留空 ——
	# 原先「到边就 clampf」的写法只朝 +z 走，看不到 0.6 那行，
	# 60 次全在重复扫 5.2；改成绕回 z_min 之后才找得到
	var at: Array = []
	for z in [3.4, 4.5, 5.2]:
		_fill_row(at, z)
	var lay: Node = _probe_layout(main, at)
	var spot: Vector3 = lay._free_spot(Vector3(0.0, 0.2, 3.4), main.my_seat)

	var clash := false
	for p in at:
		if absf((p as Vector3).x - spot.x) < 1.3 and absf((p as Vector3).z - spot.z) < 1.0:
			clash = true
	check(not clash,
		"三行铺满时找到的落点不压任何一张（spot=%.1f,%.1f）" % [spot.x, spot.z])
	check(spot.z < 3.0,
		"落点绕到了锚点**下方**的空行（z=%.2f，锚点 3.40）" % spot.z)
	lay.queue_free()

func _t5_saturated_gives_different_spots(main: Node) -> void:
	print("\n--- T5 整片挤满时两次不给同一个点 ---")
	# 近侧四行全铺满：这时候**没有**不撞的落点，走的是「返回最空的那个」那条路。
	# 判据是症状本身 —— 第一张占住之后第二次不能再给同一个点，
	# 否则第二张精确落在第一张上，就是「买到的牌不见了」
	var at: Array = []
	for z in [0.6, 1.7, 2.8, 3.9, 5.0]:
		_fill_row(at, z)
	var lay: Node = _probe_layout(main, at)
	var anchor := Vector3(0.0, 0.2, 3.4)
	var first: Vector3 = lay._free_spot(anchor, main.my_seat)
	# 第一张「飞向」first：claimed 就是 main._move_to 那条 dest_pos 在结算批里的等价物
	var second: Vector3 = lay._free_spot(anchor, main.my_seat, [first])
	var d: float = maxf(absf(first.x - second.x), absf(first.z - second.z))
	check(d > OVERLAP_EPS,
		"挤满时两次落点不重合（第一次 %.1f,%.1f 第二次 %.1f,%.1f 距 %.2f）"
			% [first.x, first.z, second.x, second.z, d])
	lay.queue_free()

## 把压着 spot 的牌全挪到**两个区域之外**（z=-12 那条线上排开），让 spot 真空出来。
##
## 两条 meta / 补间记录都得清掉，只挪 global_position 是不够的：
## _rest_pos 优先读 dest_pos，其次读 board.rest_pos（board._move_tw 里的终点）——
## 留着任何一条，被挪走的牌在避让眼里**还占着老位置**，spot 照旧算撞。
## 这是 every-tween-must-declare-its-destination 的反向用法：
## 想让一张牌「不在某处」，得把宣告过终点的那几处一起撤掉
func _park_away(main: Node, spot: Vector3, ignore: Dictionary) -> void:
	var parked := 0
	for uid in main.entities:
		if ignore.has(uid):
			continue
		var e: CardEntity = main.entities[uid]
		if not is_instance_valid(e) or e.is_market:
			continue
		var at: Vector3 = main.layout._rest_pos(e)
		if absf(at.x - spot.x) >= 1.3 or absf(at.z - spot.z) >= 1.0:
			continue
		main.board._stop_move(e, false)   # snap=false：别把它按到那个作废的终点上
		if e.has_meta("dest_pos"):
			e.remove_meta("dest_pos")   # 没这个键时 remove_meta 会报 error
		e.global_position = Vector3(-7.0 + parked * 1.7, 0.2, -12.0)
		parked += 1
	print("  （前置：挪走压着归宿的 %d 张）" % parked)

func _t6_inflight_card_holds_its_dest(main: Node) -> void:
	print("\n--- T6 飞行中的牌按**归宿**算占用 ---")
	# 这一节走真台面：要验的是 main._move_to 和 layout._rest_pos 对得上。
	# 挑一张己方散牌，让它飞去一个远处的空点，然后在**飞行途中**问那儿空不空
	var mover: CardEntity = null
	for uid in main.entities:
		var e: CardEntity = main.entities[uid]
		if is_instance_valid(e) and not e.is_market and main.board.group_of(e) == null:
			mover = e
			break
	check(mover != null, "台面上有一张己方散牌可以搬")
	if mover == null:
		return

	# 归宿得挑一个**这会儿确实空着**的点，不能随手写一个坐标：
	# 台面上散着几十张牌，随手挑的那个本来就被别人占着的话，
	# 「避开了归宿」这条判据就靠巧合过 —— 改坏 _rest_pos 它照样绿
	# （变异检查实测过这一版，MISS）
	#
	# 但**不能拿 _free_spot 来挑**：它饱和时返回的是「最空的那个」，那个点
	# 仍然撞（见 settle_layout._free_spot 的注释）。而这一节的锚点 x=6.8 只够
	# 它扫到 x∈{6.8, 8.5} 两列 —— 理牌把摞摆到右边缘时那两列会全被占上，
	# 于是下面这条前置判据按 RNG 概率红（_rand_pos 不带种子，实测 8 跑红 3）。
	# 前置条件要**造**出来，不是碰运气问出来的：先把压着这个点的牌挪走
	var ignore_self := { mover.uid: true }
	var dest := Vector3(6.8, 0.2, 1.2)
	_park_away(main, dest, ignore_self)
	check(not main.layout._spot_clash(dest, [], ignore_self),
		"挑到的归宿这会儿是空的（%.1f,%.1f）" % [dest.x, dest.z])

	var before := mover.global_position
	main._move_to(mover, dest, 0.6)
	await physics_frame
	check(maxf(absf(mover.global_position.x - dest.x),
		absf(mover.global_position.z - dest.z)) > OVERLAP_EPS,
		"这会儿它还没飞到（实时坐标 %.1f,%.1f，归宿 %.1f,%.1f）"
			% [mover.global_position.x, mover.global_position.z, dest.x, dest.z])
	check(mover.get_meta("dest_pos", Vector3.ZERO) == dest, "飞行中挂着 dest_pos")

	# 关键判据：刚才空着的那个点，现在**被飞行中的它占住了**。
	# 读实时坐标（还在出发点）的话这儿仍然算空，于是同一个坑许诺两次 ——
	# 这就是「买到的牌不见了」。判据取「空 → 占」这个跃变而不是某个坐标，
	# 靠巧合过不去：同一个点、同一份台面，前后只差一次 _move_to
	check(main.layout._spot_clash(dest, []),
		"飞起来之后那个点算占住了 —— 避开了它的归宿（%.1f,%.1f）" % [dest.x, dest.z])
	var spot: Vector3 = main.layout._free_spot(dest, main.my_seat)
	check(maxf(absf(spot.x - dest.x), absf(spot.z - dest.z)) > OVERLAP_EPS,
		"飞行途中问落点，给的不是它的归宿（给的是 %.1f,%.1f）" % [spot.x, spot.z])

	# 落地之后归宿撤掉：留着会让避让一直绕开一个其实已经有人的点
	# （这时候实时坐标就是答案，两份记录并存就有机会不一致）
	await create_timer(0.8).timeout
	await physics_frame
	check(not mover.has_meta("dest_pos"), "落地之后 dest_pos 撤掉了")
	check(maxf(absf(mover.global_position.x - dest.x),
		absf(mover.global_position.z - dest.z)) < 0.05,
		"它确实飞到了归宿（%.2f,%.2f）" % [mover.global_position.x, mover.global_position.z])
	# 搬回去，别给后面的小节留个挪过位置的台面
	mover.global_position = before

# ---------- T7 补间不许活过它动画的那张牌 ----------

## 【bug 3】清桌之后补间还在跑，回调对着一个已释放的引用。
##
## 根因和 bug 2 是同一个形状（一处换了、另一处没跟着）：补间是 **main** 建的
## （`create_tween()` 挂在调用它的节点上），而它动画的是**卡**。
## 卡被 `_clear_table` queue_free 掉之后，补间照样跑完剩下的部分 ——
## `_spawn_market_card` 那句 `tween_callback(func(): e.freeze = true)`
## 于是对着一个空引用赋值。
##
## 怎么发现的：`--host --port=N` 和 `--server=...` 两个无头进程配对实测，
## 两边各刷 8 条 `Lambda capture at index 0 was freed` + 8 条 SCRIPT ERROR。
## 走的路是「单机 new_game 摆好货架 → 紧接着 begin_net_game → _respawn_all
## → _clear_table 收掉这些卡」，而货架那个补间是 0.3 秒的。
##
## **为什么这一条必须是判据而不是「看日志干净」**：那 16 条是引擎打的 ERROR，
## harness 只数断言行、只 grep [FAIL] —— 满屏报错的一跑照样是「全绿」。
## 而联网局出问题时人就是靠翻这份日志找线索的，被这些淹掉就等于没有日志。
##
## 判据问机制本身：清桌之后**下一帧**，树上不许再有当时那批补间
## （bind_node 绑的节点没了，补间跟着失效 —— 实测正好晚一帧）。
## 在 lambda 里加 is_instance_valid 过不了这一条，也不该过：
## 引擎在调回调**之前**就把失效的捕获置空并自己打那条 ERROR，
## 守卫只能挡住第二条 SCRIPT ERROR
## 只看**卡身上**那两处带回调的补间。
##
## 不拿「清桌之后树上一条补间都没有」当判据 —— 那条会被无关的东西弄红：
## `_burst` 有一条 tween_interval 等着 queue_free 自己造的节点，
## 卡面翻新那几处也各有一条。它们动画的都不是卡，卡没了跟它们无关。
##
## 这段从前还点着 `_show_message`（说它挂着一条 MSG_HOLD 好几秒的补间），
## 那一条**已经不存在**：提示条改成常驻了，一条补间都不建。
## 顺带说明为什么这里不写具体条数 —— 原先写的是「实测活下来 4 条」，
## 而那个数随着别处的改动会变，一变就没人知道它当初是量出来的还是猜的
func _t7_no_tween_outlives_its_card(main: Node) -> void:
	print("\n--- T7 补间不许活过它动画的那张牌 ---")
	# 货架卡那一处：_spawn_market_card 建的补间，0.3 秒后回调里写 e.freeze
	var before := _tween_set()
	main._spawn_market_card(0, main.state.market[0], Vector3(0, 0.2, -4.0))
	var card: CardEntity = main.market_cards[main.market_cards.size() - 1]
	var spawn_tw: Tween = _new_tween(before)
	if not _need(spawn_tw != null, "货架卡带起了一条补间"):
		return
	check(spawn_tw.is_valid(), "这会儿它是有效的")

	# 卡没了，补间要跟着失效。**只有 bind_node 做得到这件事**：
	# 在 lambda 里加 is_instance_valid 拦不住引擎那条
	# 「Lambda capture at index 0 was freed」—— 它在调回调之前就打了
	main.board.unregister_card(card)
	main.market_cards.erase(card)
	card.queue_free()
	# 晚一帧才失效（实测），多等一帧留余量
	await process_frame
	await process_frame
	check(not spawn_tw.is_valid(),
		"卡被收掉之后那条补间跟着失效了 —— 活着的话它 0.3 秒后对着一个"
		+ "已释放的引用赋值，每张货架卡刷两条 ERROR。"
		+ "实测 `--host --port=N` 配 `--server=...` 两个无头进程时两边各 16 条")

	# 拆卡飞出那一处：_delayed_flyout 同一个形状（延迟到点时卡可能已经不在了，
	# 而 _tear_out 第一句就是 board.unregister_card）
	var victim: CardEntity = null
	for uid in main.entities:
		victim = main.entities[uid]
		break
	if not _need(victim != null, "找到一张牌来验拆卡那一处"):
		return
	before = _tween_set()
	main._delayed_flyout(victim, Vector3(0, 4, 2), 0.5)
	var fly_tw: Tween = _new_tween(before)
	if not _need(fly_tw != null, "拆卡飞出带起了一条补间"):
		return
	main.board.unregister_card(victim)
	main.entities.erase(victim.uid)
	victim.queue_free()
	await process_frame
	await process_frame
	check(not fly_tw.is_valid(), "牌没了，拆卡那条补间也跟着失效")

	# 把桌子摆回来：上面拿掉了一张货架卡和一张手牌
	main._respawn_all()
	await process_frame

## check 是 void，前置条件不满足时得能提前 return（同 test_join_panel.gd 的 need）
func _need(cond: bool, msg: String) -> bool:
	check(cond, msg)
	return cond

## 当前树上有效补间的集合（拿 get_instance_id 当键，Tween 不能当字典键用）
func _tween_set() -> Dictionary:
	var out := {}
	for tw in get_processed_tweens():
		if tw is Tween and tw.is_valid():
			out[tw.get_instance_id()] = true
	return out

## before 之后**新**冒出来的那一条。多于一条就取第一条 —— 上面两处调用
## 各只建一条，取到别人的那条会让判据变成空过的，所以这里也顺手数一下
func _new_tween(before: Dictionary) -> Tween:
	var found: Array[Tween] = []
	for tw in get_processed_tweens():
		if tw is Tween and tw.is_valid() and not before.has(tw.get_instance_id()):
			found.append(tw)
	check(found.size() <= 1,
		"这一步只该新起一条补间（实为 %d 条）—— 多了就说明下面那条判据"
			% found.size()
		+ "可能在验别人那条")
	return found[0] if not found.is_empty() else null
