# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 摞位求解器：给一批要落地的牌/摞挑坐标。
##
## 纯几何 —— 不碰场景树、不读 board、不读 entities，输入是一份 Desk 快照，
## 输出是坐标。所以能 headless 直接单测（tests/test_pile_solver.gd 造合成桌面，
## 不用起整个场景），而以前这些判定只能靠跑真实结算去间接观察。
##
## 调用方（scenes/main.gd）负责两件事：把桌面拍成 Desk、把算出来的坐标真正搬过去。


## ---------- 落点网格 ----------
## 候选格子按 0.6 的细步长走，比一张卡（1.2×1.7）小得多：左边这一条本来就窄
## （玩家的现金堆锚在 x=-8.0，再往右就是他自己的阵型），按整张卡跳着找
## 一列只有两三个落点，多半全被占着。细步长能钻进已有卡之间的缝里
const PILE_SLOT_Z_STEP := 0.6
## z 的上下界必须和 board 给玩家卡的钳制范围对齐（player_min_z=0 / player_max_z=5.2，
## 见 main._ready 里的赋值）：越界的候选位会被 _layout_group 一律钳到 z=0，
## 于是「好几个不同的格子」落成同一处，摞跟摞叠在一起 —— 挑位置的时候就得认这条线。
## 上限再让出一个收拢摞的纵深（满份摞 = (PILE_CHUNK-1) × Board.COMPACT_GAP.z），
## 免得整摞被推回来
const PILE_SLOT_Z_MIN := 0.0
const PILE_SLOT_Z_MAX := 4.7
const PILE_SLOT_X_STEP := 1.4
## 横向只让漂这几列：「放在屏幕左边」是这批摞的定位，挤不下宁可在左边多排几列，
## 也不能一路走到桌子中央 —— 那儿是玩家自己摆阵型的地方，占了就等于替他重排了
const PILE_SLOT_COLS := 3

## ---------- 判定框 ----------
## 判定框要比卡本身（1.2×1.7，见 CardEntity.CARD_SIZE）宽一点，
## 不然贴边挨着也算「不重叠」
const PILE_CLEAR_X := 1.3
const PILE_CLEAR_Z := 1.8
## 量「摞跟摞」得用摞的占地，不是一张卡的：摞从锚点往 +z 长，
## 1.7 + COMPACT_GAP.z×(PILE_CHUNK-1) = 2.15 → 取 2.3。拿 1.8 去量会压掉 0.35。
## 这条推导由 test_pile_solver 的 T1 盯着（拿 CardEntity/Board 的常量反算，
## 不读本文件的常量，否则改坏了测试照样全绿）
const PILE_TAKE_CLEAR_Z := 2.3


## 桌面快照。求解器只认这份数据，不认场景。
##
## 为什么要快照：board._group_origin() 内部会 _stop_move 把补间按到终点，
## 也就是说「读一下位置」这件事本身有副作用。求解一轮里要读几十次，
## 边算边读等于让判定结果依赖读取顺序 —— 一次拍好，之后只算不读
class Desk:
	extends RefCounted

	## 桌上可拖的卡：[{uid:int, pos:Vector3}]，含已经在摞/组里的。
	## 已排掉购牌区的和不可拖的，**没有**排掉正要摆的那一批 —— 那批按 skip/mine
	## 在每次调用时排，因为一次快照要服务好几批
	## （见 main._stack_settled 连着两次 _lay_loose_run）
	var cards: Array = []
	## 收拢摞：[{origin:Vector3, count:int, def_id:String, ref:Variant, gi:int}]。
	## ref 是场景层的组字典，求解器一律不碰，只在 host_pile() 里原样交回去。
	## gi 是它在 board.groups 里的序号 —— 定高度要限序，见 top_under()
	var piles: Array = []
	## 收拢摞里每一张卡的实际坐标。pile_overlaps() 用它而不用 origin：
	## 那一条判的是「硬障碍」，逐张量比按 origin+span 推更保守
	var pile_cards: Array = []
	## 玩家自己摊开的组里的卡（不含本代码收的余数组）。只参与软避让
	var spreads: Array = []

	## 几何来自 CardEntity / Board，由调用方填 —— 求解器不 preload 场景脚本
	var card_x := 1.2
	var card_z := 1.7
	## 收拢摞每多一张往 +z 长这么多（Board.COMPACT_GAP.z）
	var pile_step := 0.045
	## 标题带高占卡高（CardArt.BAND_FRAC）。挤到最后一档时的间距下限
	var band_frac := 0.15625
	## 桌上**实际**最长的那一摞有几张，至少按 PILE_CHUNK 算（见 longest_pile()）
	var longest_pile := 10

	## 同批散牌之间的默认间距（Board.STACK_GAP.z）
	var stack_gap := 0.52
	## 收拢摞每多一张往上抬这么多（Board.COMPACT_GAP.y）。定高度时要算摞的顶面
	var pile_step_y := 0.045
	## 一级台阶（Board.ladder_y(1)）。两张占地重叠的卡至少差这么多才不穿模
	var ladder1 := 0.024
	## 贴桌静止高度：身下什么都没压着的摞就落在这儿（SETTLE_CASH_ANCHOR.y）
	var table_y := 0.05


