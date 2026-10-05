# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node

## 牌该摆哪儿：BOT 区摆放、玩家闲置区整理、结算到货摞牌、摞的落位与高度。
##
## 从 main.gd 切出来的一段。切的是「摆放」这一层：
## main.gd 管回合流程（谁该行动、买了什么、什么时候进攻），这里只管
## 「这些牌该出现在桌面的哪个位置」。两边的分界就是这句话 —— 流程决定
## 有哪些牌要摆，这里决定摆哪儿。
##
## 再往里一层的纯几何在 engine/pile_solver.gd（挑坐标，可 headless 单测）。
## 这里留下的是必须碰场景的部分：读 board 的组、发补间、改卡的坐标。
##
## 是 Node 而不是 RefCounted：_place_loose_col / _group_pile 要 create_tween()，
## 补间得挂在场景树上的节点上。作为 main 的子节点挂着，main 释放时一起走。
##
## board / entities 进场时绑一次就不变（main._ready 里各自只赋值一次）。
## state 不绑：重开一局会 state = GameState.new()（见 main.gd 的 _restart），
## 绑过的引用会指着上一局的状态，所以一律走 _main.state 现读

## CardEntity / Board / CardArt 都是 class_name，全局可见，不用 preload
const PileSolver = preload("res://engine/pile_solver.gd")

var _main: Node
var board: Board
var entities: Dictionary

## main._ready 里 board 建好之后调一次
func bind(main: Node) -> void:
	_main = main
	board = main.board
	entities = main.entities

## BOT 理牌：组合与闲置单位卡一律收拢成摞（沿高度摞起来，见 Board.COMPACT_GAP），
## 再在 BOT 区排成均匀的两行。摊开摆法下一个 6 张的组合要吃掉 z 向 2.6，
## 三个组合加两堆闲置卡就把整个 BOT 区填满、还会互相压边；收拢后每摞只占一张卡，
## 位置可以按固定节距算出来，多少张牌摆出来都是齐的
## 闲置摞的席位与玩家侧镜像对称：现金在左、用户在右，两边读起来是同一句话。
## x 对着玩家侧那一片牌的**中线**，不是它的左边缘：BOT 一种资源是一摞（一列），
## 玩家那边是切成好几列的一片，两边对齐要按中线看才读得出「对称」。
## 中线 = 玩家侧锚点 x + PLAYER_PILE_COL_PITCH×(列数-1)/2，列数按开局张数
## （`_game.start_cash` / `_game.start_user`）每 PLAYER_PILE_PER_COL 张一列算出来；
## z 落在后行（BOT_ROW_Z 的后者）。
## 贴着玩家侧那一片的左边缘摆会把侧边清单顶到左上角的 HUD 文字上，数字压着数字
const BOT_PILE_BENCH_X := -2.0   # 杂项（非资源）闲置摞：两个资源席位之间
const BOT_COMBO_MAX_Z := -2.0    # BOT 组合 z 上限：不得越过购牌区（MARKET_Z=-1.6）

## 均匀摆放的网格：两行。分行看的是「是什么」不是「第几个」——
## 组合一律前行（靠购牌区，是这回合要看的东西），闲置摞一律后行（固定席位，
## 开局就该在自己家里）。早先按序号分行，开局零组合时两堆闲置卡被排进前行、
## 贴着购牌区挤在中间，第一次上手的人分不清那是谁的牌。
## 节距 2.5 = 卡宽 1.2 + 侧边清单约 0.7 + 间隙，相邻两摞的清单不会叠在一起
const BOT_ROW_Z := [-4.1, -6.5]  # 前行 / 后行；后行不越过 -7.6（BOT 区北缘）
## 后行闲置摞的席位节距。**前行（组合）不用这个数** —— 组合的横向节距按
## 「这一行里最宽的那个组合有多宽」现算，见 plan_combo_row。
##
## 为什么前行不能用固定节距（报上来的症状是「每次 BOT 理完牌，组合卡都叠在一起」）：
## 一个分了 2 列的组合横着占 COMBO_COL_PITCH + 卡宽 = 1.3 + 1.2 = 2.50，
## **正好等于这个节距**。于是相邻两个 2 列组合边挨边、中间一丝空当都没有 ——
## 实测一局第 6 回合，5 张那组的右列在 x=-0.60、6 张那组的左列在 x=+0.60，
## 两列相距 1.20 = 整整一张卡宽，屏幕上就是连成一片、分不出哪几张是一组
const BOT_SLOT_PITCH := 2.5
const BOT_SLOTS_PER_ROW := 6
## 摞沿 +z 长（每张 Board.COMPACT_GAP.z），所以后行的落点要按张数往北退，
## 让摞的远端停在行线上而不是越过行线去顶前行。退到 -7.2 为止（BOT 区北缘
## -7.6 之内）：退到底时后行有 0.7 的退让 + 两行之间本来的 0.7 空档，
## 29 张以内的摞都碰不到前行 —— 这个 29 现在由 back_pile_cap() 算出来并**执行**，
## 原先只是这句注释里的一个观察，摞照旧一张一级台阶地往南爬（实测 100 张
## 爬到 y=4.5、南缘压在货架上）
const BOT_BACK_Z_MIN := -7.2
const PILE_CHUNK := 10          # 结算产出按每份这么多张摞成一组（见 _stack_arrivals）

## 开局这一片摊开的牌：形态要和玩家侧一模一样 —— 玩家开局是摊开的（每列
## PLAYER_PILE_PER_COL 张，见 _group_pile），BOT 也就得是摊开的，不能一边摊开
## 一边收拢成一坨。列的 x 直接用玩家侧那两个锚点，一列对一列地对上。
##
## z 是「同一片牌摆进 BOT 区」，不是把玩家那一片按 z 翻过来：翻过来会让台阶
## 反着长，后一张盖住前一张的标题带（带在卡的远端，见 Board._stack_offset），
## BOT 那片就成了看不出张数的一堵墙。所以照样沿 +z 长，只是整片挪到 BOT 区。
##
## 起点按最长一列（PLAYER_PILE_PER_COL 张）算，让整片的远端贴着 BOT 区北缘：
## 各列按自己的张数居中会让 8 张那列和 4 张那列错开，读不出「一片」
const BOT_SPREAD_Z0 := -7.4
## 摊开这一片的右缘上限。超了就退回收拢：一种资源上百张时摊开要十几列，
## 横着能铺满整张桌子、盖掉对面 —— 收拢加侧边清单才读得出张数。
##
## 注意这条**只挡住出桌**，挡不住「摊得太开」：实测现金要到 7 列（56 张）
## 才撞上它、用户 5 列（40 张），那时整片已经占掉大半个 BOT 区。
## 「摊到几列就该收拢」由 spread_max_cols() 定，这条是它之外的兜底
const BOT_SPREAD_MAX_X := 12.4

## 摊开的组合最南那张的 z 上限：让它的**南缘**贴着货架牌的北缘。
##
## 不能直接用 BOT_COMBO_MAX_Z（-2.0，BOT 托盘的南缘）：那是「卡心不出托盘」，
## 而货架牌卡心在 MARKET_Z=-1.6、占地 CARD_SIZE.z=1.7，北缘在 -2.45 ——
## 卡心摆到 -2.0 的牌南缘已经到 -1.15，整整 0.45 压在货架牌底下
## （两者 y 差着 0.15，不会 z-fight，但屏幕上就是「BOT 的牌钻进货架里」）。
## 收拢那条路离这条线还有一截（8 张组合最南那张在 -3.75），所以这个数
## 是摊开这条路自己要守的，不是把原来那条改严。
##
## 算出来而不是写死：两个数都是常量，写死等于同一件事有两份，
## 改了 MARKET_Z 或卡的纵深就悄悄错开（实测 -1.6 - 1.7 = -3.30）。
##
## 也不能借 _bot_spread_step 的那条线（南端和玩家侧一样远 → -4.2）：那条管的是
## **资源堆**，玩家侧有一片对应的堆才比得出「一样远」。组合是**故意**摆得比它近的
## （BOT_ROW_Z[0] = -4.1 已经在 -4.2 南边，见 BOT_ROW_Z 的说明：组合一律前行、
## 靠购牌区，是这回合要看的东西）。所以组合这条只能按几何取
func combo_south_limit() -> float:
	return _main.MARKET_Z - CardEntity.CARD_SIZE.z

## 组合摊开时同一组内的台阶步长下限：每张至少露出自己的标题带。
## 同 PileSolver.loose_slots 挤到最后一档时的那条线（band_frac × card_z），
## 只有这一个出处 —— 挤到看不出张数的时候，收拢加侧边清单才是能读的形态
static func combo_band_step() -> float:
	return CardArt.BAND_FRAC * CardEntity.CARD_SIZE.z

## 组合分列时列与列的间距。比卡宽（1.2）多 0.1：列之间不重叠，
## 又不至于让一个组合横着占掉半个前行
const COMBO_COL_PITCH := 1.3

## 一列最多放几张：预算摊到标题带那条线为止。
##
## 实测 3 步 × 0.2656 = 0.797 刚好落在 0.80 的预算里，所以是 4 张。
## 算出来而不是写死 4：改了 MARKET_Z、卡的纵深或 BAND_FRAC 这个数就该跟着变，
## 写死的话表现是「组合又开始摞成一块」，而那正是这次要修的症状
func combo_per_col() -> int:
	var budget: float = combo_south_limit() - BOT_ROW_Z[0]
	return 1 + int(floor(budget / combo_band_step() + 0.0001))

## 一个 n 张的组合**想**分几列（不看整行挤不挤，见下）。
##
## 为什么组合要分列（这是这次改的核心）：z 向的预算只有 0.80，
## 加上「每张至少露出标题带」那条下限 0.2656，**一列最多摊得开 4 张**。
## 而 21 个配方里有 17 个是 5 张以上（最大 10 张）—— 于是绝大多数组合
## 一律走收拢，屏幕上就是「BOT 整理后的组合牌全摞在一块儿看不清」。
##
## z 向没得加：北边是后行的资源摞（组合朝北长到 -4.55 就压上它的占地），
## 南边是货架牌的北缘（combo_south_limit 那条）。所以地方只能从 x 上拿 ——
## 资源那一片本来就是这么摊的（_spread_bot_pile 按 PLAYER_PILE_PER_COL 切列）。
##
## 这里**不收「一行摆不下」这个约束**：它归 plan_combo_row 的降列那一段。
## 原先这个函数收一个 room 参数、自己把列数掐到 room 放得下为止，
## 后来整行的宽度成了定值（combo_row_width），三个调用方传的都是同一个数，
## 掐的那一步就再也没掐着过（24.80 放得下 19 列，最大的配方只要 3 列）——
## 也就是「有分支没人看」（memory: green-mutation-means-no-observer）。
## 那条约束现在只写在降列那一处：一行摆不下就挑最宽的那组降一列，
## 挑哪一组降是整行的事，单个组合自己看不见
func combo_cols(n: int) -> int:
	var per: int = combo_per_col()
	if per < 1:
		return 1
	return maxi(1, ceili(float(n) / float(per)))

## 前行组合摊开时的台阶步长；返回 0 表示「这一组摊不开，走收拢」。
##
## 传进来的是**一列里有几张**（per_col），不是整组的张数 —— 组合会分列，
## 见 combo_cols。分列之前这里传的是整组张数，于是 5 张以上一律返回 0。
##
## 预算是「行线（BOT_ROW_Z[0]）到 combo_south_limit()」这一段，实测 0.80。
## 组合沿 +z 长（和玩家侧同向，见 BOT_SPREAD_Z0 的说明），所以北端钉在行线上、
## 往南长 —— 北端钉住是为了让「前行在哪」这件事不随张数变。
##
## 步长取玩家侧那个（Board.STACK_GAP.z=0.52）和预算摊下来那个的小者：
## 玩家侧从不压缩，但 BOT 区纵深只有 5.6 还要塞两行，8 张按 0.52 要 3.64、
## 预算只有 0.80，不压缩的话连 3 张都摊不开（要 1.04）。压到标题带那条线为止
## 是 _bot_spread_step 对资源堆已经在做的取舍 —— 挤到看不出张数就该收拢，
## 收拢有侧边清单，反而读得出来
func combo_spread_step(per_col: int) -> float:
	if per_col < 2:
		return 0.0
	# 行线在北（-4.1），南界在南（-3.30），沿 +z 长 —— 减法的方向别写反了：
	# 反过来是 -0.80，负预算会让 minf 挑到负步长，组合朝北长进后排里
	var budget: float = combo_south_limit() - BOT_ROW_Z[0]
	var step: float = minf(Board.STACK_GAP.z, budget / float(per_col - 1))
	return step if step >= combo_band_step() - 0.0001 else 0.0

## 相邻两个组合之间要留的空当（组合甲的右缘 → 组合乙的左缘）。
##
## 取半张卡宽：一眼能看出「这是两组」就够，留一整张卡宽的话 6 个组合
## 要占 18.6，把前行推到托盘边上。半张是「看得出分界」和「行不太宽」的折中
const COMBO_ROW_GAP := 0.6

## 前行能用的宽度（整行，以 x=0 居中 → 左右各一半）。
##
## 借 BOT_SPREAD_MAX_X 那条右缘线，不新起一个常量：那条线本来的意思就是
## 「BOT 这半边的牌摆到哪儿为止」（见它的说明），前行后行守同一条边才对得齐。
## 托盘本身宽 26（±13），所以这条线左右还各剩 0.6 的余量
func combo_row_width() -> float:
	return BOT_SPREAD_MAX_X * 2.0

## 一个组合从**卡心**往左 / 往右各伸出多远。返回 Vector2(左, 右)，都是正数。
##
## 为什么要分左右两个数、不返回一个「宽度」：收拢摞右边挂着侧边清单
## （board.show_side_badges，摞右沿 + SIDE_GAP 起、宽 SIDE_W），
## 这一片是**只往右长**的。按对称的宽度算会让清单压到右邻那一组身上 ——
## 而清单正是收拢摞唯一能说出张数的地方，被压掉就等于这一摞读不出来了。
##
## cols / compact 由调用方定（见 plan_combo_row）：同一个 n 摊开还是收拢
## 占的地方差着一个清单的宽度，光看张数说不出来
func combo_reach(n: int, cols: int, compact: bool) -> Vector2:
	var half: float = CardEntity.CARD_SIZE.x / 2.0
	if compact:
		# 收拢摞就一列。n < 2 时不挂清单（show_side_badges 那条门槛），
		# 右边也就不用多让 —— 这个分叉要跟着那条门槛，不然独张的组合
		# 会白留出一份清单的宽度
		var right: float = half
		if n >= 2:
			right = half + Board.SIDE_GAP + Board.SIDE_W
		return Vector2(half, right)
	# 摊开的组合：列以 at.x 居中（_spread_bot_combo 里那句 dx），
	# 两侧各伸出 (cols-1)/2 个列距，再加卡自己的半宽。摊开的不挂清单
	var side: float = float(cols - 1) / 2.0 * COMBO_COL_PITCH + half
	return Vector2(side, side)

