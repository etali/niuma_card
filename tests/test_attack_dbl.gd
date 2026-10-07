# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 两个复发缺陷的回归测试
##
## A. 双击组合「经常只提起组合里的一部分牌，而不是展开组合」
##    按下就当场 _on_card_clicked 的话：摊开态点中间那张会把一摞劈成
##    「留下的半截」和「手上的半截」，双击的第一击就把组拆了，第二击
##    再 toggle_compact 时这张牌已经不在任何组里 → 白点。松手时能不能并回去
##    全看 _nearest_group 撞不撞得上 MERGE_DIST，所以是「成功率不高」而不是「完全不动」。
##    另外 macOS 只要两击之间光标动了几像素就把 clickCount 打回 1，
##    event.double_click 根本不来，双击退化成两次「拎起-放下」。
##
## B. 攻击 BOT 摞好的牌「没有一次性扣完组合里面的牌」
##    _pile_target_by_key 取的是摞内 cost 最小的靶：富余卡恒为一份点数，
##    配方核心当时是整份配方，于是点一摞组合永远只啃掉一张富余卡。
##    而且扣完没人重排，被扣掉那几张的层位空着、侧边清单还挂着旧张数。
##
## B8/B9. 「玩家打对方和 BOT 打玩家，撕毁动画得是同一套、速度也一样」
##    撕牌本身两边一直是同一套（都走 _animate_removed → _tear_out），
##    差的是外面那层节拍。核心改成按 `_game.attack_cost_per_card` 逐张计价之后，
##    啃穿一个满席组要一张一条意图：玩家那边 _attack_pile 攒成一批
##    （1 次瞄准、1 声、1 朵花，0.94s），BOT 那边一条一拍（实测 6.3s）。
##    修法两层：靶带 batch 键让 BOT 也按摞攒（_drive_bot_attack），
##    起飞时刻排在一条公用队上（_tear_slot_ms）让分次进来的也逐张错开


func _initialize() -> void:
	print("=== 双击可靠性 / 攻击点选 测试 ===")
	var main: Node = await boot_main()
	var board: Board = main.board

	await _a1_press_does_not_split(main, board)
	await _a2_jitter_double(main, board)
	await _a3_not_a_double(main, board)
	await _a4_hold_and_release(main, board)
	await _a6_slop_not_tighter_than_radius(main, board)
	await _a7_loose_card_midflight(main, board)
	await _a8_click_compact_valid(main, board)
	await _a9_click_near_pawn(main, board)
	await _a5_triple_click(main, board)
	await _b1_pile_target_prefers_combo(main)
	await _b2_drop_card_closes_gap(main, board)
	await _b3_relayout_after_attack(main)
	await _b4_player_group_closes_gap(main, board)
	await _b5_idle_pile_drains(main)
	await _b6_loose_card_one_click(main)
	await _b7_pile_partial_then_stop(main)
	await _b8_tear_is_symmetric()
	await _b9_stagger_across_calls()

	finish()

# ---------- A1. 按下就拎牌，松手精确复位 ----------

## 手感要求：按下当场就得把牌拎起来（不许等双击窗口）。
## 代价是双击的第一击也会拎一次 —— 由它的原地松手照 _press_snap 精确复位，
## 于是这一击对桌面是空操作，第二击面对的还是完整的一摞。
## 这一段验的就是这三件事：当场拎起、原地松手还原、第二击切得动
func _a1_press_does_not_split(main: Node, board: Board) -> void:
	print("--- A1. 按下当场拎牌，原地松手精确复位（点摊开态中间那张）---")
	var members := make_stack(main, board, 9200, "yunketang", 5)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	# 点第 2 张（摊开态的中间）：这一按会把组劈成「留下的 [0,1]」+「手上的 [2,3,4]」
	var mid: CardEntity = members[2]
	var at := _screen_of(main, mid)
	check(board._pick_card(at) != null, "射线能打到中间那张")
	var origin0: Vector3 = board._group_origin(g)
	var order0: Array = (g["cards"] as Array).duplicate()

	# 按下：同一帧就得有牌在手，一帧都不等
	var dings := [0]
	var cb := func(): dings[0] += 1
	board.group_completed.connect(cb)
	_press(board, at)
	check(not board._drag_cards.is_empty(),
		"按下当场就拎起了牌（%d 张在手，不等任何一帧）" % board._drag_cards.size())
	check(board._press_snap.has("cards"), "同时记下了按下前的桌面快照")

	# 原地松手：照快照精确复位，不走 _nearest_group 吸附
	_release_at(board, at)
	await settle()
	check(board._drag_cards.is_empty(), "松手后手上没牌（%d）" % board._drag_cards.size())
	var gr: Variant = board.group_of(mid)
	check(gr != null and gr["cards"].size() == 5, "组复位成完整 5 张（%d）" % _gsize(board, mid))
	check(gr != null and (gr["cards"] as Array) == order0, "队列顺序和按下前一致")
	check(gr != null and not gr.get("compact", false), "形态没被改（仍是摊开）")
	var origin1: Vector3 = board._group_origin(gr)
	check(Vector2(origin1.x - origin0.x, origin1.z - origin0.z).length() < 0.02,
		"起点没漂（差 %.3f）" % Vector2(origin1.x - origin0.x, origin1.z - origin0.z).length())
	check(dings[0] == 0, "一次点击前后组合结果没变 → 不响叮（实际 %d）" % dings[0])
	board.group_completed.disconnect(cb)

	# 第二击到达：切换收拢，面对的是完整的一摞
	_press(board, at, true)
	await settle()
	var g2: Variant = board.group_of(mid)
	check(g2 != null and g2["cards"].size() == 5, "收拢后还是同一摞 5 张（%d）" % _gsize(board, mid))
	check(g2 != null and g2.get("compact", false), "双击切成了收拢态")
	_release(board)
	park(board, members)

# ---------- A2. 手抖几像素：没有系统双击标志也要认 ----------