## 这些位置底下压着的摞，顶面在多高（没压着摞就返回 0）。
##
## 返回值已经含一级台阶：调用方直接拿它当地板，落上去的那张就在摞顶之上
## 一个 ladder1，不会和摞顶那张撞在同一层。
##
## limit：只量序号（gi）< limit 的摞（-1 = 全量）。
## 摞给自己定高度时必须限序，否则两摞占地互相重叠就会互相往上顶 ——
## A 要落在 B 上、B 要落在 A 上，反复算就发散（实测十轮后顶面到 y=509）。
## 限成「只许落在序号更小的摞上面」就是严格偏序，没有环、一趟收敛。
## 序号 = 入组顺序，所以「先在桌上的那摞不动，后来的落在它上面」，
## 和玩家看到的因果一致。散牌那两处调用不限序（-1）：散牌要躲开所有摞
static func top_under(desk: Desk, seats: Array, limit := -1) -> float:
	var top := 0.0
	for pile in desk.piles:
		if limit >= 0 and int(pile["gi"]) >= limit:
			continue
		var n: int = int(pile["count"])
		if n < 1:
			continue
		var origin: Vector3 = pile["origin"]
		# 摞从 origin 往 +z 长 pile_step*(n-1)，两头各半张卡
		var z_lo: float = origin.z - desk.card_z / 2.0
		var z_hi: float = origin.z + desk.pile_step * float(n - 1) + desk.card_z / 2.0
		for seat in seats:
			if absf(float(seat["x"]) - origin.x) >= desk.card_x:
				continue
			var sz: float = float(seat["z"])
			if sz - desk.card_z / 2.0 >= z_hi or sz + desk.card_z / 2.0 <= z_lo:
				continue
			top = maxf(top, origin.y + desk.pile_step_y * float(n - 1) + desk.ladder1)
			break
	return top


## 这一摞现在该落多高。只算，不动牌（搬的活儿见 main._settle_pile_heights）。
##
## 为什么摞会离桌：带子满了，而这一摞和身下那摞**不是同种资源**，
## 不能并成一摞（玩家按摞付账，混了分不清该付哪摞，见 host_pile）。
## 这时候两摞最多错开一个网格步长 0.60，远小于卡的纵深 1.7，占地照样重叠，
## 两摞都从 table_y 起排自己的台阶，于是十层逐层对撞
## （实测 摞#15×摞#16 十对 Δy=0.000 全穿）。身下也可能是玩家自己编的摊开组
## —— 那种一张都不许动（见 main.gd 的硬约束），也并不进去，
## 只剩「摞落在它上面」这条路。
##
## 高度是**当前布局的函数**，不是摆放历史的残留。在摆下那一刻抬一次、之后
## 再不回头的话，垫在身下的结构被并走或被重排之后抬升还留着：
## 实测十轮结算后有两摞常驻悬空（摞#12 底面 1.379，身下什么都没有），
## 屏幕上就是一摞牌离桌浮着。每次结算都按现状重算，落差自然消掉。
##
## 有界：只抬「身下那个结构的顶 + 一级台阶」，不递归、不累积。
## limit 见 top_under() —— 没有它这件事会发散
static func floor_for_pile(desk: Desk, seats: Array, limit: int) -> float:
	var top: float = top_under(desk, seats, limit)
	# 身下也可能压着玩家自己编的摊开组。那种组一张都不许动（见硬约束），
	# 又不是摞、并不进去，所以只剩「摞抬上去」这一条路
	# （实测 摞#12 压在 玩家组#5 上，Δy=0.003，之前一直穿着）。
	# 摊开组的 z 不规整，只能逐张量
	for p in desk.spreads:
		for seat in seats:
			if absf(p.x - float(seat["x"])) >= desk.card_x \
					or absf(p.z - float(seat["z"])) >= desk.card_z:
				continue
			top = maxf(top, p.y + desk.ladder1)
			break
	# 贴桌高度是下限：身下什么都没有的摞就落在桌上
	return maxf(desk.table_y, top)


