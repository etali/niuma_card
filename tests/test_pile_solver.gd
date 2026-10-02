# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 摞位求解器测试：engine/pile_solver.gd 的纯几何判定
## 运行：godot --headless -s tests/test_pile_solver.gd
##
## 造合成桌面，不起场景 —— 以前这些判定只能靠跑一整轮真实结算去间接观察
## （摞撞死了才在别的测试里露出来），现在能直接把「饱和带」摆出来问它要位置。
##
## **判据一律不读 PileSolver 自己的常量。** 判据读被测常量的话，改坏常量测试照样全绿
## （这条踩过：拿 PILE_TAKE_CLEAR_Z 当判据量避让，把它改成 1.8 一条不报）。
## 所以余量按 CardEntity.CARD_SIZE / Board.COMPACT_GAP / CardArt.BAND_FRAC 反算，
## 「不许漫进玩家地盘」按玩家现金堆的锚点判。
## 这条纪律只管**被测文件**（engine/pile_solver.gd）自己的常量：布局侧那两个
## （锚点、摞的份额）读 SettleLayout 的原件，各写一份才会和布局悄悄漂开

const PileSolver = preload("res://engine/pile_solver.gd")
const SettleLayout = preload("res://scenes/settle_layout.gd")

## 判据用的几何，全部来自被测代码之外
var CX: float = CardEntity.CARD_SIZE.x       # 卡宽
var CZ: float = CardEntity.CARD_SIZE.z       # 卡纵深
var GAP: float = Board.COMPACT_GAP.z         # 收拢摞每张往 +z 长这么多
var BAND: float = CardArt.BAND_FRAC * CardEntity.CARD_SIZE.z   # 标题带高
## 玩家的现金堆锚点（SettleLayout.PLAYER_PILE_CASH_ANCHOR）：
## 结算的摞漫过这条线就等于替玩家重排他的阵型
var PLAYER_X: float = SettleLayout.PLAYER_PILE_CASH_ANCHOR.x
var CHUNK: int = SettleLayout.PILE_CHUNK      # 结算按每份这么多张摞


func _initialize() -> void:
	print("=== 摞位求解器测试 ===\n")
	test_clearance_derivation()
	test_empty_desk()
	test_hard_avoid_single_pile()
	test_saturated_band_stays_in_zone()
	test_host_pile_same_kind_only()
	test_overlap_depth_is_continuous()
	test_loose_slots_never_collide()
	test_longest_pile()
	test_height_needs_global_order()
	test_height_is_current_layout()
	finish()

## 空桌面：几何填好，障碍全空
func _desk() -> PileSolver.Desk:
	var d := PileSolver.Desk.new()
	d.card_x = CX
	d.card_z = CZ
	d.pile_step = GAP
	d.stack_gap = Board.STACK_GAP.z
	d.band_frac = CardArt.BAND_FRAC
	d.longest_pile = CHUNK
	return d

var _uid := 0

## 往桌面上摆一摞（收拢态）。
## 三个数组都得填：main.layout._desk() 里一张摞里的卡同时进 cards（散牌避让和代价用）
## 和 pile_cards（硬障碍用），组本身进 piles。只填 pile_cards 的话
## loose_spot_free 那条根本看不见这摞，「饱和带」就假了
func _add_pile(d: PileSolver.Desk, origin: Vector3, n: int, def_id: String) -> Dictionary:
	var ref := { "tag": def_id + "@" + str(origin.z) }
	d.piles.append({ "origin": origin, "count": n, "def_id": def_id, "ref": ref })
	for i in n:
		var pos: Vector3 = origin + Vector3(0, 0, GAP * i)
		d.pile_cards.append(pos)
		_uid += 1
		d.cards.append({ "uid": _uid, "pos": pos })
	d.longest_pile = PileSolver.longest_pile(d.piles, CHUNK)
	return ref

## 一摞的占地（x 半宽 / z 从 origin 往 +z 长 n-1 层）
func _footprint(origin: Vector3, n: int) -> Array:
	return [
		origin.x - CX / 2.0, origin.x + CX / 2.0,
		origin.z - CZ / 2.0, origin.z + CZ / 2.0 + GAP * float(n - 1),
	]

## 两个占地是否相交
func _overlap(a: Array, b: Array) -> bool:
	return a[0] < b[1] and a[1] > b[0] and a[2] < b[3] and a[3] > b[2]