## 用户报的那一次「只提起了一部分牌」就是这条路：
## macOS 见光标动了就把 clickCount 打回 1 → event.double_click = false。
## 位移落在 6~24 像素这一段最要命：够格判双击（DBL_RADIUS=24），
## 而只要松手的位移门槛比它紧，第一击的松手就已经把半截牌就地落成了新组，
## 第二击白点。现在 CLICK_SLOP = DBL_RADIUS，这一段里松手一律精确复位
func _a2_jitter_double(main: Node, board: Board) -> void:
	print("--- A2. 两击之间手抖 10 像素、无系统双击标志 ---")
	var members := make_stack(main, board, 9250, "ditui", 4)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var mid: CardEntity = members[1]
	var at := _screen_of(main, mid)

	# 第一击：按下拎牌 + 抖着松手（松手点偏 9.9 像素，仍在 CLICK_SLOP 内 → 精确复位）
	var jitter := at + Vector2(7.0, 7.0)   # 距离 9.9：< DBL_RADIUS 24
	check(jitter.distance_to(at) > 6.0 and jitter.distance_to(at) < Board.DBL_RADIUS,
		"抖动量 %.1f 落在「够格判双击」的范围内" % jitter.distance_to(at))
	_press(board, at)
	check(not board._drag_cards.is_empty(), "第一击当场拎起了牌")
	_release_at(board, jitter)
	# 这一等必须短于 DBL_WINDOW —— 下面那句 `_mk(jitter, true)` 要问「第二击还算双击吗」，
	# 问的是真实时钟（A3 那几条是先改 _last_click_t 再问，不受这里影响）。
	# 全组唯一一处有这个约束的等待，所以只有它走 settle_within_dbl
	await settle_within_dbl()
	check(board._drag_cards.is_empty() and _gsize(board, mid) == 4,
		"抖着松手仍精确复位：牌回去了，组 4 张（%d）" % _gsize(board, mid))
	var ev := _mk(jitter, true)
	check(not ev.double_click, "这一击没有系统双击标志（复现 macOS 的行为）")
	check(board._is_double(ev, board._pick_card(jitter)),
		"自己判定：仍算双击的第二击")
	board._unhandled_input(ev)
	await settle()
	var g2: Variant = board.group_of(mid)
	check(g2 != null and g2["cards"].size() == 4,
		"切换后组仍是完整 4 张（%d）—— 不是被劈开的半截" % _gsize(board, mid))
	check(g2 != null and g2.get("compact", false), "确实展开/收拢了，不是「只提起一部分」")
	check(board._drag_cards.is_empty(), "手上没牌（%d）" % board._drag_cards.size())
	_release(board)
	park(board, members)

# ---------- A3. 不该认成双击的几种 ----------

func _a3_not_a_double(main: Node, board: Board) -> void:
	print("--- A3. 超时 / 离得太远 / 换了一摞：都不算双击 ---")
	var members := make_stack(main, board, 9300, "yunketang", 4)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var c0: CardEntity = members[0]
	var at := _screen_of(main, c0)

	# 超出时间窗口
	board._note_click(_mk(at, true), c0)
	board._last_click_t = board._now() - Board.DBL_WINDOW - 0.05
	check(not board._is_double(_mk(at, true), c0), "隔得比 DBL_WINDOW 久 → 不算双击")

	# 在窗口内但离得远
	board._note_click(_mk(at, true), c0)
	var far := at + Vector2(Board.DBL_RADIUS + 6.0, 0)
	check(not board._is_double(_mk(far, true), c0), "位移超过 DBL_RADIUS → 不算双击")

	# 同一摞的相邻两张算同一次双击（摊开态每张只露 0.52 宽，很常见）
	board._note_click(_mk(at, true), c0)
	check(board._is_double(_mk(at + Vector2(3, 3), true), members[1]),
		"落在同一摞的另一张上 → 算双击")

	# 换到另一摞：不算
	var nb := make_stack(main, board, 9350, "chaping", 3, members)
	var g2: Dictionary = board.make_group(nb.duplicate())
	board.groups.append(g2)
	nb[0].global_position = Vector3(-2.0, 0.05, 3.0)
	board._layout_group(g2)
	await settle()
	board._note_click(_mk(at, true), c0)
	check(not board._is_double(_mk(at + Vector2(3, 3), true), nb[0]),
		"落在另一摞的牌上 → 不算双击")
	park(board, nb)
	park(board, members)

# ---------- A4. 拎起的是哪一段 / 按住不动也照样在手上 ----------

func _a4_hold_and_release(main: Node, board: Board) -> void:
	print("--- A4. 按下即拎起从被点那张往后的整段；一直按住就一直在手上 ---")
	var members := make_stack(main, board, 9400, "ditui", 4)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var top: CardEntity = members[0]
	var at := _screen_of(main, top)

	# 期望张数按射线实际打到的那张算：摊开态每张都被上一层压着中段，
	# 点队首那张的中心，射线打到的其实是它上面那张（这是正常几何，不是缺陷）
	var hit: CardEntity = board._pick_card(at)
	var want: int = 4 - board.group_of(hit)["cards"].find(hit)
	_press(board, at)
	check(board._drag_cards.size() == want,
		"按下当场从被点那张往后拎起 %d 张（实际 %d）" % [want, board._drag_cards.size()])
	# 按住不放熬过双击窗口：牌该一直在手上（没有「窗口到了才提交」这回事）
	for i in 12:
		await process_frame
	check(board._drag_cards.size() == want,
		"按住 12 帧牌仍在手上（%d 张）" % board._drag_cards.size())

	# 原地松手 = 只是点了一下：组完整回去
	_release_at(board, at)
	await settle()
	check(board._drag_cards.is_empty(), "松手后手上没牌（%d 张）" % board._drag_cards.size())
	check(_gsize(board, top) == 4, "组复位成 4 张（%d）" % _gsize(board, top))
	board._reset_click_track()   # 别让下一段的第一击和这一击配成双击
	park(board, members)

# ---------- A6. 松手门槛不许比双击半径紧 ----------

## 这条是复发的真正原因，换了机制照样成立。假如 CLICK_SLOP 比 DBL_RADIUS 小，
## 中间就留出一段位移：手抖 10 像素时，第一击的松手够格「算真拖」当场把半截牌
## 落成新组（或靠 _nearest_group 侥幸并回去），第二击又够格「算双击」，
## 于是 toggle_compact 面对的已经不是原来那一摞 ——
## 屏幕上就是「提起了组合里的一部分牌，没有展开」。
## 而 macOS 把 clickCount 打回 1 的抖动量级恰好落在这一段，所以这个洞是常态。
## 两个阈值必须同一个值，中间不能留缝
func _a6_slop_not_tighter_than_radius(main: Node, board: Board) -> void:
	print("--- A6. 手抖 10 像素的松手仍是精确复位（CLICK_SLOP ≥ DBL_RADIUS）---")
	check(Board.CLICK_SLOP >= Board.DBL_RADIUS,
		"CLICK_SLOP %.0f ≥ DBL_RADIUS %.0f，中间没有「又算拖又算双击」的缝" % [
			Board.CLICK_SLOP, Board.DBL_RADIUS])
	var members := make_stack(main, board, 9550, "yunketang", 4)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var mid: CardEntity = members[1]
	var at := _screen_of(main, mid)
	var origin0: Vector3 = board._group_origin(g)

	# 抖 9.9 像素松手：按快照精确复位，不是「就地落成新组」
	_press(board, at)
	check(not board._drag_cards.is_empty(), "按下拎起了牌")
	_release_at(board, at + Vector2(7.0, 7.0))
	await settle()
	check(_gsize(board, mid) == 4, "抖 9.9 像素松手后组仍是完整 4 张（%d）" % _gsize(board, mid))
	var origin1: Vector3 = board._group_origin(board.group_of(mid))
	check(Vector2(origin1.x - origin0.x, origin1.z - origin0.z).length() < 0.02,
		"复位到原起点，没就地落下（差 %.3f）" % Vector2(
			origin1.x - origin0.x, origin1.z - origin0.z).length())
	board._reset_click_track()

	# 真拖出去 40 像素再松手：走 _end_drag 的吸附，不是精确复位
	_press(board, at)
	var held: int = board._drag_cards.size()
	check(held > 0, "按下拎起了 %d 张" % held)
	_release_at(board, at + Vector2(40.0, 0.0))
	await settle()
	check(board._drag_cards.is_empty(), "拖 40 像素后松手落了手（%d 张在手）" % board._drag_cards.size())
	check(board._press_snap.is_empty(), "真拖的那条路把快照作废了")
	park(board, members)