## 桌上最长的那一摞有几张，至少 floor_n 张。
##
## 避让余量要按真实长度留：摞会往里并（带子满了的降级，见 main._stack_arrivals），
## 按固定张数估会把「摞并长出来的那半截」漏在余量外面
static func longest_pile(piles: Array, floor_n: int) -> int:
	var n: int = floor_n
	for p in piles:
		n = maxi(n, int(p["count"]))
	return n


## 这个位置有多挤：算压着几张卡 / 几摞。0 = 全空。
## 同批已占的位置算重价 —— 新摞之间绝不能互相压，
## 压在旧卡上还看得出是两摞，压在自己人身上就成一坨了。
##
## skip —— 正要摆的这批卡的 uid。它们刚被 _sync_entities 生在玩家区，
## 站的地方常常正是要去的地方；不排掉就成了「自己挡自己」，
## 明明空着的格子被判定为占用，最后挤到最边上去
static func spot_cost(desk: Desk, spot: Vector3, taken: Array,
		skip: Dictionary = {}) -> float:
	var cost := 0.0
	for t in taken:
		if absf(t.x - spot.x) < PILE_CLEAR_X and absf(t.z - spot.z) < PILE_TAKE_CLEAR_Z:
			cost += 10.0
	for s in desk.cards:
		if skip.has(s["uid"]):
			continue
		var p: Vector3 = s["pos"]
		if absf(p.x - spot.x) < PILE_CLEAR_X and absf(p.z - spot.z) < PILE_CLEAR_Z:
			cost += 1.0
	return cost


## spot 上摆一摞，会不会和已经放下的摞压在一起。
##
## 已有的摞有两个来源：taken（本批刚发出去的落点，牌还在补间路上，读坐标读不到）
## 和桌上收拢态的组（上几轮结算/典当留下的）。两者都得认 —— 只认 taken 的话，
## 隔一轮再结算就会照着老摞的位置再发一次。
##
## 量的是「摞的占地」而不是「一张卡的占地」：摞从落点往 +z 长，满份收拢摞的
## 纵深是 Board.COMPACT_GAP.z × (PILE_CHUNK-1)，实际占地是卡的 z 深再加这一截，
## 所以 z 方向用 PILE_TAKE_CLEAR_Z 而不是卡的 z 深（见那两个常量的注释）
##
## 只把「摞」当硬障碍。玩家自己编的摊开组也该躲（我们一张都不许动它，
## 压上去没有补救路径），但**不能当硬障碍**：带子里本来就散着玩家的组，
## 全算死格子的话 hard 一轮几乎必然落空，摞被挤出结算带
## （实测有一摞跑到 x=0.5 —— 玩家地盘）。
## 躲它的事交给软挑的 overlap_depth()：那是连续量，
## 只影响「同样都压着时先压谁」，不会让位置挑不出来
static func pile_overlaps(desk: Desk, spot: Vector3, taken: Array) -> bool:
	for t in taken:
		if absf(t.x - spot.x) < PILE_CLEAR_X and absf(t.z - spot.z) < PILE_TAKE_CLEAR_Z:
			return true
	for p in desk.pile_cards:
		if absf(p.x - spot.x) < PILE_CLEAR_X and absf(p.z - spot.z) < PILE_TAKE_CLEAR_Z:
			return true
	return false