## T1. 摞跟摞的避让余量必须够一整摞的纵深。
## 判据从 CardEntity/Board/PILE_CHUNK 反算，不读 PILE_TAKE_CLEAR_Z ——
## 这一条就是为了在那个常量被改小时报出来（拿一张卡的 1.8 去量会压掉 0.35）
func test_clearance_derivation() -> void:
	print("--- T1. 判定框够不够一摞的占地 ---")
	var need: float = CZ + GAP * float(CHUNK - 1)
	check(PileSolver.PILE_TAKE_CLEAR_Z >= need,
		"摞的 z 余量 %.2f ≥ 一摞实际占地 %.2f（%.1f + %.3f×%d）"
		% [PileSolver.PILE_TAKE_CLEAR_Z, need, CZ, GAP, CHUNK - 1])
	check(PileSolver.PILE_CLEAR_X >= CX,
		"摞的 x 余量 %.2f ≥ 卡宽 %.1f（贴边挨着不算「不重叠」）"
		% [PileSolver.PILE_CLEAR_X, CX])
	# 列间距必须大于卡宽，否则相邻两列本身就压着，「挑到不同列」也没用
	check(PileSolver.PILE_SLOT_X_STEP > CX,
		"列间距 %.1f > 卡宽 %.1f（不同列压不着）"
		% [PileSolver.PILE_SLOT_X_STEP, CX])


## T2. 空桌面：摞落在锚点上，散牌按步长排开
func test_empty_desk() -> void:
	print("--- T2. 空桌面 ---")
	var anchor := Vector3(-11.7, 0.05, 1.0)
	var spot := PileSolver.slot_for_pile(_desk(), anchor, [])
	check(spot.is_equal_approx(anchor),
		"空桌面上一摞就落在锚点（得到 %s）" % str(spot))

	var step: float = Board.STACK_GAP.z
	var loose: Array = []
	var spots: Array = PileSolver.loose_slots(_desk(), 5, step, anchor, [], {}, [], loose)
	check(spots.size() == 5, "要 5 个散牌位，给了 %d 个" % spots.size())
	var min_gap := INF
	for i in spots.size():
		for j in range(i + 1, spots.size()):
			if absf(spots[i].x - spots[j].x) < 0.01:
				min_gap = minf(min_gap, absf(spots[i].z - spots[j].z))
	check(min_gap >= step * 0.9,
		"同一列里两张散牌至少隔 %.2f（实测最近 %.2f）" % [step * 0.9, min_gap])


## T3. 桌上已有一摞：新摞的占地不许和它相交。
## 判据是两个占地矩形相交与否 —— 纯几何，和求解器怎么挑无关
func test_hard_avoid_single_pile() -> void:
	print("--- T3. 硬避让已有的摞 ---")
	var anchor := Vector3(-11.7, 0.05, 1.0)
	var d := _desk()
	_add_pile(d, anchor, CHUNK, "cash")
	var spot := PileSolver.slot_for_pile(d, anchor, [])
	check(not spot.is_equal_approx(anchor), "新摞没落在旧摞的坐标上（%s）" % str(spot))
	check(not _overlap(_footprint(spot, CHUNK), _footprint(anchor, CHUNK)),
		"两摞占地不相交：新 %s ×旧 %s" % [str(spot), str(anchor)])

	# taken（本批刚发出去、牌还在补间路上的落点）同样得躲
	var d2 := _desk()
	var spot2 := PileSolver.slot_for_pile(d2, anchor, [anchor])
	check(not _overlap(_footprint(spot2, CHUNK), _footprint(anchor, CHUNK)),
		"也躲开 taken 里的落点：%s" % str(spot2))

	# 「宁可挤在散牌堆里，也不压在摞上」：光比代价挑不出这一条 ——
	# 压在一个满份摞上按每张 1 分算，和「被同样多张散牌占着」的空档同价甚至更便宜，
	# 于是新摞真的落在旧摞的坐标上，逐层撞死。
	# 所以这里把摞外的格子故意堆得更贵（15 张散牌），只有硬避让那一轮才躲得开
	var d3 := _desk()
	_add_pile(d3, anchor, CHUNK, "cash")
	for i in 15:
		_uid += 1
		d3.cards.append({ "uid": _uid, "pos": Vector3(anchor.x, anchor.y, 3.3) })
	var spot3 := PileSolver.slot_for_pile(d3, anchor, [], {}, [anchor.x])
	check(not _overlap(_footprint(spot3, CHUNK), _footprint(anchor, CHUNK)),
		"摞外的格子更贵也不压在摞上：落在 %s（旧摞 %s）" % [str(spot3), str(anchor)])