# ---------- A7. 半路上的散卡：快照要记落定点，不是飞行中的坐标 ----------

## 散卡的原位如果在补间没落定时就读，松手复位会把它钉在半空 ——
## 而这张牌可能正从上一次整理里飞回来，点它的时机完全由玩家决定。
## 成组那条路不用担心（_group_origin 内部先 _stop_move 过队首）
func _a7_loose_card_midflight(main: Node, board: Board) -> void:
	print("--- A7. 点一张正在飞回来的散卡，松手落回补间终点 ---")
	var c: CardEntity = main._spawn_entity(
		{ "uid": 9600, "def_id": "cash" }, Vector3(-6.0, 0.05, 3.0), true)
	isolate(board, [c])
	board._detach_from_group(c)
	await settle()
	var dest := Vector3(-3.0, 0.05, 2.0)
	board._move_to(c, dest)          # 起飞
	await create_timer(0.06).timeout  # 半路上（补间 0.18s）
	var mid_pos: Vector3 = c.global_position
	check(mid_pos.distance_to(dest) > 0.1,
		"这一刻牌还在半路（离终点 %.2f）" % mid_pos.distance_to(dest))

	var at := _screen_of(main, c)
	board._snapshot_press(c, at)
	var snap: Vector3 = board._press_snap["pos"]
	check(snap.distance_to(dest) < 0.01,
		"快照记的是补间终点，不是飞行中的坐标（差 %.3f）" % snap.distance_to(dest))
	board._on_card_clicked(c)
	check(board._drag_cards.size() == 1, "拎起了这张散卡（%d）" % board._drag_cards.size())
	_release_at(board, at)
	await settle()
	check(c.global_position.distance_to(dest) < 0.05,
		"原地松手落回终点，没钉在半空（差 %.3f）" % c.global_position.distance_to(dest))
	board._reset_click_track()
	park(board, [c])

# ---------- A8. 点一下摞好的凑满组：整摞原样不动 ----------

## 收拢态点一下会把**整摞**拎走 —— _on_card_clicked 把这个组从 groups 里摘掉了。
## 走吸附结算的话 _end_drag 找不到可并的组，只能就地另立一个新组：
## 顺序、形态、凑满基线、起点全按落点重算，于是玩家看到摞挪了窝、
## 或者凭空又响一声「凑满」。精确复位这条路把那份快照原样写回去（组 dict 是引用），
## 所以这一段是「按下-松手」对桌面为空操作最硬的一条
func _a8_click_compact_valid(main: Node, board: Board) -> void:
	print("--- A8. 点一下摞好的凑满组合，整摞不挪窝也不重响 ---")
	# 地推扫码凑满 = 核心 1 张 + 配方那几张现金（make_stack 的 n 含核心卡）。
	# 张数从卡表取：这一节量的是「点一下整摞不挪窝」，配方几张无关
	var stack_n := int(CardDB.get_def("ditui")["recipe_n"]) + 1
	var members := make_stack(main, board, 9650, "ditui", stack_n)
	var g: Dictionary = board.make_group(members.duplicate(), false, false)
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	check(g.get("was_valid", false), "这一摞是凑满状态")
	board.toggle_compact(members[0])
	await settle()
	var gc: Variant = board.group_of(members[0])
	check(gc != null and gc.get("compact", false), "已切成收拢态")
	var origin0: Vector3 = board._group_origin(gc)
	var order0: Array = (gc["cards"] as Array).duplicate()
	board._reset_click_track()   # 上面那次 toggle 不该和下面的点击配成双击

	var dings := [0]
	var cb := func(): dings[0] += 1
	board.group_completed.connect(cb)
	var at := _screen_of(main, gc["cards"][Board._top_index(gc)])
	_press(board, at)
	check(board._drag_cards.size() == stack_n,
		"收拢态点一下整摞拎起（%d 张）" % board._drag_cards.size())
	var still_listed := false
	for gg in board.groups:
		if is_same(gg, gc):
			still_listed = true
	check(not still_listed, "整摞被拎走时这个组已从 groups 里摘掉")

	_release_at(board, at)
	await settle()
	var g2: Variant = board.group_of(members[0])
	check(g2 != null, "松手后组回到桌上")
	check(g2 != null and (g2["cards"] as Array) == order0, "顺序和按下前一致")
	check(g2 != null and g2.get("compact", false), "还是收拢态，没被摊开")
	check(g2 != null and g2.get("was_valid", false), "凑满基线还在")
	check(dings[0] == 0, "结果没变 → 一声都不响（实际 %d）" % dings[0])
	var origin1: Vector3 = Vector3.INF
	if g2 != null:
		origin1 = board._group_origin(g2)
	var drift: float = Vector2(origin1.x - origin0.x, origin1.z - origin0.z).length()
	check(drift < 0.02, "整摞没挪窝（位移 %.3f）" % drift)
	board.group_completed.disconnect(cb)
	board._reset_click_track()
	park(board, members)

# ---------- A9. 典当行边上点一下，牌不许被当掉 ----------