## 这一格压在已有的摞上有多深：0 = 完全不压，1 = 和某一摞坐标完全重合。
## 压着好几摞就累加。
##
## 给 slot_for_pile() 的软挑那一轮排序用。带子满了的时候「压不压」已经没有选择了，
## 但「压多深」还有：错开半个身位的两摞看得出是两摞，重合的两摞在屏幕上
## 就是一摞，玩家按它付账会付错。所以要的是一个连续量，不是 pile_overlaps()
## 那样的真假 —— 真假只能筛掉全空的格子，筛不出「最不坏的那一格」
static func overlap_depth(desk: Desk, spot: Vector3) -> float:
	var depth := 0.0
	# 搬不动的摊开组：hard 一轮已经把它们当障碍挡掉了，但带子满了会退回软挑，
	# 那时候还得按「压得多深」躲。它们的 z 是逐格避让挑出来的、不规整，
	# 没法用 origin+span 推，逐张按卡的占地量（这些牌早就站定了，坐标读得准）
	for p in desk.spreads:
		var d1: float = absf(p.x - spot.x)
		var d2: float = absf(p.z - spot.z)
		if d1 >= PILE_CLEAR_X or d2 >= PILE_TAKE_CLEAR_Z:
			continue
		# 加倍计价：压在摞上还能靠合并/错位补救，压在玩家的组上没得补救
		depth += 2.0 * (1.0 - d1 / PILE_CLEAR_X) * (1.0 - d2 / PILE_TAKE_CLEAR_Z)
	for pile in desk.piles:
		var origin: Vector3 = pile["origin"]
		var dx: float = absf(origin.x - spot.x)
		if dx >= PILE_CLEAR_X:
			continue
		# 摞的中心在 origin 往 +z 半个身长处
		var span: float = desk.pile_step * float(int(pile["count"]) - 1)
		var dz: float = absf(origin.z + span / 2.0 - spot.z)
		var reach: float = PILE_TAKE_CLEAR_Z + span / 2.0
		if dz >= reach:
			continue
		depth += (1.0 - dx / PILE_CLEAR_X) * (1.0 - dz / reach)
	return depth


## spot 上已经压着的那一摞（收拢态、且和 def_id 同一种卡），没有就 null。
## 返回的是快照里那条 pile 的 ref，也就是调用方给进来的组字典原物。
##
## 带子满了的时候要往它里头并，而不是在它头上再摆一摞：
## 一摞占 PILE_TAKE_CLEAR_Z=2.3 的纵深，z 只有 PILE_SLOT_Z_MAX=4.7，
## 一列放得下两摞，三列一共 6 摞 = 60 张。再多就没地方了，而
## 「没地方」按代价函数挑出来的结果是**落在旧摞的坐标上**，两摞每一层都撞死
## （实测 (-10.30,0.455,1.35) 两摞完全重合）。
##
## 并成一摞双份是合理的降级：现金/用户卡是同质的，玩家按摞付账时看的是
## 侧边清单那行「图标 ×N」，报出真实张数比「两摞叠在一处、看着像一摞满份」诚实得多。
## 限定同种卡是因为两种资源混在一摞里就分不出该付哪一摞了（见 main._stack_settled）
static func host_pile(desk: Desk, spot: Vector3, def_id: String) -> Variant:
	for pile in desk.piles:
		# 认摞的核心卡（收拢态核心卡在最前，见 board._core_first），纯资源摞整摞同种。
		# 混着核心卡的摞认不出来就当认不出，宁可不并也不能把两种资源并进一摞
		if String(pile["def_id"]) != def_id:
			continue
		var origin: Vector3 = pile["origin"]
		if absf(origin.x - spot.x) >= PILE_CLEAR_X:
			continue
		# 摞从 origin 往 +z 长 pile_step×(n-1)，两端各留一摞的余量
		var span: float = desk.pile_step * float(int(pile["count"]) - 1)
		if spot.z > origin.z - PILE_TAKE_CLEAR_Z \
				and spot.z < origin.z + span + PILE_TAKE_CLEAR_Z:
			return pile["ref"]
	return null