## T4. 饱和带（三列各两摞 = 60 张）：位置挑不出空的了，但绝不许漫进玩家地盘。
## 「挤不下宁可压着，也不能占玩家摆阵型的地方」是这一段的定位
func test_saturated_band_stays_in_zone() -> void:
	print("--- T4. 饱和带不漫进玩家地盘 ---")
	var cols := [-11.7, -10.3, -8.9]
	var anchor := Vector3(cols[0], 0.05, 0.0)
	var d := _desk()
	for x in cols:
		_add_pile(d, Vector3(x, 0.05, 0.0), CHUNK, "cash")
		_add_pile(d, Vector3(x, 0.05, 2.4), CHUNK, "cash")
	var spot := PileSolver.slot_for_pile(d, anchor, [], {}, cols)
	check(spot.x + CX / 2.0 < PLAYER_X,
		"挤不下也没漫到玩家现金堆（x=%.2f，玩家锚点 %.1f）" % [spot.x, PLAYER_X])
	check(spot.z >= PileSolver.PILE_SLOT_Z_MIN and spot.z <= PileSolver.PILE_SLOT_Z_MAX,
		"z=%.2f 在 board 给玩家卡的钳制范围内（越界会被一律钳到 0，几摞落成同一处）"
		% spot.z)
	# 给 col_xs 就只许在这三列上，不许沿 anchor.x 往右漫进另一批的列
	var on_col := false
	for x in cols:
		if absf(spot.x - float(x)) < 0.001:
			on_col = true
	check(on_col, "落在指定的三列之一（x=%.2f）" % spot.x)


## T5. 只往同种卡的摞里并。
## 两种资源混一摞就分不清该付哪一摞（玩家按摞付账）
func test_host_pile_same_kind_only() -> void:
	print("--- T5. 并摞只认同种卡 ---")
	var spot := Vector3(-11.7, 0.05, 1.0)
	var d := _desk()
	var cash_ref := _add_pile(d, spot, CHUNK, "cash")
	check(PileSolver.host_pile(d, spot, "cash") == cash_ref, "同种卡：认出脚下那一摞")
	check(PileSolver.host_pile(d, spot, "user") == null, "异种卡：不认（宁可不并）")
	var far := Vector3(-11.7, 0.05, 4.6)
	check(PileSolver.host_pile(d, far, "cash") == null,
		"隔着一摞的余量之外就不算压着它了（z=%.1f）" % far.z)


## T6. 压得多深是连续量，不是真假。
## 「错开半个身位的两摞看得出是两摞，重合的两摞看着就是一摞」——
## 真假量筛不出「最不坏的那一格」，所以这里钉住单调性
func test_overlap_depth_is_continuous() -> void:
	print("--- T6. 压深是连续量 ---")
	var origin := Vector3(-11.7, 0.05, 1.0)
	var d := _desk()
	_add_pile(d, origin, CHUNK, "cash")
	var span: float = GAP * float(CHUNK - 1)
	var center := origin + Vector3(0, 0, span / 2.0)
	var d0: float = PileSolver.overlap_depth(d, center)
	var d1: float = PileSolver.overlap_depth(d, center + Vector3(0, 0, 1.0))
	var d2: float = PileSolver.overlap_depth(d, center + Vector3(0, 0, 2.0))
	var d3: float = PileSolver.overlap_depth(d, center + Vector3(0, 0, 9.0))
	check(d0 > d1 and d1 > d2, "越靠摞心压得越深：%.3f > %.3f > %.3f" % [d0, d1, d2])
	check(is_equal_approx(d3, 0.0), "离远了就是 0（%.3f）" % d3)
	check(d0 > 0.9, "坐标重合时接近 1（%.3f）" % d0)

	# 玩家自己摊开的组加倍计价：压在他的组上没有补救路径。
	# 判据取倍率而不是「大于」：同样是坐标重合，两边算出来都在 1.0 附近，
	# Vector3 是 32 位浮点、标量是 64 位，d0 实际是 0.9999…，
	# 「1.0 > 0.9999」这种比较去掉倍率照样成立（试过，那条变异全绿）
	var dp := _desk()
	dp.spreads.append(center)
	var dep: float = PileSolver.overlap_depth(dp, center)
	check(dep > d0 * 1.5,
		"压玩家的摊开组比压摞贵一倍：%.3f > %.3f×1.5" % [dep, d0])