## 一次点击必须是空操作，最要命的一条：_end_drag 开头会看落点离不离典当行
## （PAWN_RADIUS 1.8）和公共区，够近就直接把手上的牌回收成现金 / 拿去买牌。
## 摞在典当行旁边的组只要被点一下（哪怕玩家只想双击把它摞起来），
## 走吸附结算就等于把它当掉了 —— 精确复位这条路根本不碰这些判定
func _a9_click_near_pawn(main: Node, board: Board) -> void:
	print("--- A9. 典当行 1.8 格内点一下，牌不会被当掉 ---")
	var members := make_stack(main, board, 9700, "yunketang", 3)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	# 把典当行挪到这一摞头上：落点必然落在 PAWN_RADIUS 内
	var was_pawn: Vector3 = board.pawn_pos
	var head: Vector3 = members[0].global_position
	board.pawn_pos = Vector3(head.x, 0.05, head.z)
	var pawned := [0]
	var cb := func(dc: Array): pawned[0] += dc.size()
	board.dropped_on_pawn.connect(cb)

	var at := _screen_of(main, members[0])
	var hit: CardEntity = board._pick_card(at)
	check(hit != null, "射线打到了这一摞")
	_press(board, at)
	check(not board._drag_cards.is_empty(), "按下拎起了牌")
	var drop: Vector3 = board._drag_cards[0].global_position
	check(Vector2(board.pawn_pos.x - drop.x, board.pawn_pos.z - drop.z).length() < Board.PAWN_RADIUS,
		"落点确实在典当行判定圈内（%.2f < %.1f）" % [
			Vector2(board.pawn_pos.x - drop.x, board.pawn_pos.z - drop.z).length(),
			Board.PAWN_RADIUS])
	# 松手点偏 9.9 像素：正是 macOS 把 clickCount 打回 1 的那个抖动量级。
	# CLICK_SLOP 只要比 DBL_RADIUS 紧，这一下就落进「按拖拽结算」——
	# 于是玩家想双击摞牌，牌被当掉了
	_release_at(board, at + Vector2(7.0, 7.0))
	await settle()
	check(pawned[0] == 0, "抖 9.9 像素松手也没触发典当（被当掉 %d 张）" % pawned[0])
	check(_gsize(board, members[0]) == 3, "三张牌都还在这一摞里（%d）" % _gsize(board, members[0]))
	var alive := 0
	for c in members:
		if is_instance_valid(c):
			alive += 1
	check(alive == 3, "三张牌都还活着（%d）" % alive)
	board.dropped_on_pawn.disconnect(cb)
	board.pawn_pos = was_pawn
	board._reset_click_track()
	park(board, members)

# ---------- A5. 三击不许连切两次 ----------

func _a5_triple_click(main: Node, board: Board) -> void:
	print("--- A5. 连点三下只切换一次 ---")
	var members := make_stack(main, board, 9450, "yunketang", 4)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var top: CardEntity = members[0]
	var at := _screen_of(main, top)
	var was: bool = board.group_of(top).get("compact", false)

	_click(board, at)               # 1（按下拎起 + 原地松手复位）
	await process_frame
	_press(board, at, true)        # 2 → 切换
	# **必须 settle_within_dbl，不能 settle()**：拦住第三击的是 _reset_click_track()
	# 那行（双击成立后清掉追踪），而 settle() 等 0.52s > DBL_WINDOW(0.45)——
	# 第三击隔那么久，单靠「离上一击太远」就判不成双击，那行删掉这一节照旧全绿。
	# 实跑验过：掐掉 _reset_click_track 后 107 条一条不红。
	# 在窗口内点第三下，判的才是那道守卫
	await settle_within_dbl()
	var mid_state: bool = board.group_of(top).get("compact", false)
	check(mid_state != was, "第二击切换了一次")
	_click(board, at)               # 3 → 不该和第 2 击再配成一对
	await settle()
	check(board.group_of(top).get("compact", false) == mid_state,
		"第三击没再切回去（%s）" % str(board.group_of(top).get("compact", false)))
	check(_gsize(board, top) == 4, "第三击也没把摞拆散（%d 张）" % _gsize(board, top))
	park(board, members)

# ---------- B1. 点 BOT 的组合摞：优先配方核心 ----------

## BOT 的摞是收拢的，射线只打得到顶上那张，而 core_first_order 把
## 核心/产物放在顶上 —— 它本身永远不是合法靶。所以 _pile_target_by_key 这条
## 回退路径是「点 BOT 组合摞」的唯一通路，它挑错靶就等于整个功能挑错靶
func _b1_pile_target_prefers_combo(main: Node) -> void:
	print("--- B1. 点组合摞优先取配方核心（能废整组），不是不影响配方的富余卡 ---")
	var state: GameState = main.state
	# BOT 编一个「云课堂 + 用户×(配方量+2)」：核心占配方量、余下的是富余，
	# 一律按 attack_cost_per_card 计价。摞内两种靶同时存在，
	# 才分得出「先给能废组的那张」这条优先级
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var need := int(CardDB.get_def("yunketang")["recipe_n"])
	var feed := need + 2
	var prod: Dictionary = state.add_card(GameState.BOT, "yunketang")
	main._spawn_entity(prod, Vector3(0, 0.05, -3.6), false)
	var uids: Array = [prod["uid"]]
	var n := 0
	for c in state.players[GameState.BOT]["cards"]:
		if c["def_id"] == "user" and n < feed:
			uids.append(c["uid"])
			n += 1
	check(n == feed, "凑到 %d 张用户卡（%d）" % [feed, n])
	var r: Dictionary = state.create_combo(GameState.BOT, uids)
	check(r["ok"], "BOT 组合成立")
	main.layout._layout_bot_zone()
	await create_timer(0.45).timeout
	for i in 4:
		await physics_frame

	# 摞内同时存在 combo 靶和 spare 靶
	var kinds := {}
	for t in state.attack_targets(GameState.BOT):
		var inside := false
		for u in t["uids"]:
			if uids.has(u):
				inside = true
		if inside:
			kinds[t["kind"]] = int(t["cost"])
	check(kinds.has("combo") and kinds.has("spare"),
		"摞内既有配方核心也有富余卡（%s）" % str(kinds))

	# 组内组外同价：核心和富余都按 attack_cost_per_card，
	# 区别只在打掉之后配方还成不成立
	check(int(kinds.get("combo", 0)) == per_card and int(kinds.get("spare", 0)) == per_card,
		"核心 / 富余同价 %d 点（%s）" % [per_card, str(kinds)])

	# 点数给足：优先取能废掉整组的核心
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, 20)
	var pkey: String = str(main.layout._bot_pile_of_uid[prod["uid"]])
	var target: Dictionary = main._pile_target_by_key(pkey)
	check(not target.is_empty(), "顶卡能解析出靶")
	check(target.get("kind", "") == "combo",
		"取的是配方核心而不是富余卡（实际 %s，cost %s）" % [
			target.get("kind", "?"), str(target.get("cost", "?"))])
	check(int(target.get("cost", 0)) == per_card,
		"cost = attack_cost_per_card %d（实际 %s）" % [
			per_card, str(target.get("cost", "?"))])

	# 只剩一份点数也照样点得到核心 —— 原先核心是「整份配方」的整体靶，
	# 一份点数只能退回富余卡，「编进组的牌打不掉」就是从这儿来的
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, per_card)
	var cheap: Dictionary = main._pile_target_by_key(pkey)
	check(cheap.get("kind", "") == "combo",
		"%d 点也够点核心（实际 %s）" % [per_card, cheap.get("kind", "空")])
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, 0)