## 给一摞找位置：在锚点所在的那一小片里挑「最空」的格子。
##
## 不走「找到第一个空位就用」那条路：左侧这一带本来就被玩家的起手牌占着
## （现金堆锚点在 x=-8.0），一圈走下来常常一个全空的格子都没有，
## 于是退回锚点、几摞叠在一处 —— 那正是「尽可能不重叠」要避免的样子。
## 改成给每个候选格子算个拥挤度，挑最小的那个：全空的格子当场就用，
## 实在挤不开也是挤在最空的一格上，而不是一律压回锚点。
##
## col_xs 非空时只在这几列上找（按给的顺序，靠前的优先）：结算要「现金一列、
## 用户一列」，不能让哪一批沿着 anchor.x 往右漫进另一批的列
static func slot_for_pile(desk: Desk, anchor: Vector3, taken: Array,
		skip: Dictionary = {}, col_xs: Array = []) -> Vector3:
	# 两轮：先只在「不和任何已有摞重叠」的格子里挑，一个都没有才退回按代价挑。
	# 单纯比代价不够 —— 压在一个满份的旧摞上按每张 1 分算，
	# 和「被同样多张散牌占着」的空档同价，于是新摞真的落在旧摞的坐标上，
	# 逐层撞死（实测两摞坐标完全相同）。摞跟摞重叠和别的重叠不是一回事：
	# 散牌之间还能靠组内台阶错开，两摞各排各的台阶，一撞就是整摞穿模
	for hard in [true, false]:
		var best := anchor
		var best_cost := INF
		var steps: int = int((PILE_SLOT_Z_MAX - PILE_SLOT_Z_MIN) / PILE_SLOT_Z_STEP) + 1
		var ncols: int = col_xs.size() if not col_xs.is_empty() else PILE_SLOT_COLS
		for col in ncols:
			var x: float = float(col_xs[col]) if not col_xs.is_empty() \
				else anchor.x + col * PILE_SLOT_X_STEP
			for zi in steps:
				# 先沿 z 往玩家区深处走，走到底再折回锚点上方（购牌区那一侧）
				var z: float = anchor.z + zi * PILE_SLOT_Z_STEP
				if z > PILE_SLOT_Z_MAX:
					z = anchor.z - (z - PILE_SLOT_Z_MAX)
					if z < PILE_SLOT_Z_MIN:
						break
				var spot := Vector3(x, anchor.y, z)
				if hard and pile_overlaps(desk, spot, taken):
					continue
				# 离锚点越远略微加价：一样空的格子里挑最靠锚点那个，排面才齐整
				var cost: float = spot_cost(desk, spot, taken, skip) \
					+ 0.004 * (col * steps + zi)
				# 软挑这一轮（带子满了，怎么摆都压着）里再按「压得多深」排个序：
				# 光比张数不够 —— 压在旧摞正上方、和错开半个身位压着，都算整摞同价，
				# 而序号那一项偏向最早的格子，于是新摞落成和旧摞**坐标完全相同**
				# （实测 摞#7×摞#16 十层逐层 Δy=0.000 全穿）。两种资源不能并成一摞
				# （玩家按摞付账，混了就分不清该付哪一摞，见 host_pile），
				# 那至少要错开身位 —— 错开还看得出是两摞，重合了看着就是一摞
				if not hard:
					cost += 40.0 * overlap_depth(desk, spot)
				if cost < best_cost:
					best_cost = cost
					best = spot
				if best_cost < 0.5:      # 全空的格子，不用再找了
					return best
		if best_cost < INF:
			return best
	return anchor


## 这一格能不能放一张散牌：不压着摞、不压着桌上原有的卡、
## 也不和这一批已经排下的散牌挤到同一格。
## 按真实占地算（卡宽 × 卡纵深 + 摞往 +z 长出来的那截），不借
## PILE_TAKE_CLEAR_Z 那种「一摞的余量」—— 散牌只要不重叠就行。
## 不过这一条也是余量：改回按摞的余量避让，T9 眼下仍全绿
static func loose_spot_free(desk: Desk, spot: Vector3, taken: Array,
		mine: Dictionary, loose_io: Array) -> bool:
	var half_z: float = desk.card_z / 2.0
	# 按桌上**实际最长**的那一摞算尾巴，不按 PILE_CHUNK：带子满了以后摞会
	# 一直往里并（见 main._stack_arrivals 的合并分支，已不封顶），按满份那 PILE_CHUNK-1
	# 层算避让就短了一半，余数正好压在并出来的那半截上
	var pile_tail: float = desk.pile_step * float(desk.longest_pile - 1)
	for t in taken:
		# 摞往 +z 长 pile_tail，两头各半张卡
		if absf(t.x - spot.x) < desk.card_x \
				and spot.z - half_z < t.z + pile_tail + half_z \
				and spot.z + half_z > t.z - half_z:
			return false
	# 同批散牌之间只要求隔开一个步长（挤的时候步长会收紧，见 loose_slots）
	var gap: float = desk.stack_gap * 0.9
	for u in loose_io:
		if absf(u.x - spot.x) < desk.card_x and absf(u.z - spot.z) < gap:
			return false
	for s in desk.cards:
		if mine.has(s["uid"]):
			continue
		var p: Vector3 = s["pos"]
		if absf(p.x - spot.x) < desk.card_x and absf(p.z - spot.z) < desk.card_z:
			return false
	return true