## T7. 饱和带上要 CHUNK-1 张散牌的位：一个都不能少，且两两不许坐标撞车。
## 撞车在屏幕上看着就是少了几张。间距下限取标题带高（每张仍露出自己的标题带，
## 看得出是几张）—— 判据按 CardArt.BAND_FRAC × 卡纵深 反算
func test_loose_slots_never_collide() -> void:
	print("--- T7. 饱和带上的散牌不撞车 ---")
	var cols := [-11.7, -10.3, -8.9]
	var anchor := Vector3(cols[0], 0.05, 0.0)
	var d := _desk()
	for x in cols:
		_add_pile(d, Vector3(x, 0.05, 0.0), CHUNK, "cash")
		_add_pile(d, Vector3(x, 0.05, 2.4), CHUNK, "cash")
	# 一次至多要 PILE_CHUNK-1 格（见 settle_layout._lay_loose_run 的三个调用点）
	var n := CHUNK - 1
	var loose: Array = []
	var spots: Array = PileSolver.loose_slots(d, n, Board.STACK_GAP.z, anchor,
		[], {}, cols, loose)
	check(spots.size() == n, "要 %d 个位，给了 %d 个（一张都不能省）" % [n, spots.size()])
	var worst := INF
	var clash := 0
	for i in spots.size():
		for j in range(i + 1, spots.size()):
			if absf(spots[i].x - spots[j].x) < 0.01:
				var dz: float = absf(spots[i].z - spots[j].z)
				worst = minf(worst, dz)
				if dz < BAND:
					clash += 1
	check(clash == 0, "同列两张的间距都 ≥ 标题带高 %.4f（实测最近 %.4f，撞车 %d 对）"
		% [BAND, worst, clash])

	# 连着排两批共用一个 loose_io：后一批必须躲开前一批
	var d2 := _desk()
	var loose2: Array = []
	var first: Array = PileSolver.loose_slots(d2, 4, Board.STACK_GAP.z, anchor,
		[], {}, cols, loose2)
	var second: Array = PileSolver.loose_slots(d2, 4, Board.STACK_GAP.z, anchor,
		[], {}, cols, loose2)
	var dup := 0
	for a in first:
		for b in second:
			if a.is_equal_approx(b):
				dup += 1
	check(dup == 0, "两批共用 loose_io 时不落在同一格（重复 %d 处）" % dup)

	# mine：正要重排的这批卡，自己现在站的地方不算障碍。
	# 不排掉的话它们把自己的目标格判成占用，于是被推到更外面 ——
	# 场景里这条只体现成「余数多散一张、带子宽一点」，越不过
	# 「不重叠 / 不出界」那几条判据（实测：去掉 mine，test_arrivals 仍全绿，
	# 只有余数 8→9、垫高 2.375→2.399）。所以在这儿直接按定义判
	var d3 := _desk()
	var here := Vector3(cols[0], 0.05, 1.2)
	_uid += 1
	var my_uid := _uid
	d3.cards.append({ "uid": my_uid, "pos": here })
	var free_mine: bool = PileSolver.loose_spot_free(d3, here, [],
		{ my_uid: true }, [])
	var free_not: bool = PileSolver.loose_spot_free(d3, here, [], {}, [])
	check(free_mine, "自己正站着的那一格算空的（mine 里排掉了）")
	check(not free_not, "别人站着的同一格算占用（不在 mine 里）")


## T8. 避让余量按桌上**实际**最长的那一摞算，不按 PILE_CHUNK。
## 带子满了以后摞会一直往里并（已不封顶），按满份那 CHUNK-1 层算避让就短了一半，
## 余数正好压在并出来的那半截上
func test_longest_pile() -> void:
	print("--- T8. 最长的摞 ---")
	check(PileSolver.longest_pile([], CHUNK) == CHUNK,
		"空桌面按下限 %d 算" % CHUNK)
	var piles := [{ "count": 4 }, { "count": 20 }, { "count": 7 }]
	check(PileSolver.longest_pile(piles, CHUNK) == 20,
		"并成 20 的那一摞算 20，不是 %d" % CHUNK)

	# 并出来的长摞比满份摞多出的那几层各长一个 GAP，散牌得躲开这半截
	var origin := Vector3(-11.7, 0.05, 0.0)
	var d := _desk()
	_add_pile(d, origin, 20, "cash")
	var tail_z: float = origin.z + GAP * 19.0 + CZ / 2.0
	var loose: Array = []
	var spots: Array = PileSolver.loose_slots(d, 1, Board.STACK_GAP.z, origin,
		[origin], {}, [origin.x], loose)
	check(spots[0].z - CZ / 2.0 >= tail_z - 0.001 or spots[0].z + CZ / 2.0 <= origin.z - CZ / 2.0,
		"散牌躲开 20 张摞的尾巴（摞尾 z=%.3f，散牌 z=%.3f）" % [tail_z, spots[0].z])