## 排前行：定下每个组合分几列、摊开的步长、以及卡心的 x。
##
## 这是修「组合卡都叠在一起」的那一步。原先前行是**固定节距 2.5 的格子**，
## 而一个 2 列组合横着正好占 2.50 —— 相邻两组边挨边，零空当（见 BOT_SLOT_PITCH）。
## 现在反过来：先让每个组合按自己的张数摊开（要几列给几列），
## 再按「最宽的那个 + COMBO_ROW_GAP」算出整行统一的节距。
##
## 节距整行统一（而不是一组一组紧挨着排）：等距的一行读得出「这是并列的几组」，
## 宽窄不一地紧挨着排会让人把窄的两组看成一组。代价是行会宽一些，
## 而前行本来有富余 —— 托盘宽 26，原先的 6 格网格只用了 15。
##
## piles 只要每项的 n（张数）和 compact（Variant：true/false/null，
## 对手声明的形态，见 _layout_bot_zone），不需要真的卡 —— 这样这个函数是纯的，
## 判据能直接拿几个张数问它，不必先在桌上摆出一局
func plan_combo_row(piles: Array) -> Array:
	var k: int = piles.size()
	var out: Array = []
	if k == 0:
		return out
	for p in piles:
		var n: int = int((p as Dictionary).get("n", 0))
		# 对手**说了**这一摞是什么形态，就照他说的摆 —— 不再照几何猜。
		#
		# 这是联网局里玩家最直观的一个动作：他双击把一摞收起来 / 摊开来，
		# 我这边也该看见同一件事。两个方向都要治：
		#   - 他说收拢 → step 归零，走 _place_bot_pile
		#   - 他说摊开 → 换一份朝北的预算（declared_spread_step），
		#     否则 8 张的摞按前行那 0.80 会被压成收拢，
		#     于是收拢和摊开在我屏幕上长得一模一样
		# 几何只在「他说摊开、连朝北那份预算也摊不下」时还有发言权：
		# 那种形态读不出张数，收拢加侧边清单才是**更**接近他本意的表述。
		# 单机局和老形状的包里 compact 是 null，整条判断退化成
		# combo_spread_step > 0.0，也就是这条改动之前的行为
		var want: Variant = (p as Dictionary).get("compact", null)
		# 先定分几列，再按**一列里有几张**问步长：z 向的预算是按列吃的，
		# 拿整组张数去问会得出「摊不开」（5 张以上一律 0），那正是要修的
		var cols: int = combo_cols(n)
		var step: float = combo_spread_step(ceili(float(n) / float(maxi(cols, 1))))
		# 「他说摊开」和「几何自己摊开」要分开记：钉南端那一步（见 _layout_bot_zone）
		# **只属于前者**。declared_spread_step 是一份朝北的预算（见那个函数），
		# 而 combo_spread_step 那份本来就是从行线往南长的 ——
		# 两者都往北挪的话，单机局的 BOT 组合会整片偏出行线
		var declared_spread := false
		if want is bool:
			if bool(want):
				step = 0.0
			else:
				step = declared_spread_step(n)
				declared_spread = step > 0.0
				# 明说摊开的那一摞**不分列**：declared_spread_step 那份预算
				# 是朝北的 3.10，一列就摊得开 8 张，不需要横着借地方。
				# 而且分列会和「南端钉行线」那一步打架 —— 那一步按整摞的
				# z 跨度往北挪，分列之后跨度只剩一列那么长
				cols = 1
		if step <= 0.0:
			cols = 1
		out.append({
			"n": n, "cols": cols, "step": step,
			"compact": step <= 0.0, "declared_spread": declared_spread,
		})
	# 节距 = 「最宽那组的右伸 + 最宽那组的左伸 + 空当」。取整行的最大值
	# 而不是逐对相邻算：等距才读得出并列关系（见上面）
	var lead: float = _row_lead(out)
	var trail: float = _row_trail(out)
	# 摆不下就把最宽的那几组降列 —— 降到 1 列就成了收拢（step 归零），
	# 占地缩到一张卡 + 一份清单，也就读得出张数。
	#
	# 降列是有损的（一列摊不开 5 张以上，只好收拢），但收拢有清单顶着，
	# 读得出「这是一组 8 张」。所以它是**退到最后**才走的一步，前面还有一步
	# 不亏东西的：先把空当挤掉。
	#
	# 闸门按**空当挤到 0** 的宽度问，不按「带着 COMBO_ROW_GAP 摆得下吗」问 ——
	# 这是这一版改的地方。空当归 0 只是两组边挨边，谁也没盖住谁；
	# 真正开始互相盖是节距压到 lead+trail 以下（那一步在下面，压到卡宽为止）。
	# 拿「带空当」当闸门的话，只差一点空当就触发降列，而降列的代价大得多：
	# 实测 9 个 8 张的组合，带空当要 27.30 > 24.80 于是全体降列 → 九摞全收拢，
	# 屏幕上九个组合各剩一张牌；而空当挤到 0.29 就摆得下了，九组全是摊开的
	# 2 列 × 4 行。更糟的是降列**反而会把节距顶宽**：2 列组合右伸 1.25，
	# 收拢摞右边挂着清单要 1.71，降完一组、其余还是 2 列时最大右伸从
	# 1.25 变 1.71，整行比降之前还宽 —— 于是一路降到全体收拢才停。
	# 「一个组合太多就全体崩成单张」那个断崖就是这么来的
	var avail: float = combo_row_width()
	while _row_span(out, lead + trail) > avail:
		var widest: int = -1
		var most: int = 1
		for i in out.size():
			if int(out[i]["cols"]) > most:
				most = int(out[i]["cols"])
				widest = i
		if widest < 0:
			break      # 全都只有一列了，再降不下去 —— 挤一点也留在一行
		var e: Dictionary = out[widest]
		var cols2: int = most - 1
		var step2: float = combo_spread_step(
			ceili(float(int(e["n"])) / float(maxi(cols2, 1))))
		if step2 <= 0.0:
			cols2 = 1
		e["cols"] = cols2
		e["step"] = step2
		e["compact"] = step2 <= 0.0
		# 降完这一组，两头的最大伸出都可能变（见上面那段：收拢摞的清单
		# 比 2 列还宽），闸门下一轮要按新的量问
		lead = _row_lead(out)
		trail = _row_trail(out)
	# 节距 = 「最宽那组的左伸 + 右伸 + 空当」，但空当只加**摆得下的那部分**：
	# 上面的闸门保证了零空当摆得下，这里从零空当往上加回来，加到
	# COMBO_ROW_GAP 为止或者加到贴着 avail 为止，取先到的那个。
	# 直接写 lead+trail+COMBO_ROW_GAP 再让下面去压是等价的，
	# 但那样「压」这个动作就同时管两件事（挤空当、啃清单），
	# 出了问题分不清是哪一件（memory: number-lives-in-five-places）
	var pitch: float = lead + trail + COMBO_ROW_GAP
	var gapped: float = _row_span(out, pitch)
	if k > 1 and gapped > avail:
		# 一行的占地对节距是线性的，斜率 k-1（首末两组之间隔 k-1 个节距），
		# 所以要挤的那点宽度摊到每个节距上就是 over/(k-1)。
		# 挤到 lead+trail 为止 —— 那是零空当，再往下就是啃清单（下面那一步）
		pitch = maxf(pitch - (gapped - avail) / float(k - 1), lead + trail)
	# 降到全是一列还是摆不下（组合个数本身太多），就压节距 —— 但**压到卡宽为止**。
	#
	# 压掉的是清单那份宽度：右邻的牌会盖住一部分侧边清单，读得出「这是几组」、
	# 张数可能被挡。而不压的话整行会长到 ±15.7（实测 11 个组合），
	# 那已经出了 BOT 托盘（±13）—— 牌摆到别人半场去，比清单被挡严重得多。
	#
	# 底线取卡宽：到这个数相邻两张正好边挨边，再压就是**牌压牌**，
	# 也就回到「组合卡都叠在一起」那个症状本身了。
	# 卡宽这个底线仍可能撑破整行（20 个以上的组合），那时宁可出桌不许重叠 ——
	# 出桌看得见（一眼就知道不对），重叠看不见（长得像「本来就这么多牌」）
	if k > 1 and _row_span(out, pitch) > avail:
		var over: float = _row_span(out, pitch) - avail
		pitch = maxf(pitch - over / float(k - 1), CardEntity.CARD_SIZE.x)
	# 一行空得慌的时候把节距**撑开**到 BOT_SLOT_PITCH。
	#
	# 上面算出来的节距只保证「不重叠」，没保证「不显得挤」：节距是按
	# 最宽那组的伸出算的，而组合小的时候那个数很小 —— 两个 2 张的组合
	# 各占一列，左右伸出各 0.60，节距只有 0.60+0.60+0.60 = 1.80，
	# 而前行有 24.80 的地方、这两组一共只用了 3.00。原先的固定网格给的是
	# 2.50，所以这一版**比改之前还挤**，虽然没重叠。
	#
	# 撑到 BOT_SLOT_PITCH（2.5）为止：那就是原先那个网格的节距，
	# 也就是这一行「本来该有多松」的既有口径 —— 另起一个数的话，
	# 同一件事就有了两个出处（memory: number-lives-in-five-places）。
	# 撑开只会把空当变大，不会造成重叠，所以不必再判一次不重叠。
	#
	# 只在**撑得下**的时候撑：能撑到多宽由 avail 反解 —— 占地对节距线性、
	# 斜率 k-1，所以最多能加 (avail - 现在的占地)/(k-1)。
	# 反解而不是「撑完再判超没超」：判了超再退回去就是同一个数算两遍
	if k > 1 and pitch < BOT_SLOT_PITCH:
		var room: float = (avail - _row_span(out, pitch)) / float(k - 1)
		pitch = minf(BOT_SLOT_PITCH, pitch + maxf(room, 0.0))
	# 整行居中：居中的是**整片牌的占地**（含收拢摞右边那份侧边清单），
	# 不是卡心那一串。
	#
	# 按卡心居中不行：清单只往右长，于是「有几摞是收拢的」会让整片牌
	# 整体偏右 —— 实测 9 个组合时占地是 [-11.84, 12.96]，右边那 0.56 出了桌
	# （BOT_SPREAD_MAX_X=12.4），而卡心那一串明明是对称的。
	# 代价是组合的形态一变，卡心会跟着挪一点；而形态本来每回合就在变
	for i in out.size():
		out[i]["x"] = float(i) * pitch
		out[i]["pitch"] = pitch
	var ext: Vector2 = _row_extent(out)
	var shift: float = -(ext.x + ext.y) / 2.0
	for i in out.size():
		out[i]["x"] = float(out[i]["x"]) + shift
	return out

## 这一行里最靠左那份左伸 / 最靠右那份右伸（用来定节距：等距要按最宽的那组算）
func _row_lead(plan: Array) -> float:
	var lead: float = 0.0
	for e in plan:
		lead = maxf(lead, combo_reach(
			int(e["n"]), int(e["cols"]), bool(e["compact"])).x)
	return lead

func _row_trail(plan: Array) -> float:
	var trail: float = 0.0
	for e in plan:
		trail = maxf(trail, combo_reach(
			int(e["n"]), int(e["cols"]), bool(e["compact"])).y)
	return trail

## 按这个节距摆出来，整片牌的占地是 [左, 右]（相对第 0 组的卡心）。
##
## 逐组量而不是拿「首组左伸 + (k-1)*节距 + 末组右伸」算：最宽的那组可能在中间，
## 那时整片的边缘由它定，按首末两组算会少算一截
func _row_extent(plan: Array) -> Vector2:
	var lo: float = INF
	var hi: float = -INF
	for e in plan:
		var r: Vector2 = combo_reach(int(e["n"]), int(e["cols"]), bool(e["compact"]))
		lo = minf(lo, float(e["x"]) - r.x)
		hi = maxf(hi, float(e["x"]) + r.y)
	return Vector2(lo, hi)

## 按这个节距摆出来整片牌有多宽（含清单）。节距还没写进 plan，所以现摆一遍
func _row_span(plan: Array, pitch: float) -> float:
	var lo: float = INF
	var hi: float = -INF
	for i in plan.size():
		var e: Dictionary = plan[i]
		var r: Vector2 = combo_reach(int(e["n"]), int(e["cols"]), bool(e["compact"]))
		var x: float = float(i) * pitch
		lo = minf(lo, x - r.x)
		hi = maxf(hi, x + r.y)
	return hi - lo

## 对手**明说摊开**的那一摞的台阶步长；返回 0 表示「连这份预算也摊不开」。
##
## 为什么不共用 combo_spread_step：那一份的预算是「行线往南到货架北缘」，
## 实测只有 0.80 —— 8 张要 3.64，于是**摊开的摞会被压成收拢**。
## 单机局那样没问题（收方不知道 BOT 想怎么摆，收拢加侧边清单是保守的选择），
## 联网局不行：发送端明说了这一摞是摊开的，压成收拢就等于收拢和摊开
## 在对手屏幕上长得一模一样 —— 而那正是玩家双击时唯一能看见的反馈。
##
## 预算换个方向拿：**南端钉在行线上，往北长**（行线 -4.1 → 后行退让线 -7.2，
## 实测 3.10，8 张够摊到 0.443）。台阶方向照旧沿 +z 长，只是整列往北挪 ——
## 所以台阶不会反着长（BOT_SPREAD_Z0 那段警告的是把玩家那片按 z 翻过来，
## 那才会让后一张盖住前一张的标题带）。
##
## 钉南端而不是北端：南端是靠货架、靠玩家的那一边，钉住它整片牌的
## 「离我多远」不随张数变。北端钉住的话（combo_spread_step 的做法）
## 张数一多整片就朝南长进货架里，而这条预算是朝北的
func declared_spread_step(n: int) -> float:
	if n < 2:
		return 0.0
	var budget: float = BOT_ROW_Z[0] - BOT_BACK_Z_MIN
	var step: float = minf(Board.STACK_GAP.z, budget / float(n - 1))
	return step if step >= combo_band_step() - 0.0001 else 0.0

## 后行那几摞收拢时台阶最多长几级（= 一摞里有几张露得出自己那一级）。
##
## 预算是「摞退到底（BOT_BACK_Z_MIN）时，最南那张的卡心还能往南走多远」：
## 摞沿 +z 往南长，最南那张的**南缘**（卡心 + 纵深/2）不许越过前行那片牌的
## **北缘**（BOT_ROW_Z[0] − 纵深/2）—— 越过就是压在组合的占地上。
## 两边各让半个纵深，合起来正好是一整个纵深：
##   (行线 − 纵深/2) − 纵深/2 − 退让线 = 行线 − 退让线 − 纵深
## 实测 -4.1 − (-7.2) − 1.7 = 1.40，按 COMPACT_GAP.z=0.05 一级 → 29 级，
## 正是 BOT_BACK_Z_MIN 那句注释一直写着、却从来没人执行的那个数。
##
## 纵深只减一次（别减两次）：减两次剩 0.55、只有 12 级，摞看着更矮更紧，
## 可那是把「不碰前行」偷偷换成一条更严的、没人说出口的规矩 ——
## 12 这个数会显得是算出来的，其实是式子写错了。要更矮就得另立一条规矩、
## 并把理由写在这儿。
##
## 算出来而不是写死 29：这四个量（退让线、行线、卡的纵深、收拢台阶）
## 每一个都是旋钮，写死的话调了任何一个都表现为「摞又开始压前行」，
## 而那正是这次要修的症状。
##
## 满级那一摞的高度：29 级 × COMPACT_GAP.y = 1.26（摞顶 y=1.31，清单 1.33）——
## 29 张真牌叠起来是 0.87 厚，抬得比实物高是因为台阶得跨过 FACE_SPAN_Y 那条
## 防穿模的线（0.045 > 0.020），不是因为摞得虚
func back_pile_cap() -> int:
	var budget: float = BOT_ROW_Z[0] - BOT_BACK_Z_MIN - CardEntity.CARD_SIZE.z
	if budget <= 0.0:
		return 1
	return 1 + int(floor(budget / Board.COMPACT_GAP.z + 0.0001))

## 一摞在 z 向占多长。step>0 是摊开态（台阶 step 一格），=0 是收拢态
## （台阶 COMPACT_GAP.z，且台阶封顶在 back_pile_cap 级）。
## 两种形态各自的偏移在 Board 里，这里只做「乘级数」——
## 抽出来是因为**摆放和量跨度必须用同一个数**：量少了那一摞会伸出桌沿，
## 量多了它会缩着摆，而两种都只看得见「位置不太对」
func _pile_z_span(n: int, step: float) -> float:
	if n < 2:
		return 0.0
	if step > 0.0:
		return step * float(n - 1)
	return Board.COMPACT_GAP.z * float(mini(n, back_pile_cap()) - 1)

## 对手声明的归一化位置 → 摆放函数要的那个 at（= 摞的**北端**）。
##
## 两处口径要对上：发送端发的是整摞 z 向的**中点**（见 main.my_pile_lists），
## 而 _spread_bot_combo / _place_bot_pile 要的是北端 —— 所以往北退半个跨度。
## 直接把中点当北端的话，摞越长越往南偏，长摞会整个压到货架上。
##
## z 钳在对手半区内（和 _free_spot 那对边界同一个数）：他那边可以把一摞
## 拖到贴着自己镜头那条边，镜像过来就是贴着我这边的北缘 —— 长摞的南端会
## 越过 -1.8 伸进公共区，盖住市场的牌。钳北端**优先**：钳不下时（摞比整个
## 半区还长）宁可往南伸一点，也不能让北端出桌 —— 北端出桌是「牌飞到桌外面」，
## 而往南伸只是和公共区挨得近
func _pile_anchor_at(uv: Vector2, span: float) -> Vector3:
	var p: Vector3 = _main.foe_pile_point(uv.x, uv.y)
	p.z -= span / 2.0
	p.z = minf(p.z, BOT_FAR_Z_MAX - span)
	p.z = maxf(p.z, BOT_FAR_Z_MIN)
	return p

## 对手半区的 z 边界。和 _free_spot 里那对数字是同一件事 ——
## 那边写在函数里（is_near 分叉），这里要的是常量形式
const BOT_FAR_Z_MIN := -7.6
const BOT_FAR_Z_MAX := -1.8

## 一摞在**我这一侧**该按什么次序摆。declared 是发方声明的收拢位
## （true 收拢 / false 摊开 / null 没说）。
##
## 规矩和发方逐字相同（board.toggle_compact → _core_first）：**只有收拢才提核心卡**。
## 收拢态只露得出摞顶那一张，露的得是「刷不停」这类说明得了阵型的卡；
## 摊开态队首反而是露得最少的那张（Board._top_index 摊开取队尾），
## 把核心卡挪过去等于把它藏起来。
##
## 两侧规矩不一致的后果有两个，都在联机局：
##   1. 摊开的摞在两个视角里次序不一样 —— 而 uids 里带着的**就是**他屏幕上的次序
##      （摞走 my_pile_lists 的 g["cards"]，组合走 _register_player_combos
##      发出去的 create_combo，GameState.create_combo 原样 duplicate 存下）
##   2. 队首会跟着变：调用方那圈过滤会剔掉租出去的 uid（is_drag_leased），
##      无条件重排是在**剩下这个子集**上算的 —— 他从摞里拎起几张，
##      我这边首张牌当场换人。照他的次序摆就没有这个洞：
##      剔掉几张，余下的相对次序不变
##
## null 走核心卡优先（单机局的 BOT、老形状的包）：那一侧没有「他双击过」这回事，
## 形态由几何定，而几何定出来的多是收拢 —— 也就是这条改动之前的行为
func _order_as_declared(cards: Array, declared: Variant) -> Array:
	if declared is bool and not bool(declared):
		return cards
	return Board.core_first_order(cards)

## 对手声明但还没编成组合的摞（见 Protocol.PILES / main.foe_piles）。
## claimed 是已经被组合收走的 uid，进来时只读、出去时**记上这几摞收了谁** ——
## 调用方拿它去剔资源摞（见 _bot_piles 那一句）。
##
## 三道过滤，都在读的这一侧（发的那一侧只管说「我摆成这样」）：
##   - 不是对手名下的牌：忽略。发方编造 uid 或者牌刚被打掉都走这条
##   - 已经被组合收走的：忽略。组合是玩法状态，压过声明
##   - 正被远端拖着的：忽略，同 _collect_idle_units 那条租约
## 一张牌只进第一次出现的那一摞（发方分组重叠时，后一摞里那份丢掉）
func _declared_piles(claimed: Dictionary) -> Array:
	var out: Array = []
	if _main.foe_piles.is_empty():
		return out
	var owned := {}
	for c in _main.state.players[_main.foe_seat]["cards"]:
		owned[int(c["uid"])] = true
	var i := 0
	for g in _main.foe_piles:
		var cs: Array = []
		# 形状由 Protocol.pile_lists 归一化过：一律 { uids, compact }
		var uids: Array = (g as Dictionary).get("uids", [])
		for u in uids:
			var uid := int(u)
			if not owned.has(uid) or claimed.has(uid):
				continue
			if not entities.has(uid) or not is_instance_valid(entities[uid]):
				continue
			if _main.is_drag_leased(uid):
				continue
			claimed[uid] = true
			cs.append(entities[uid])
		# 剩一张的摞不算摞：一张牌自己站着和「散卡」没有区别，
		# 而当成摞会给它挂一份「1 张」的侧边清单
		if cs.size() >= 2:
			# 次序**照发方说的来**，这一侧不重排。
			#
			# 发方那边的规矩是「收拢才提核心卡」（board.toggle_compact →
			# _core_first）：摊开态的队首是露得最少的那张（_top_index 摊开取队尾，
			# 收拢取队首），把核心卡挪到队首反而看不清。这一侧无条件
			# core_first_order 的话，摊开的摞在两个视角里次序不一样 ——
			# 而 uids 里带着的正是他屏幕上的次序。
			#
			# 更麻的是队首会**跟着变**：上面那圈过滤会把租出去的 uid
			# （is_drag_leased）剔掉，重排是在剩下这个子集上算的 ——
			# 他从摞里拎起几张，我这边剩下那几张的次序就重算一次，
			# 首张牌当场换人。照发方的次序摆就没有这个洞：剔掉几张，
			# 余下的相对次序不变
			var rec := { "cards": _order_as_declared(cs,
					bool((g as Dictionary).get("compact", false))),
				"key": "bot_group_%d" % i,
				# 发送端说的收拢位，一路带到 _layout_bot_zone
				"compact": bool((g as Dictionary).get("compact", false)) }
			# 发送端说的位置（可选，见 Protocol.pile_lists）。没说就不放这个键 ——
			# _layout_bot_zone 靠「有没有这个键」决定照他说的摆还是整行居中
			if (g as Dictionary).has("u") and (g as Dictionary).has("v"):
				rec["anchor"] = Vector2(float((g as Dictionary)["u"]),
					float((g as Dictionary)["v"]))
			out.append(rec)
			i += 1
		else:
			# 没成摞的那张还给资源摞：claimed 里记过了，得撤回来
			for e in cs:
				claimed.erase(int(e.uid))
	return out