## 给 n 张散牌挑格子。两档：先按 step 逐格填，填不满再按代价挑最不挤的。
##
## 就这两档，没有「收紧步长整条重排一遍」那一档。空带子供 PILE_SLOT_COLS 列
##（每列 z 从 PILE_SLOT_Z_MIN 铺到 PILE_SLOT_Z_MAX、步长是调用方传的 Board.STACK_GAP.z），
## 一次至多要 PILE_CHUNK-1 格（见 settle_layout._lay_loose_run 的三个调用点），
## 供远大于求，填不满都是被摞的占地挡的，而收紧散牌之间的间距让不开摞。
## 真在饱和带（三列各两摞）上量过：逐格填只找到 2 格，收紧那一档一格也没多挑出来，
## 9 张全是下半段摆的（这是那一次实测的张数，不是从常量推的）。
## 「每张都摆得下、且不撞车」由下半段的 clash 判定保证（间距下限 floor_step），
## 那才是 T9 钉住的东西
##
## loose_io 进出参：已排下的散牌坐标。调用方连着排两批时共用一个数组，
## 后一批才躲得开前一批（见 main._stack_settled）
static func loose_slots(desk: Desk, n: int, step: float, anchor: Vector3,
		taken: Array, mine: Dictionary, col_xs: Array, loose_io: Array) -> Array:
	var out: Array = []
	# 只挑 x/z。高度不在这儿定：同一列里前后两张占地重叠，抬高多少归组管
	# （见 main._place_loose_col / Board.ladder_y）
	var ncols: int = col_xs.size() if not col_xs.is_empty() else PILE_SLOT_COLS
	for col in ncols:
		if out.size() >= n:
			break
		var x: float = float(col_xs[col]) if not col_xs.is_empty() \
			else anchor.x + col * PILE_SLOT_X_STEP
		var z: float = PILE_SLOT_Z_MIN
		while z <= PILE_SLOT_Z_MAX and out.size() < n:
			var spot := Vector3(x, anchor.y, z)
			if loose_spot_free(desk, spot, taken, mine, loose_io):
				out.append(spot)
				loose_io.append(spot)
				z += step
			else:
				z += step / 2.0    # 半步挪一挪，别整格跳过一个能用的缝
	# 逐格填不够 n 个：剩下的按代价挑，但**必须挑没被占的格子**，
	# 坐标撞车比压在摞上更糟 —— 屏幕上看着就是少了几张。
	# 撞车判定的间距下限取标题带高：挤到这一步每张仍露出自己的标题带，看得出是几张
	var floor_step: float = desk.band_frac * desk.card_z
	while out.size() < n:
		var best := Vector3.ZERO
		var best_cost := INF
		for col in ncols:
			var x3: float = float(col_xs[col]) if not col_xs.is_empty() \
				else anchor.x + col * PILE_SLOT_X_STEP
			var z3: float = PILE_SLOT_Z_MIN
			while z3 <= PILE_SLOT_Z_MAX:
				var spot3 := Vector3(x3, anchor.y, z3)
				var clash := false
				for u in loose_io:
					if absf(u.x - spot3.x) < 0.01 and absf(u.z - spot3.z) < floor_step:
						clash = true
						break
				if not clash:
					var cost := spot_cost(desk, spot3, taken, mine)
					if cost < best_cost:
						best_cost = cost
						best = spot3
				z3 += floor_step / 2.0
		if best_cost == INF:
			break      # 连一个不撞车的格子都没有了，认了
		out.append(best)
		loose_io.append(best)
	# 真的一个都挑不出来（格子全占满）时补齐，保证返回 n 个
	while out.size() < n:
		var pad := Vector3(anchor.x, anchor.y,
			PILE_SLOT_Z_MAX + floor_step * float(out.size()))
		out.append(pad)
		loose_io.append(pad)   # 后一批也要避开它，不然两批叠在同一格
	return out