## 一摞的座位（每张卡占的 x/z）
func _seats(origin: Vector3, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({ "x": origin.x, "z": origin.z + GAP * i })
	return out

## 跑一趟「按序定高度」，把算出来的高度写回快照（模拟 main.layout._settle_pile_heights）。
## 返回这一趟里最高的顶面
func _settle_once(d: PileSolver.Desk) -> float:
	var top := 0.0
	for i in d.piles.size():
		var pile: Dictionary = d.piles[i]
		var origin: Vector3 = pile["origin"]
		var n: int = int(pile["count"])
		var want: float = PileSolver.floor_for_pile(d, _seats(origin, n), int(pile["gi"]))
		pile["origin"] = Vector3(origin.x, want, origin.z)
		top = maxf(top, want)
	return top


## T9. 定高度必须有全局次序，否则两摞互相往上顶、反复算就发散。
##
## 这一条以前只能靠跑十轮真实结算才看得见（实测顶面涨到 y=509）。
## 判据：反复结算必须收敛 —— 第二趟起高度不再变
func test_height_needs_global_order() -> void:
	print("--- T9. 定高度限序才收敛 ---")
	# 两摞占地重叠（错开一个网格步长 0.6，远小于卡纵深 1.7），且不同种资源
	var d := _desk()
	_add_pile(d, Vector3(-11.7, 0.05, 1.0), CHUNK, "cash")
	_add_pile(d, Vector3(-11.7, 0.05, 1.6), CHUNK, "user")
	d.piles[0]["gi"] = 0
	d.piles[1]["gi"] = 1

	var first: float = _settle_once(d)
	var tops: Array = [first]
	for _i in 9:
		tops.append(_settle_once(d))
	check(is_equal_approx(tops[0], tops[9]),
		"十趟结算高度不变（首趟 %.3f，末趟 %.3f）" % [tops[0], tops[9]])
	check(tops[9] < 1.0,
		"顶面有界（%.3f < 1.0）—— 不限序时实测能涨到 509" % tops[9])
	# 序号小的那摞不动，后来的落在它上面：和玩家看到的因果一致
	check(is_equal_approx(float(d.piles[0]["origin"].y), d.table_y),
		"先在桌上的那摞贴桌不动（y=%.3f）" % d.piles[0]["origin"].y)
	check(float(d.piles[1]["origin"].y) > float(d.piles[0]["origin"].y),
		"后来的那摞落在它上面（%.3f > %.3f）"
		% [d.piles[1]["origin"].y, d.piles[0]["origin"].y])


## T10. 抬升只抬一级台阶，且是「当前布局的函数」——
## 身下的结构没了，高度就该自己落回桌面，不留残值
func test_height_is_current_layout() -> void:
	print("--- T10. 高度按现状重算 ---")
	var lower := Vector3(-11.7, 0.05, 1.0)
	var d := _desk()
	_add_pile(d, lower, CHUNK, "cash")
	_add_pile(d, Vector3(-11.7, 0.05, 1.6), CHUNK, "user")
	d.piles[0]["gi"] = 0
	d.piles[1]["gi"] = 1
	_settle_once(d)
	var lifted: float = d.piles[1]["origin"].y
	# 只抬一级台阶：身下那摞的顶面 + ladder1
	var want: float = lower.y + Board.COMPACT_GAP.y * float(CHUNK - 1) + Board.ladder_y(1)
	check(is_equal_approx(lifted, want),
		"抬到身下那摞的顶 + 一级台阶（%.3f，期望 %.3f）" % [lifted, want])

	# 把身下那摞撤掉（被并走 / 被解散重排），高度必须自己落回桌面
	d.piles.remove_at(0)
	d.pile_cards.clear()
	d.cards.clear()
	d.piles[0]["gi"] = 0
	_settle_once(d)
	check(is_equal_approx(float(d.piles[0]["origin"].y), d.table_y),
		"身下空了就落回桌面（y=%.3f）—— 抬升不是摆放历史的残留"
		% d.piles[0]["origin"].y)

	# 没压着任何东西的摞就贴桌
	var d2 := _desk()
	var solo: float = PileSolver.floor_for_pile(d2, _seats(lower, CHUNK), -1)
	check(is_equal_approx(solo, d2.table_y), "空桌面上的摞贴桌（%.3f）" % solo)