## 收集某方未编组的闲置单位卡实体 → [现金实体, 用户实体]（玩家/BOT 共用这一份判定）。
##
## extra_grouped 是「已经被别的摞收走」的 uid（对手声明的摞，见 _declared_piles）。
## 单独一个参数而不是并进 grouped：grouped 是**这里自己算**的那份
## （我方看 board.groups、对手看 state.combos），两份混在一处的话
## 就说不清「谁该维护它」了
func _collect_idle_units(who: String, extra_grouped: Dictionary = {}) -> Array:
	var grouped := {}
	for u in extra_grouped:
		grouped[u] = true
	if who == _main.foe_seat:
		for combo in _main.state.combos:
			if combo["owner"] == who:
				for u in combo["uids"]:
					grouped[u] = true
	else:
		for g in board.groups:
			for c in g["cards"]:
				grouped[c.uid] = true
	var idle_cash: Array = []
	var idle_user: Array = []
	var idle_other: Array = []   # 没编进组合的核心/Buff 卡（第三格，只有 BOT 侧在用）
	for c in _main.state.players[who]["cards"]:
		if grouped.has(c["uid"]) or not entities.has(c["uid"]):
			continue
		# 正被远端拖着的牌不参与摆放（scenes/main.gd 的拖拽广播与租约处理的租约）。
		# 不挡的话每一步之后的 _layout_bot_idle 都会抢着把牌摆回摞里，
		# 而网络那头每 50ms 写一次新位置 —— 两边打架的样子是牌在抽搐
		if _main.is_drag_leased(int(c["uid"])):
			continue
		var e: CardEntity = entities[c["uid"]]
		if not is_instance_valid(e):
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") != CardDB.KIND_UNIT:
			idle_other.append(e)
			continue
		if def.get("res") == CardDB.RES_CASH:
			idle_cash.append(e)
		else:
			idle_user.append(e)
	return [idle_cash, idle_user, idle_other]

## 一张牌**会停在**哪儿。飞行中的牌实时坐标还在出发点，问它「在哪」会得到
## 早已过时的答案 —— 于是买卡飞的那 0.35 秒里，任何一处再问落点都会把
## 同一个坑再许诺一次（memory: settle-runs-mid-flight 的同一个形状）。
##
## 桌上一共三种搬牌的补间，这里三种都要认，缺一种就是一处「读到出发点」：
##   - main._move_to（买卡、退回）和本文件的 _move_to_spot（结算余数）：
##     起飞时把终点记成 dest_pos 这个 meta，落地清掉
##   - board._move_to（编组重排、抬升）：终点记在 board._move_tw 里，
##     读它的只读接口 board.rest_pos
## dest_pos 排在前面：同一张牌先被 board 排过、又被结算搬走时，后发的那条才是归宿
func _rest_pos(e: CardEntity) -> Vector3:
	if e.has_meta("dest_pos"):
		return e.get_meta("dest_pos")
	return board.rest_pos(e)

## 这会儿算障碍的所有坐标：`claimed` 里已许诺出去的落点，加上桌上每张牌的归宿。
##
## ignore 是「这几张不算障碍」的 uid：退回自己拖着的那摞卡时，那几张还登记在
## entities 里、坐标还在手上那个位置，不排掉的话它们会把自己要回去的坑占住。
##
## 抽出来是因为「撞不撞」和「离最近的牌多远」问的是同一批障碍 —— 两处各写一遍
## 筛选的话，一处漏掉 is_market 就会变成「搜索认为这儿空、评分认为这儿挤」，
## 而 _free_spot 正是拿这两个数配合着挑坑的。
## 也顺带把重复的活儿去掉：一轮搜索里障碍集合根本不变，原先每轮重扫两遍
func _obstacles(claimed: Array, ignore: Dictionary) -> Array:
	var out: Array = []
	for p in claimed:
		out.append(p as Vector3)
	for uid in entities:
		if ignore.has(uid):
			continue
		var e: CardEntity = entities[uid]
		if not is_instance_valid(e) or e.is_market:
			continue
		out.append(_rest_pos(e))
	return out

## 这个位置和已有的牌撞不撞。x 1.3 / z 1.0 是一张卡的避让半径
func _spot_clash(spot: Vector3, claimed: Array, ignore: Dictionary = {}) -> bool:
	return _clash_at(spot, _obstacles(claimed, ignore))

func _clash_at(spot: Vector3, blockers: Array) -> bool:
	for p in blockers:
		if absf((p as Vector3).x - spot.x) < 1.3 and absf((p as Vector3).z - spot.z) < 1.0:
			return true
	return false

## 这个位置离最近的一张牌有多远（取 x/z 里大的那个，和避让判据同一个口径）
func _clearance_at(spot: Vector3, blockers: Array) -> float:
	var best := 999.0
	for p in blockers:
		best = minf(best, maxf(absf((p as Vector3).x - spot.x),
			absf((p as Vector3).z - spot.z)))
	return best

## 在锚点附近找一个不压到现有卡牌的落点：沿 +x 滑移，到边换行，钳制在该方区域内。
## claimed 是本批已经许诺出去、但牌还在飞的落点：整批同时出生时实时坐标全在
## 出发点上，只看 entities 会给每张牌返回同一个 spot（产出牌完全重叠的老毛病）
##
## 换行要**绕回另一头**，不是钳在边上。原先是 `z = clampf(z + z_dir*1.1, ...)`，
## 于是搜索只朝一个方向走、到边就钉住：买卡的锚点是 PLAYER_ZONE_Z+1.6=3.4，
## 近侧区间 [0.6, 5.2] 里它只看得到 3.4 / 4.5 / 5.2 三行，再往后 60 次全在
## 重复扫 5.2 那行 —— 0.6 / 1.7 / 2.8 三行**空着也不看**。
## 「桌面挤满了」因此来得比实际早得多，这是同一个 bug 的上游
func _next_row(z: float, z_dir: float, z_min: float, z_max: float) -> float:
	var next := z + z_dir * 1.1
	if next > z_max + 0.01:
		return z_min      # 走到远边，绕回近边接着扫
	if next < z_min - 0.01:
		return z_max
	return clampf(next, z_min, z_max)

## 抽屉模式下 board 提供的是「卡牌占物理外框」；卡心必须再让开半张牌，
## 否则边缘卡虽然卡心在框内，实际仍会被裁掉。旧 headless 场景没有这些字段，
## 返回空 Rect2 以保持原有宽桌行为。
func _center_bounds(who: String) -> Rect2:
	if board == null:
		return Rect2()
	var raw: Variant = null
	if who == _main.my_seat:
		raw = board.get("player_bounds")
	else:
		# Board 只公开 player_bounds/table_bounds；抽屉远侧使用同宽的固定安全框，
		# 避免读取不存在的 enemy_bounds 触发 Godot invalid-property 日志。
		var pb: Variant = board.get("player_bounds")
		if pb is Rect2 and (pb as Rect2).has_area():
			raw = Rect2(-12.5, -8.0, 25.0, 5.2)
	if not (raw is Rect2) or not (raw as Rect2).has_area():
		return Rect2()
	var r: Rect2 = raw
	var hx := CardEntity.CARD_SIZE.x * 0.5
	var hz := CardEntity.CARD_SIZE.z * 0.5
	return Rect2(r.position.x + hx, r.position.y + hz,
		maxf(0.0, r.size.x - 2.0 * hx), maxf(0.0, r.size.y - 2.0 * hz))

func _drawer_bounds_enabled() -> bool:
	return _center_bounds(_main.my_seat).has_area()

## 找不到空位时返回**空得最多**的那个，不是最后试的那个。
## 为什么这条要紧：原先 60 次全撞之后直接 `return spot`，返回的是循环出口那个
## 坐标 —— 和搜索到过的最好位置没关系，而且同一张桌面上每次调用都是同一个点。
## 桌面一挤，接着买的每一张都精确落在同一点上，后来的把先到的整个盖住：
## 看着就是「买到的牌不见了」，而在那个位置拖牌又能凑成组合（牌一直在），
## 组合一摊开它就「又出现了」。
##
## 取最空的那个之后，两次连着买也不会重合 —— 但**不是因为 best 每次不同**，
## 是因为第一张在飞的路上就把 best 那个点用 dest_pos 宣告成己方占用了
## （见 _rest_pos），第二次搜索里那儿已经不空。两条修法缺一条都还会重合
func _free_spot(anchor: Vector3, who: String, claimed: Array = [],
		ignore: Dictionary = {}) -> Vector3:
	## 近侧 / 远侧，不是「人 / 电脑」：联网时远端客户端的 my_seat 是 GameState.BOT，
	## 它的牌照样摆在屏幕下半边（近侧）
	var is_near: bool = who == _main.my_seat
	var z_dir := 1.0 if is_near else -1.0
	# 远侧那对边界和 _pile_anchor_at 钳位用的是同一份常量：
	# 两处各写一个数的话，「找空位」和「摆声明的摞」会对不同的桌沿负责，
	# 而症状是某一种摆法的牌伸出桌外
	var z_min := 0.6 if is_near else BOT_FAR_Z_MIN
	var z_max := 5.2 if is_near else BOT_FAR_Z_MAX
	var x_min := -INF
	var x_max := INF
	var safe := _center_bounds(who)
	if safe.has_area():
		x_min = safe.position.x
		x_max = safe.end.x
		z_min = maxf(z_min, safe.position.y)
		z_max = minf(z_max, safe.end.y)
	var spot := anchor
	spot.x = clampf(spot.x, x_min, x_max)
	spot.z = clampf(spot.z, z_min, z_max)
	var best := spot
	var best_clear := -1.0
	# 障碍在这一轮搜索里不变（entities 和 ignore 都不动），收一次给 60 轮共用
	var blockers := _obstacles(claimed, ignore)
	for _try in (120 if safe.has_area() else 60):
		spot.x = clampf(spot.x, x_min, x_max)
		spot.z = clampf(spot.z, z_min, z_max)
		if not _clash_at(spot, blockers):
			return spot
		var clear := _clearance_at(spot, blockers)
		if clear > best_clear:
			best_clear = clear
			best = spot
		spot.x += 1.7
		var wrap_x := x_max if safe.has_area() else 8.5
		if spot.x > wrap_x + 0.01:
			spot.x = x_min if safe.has_area() else anchor.x
			spot.z = _next_row(spot.z, z_dir, z_min, z_max)
	return best

## 按资源给新卡选落位锚点：现金锚左、用户锚右，非单位卡落区域中部
func _unit_anchor(who: String, def_id: String) -> Vector3:
	var def: Dictionary = CardDB.get_def(def_id)
	if who == _main.foe_seat:
		if def.get("kind") == CardDB.KIND_UNIT:
			return _bot_resource_anchor(str(def.get("res")))
		return Vector3(0, 0.05, _main.BOT_ZONE_Z - 1.5)
	if def.get("kind") == CardDB.KIND_UNIT:
		return PLAYER_PILE_CASH_ANCHOR if def.get("res") == CardDB.RES_CASH else PLAYER_PILE_USER_ANCHOR
	return Vector3(0, 0.05, _main.PLAYER_ZONE_Z + 1.6)

## BOT 每步（典当/买卡/编组/结算/回合开始）结束后都调这一个入口：
## 把组合和闲置卡各自收拢成摞，然后整片重排。分成两个函数的时候
## 「买完卡只理闲置、不动组合」会让组合和新的闲置摞挤在一起
func _layout_bot_idle() -> void:
	_layout_bot_zone()

## 这个 key 是不是「前行的摞」= 对手自己摆出来的分组。
## 两种：编成了的组合（bot_combo_*）和还只是摞在一起的（bot_group_*，
## 见 Protocol.PILES）。后行是三个固定席位的资源/备牌摞。
##
## 一处定义：判前行的地方有四五处（分行、摊开预算、测试的分行断言），
## 各写一遍 begins_with 的话，新加一种摞会**只在其中几处**被当成前行 ——
## 症状是那一摞摆在后行的资源席位上，跟资源摞互相压边
static func is_front_pile(key: String) -> bool:
	return key.begins_with("bot_combo_") or key.begins_with("bot_group_")

## BOT 区的全部摞：[{cards: Array[CardEntity], key: String, compact: Variant}]，
## 组合在前、闲置在后。compact 是对手声明的收拢位（true/false），
## null = 他没说，形态照几何定（单机局的 BOT 摞、闲置资源摞都是 null）
func _bot_piles() -> Array:
	var out: Array = []
	var claimed := {}   # 已经被前面的摞收走的 uid，一张牌只进一摞
	var i := 0
	for combo in _main.state.combos:
		if combo["owner"] != _main.foe_seat:
			continue
		var cs: Array = []
		for u in combo["uids"]:
			claimed[int(u)] = true
			# 组合里的牌也可能正被拖着（对手把整组拎起来挪位置），
			# 同 _collect_idle_units 那条租约
			if entities.has(u) and is_instance_valid(entities[u]) \
					and not _main.is_drag_leased(int(u)):
				cs.append(entities[u])
		if not cs.is_empty():
			# 收拢位从**对手的声明**里继承（按 uid 查，见 main.foe_compact_of）：
			# 他收手那一刻这一摞从 bot_group_* 变成 bot_combo_*，而声明里那一位
			# 还在。不继承的话玩家看见的是「收手一瞬间对面的摞自己摊开了」——
			# 而他那边一直是收拢的。查不着（单机局、或者组合不是从摞来的）返回
			# null，形态照几何定，也就是这条改动之前的行为
			var declared: Variant = _main.foe_compact_of(int(combo["uids"][0])) if not \
				(combo["uids"] as Array).is_empty() else null
			# 次序照 combo["uids"] 来 —— 那**就是**他屏幕上的次序
			# （_register_player_combos 按 g["cards"] 的次序发 create_combo，
			# GameState.create_combo 原样 duplicate 存下）。同 _declared_piles
			# 那条：只在收拢态提核心卡，摊开态照原样摆
			var rec := { "cards": _order_as_declared(cs, declared),
				"key": "bot_combo_%d" % i, "compact": declared }
			# 位置也从声明里继承，同 compact 那一条（见 main.foe_anchor_of）：
			# 他收手那一刻这一摞从 bot_group_* 变成 bot_combo_*，不继承的话
			# 玩家看见的是「收手一瞬间对面那一摞自己跳回行中间了」。
			# 查不着（单机局的 BOT、或者组合不是从摞来的）就不放这个键
			if not (combo["uids"] as Array).is_empty():
				var uv: Variant = _main.foe_anchor_of(int(combo["uids"][0]))
				if uv != null:
					rec["anchor"] = uv
			out.append(rec)
		i += 1
	# 对手**声明**的摞（还没编成组合的那些，见 Protocol.PILES）。
	# 排在组合之后、闲置摞之前：它们和组合同属「他自己摆出来的分组」，
	# 该摆在同一行；等他收手时那几摞会变成真组合（_register_player_combos），
	# 位置不跳 —— 从 bot_group_* 换成 bot_combo_* 而已。
	#
	# 组合**优先**：已经在 state.combos 里的 uid 从声明里剔掉。
	# 反过来（声明盖过组合）的话，对手收手那一刻同一批牌会既属于组合、
	# 又属于声明摞，两条布局互相抢位
	for p in _declared_piles(claimed):
		out.append(p)
	# 声明摞收走的牌不能再进资源摞：不剔的话同一张牌会被摆两次
	# （先摆进声明摞、又摆进 bot_cash），后摆的赢 —— 症状是声明的摞里
	# 缺牌，而缺的那几张躺在资源堆上
	var idle := _collect_idle_units(_main.foe_seat, claimed)
	# 闲置卡按资源各摞一摞：同一种资源只出现一摞，**不按张数切块**。
	# 切块（几十张现金按 PILE_CHUNK 摊成好几摞）会让玩家看到「同一种资源摞了好几坨」——
	# 摞的意义是把一类东西收成一个对象，切块反而把这个意义拆没了。
	# 张数在侧边清单里写着，一摞多高都读得出来。
	# 第三摞是没编进组合的核心/Buff 卡（买来还凑不齐配方的生产卡、攻击卡、
	# 没贴上的加成卡）：不收进来的话它们不在任何摞里，_layout_bot_zone 就不管它们，
	# 只能留在 _free_spot 当初随手找的空位上，跟摞好的组合互相压边
	var names := ["bot_cash", "bot_user", "bot_bench"]
	for k in 3:
		var pile: Array = idle[k]
		if pile.is_empty():
			continue
		if k == 2:
			# 备牌**按卡面分摞**，不是全塞进一摞。
			#
			# 资源摞收拢是对的：20 张现金张张一样，收成一摞、侧边写个 ×20，
			# 该知道的就全知道了。备牌摞不一样 —— 里头是刷不停、左空、春晚、
			# 百亿补贴、黑公关、裂变这些**互不相同**的卡，收成一摞只露得出
			# 最上面那一张，侧边那个 ×6 说得出「有六张」，说不出「是哪六张」。
			# 实测 6 张不同的核心卡全落在同一个 x 上、z 只铺开 0.25，
			# 而牌的纵深是 1.7 —— 85% 互相盖住，屏幕上就是一张牌。
			# 这正是报上来的「BOT 整理后把组合牌都摞在一块儿看不清」。
			#
			# 分摞的口径是 def_id：**同一张卡**摞在一起（两张裂变收成一摞、
			# 侧边 ×2，跟资源摞同一个道理），**不同的卡**各占一摞。
			# 不按张数切块（见上面那段）—— 那会把同一张卡切成好几坨。
			#
			# 次序按 def_id 排，不按手里的先后：不排的话同一批卡在两趟理牌之间
			# 会换位置（idle 的次序跟着 state.players 的增删走），
			# 屏幕上就是「什么都没做，BOT 的备牌却自己重排了一遍」。
			# 摞内仍然核心卡提到摞顶（同一张卡的那几份，露哪一份都一样，
			# 但 Board.core_first_order 那条口径就在这儿，别另起一套）
			var by_def := {}
			for e in pile:
				var d: String = e.def_id
				if not by_def.has(d):
					by_def[d] = []
				by_def[d].append(e)
			var defs: Array = by_def.keys()
			defs.sort()
			for bi in defs.size():
				var sub: Array = by_def[defs[bi]]
				if sub.size() >= 2:
					sub = Board.core_first_order(sub)
				out.append({ "cards": sub, "key": "bot_bench_%d" % bi })
			continue
		out.append({ "cards": pile, "key": "%s_0" % names[k] })
	return out