# ---------- B2. 扣掉几张后剩下的合上空档 ----------

func _b2_drop_card_closes_gap(main: Node, board: Board) -> void:
	print("--- B2. drop_card 合上空档、且整摞不挪窝 ---")
	var members := make_stack(main, board, 9500, "yunketang", 5)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var origin: Vector3 = board._group_origin(g)

	# 扣掉中间两张（模拟被攻击点掉）：旧实现只 refresh_group，
	# 剩下的还停在第 0/3/4 层，中间空着两层
	board.drop_card(members[2])
	board.drop_card(members[3])
	await settle()
	var g2: Variant = board.group_of(members[0])
	check(g2 != null and g2["cards"].size() == 3, "组剩 3 张（%d）" % _gsize(board, members[0]))
	var zs: Array = []
	for c in g2["cards"]:
		zs.append(c.global_position.z)
	var gap_ok := true
	for i in range(1, zs.size()):
		if absf(absf(zs[i] - zs[i - 1]) - Board.STACK_GAP.z) > 0.02:
			gap_ok = false
	check(gap_ok, "相邻两张的 z 间距都是 %.3f，没有空层（实际 %s）" % [
		Board.STACK_GAP.z, str(zs.map(func(v): return "%.2f" % v))])
	var o2: Vector3 = board._group_origin(g2)
	var d := Vector2(o2.x - origin.x, o2.z - origin.z).length()
	check(d < 0.02, "合上空档没让整摞挪窝（位移 %.3f）" % d)

	# 扣掉队首那张：组起点不该往 +z 挪一格
	origin = o2
	board.drop_card(g2["cards"][0])
	await settle()
	var g3: Variant = board.group_of(members[1])
	if g3 == null:
		g3 = board.group_of(members[4])
	check(g3 != null, "组还在")
	if g3 != null:
		var o3: Vector3 = board._group_origin(g3)
		var d2 := Vector2(o3.x - origin.x, o3.z - origin.z).length()
		check(d2 < 0.02, "扣掉队首那张，整摞仍不挪窝（位移 %.3f）" % d2)
	park(board, members)

# ---------- B3. 攻击命中后 BOT 区重排 ----------

func _b3_relayout_after_attack(main: Node) -> void:
	print("--- B3. 点掉一张配方核心后 BOT 区重排、侧边张数跟上 ---")
	var state: GameState = main.state
	var combo: Dictionary = {}
	for c in state.combos:
		if c["owner"] == GameState.BOT and c["eval"].get("leader", "") == "yunketang":
			combo = c
			break
	check(not combo.is_empty(), "找到 B1 建的那个 BOT 组合（云课堂）")
	if combo.is_empty():
		return
	var pile_key: Variant = main.layout._bot_pile_of_uid.get(combo["uids"][0], null)
	var before: int = main.layout._bot_pile_uids.get(pile_key, []).size()

	var target := {}
	for t in state.attack_targets(GameState.BOT):
		if t["kind"] == "combo" and combo["uids"].has(t["uids"][0]):
			target = t
			break
	check(not target.is_empty(), "拿到配方核心靶（cost %s）" % str(target.get("cost", "?")))
	if target.is_empty():
		return
	var cost := int(target["cost"])
	var user_before := int(state.resource_count(GameState.BOT, CardDB.RES_USER))

	# 走玩家的真实入口：攻击模式下点摞顶那张。
	# 摞顶按 core_first_order 是产物卡，它自己不是合法靶 → 落到 _pile_target_by_key
	main.phase = main.PHASE_ATTACK
	main.board.attack_mode = true
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, cost)
	var top_uid: int = main.layout._bot_pile_uids[main.layout._bot_pile_of_uid[combo["uids"][0]]][0]
	await main._on_attack_clicked(main.entities[top_uid])
	await create_timer(0.45).timeout
	for i in 4:
		await physics_frame
	var removed_n := user_before - int(state.resource_count(GameState.BOT, CardDB.RES_USER))
	# 核心按 attack_cost_per_card 逐张计价，所以一下点掉一张。cost 现取不写死：
	# 这一节量的是「点完之后桌面重排跟不跟得上」，不是定价
	check(removed_n == cost,
		"点一下摞顶扣掉 %d 张（实际 %d）" % [cost, removed_n])
	main.board.attack_mode = false

	var still := 0
	for u in target["uids"]:
		if main.layout._bot_pile_of_uid.has(u):
			still += 1
	check(still == 0, "被扣掉的牌不再登记在任何摞里（残留 %d）" % still)
	var after := 0
	for key in main.layout._bot_pile_uids:
		for u in main.layout._bot_pile_uids[key]:
			if combo["uids"].has(u):
				after += 1
	check(after == before - cost,
		"摞内张数从 %d 降到 %d（实际 %d）" % [before, before - cost, after])
	var loose: Array = []
	for c in state.players[GameState.BOT]["cards"]:
		if not main.layout._bot_pile_of_uid.has(c["uid"]):
			loose.append(str(c["uid"]))
	check(loose.is_empty(), "重排后 BOT 每张牌都在某个摞里（游离 %s）" % [
		"无" if loose.is_empty() else ", ".join(loose)])
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, 0)

# ---------- B4. BOT 打玩家的摞：剩下的当场合上空档 ----------