## 把所有摞收拢好铺在 BOT 区：组合排前行（整行居中），闲置摞坐后行的固定席位。
## 席位与玩家侧镜像对称 —— 现金左、用户右，两边看过去是同一个布局
func _layout_bot_zone() -> void:
	board.clear_side_badges()   # 摞的数量/内容每步都在变，先全清再按当前情况重挂
	_bot_pile_of_uid.clear()
	_bot_pile_uids.clear()
	_bot_pile_compact.clear()
	var combos: Array = []
	var idles: Array = []
	for p in _bot_piles():
		if is_front_pile(p["key"]):
			combos.append(p)
		else:
			idles.append(p)
	# 前行：组合。先让每组按自己的张数摊开，再按「最宽那组 + 空当」定统一节距，
	# 整行居中；摆不下就降列（降到收拢），压到挤在一起也留在一行 ——
	# 换行会把第二行摆到闲置摞的席位上，两片牌互相压边比挤一点更难读。
	# 节距不再是固定的 BOT_SLOT_PITCH：固定 2.5 时 2 列组合正好占满一格，
	# 相邻两组零空当地连成一片（见 BOT_SLOT_PITCH / plan_combo_row）
	var plan: Array = plan_combo_row(combos.map(
		func(p: Dictionary) -> Dictionary:
			return { "n": (p["cards"] as Array).size(), "compact": p.get("compact", null) }))
	for i in combos.size():
		# 没有声明位置时的落点：整行居中的第 i 个位置（下面若有 anchor 就不用它）
		var at := Vector3(float(plan[i]["x"]), 0.05, BOT_ROW_Z[0])
		# 摊开还是收拢**一组一组地判**，不是整行统一。
		#
		# 玩家侧就是这样的：同一片桌面上他可以让一组摊开、另一组双击收拢
		# （board.toggle_compact 是按组的）。整行统一的话，一个 8 张的组合
		# 摊不开就把同行 3 张的那几个也一起按成收拢 —— 明明摊得下。
		# 两种形态混在一行也读得出来：收拢的那几摞有侧边清单写着张数
		# （board.show_side_badges，摊开的不挂，见 _spread_bot_combo）
		var n: int = combos[i]["cards"].size()
		# 分几列、步长多少、以及「对手明说摊开」那一位，都由 plan_combo_row
		# 一次算好 —— 它要按整行最宽的那组定节距，所以只能整行一起算。
		# 那几条规则**只写在那儿一处**：抄一份在这里的话，改坏一处另一处顶上，
		# 判据两头都绿（memory: vacuous-mutation-two-flavors 的第二种）
		var cols: int = int(plan[i]["cols"])
		var step: float = float(plan[i]["step"])
		var declared_spread: bool = bool(plan[i]["declared_spread"])
		# 对手**说了**这一摞摆在哪，就摆在那儿（镜像到我这半边）——
		# 不再按「第几摞」现算格子。见 main.my_pile_lists / foe_pile_point。
		# 他没说（单机局的 BOT、老形状的包）就还是整行居中，一如从前
		var uv: Variant = combos[i].get("anchor", null)
		# 量 z 跨度按**一列里有几张**：分列之后整摞的 z 跨度就是一列的跨度，
		# 拿 n 去量会多算好几倍，那一摞会缩着摆（见 _pile_z_span 那段）
		var per_col: int = ceili(float(n) / float(maxi(cols, 1)))
		if uv is Vector2:
			at = _pile_anchor_at(uv, _pile_z_span(per_col, step))
		elif declared_spread:
			# 南端钉行线、往北长：整列朝北挪 step*(n-1)，
			# 台阶方向不变（沿 +z），所以最南那张正好落回行线
			at.z -= step * float(n - 1)
		if step > 0.0:
			_spread_bot_combo(combos[i], at, step, cols)
		else:
			_place_bot_pile(combos[i], at)
	# 后行：闲置摞的固定席位。key 决定 x，不看是第几摞 —— 现金永远在左边那个位置。
	# 备牌摞是例外：它按卡面分成了好几摞（见 _bot_piles），几摞就得占几个 x，
	# 全落在 BOT_PILE_BENCH_X 上的话分摞白分（那正是分摞之前的样子）
	var spread: bool = _spread_bot_res(idles, combos.is_empty())
	idles = _merge_bench_overflow(idles, spread)
	var bench_x: Dictionary = _bench_seats(idles, spread)
	for p in idles:
		var key: String = p["key"]
		var x: float = BOT_PILE_BENCH_X
		if key.begins_with("bot_cash"):
			x = _bot_resource_anchor(CardDB.RES_CASH).x
		elif key.begins_with("bot_user"):
			x = _bot_resource_anchor(CardDB.RES_USER).x
		elif bench_x.has(key):
			x = float(bench_x[key])
		# 摊开这一片时资源牌照玩家侧的列摆，其余（备牌摞）照旧收拢
		if spread and key.begins_with("bot_cash"):
			_spread_bot_pile(p, PLAYER_PILE_CASH_ANCHOR.x)
		elif spread and key.begins_with("bot_user"):
			_spread_bot_pile(p, PLAYER_PILE_USER_ANCHOR.x)
		else:
			_place_bot_pile(p, Vector3(x, 0.05, _bot_back_z(p["cards"].size())))
	# 三个摆放函数只是把请求攒进 _bot_pending，到这里才按落点高低一次发出去。
	# **必须在整趟的末尾**：次序要看整桌的落点，一摞一摞地发就只在摞内排得对，
	# 跨摞那几对（正是探针里越线最狠的那几对）照旧对调
	_flush_bot_moves()

## 一种资源摊开到几列就该改收拢。
##
## 取「开局那种资源摊出来的列数」：开局是两边形态必须一致的那一刻
## （玩家摊开、BOT 也摊开，见 BOT_SPREAD_Z0），那时的列数就是这一片
## **本来该占多宽**。牌比开局多出来的部分不该让这一片跟着横向长 ——
## 长下去就是「资源牌多的时候反而不怎么摞」：实测现金能摊到 7 列 56 张、
## 用户 5 列 40 张，横着占掉大半个 BOT 区，一眼看不出是几张。
## 到顶就收拢，张数交给侧边清单说。
##
## 按资源分别算，不取一个统一的数：开局现金 20 张（3 列）、用户 10 张（2 列），
## 两片本来就不一样宽，统一成一个数必有一边对不上开局的形态。
##
## 从规则表算而不是读玩家侧的实时列数：实时列数要看玩家有没有理牌、
## 这一刻理到哪一步了，BOT 的形态会跟着玩家的操作抖。规则表那两个数
## （start_cash / start_user）是常量
func spread_max_cols(res: String) -> int:
	var rules: Dictionary = CardDB.game_rules()
	var n0: int = int(rules["start_cash" if res == CardDB.RES_CASH else "start_user"])
	return maxi(1, ceili(float(n0) / float(PLAYER_PILE_PER_COL)))

## 收拢席位与当前卡表的开局资源片中线对齐。切换卡表时重新计算，
## 不缓存旧配置的中线，也不跟随玩家回合中的资源增减来回移动。
func _bot_resource_anchor(res: String) -> Vector3:
	var anchor := PLAYER_PILE_CASH_ANCHOR if res == CardDB.RES_CASH else PLAYER_PILE_USER_ANCHOR
	anchor.x += float(spread_max_cols(res) - 1) * PLAYER_PILE_COL_PITCH / 2.0
	anchor.z = BOT_ROW_Z[-1]
	return anchor

## 这一轮 BOT 的资源该摊开还是收拢。三条都过才摊开：
##   1. 没有组合 —— 有组合时前行要让给组合，摊开那一片会横穿 BOT 区压在组合上
##   2. 不比开局那一片更宽 —— 见 spread_max_cols，这条治的是
##      「资源牌多的时候也不怎么摞」
##   3. 不出桌 —— BOT_SPREAD_MAX_X 那条兜底
## 开局正是三条都过的时候，于是开局两边形态一致：玩家摊开，BOT 也摊开
func _spread_bot_res(idles: Array, no_combos: bool) -> bool:
	if not no_combos:
		return false
	for p in idles:
		var key: String = p["key"]
		var x0: float = PLAYER_PILE_CASH_ANCHOR.x
		var res: String = CardDB.RES_CASH
		if key.begins_with("bot_user"):
			x0 = PLAYER_PILE_USER_ANCHOR.x
			res = CardDB.RES_USER
		elif not key.begins_with("bot_cash"):
			continue      # 备牌摞不摊开：杂项卡在玩家侧本来就没有对照的一片
		var cols: int = ceili(float(p["cards"].size()) / float(PLAYER_PILE_PER_COL))
		if cols > spread_max_cols(res):
			return false
		var right: float = x0 + float(cols - 1) * PLAYER_PILE_COL_PITCH \
			+ CardEntity.CARD_SIZE.x / 2.0
		if right > BOT_SPREAD_MAX_X:
			return false
		# 现金那一片不许长到用户那一片的头上：中间至少留得下一列
		if key.begins_with("bot_cash") \
				and right > PLAYER_PILE_USER_ANCHOR.x - PLAYER_PILE_COL_PITCH:
			return false
	return true

## 备牌摞多到摆不下时，把超出 bench_seat_cap() 的那几摞并成一摞收拢。
##
## 为什么在这儿并、不在 _bot_piles 里并：摆得下几摞要看窗口，而窗口要看资源
## 摊开没摊开（_spread_bot_res），那个判断的输入正是 _bot_piles 的输出 ——
## 在 _bot_piles 里并就得先知道自己的结果。这儿两样都齐了。
##
## 并的是**末尾那几摞**（def_id 排序后的），不是随便几摞：次序稳定，
## 同一批卡不会在两趟理牌之间换人并进去。留在外面的那几种也就不会跳位置
func _merge_bench_overflow(idles: Array, spread: bool) -> Array:
	var bench: Array = []
	var rest: Array = []
	for p in idles:
		if str(p["key"]).begins_with("bot_bench"):
			bench.append(p)
		else:
			rest.append(p)
	if bench.size() <= 1:
		return idles
	var win: Vector2 = bench_window(idles, spread)
	var cap: int = bench_seat_cap(win.x, win.y)
	if bench.size() <= cap:
		return idles
	bench.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["key"]) < str(b["key"]))
	var out: Array = []
	# 前 cap-1 摞照旧一种一摞，第 cap 个席位坐并起来的那一摞
	for i in cap - 1:
		out.append({ "cards": bench[i]["cards"], "key": "bot_bench_%d" % i })
	var merged: Array = []
	for i in range(cap - 1, bench.size()):
		for e in bench[i]["cards"]:
			merged.append(e)
	if merged.size() >= 2:
		merged = Board.core_first_order(merged)
	out.append({ "cards": merged, "key": "bot_bench_%d" % (cap - 1) })
	return out + rest

## 备牌这一片能用的 x 窗口 [lo, hi]。
##
## 由**左右两个资源席位**定，且资源摊开与否会改这个宽度：收拢时资源各占一摞
## （各自开局资源片的中线），摊开时现金往右长、用户从左边缘起。
## 所以两边的内缘都问一遍 —— 不问的话开局那一趟备牌会压在摊开的现金片上。
##
## 一处定义：席位表和 bench_seat_cap 都得按同一个窗口算，各写一遍的话
## 「算得下」和「摆得下」会对不上（memory: number-lives-in-five-places）
func bench_window(idles: Array, spread: bool) -> Vector2:
	var left: float = _bot_resource_anchor(CardDB.RES_CASH).x
	var right: float = _bot_resource_anchor(CardDB.RES_USER).x
	if spread:
		for p in idles:
			var k2: String = str(p["key"])
			var n2: int = (p["cards"] as Array).size()
			var cols: int = ceili(float(n2) / float(PLAYER_PILE_PER_COL))
			if k2.begins_with("bot_cash"):
				left = PLAYER_PILE_CASH_ANCHOR.x \
					+ float(cols - 1) * PLAYER_PILE_COL_PITCH
			elif k2.begins_with("bot_user"):
				right = PLAYER_PILE_USER_ANCHOR.x
	# 两边各让开一张卡加一点空当，剩下的就是备牌这一片能用的宽
	var edge: float = CardEntity.CARD_SIZE.x + 0.2
	return Vector2(left + edge, right - edge)

## 备牌各摞的 x 席位：key → x。以 BOT_PILE_BENCH_X 为中心一字排开。
##
## 为什么要算而不是写死一串常量：备牌摞有几摞看的是「BOT 手里有几种还没编组的卡」，
## 从 0 到二十几都可能（卡表里非资源卡 29 种），写死席位表要么不够用、
## 要么留一大片空位。能用多宽见 bench_window，摆得下几摞见 bench_seat_cap ——
## 进到这儿的 k 已经是摆得下的数了（超出的在 _merge_bench_overflow 那头并掉）
func _bench_seats(idles: Array, spread: bool) -> Dictionary:
	var keys: Array = []
	for p in idles:
		if str(p["key"]).begins_with("bot_bench"):
			keys.append(str(p["key"]))
	var out := {}
	if keys.is_empty():
		return out
	keys.sort()
	var win: Vector2 = bench_window(idles, spread)
	var lo: float = win.x
	var hi: float = win.y
	var k: int = keys.size()
	if k == 1:
		out[keys[0]] = BOT_PILE_BENCH_X
		return out
	var pitch: float = minf(PLAYER_PILE_COL_PITCH,
		(hi - lo) / float(k - 1))
	pitch = maxf(pitch, CardEntity.CARD_SIZE.x)
	# 以 BOT_PILE_BENCH_X 为中心排：整片居中，跟前行组合那一行同一个口径
	var x0: float = BOT_PILE_BENCH_X - pitch * float(k - 1) / 2.0
	# 但**要落回窗口里**。节距是从窗口宽反解的，居中的位置却是按 BENCH_X 算的，
	# 而 BENCH_X（-2.0）不是窗口的中点 —— 两个基准不是一个数，居中完就可能
	# 探到窗口外面去。实测 6 摞时最左那摞落在 -5.00，而摊开的现金片右缘在
	# -4.80，两者相差 0.20、牌宽 1.2，正好是一次真穿模。
	# 先按 BENCH_X 居中（地方够时那就是想要的位置），再整片平移回窗口内
	var span: float = pitch * float(k - 1)
	# 整片必须落在窗口里。摆不下的时候**不许把片撑出窗口** —— 试过，
	# 29 种卡时最外那几摞落到 x = -18.80 / -17.60 / 12.40 / 13.60 / 14.80
	#（BOT_SPREAD_MAX_X 是 12.4，直接出桌），
	# 而且照旧压在现金片上，比不分摞还糟。摆不下由 bench_seat_cap()
	# 那头削摞数解决（多出来的并成一摞收拢），到这里 k 已经是摆得下的数了
	x0 = clampf(x0, lo, hi - span)
	for i in k:
		out[keys[i]] = x0 + pitch * float(i)
	return out

## 备牌这一片摆得下几摞。超出的那些并成一摞收拢（见 _layout_bot_zone）。
##
## 为什么要削而不是把节距压到卡宽以下：压下去就是让牌互相盖住，
## 而「不许互相盖住」是整个后行的口径（tests/test_tidy.gd 盯着）。
## 为一种少见的局面（同时攥着十几种编不成组的卡）在那条不变量上开个口子，
## 代价比「多出来的那几种并成一摞、张数交给侧边清单说」大。
##
## 并起来那一摞不是黑箱：Board.side_spec 会把摞里的核心卡按卡种列进侧边清单
## （最多 Board.SIDE_MAX_ROWS 行，再多折成一行「+N 种」）。
## 实测真实对局里备牌最多攥到 7 种、席位摆得下 5 摞，并进去的通常两三种，
## 清单一行一种全列得出来。
## 前 cap-1 种仍然一种一摞、各自在桌上占个位置，这是常态局面
func bench_seat_cap(lo: float, hi: float) -> int:
	if hi <= lo:
		return 1
	# 节距下限是一张卡宽（边挨边，谁也没盖住谁），所以窗口里塞得下
	# floor((hi-lo)/卡宽) + 1 个席位
	return maxi(1, floori((hi - lo) / CardEntity.CARD_SIZE.x) + 1)

## 同一列内的台阶步长。想要的是照抄玩家侧的 Board.STACK_GAP.z，
## 但双方初始资源列从不同的远近边缘出发：直接照抄时 BOT 最南端卡心到市场
## 只有 2.16，玩家最近卡心到市场为 3.10，会破坏双方资源与购牌区的间距关系。
## 所以按「南端和玩家侧一样远」反解步长，再以玩家侧的步长收口：
## 地方够就和玩家一模一样，不够才压，压也只压这一处
func _bot_spread_step(n: int) -> float:
	if n <= 1:
		return Board.STACK_GAP.z
	var keep: float = absf(PLAYER_PILE_CASH_ANCHOR.z - _main.MARKET_Z)
	var south: float = _main.MARKET_Z - keep      # 最南那张的 z 上限
	return minf(Board.STACK_GAP.z, (south - BOT_SPREAD_Z0) / float(n - 1))

## 对手侧那几张牌正在跑的归位补间，uid → Tween。
##
## 为什么要记：租约（scenes/main.gd 的拖拽广播与租约处理）只挡住「之后」的摆放 —— _collect_idle_units
## 和 _bot_piles 里那两条 is_drag_leased 让被拖的牌不再进入摆放清单。但**已经在跑**
## 的补间挡不住，它会在接下来的 0.3 秒里逐帧把 position 写回摞里，
## 而网络那头每 50ms 写一次新位置。两边打架的样子是牌抽搐着往摞里缩回去。
##
## 为什么不用 fly_tw 那个 meta：tests/harness.gd 的 arrivals_landed 拿它当
## 「到货飞完了没」的判据，摆放补间挂上去会让测试等一堆无关的补间
## （memory: settle-runs-mid-flight 里等错东西的那个坑）
var _bot_tw := {}

## 归位补间的时长。开成常量是为了让 tests/harness.gd 的 bot_moves_landed
## 能按它折算兜底上限 —— 等多久由补间自己说，不写死在测试里
const BOT_MOVE_TIME := 0.3

## 一趟理牌从发出到最后一张落地要多久。tests/harness.gd 的 bot_moves_landed
## 按它折算兜底上限。
##
## 等于单条补间的时长，因为**一趟里所有牌同时出发、同时落地**。
## 错开出发试过两回，两回都退回来了：
##   按张错开：同一摞的 y 差靠「同一时刻处在弧线的同一相位」保住，错开之后
##             一整摞平移时 27 对牌的 y 差全漂到 0.002 以下 —— 比不抬还惨
##   按摞错开：想治的是「两张各自长途、飞向不同摞，y 曲线脱钩后擦在一起」。
##             实测治不了 —— 撞的那一对里有一张**已经停住**了（见 foot_gate
##             那段末尾），错开出发对停着的牌没有意义。变异到 0 之后判据一条不红，
##             那就是一段不干活的机制，删掉；每趟少 0.24 秒
static func bot_pass_time() -> float:
	return BOT_MOVE_TIME