## 玩家的组在 board.groups 里，走的是 drop_card 那条路（BOT 的摞不在，靠 _layout_bot_zone）。
## 不在 _animate_removed 里当场 drop_card 的话：飞出是 0.08s 一张地排队、
## 每张再飞 0.4s，中间这半秒剩下的牌还停在原来的层位上，中间空着几层，
## 看起来就像「那几张还在，只是不见了」；而 _fly_out 末尾的 unregister_card
## 只 refresh_group 刷标签，从头到尾没人把层号排紧
func _b4_player_group_closes_gap(main: Node, board: Board) -> void:
	print("--- B4. BOT 打掉玩家摞里的几张，剩下的立刻合上空档 ---")
	var state: GameState = main.state
	var members: Array = []
	var uids: Array = []
	for i in 5:
		var c: Dictionary = state.add_card(GameState.PLAYER, "user")
		uids.append(c["uid"])
		members.append(main._spawn_entity(c, Vector3(-6.0, 0.05, 4.0), true))
	isolate(board, members)
	for c in members:
		board._detach_from_group(c)
	var g: Dictionary = board.make_group(members.duplicate())
	board.groups.append(g)
	board._layout_group(g)
	await settle()
	var origin: Vector3 = board._group_origin(g)

	# 打掉中间两张：模拟 BOT 的一次攻击命中
	main._animate_removed([uids[1], uids[2]], true)
	# 一帧都不等就量：drop_card 是同步的，不许等 _fly_out 那半秒
	var g2: Variant = board.group_of(members[0])
	check(g2 != null and g2["cards"].size() == 3,
		"当帧组就只剩 3 张（%d）" % _gsize(board, members[0]))
	await settle()
	var zs: Array = []
	for c in g2["cards"]:
		zs.append(c.global_position.z)
	var gap_ok := true
	for i in range(1, zs.size()):
		if absf(absf(zs[i] - zs[i - 1]) - Board.STACK_GAP.z) > 0.02:
			gap_ok = false
	check(gap_ok, "剩下 3 张排紧了，没有空层（z = %s）" % str(
		zs.map(func(v): return "%.2f" % v)))
	var o2: Vector3 = board._group_origin(g2)
	check(Vector2(o2.x - origin.x, o2.z - origin.z).length() < 0.02,
		"合上空档没让整摞挪窝（位移 %.3f）" % Vector2(
			o2.x - origin.x, o2.z - origin.z).length())
	park(board, members)

# ---------- B5. 点 BOT 的闲置摞：一次啃到底 ----------

## 用户报的那条：「BOT 牌看上去摞好了，但攻击还是点一次攻击一下」。
## 闲置摞（现金/用户/备牌）是把散卡收拢成的一摞，摞顶那张自己就是合法靶
## （kind="card"，1 点），于是 _on_attack_clicked 里直接命中那一支先返回，
## 压根走不到 _pile_target_by_key —— 点十次才扣得完一摞十张。
## 组合摞之所以没这毛病，纯粹因为它摞顶是不可点的核心卡。
## 摞在玩家眼里是一个整体（收拢之后张数只在侧边写着），点一下就该点这一摞
func _b5_idle_pile_drains(main: Node) -> void:
	print("--- B5. 点闲置摞：一次点掉点数够得着的所有张 ---")
	var state: GameState = main.state
	# 清空 BOT 手牌和组合，只留一摞干净的现金，摞里张数才数得准
	state.players[GameState.BOT]["cards"].clear()
	state.combos = state.combos.filter(func(c): return c["owner"] != GameState.BOT)
	main._sync_entities()   # 把上面清掉的那些实体一并收走（不在 state 里的都飞出）
	# 留一张用户卡吊着命：清零即胜是**每扣一张就判**的（engine/settle.gd 的攻击循环、
	# IntentApply._attack 都是），BOT 只有现金 = 用户已经是 0 = 这局在点之前就赢了，
	# 那样第一下扣完就 game_over，后面几下全被判无效，测不到「一次点掉一摞」
	state.add_card(GameState.BOT, "user")
	# 摞多大、给几点，是这一节自己的规模：点数只够啃掉一部分，
	# 剩下的那几张用来判「重排跟不跟得上」。张数按 attack_cost_per_card 折算
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var kill := 5
	var pile_n := kill + 2
	var pool := kill * per_card
	var uids: Array = []
	for i in pile_n:
		uids.append(int(state.add_card(GameState.BOT, "cash")["uid"]))
	main._sync_entities()
	main.layout._layout_bot_zone()
	await settle()

	var key: Variant = main.layout._bot_pile_of_uid.get(uids[0], null)
	check(key != null, "%d 张现金收成了一摞（key %s）" % [pile_n, str(key)])
	if key == null:
		return
	check(int(main.layout._bot_pile_uids[key].size()) == pile_n,
		"这一摞就是 %d 张（%d）" % [pile_n, int(main.layout._bot_pile_uids[key].size())])
	var top_uid: int = main.layout._bot_pile_uids[key][0]
	check(main.entities.has(top_uid), "摞顶那张有实体，点得到")

	# 摞顶自己就是一份点数的合法靶 —— 这正是旧实现只扣一张的原因
	var direct := {}
	for t in state.attack_targets(GameState.BOT):
		if t["uids"].has(top_uid):
			direct = t
			break
	check(direct.get("kind", "") == "card" and int(direct.get("cost", 0)) == per_card,
		"摞顶自己是 %d 点的散卡靶（%s / %s）" % [
			per_card, direct.get("kind", "空"), str(direct.get("cost", "?"))])

	main.phase = main.PHASE_ATTACK
	main.board.attack_mode = true
	main.pipe.applier().seed_pool_for_test(main.my_seat, pool, 0)
	# 一次点击就是一次攻击：收尾（音效、BOT 区重排、回合结束信号）只许走一遍。
	# 在循环里逐张收尾的话，攻击音按张数连放好几声，
	# 而且点数一花光就 emit attack_turn_finished、循环还在跑 → 信号发好几次，
	# 上层 await 收到第一次就把攻击阶段关了，剩下的 emit 落在下个阶段上
	var fins := [0]
	var fin_cb := func(): fins[0] += 1
	main.attack_turn_finished.connect(fin_cb)
	await main._on_attack_clicked(main.entities[top_uid])
	await settle()
	check(fins[0] <= 1, "attack_turn_finished 只发了一次（实际 %d）" % fins[0])
	main.attack_turn_finished.disconnect(fin_cb)
	var left := int(state.resource_count(GameState.BOT, CardDB.RES_CASH))
	check(left == pile_n - kill, "点一下扣掉 %d 张（%d 点花光），摞里剩 %d 张（实际剩 %d）" % [
		kill, pool, pile_n - kill, left])
	check(int(main._attack_pools["cash"]) == 0,
		"%d 点全花在这一摞上（剩 %d）" % [pool, int(main._attack_pools["cash"])])
	# 认「被点的那一摞」而不是「随便一个非空的摞」：吊命的那张用户卡也自成一摞，
	# 扫到最后一个就会读成它（1 张）
	var key2: Variant = null
	for u in uids:
		if not state.find_card(GameState.BOT, u).is_empty():
			key2 = main.layout._bot_pile_of_uid.get(u, null)
			break
	check(key2 != null and int(main.layout._bot_pile_uids[key2].size()) == pile_n - kill,
		"重排后摞里登记的也是 %d 张（%s）" % [pile_n - kill,
			"无摞" if key2 == null else str(main.layout._bot_pile_uids[key2].size())])
	main.board.attack_mode = false
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, 0)

# ---------- B6. 摞外的散卡还是一张一点 ----------

## 「点一摞 = 点这一摞」不能溢出成「点一张 = 清一片」：
## 不在任何摞里的散卡在玩家眼里就是一张，点它只该扣它自己
func _b6_loose_card_one_click(main: Node) -> void:
	print("--- B6. 摞外散卡：点数再多也只扣它自己一张 ---")
	var state: GameState = main.state
	# 自己摆干净的局：判据数的是「BOT 还剩几张用户卡」，接着上一条的残留就数不准。
	# 留一张现金吊命（清零即胜是每扣一张就判的，见 B5 那条注释）
	state.players[GameState.BOT]["cards"].clear()
	state.combos = state.combos.filter(func(c): return c["owner"] != GameState.BOT)
	state.add_card(GameState.BOT, "cash")
	var a: int = int(state.add_card(GameState.BOT, "user")["uid"])
	var b: int = int(state.add_card(GameState.BOT, "user")["uid"])
	main._sync_entities()
	# 故意不 _layout_bot_zone：这两张就不登记在任何摞里，正是「摞外散卡」
	main.layout._bot_pile_of_uid.erase(a)
	main.layout._bot_pile_of_uid.erase(b)
	check(not main.layout._bot_pile_of_uid.has(a), "这张不在任何摞里")

	main.phase = main.PHASE_ATTACK
	main.board.attack_mode = true
	# 点数给到远超一张的量：花不完才说明「点一张只扣一张」
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var pool := per_card * 9
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, pool)
	await main._on_attack_clicked(main.entities[a])
	await settle()
	check(int(state.resource_count(GameState.BOT, CardDB.RES_USER)) == 1,
		"只扣了 1 张（剩 %d）" % int(state.resource_count(GameState.BOT, CardDB.RES_USER)))
	check(int(main._attack_pools["user"]) == pool - per_card,
		"只花 %d 点（剩 %d）" % [per_card, int(main._attack_pools["user"])])
	main.board.attack_mode = false
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, 0)

# ---------- B7. 点数点不完一摞：扣到花光为止，不是整摞拒点 ----------

func _b7_pile_partial_then_stop(main: Node) -> void:
	print("--- B7. 点数只够一部分：扣掉够得着的，剩下的留着，不报「点数不够」---")
	var state: GameState = main.state
	state.players[GameState.BOT]["cards"].clear()
	state.combos = state.combos.filter(func(c): return c["owner"] != GameState.BOT)
	for u in main.entities.keys():
		if state.find_card(GameState.BOT, u).is_empty() and main.layout._bot_pile_of_uid.has(u):
			main.layout._bot_pile_of_uid.erase(u)
	state.add_card(GameState.BOT, "user")   # 吊命，见 B5 那条注释
	# 摆几张现金是判据自己的规模：这一节量的是「点得起 / 点不起」的分界，
	# 只要多于下面那一点点数就够（点掉一张之后还剩得下）
	var n_cash := 4
	for i in n_cash:
		state.add_card(GameState.BOT, "cash")
	main._sync_entities()
	main.layout._layout_bot_zone()
	await settle()
	var key: Variant = null
	for k in main.layout._bot_pile_uids:
		if main.layout._bot_pile_uids[k].size() == n_cash:
			key = k
	check(key != null, "%d 张现金一摞" % n_cash)
	if key == null:
		return

	main.phase = main.PHASE_ATTACK
	main.board.attack_mode = true
	# 给「刚好点掉一张」的点数：一张的价钱是 `_game.attack_cost_per_card`
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	main.pipe.applier().seed_pool_for_test(main.my_seat, per_card, 0)
	await main._on_attack_clicked(main.entities[main.layout._bot_pile_uids[key][0]])
	await settle()
	check(int(state.resource_count(GameState.BOT, CardDB.RES_CASH)) == n_cash - 1,
		"%d 点扣 1 张（剩 %d，应为 %d）" % [
			per_card, int(state.resource_count(GameState.BOT, CardDB.RES_CASH)), n_cash - 1])

	# 池子空了再点：这一下才该是「点不起」，且一张都不许扣。
	# 还得给个说法 —— 一摞点不动又不吭声，玩家只会以为点击没被收到，
	# 接着一直点下去（摞收拢之后张数只在侧边写着，看不出扣没扣）
	var before := int(state.resource_count(GameState.BOT, CardDB.RES_CASH))
	main.pipe.applier().seed_pool_for_test(main.my_seat, 0, 0)
	main.lbl_msg.text = ""
	await main._on_attack_clicked(main.entities[main.layout._bot_pile_uids[key][0]])
	await settle()
	check(int(state.resource_count(GameState.BOT, CardDB.RES_CASH)) == before,
		"0 点点这一摞：一张都没扣（%d → %d）" % [
			before, int(state.resource_count(GameState.BOT, CardDB.RES_CASH))])
	check(main.lbl_msg.text != "", "点不动这一摞会给提示，不是静默（提示「%s」）" % main.lbl_msg.text)
	main.board.attack_mode = false

# ---------- 工具 ----------

func _mk(at: Vector2, pressed: bool, dbl: bool = false) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = at
	ev.double_click = dbl
	return ev

## 一次按下。dbl 只控制**系统**双击标志：默认不给，
## 走的正是 macOS 那条「标志不来、靠 _is_double 自己认」的路
func _press(board: Board, at: Vector2, dbl: bool = false) -> void:
	board._unhandled_input(_mk(at, true, dbl))

## 在 at 松手。位移是拿松手事件的坐标和 _press_snap["at"] 比的（都在事件里，
## 不碰 get_viewport().get_mouse_position() —— 无头下那个恒为 (0, -350)），
## 所以同一个 at 就表达出了「光标没动」
func _release_at(board: Board, at: Vector2) -> void:
	board._unhandled_input(_mk(at, false))

## 一次完整的「点一下」：按下（当场拎牌）+ 原地松手（照快照精确复位）。
## 对桌面应当是空操作，双击的第一击走的就是这条路
func _click(board: Board, at: Vector2, dbl: bool = false) -> void:
	_press(board, at, dbl)
	_release_at(board, at)

## 远处松手 = 真拖了一段之后放手，走 _end_drag 的吸附
func _release(board: Board) -> void:
	board._unhandled_input(_mk(Vector2.ZERO, false))

func _screen_of(main: Node, c: CardEntity) -> Vector2:
	return main.get_node("Camera3D").unproject_position(c.global_position)

func _gsize(board: Board, c: CardEntity) -> int:
	var g: Variant = board.group_of(c)
	return 0 if g == null else int(g["cards"].size())

# ---------- B8. 两个方向的撕毁演出必须同一套、同速度 ----------