## 飞行途中抬起来的余量：越过被飞过的那些摞的顶。
##
## 为什么非抬不可（Board.ladder_y 写的那条不变量的动态版）：占地重叠的两张卡
## y 差必须大于 CardEntity.FACE_SPAN_Y，否则下面那张的图标/卡名比上面那张的
## 底板还高，从底板里穿出来。**静止时靠台阶高满足，飞行途中没人管** ——
## 一张从 20 张厚的摞上下来的牌（y≈1.5）飞去另一摞的底座（y≈0.05），
## 半路正好穿过第三摞的中间高度，而那一摞的占地就在航线上。
## 实测一趟重排里有 5 对牌的最小 y 差落到 0.003~0.020（探针 probe_flight）
const BOT_LIFT_MARGIN := 0.12

## 这一趟里牌能飞到的最高处：桌上最高那张卡的顶 + 余量。
## 按**这一趟出发前**的实际高度算，不写死：摞多厚由张数决定，
## 写死一个数会在几十张的摞上不够抬（照旧穿模），在开局的薄摞上抬得离谱
func _lift_ceiling() -> float:
	var top := 0.0
	for uid in entities:
		var e: CardEntity = entities[uid]
		if is_instance_valid(e):
			top = maxf(top, e.position.y)
	return top + BOT_LIFT_MARGIN

## 航迹上「已经脱开出发那片占地」的那个进度（0~1），按**这条航迹自己的方向**算。
##
## 两张卡的占地重叠意味着 x 差 < CARD_SIZE.x **且** z 差 < CARD_SIZE.z ——
## 是**且**，所以「脱开」这件事沿两个轴各有一条线，先过的那条就算脱开了。
##
## 原先这儿是一个圆（半径 √(1.2²+1.7²)≈2.08，即那个矩形最远的角），
## 于是纯 x 向飞的牌明明走 1.2 就脱开了，却要多滑 0.88 才肯落 y ——
## 而这一段是**贴着落点高度**滑的，各摞底座又都在 0.05 上，
## 多滑的那一段就从邻摞已经停好的牌上面擦过去。
##
## 实测（tests/test_tidy.gd 第 3 节按算式密采整趟，不是按帧采）：
##   圆 2.08：跨摞掠过 14 对，最小 y 差低到 0.0000
##   圆 0.85（只够半张卡）：7 对 —— 少一半，但这个值本身没有道理，
##            它小于「一定脱开」所需，斜向飞的牌会在还压着出发占地时就动 y
##   按矩形算（本函数）：7 对，且每一段的起止都踩在「真的脱开了」那一刻上
## 也就是说原先那句「这个半径两头堵、别再来回调」是**被采样骗的** ——
## 按帧采只看得见 14 对里的 2 对，于是长半径看着比短半径干净。
## 换成密采之后长半径明显更差，而正确的做法不是在两个坏值之间选，
## 是把「脱开」这件事按它本来的形状（矩形）算。
##
## 剩下的 7 对是**摆放本身**的账，不是航迹的账：牌要滑进的座位离邻摞不足一张卡，
## 落点高度又都是 0.05，横着进座位就一定从邻摞上面过。要清零得让座位之间
## 留出一整张卡的空当（改的是 BOT_SLOT_PITCH / COMBO_COL_PITCH 那一层），
## 或者给降落留一条空走廊 —— 两行之间现在没有这样的走廊（BOT_ROW_Z 相距 2.4，
## 一张卡的纵深 1.7，两边各让半张就只剩 0.7）。没做，因为那是重排整个 BOT 区。
## tests/test_tidy.gd 第 3 节盯着这个残留值不许变大
##
## 返回值 ≥ 0.5 表示「整条航迹都在两片占地里」（短程），调用处走平飞
static func foot_gate(from: Vector3, at: Vector3) -> float:
	var dx: float = absf(at.x - from.x)
	var dz: float = absf(at.z - from.z)
	# 沿这条直线走到「x 差够了」或「z 差够了」，先到的那个就脱开了。
	# 某个轴上根本不动（dx=0）时那个轴永远不够，取另一个轴
	var fx: float = CardEntity.CARD_SIZE.x / dx if dx > 0.0 else INF
	var fz: float = CardEntity.CARD_SIZE.z / dz if dz > 0.0 else INF
	return minf(fx, fz)

## 本趟攒下的搬牌请求：[[实体, 落点], ...]。
## 攒起来而不是当场发，是因为**发出的次序要按落点高低排**（见 _flush_bot_moves）
var _bot_pending: Array = []

## 「落点就是现在站的地方」的判定余量。比台阶高（STACK_GAP.y = 0.024）小一个量级：
## 摆放函数算出来的落点是同一套算式的输出，没动的牌两边逐位相同，
## 这个余量只是防浮点尾数，不该把「挪了半个台阶」也算成没动
const BOT_STILL_EPS := 0.001

## 攒一条对手侧的归位请求。真正发补间在 _flush_bot_moves。
##
## **落点等于现在的位置就直接返回**，不排队也不发补间。理牌每趟都对全桌每张牌
## 调一次本函数，而一趟里真正换地方的只有个别几张（实测 76 张里 11 张）。
##
## 守穿模那条不变量**不靠这一句**：原地不动的牌 span=0，进 _bot_arc 也走
## 「短程平飞」那一支，y 一动不动（试过删掉这句，判据全绿 —— 别再把这句
## 当成不变量的防线写注释了）。它管的是另一件事：一趟里不该有几十条
## 什么都不干的补间在跑。bot_moving() 是测试和 main 的同步条件，
## 空跑的补间会让「摆完了没有」在整个 BOT_MOVE_TIME 里一直答「没有」
func _bot_move(e: CardEntity, at: Vector3) -> void:
	if e.position.distance_to(at) < BOT_STILL_EPS:
		kill_bot_move(e.uid)
		e.position = at
		return
	_bot_pending.append([e, at])

## 把本趟攒下的请求一次发出去，**整趟共用同一个抬升量**。
##
## 为什么必须是「同一个抬升量」而不是「同一个飞行高度」（这条是实跑探针改出来的）：
## 一趟里最常见的动作是**一整摞平移**（BOT 区多了一摞、整行重新居中，
## 摞里每张牌的落点都只是原位 +Δxz，y 一点不变）。摞里两张牌的 y 差
## 靠的是台阶高（0.024~0.045），只比 FACE_SPAN_Y 大一点点。
## 抬到同一个高度 = 底下那张抬得多、上面那张抬得少，飞到半途整摞压成一个平面，
## 实测 9 张的摞里 27 对牌的 y 差全掉到 0.002 以下 —— 比不抬还惨。
## 抬同一个 Δy 则两两 y 差原样保持，整摞是刚体地飞过去。
##
## 抬升量按**本趟最低的那张**折算，让每张都至少越过桌上最高的摞顶：
## 抬得比这个少就有牌从摞中间穿过去，多则纯粹是飞得夸张
func _flush_bot_moves() -> void:
	var moves: Array = _bot_pending
	_bot_pending = []
	_bot_flight.clear()
	if moves.is_empty():
		return
	var low: float = INF
	for m in moves:
		low = minf(low, minf((m[0] as CardEntity).position.y, (m[1] as Vector3).y))
	var lift: float = maxf(0.0, _lift_ceiling() - low)
	for m in moves:
		var e: CardEntity = m[0]
		_bot_flight[e.uid] = {"from": e.position, "at": m[1] as Vector3, "lift": lift}
		_bot_fly(e, m[1], lift)

## 发一条对手侧的归位补间，替掉这张牌上一条还没跑完的。
##
## 三个轴**由同一个参数驱动**（一条 tween_method 里一起写 position），
## 不是三条各自带缓动的补间：y 抬多少要看「这一刻横向走到哪了」，
## 分开三条就没有这个共同的相位可依。
##
## 航迹是「平 → 抬 → 平」三段：
##   1. 还压在出发点那片占地上时 y **一动不动**。这一段的邻居是原摞的同伴，
##      它们之间的 y 差是台阶高定的，一升就把这点余量吃掉 —— 正是要修的穿模
##   2. 两头占地都脱开了，才把 y 抬起来越过航线上的摞顶
##   3. 进了落点那片占地就把 y 落回去，之后平着滑进座位
## 于是「垂直穿过一摞」这件事从航迹里消失了：出摞和进摞都是横着走的。
##
## y 绝不用 TRANS_BACK 之类会过冲的曲线：向下那一段过冲会把牌按到落点**以下**，
## 扎进底下那张牌里（过冲量约位移的 10%，而台阶高只有 0.024）
##
func _bot_fly(e: CardEntity, at: Vector3, lift: float) -> void:
	kill_bot_move(e.uid)
	# 连续收到交易时，归位接管尚未结束的到货飞行，避免两条补间争写位置。
	_main._cancel_fly(e)
	var from: Vector3 = e.position
	var span: float = Vector2(at.x - from.x, at.z - from.z).length()
	var gate: float = foot_gate(from, at)
	var tw := create_tween()
	tw.tween_method(
		func(f: float) -> void:
			if is_instance_valid(e):
				e.position = _bot_arc(from, at, span, gate, lift, f),
		0.0, 1.0, BOT_MOVE_TIME)
	_bot_tw[e.uid] = tw

## 航迹上 f∈[0,1] 处的坐标。抽成独立函数是为了让测试能直接采样整条航迹，
## 不必真跑补间去逐帧读（补间的采样点由帧率决定，短程的牌可能只被采到两三帧）。
##
## 缓动写在函数里、补间那头喂线性的 f：横向进度和 y 的分段判据必须是**同一个数**。
## 交给补间去缓动的话，函数里拿到的 f 是缓动后的，而 t0/t1 是按「横向走了多远」
## 算的 —— 两者差一层曲线，闸门就开在错的地方
static func _bot_arc(from: Vector3, at: Vector3, span: float, gate: float,
		lift: float, f: float) -> Vector3:
	# 两头**照原样返回端点**，不走下面的插值。
	# lerp(from, at, 1.0) 算的是 from + (at - from) * 1.0，浮点下不保证等于 at ——
	# 差一个 ulp。而摆放算出来的落点常常正好压在判据的分桶边界上
	# （比如 x=6.25，tests/test_bot_pile.gd 按 snappedf(x, 0.1) 分列），
	# 差一个 ulp 就把一摞牌记成「跨 2 列」
	if f >= 1.0:
		return at
	if f <= 0.0:
		return from
	# 横向的缓动：两端速度为 0，中间快。y 不跟着这条曲线，见下
	var u: float = 0.5 - 0.5 * cos(PI * f)
	var p: Vector3 = from.lerp(at, u)
	if gate >= 0.5 or lift <= 0.0:
		# 走不出两片占地的短程（一整摞平移就是这种）：全程平飞。
		# 抬不抬都躲不开原摞的同伴，而平飞时两两 y 差原样保持，本来就不越线
		p.y = lerpf(from.y, at.y, u)
		return p
	# 横向走出出发占地、且还没进落点占地的那一段，才是能动 y 的窗口。
	# 两头对称（出发和落点是同一条直线的两端，脱开所需的位移一样），
	# 所以一个 gate 够用 —— 它已经是「走了整段的百分之几」
	var t0: float = gate
	var t1: float = 1.0 - gate
	if u <= t0:
		# 还压在出发那片占地上：y **一点不许动**。
		# 只冻抬升不冻 lerp 是不够的 —— 从 20 张厚的摞顶飞去别处的那张，
		# 光 lerp 就能在头几帧把它拽到原摞同伴的高度上（实测 dy 掉到 0.002）
		p.y = from.y
		return p
	if u >= t1:
		# 已经进了落点那片占地：y 已经落到位，平着滑进座位
		p.y = at.y
		return p
	# 窗口内才走完整段升降，外加 sin 拱起来的弧线越过航线上的摞顶。
	# 两端 sin 为 0 且斜率为 0，接上前后的平飞段不会有折角
	var w: float = (u - t0) / (t1 - t0)
	p.y = lerpf(from.y, at.y, w) + lift * sin(PI * w)
	return p

## 还有对手侧的归位补间在跑吗。测试拿它当「摆完了没有」的同步条件：
## 按墙钟等在 CPU 被抢的时候会读到出发点（memory: flaky-baseline-kills-mutation-run）
func bot_moving() -> bool:
	for uid in _bot_tw:
		var tw: Tween = _bot_tw[uid]
		if tw != null and tw.is_valid() and tw.is_running():
			return true
	return false

## 掐掉这张牌的归位补间。租约开始时由 main._lease_foe_cards 调
func kill_bot_move(uid: int) -> void:
	if _bot_tw.has(uid):
		var tw: Tween = _bot_tw[uid]
		if tw != null and tw.is_valid():
			tw.kill()
		_bot_tw.erase(uid)

## 一片摊开的资源牌：列的 x 和每列张数照玩家侧（见 _group_pile），
## 同一列内沿 +z 长台阶（照 Board._stack_offset），整片摆进 BOT 区。
## 不建 board.groups：那是玩家能拖能典当的东西，BOT 的牌只是给人看的
func _spread_bot_pile(pile: Dictionary, x0: float) -> void:
	var cards: Array = pile["cards"]
	var key: String = pile["key"]
	var step: float = _bot_spread_step(mini(cards.size(), PLAYER_PILE_PER_COL))
	for i in cards.size():
		var e: CardEntity = cards[i]
		var seat: int = i % PLAYER_PILE_PER_COL
		var at := Vector3(x0 + float(i / PLAYER_PILE_PER_COL) * PLAYER_PILE_COL_PITCH,
			0.05 + Board.ladder_y(seat),
			BOT_SPREAD_Z0 + step * float(seat))
		e.freeze = true
		_bot_move(e, at)
		_bot_pile_of_uid[e.uid] = key
	_bot_pile_uids[key] = cards.map(func(c: CardEntity) -> int: return c.uid)
	_bot_pile_compact[key] = false

## 一组摊开的组合：按 cols 列切开，同一列内沿 +z 长台阶，北端钉在前行的行线上。
## 步长由 combo_spread_step 定（0 表示摊不开，调用方走 _place_bot_pile 收拢）。
##
## 和 _spread_bot_pile 同一个形状（照 Board._stack_offset 的摊开分支），
## 也一样按列切。原先组合只摆**一列**，理由是「切列会把一个阵型拆成两坨」——
## 那个取舍是反的：z 向一列最多摊得开 4 张（见 combo_per_col），
## 而 21 个配方里 17 个在 5 张以上，于是它们全部退回收拢、摞成一块，
## 屏幕上只看得见最南那一张。拆成两列读得出张数也读得出内容，所以宁可拆。
##
## 不建 board.groups：那是玩家能拖能典当的东西，BOT 的牌只是给人看的
## （同 _spread_bot_pile）。也不挂侧边清单 —— 摊开态每张自己露着标题带，
## 清单是收拢态才需要的替代品（board._sync_side 对玩家侧的摊开组同样不挂）
func _spread_bot_combo(pile: Dictionary, at: Vector3, step: float, cols: int) -> void:
	_refresh_bot_pile_progress(pile)
	var cards: Array = pile["cards"]
	var key: String = pile["key"]
	var n: int = cards.size()
	# 每列几张按列数**匀**，不是「填满一列再开下一列」：10 张分 3 列匀成 4/4/2，
	# 填满式是 4/4/2 —— 同一个结果；但 5 张分 2 列匀成 3/2，填满式是 4/1，
	# 后者那个单张的列在屏幕上像一张落单的牌，不像阵型的一部分
	var per: int = ceili(float(n) / float(maxi(cols, 1)))
	for j in n:
		var e: CardEntity = cards[j]
		# 座次翻过来：cards 是 core_first_order 排的（index 0 是核心卡），
		# 而收拢态里 compact_offset 把 index 0 推到最南、最高 —— 那是唯一
		# 完整露出来的一张，核心卡就该在那儿。摊开态的台阶是 +z*j 往南长、
		# 越往南越高，最南最高的是**最后**一张，所以核心卡要坐 per-1 这个座。
		# 不翻的话核心卡落在最北那个座，被它后面每一张压掉，
		# 屏幕上摊开的组合露的是随便一张用户卡（收拢态露对了、摊开态露错了）
		#
		# 翻的是**列内**的座次（per-1-…），不是整组的（n-1-…）：分列之后
		# 按整组翻会把核心卡算到一个不存在的座上，它反而落到最北去
		var col: int = j / per
		var seat: int = per - 1 - (j % per)
		# 列**以 at.x 为中心**往两边排，不是从 at.x 往右长：at.x 是这一格的中心
		# （整行居中算出来的，或者对手声明的锚点），从它往右长的话
		# 一个两列的组合整片偏右 1.3/2，屏幕上就是「组合没对准自己那一格」
		var dx: float = (float(col) - float(cols - 1) / 2.0) * COMBO_COL_PITCH
		_bot_move(e, at + Vector3(dx, Board.ladder_y(seat), step * float(seat)))
		e.freeze = true
		_bot_pile_of_uid[e.uid] = key
	_bot_pile_uids[key] = cards.map(func(c: CardEntity) -> int: return c.uid)
	_bot_pile_compact[key] = false

## 后行摞的落点 z：摞的远端（index 0，偏移最大的那张）停在行线上。
## 张数多到退不下去就贴着北缘 —— 而台阶封顶之后「退不下去」有了尽头：
## 满 back_pile_cap() 级的摞退到 BOT_BACK_Z_MIN 刚好把南缘顶在前行北缘上，
## 再多的牌不再加台阶，所以后行的摞**不可能**伸进前行（见 back_pile_cap）
func _bot_back_z(n: int) -> float:
	var span: float = Board.capped_offset(n, 0, back_pile_cap()).z
	return maxf(BOT_ROW_Z[1] - span, BOT_BACK_Z_MIN)

## 一摞收拢到 at：逐张发补间、记 uid→key、挂侧边清单。
##
## 台阶封顶在 back_pile_cap() 级（Board.capped_offset）：超出的那几张停在摞底
## 那一级上，所以**这一摞的占地不随张数变**。不封顶的话 100 张现金（胜利线）
## 会摞成一条爬到 y=4.5 的斜坡，南缘压在货架牌上
func _place_bot_pile(pile: Dictionary, at: Vector3) -> void:
	_refresh_bot_pile_progress(pile)
	var cards: Array = pile["cards"]
	var key: String = pile["key"]
	var n: int = cards.size()
	var cap: int = back_pile_cap()
	for j in n:
		var e: CardEntity = cards[j]
		e.freeze = true
		_bot_move(e, at + Board.capped_offset(n, j, cap))
		_bot_pile_of_uid[e.uid] = key
	# 侧边清单挂在摞顶（index 0）的目标位置上，不读实时坐标：tween 还没跑完
	if n >= 2:
		board.show_side_badges(key, cards, at + Board.capped_offset(n, 0, cap))
	_bot_pile_uids[key] = cards.map(func(c: CardEntity) -> int: return c.uid)
	_bot_pile_compact[key] = true

## 对手摞不在 board.groups 中，摆放时也要刷新核心卡的配方与效果墨点。
## 复用玩家侧计算，覆盖尚未提交的半成品、裂变补满以及离组回备牌区；
## 不能只读 state.combos 的旧 eval，否则缺料或移除 Buff 后仍会残留完成态。
func _refresh_bot_pile_progress(pile: Dictionary) -> void:
	var cards: Array = pile["cards"]
	var data: Array = []
	for c: CardEntity in cards:
		data.append({ "uid": c.uid, "def_id": c.def_id })
	board._update_group_progress(pile, ComboRules.evaluate(data))

## uid → 所在 BOT 摞的 key；摞里全部 uid（攻击阶段点摞顶时用来找摞内的合法靶）
var _bot_pile_of_uid := {}
var _bot_pile_uids := {}
## key → 这一摞是不是**收拢**的。
##
## 攻击阶段的红光要照这个分叉：收拢摞只露摞顶那一张，把每个靶都点红等于
## 在看不见的地方点灯，所以收拢摞的红光收到摞顶（玩家点得到的那一张）；
## 摊开的摞每张都露着，就该每个点得起的靶各自变红 ——
## 否则玩家看到一整排组合里只有一张红的（而且那张还是核心卡，压根点不了）。
## 三个摆放函数各自登记，别在 main 那边靠坐标反推「这一摞叠没叠」
var _bot_pile_compact := {}

## 这一趟的航迹计划：uid → {from, at, lift}。只有**真在飞**的牌在里面
## （落点等于原位的那些在 _bot_move 就被挡掉了，见那段注释）。
##
## 记下来是给判据用的：防穿模那条不变量要问「一趟里有没有两张牌被安排成
## 互相穿过去」，而这件事按物理帧采样问不准 —— 一趟 0.3 秒只落到十几帧上，
## 掠过一瞬的那种会不会被采到取决于帧的相位。实测同一条判据在同一台机器上
## 时而 2 对时而 4 对（memory: sampling-cannot-see-jumps）。
## 有了这份计划，判据能拿 _bot_arc 把整条航迹密采一遍，结果不再看帧率。
##
## lift 整趟一个值（见 _flush_bot_moves 为什么不能各飞各的高度），所以逐条都记
## 同一个数，为的是让判据不必自己复算一遍 _lift_ceiling
var _bot_flight := {}

## 玩家理牌：把未编组的零散现金/用户卡整理成真实摞（进 board.groups，可整摞拖动/典当）
## 先解散上轮理牌生成的纯资源摞（有核心的真组合不动），再按每摞 PLAYER_PILE_PER_COL 张重新分组；
## 现金锚左、用户锚右，从低 z 往 +z 排（与分组布局方向一致）。
## 普通牌桌初始卡心从 1.5 起：首张卡北缘为 0.7，避开市场下方缓冲带；
## 满列 8 张的最后卡心为 5.14、卡南缘为 5.94，完整落在玩家视觉托盘内。
const PLAYER_PILE_PER_COL := 8
const PLAYER_PILE_CASH_ANCHOR := Vector3(-8.0, 0.05, 1.5)
const PLAYER_PILE_USER_ANCHOR := Vector3(4.0, 0.05, 1.5)
## 列与列的节距。BOT 侧摊开那一片共用这一份（见 _spread_bot_pile）：
## 两边的列要能一列对一列地对上，节距各写一个数就对不上了
const PLAYER_PILE_COL_PITCH := 1.6

func _tidy_player_idle() -> void:
	# 1. 解散纯资源摞（上轮理牌产物），释放其中的卡重新整理
	for g in board.groups.duplicate():
		var pure := true
		for c in g["cards"]:
			if CardDB.get_def(c.def_id).get("kind") != CardDB.KIND_UNIT:
				pure = false
				break
		if pure:
			board._remove_group(g)
	# 2. 收集散单位卡（与 BOT 共用同一份收集判定）
	var piles := _collect_idle_units(_main.my_seat)
	_group_pile(piles[0], PLAYER_PILE_CASH_ANCHOR)
	_group_pile(piles[1], PLAYER_PILE_USER_ANCHOR)

# ---------- 结算到货窗口 ----------
#
# 一次结算里会连着蹦出好几批产出牌（每个组合一批，见 main._resolve_combo_visual）。
# 每张牌出生时都要当场决定飞去哪儿，可这时候整批牌的实时坐标全在组合中心 ——
# 只看 entities 的话 _free_spot 对每一张都判「那儿是空的」，返回同一个坐标，
# 于是一批牌完全重叠落在一个点上，等结算末尾 _stack_settled 再把它们拽去左侧。
# 玩家看到的就是「先落到别处、糊成一张、然后整批跳走」。
#
# 所以开一个窗口，把「已经许诺出去但牌还在飞」的落点记成台账：
#   begin_arrivals() → 每张新牌 arrival_spot() → end_arrivals()
# 玩家侧的资源卡直接按每 PILE_CHUNK 张分组落进左侧资源带（一组的落点算一次、
# 缓存起来，组内逐张沿收拢偏移码上去），BOT 侧的仍走 _free_spot，只是把台账
# 当作已占用传进去，同一批不会再挤在一个点上。
#
# 落地后仍然要跑结算末尾那一趟 _stack_settled：那一趟才是「同资源每 PILE_CHUNK
# 张摞一次」的统一口径（还要并进上几轮的零头）。到货落点和它挑的位置用的是同一个
# _pile_slot + 同一份台账，所以那一趟对满份的组基本是原地收拢，看不出跳动

var _arr_open := false
var _arr_taken: Array = []        # 本次结算已许诺的摞落点（喂给 PileSolver 当硬占用）
var _arr_claimed: Array = []      # 本次结算已许诺的单卡落点（喂给 _free_spot）
var _arr_mine: Dictionary = {}    # 本次结算会被重排的 uid：它们现在站的地方不算障碍
var _arr_base: Dictionary = {}    # "res:组序号" → 该组的落点
var _arr_count: Dictionary = {}   # res → 本次结算已到货张数（决定组序号与组内座次）

## 结算开始时开窗。重入即重置：上一次结算若被打断（重开一局）台账不该留到下一局
func begin_arrivals() -> void:
	_arr_open = true
	_arr_taken.clear()
	_arr_claimed.clear()
	_arr_mine.clear()
	_arr_base.clear()
	_arr_count.clear()
	# 左侧带里已有的零头本轮会被 _stack_settled 捞进同一个池子重排，
	# 所以它们现在占的位置不算障碍 —— 否则新摞会绕开它们落到别处，
	# 等统一那趟把两边并起来时再整摞挪一次，就又跳了
	for res in [CardDB.RES_CASH, CardDB.RES_USER]:
		for e in _mergeable_left(res):
			_arr_mine[e.uid] = true
			_arr_count[res] = int(_arr_count.get(res, 0)) + 1

## 结算末尾关窗（在 _stack_settled 之前关：那一趟要按落地后的实况重新挑位置）
func end_arrivals() -> void:
	_arr_open = false
	_arr_taken.clear()
	_arr_claimed.clear()
	_arr_mine.clear()
	_arr_base.clear()
	_arr_count.clear()

## 一张新产出的牌该飞去哪儿。card 是 state 里那条卡（要 def_id 和 uid）。
## 窗口没开（买卡、典当等单张场合）就退回 _free_spot
## 配方支付的吸入目标。结算窗口打开时，玩家资源牌会直接进入左侧结算带，
## 因而付款动画也必须指向同一条现金带；不能再回到普通玩家区的现金锚点，
## 否则「现金被吸走」和「用户产出落地」会像两套互不相干的动画。
func payment_spot(who: String, res: String) -> Vector3:
	if _arr_open and who == _main.my_seat and res == CardDB.RES_CASH:
		return SETTLE_CASH_ANCHOR
	return _unit_anchor(who, CardDB.unit_id(res))

## 预览资源带的下一张实际落点，不推进到货台账。
## 结算演出先用它给付款动画定位，随后 arrival_spot() 会按同一状态提交该落点。
func preview_band_arrival_spot(res: String) -> Vector3:
	if not _arr_open:
		return _unit_anchor(_main.my_seat, CardDB.unit_id(res))
	var k: int = int(_arr_count.get(res, 0))
	var part: int = k / PILE_CHUNK
	var seat: int = k % PILE_CHUNK
	var ck := "%s:%d" % [res, part]
	var base: Vector3
	if _arr_base.has(ck):
		base = _arr_base[ck]
	else:
		var anchor: Vector3 = SETTLE_CASH_ANCHOR if res == CardDB.RES_CASH else SETTLE_USER_ANCHOR
		var cols: Array = SETTLE_CASH_COLS if res == CardDB.RES_CASH else SETTLE_USER_COLS
		base = _pile_slot(anchor, _arr_taken, _arr_mine, cols)
	return base + Board.compact_offset(PILE_CHUNK, seat)

## 预览任意一方的产出落点，不推进到货台账；现金→用户动画用它和真实 arrival_spot 对齐。
func preview_arrival_spot(who: String, card: Dictionary) -> Vector3:
	var def_id: String = card.get("def_id", "")
	var anchor := _unit_anchor(who, def_id)
	if not _arr_open:
		return _free_spot(anchor, who)
	var def: Dictionary = CardDB.get_def(def_id)
	if who == _main.my_seat and def.get("kind") == CardDB.KIND_UNIT:
		return preview_band_arrival_spot(def.get("res", ""))
	return _free_spot(anchor, who, _arr_claimed)

func arrival_spot(who: String, card: Dictionary) -> Vector3:
	var def_id: String = card["def_id"]
	var anchor := _unit_anchor(who, def_id)
	if not _arr_open:
		return _free_spot(anchor, who)
	var def: Dictionary = CardDB.get_def(def_id)
	# 玩家的资源卡直接进左侧资源带，按每 PILE_CHUNK 张一组
	if who == _main.my_seat and def.get("kind") == CardDB.KIND_UNIT:
		# 落地后它也是「本轮要重排的牌」之一：后面几组挑位置时不该把它当障碍绕开，
		# 否则和结算末尾那趟（mine 含整池）挑出的位置不一致，整摞会再跳一次
		_arr_mine[card["uid"]] = true
		return _band_arrival_spot(def.get("res"))
	var spot := _free_spot(anchor, who, _arr_claimed)
	_arr_claimed.append(spot)
	return spot

## 左侧资源带里的落点：第 k 张进第 k / PILE_CHUNK 组、坐第 k % PILE_CHUNK 席。
## 一组的基准落点只算一次（缓存），组内逐张按 Board.compact_offset 码上去 ——
## 满 PILE_CHUNK 张的组落地时就已经是一摞的形状，末尾统一那趟原地收拢
func _band_arrival_spot(res: String) -> Vector3:
	var k: int = int(_arr_count.get(res, 0))
	_arr_count[res] = k + 1
	var part: int = k / PILE_CHUNK
	var seat: int = k % PILE_CHUNK
	var ck := "%s:%d" % [res, part]
	if not _arr_base.has(ck):
		var anchor: Vector3 = SETTLE_CASH_ANCHOR if res == CardDB.RES_CASH else SETTLE_USER_ANCHOR
		var cols: Array = SETTLE_CASH_COLS if res == CardDB.RES_CASH else SETTLE_USER_COLS
		var base := _pile_slot(anchor, _arr_taken, _arr_mine, cols)
		_arr_base[ck] = base
		_arr_taken.append(base)
	return (_arr_base[ck] as Vector3) + Board.compact_offset(PILE_CHUNK, seat)

## 结算产出的卡摞到屏幕左侧。
## known = 结算前场上已有的 uid，多出来的才是本回合产出的。
## 桌上原有的卡（含玩家自己摆的阵型）一张都不动 —— 结算是「多了一批牌」，
## 不该顺手把玩家的布局重排一遍。
##
## 摞不摞的口径是**左侧这一片累计有多少张散牌**，不是「本回合新产出几张」：
## 你要的是「左侧不够 PILE_CHUNK 张则不摞，超过就分组摞好」，这是对左侧那片区域
## 常态的约束。只看本回合的话，连着两回合各产半摞多一点就会在左边留下超过
## PILE_CHUNK 张散牌，而每一批都「不够」，可左侧已经乱了。所以每次结算都把左侧的
## 散牌和这批新卡并成一个池子重排：满 PILE_CHUNK 的摞成一组，剩下不够的继续散着摆。
## 已经摞好的那几摞整份不动 —— 它们本来就合规，动了就是替玩家重排
func _stack_settled(known: Dictionary) -> void:
	_col_singles.clear()      # 台账只在一次结算的两趟之间传话（见 _col_singles）
	var fresh_cash: Array = []
	var fresh_user: Array = []
	for c in _main.state.players[_main.my_seat]["cards"]:
		if known.has(c["uid"]) or not entities.has(c["uid"]):
			continue
		var e: CardEntity = entities[c["uid"]]
		if not is_instance_valid(e):
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") != CardDB.KIND_UNIT:
			continue   # 产出的核心卡（升级产物）留在原地，玩家要自己编进阵型
		if def.get("res") == CardDB.RES_CASH:
			fresh_cash.append(e)
		else:
			fresh_user.append(e)
	# 并进上几轮留在左侧、还没摞起来的同种资源（去重：新卡也可能已经落在左侧带里）
	var cash_pool: Array = _merge_loose_left(fresh_cash, CardDB.RES_CASH)
	var user_pool: Array = _merge_loose_left(fresh_user, CardDB.RES_USER)
	# 现金一列、用户一列，各自纵向排：两种资源混在一列里找不着自己要付的那摞。
	# taken 两次调用共用一份（Array 按引用传）：现金那批的落位是 0.18s 补间送过去的，
	# 用户这批挑位置时它们坐标还没到位，只靠 _spot_cost 读实体会当那儿是空的
	# 两趟：先把两种资源的摞都摆好，再摆两边的余数。
	# 一趟一种资源地走（现金的摞+余数，然后用户的摞+余数）的话，现金的余数会
	# 抢在用户的摞之前占位置，把用户那摞挤到没地方 —— 实测用户的余数最后压在
	# 自己那摞上。摞的位置比余数金贵：玩家是按摞付账的
	# 这次要重排的卡自己不算障碍：它们此刻站的地方正是要腾开的地方。
	# 上几轮留在左侧、被 _merge_loose_left 捞进来的那些尤其要排除，
	# 不然它们会把自己的旧位置判成占用，把余数挤去压摞。
	#
	# 两种资源合成**一份** mine，而且要在摞牌那两趟之前就算出来：产出牌现在是
	# 直接飞进左侧带的（见 arrival_spot），现金这趟挑位置时用户那批正从现金列上空
	# 横穿过去 —— 各算一份 mine 的话现金看不见「用户那批也是本轮要重排的」，
	# 把半空中的 7 张判成障碍，自己的锚点算出 cost=7，整摞躲到隔壁列最南端，
	# 余数跟着往南推，尾巴滑出画面外（实测 x=-13.0，屏幕投影 -58）
	var mine := {}
	for c in cash_pool + user_pool:
		if is_instance_valid(c):
			mine[c.uid] = true
	var taken: Array = []
	var cash_rest: Array = _stack_piles_only(cash_pool, SETTLE_CASH_ANCHOR,
		SETTLE_CASH_COLS, taken, mine)
	var user_rest: Array = _stack_piles_only(user_pool, SETTLE_USER_ANCHOR,
		SETTLE_USER_COLS, taken, mine)
	# 两批余数共用一份 loose：现金的余数排到哪儿了，用户那批得看得见。
	# cols_io 同理共用：两批可能落进同一列（SETTLE_*_COLS 第三项是对方的列），
	# 那一列必须并成一组，否则两组各排各的台阶、撞在同一层上又穿模
	var loose: Array = []
	var cols: Dictionary = {}
	if not cash_rest.is_empty():
		_lay_loose_run(cash_rest, SETTLE_CASH_ANCHOR, taken, mine,
			SETTLE_CASH_COLS, loose, cols)
	if not user_rest.is_empty():
		_lay_loose_run(user_rest, SETTLE_USER_ANCHOR, taken, mine,
			SETTLE_USER_COLS, loose, cols)

## 只摆整 PILE_CHUNK 张的那几摞，把凑不满的那几张原样返回给调用方后面统一摆。
## 走 _stack_arrivals 的同一条摞牌路径（chunk=PILE_CHUNK、min_stack=PILE_CHUNK），
## 只是把余数留到第二趟
## mine —— 本轮要重排的**全部**卡（两种资源合一份），见 _stack_settled 里的说明
func _stack_piles_only(pool: Array, anchor: Vector3, col_xs: Array,
		taken: Array, mine: Dictionary = {}) -> Array:
	var live: Array = []
	for c in pool:
		if is_instance_valid(c):
			live.append(c)
	if live.size() < PILE_CHUNK:
		return live      # 不够一摞，整批当余数
	var full: int = (live.size() / PILE_CHUNK) * PILE_CHUNK
	_stack_arrivals(live.slice(0, full), anchor, PILE_CHUNK, false,
		PILE_CHUNK, col_xs, taken, false, mine)
	return live.slice(full)

## 结算余数组的标记键。这个组是**代玩家临时收的零头**，不是他的布置：
## 下一轮凑够 PILE_CHUNK 张时要拆开重排；_stack_piles_only 按这个阈值分摞。
## 自动整理只改变视觉布局，不改变规则状态。
##
## 为什么要显式标记，不按「摊开 + 纯资源 + 在结算带里」去猜：玩家完全可以
## 把自己的三张用户卡就摆在结算带那一列上（T3 就是这么摆的），几何判定分不出
## 「上一轮的零头」和「玩家自己摆在那儿的一摞」，一猜就把他的布局拆了 ——
## 而「桌上原有的卡一张都不动」是这条路的硬约束（见 _stack_arrivals 的头注释）
const REST_FLAG := "settle_rest"

## g 是不是本代码自己收的那种余数组（本轮该拆开重排）。
## 玩家双击收拢过就不算了：那是他要的形态，按他的算
func _is_loose_remainder(g) -> bool:
	return bool(g.get(REST_FLAG, false)) and not g.get("compact", false)

## 一张卡算不算「在左侧结算带里」：落在三列结算列（SETTLE_CASH_COLS，
## 也就是 -11.7/-10.3/-8.9）中某一列的半格之内。
## 不用一个手写的 x 边界：结算带的右缘和玩家地盘（现金堆锚点 x=-8.0）只隔 0.9，
## 比一张卡还窄（卡宽 1.2），边界写歪一点就会把玩家自己摆的现金也扫进来重排。
## 按列判定的话边界就是列网格自己的（±PILE_SLOT_X_STEP/2 = ±0.7），
## 最右一列的带子到 -8.2 为止，玩家的 -8.0 天然在外面。
##
## 按归宿判（_rest_pos）不按实时坐标：一次结算里余数分两趟排，第一趟刚送出去的
## 那几张还在 0.3s 补间路上，问实时坐标会答「还在玩家区」—— 于是第二趟不认为
## 它们在带里，既不并进同一列，也不算障碍
func _in_settle_zone(e: CardEntity) -> bool:
	for col in SETTLE_CASH_COLS:      # 三列全在里面，只是顺序不同
		if absf(_rest_pos(e).x - float(col)) < PILE_SLOT_X_STEP / 2.0:
			return true
	return false