## 数声音得用替身。**不是因为 headless 下播不了** —— wav 是真加载得上的
## （配置里那 12 个流一个都不为 null，见 tests/test_config_complete.gd 的 T4），
## 只是听不见。用替身的原因是真 Sfx 那 10 格轮转池**会把旧的盖掉**：
## 这一节要数的是「一摞响了几声」，八声下去池子已经转过一轮，
## 从池子上只读得到最后那几声
##
## 按**音效名**记而不是按动作名：命中音和逐张拆除音是两个动作
## （attack / attack_tear，响度音高各一档），但玩家听到的是同一个 wav ——
## 这一节量的是「一摞响几声」，按动作名分开记就把同一串声音拆成了两笔
class CountingSfx extends Sfx:
	var counts := {}
	func play(action_name: String, pitch_scale := 1.0) -> void:
		var key := str(Sfx.action(action_name).get("sound", action_name))
		counts[key] = int(counts.get(key, 0)) + 1

## 同一件事（啃穿同一个 7 席组合）在两个方向上：声数、爆花朵数、耗时都要对上。
##
## **为什么必须量耗时**：撕牌用的是同一个函数（_tear_out）、同一个 TEAR_TIME，
## 光比「调的是不是同一个函数」永远是绿的 —— 修之前那一版也是绿的。
## 玩家 936ms / BOT 6323ms 的差全在外面那层节拍上（BOT 一条意图一拍
## BEAT_ATTACK_BOTM + BEAT_ATTACK_HIT = 0.9s，7 张就是 6.3s）
func _b8_tear_is_symmetric() -> void:
	print("--- B8. 玩家打对方 / BOT 打玩家：同一套演出、同一个速度 ---")
	var a := await _tear_one_side(true)
	var b := await _tear_one_side(false)
	print("    玩家点对手：命中音 %d 声，爆花 %d 朵，%d ms" % [a["atk"], a["burst"], a["ms"]])
	print("    BOT 点玩家：  命中音 %d 声，爆花 %d 朵，%d ms" % [b["atk"], b["burst"], b["ms"]])
	# 撕几张 = 靶摞的席位数（点数正好配满），从卡表推
	var seats := int(CardDB.get_def("shuabuting")["recipe_n"])
	check(a["torn"] == seats and b["torn"] == seats,
		"两边都啃掉 %d 张（A %d / B %d）" % [seats, a["torn"], b["torn"]])
	# 这一节按「响了几声同一个 wav」来数，前提是命中和逐张真共用一个 wav。
	# 哪天 attack_tear 换成自己的音效，下面那几个数会变成 1 和 seats，
	# 报出来的却是「声数不对」—— 先把前提钉在这儿，坏了直接说是配置改了
	check(str(Sfx.action("attack").get("sound", "")) == str(Sfx.action("attack_tear").get("sound", "")),
		"命中音和逐张拆除音共用一个 wav（_sfx.actions 里两个动作同 sound）")
	check(a["atk"] == 2, "玩家一批只响一次命中、一次撕纸（实 %d）" % a["atk"])
	check(b["atk"] == 2, "BOT 一批只响一次命中、一次撕纸（实 %d）" % b["atk"])
	check(a["burst"] == 1, "玩家侧 1 朵爆花（实 %d）" % a["burst"])
	check(b["burst"] == 1, "BOT 侧也只 1 朵，不是一张一朵（实 %d）" % b["burst"])
	var gap: float = absf(float(a["ms"]) - float(b["ms"]))
	check(gap < 300.0,
		"两边耗时相差 %d ms（<300；修之前是 936 vs 6323）" % int(gap))

func _tear_one_side(mine: bool) -> Dictionary:
	var main: Node = await boot_main()
	await settle()
	var fake := CountingSfx.new()
	main.add_child(fake)
	main.sfx = fake
	var state: GameState = main.state
	var victim: String = main.foe_seat if mine else main.my_seat
	var attacker: String = main.my_seat if mine else main.foe_seat

	# 靶摞的席位数 = 核心卡的配方量，点数按 `_game.attack_cost_per_card` 折算成
	# 「刚好啃光这一摞」。两个数都读配置：这一节量的是演出对称，不是某个张数
	var core_def: Dictionary = CardDB.get_def("shuabuting")
	var seats := int(core_def["recipe_n"])
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var uids: Array = [int(state.add_card(victim, "shuabuting", true)["uid"])]
	for i in seats:
		uids.append(int(state.add_card(victim, "user", true)["uid"]))
	check(state.create_combo(victim, uids)["ok"], "%d 席%s编得成（%s）" % [
		seats, core_def["name"], "对手侧" if mine else "我这侧"])
	main._sync_entities()
	main.layout._layout_bot_zone()
	await settle()
	await main._tears_drained()      # 摆场也会排撕牌，等干净再量

	fake.counts.clear()
	var burst0 := _n_particles(main)
	main.pipe.applier().seed_pool_for_test(attacker, 0, seats * per_card)
	main.phase = main.PHASE_ATTACK
	main._attack_pools = main.pipe.applier().pools(attacker)

	var t0 := Time.get_ticks_msec()
	if mine:
		main.board.attack_mode = true
		var key := ""
		for u in uids:
			var k := str(main.layout._bot_pile_of_uid.get(u, ""))
			if k != "":
				key = k
				break
		check(key != "", "找得到对手那一摞")
		if key != "":
			await main._attack_pile(key)
	else:
		await main._drive_bot_attack(attacker, main.pipe.applier().pools(attacker))
	var ms := Time.get_ticks_msec() - t0

	var left := 0
	for u in uids:
		if not state.find_card(victim, u).is_empty():
			left += 1
	return {
		# CountingSfx 按音效名记，attack / attack_tear 共用这一个 wav
		"atk": int(fake.counts.get(str(Sfx.action("attack").get("sound", "")), 0)),
		"burst": _n_particles(main) - burst0,
		"ms": ms,
		"torn": uids.size() - left,
	}

func _n_particles(main: Node) -> int:
	var n := 0
	for c in main.get_children():
		if c is CPUParticles3D:
			n += 1
	return n

# ---------- B9. 同批七张同时撕，不增加七次动画 ----------
func _b9_stagger_across_calls() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	await settle()
	await main._tears_drained()
	var uids: Array = []
	for i in 7:
		uids.append(int(main.state.add_card(main.my_seat, "user", true)["uid"]))
	main._sync_entities()
	await settle()
	await main._tears_drained()
	var count: int = main.table_hands.batch_count
	var dur: float = main._animate_removed(uids, false)
	check(absf(dur - 0.74) < 0.01, "七张与一张使用同一时长，不按张数排队")
	check(main.table_hands.batch_count == count + 1, "七张只创建一双撕纸手")
	check(main.table_hands._batches.back().count == 7, "一双手覆盖本批七张牌")
	for uid in uids:
		check(not main.entities.has(uid), "被移除的牌立即退出交互")
	await main._tears_drained()