## 把 fresh 和「左侧带里还散着的同种资源卡」并成一个池子。
## 只收散牌：已经在某个摞里的（group_of 非空）本来就合规，不重排。
## 也只收左侧带里的 —— 玩家拖到桌子中间的那几张现金是他自己放的
func _merge_loose_left(fresh: Array, res: String) -> Array:
	var pool: Array = fresh.duplicate()
	var seen := {}
	for e in fresh:
		if is_instance_valid(e):
			seen[e.uid] = true
	for e in _mergeable_left(res, seen):
		var g: Variant = board.group_of(e)
		if g != null:
			# 上一轮结算把余数按列成了组（见 _place_loose_col）。这些组是「还没摞够
			# PILE_CHUNK 张的零头」，本轮新卡来了正该和它们凑成整摞 —— 不捞进来的话
			# 「左侧累积到 PILE_CHUNK 张就摞」永远凑不齐（scenes/settle_layout.gd 的 PILE_CHUNK）。
			# 纯资源的摊开小组才解散；收拢的摞和玩家编的阵型不动
			board._remove_group(g)
		pool.append(e)
	return pool

## 左侧带里会被本轮捞进来重排的同种资源散牌（只读，不动组不改坐标）。
## 抽出来是给到货窗口用的：牌一落地就要知道「这一摞最终会连上谁」，
## 落点才能和结算末尾 _stack_settled 挑的位置对上、不会摆完再跳一次
func _mergeable_left(res: String, seen: Dictionary = {}) -> Array:
	var out: Array = []
	for c in _main.state.players[_main.my_seat]["cards"]:
		if not entities.has(c["uid"]):
			continue
		var e: CardEntity = entities[c["uid"]]
		if not is_instance_valid(e) or seen.has(e.uid):
			continue
		if not _in_settle_zone(e):
			continue
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") != CardDB.KIND_UNIT or def.get("res") != res:
			continue
		var g: Variant = board.group_of(e)
		if g != null and not _is_loose_remainder(g):
			continue     # 收拢的摞和玩家编的阵型不动
		out.append(e)
		seen[e.uid] = true
	return out

## 结算产出的落脚点：屏幕左侧边缘（玩家区左端），从这里往 +z 排。
## x = -11.7：实测这一列卡的左缘落在屏幕 x=30（1600 宽），是「还能整张看全」的最外一列，
## 再往左（-13.1）近端就出画了。
##
## 现金和用户各占一列，互不穿插（实测左侧可用带只有 x=119..334px / 3 列，
## 列节距 1.4=81px、卡宽 1.2=70px，塞不进两个各两列的带，所以一人一列）：
##   现金 -11.7、用户 -10.3，超出各自一列的容量才共用第三列 -8.9。
## 一列装两摞（20 张），不是三摞：落点网格是 PILE_SLOT_Z_MIN=0.0 起、
## 步长 0.6、上限 PILE_SLOT_Z_MAX=4.7（实际最高格 4.2），而两摞要隔
## PILE_TAKE_CLEAR_Z=2.3，第三摞得 z≥4.6+ 才行，网格上够不着。
## 所以锚点留在 z=0.9 而不是往下挪到 0：挪下去一摞也多装不了，
## 只会让摞的近端伸到 z=-0.9（摞纵深 2.15，往两头各摊一半）压上旧卡
const SETTLE_CASH_ANCHOR := Vector3(-11.7, 0.05, 0.9)
const SETTLE_USER_ANCHOR := Vector3(-10.3, 0.05, 0.9)
const SETTLE_SPILL_X := -8.9                       # 两种资源溢出时共用的第三列
## 列的先后就是优先级（_pile_slot 里每往后一列只加价 0.004，压到一张卡是 1.0，
## 所以「后面的空列」永远赢过「前面的占着的格子」）。因此三列都列上、只是顺序不同：
## 自己的列 → 共用列 → 对方的列。真只剩对方的列可用时才借，
## 而不是宁可压在旧卡上也守着「一人一列」—— 不重叠比排面齐整重要
const SETTLE_CASH_COLS: Array = [-11.7, SETTLE_SPILL_X, -10.3]
const SETTLE_USER_COLS: Array = [-10.3, SETTLE_SPILL_X, -11.7]
## 结算的摞不摞用 PILE_CHUNK 当门槛，见 _stack_settled：
## 「左侧不够 PILE_CHUNK 张则不摞，超过就分组摞好」—— 门槛和分组大小是同一个数，
## 所以不再另立常量

## 新到的卡就地摞好，**不动桌上已有的任何东西**。
## 玩家自己摆的阵型是他的记忆：典当一张、结算一次就把整片重排
## （_tidy_player_idle 那种「先解散所有纯资源摞再重建」）等于每回合把桌面洗一遍，
## 玩家找不着自己刚摆的牌。所以这条路只管「刚出现的这几张」。
##
## cards   —— 刚落到桌上的实体
## anchor  —— 希望摆在哪儿（典当：被当那张卡的原位；结算：屏幕左侧）
## chunk   —— 每份几张。0 = 全部摞成一摞
const COMPACT_SPAN := Board.COMPACT_GAP.z   # 收拢摞每多一张往 +z 长这么多
## keep_anchor —— 第一摞钉死在 anchor 上，不做避让。典当走这条：
##   「摞在被典当卡的位置」是玩家给的定位，那张卡刚被吸走、位子刚空出来，
##   为了躲开旁边的邻居再挪一格，反而不在他指的地方了
## min_stack   —— 少于这个张数就摊开摆、不摞（一两张现金摆成「一摞」，
##   玩家还得双击展开才看得见是什么）。典当和结算都用 PILE_CHUNK：
##   典当是「典当获得的现金够 PILE_CHUNK 张才自动摞」，
##   结算是「左侧不够 PILE_CHUNK 张则不摞」
## col_xs      —— 限定只在这几列 x 上找位置（按给的顺序优先）。空 = 老行为，
##   从 anchor.x 往右数 PILE_SLOT_COLS 列。结算靠它做到「现金一列、用户一列」
## taken_io    —— 已被占掉的格子。传进来的话就在这一份上追加（Array 按引用传），
##   让先后两批（现金→用户）能互相避让 —— 落位是补间送的，读实体坐标读不到
## loose_remainder —— 凑不满 chunk 的那几张摊开摆、不摞成小摞。结算走这条：
##   「够 PILE_CHUNK 就分组摞好」的另一半是「不够的不摞」，余数摞成一小摞就违了这条。
##   典当不走（那边是一次性换出的一笔钱，整笔摞在被当那张卡的位置上）
## extra_mine —— 除了这一批自己，还有哪些卡算「本轮要重排的」（不当障碍）。
##   结算时两种资源分两趟摞，另一趟那批正在飞，得靠调用方告诉这一趟
##   （见 _stack_settled 里那段说明）
func _stack_arrivals(cards: Array, anchor: Vector3, chunk: int = 0,
		keep_anchor: bool = false, min_stack: int = PILE_CHUNK,
		col_xs: Array = [], taken_io: Array = [],
		loose_remainder: bool = false, extra_mine: Dictionary = {}) -> Array:
	var live: Array = []
	for c in cards:
		if is_instance_valid(c):
			board._detach_from_group(c)
			# 结算产出的卡是飞进来的，可能还在半路（见 _fly_from）。
			# 摞成分组走的是 _layout_group 直接赋值坐标，会被没跑完的补间盖回去，
			# 所以在这个总入口一次掐干净，底下 _move_to_spot / 分组两条路都覆盖到
			_main._cancel_fly(c)
			live.append(c)
	if live.is_empty():
		return []
	# 这一批自己不算障碍：它们此刻站的地方就是要腾开的地方
	var mine := {}
	for uid in extra_mine:
		mine[uid] = true
	for c in live:
		mine[c.uid] = true
	var made: Array = []
	if live.size() < min_stack:
		# 不够摞：沿 z 铺成一条，每张露出标题带（见 _lay_loose_run）。
		# 不一张张去 _pile_slot 找位置 —— 那条路按「一摞」的余量避让，
		# 一列只放得下两个位置，几张下来就互相挤到已有的摞头上
		_lay_loose_run(live, anchor, taken_io, mine, col_xs)
		return made
	var size: int = live.size() if chunk <= 0 else chunk
	var taken: Array = taken_io      # 这一批自己占掉的位置，后一摞要避开
	# 余数要散着摆的话，先把它从待摞的那部分里切出来
	var rest: Array = []
	if loose_remainder and size > 0 and live.size() % size != 0:
		var full: int = (live.size() / size) * size
		rest = live.slice(full)
		live = live.slice(0, full)
	var part := 0
	while part * size < live.size():
		var part_cards: Array = live.slice(part * size, mini((part + 1) * size, live.size()))
		var spot: Vector3 = anchor if (keep_anchor and part == 0) else _pile_slot(anchor, taken, mine, col_xs)
		if keep_anchor and part == 0:
			# 摞是从第一张往 +z 长的，所以「摞的位置」和「第一张的位置」差半个纵深。
			# 典当 50 张的摞纵深 2.45，直接把第一张钉在原位，整摞会往玩家身前压过去，
			# 还会顶到 player_max_z 被钳回来。把摞的中心对到原位，看着才是「摞在这张卡的地方」
			spot.z -= COMPACT_SPAN * (part_cards.size() - 1) / 2.0
			spot.z = clampf(spot.z, PILE_SLOT_Z_MIN, PILE_SLOT_Z_MAX)
		# 带子满了：_pile_slot 挑不出空位，只能退回压在某个旧摞上。
		# 那就并进它，别在它头上再摆一摞（见 _pile_host）
		var host: Variant = null
		if not (keep_anchor and part == 0):
			host = _pile_host(spot, part_cards[0].def_id)
			# 合并**不按张数封顶**：带子满了就认下高度，把张数如实并进去。
			# 封顶（曾按 20 张）的理由是收拢摞每张抬 COMPACT_GAP.y=0.045，
			# 并太多会顶成一根悬空的塔 —— 但这个取舍是反的：
			# host 不为空说明 spot 已经压在这摞上了
			# （_pile_slot 的 hard 一轮挑不出空位才会返回被占的格子），
			# 拒绝合并换来的不是「矮一点」，而是**两摞坐标完全重合**
			# （实测 摞#7×摞#17 十层逐层 Δy=0.000 全穿）。
			# 重合比高更坏：高摞看得出是一摞、侧边清单还报得出「×30」，
			# 重合两摞在屏幕上看着就是一摞满份的，玩家按它付账会付错
		if host != null:
			for c in part_cards:
				c.freeze = true
			host["cards"].append_array(part_cards)
			board._core_first(host)      # 收拢态只露摞顶，核心卡得留在最上面
			board._layout_group(host)
			# 并进去的这一摞也要登记进 taken：它刚被 _layout_group 重排，20 张
			# 全在 0.18s 补间路上，后面摆余数的人读 global_position 读到的是旧坐标，
			# 看不见它，于是余数直接压上来（实测 (-10.30,·,1.59) 压在这摞的 0.50 上）。
			# 读 _group_origin 而不是 spot —— 那是「这摞真正的落脚点」，
			# 它内部会先 _stop_move 按到补间终点（见 board._group_origin）
			taken.append(board._group_origin(host))
			part += 1
			continue
		taken.append(spot)
		if part_cards.size() < 2:
			part_cards[0].freeze = true
			_move_to_spot(part_cards[0], spot)
		else:
			part_cards[0].global_position = spot
			# 直接建成收拢态：摞的意义就是占地小，建完再让玩家双击一次没道理
			var g := board.make_group(part_cards, true)
			board.groups.append(g)
			board._layout_group(g, spot)
			made.append(g)
		part += 1
	# 摞都摆下了，先统一按当前布局给每摞定高度（带子满了、又和身下那摞不同种
	# 资源并不进去时，整摞落在它顶上），再把被摞埋掉的老余数垫上去，最后摆
	# 这一批的余数。三步的顺序都要紧：摞的高度还没定就去垫余数，余数读到的
	# 是旧高度；余数还没垫就摆新余数，新余数挑位置时读到的也是旧高度
	_settle_pile_heights()
	_relift_remainders()
	if not rest.is_empty():
		_lay_loose_run(rest, anchor, taken, mine, col_xs)
	# 全部落定之后再统一重摆侧边清单：清单的高度按「盖住谁」算，而一摞一摞
	# 挨着摆的时候，前一摞的清单摆下时后面那摞还没抬起来（见 board.resync_sides）
	board.resync_sides()
	return made

## 把凑不满一摞的那几张沿 z 铺成一条，每张露出一条标题带 —— 就是摊开组的排法
## （步长取 Board.STACK_GAP.z）。
##
## 不能一张一张去 _pile_slot 找位置：那条路按「一摞」的余量（PILE_TAKE_CLEAR_Z=2.3）
## 算避让，左侧三列一共只放得下 6 个这样的位置，9 张余数一找就把整条带占满，
## 后面几张只能挑「最不挤」的格子 —— 实测会落到已经建好的摞头上
## （现金余数落在 (-11.70, 0.90)，正是现金摞自己的位置）。
## 改成**逐格填**：一格一格往下试，撞上东西就半步挪开再试，而不是给整条
## 只找一个头位。头位那条路要求一列里有连续的一段空档，而一摞给散牌挡掉的
## 纵深不小，一列 4.7 摆下两摞就凑不出连续的一段，整条余数只能压在摞上
## （变异测试：把头位那版塞回去，T9 立刻报「(-8.9,1.0), (-8.9,1.6) 压在摞上」）。
##
## 顺带也允许跨列续排、也排除了这一批自己的旧位置 —— 但这两条按变异测试**各自
## 单独去掉，T9 照样全绿**，眼下这个负载还用不上，是给更挤的场面留的余地，
## 不是这次修好的原因。容量本来就够：3 摞 + 11 张余数要 13.35 纵深，三列供 19.20
func _lay_loose_run(rest: Array, anchor: Vector3, taken: Array,
		mine: Dictionary, col_xs: Array, loose_io: Array = [],
		cols_io: Dictionary = {}) -> void:
	var spots: Array = _loose_slots(rest.size(), Board.STACK_GAP.z, anchor,
		taken, mine, col_xs, loose_io)
	# 按列归拢：同一列里前后两张的占地是**故意重叠**的（步长 0.52 远小于卡纵深 1.7，
	# 就是摊开组「每张露一条标题带」的排法）。占地重叠就必须同属一组 ——
	# 组负责两件事：沿 y 排开台阶（不穿模），以及让这一列能被整体拎起、双击收拢
	var by_col: Dictionary = {}
	for i in rest.size():
		var key: int = _col_key(spots[i].x)
		if not by_col.has(key):
			by_col[key] = []
		by_col[key].append(i)
	for key in by_col:
		var members: Array = []
		for i in by_col[key]:
			var c: CardEntity = rest[i]
			c.freeze = true
			members.append({ "card": c, "z": spots[i].z, "x": spots[i].x })
		var host: Variant = _col_host(key, cols_io)
		if host == null:
			# 这一列上一轮可能留下过落单的余数（一列只排到一张时不建组），
			# 它不在任何台阶体系里，新组从地板起排会和它撞在同一层
			members.append_array(_col_strays(key, mine))
		_place_loose_col(members, anchor.y, host, key, cols_io)


## 列号 → 这一列摆下了、但没凑够两张所以没建组的那张牌（seat 格式）。
##
## 一次结算里余数分两趟排（现金一趟、用户一趟，见 _stack_settled），两趟可能
## 落进同一列。前一趟只排到一张时不会建组，后一趟就找不到它 —— 而这一刻它正在
## 0.3s 补间路上，读 global_position 读到的还是玩家区的旧坐标，按坐标也筛不出来。
## 所以走内存台账。每次结算开头清空（见 _stack_settled）
var _col_singles: Dictionary = {}

## 列号：按列网格取整（列间距 PILE_SLOT_X_STEP=1.4 > 卡宽 1.2，不同列压不着）
func _col_key(x: float) -> int:
	return int(roundf(x * 100.0))




## 这一列该并进哪个组。
##
## 先认本次传进来的 cols_io（同一次结算里现金余数和用户余数分两趟排，
## 可能落进同一列），再去桌上找 —— 上一次典当/溢出留下的余数组也可能正占着
## 这一列，那时候的 cols_io 早没了。找不到就返回 null（新起一组）。
##
## 必须找得到才行：一列里两个组各排各的台阶，第二组从 base_y 重新起，
## 立刻和第一组撞在同一层，又是穿模
func _col_host(key: int, cols_io: Dictionary) -> Variant:
	var g: Variant = cols_io.get(key)
	if g != null and board.groups.has(g):
		return g
	for gg in board.groups:
		if not _is_loose_remainder(gg):
			continue      # 只往自己收的零头里续排，绝不动玩家摆的组
		for c in gg["cards"]:
			if is_instance_valid(c) and _col_key(_rest_pos(c).x) == key:
				return gg
	return null

## 这一列里落单的余数（不在任何组里的纯资源卡），按 _place_loose_col 的 seat 格式返回。
##
## 为什么要专门捞：一列只排到一张时不建组（一张牌没有「重叠」也没有「摞」可言），
## 于是它不在任何台阶体系里。下一轮同一列又排进几张、建成组，组从地板起排，
## 第一张正好和这张落单的撞在同一层（实测 (-8.90,0.479,0.00) 和
## (-8.90,0.479,0.40) 同高）。把它收进新组，这一列就还是只有一套台阶。
##
## 只捞纯资源卡（现金/用户卡）：那本来就是 _merge_loose_left 会重排的东西
## （见 _merge_loose_left 的累积整理逻辑）。玩家自己摆在带里的单位卡不碰 —— 那是他的布置
func _col_strays(key: int, mine: Dictionary) -> Array:
	var out: Array = []
	for c in _main.state.players[_main.my_seat]["cards"]:
		if not entities.has(c["uid"]) or mine.has(c["uid"]):
			continue
		var e: CardEntity = entities[c["uid"]]
		if not is_instance_valid(e) or e.is_market or not e.draggable:
			continue
		if board.group_of(e) != null:
			continue      # 成了组的交给 _col_host
		var def: Dictionary = CardDB.get_def(c["def_id"])
		if def.get("kind") != CardDB.KIND_UNIT:
			continue
		var res = def.get("res")
		if res != CardDB.RES_CASH and res != CardDB.RES_USER:
			continue
		var at := _rest_pos(e)
		if _col_key(at.x) != key or not _in_settle_zone(e):
			continue
		out.append({ "card": e, "z": at.z, "x": at.x })
	return out


## 把一列余数摆成「摊开态的一组」：z 用逐格避让挑出来的值（不规整，
## 所以不能交给 _layout_group 按等距重排 —— 那会让整条穿过刚摞好的摞），
## y 用 Board.ladder_y 按远近名次排台阶。
##
## 为什么必须成组：
##   1. 占地重叠的牌之间要有 y 台阶，台阶归组管（见 Board.ladder_y）
##   2. 「不够 PILE_CHUNK 张不摞」只是不替玩家收拢，玩家自己双击该能摞
##      —— toggle_compact 只认组里的牌，散着的双击是白点
## 这些位置底下压着的摞，顶面在多高（没压着摞就返回 0，已含一级台阶）。
## 判定在 PileSolver.top_under，这里只负责拍快照。
## limit 是 board.groups 里的序号上限 —— 定高度必须限序，见那边的注释
func _pile_top_under(seats: Array, limit := -1) -> float:
	return PileSolver.top_under(_desk(), seats, limit)

## 这一摞现在该落多高（只算，不动牌；由 _settle_pile_heights 按它摆）。
## 为什么会离桌、为什么必须限序，见 PileSolver.floor_for_pile。
##
## 这一层只把「这一摞的每张卡占哪个位置」算出来交过去，坐标全程按补间**终点**取：
## 这一摞可能刚被 _layout_group 排过，整摞还在 0.18s 路上，读 global_position
## 读到的是它在玩家区的旧坐标，量出来的抬升是假的。
##
## 为什么不把高度交给 _layout_group：它把 base.y 写死成 0.05（贴桌静止高度），
## 任何外面加的抬升都会被下一次重排抹掉。所以改成排完之后按 board._move_to
## 重发一遍：_move_to 会记下终点，rest_origin 读的就是这个终点，整套坐标自洽。
## 玩家下次拎起这一摞放下时，_layout_group 从 _group_origin 重新起排、
## y 回到 0.05 —— 落差自然消失，这也正是想要的：那时候他自己挑了位置
func _pile_floor(g: Variant, limit: int) -> float:
	var n: int = g["cards"].size()
	if n < 1 or not is_instance_valid(g["cards"][0]):
		return SETTLE_CASH_ANCHOR.y
	# 全程按补间**终点**算：这一摞可能刚被 _layout_group 排过，整摞还在 0.18s
	# 路上，读 global_position 读到的是它在玩家区的旧坐标，量出来的抬升是假的
	var origin: Vector3 = board.rest_origin(g)
	var seats: Array = []
	for i in n:
		var off: Vector3 = board._stack_offset(g, i)
		seats.append({ "x": origin.x + off.x, "z": origin.z + off.z })
	return PileSolver.floor_for_pile(_desk(), seats, limit)

## 把每一摞按到「它现在该在的高度」（见 _pile_floor）。
##
## 为什么要一趟全局的、而不是摆下时各抬各的：一摞的高度取决于身下压着谁，
## 而那个「谁」在同一次结算里还会变 —— 被并进别的摞、被 _merge_loose_left
## 解散重排。摆下那一刻抬一次、之后不回头，抬升就成了摆放历史的残留：
## 实测十轮结算后有两摞常驻悬空（摞#12 底面 1.379，身下什么都没有）。
##
## 按 board.groups 的序号从小到大扫**一趟**就够：第 i 摞只许落在序号 < i 的
## 摞上面（见 _pile_top_under 的 limit），扫到 i 的时候前面那些已经定好了。
##
## 不能反复迭代到「不动为止」：两摞占地互相重叠时，A 要落在 B 上、B 要落在
## A 上，多跑一轮就互相顶高一级，实测十轮结算后顶面涨到 y=509。限序之后
## 这种环根本不成立 —— 这也是为什么定高度这件事必须有个全局次序
func _settle_pile_heights() -> void:
	for gi in board.groups.size():
		var g = board.groups[gi]
		if not bool(g.get("compact", false)) or g["cards"].is_empty():
			continue
		if not is_instance_valid(g["cards"][0]):
			continue
		var origin: Vector3 = board.rest_origin(g)
		var want: float = _pile_floor(g, gi)
		if absf(want - origin.y) <= 0.0005:
			continue
		var base := Vector3(origin.x, want, origin.z)
		for i in g["cards"].size():
			var c: CardEntity = g["cards"][i]
			if is_instance_valid(c):
				board._move_to(c, base + board._stack_offset(g, i))
	# 侧边清单在 _stack_arrivals 末尾统一重摆（board.resync_sides），不在这里补：
	# 这一趟里前面的摞会带动后面的摞改高度，补在里面等于白摆好几遍

## 刚摆下几摞之后，把「被摞埋掉的老余数组」重新垫到摞顶上。
##
## 为什么需要：_pile_slot 故意不避让散牌（散牌靠组内台阶错开，不该占死格子），
## 所以新摞完全可以落在上几轮留下的余数组头上。结算那条路碰不到这个问题
## —— _merge_loose_left 会先把同种资源的余数组解散、连新卡一起重排；
## 但典当那条路（_stack_arrivals 直接调用）不解散任何东西，于是老余数
## 就一直躺在新摞底下（实测 余数#5(-11.70,0.098,1.94) 压在 摞#12 的 0.095 上，
## Δy=0.003，正是用户报的「典当获得的现金有一样的问题」）。
##
## 只动「自己代收的零头」（_is_loose_remainder），且只改 y：
## x/z 是逐格避让挑出来的，动了就等于替玩家重排桌面（见 main.gd 的硬约束）。
## 也不碰收拢的摞和玩家自己编的阵型。
##
## 有界：一列余数最多 PILE_CHUNK-1 张，底下最多压着一摞，
## 抬高就是「那一摞的顶 + 一级台阶」，不会累积成塔
func _relift_remainders() -> void:
	for g in board.groups:
		if bool(g.get("compact", false)) or not _is_loose_remainder(g):
			continue
		var seats: Array = []
		for c in g["cards"]:
			if is_instance_valid(c):
				# 按归宿取 x/z，不读实时坐标：这一趟跑在 _lay_loose_run 之后，
				# 组里的牌多半还在 0.3s 补间路上（见 _move_to_spot）。
				# 读出发点等于把它们按半路上的位置重新钉死，补间白跑
				var at := _rest_pos(c)
				seats.append({ "card": c, "z": at.z, "x": at.x })
		if seats.is_empty():
			continue
		seats.sort_custom(func(a, b): return a["z"] < b["z"])
		var floor_y: float = maxf(SETTLE_CASH_ANCHOR.y, _pile_top_under(seats))
		for r in seats.size():
			var c2: CardEntity = seats[r]["card"]
			var spot := Vector3(seats[r]["x"], floor_y + Board.ladder_y(r),
				seats[r]["z"])
			if not _rest_pos(c2).is_equal_approx(spot):
				_move_to_spot(c2, spot)

func _place_loose_col(members: Array, base_y: float, into: Variant,
		key: int, cols_io: Dictionary) -> void:
	# 已经在这一列的牌（续排的情况）也参与排名：台阶按「从远到近第几张」算，
	# 新来的插在中间也拿到中间那一层，不会和已经站定的撞在同一层
	var seats: Array = members.duplicate()
	var seen: Dictionary = {}
	for m in members:
		seen[m["card"]] = true
	if into != null:
		for c in into["cards"]:
			if is_instance_valid(c) and not seen.has(c):
				seen[c] = true
				# 归宿，不是实时坐标：现金那趟刚把这几张送上路，读出发点会把它们
				# 按半路上的位置重新钉死一遍（见 _move_to_spot 的注释）
				var at := _rest_pos(c)
				seats.append({ "card": c, "z": at.z, "x": at.x })
	# 本次结算前半程（现金那趟）已经摆进这一列、但没凑够两张所以没建组的牌。
	# 必须走内存台账，不能靠读坐标去找：它是 _move_to_spot 的 0.3s 补间送过去的，
	# 这一刻 global_position 还停在玩家区，按坐标筛「在不在这一列」一个都筛不出来。
	# 漏掉它的后果是这一列出现两套台阶 —— 它自己一层，新建的组从同一个地板起排，
	# 第一张和它撞死（实测 (-8.90,0.479,0.00) 和 (-8.90,0.479,0.40) 同高）
	for rec in _col_singles.get(key, []):
		var c2: CardEntity = rec["card"]
		# 已经成组的跳过：台账是跨趟传话用的，成了组之后归 _col_host 管
		if is_instance_valid(c2) and not seen.has(c2) and board.group_of(c2) == null:
			seen[c2] = true
			seats.append(rec)
	seats.sort_custom(func(a, b): return a["z"] < b["z"])
	# 这一列压着的摞有多高：带子挤到余数只能和摞共用一列时，两边各从 base_y
	# 起排自己的台阶，立刻撞在同一层（实测摞的第 3 层 y=0.140 和余数的第 4 张
	# y=0.122 落在 Δz=0.20 处，图标直接从摞里穿出来）。从摞顶往上起排，
	# 这一列就只有一套台阶了。抬高有界：余数最多 PILE_CHUNK-1 张，底下最多一摞
	var floor_y: float = maxf(base_y, _pile_top_under(seats))
	var cards: Array = []
	for r in seats.size():
		var seat: Dictionary = seats[r]
		var c: CardEntity = seat["card"]
		cards.append(c)
		var spot := Vector3(seat["x"], floor_y + Board.ladder_y(r), seat["z"])
		# 续排时老牌的名次可能被顶高：它已经站定了，也得跟着抬，
		# 否则新牌插进来只是「以为垫开了」，实物还在同一层上。
		# 比的是归宿而不是实时坐标：正飞往 spot 的牌实时坐标还在出发点，
		# 按那个比会判成「不在位」，于是又发一条同终点的补间，牌从半路重新起跑
		if not _rest_pos(c).is_equal_approx(spot):
			_move_to_spot(c, spot)
	if into != null:
		into["cards"] = cards
		board.refresh_group(into)
		cols_io[key] = into
		_col_singles.erase(key)      # 都并进组了，台账上不用再留
		return
	if cards.size() < 2:
		# 一列就一张，没有「重叠」也没有「摞」可言，不必成组。
		# 但要记在台账上：同一次结算的后半程（用户那趟）可能还往这一列排，
		# 那时候得把它一起收进组里排台阶（见上面读 _col_singles 的地方）
		_col_singles[key] = [{ "card": cards[0], "z": seats[0]["z"], "x": seats[0]["x"] }]
		return
	_col_singles.erase(key)
	# 摊开态（compact=false）：每张仍露出自己的标题带，看得出这一列有几张什么牌。
	# 「不够 PILE_CHUNK 张不摞」说的是不替玩家收拢，不是不许成组
	var ng := board.make_group(cards, false)
	ng[REST_FLAG] = true      # 代收的零头，下一轮可以拆（见 _is_loose_remainder）
	board.groups.append(ng)
	board.refresh_group(ng)
	cols_io[key] = ng

## ---------- 摞位求解 ----------
## 挑坐标的活儿全在 engine/pile_solver.gd（纯几何，headless 单测见
## tests/test_pile_solver.gd）。这一段只做两件事：把桌面拍成一份 Desk 快照，
## 和把常量转出去给别处用。
##
## 常量转出而不是各写一份：网格/判定框是求解器的东西，但 _in_settle_zone、
## _stack_arrivals 这些搬运代码也要按同一套网格钳位，两份数会各说各话
const PILE_SLOT_Z_MIN := PileSolver.PILE_SLOT_Z_MIN
const PILE_SLOT_Z_MAX := PileSolver.PILE_SLOT_Z_MAX
const PILE_SLOT_X_STEP := PileSolver.PILE_SLOT_X_STEP
const PILE_SLOT_COLS := PileSolver.PILE_SLOT_COLS
const PILE_TAKE_CLEAR_Z := PileSolver.PILE_TAKE_CLEAR_Z

## 把当前桌面拍成求解器认的那份数据。
##
## 每次求解都重新拍一份，不缓存：_stack_arrivals 是「挑一个位置、摆一摞、
## 再挑下一个」的循环，上一摞摆下去之后桌面就变了，缓存会让第二摞照着
## 旧桌面挑位置 —— 那正是两摞坐标撞死的老毛病。
##
## 摞的位置读 board.rest_origin 而不是 _group_origin：两者返回的数一样
## （补间在跑就取终点），但后者会 _stop_move 把队首那张按到终点。
## 拍快照要读全场每一摞，用会 snap 的那条等于顺手掐掉别人正在跑的抬升演出
## （见 board.rest_origin 的注释）
func _desk() -> PileSolver.Desk:
	var d := PileSolver.Desk.new()
	d.card_x = CardEntity.CARD_SIZE.x
	d.card_z = CardEntity.CARD_SIZE.z
	d.pile_step = Board.COMPACT_GAP.z
	d.pile_step_y = Board.COMPACT_GAP.y
	d.stack_gap = Board.STACK_GAP.z
	d.band_frac = CardArt.BAND_FRAC
	d.ladder1 = Board.ladder_y(1)
	d.table_y = SETTLE_CASH_ANCHOR.y
	for uid in entities:
		var e: CardEntity = entities[uid]
		if not is_instance_valid(e) or e.is_market or not e.draggable:
			continue
		# 归宿而不是实时坐标：摞是一摞一摞摆下去的，上一摞还在 0.18/0.3s 路上时
		# 下一摞就在挑位置了 —— 读出发点等于照着「牌还没搬走」的旧桌面挑
		var at := _rest_pos(e)
		d.cards.append({ "uid": uid, "pos": at })
		var g: Variant = board.group_of(e)
		if g != null and bool(g.get("compact", false)):
			# 摞里的每一张都当硬障碍，逐张量比按 origin+span 推更保守
			d.pile_cards.append(at)
	for gi in board.groups.size():
		var g = board.groups[gi]
		var cards: Array = g["cards"]
		if cards.is_empty() or not is_instance_valid(cards[0]):
			continue
		if bool(g.get("compact", false)):
			d.piles.append({
				"origin": board.rest_origin(g),
				"count": cards.size(),
				# 收拢态核心卡在最前（见 board._core_first），纯资源摞整摞同种
				"def_id": cards[0].def_id,
				"ref": g,
				# 定高度要限序，序号就是 board.groups 里的下标（= 入组顺序）
				"gi": gi,
			})
		elif not _is_loose_remainder(g):
			# 玩家自己摊开的组：只参与软避让。它们的 z 是逐格避让挑出来的、
			# 不规整，没法用 origin+span 推，逐张记
			for c in cards:
				if is_instance_valid(c):
					d.spreads.append(_rest_pos(c))
	d.longest_pile = PileSolver.longest_pile(d.piles, PILE_CHUNK)
	return d

func _loose_slots(n: int, step: float, anchor: Vector3, taken: Array,
		mine: Dictionary, col_xs: Array, loose_io: Array) -> Array:
	return PileSolver.loose_slots(_desk(), n, step, anchor, taken, mine,
		col_xs, loose_io)

func _pile_slot(anchor: Vector3, taken: Array, skip: Dictionary = {},
		col_xs: Array = []) -> Vector3:
	return PileSolver.slot_for_pile(_desk(), anchor, taken, skip, col_xs)

func _pile_host(spot: Vector3, def_id: String) -> Variant:
	return PileSolver.host_pile(_desk(), spot, def_id)

## 搬一张牌到 spot。**必须宣告归宿**（dest_pos）：这 0.3 秒里同一次结算还会
## 接着问「这张牌在哪」——`_stack_settled` 一次跑两趟（现金一趟、用户一趟），
## 第二趟的 _col_host / _place_loose_col 读的就是第一趟刚送出去的这些牌。
## 不宣告的话读到的是**出发点**，于是余数被按出发点重新钉死一遍，补间白跑：
## 实测一个余数组里 11 张牌散在 x=-11.7..7.3（横穿整张桌子），
## 各自按台阶名次抬到 y=1.65..1.89 —— 屏幕上是一排牌悬在半空
## （memory: settle-runs-mid-flight 的同一个形状，第三处）
func _move_to_spot(c: CardEntity, spot: Vector3) -> void:
	_main._cancel_fly(c)
	c.set_meta("dest_pos", spot)
	var tw := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(c, "position", spot, 0.3)
	tw.tween_callback(func() -> void: _main._clear_dest(c))
	# 登记成「这张牌身上有一段没跑完的位移」，好让别人（board 编组、下一次搬它）
	# 掐得掉。不登记的话这 0.3s 里玩家把一摞资源拖到它上面，
	# 整摞会按它的中间坐标排好，而这条补间接着把它搬走 —— 见 main._move_to
	c.set_meta("fly_tw", tw)

## 把一摞卡按每列 PLAYER_PILE_PER_COL 张切块，每块建成真实分组（≥2 张，可整摞拖动），单卡直接归位
func _group_pile(pile: Array, anchor: Vector3) -> void:
	var safe := _center_bounds(_main.my_seat)
	if safe.has_area():
		_group_pile_in_bounds(pile, anchor, safe)
		return
	var col := 0
	while col * PLAYER_PILE_PER_COL < pile.size():
		var chunk: Array = pile.slice(col * PLAYER_PILE_PER_COL,
			mini((col + 1) * PLAYER_PILE_PER_COL, pile.size()))
		var origin := anchor + Vector3(col * PLAYER_PILE_COL_PITCH, 0, 0)
		_place_resource_chunk(chunk, origin, false)
		col += 1

func _place_resource_chunk(chunk: Array, origin: Vector3, compact: bool) -> void:
	if chunk.size() >= 2:
		chunk[0].global_position = origin
		var g := board.make_group(chunk, compact)
		board.groups.append(g)
		board._layout_group(g, origin)
	elif chunk.size() == 1:
		chunk[0].freeze = true
		_move_to_spot(chunk[0], origin)

## 每种资源有自己的席位。空间满时增加每摞张数，而不是把后面的摞钳到同一行。
func _group_pile_in_bounds(pile: Array, anchor: Vector3, safe: Rect2) -> void:
	if pile.is_empty():
		return
	var cash: bool = CardDB.get_def(pile[0].def_id).get("res") == CardDB.RES_CASH
	var start_x := clampf(anchor.x, safe.position.x, safe.end.x)
	var end_x := minf(-0.8, safe.end.x) if cash else safe.end.x
	var pitch := maxf(PLAYER_PILE_COL_PITCH, CardEntity.CARD_SIZE.x + Board.SIDE_W + Board.SIDE_GAP + 0.2)
	var columns := maxi(1, int(floor((end_x - start_x) / pitch)) + 1)
	var compact := pile.size() > PLAYER_PILE_PER_COL * 2
	var span := Board.COMPACT_GAP.z * 7.0 if compact else Board.STACK_GAP.z * 7.0
	var row_pitch := maxf(2.45, span + CardEntity.CARD_SIZE.z + 0.15)
	var start_z := clampf(anchor.z, safe.position.y, safe.end.y - minf(span, safe.size.y))
	var rows := maxi(1, int(floor((safe.end.y - start_z - minf(span, safe.size.y)) / row_pitch)) + 1)
	var capacity := columns * rows
	var chunk_size := maxi(PLAYER_PILE_PER_COL, ceili(float(pile.size()) / float(capacity)))
	if chunk_size > PLAYER_PILE_PER_COL:
		compact = true
	var group_count := ceili(float(pile.size()) / float(chunk_size))
	for index in group_count:
		var chunk: Array = pile.slice(index * chunk_size, mini((index + 1) * chunk_size, pile.size()))
		var origin := Vector3(start_x + float(index % columns) * pitch, anchor.y,
			start_z + float(index / columns) * row_pitch)
		_place_resource_chunk(chunk, origin, compact)
