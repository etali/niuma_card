# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Board
extends Node3D

## 自由桌面：管理卡牌拖拽、堆叠成组、配方进度显示
## 规则：拖任意卡到另一组上 = 并入该组；拖组顶卡离开 = 整组移动；
##       拖组中间的卡 = 单独拆出该卡

const DRAG_HEIGHT := 1.2        # 拖拽时离桌高度
const MERGE_DIST := 1.6         # 松手时的吸附距离
## 组内竖直一条线；z 露出标题条，y 每张略抬一点。
## y 必须大于「卡面元素在卡内的抬升跨度」（CardEntity.FACE_SPAN_Y = Y_OVERLAY - Y_PLATE = 0.020）：
## 小于它（比如 0.005）时上面那张的底板（y+0.023）比下面那张的卡名（y+0.030）还低，
## 盖不住反被穿透——电脑玩家的牌列往 -z 堆，下张卡的标题就直接印在上张卡脸上。
## 6 张一列总共抬 0.12，仍远小于拖拽高度，看着还是一摞牌而不是楼梯
const STACK_GAP := Vector3(0, 0.024, 0.52)

## 收拢态（双击切换）的层间距：几乎不往 z 铺，靠 y 往上摞。
## 一列 8 张摊开占 z 向 3.64（≈3 张卡长），收拢后只占 0.35，桌面立刻腾出地方。
## y 取 0.045（> STACK_GAP.y）是为了让侧壁的厚度看得出来——一摞才像一摞，
## 而不是几张卡糊在同一个平面上；z 留 0.05 让下面每张卡露出一条边，
## 提示「这里不止一张」，全 0 的话看起来就是单张卡
const COMPACT_GAP := Vector3(0, 0.045, 0.05)

var cards: Array[CardEntity] = []
var groups: Array = []          # Array of {cards: Array[CardEntity], label: Label3D}
var _drag_cards: Array[CardEntity] = []
var _drag_offsets: Array[Vector3] = []
## 手上这摞是不是收拢态。整摞拎起来时原组会被销毁（remain 空），
## 收拢标记得先存下来，落桌重建新组时照原样还回去——
## 否则「双击收拢 → 挪个位置」会把牌又摊开，等于双击白点了
var _drag_compact := false
## 上一次拖拽结束时手上那摞是不是收拢态。
## dropped_on_market / dropped_on_pawn 的接收方要重建牌摞（买卡付掉一部分、
## 被拒退回全部），它们得知道原来是收拢的——而信号发出前 _drag_compact 已经清了。
## 下一次拎牌时会被覆盖，只在「这一次落手」的处理里有效
var last_drag_compact := false
## 手上这几张牌在拎起来的那一刻，自己是不是已经凑满了一个配方。
## 由它给「用手上的牌新建的组」当凑满基线：整摞已凑满的牌挪个位置，
## 组对象重建了但结果没变，不该再响一次风铃；反过来两张同名 T2 从散卡并起来
## 是实打实的新凑满，必须响——make_group 按最终牌面预评估会把这一声吞掉
var _drag_hand_valid := false
var _drag_start_origin := Vector3.INF
var _drag_start_anchor := Vector3.INF
## 拎牌时留在桌上的那半截（整摞被拎走时组已销毁，这里是 null），
## 以及它在被抽走几张之前的凑满状态。
## 抽走的牌会把源组刷成「不成立」，把牌放回同一组时得按这个值还原基线，
## 否则「从一组凑满的牌里按住几张再松手」会凭空再响一声（前后结果并没有变）
var _drag_src_group = null
var _drag_src_valid := false
## 拎牌那一刻先不报「凑满」：从组里抽走一张有可能让剩下的牌反而凑满
## （比如升级组里多塞了一张用户卡，把它抽掉剩下的就成立了）。
## 这一声压到落手时由 _commit_pickup_ding 统一结算——按下就响、放回原处又没变，
## 同样是一次结果没变却响了的误报
var _pickup_quiet := false
var _grab_offset := Vector3.ZERO   # 点击瞬间：鼠标点 → 被点卡中心 的偏移
var _hover_group = null
var _hover_card: CardEntity = null

var camera: Camera3D

signal card_picked(card: CardEntity)
signal card_stacked(completed: bool)  # 并入某组；completed=这次并入凑满了配方
signal card_dropped_table    # 落回桌面
signal group_formed(cards: Array)  # 带成员的视觉事件，旧音效信号仍保持无参数
signal group_completed       # 某组配方凑满（可结算）
## 双击把一组收拢成摞 / 摊开回来。和 card_stacked 分开是为了分开发声：
## 「摞」是玩家单独做的一个动作，配一声独立的音；
## 「组合」永远是拖到位松手的副产物，落桌那一声已经交代了，不另外发音
signal pile_toggled          # 双击收拢/摊开了某一摞
signal dropped_on_market(drag_cards: Array, market_card: CardEntity)  # 拖现金堆到公共区卡上 = 购买
signal dropped_on_pawn(drag_cards: Array)   # 拖卡到典当行 = 回收成现金
signal attack_clicked(card: CardEntity)     # 攻击模式下点选卡牌（点选攻击目标）

## 手上这摞的状态变了，够一帧广播（scenes/main.gd 的拖拽广播与租约处理）。
## phase 取 Protocol.DRAG_PICKUP / DRAG_MOVE / DRAG_CANCEL，`at` 是**桌面坐标**——
## 这一层不知道座位也不知道两侧区域的跨度，归一化交给 scenes/main.gd。
##
## 为什么是一个信号而不是三个：接收端要做的事只有「按 phase 分派」，
## 三个信号会让 main.gd 那边多两处连接、而每处都得记得同样的节流和租约规矩。
##
## 为什么不发鼠标坐标而发牌的位置：广播的是「牌已经离桌、正往那边去」，
## 不是「光标在哪」。悬停犹豫是心理活动不是动作，给了它读盘就退化成读表情
## （scenes/main.gd 的拖拽广播与租约处理）
signal drag_broadcast(phase: String, uids: Array, at: Vector3)

## 手上这摞**停着不动**时的续租间隔（秒）。
##
## 原先这里是一个 0.05 的无条件节流（~20Hz），理由写的是「再密对画面没有
## 可见改善，而 dragging 帧是不可靠通道里最吵的一路」。第一条是错的，实测：
## 收方是硬写位置（main._move_foe_drag，没有插值），60fps 的屏幕上
## **那张牌每 3 帧才动一次** —— 看起来就是一格一格地跳。改成每帧一发之后
## 是每帧动一次，而这是玩家对「延迟高」最直接的感受来源
## （量到的往返只有 16ms，传输根本不是瓶颈）。
##
## 第二条（吵）站得住，但它管的是**停下来之后**：拖着不动时每帧发同一个坐标
## 是纯浪费，而这一路完全不发也不行 —— 收方那条租约要靠它续
## （main.DRAG_LEASE_TIMEOUT = 2.0 秒，不续就到期，牌被布局抢回去）。
## 所以节流只留给「停下」这一种情况，间隔可以放得比原来宽得多
const DRAG_KEEPALIVE_DT := 0.2
## 「动了」的判据（世界坐标）。比这个还小的位移在屏幕上看不出来，
## 发它等于把停下那一路的节流又绕开了
const DRAG_MOVE_EPS := 0.001
var _bcast_t := 0.0
var _bcast_uids: Array = []     # 上一帧广播出去的那几张；空 = 手上没牌
var _bcast_at := Vector3.INF    # 上一帧广播出去的坐标；INF = 还没发过

## 触摸使用事件坐标；Android 的鼠标查询可能仍停在最后一次悬停位置。
var touch_mode := false
var view_gesture := false
var _pointer_at := Vector2.INF

func pointer_position() -> Vector2:
	return _pointer_at if touch_mode and _pointer_at != Vector2.INF else get_viewport().get_mouse_position()

func _input(event: InputEvent) -> void:
	if touch_mode and event is InputEventMouse:
		_pointer_at = event.position

func cancel_pointer() -> void:
	if not _press_snap.is_empty():
		_restore_press()
	else:
		cancel_drag()
	_reset_click_track()

## 同一个松手入口供鼠标、触摸及GUI消费事件后的兜底使用。
func release_pointer(at: Vector2) -> void:
	if _drag_cards.is_empty():
		return
	if _interaction_is_blocked():
		cancel_pointer()
		return
	if not _press_snap.is_empty() and at.distance_to(_press_snap["at"]) <= CLICK_SLOP:
		_restore_press()
	else:
		if touch_mode:
			_pointer_at = at
			_process(1.0 / 60.0)
		_press_snap = {}
		_end_drag()

var attack_mode := false    # 攻击点选模式：点击 = 选靶，不触发拖拽
var input_locked := false   # 输入锁：AI 行动/结算演出期间屏蔽玩家拖拽
## 窗口收起/切换/弹层独立于业务输入锁，控制器返回 true 时暂停桌面交互。
var interaction_blocked := Callable()
var hover_blocked := Callable()

func _interaction_is_blocked() -> bool:
	return interaction_blocked.is_valid() and bool(interaction_blocked.call())

const PAWN_RADIUS := 1.35
var pawn_pos := Vector3.INF   # 由游戏控制器设置；INF = 无典当行
## 「把这张牌身上**别人**那条位移补间掐掉」的口子，由游戏控制器接上
## （见 main._cancel_fly）。空 Callable = 不掐，只掐得掉本文件 _move_tw 里那些。
##
## 为什么非要这个口子：桌上写 CardEntity.position 的补间**分属两处**登记 ——
## 本文件的 _move_tw（编组重排、抬升），和 main 那侧的 fly_tw
## （买卡飞入 main._move_to、产出飞入 _fly_from、理牌搬运 layout._move_to_spot）。
## _stop_move 只看得见前者。于是「拖一摞资源到一张**正在飞**的组合卡上」时：
## _group_origin 读到的是它的中间坐标，整摞按那个坐标排好，
## 而 main 那条补间接着跑完，把核心卡一路搬去它自己的落点 ——
## 屏幕上就是「组合卡消失了」（实测核心卡离组内第二张 0.89 远）。
## 「有时候」正是那 0.3~0.35 秒的窗口：刚买到手、刚被理牌挪过、刚产出飞进来
var cancel_anim := Callable()

var player_min_z := -1000.0   # 玩家卡放置的 z 下限（购牌区南缘）；默认不限制，由游戏控制器开启
var player_max_z := 1000.0    # 玩家卡放置的 z 上限（桌面近边）；长牌列按此反推起点

## 世界坐标 x/z 的卡面外边界。空 Rect2 沿用旧桌面；抽屉由 main 配好这两块区域。
## table_bounds 允许手牌拖到市场/典当行；player_bounds 限制实际落桌和整摞排布。
var table_bounds := Rect2()
var player_bounds := Rect2()
## 抽屉透视相机提供按高度/前后位置计算的屏幕约束；旧横屏为空。
var screen_position_clamper := Callable()
const BOUNDS_PAD := 0.08   # 留给卡面轻倾斜、描边与窗口边缘的呼吸空间
const BOUNDED_COMPACT_LAYERS := 8
var _playable_bounds_pending := false

static func has_table_bounds(bounds: Rect2) -> bool:
	return bounds.size.x > 0.0 and bounds.size.y > 0.0

## 保留整摞相对偏移，夹取其锚点；边界按卡面外沿计算，而不是只管卡牌中心。
static func clamp_stack_anchor(at: Vector3, offsets: Array, bounds: Rect2) -> Vector3:
	if not has_table_bounds(bounds):
		return at
	var lo := Vector2.ZERO
	var hi := Vector2.ZERO
	for offset in offsets:
		lo.x = minf(lo.x, offset.x)
		lo.y = minf(lo.y, offset.z)
		hi.x = maxf(hi.x, offset.x)
		hi.y = maxf(hi.y, offset.z)
	var half := Vector2(CardEntity.CARD_SIZE.x, CardEntity.CARD_SIZE.z) * 0.5 \
		+ Vector2.ONE * BOUNDS_PAD
	var minimum := bounds.position + half - lo
	var maximum := bounds.end - half - hi
	# 外部恢复的旧牌列可能长于窗口。此时保持中心，随后 _layout_group 会收紧间距。
	at.x = clampf(at.x, minimum.x, maximum.x) if maximum.x >= minimum.x \
		else (minimum.x + maximum.x) * 0.5
	at.z = clampf(at.z, minimum.y, maximum.y) if maximum.y >= minimum.y \
		else (minimum.y + maximum.y) * 0.5
	return at

func clamp_player_position(at: Vector3, offsets: Array = []) -> Vector3:
	if has_table_bounds(player_bounds):
		at = clamp_stack_anchor(at, offsets, player_bounds)
		return screen_position_clamper.call(at, offsets) if screen_position_clamper.is_valid() else at
	var span := 0.0
	for offset in offsets:
		span = maxf(span, offset.z)
	at.z = clampf(at.z, player_min_z, maxf(player_min_z, player_max_z - span))
	return at

## 窗口可见桌面改变时更新交互边界。牌桌变大不重新居中玩家的牌；变小时只把
## 越界牌摞整体移回。正在拖拽、结算或飞入的牌等动作结束后再校正，避免抢补间位置。
func set_playable_bounds(table_rect: Rect2, player_rect: Rect2) -> void:
	if table_bounds.is_equal_approx(table_rect) and player_bounds.is_equal_approx(player_rect):
		return
	table_bounds = table_rect
	player_bounds = player_rect
	_playable_bounds_pending = has_table_bounds(player_bounds)
	_apply_pending_playable_bounds()

func _bounds_card_is_moving(card: CardEntity) -> bool:
	if card.dragging or card.has_meta("dest_pos"):
		return true
	var rec: Variant = _move_tw.get(card)
	return rec != null and rec["tw"] != null and is_instance_valid(rec["tw"]) \
		and rec["tw"].is_running()

func _apply_pending_playable_bounds() -> void:
	if not _playable_bounds_pending or input_locked or not _drag_cards.is_empty():
		return
	_playable_bounds_pending = false
	var grouped := {}
	for g in groups:
		var members: Array = g["cards"]
		if members.is_empty():
			continue
		var busy := false
		var player_group := true
		for card in members:
			grouped[card] = true
			if not is_instance_valid(card) or card.is_market or not card.draggable:
				player_group = false
			elif _bounds_card_is_moving(card):
				busy = true
		if not player_group:
			continue
		if busy:
			_playable_bounds_pending = true
			continue
		var anchor: Vector3 = members[0].global_position
		var offsets: Array = []
		var lo_z := 0.0
		var hi_z := 0.0
		for card in members:
			var offset: Vector3 = card.global_position - anchor
			offsets.append(offset)
			lo_z = minf(lo_z, offset.z)
			hi_z = maxf(hi_z, offset.z)
		if hi_z - lo_z + CardEntity.CARD_SIZE.z + BOUNDS_PAD * 2.0 > player_bounds.size.y:
			# 只有整列比新窗口还长时才减少露出间距；卡面尺寸、UID 和组员保持原样。
			_layout_group(g, anchor - _stack_offset(g, 0))
			continue
		var correction := clamp_player_position(anchor, offsets) - anchor
		if correction.is_zero_approx():
			continue
		for card in members:
			card.global_position += correction
		refresh_group(g)
	for card in cards:
		if not is_instance_valid(card) or grouped.has(card) or card.is_market or not card.draggable:
			continue
		if _bounds_card_is_moving(card):
			_playable_bounds_pending = true
			continue
		var at := card.global_position
		var bounded := clamp_player_position(at)
		if not at.is_equal_approx(bounded):
			card.global_position = bounded
			card.linear_velocity.x = 0.0
			card.linear_velocity.z = 0.0

## 落手与强制取消共用。以当前首牌为锚，不把每张卡分别夹到同一条边上。
func _clamp_drag_to_player() -> void:
	var alive: Array[CardEntity] = []
	for card in _drag_cards:
		if is_instance_valid(card):
			alive.append(card)
	if alive.is_empty():
		return
	var anchor := alive[0].global_position
	var offsets: Array = []
	for card in alive:
		offsets.append(card.global_position - anchor)
	var bounded := anchor
	if has_table_bounds(player_bounds):
		bounded = clamp_player_position(anchor, offsets)
	else:
		# 旧横屏的拖放只约束购牌区下沿，上沿由 _layout_group 排列后处理。
		bounded.z = maxf(bounded.z, player_min_z)
	var correction := bounded - anchor
	for card in alive:
		card.global_position += correction

func _physics_process(_delta: float) -> void:
	if not has_table_bounds(player_bounds):
		return
	# 碰撞可能把落地散卡推过边线；运动中/结算中有独立落点的牌由各自动画管理。
	for card in cards:
		if not is_instance_valid(card) or card.freeze or card.dragging or card.is_market \
				or not card.draggable or card.has_meta("dest_pos"):
			continue
		var at := card.global_position
		var bounded := clamp_player_position(at)
		if not at.is_equal_approx(bounded):
			card.global_position = bounded
			card.linear_velocity.x = 0.0
			card.linear_velocity.z = 0.0

func register_card(card: CardEntity) -> void:
	cards.append(card)
	# 点击拾取统一由 Board 在 _unhandled_input 里做物理射线（冻结刚体的 input_event 不可靠）

## 一张牌当场离场（被攻击点掉）：从组里摘掉，剩下的**立刻合上空档**。
## unregister_card 只 refresh_group（刷标签），剩下的牌还停在原来的槽位上——
## 一摞 5 张扣掉中间 2 张，剩的 3 张留在第 0/3/4 层，中间空着两层，
## 看起来就像「那两张还在，只是不见了」。这里补一次 _layout_group 把层号排紧
func drop_card(card: CardEntity) -> void:
	var g: Variant = group_of(card)
	# 组起点必须在牌走之前取：走掉的要是队首那张，之后反推就是拿队列里
	# 下一张的位置当起点，摊开态整摞会往 +z 挪一格 STACK_GAP.z
	var origin := Vector3.INF
	if g != null:
		origin = _group_origin(g)
	unregister_card(card)
	# unregister_card 可能已经把空组删了；组还在才值得重排
	if g != null and g in groups and not g["cards"].is_empty():
		_layout_group(g, origin)

func unregister_card(card: CardEntity) -> void:
	if card == _hover_card:
		_set_hover_card(null)
	card.reset_interaction_visual()
	cards.erase(card)
	_stop_move(card, false)   # 归位补间还在飞的话会写已释放实例
	# 在手的牌被释放时也要摘掉，否则 _process 会写已释放实例
	var di := _drag_cards.find(card)
	if di >= 0:
		_drag_cards.remove_at(di)
		if di < _drag_offsets.size():
			_drag_offsets.remove_at(di)
	# 同时从所在组移除——否则组里残留已释放对象的引用，后续组操作会崩
	var g: Variant = group_of(card)
	if g:
		g["cards"].erase(card)
		if g == _hover_group and g["cards"].is_empty():
			_hover_group = null
		if g["cards"].is_empty():
			_remove_group(g)
		elif is_instance_valid(g["cards"][0]):
			refresh_group(g)

# ---------- 拖拽 ----------

	## Stacklands 子堆拖拽：点第 N 张牌 = 拖走第 N 张 + 它屏幕下方的所有牌；
	## 点最顶上一张（index 0）= 拖走整个组合；其余牌留在原组并即时收拢
func _on_card_clicked(card: CardEntity) -> void:
	_set_hover_card(null)
	if not card.draggable:
		return
	var g: Variant = group_of(card)
	_drag_compact = false
	_drag_start_origin = Vector3.INF
	_drag_start_anchor = Vector3.INF
	_drag_src_group = null
	_drag_src_valid = false
	# 默认「手上这摞本身没凑满过」：散卡、以及从组里拆出来的半截都算这一类
	# （半截本身不是一个独立的组，它自己凑成配方是实打实的新凑满，该响）
	_drag_hand_valid = false
	if g:
		if g["cards"].size() > 1:
			# 记录被点的队首/卡心；若玩家拖远后又回到原处，松手应恢复快照，
			# 不再让高摞层距或透视边界参与一次无意义的重排。
			_drag_start_anchor = card.global_position
		# 收拢态整摞一起走：牌全叠在一处，射线基本只打得到最顶上那张，
		# 「点第 N 张拖走后半截」在这里既点不准也看不出效果。要拆先双击摊开
		var compact: bool = g.get("compact", false)
		var idx: int = 0 if compact else g["cards"].find(card)
		# 整摞被拎走（idx 0）才继承收拢态：摊开态拆出来的半截是一摞新牌，
		# 玩家没对它双击过
		_drag_compact = compact and idx == 0
		if _drag_compact:
			# 先记下桌面上的整摞起点和可见队首位置。拖拽时卡牌会被抬到
			# DRAG_HEIGHT；高摞还可能有 capped_offset，不能在新组上重新猜层距。
			_drag_start_origin = g["cards"][0].global_position - _stack_offset(g, 0)
			_drag_start_anchor = g["cards"][0].global_position
		_drag_cards.clear()
		for i in range(idx, g["cards"].size()):
			_drag_cards.append(g["cards"][i])
		var remain: Array = g["cards"].slice(0, idx)
		if remain.is_empty():
			# 整摞被拎走：手上这摞本来就是这个组，凑满基线跟着牌一起走，
			# 落桌重建时照原样还回去（挪个位置不该重复报凑满）
			_drag_hand_valid = bool(g.get("was_valid", false))
			# 牌的集合没变，只是整摞挪到手上：进度数字跟着牌一起走
			_remove_group(g, true)
		else:
			# 抽走几张之前的凑满状态：落手时要么按它还原（牌放回同一组），
			# 要么用它判断「抽走这几张是不是让剩下的反而凑满了」
			_drag_src_group = g
			_drag_src_valid = bool(g.get("was_valid", false))
			g["cards"] = remain
			if remain.size() < 2:
				g["compact"] = false   # 剩一张不成摞，见 _detach_from_group
			_pickup_quiet = true
			_layout_group(g)
			refresh_group(g)
			_pickup_quiet = false
	else:
		_drag_cards = [card]

	_drag_offsets.clear()
	# 拎到手上就清掉组高亮：那圈金光说的是「这一摞凑成了配方」，
	# 而手上这几张已经不在原来那个组里了。不清的话，从成立的组里拖走一张
	# 现金放到空地上，它会一直亮着 —— 亮的是一个已经不存在的组
	# （_detach_from_group 走的是同一条规矩）。
	# 落桌后该不该亮由 _end_drag → refresh_group 重新判，不影响并卡后重新点亮
	for c in _drag_cards:
		c.set_highlight(false)
	# 先掐掉在手这几张的归位补间：双击收拢的补间要跑 0.18s，玩家在这期间就能拎起来，
	# 补间不掐会一路盖掉 _process 的拖拽定位（见 _stop_move）
	for c in _drag_cards:
		_stop_move(c)
	# 抓取点 = 鼠标点击位置（而非卡中心），拖动时卡牌不跳位
	var grab := _mouse_table_point()
	_grab_offset = card.global_position - grab if grab != Vector3.INF else Vector3.ZERO
	var anchor := card.global_position
	for c in _drag_cards:
		c.freeze = true
		c.dragging = true
		c.set_drag_visual(true)
		_drag_offsets.append(c.global_position - anchor)
	# 高度归零到最低那张：被点的那张不一定在摞底（收拢态点摞顶、摊开态点中间都是），
	# 不归零的话 _process 里 DRAG_HEIGHT + 负偏移 会把整摞压到拖拽高度以下
	var min_y := 0.0
	for o in _drag_offsets:
		min_y = minf(min_y, o.y)
	for i in _drag_offsets.size():
		_drag_offsets[i].y -= min_y
	card_picked.emit(card)

func _unhandled_input(event: InputEvent) -> void:
	if view_gesture:
		return
	if touch_mode and event is InputEventMouse:
		_pointer_at = event.position
	if _interaction_is_blocked():
		# 释放事件仍能终止在手状态，避免窗口切换/弹层吃掉它后永远保持拖拽。
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
				and not event.pressed and not _drag_cards.is_empty():
			cancel_drag()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# 物理射线拾取：冻结/成组的卡也能点到
			var picked := _pick_card(event.position)
			# 双击 = 这一摞在「摊开」和「收拢」之间切换（收拢 = 沿高度摞起来省桌面）。
			# 第一击虽然当场把牌拎起来了，但它的松手照快照精确复位过
			# （见 _press_snap / _restore_press），所以这里面对的还是完整的那一摞。
			# 拿不准射线这一下打到了什么就交给 _dbl_target 兜底（见那边的注释）
			if _is_double(event, picked) and not attack_mode and not input_locked:
				var t := _dbl_target(picked)
				_reset_click_track()
				_last_press_card = null
				# 上一击的牌万一还在手上（松手事件被 HUD 吃掉了），先原样放回去
				if not _press_snap.is_empty():
					_restore_press()
				else:
					cancel_drag()
				if t != null:
					toggle_compact(t)
				return
			_note_click(event, picked)
			# 记下这一击打到哪张：第二击的射线未必还能打中同一张（见 _dbl_target）。
			# 打空也要记（写 null）——不然会留着上一次点的牌，
			# 下一次双击就跑去切一摞玩家这会儿根本没点的牌
			_last_press_card = picked
			if picked == null:
				return
			if attack_mode:
				# 攻击点选模式：点击 = 选靶（公共区卡除外），不拖拽
				if not picked.is_market:
					attack_clicked.emit(picked)
				return
			if input_locked:
				return
			# 按下就拎起来 —— 手感优先，不等双击窗口。代价是双击的第一击也会拎一次，
			# 由它的松手照快照原样放回（见 _press_snap），对桌面是空操作
			_snapshot_press(picked, event.position)
			_on_card_clicked(picked)
		else:
			if event.canceled:
				cancel_pointer()
			else:
				release_pointer(event.position)

## 上一次按下（非双击）拾到的卡：双击第二击的兜底目标
var _last_press_card: CardEntity = null

## 双击的时间上限（不靠 event.double_click，见 _is_double）
const DBL_WINDOW := 0.45
## 双击两击之间容许的光标位移（视口单位）。比系统的判定宽松：
## 玩家在一张 0.52 宽的标题带上快点两下，手抖几像素是常态
const DBL_RADIUS := 24.0
## 松手时光标离按下点还在这个距离内 = 这一下只是「点了一下」，不是拖：
## 按 _press_snap 原样还原，桌面回到按下前的样子。超出去才算真拖，走 _end_drag。
## **不能比 DBL_RADIUS 小**：小了就留出一段「够格判双击、松手却按拖拽结算」的位移区间
## —— 手抖 10 像素时第一击的松手把半截牌就地落成了新组（或靠 _nearest_group
## 侥幸并回去），第二击虽然认成了双击，toggle_compact 面对的却已经不是原来那一摞，
## 玩家看到的正是「只提起了组合里的一部分牌」。而 macOS 把 clickCount 打回 1
## 的抖动量级恰好就落在这一段里，所以这个洞是常态、不是边角
const CLICK_SLOP := DBL_RADIUS

## 这一次按下时桌面的原样，松手判定为「只是点了一下」时照它还原。
## 为什么需要它：按下就得把牌拎起来（手感——点了就得起来，不能等），
## 可摊开态点中间那张会把这一摞劈成「留下的半截」和「手上的半截」。
## 所以没移动过的松手不能靠吸附并回去：靠 _nearest_group 并得回去只是运气好 ——
## 落点越过 MERGE_DIST、或者边上另一摞更近，这一摞就真被劈成两半了，
## 而玩家的本意只是想双击把它摞起来。照这份快照精确复位才能保证
## 一次点击对桌面是彻底的空操作，于是第二击面对的必然还是完整的那一摞。
## 字段见 _snapshot_press
var _press_snap := {}
## 上一击的落点，用来自己判定双击
var _last_click_card: CardEntity = null
var _last_click_at := Vector2.ZERO
var _last_click_t := -100.0

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

## 这一击算不算双击的第二击。
## 平台给的 event.double_click 不能单独用：macOS 只要两击之间光标动了几像素
## 就把 clickCount 打回 1，双击标志根本不来 —— 表现就是「双击经常没反应，
## 只是把牌拎起来又放下」。所以自己再判一遍：同一张牌（或同一摞）、
## 在 DBL_WINDOW 内、位移不超过 DBL_RADIUS
func _is_double(event: InputEventMouseButton, picked: CardEntity) -> bool:
	if event.double_click:
		return true
	if _last_click_card == null or not is_instance_valid(_last_click_card):
		return false
	if _now() - _last_click_t > DBL_WINDOW:
		return false
	if event.position.distance_to(_last_click_at) > DBL_RADIUS:
		return false
	if picked == null:
		return true   # 第二击射线打空：位置和时间都对得上，认这一次（_dbl_target 会挑靶）
	if picked == _last_click_card:
		return true
	# 摊开态每张只露 0.52 宽，两击很容易落在同一摞的相邻两张上 —— 同摞也算
	var g1: Variant = group_of(picked)
	var g2: Variant = group_of(_last_click_card)
	return g1 != null and g2 != null and is_same(g1, g2)

func _note_click(event: InputEventMouseButton, picked: CardEntity) -> void:
	_last_click_card = picked
	_last_click_at = event.position
	_last_click_t = _now()

## 双击成立后清掉追踪：不清的话三击的第三下会和第二下再配成一对，
## 一摞牌在「收拢-摊开」之间闪一下
func _reset_click_track() -> void:
	_last_click_card = null
	_last_click_t = -100.0

## 双击该切换哪一摞。第二击的射线不总是可靠：第一击要是移开了光标（长成了拖拽），
## 牌就被拎到了 DRAG_HEIGHT 又松手，此刻 _layout_group 的 0.18s 归位补间还在跑，
## 牌正悬在半空往下落。相机是 71° 俯角，牌每高出桌面 Δ，射线打到它的位置就往
## +z 偏 Δ×0.345——摊开态每张只露 0.52 宽的标题带，这点偏移足够让射线擦过牌沿打空，
## picked 就成了 null。所以优先认第一击拾到的那张（玩家的真实意图），
## 它已经不在任何组里才退回射线结果。
## 精确复位（见 _press_snap）让「按下-松手-按下」这条常路上桌面回到了原样，
## 射线本来就打得准；这里兜的是「第一击真拖了一段再松手」的情形
func _dbl_target(picked: CardEntity) -> CardEntity:
	if _last_press_card != null and is_instance_valid(_last_press_card) \
		and group_of(_last_press_card) != null:
		return _last_press_card
	if picked != null and group_of(picked) != null:
		return picked
	# 都不在组里：射线结果优先（至少是玩家看得见的那张），让 toggle_compact 去拒
	return picked if picked != null else _last_press_card

## 从屏幕坐标射线拾取一张卡（只认 CardEntity，忽略桌面）
func _pick_card(screen_pos: Vector2) -> CardEntity:
	if not camera:
		return null
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 100.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	if hit["collider"] is CardEntity:
		return hit["collider"]
	return null

func _process(delta: float) -> void:
	_apply_pending_playable_bounds()
	if _interaction_is_blocked():
		_set_hover_card(null)
		_hide_desc()
		if not _drag_cards.is_empty():
			cancel_drag()
		_tick_drag_broadcast(delta)
		return
	_tick_drag_broadcast(delta)
	if _drag_cards.is_empty():
		if not touch_mode and not attack_mode and not input_locked:
			_update_hover_hint()
		else:
			_set_hover_card(null)
			_hide_desc()
		return
	# 结算/攻击可能在拖拽途中释放掉在手的牌（HUD 吃掉松手事件时拖拽不会结束）
	for c in _drag_cards.duplicate():
		if not is_instance_valid(c):
			cancel_drag()
			return
	var target := _mouse_table_point()
	if target == Vector3.INF:
		return
	# 展开牌列以抓住的首牌为交互锚点，尾部可临时伸出屏幕；
	# 否则列越长，首牌越够不到底部目标。收拢摞继续按整体约束。
	var held_bounds: Array = _drag_offsets if _drag_compact else _drag_offsets.slice(0, 1)
	var anchor := clamp_stack_anchor(target + _grab_offset, held_bounds, table_bounds)
	anchor.y = DRAG_HEIGHT
	if screen_position_clamper.is_valid():
		anchor = screen_position_clamper.call(anchor, held_bounds)
	for i in _drag_cards.size():
		var c := _drag_cards[i]
		var pos := anchor + _drag_offsets[i]
		# 层高沿用抓起瞬间的相对高度，不按 index 重算：收拢态的 y 顺序是反的
		# （index 0 在最顶上），按 index 递增会把核心卡翻到摞底，一拎起来就变了个样
		pos.y = DRAG_HEIGHT + _drag_offsets[i].y
		var velocity := (pos - c.global_position) / maxf(delta, 0.001)
		c.global_position = pos
		c.update_drag_motion(velocity, delta)
	# 吸附高亮
	var g: Variant = _nearest_group(target, _drag_cards)
	# 刚拆出来的那一摞不算吸附目标：手上这几张是**从它身上**拿的，
	# 松手前一直贴着它，_nearest_group 必然选中它 —— 于是玩家一拆组，
	# 剩下的牌就无端亮一下，看着像「拆完反而凑成了」。
	# 只掐高亮不掐吸附：_end_drag 自己重新问一次 _nearest_group，
	# 所以拆一半又放回原摞照旧能并回去
	if g != null and _is_drag_src(g):
		g = null
	if g != _hover_group:
		clear_hover_group()   # 内含有效性检查：上一组可能已在结算中被释放
		_hover_group = g
		if _hover_group:
			_set_group_highlight(_hover_group, true)
	# 拖拽途中不弹提示：配方进度已经印在牌面 D 位的墨团和组顶进度条上，
	# 手上那张的进度看牌面就够，浮动大字只是又抄了一遍

## 每帧看一眼手上这摞，该广播就广播（scenes/main.gd 的拖拽广播与租约处理）。
##
## 为什么盯**状态**而不是在各处拎起/落手的代码里插 emit：手上这摞的出口有五条
## （_end_drag 的典当/购买/并组/散落四条 + cancel_drag + _restore_press），
## 而且还会继续加。逐处插 emit 的话漏掉一条的后果是**对手那边的牌永远浮在半空**，
## 而本地一切正常 —— 正是 README.md §「3. 文件目录结构」要防的那种静默分叉。
## 盯「上一帧手上有、这一帧没有了」，一处就盖住全部出口，以后新增出口也自动覆盖。
##
## 代价是松手比落手的信号晚一帧到。这一帧不影响正确性：落点是权威事件，
## 由 drop 那条意图的结果决定，不由最后一帧 dragging 决定（scenes/main.gd 的拖拽广播与租约处理）
func _tick_drag_broadcast(delta: float) -> void:
	if _drag_cards.is_empty():
		if not _bcast_uids.is_empty():
			# 手上空了：广播一帧「放下了」。至于放到哪儿去了 —— 那是意图的结果
			# 说的事，这条只负责把远端那几张牌从网络驱动交还给布局
			drag_broadcast.emit(Protocol.DRAG_CANCEL, _bcast_uids, Vector3.ZERO)
			_bcast_uids = []
			_bcast_at = Vector3.INF
		return
	var uids: Array = []
	for c in _drag_cards:
		if is_instance_valid(c):
			uids.append(c.uid)
	if uids.is_empty():
		return
	# 拎起来的第一帧不节流：pickup 是可靠的一次性事件，晚一拍到就是对手侧
	# 那几张牌晚一拍才抬起来
	var at: Vector3 = _drag_cards[0].global_position
	if _bcast_uids != uids:
		_bcast_uids = uids
		_bcast_t = 0.0
		_bcast_at = at
		drag_broadcast.emit(Protocol.DRAG_PICKUP, uids, at)
		return
	# 动了就**当帧发**，不攒。收方是硬写位置的，攒一帧就是对手屏幕上
	# 那张牌少动一帧（见 DRAG_KEEPALIVE_DT 那段实测）
	if _bcast_at.distance_squared_to(at) > DRAG_MOVE_EPS * DRAG_MOVE_EPS:
		_bcast_t = 0.0
		_bcast_at = at
		drag_broadcast.emit(Protocol.DRAG_MOVE, uids, at)
		return
	# 停着不动：只为续租而发（收方那条租约要靠它续，见 DRAG_KEEPALIVE_DT）
	_bcast_t += delta
	if _bcast_t < DRAG_KEEPALIVE_DT:
		return
	_bcast_t = 0.0
	_bcast_at = at
	drag_broadcast.emit(Protocol.DRAG_MOVE, uids, at)

## 拎牌之前记下桌面原样。必须在 _on_card_clicked 之前调用：那边会改 g["cards"]、
## 翻 compact、甚至把整个组从 groups 里摘掉，之后就没处问「原来是什么样」了。
## 组 dict 本身是引用，摘出去了这份快照照样攥着它，还得回去
func _snapshot_press(card: CardEntity, at: Vector2) -> void:
	var g: Variant = group_of(card)
	# 散卡的原位要在补间落定之后读：这张牌可能正从上一次整理里飞回来，
	# 半路的 global_position 记下来，松手复位就把它钉在了半空
	# （成组那条路不用管，_group_origin 内部先 _stop_move 过队首）
	if g == null:
		_stop_move(card)
	_press_snap = {
		"card": card,
		"at": at,
		"group": g,        # null = 散卡
		"cards": [],       # 按下前的队列（含顺序：_core_first 会重排）
		"compact": false,
		"was_valid": false,
		"origin": Vector3.INF,   # 队首静止位置减掉层偏移，见 _group_origin
		"pos": card.global_position,        # 散卡才用得上
		"rot": card.rotation_degrees,
	}
	if g != null:
		_press_snap["cards"] = (g["cards"] as Array).duplicate()
		_press_snap["compact"] = bool(g.get("compact", false))
		_press_snap["was_valid"] = bool(g.get("was_valid", false))
		# 起点在牌动之前取：拎起来之后队首那张已经在 DRAG_HEIGHT 上，反推出来的
		# 起点会高出一个拖拽高度，还原时整摞就浮在半空
		_press_snap["origin"] = _group_origin(g)

## 把桌面恢复成按下之前的样子，用于「按下-松手，光标基本没动」这条路。
## 不走 _end_drag 的吸附：吸附要看落点离哪一摞近，而这里要的是精确复位 ——
## 一次点击必须是空操作，否则双击的第二击就面对不到完整的那一摞（见 _press_snap）。
## 也不响任何声音：牌确实起来又落下，但组合结果前后一模一样
func _restore_press() -> void:
	if _press_snap.is_empty():
		return
	var snap := _press_snap
	_press_snap = {}
	for c in _drag_cards:
		if is_instance_valid(c):
			c.dragging = false
			c.pulse_landed()
			c.freeze = false
	_drag_cards = []
	_drag_offsets.clear()
	_drag_compact = false
	_drag_start_origin = Vector3.INF
	_drag_start_anchor = Vector3.INF
	_drag_hand_valid = false
	# 源组的凑满基线跟着还原，且不结算那一声：这次点击前后组合结果没变
	# （_commit_pickup_ding 只在真落手的路径上调，这里直接清掉记录）
	_drag_src_group = null
	_drag_src_valid = false
	clear_hover_group()
	_hide_desc()
	var g: Variant = snap["group"]
	if g == null:
		var c0: CardEntity = snap["card"]
		if is_instance_valid(c0):
			_stop_move(c0, false)
			c0.global_position = snap["pos"]
			c0.rotation_degrees = snap["rot"]
			c0.freeze = false
		return
	# 组还原：队列、形态、基线三样都按原值写回，再照原起点重排
	var alive: Array = []
	for c in snap["cards"]:
		if is_instance_valid(c):
			alive.append(c)
	if alive.is_empty():
		return
	g["cards"] = alive
	g["compact"] = snap["compact"]
	g["was_valid"] = snap["was_valid"]
	var listed := false
	for gg in groups:
		if is_same(gg, g):
			listed = true
			break
	if not listed:
		groups.append(g)   # 整摞被拎走时 _on_card_clicked 把它摘掉了
	_pickup_quiet = true   # 复位不是新凑满，别报叮
	_layout_group(g, snap["origin"])
	refresh_group(g)
	_pickup_quiet = false

# ---------- 悬停说明（光标停在卡上时，贴在卡右侧的一行效果描述） ----------

var _desc: Label3D = null      # 悬停说明：平铺在桌面上，贴卡右侧
var _desc_panel: MeshInstance3D = null   # 说明的衬底
var _desc_edge: MeshInstance3D = null    # 衬底的深色描边

## 悬停说明的排版（见 _ensure_desc）
const DESC_PIXEL := 0.0052     # 行盒约 0.33 世界单位 ≈ 卡名字高，明显小于原先的悬浮大字
## 单行宽度上限（世界单位，约 12 个汉字）。文案在 describe_def 里自带换行，
## 运行时不折行；这条只是 test_hover_desc 的守栏：
## 任何一行超过它就说明该在 describe_def 里补个 \n，否则说明会横穿邻列牌堆
const DESC_WIDTH := 2.6
const DESC_GAP := 0.14         # 卡右沿 → 文字左沿的间距
const DESC_Y := 0.32           # 离桌高度：压过最高的牌堆（10 张 × 0.024 + 牌厚）又不脱离桌面
const DESC_PAD := Vector2(0.13, 0.07)   # 衬底相对文字外廓的留白：x 左右，z 上下

## 悬停说明标签：与卡牌同平面（-90° 平铺，不像拖拽提示那样立起来），
## 放在卡右侧、左对齐，读起来像卡边上的一行注释而不是盖在桌面上的横幅
func _ensure_desc() -> void:
	if _desc == null:
		_desc = Label3D.new()
		# 伪加粗 + 深墨色：桌布是浅绿的，先前的近白字加黑描边在上面糊成一团灰发丝
		# （描边从两侧吃掉笔画，见 Fonts.EMBOLDEN 的实测）。改成和卡面同一套墨色，
		# 浅色衬边只负责把字从桌布纹理里托出来
		_desc.font = Fonts.zh_bold()
		_desc.pixel_size = DESC_PIXEL
		_desc.font_size = 40
		_desc.outline_size = 4
		_desc.outline_modulate = Color(0.96, 0.97, 0.90, 0.85)
		_desc.modulate = Color(0.13, 0.12, 0.11)
		_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_desc.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# width 每次显示时按实测文字外廓收紧（见 _show_desc）：
		# 留一个固定的宽框会让文字在框里居中、和衬底对不上左沿
		_desc.autowrap_mode = TextServer.AUTOWRAP_OFF
		_desc.rotation_degrees = Vector3(-90, 0, 0)
		_desc.visible = false
		add_child(_desc)
	if _desc_panel == null:
		# 衬底：说明贴在卡右侧，而右边邻居十有八九还是张卡（货架整整一排），
		# 没有衬底时深墨字直接落在别人的图标线条上，两层黑线糊成一团。
		# 描边框 + 米色底照抄卡面的做法，让这块读起来像张便签而不是浮在桌上的字
		_desc_edge = _flat_plate(Color(0.16, 0.14, 0.12))
		_desc_panel = _flat_plate(Color(0.97, 0.96, 0.89))
		_desc_edge.visible = false
		_desc_panel.visible = false

## 平铺的单色薄板，给说明衬底用（BoxMesh 而非 QuadMesh：0 厚度的面在
## gl_compatibility 下会和桌面 z-fighting）
func _flat_plate(col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1, 0.01, 1)   # 尺寸每次显示时按文字外廓重设
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 1.0
	mi.material_override = mat
	add_child(mi)
	return mi

## 显示卡牌说明：贴在 card 右侧，与卡同平面。
## at_z 给定时说明在纵向跟着光标走（见 _update_hover_hint）；
## 省略 = 对齐卡中心（测试和非鼠标调用走这条）
func _show_desc(text: String, card: CardEntity, at_z := INF) -> void:
	# 空文案不摆空板子：调用方（_update_hover_hint）本来就会跳过，
	# 但衬底一旦有尺寸就会在桌上留一块白，宁可在这里也挡一道
	if text.strip_edges() == "":
		_hide_desc()
		return
	_ensure_desc()
	_desc.text = text
	var at := card.global_position
	# 衬底按真实文字外廓收紧，不用 DESC_WIDTH：短说明（「组内产出 ×2」）
	# 配一块 2.6 宽的板子会盖住右边整张卡
	var box := _desc_extent(text)
	var left := at.x + CardEntity.CARD_SIZE.x / 2.0 + DESC_GAP
	# 纵向跟着光标：镜头俯视，屏幕上下就是世界 z，光标在卡上从上缘扫到下缘时
	# 说明跟着走，读起来是「指到哪儿注在哪儿」。横向不跟——x 固定在卡右沿之外，
	# 这是「不遮挡卡牌」的保证；跟着光标 x 走的话光标一往右挪说明就爬到卡上了。
	# z 钳在卡的上下缘内，免得光标压着卡边时整块说明飘到卡外面去
	var z: float = at.z
	if at_z != INF:
		var half: float = CardEntity.CARD_SIZE.z / 2.0
		z = clampf(at_z, at.z - half, at.z + half)
	if has_table_bounds(table_bounds):
		var padding := DESC_PAD + Vector2.ONE * 0.05
		if left + box.x + padding.x > table_bounds.end.x:
			left = at.x - CardEntity.CARD_SIZE.x / 2.0 - DESC_GAP - box.x
		left = clampf(left, table_bounds.position.x + padding.x,
			maxf(table_bounds.position.x + padding.x, table_bounds.end.x - box.x - padding.x))
		z = clampf(z, table_bounds.position.y + box.y / 2.0 + padding.y,
			maxf(table_bounds.position.y + box.y / 2.0 + padding.y,
				table_bounds.end.y - box.y / 2.0 - padding.y))
	# 高度不能写死成 DESC_Y：那个值按「一摞满份的摊开堆」算的（0.32），
	# 而结算带里的收拢摞会被抬到 y=1.8（见 main._settle_pile_heights），说明就埋进牌底下了。
	# 和清单同一条规矩：盖住谁就落在谁上面一级台阶，DESC_Y 是下限（见 overlay_y）。
	# 被悬停的那张自己也在里面 —— 说明本来就该压在它上面
	var y: float = overlay_y(Vector3(left + box.x / 2.0, 0.0, z),
		box + DESC_PAD * 2.0, DESC_Y)
	# autowrap 关掉后 width 不再参与排版，左对齐的文字直接从原点向右画，
	# 所以原点就是文字左沿（不是 width 盒的中心）
	_desc.global_position = Vector3(left, y, z)
	_desc.visible = true
	var mid := Vector3(left + box.x / 2.0, y, z)
	# 两块板子各下沉一档：Label3D 走透明通道，和衬底贴太近会 z-fighting
	_place_plate(_desc_panel, mid, box + DESC_PAD * 2.0, -0.02)
	_place_plate(_desc_edge, mid, box + DESC_PAD * 2.0 + Vector2(0.09, 0.09), -0.04)

## 把衬底摆到 mid、尺寸设为 size，dy 是相对文字的高度偏移（负数=压在文字下面）
func _place_plate(mi: MeshInstance3D, mid: Vector3, size: Vector2, dy: float) -> void:
	var bm: BoxMesh = mi.mesh
	bm.size = Vector3(size.x, 0.01, size.y)
	mi.global_position = mid + Vector3(0, dy, 0)
	mi.visible = true

## 说明文字的实际外廓（世界单位）。按 \n 逐行量最宽的一行，
## 行高用 get_string_size 的 y（行盒 = ascent+descent，和 Label3D 的排版一致）
func _desc_extent(text: String) -> Vector2:
	var f := _desc.font
	var fs := _desc.font_size
	var w := 0.0
	var lines := text.split("\n")
	for line in lines:
		w = maxf(w, f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var lh := f.get_string_size("字", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).y
	return Vector2(w, lh * lines.size()) * DESC_PIXEL

func _hide_desc() -> void:
	if _desc:
		_desc.visible = false
	if _desc_panel:
		_desc_panel.visible = false
	if _desc_edge:
		_desc_edge.visible = false

## 卡牌效果的一句话描述（产出/攻击/合成/增益）
## 悬停时只展示这一句：卡名已印在标题带上、配方进度已在 D 位墨团和组顶进度条上，
## 提示框里再抄一遍等于让玩家读三处相同信息
## 换行位置是写死的，不靠 autowrap：中文没有词间空格，
## AUTOWRAP_WORD_SMART 只能在任意字之间断，会切出「每回合资 / 金+12」这种断词。
## 手动在箭头处断行，「配方 → 效果」正好一行一段
func describe_def(def_id: String) -> String:
	var def: Dictionary = CardDB.get_def(def_id)
	# 配方和攻击目标数的是牌（现金×4），每回合产出说的是资源总量（资金+7）。
	# 两种名字都得按这条分，否则同一个配方在悬停里叫「资金×4」、在配方不足的报错里叫「现金×4」
	match str(def.get("kind", "")):
		CardDB.KIND_PRODUCT:
			# 普通升级仍须同名；传说路线则可搭配同档的其他生产卡。
			return "%s×%d\n→ 每回合%s+%d%s" % [
				CardDB.card_label(def["recipe_res"]), int(def["recipe_n"]),
				CardDB.res_label(def["output_res"]), int(def["output_n"]),
				_upgrade_line(def_id)]
		CardDB.KIND_ATTACK:
			return "%s×%d\n→ 移除对方%s×%d" % [
				CardDB.card_label(def["recipe_res"]), int(def["recipe_n"]),
				CardDB.card_label(def["attack_res"]), int(def["attack_n"])]
		CardDB.KIND_LEGEND:
			var routes: PackedStringArray = []
			for tier in [1, 2]:
				var counts: PackedStringArray = []
				for n in range(2, CardDB.max_upgrade_n() + 1):
					if ComboRules.legend_upgrade_target(tier, n) == def_id:
						counts.append(str(n))
				if not counts.is_empty():
					routes.append("同档T%d生产卡×%s" % [tier, "/".join(counts)])
			if routes.is_empty():
				return "当前配置无合成路线"
			return "合成：\n%s\n同名异名均可\n张数须精确\n不能夹杂其他牌" % "\n或".join(routes)
		CardDB.KIND_BUFF:
			var bt := str(def.get("buff_type", ""))
			match bt:
				# 主语必须是**配方**而不是用户：写「用户视为满」会读成「用户变多了」，
				# 而这张卡一张卡都不增（产出照旧按配方量算，席位也只占实放的那几张）。
				# 「至少1张」是硬门槛，得写出来 —— 一张都不放时裂变救不了，
				# 这是玩家最容易踩的那一脚（ComboRules._fission_fills 第三条）
				#
				# 断成三行不是排版洁癖：写成两行时「组里至少1张即视为配方已满」
				# 单行 2.66 > DESC_WIDTH 2.60，会在汉字之间断词（test_hover_desc 报红）。
				# 宁可多一行也不删「至少」/「配方」——那两个词各挡一个误读
				"user_fill": return "核心卡吃%s时：\n组里至少1张\n即视为配方已满" % CardDB.card_label(CardDB.RES_USER)
				"output_x2": return "组内产出 ×2"
				"attack_x2": return "组内攻击 ×2"
				# 保护挡的是「被移除」，移除的单位是牌 → 卡名。
				# buff_type 是 protect_<res> 拼出来的（CardDB.protect_key），这里反解回 res：
				# 两种资源共用一句模板，各写一遍时改措辞只会改到一半
				"protect_user", "protect_cash":
					return "入组立即保护\n组内%s不可被移除\n仅限配方所需张数" % CardDB.card_label(bt.trim_prefix("protect_"))
		CardDB.KIND_UNIT:
			# 单位卡本身没有效果，说明它是配方材料，否则悬停时这类卡完全没有反馈
			return "配方材料：%s" % CardDB.card_label(str(def.get("res", "")))
	return ""

## 普通升级与同档传说分开说明；张数和折算率均由真实规则派生。
func _upgrade_line(def_id: String) -> String:
	var def: Dictionary = CardDB.get_def(def_id)
	var near := ""
	var legend_ns: PackedStringArray = []
	var tier := int(def.get("tier", 0))
	for n in range(2, CardDB.max_upgrade_n() + 1):
		var target := ComboRules.upgrade_target(def_id, n)
		if def.get("kind", "") == CardDB.KIND_PRODUCT and ComboRules.legend_upgrade_target(tier, n) != "":
			legend_ns.append(str(n))
		if target != "" and CardDB.get_def(target).get("kind", "") != CardDB.KIND_LEGEND and near == "":
			near = "\n同名×%d → %s" % [n, CardDB.card_name(target)]
	if not legend_ns.is_empty():
		near += "\n同档T%d×%s\n→ 传说卡（可异名）\n张数须精确\n不能夹杂其他牌" % [tier, "/".join(legend_ns)]
	return near

## 悬停说明文案：效果描述 + 典当价（卡名/标价/配方进度都已在牌面或价签上）。
## 每张卡都写典当价，不只传说卡：典当是要不要出手的即时判断，
## 缺这一行就只能拖过去试 —— 和效果放在同一块白板上才比得出来。
## 现金卡不可典当（pawn_value 0），不写这一行免得白板上多一句「+0」
func hover_desc_text(def_id: String) -> String:
	var t := describe_def(def_id)
	var pawn := CardDB.pawn_value(def_id)
	if pawn <= 0:
		return t
	return ("典当 +%d" % pawn) if t == "" else "%s\n典当 +%d" % [t, pawn]

## 悬停（未拖拽）时：贴在被指卡右侧显示效果说明，购卡区和场上卡一视同仁。
## 每帧都跑：光标一离开卡（_pick_card 打空）说明立刻收掉
func _set_hover_card(card: CardEntity) -> void:
	if card == _hover_card:
		return
	if is_instance_valid(_hover_card):
		_hover_card.set_hover_visual(false)
	_hover_card = card
	if is_instance_valid(_hover_card):
		_hover_card.set_hover_visual(true)

func _update_hover_hint() -> void:
	if hover_blocked.is_valid() and hover_blocked.call():
		_set_hover_card(null)
		_hide_desc()
		return
	var picked := _pick_card(get_viewport().get_mouse_position())
	_set_hover_card(picked)
	if picked != null:
		var t := hover_desc_text(picked.def_id)
		if t != "":
			# 说明的纵向跟着光标在桌面上的落点走（见 _show_desc）
			var mp := _mouse_table_point()
			_show_desc(t, picked, mp.z if mp != Vector3.INF else INF)
			return
	_hide_desc()

## 清掉吸附高亮：每条拖拽结束路径都必须走这一步
## （否则 _hover_group 留着已释放的组，下一次拖拽访问它就崩）
func clear_hover_group() -> void:
	if _hover_group and _hover_group in groups:
		var alive := true
		for c in _hover_group["cards"]:
			if not is_instance_valid(c):
				alive = false
				break
		if alive:
			_set_group_highlight(_hover_group, false)
			refresh_group(_hover_group)
	_hover_group = null

## 强制中止拖拽：把在手的牌放回桌面（HUD 控件吃掉松手事件时的兜底）
func cancel_drag() -> void:
	_clamp_drag_to_player()
	_press_snap = {}   # 强制中止：这一击不再有「原样放回」的机会，快照作废
	for c in _drag_cards:
		if is_instance_valid(c):
			c.dragging = false
			c.pulse_landed()
			c.freeze = false
			# 这条路不重建组（牌是散着落回桌面的）。整摞拎起来时进度是跟着牌
			# 走的（见 _remove_group 的 keep_progress），到这儿组没了，
			# 留着的数字就成了「不属于任何组的 3/3」，退回 0/N
			if group_of(c) == null:
				reset_recipe_progress(c)
	_drag_cards = []
	_drag_offsets.clear()
	_drag_compact = false
	_drag_start_origin = Vector3.INF
	_drag_start_anchor = Vector3.INF
	_drag_hand_valid = false
	clear_hover_group()
	# 牌被原样放回桌面：源组此刻的凑满状态就是最终状态，该响的补上
	_commit_pickup_ding()
	_hide_desc()

## 把手上的牌摘下来交给外部接收方（典当行 / 购牌区），返回这一摞。
##
## 这两条路的共同点是牌不落回桌面，由接收方决定去处，所以这里只做「放手」：
## 牌停止拖拽、摘平、清掉拖拽态和吸附高亮，然后把 `_drag_compact` 转存到
## `last_drag_compact` —— 接收方要靠它知道交过来的是收拢摞还是摊开的几张
## （买不起时 main.gd 照原样把摞重建回来）。
##
## 不并进 `cancel_drag`：那条路牌是散着落回桌面的，要 `is_instance_valid` 保护、
## 要恢复 `freeze`、要退配方进度，且不存 `last_drag_compact`（没有接收方）
func _detach_drag() -> Array:
	var dc: Array = _drag_cards.duplicate()
	for c in dc:
		c.dragging = false
		c.pulse_landed()
	_drag_cards = []
	_drag_offsets.clear()
	last_drag_compact = _drag_compact
	_drag_compact = false
	clear_hover_group()
	_commit_pickup_ding()
	return dc

## 仅用于原摞落到空地：把原有支撑面沿拖拽的 x/z 位移平移。
## 与散卡/另一摞合并必须先记录目标的支撑面，不能按新成员数反减层高。
func _drag_drop_origin(g: Dictionary) -> Vector3:
	if not bool(g.get("compact", false)) or _drag_start_origin == Vector3.INF \
		or _drag_start_anchor == Vector3.INF or _drag_cards.is_empty():
		return Vector3.INF
	var delta := _drag_cards[0].global_position - _drag_start_anchor
	return _drag_start_origin + Vector3(delta.x, 0.0, delta.z)

func _end_drag() -> void:
	# 在手的牌可能先被 unregister_card 摘走；随后到达的松手事件不再有落点。
	if _drag_cards.is_empty():
		return
	# 真实鼠标可能在按住期间越过 CLICK_SLOP 后又回到原处；这仍是“原地松手”。
	# 直接走按下快照，尤其避免高摞在抬升/降回时重新计算层距造成落点漂移。
	if _drag_cards.size() > 1 and not _press_snap.is_empty() \
		and not _drag_start_anchor == Vector3.INF and is_instance_valid(_drag_cards[0]):
		var delta := _drag_cards[0].global_position - _drag_start_anchor
		if Vector2(delta.x, delta.z).length() <= 0.12:
			_restore_press()
			return
	_hide_desc()
	var drop := _drag_cards[0].global_position
	# 典当行与最右市场卡现在同处购牌带：两者命中范围重叠时取更近目标。
	var pawn_distance := INF
	if pawn_pos != Vector3.INF:
		pawn_distance = Vector2(pawn_pos.x - drop.x, pawn_pos.z - drop.z).length()
	var m: CardEntity = _market_card_near(drop)
	var market_distance := INF
	if m != null:
		market_distance = Vector2(m.global_position.x - drop.x, m.global_position.z - drop.z).length()
	if pawn_distance < PAWN_RADIUS and pawn_distance <= market_distance:
		dropped_on_pawn.emit(_detach_drag())
		return
	# 拖到公共区的卡上 = 尝试购买（由游戏控制器校验现金与价格）
	if m != null:
		dropped_on_market.emit(_detach_drag(), m)
		return
	# 先按实际松手位置认领目标。展开列尾部可能在屏外，若先回夹整列，
	# 抓住的首牌会被推离底部目标，造成高亮能对上、松手却合不上。
	var target_group: Variant = _nearest_group(drop, _drag_cards)
	var loose: CardEntity = _nearest_loose_card(drop, _drag_cards) if target_group == null and _drag_cards.size() > 1 else null
	if target_group == null and loose == null:
		_clamp_drag_to_player()
		drop = _drag_cards[0].global_position
	for c in _drag_cards:
		c.dragging = false
		c.pulse_landed()
	if target_group:
		# 必须在追加成员和重排核心之前取：新队首/新层数不代表目标原本的底面。
		var target_origin := _group_origin(target_group)
		for c in _drag_cards:
			target_group["cards"].append(c)
		# 并入哪一组，就随哪一组的形态。落进收拢摞的牌是追加在队尾（=摞底），
		# 核心卡得重新提回摞顶，否则新买的核心卡一并进去就被埋了
		if target_group.get("compact", false):
			_core_first(target_group)
		# 牌放回刚抽走它们的那一组：基线还原，结果没变就不响（见 _restore_src_baseline）
		_restore_src_baseline(target_group)
		var completed: bool = _layout_group(target_group, target_origin)  # 内部已刷新配方标签
		clear_hover_group()
		_commit_pickup_ding()
		card_stacked.emit(completed)
		# 组合不单独发音，但牌确实落到桌上了：这一声归 drop（见 pile_toggled）
		card_dropped_table.emit()
	else:
		clear_hover_group()
		if _drag_cards.size() > 1:
			# 一摞牌落到单张散卡上：散卡并入这摞
			if loose != null:
				# 基线取「手上这摞拎起来时是否已凑满」：并入一摞已凑满的牌不该再报一次「凑满」，
				# 但拆出来的半截和散卡凑成新配方要照响
				# 散卡原来的位置是新摞的底部基准，不是新摞顶层。
				# 若先按新牌数扣层高，再套8层显示上限，整组会被排到桌面以下。
				_stop_move(loose)
				var target_origin := loose.global_position
				var mg := make_group([loose] + _drag_cards.duplicate(), _drag_compact, _drag_hand_valid)
				groups.append(mg)
				var mg_completed: bool = _layout_group(mg, target_origin)  # 内部已刷新配方标签
				_commit_pickup_ding()
				card_stacked.emit(mg_completed)
			else:
				# 子组合落桌：自成新组，保持堆叠。基线同上——整摞挪个位置不重复报叮，
				# 从一组里拆出来的半截自己凑成了配方则要报
				var ng := make_group(_drag_cards.duplicate(), _drag_compact, _drag_hand_valid)
				groups.append(ng)
				var ng_origin := _drag_drop_origin(ng) if _drag_compact else Vector3.INF
				_layout_group(ng, ng_origin)
				_commit_pickup_ding()
		else:
			# 单卡：按松手位置立即吸附，没并入组的才恢复物理
			var c0: CardEntity = _drag_cards[0]
			_drag_cards = []
			_drag_offsets.clear()
			var mr: Dictionary = try_merge(c0)
			_drag_compact = false
			_commit_pickup_ding()
			if mr["merged"]:
				card_stacked.emit(mr["completed"])
			else:
				c0.freeze = false  # 恢复刚体，自然落定
			# 并进组也好、落回空桌也好，都是「牌落到桌上」，一律一声闷响。
			# 成组不另配咔哒 —— 那一声留给双击摞牌（见 pile_toggled）
			card_dropped_table.emit()
			return
		card_dropped_table.emit()
	_drag_cards = []
	_drag_offsets.clear()
	_drag_compact = false
	_drag_start_origin = Vector3.INF
	_drag_start_anchor = Vector3.INF
	_drag_hand_valid = false

## 最近的散卡（不在任何组里的单卡）
func _nearest_loose_card(pos: Vector3, exclude: Array) -> CardEntity:
	var best: CardEntity = null
	var best_d := 1.0   # 需要明显重叠
	for c in cards:
		if not is_instance_valid(c) or c.is_market or c.dragging or exclude.has(c):
			continue
		if group_of(c) != null:
			continue
		var d := Vector2(c.global_position.x - pos.x, c.global_position.z - pos.z).length()
		if d < best_d:
			best_d = d
			best = c
	return best

## 附近的公共区卡牌（拖现金上去购买用）
func _market_card_near(pos: Vector3) -> CardEntity:
	var best: CardEntity = null
	var best_d := 1.5
	for c in cards:
		if not is_instance_valid(c) or not c.is_market:
			continue
		var d := Vector2(c.global_position.x - pos.x, c.global_position.z - pos.z).length()
		if d < best_d:
			best_d = d
			best = c
	return best

# ---------- 分组管理 ----------

func group_of(card: CardEntity):
	for g in groups:
		if g["cards"].has(card):
			return g
	return null

func _detach_from_group(card: CardEntity) -> void:
	var g: Variant = group_of(card)
	if not g:
		return
	g["cards"].erase(card)
	card.set_highlight(false)  # 拆出的卡清掉组高亮
	if g["cards"].is_empty():
		_remove_group(g)
	else:
		# 只剩一张就没有「摞」了：留着收拢标记，下次并卡会直接摞成一堆，
		# 而玩家并没有对这个新组合双击过
		if g["cards"].size() < 2:
			g["compact"] = false
		_layout_group(g)
		refresh_group(g)

func _nearest_group(pos: Vector3, exclude: Array):
	var best = null
	var best_d := MERGE_DIST
	for g in groups:
		if g["cards"].is_empty():
			continue
		var overlapping := false
		for c in exclude:
			if g["cards"].has(c):
				overlapping = true
		if overlapping:
			continue
		# 量到组内最近的一张卡（长条牌列中间也能放上去）
		for c in g["cards"]:
			var d := Vector2(c.global_position.x - pos.x, c.global_position.z - pos.z).length()
			if d < best_d:
				best_d = d
				best = g
	return best

## 结算后清理：移除已销毁的卡，删掉空组，刷新其余组的配方标签
func prune_groups() -> void:
	for g in groups.duplicate():
		for c in g["cards"].duplicate():
			if not is_instance_valid(c):
				g["cards"].erase(c)
		if g["cards"].is_empty():
			_remove_group(g)
		else:
			refresh_group(g)

## keep_progress：这一摞不是散了，只是整摞被拎到手上，牌的集合一张没变。
## 组字典从 groups 摘掉纯粹是记账（在手的牌不参与桌面上的组运算），
## 落桌时按原样重建，所以牌面的 have/need 该原样留着 —— 归 0 的话玩家看到的是
## 「金色凑满高亮还在，进度却写着 0/3」
func _remove_group(g, keep_progress := false) -> void:
	_clear_side(g)
	if not keep_progress:
		# 组散了，留在牌面上的进度数字就没有意义了，退回 0/N
		for c in g["cards"]:
			if is_instance_valid(c):
				reset_recipe_progress(c)
	groups.erase(g)

# ---------- 配方进度 ----------

## 组进度只写进核心卡右下角的配方墨团，由 CardEntity.set_recipe_progress 更新。
## 只写墨团，组顶不另挂填充进度条：那会是桌面上唯一一块不属于任何卡的悬浮物，
## 在摊开态压着牌列外的空桌面、在收拢态又得为了避开摞顶单独往镜头方向挪，
## 而它显示的 have/need 和核心卡右下角的墨团完全是同一个数
func _update_group_progress(g, eval: Dictionary) -> void:
	_push_recipe_progress(g, _group_progress(g), eval["valid"])
	_push_effect_mult(g)

## 把组里的翻倍 Buff 推到核心卡的 C 位效果格上。
##
## 倍数**不看 eval**：eval 对没凑满的组给 output_n=0，而玩家把 996 拖进来的
## 那一刻配方通常还没满，正是最需要看到「×2」的时刻。所以走
## ComboRules.effect_multipliers（只问「组里有没有那张 Buff」），
## 和 _group_progress 的 0/N 一起读才是完整的一句话：「凑满后产 2」
func _push_effect_mult(g) -> void:
	var data: Array = []
	for c in g["cards"]:
		data.append({ "uid": c.uid, "def_id": c.def_id })
	var mult: Dictionary = ComboRules.effect_multipliers(data)
	for c in g["cards"]:
		if not c.has_effect_badge():
			continue
		# 产出卡吃 output_x2、攻击卡吃 attack_x2，各认自己那一路：
		# 一个组里同时放 996 和热搜时，两张核心不该互相串台
		var k: String = CardDB.get_def(c.def_id).get("kind", "")
		if k == CardDB.KIND_PRODUCT:
			c.set_effect_mult(int(mult["output"]))
		elif k == CardDB.KIND_ATTACK:
			c.set_effect_mult(int(mult["attack"]))

# ---------- 收拢摞的侧边清单 ----------

## 收拢态只露得出最顶上一张，摞里有几张用户卡、几张现金卡、带没带 buff 全看不见了。
## 在摞的右侧竖排一列「图标 ×N」补上这份信息：图标用卡面同一套资源/buff 线稿
## （多语言化：不写「用户 3 张」这类中文），×N 用数字。摊开态不显示——那时候
## 每张卡自己的标题带都露着，清单纯属噪音
const SIDE_ICON := 0.30        # 图标边长（世界单位）：约卡宽的 1/4，和卡面 D 位墨团的图标一个量级
const SIDE_ROW_Z := 0.36       # 行距：留出图标外廓 + 一点呼吸
# 整列横向占地：图标 + 间隙 + 「×NN」两三个半角字（SIDE_TEXT_PIXEL×42 一字约 0.25）。
# 只用来算这一列盖住了谁（见 overlay_y），宁可估宽一点
const SIDE_W := 0.95
const SIDE_GAP := 0.16         # 摞右沿 → 图标左沿
const SIDE_Y := 0.42           # 离桌高度：压过收拢摞的最高一张（8 张 × 0.045 + 牌厚）
const SIDE_TEXT_PIXEL := 0.0060

## 一列清单最多几行，超出的折成一行「+N 种」。
##
## 为什么要有上限：这一列竖排，行数直接变成列高（rows × SIDE_ROW_Z），
## 而它以摞顶为**中心**上下摊开（见 _place_side）—— 行数一多就两头一起探。
## 最紧的一处是 AI 区的后行（摞心 z=-6.5）：北边是 AI 区北缘 -7.6，
## 南边是前行组合的北沿（AI_ROW_Z[0] -4.1 减半张卡 0.85 = -4.95）。
## 居中摊开时北边先吃紧 —— 列高得 ≤ 2×(7.6-6.5) = 2.2，也就是 6 行。
##
## 不封顶会探出去多少：卡表里资源 2 种、buff 5 种、核心 24 种，
## 一摞全占上就是 31 行、列高 11.16，两头各探出 5.58 —— 整张桌子都不够长。
## 拆掉这个封顶会被 tests/test_ai_pile.gd 那条「清单这一列留在后行带子里」抓住
## （变异表里有这一条）。
## buff 那几行原先也没上限，只是核心卡当时一行都不出、凑不到这个行数
const SIDE_MAX_ROWS := 6

## 一摞牌的侧边清单内容：[{tex, text}]，按用户 → 现金 → buff → 核心卡排。
## 只列非零项：一摞纯用户卡显示一行，不必挂两个「×0」
##
## 核心卡（产品/攻击/传奇）只在**同一摞里有两张以上**时才列。
## 一张的时候它就是露在摞顶那张，清单再说一遍是纯噪音 ——
## 组合摞正是这种（一张核心 + 一堆资源），那儿要的信息是「压着几张现金」。
## 两张以上就不一样了：摞顶只露得出其中一张，剩下的既看不见、又没有一行说得出
## （原先这个 match 根本不认核心卡，产品/攻击卡一行都不出）。
## 实测真实对局里 AI 备牌能攥到 7 种，而备牌席位只摆得下 5 摞，
## 多出来的会并成一摞（见 settle_layout 的 _merge_bench_overflow）——
## 那一摞不列核心的话，屏幕上就是「一张牌 + 什么提示都没有」，
## 正是报上来的「组合牌都摞在一块儿导致看不清」的最后一段
##
## 闸门数**张**不数种：这两个数只在「同名的核心卡不止一张」时才分岔，
## 而那正是报上来的「AI 合成了 2 张独角兽，下一回合只看到 1 张」。
## 备牌摞按 def_id 分摞（settle_layout 的 _ai_piles），两张独角兽必然同摞、
## 收拢后只露摞顶那张；原先按「种」判，1 种 → 核心一行都不出，
## 于是第二张既看不见、清单也不提 —— 屏幕上和「只合出一张」一模一样。
## 按张判则出一行「独角兽 ×2」，跟资源摞的 ×N 同一个口径
static func side_spec(cards: Array) -> Array:
	var n_user := 0
	var n_cash := 0
	var buffs: Array = []      # [def_id]，保持出现顺序
	var buff_n := {}
	var cores: Array = []      # [def_id]，保持出现顺序
	var core_n := {}
	for c in cards:
		if not is_instance_valid(c):
			continue
		var def: Dictionary = CardDB.get_def(c.def_id)
		match str(def.get("kind", "")):
			CardDB.KIND_UNIT:
				if def.get("res") == CardDB.RES_CASH:
					n_cash += 1
				else:
					n_user += 1
			CardDB.KIND_BUFF:
				if not buff_n.has(c.def_id):
					buffs.append(c.def_id)
					buff_n[c.def_id] = 0
				buff_n[c.def_id] += 1
			_:
				if not core_n.has(c.def_id):
					cores.append(c.def_id)
					core_n[c.def_id] = 0
				core_n[c.def_id] += 1
	var out: Array = []
	if n_user > 0:
		out.append({ "tex": CardArt.res_icon_texture(CardDB.RES_USER), "text": "×%d" % n_user })
	if n_cash > 0:
		out.append({ "tex": CardArt.res_icon_texture(CardDB.RES_CASH), "text": "×%d" % n_cash })
	# buff 卡按卡种分行：用它自己的图标（996 引擎和推送弹窗是两回事，
	# 合成一个「buff ×2」等于没说）
	for def_id in buffs:
		out.append({ "tex": CardArt.icon_texture(def_id), "text": "×%d" % buff_n[def_id] })
	var core_total := 0
	for def_id in cores:
		core_total += int(core_n[def_id])
	if core_total >= 2:
		for def_id in cores:
			out.append({ "tex": CardArt.icon_texture(def_id),
				"text": "×%d" % core_n[def_id] })
	# 封顶：留前 SIDE_MAX_ROWS-1 行，其余折成一行「还有几种」。
	# 折行只说数目、不借谁的图标 —— 借了就是拿一张卡的脸指代另外几张卡
	# （tex 给 null，_build_side 会只出数字那一半）。
	# 削的是**尾巴**，也就是核心卡那几行：资源和 buff 排在前面，
	# 它们是「摞顶那张看不出来」的信息，核心卡至少还露着其中一张
	if out.size() > SIDE_MAX_ROWS:
		var rest: int = out.size() - (SIDE_MAX_ROWS - 1)
		out = out.slice(0, SIDE_MAX_ROWS - 1)
		out.append({ "tex": null, "text": "+%d 种" % rest })
	return out

## 一摞牌在 z 向的跨度（最南那张 − 最北那张）。
##
## 联网同步拿它把「摞顶那张」换算成**整摞的中点**：摞顶在两种形态下坐的位置
## 不一样（摊开态最北、收拢态最南，见 main.gd 的 my_pile_lists），拿它当锚点
## 发出去，双击收拢会让摞在对手屏幕上平移半个摞长 —— 而收拢是原地的动作。
## 中点和形态无关，代价是发之前加半个跨度、收之后减回去
static func z_span(g) -> float:
	var n: int = g["cards"].size()
	if n < 2:
		return 0.0
	var lo := INF
	var hi := -INF
	for i in n:
		var z: float = _stack_offset_of(g, i).z
		lo = minf(lo, z)
		hi = maxf(hi, z)
	return hi - lo

## _stack_offset 的静态版（z_span 要在没有实例的地方也能算）
static func _stack_offset_of(g, i: int) -> Vector3:
	if g.get("compact", false):
		if g.has("bounded_compact_cap"):
			return capped_offset(g["cards"].size(), i, int(g["bounded_compact_cap"]))
		return compact_offset(g["cards"].size(), i)
	return Vector3(STACK_GAP.x * i, ladder_y(i), float(g.get("z_gap", STACK_GAP.z)) * i)

## 重建 / 摆放某组的侧边清单。收拢态才画，其余情况一律清掉
func _sync_side(g, at: Vector3, pin_y := false) -> void:
	if not g.get("compact", false) or g["cards"].size() < 2 or at == Vector3.INF:
		_clear_side(g)
		return
	var spec := side_spec(g["cards"])
	if spec.is_empty():
		_clear_side(g)
		return
	# 内容没变就只挪位置：refresh_group 在每次悬停进出、每次并卡时都会跑，
	# 每回重建节点会让这一列在拖拽途中闪
	var sig := ""
	for row in spec:
		sig += str(row["text"]) + "|"
	if g.get("side_sig", "") != sig:
		_clear_side(g)
		g["side"] = _build_side(self, spec)
		g["side_sig"] = sig
	_place_side(g["side"], spec.size(), at, pin_y)

## 造出清单节点：每行（图标 + ×N）。返回 [行 0 图标, 行 0 文字, 行 1 图标, ...]
##
## 不铺衬底：这一列贴着摞的右沿、落在空桌面上，衬底是块纯白硬边矩形，
## 桌面上就多出一块跟任何卡都不搭的白板。图标和数字自己带浅色描边就够托出来了
## （悬停说明那块衬底留着——它压在货架卡的线条上，不垫会两层黑线糊成一团）
static func _build_side(parent: Node3D, spec: Array) -> Array:
	var out: Array = []
	for row in spec:
		# 图标可能缺素材（icon_ 那张没生成）：那一行只剩数字，不留空位
		var ic: Sprite3D = null
		var tex: Texture2D = row["tex"]
		if tex:
			ic = Sprite3D.new()
			ic.texture = tex
			ic.pixel_size = SIDE_ICON / float(tex.get_width())
			ic.modulate = Color(0.16, 0.14, 0.12)
			ic.rotation_degrees = Vector3(-90, 0, 0)
			ic.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			ic.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
			parent.add_child(ic)
		out.append(ic)
		var lb := Label3D.new()
		lb.text = str(row["text"])
		# 「×7」等清单计数使用常规字重，保留小尺寸下的笔画间隙。
		lb.font = Fonts.zh()
		lb.font_size = 42
		lb.pixel_size = SIDE_TEXT_PIXEL
		lb.modulate = Color(0.16, 0.14, 0.12)
		# 去掉衬底后字直接落在桌布上：留一圈浅色描边把它从桌面纹理里托出来。
		# 描边大小为字号的 4/42 ≈ 9.5%，让浅色外沿与深色字形保持区分。
		lb.outline_size = 4
		lb.outline_modulate = Color(0.96, 0.97, 0.90, 0.85)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lb.autowrap_mode = TextServer.AUTOWRAP_OFF
		lb.rotation_degrees = Vector3(-90, 0, 0)
		parent.add_child(lb)
		out.append(lb)
	return out

## 摆放清单：整列以 at（摞顶）为锚，贴在摞的右侧、竖向居中
##
## 不能是 static：高度要按「这一列盖住了谁」算（见 overlay_y），得读全场卡。
## 写死 SIDE_Y=0.42 不行 —— 这一列贴在摞右沿 +0.76 处、整条宽约 SIDE_W，
## 结算带列距只有 PILE_SLOT_X_STEP=1.4，所以它必然探进**邻列**的占地里，
## 邻列被抬到 1.8 的时候 0.42 的清单就埋在人家牌底下了
## pin_y —— 高度只按 at 算，不扫周围的卡。调用方已经知道这条清单要盖住谁，
##   而 overlay_y 读的是**实时**坐标：一批牌正飞着的时候（开局发牌、结算产出），
##   路过头顶的那张会把清单顶到它半路的高度上，落地之后没人再把它放回来
##   （resync_sides 只走 board.groups，AI 那几摞不在里面）。
##   实测：AI 现金摞的 ×20 被顶到 y=4.45，投出去就在屏幕外
func _place_side(nodes: Array, rows: int, at: Vector3, pin_y := false) -> void:
	if nodes.is_empty():
		return
	var left: float = at.x + CardEntity.CARD_SIZE.x / 2.0 + SIDE_GAP
	var col_h: float = rows * SIDE_ROW_Z
	var mid_z: float = at.z
	if has_table_bounds(table_bounds):
		if left + SIDE_W > table_bounds.end.x - BOUNDS_PAD:
			left = at.x - CardEntity.CARD_SIZE.x / 2.0 - SIDE_GAP - SIDE_W
		left = clampf(left, table_bounds.position.x + BOUNDS_PAD,
			maxf(table_bounds.position.x + BOUNDS_PAD, table_bounds.end.x - SIDE_W - BOUNDS_PAD))
		mid_z = clampf(mid_z, table_bounds.position.y + col_h / 2.0 + BOUNDS_PAD,
			maxf(table_bounds.position.y + col_h / 2.0 + BOUNDS_PAD,
				table_bounds.end.y - col_h / 2.0 - BOUNDS_PAD))
	var z0: float = mid_z - col_h / 2.0 + SIDE_ROW_Z / 2.0
	var text_x: float = left + SIDE_ICON + 0.06
	var floor_y: float = maxf(SIDE_Y, at.y + ladder_y(1))
	var y: float = floor_y if pin_y else overlay_y(
		Vector3(left + SIDE_W / 2.0, 0.0, mid_z), Vector2(SIDE_W, col_h), floor_y)
	# overlay_y 返回的是卡根节点之上的一级台阶；只有确实检测到较高的
	# 邻牌时才再让清单越过卡面元素，避免空桌上的清单被无意义地抬到半空。
	# 外部固定席位（pin_y）由结算布局保证不压邻列，不改变它原有的基准高度。
	if not pin_y and y > floor_y + 0.0001:
		y += CardEntity.Y_OVERLAY
	for i in rows:
		var z: float = z0 + i * SIDE_ROW_Z
		var ic: Variant = nodes[i * 2]
		if ic != null and is_instance_valid(ic):
			ic.global_position = Vector3(left + SIDE_ICON / 2.0, y, z)
		var lb: Label3D = nodes[1 + i * 2]
		lb.global_position = Vector3(text_x, y, z)

func _clear_side(g) -> void:
	for n in g.get("side", []):
		if n != null and is_instance_valid(n):
			n.queue_free()
	g["side"] = []
	g["side_sig"] = ""

## 给不属于 board.groups 的摞挂侧边清单（AI 的组合与理牌摞在 state.combos 里，
## 不进 board.groups，但它们同样是收拢摞、同样需要这份清单）。
## key = 调用方自己的标识，同一个 key 反复调用只会更新不会堆积节点
var _ext_side := {}

## at 是摞顶那张的**目标**位置（调用方给的，不是实时坐标）。高度也按它钉死：
## 这几摞各占一个固定席位、互相不叠，用不着扫周围；而扫的话读到的是
## 正飞着的牌（开局发牌、结算产出），清单会被顶到半空里（见 _place_side 的 pin_y）
func show_side_badges(key: String, cards: Array, at: Vector3) -> void:
	if not _ext_side.has(key):
		_ext_side[key] = { "cards": [], "compact": true, "side": [], "side_sig": "" }
	var g: Dictionary = _ext_side[key]
	g["cards"] = cards
	_sync_side(g, at, true)

## 某个 key 那一列清单的节点（[图标, 文字, 图标, 文字, ...]，图标可能是 null）。
## 判据要量「这一列占了哪块地」，而量的得是真节点 —— 拿行数乘节距算等于
## 把 _place_side 的算式抄第二遍（memory: green-suite-cant-prove-mapping）
func side_nodes_of(key: String) -> Array:
	return _ext_side.get(key, {}).get("side", [])

## 清掉某个 key 的清单；key 省略 = 清掉全部（AI 重排前先全清，避免上一轮的残留）
func clear_side_badges(key := "") -> void:
	if key != "":
		if _ext_side.has(key):
			_clear_side(_ext_side[key])
			_ext_side.erase(key)
		return
	for k in _ext_side.keys():
		_clear_side(_ext_side[k])
	_ext_side.clear()

## 把组进度写进组内每张有配方的卡的 D 位墨团。
## 组里通常只有一张核心卡，但拖错也可能出现两张——各自都按这一组的进度显示，
## 不然会留着上一组的旧数字
func _push_recipe_progress(g, info: Dictionary, done: bool) -> void:
	for c in g["cards"]:
		if c.has_recipe_badge():
			c.set_recipe_progress(int(info["have"]), done)

## 单卡离组/组解散后把 D 位墨团退回 0/N，否则旧进度会一直挂在牌面上。
## C 位的翻倍一并还原：核心卡从带 996 的组里被拎出来之后还写着 +2，
## 那个数就不再对应任何一组牌了（和进度停在 3/3 是同一种残留）
static func reset_recipe_progress(c: CardEntity) -> void:
	if c.has_recipe_badge():
		c.set_recipe_progress(0, false)
	if c.has_effect_badge():
		c.set_effect_mult(1)

## 组内配方进度：返回 {have, need}；无配方核心返回 need=0
func _group_progress(g) -> Dictionary:
	for c in g["cards"]:
		var def: Dictionary = CardDB.get_def(c.def_id)
		if def.get("kind") in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK]:
			var need: int = def.get("recipe_n", 0)
			var res: String = def.get("recipe_res", "")
			if need == 0:
				continue
			var have := 0
			var fill := false   # 裂变鬼才：有一张就算配方满（只对用户配方）
			for c2 in g["cards"]:
				var d2: Dictionary = CardDB.get_def(c2.def_id)
				if d2.get("kind") == CardDB.KIND_UNIT and d2.get("res") == res:
					have += 1
				elif d2.get("buff_type", "") == "user_fill" and res == CardDB.RES_USER:
					fill = true
			# 墨点进度必须和 ComboRules._fission_fills 同判据，
			# 否则会出现「墨点 1/7、引擎认为已满」
			if fill and have >= 1:
				have = need
			return { "have": have, "need": need }
	return { "have": 0, "need": 0 }

## origin = 组起点（这一摞第 0 层落在哪）。INF = 按队首那张的现位置反推。
## 双击切换形态必须显式传：那条路径会先 _core_first 把核心卡换到队首，
## 反推就成了「按另一张牌的位置重新定位整摞」，一摞牌会跟着来回跳
func _layout_group(g, origin := Vector3.INF) -> bool:  # 返回: 这次重排是否刚凑满配方
	# 传入明确起点时保留它的 y：结算/理牌可能把整摞抬到其它牌上，
	# 点击后原地松手的复位也必须回到同一个高度。只有没有起点的普通落桌
	# 才回到桌面静止高度，避免拖拽高度泄漏到新组。
	var explicit_origin := origin != Vector3.INF
	var base: Vector3 = origin
	if base == Vector3.INF:
		base = _group_origin(g)
	if not explicit_origin:
		base.y = 0.05   # 贴桌静止高度（桌面碰撞顶 0 + 牌碰撞半高）
	# 成员减少或恢复旧布局后，反推起点可能低于桌面。显式起点可保留
	# 其它牌上的支撑高度，但不能让冻结的整摞停在桌布下面。
	base.y = maxf(base.y, 0.05)
	var n: int = g["cards"].size()
	if has_table_bounds(player_bounds):
		# 窄窗只收紧牌与牌之间的露出量，绝不缩放卡面；收拢摞的高度也有上限。
		var available := maxf(0.0, player_bounds.size.y - CardEntity.CARD_SIZE.z - BOUNDS_PAD * 2.0)
		g["z_gap"] = minf(STACK_GAP.z, available / maxf(n - 1, 1))
		g["bounded_compact_cap"] = mini(BOUNDED_COMPACT_LAYERS,
			maxi(1, int(floor(available / COMPACT_GAP.z)) + 1))
	else:
		g.erase("z_gap")
		g.erase("bounded_compact_cap")
	var offsets: Array = []
	for i in n:
		offsets.append(_stack_offset(g, i))
	base = clamp_player_position(base, offsets)
	for i in n:
		var c: CardEntity = g["cards"][i]
		c.freeze = true
		_move_to(c, base + _stack_offset(g, i))
	# 进度条按「重排后最上面那张的位置」定位：此刻 tween 还没跑完，
	# 读实时坐标会把进度条留在鼠标松手的地方
	return refresh_group(g, base + _stack_offset(g, _top_index(g)))

## 组起点 = 队首那张的**静止**位置减掉它自己的层间偏移。
## 两处坑：
## 1) 收拢态队首（核心卡）的偏移不是 0（它在摞顶，z 偏移最大，见 compact_offset），
##    直接拿它的坐标当起点，等于每次重排都把整摞往 +z 推 COMPACT_GAP.z*(n-1)——
##    「单击把摞好的组合拎起来原地放下」就会看着往近边挪一截，反复几次越挪越远。
##    摊开态队首偏移本来是 0，减掉不影响。
## 2) 队首可能正被上一次重排的 0.18s 补间往它的新槽位送，此刻读到的是飞行中的
##    中间值。先 _stop_move 按到补间终点，拿到的才是这张牌真正该在的地方
func _group_origin(g) -> Vector3:
	_stop_move(g["cards"][0])
	return g["cards"][0].global_position - _stack_offset(g, 0)

## 归位补间：每张卡同时只允许一条。双击收拢的补间要跑 0.18s，
## 玩家完全可能在这 0.18s 里就把牌拎起来——旧补间还在写 global_position，
## 会跟 _process 的拖拽定位对着写，牌在手上一路往桌面沉
var _move_tw := {}

func _move_to(c: CardEntity, to: Vector3) -> void:
	_stop_move(c, false)
	# 保持原有理牌速度与回弹节奏；穿模由浮层高度和深度测试处理。
	var tw := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(c, "global_position", to, 0.18)
	_move_tw[c] = { "tw": tw, "to": to }

## 掐掉某张卡在飞的归位补间。snap = 顺手把它按到补间的终点：
## 拎牌时要 snap，否则读到的层间偏移是补间半路上的中间值——
## 收拢/摊开的 y 顺序正好相反，半路上的 y 谁高谁低是说不清的。
## 只有补间**还在跑**才 snap：_move_tw 里的记录不会随补间自然结束而清掉，
## 跑完的那条留着一个早就作废的终点，照着它 snap 等于把牌传送回上一次的槽位
## （结算/理牌挪过位置的牌尤其明显：会被拽回上一轮的堆）
func _stop_move(c: CardEntity, snap := true) -> void:
	# 先掐**别人**那条（买卡飞入 / 理牌搬运 / 产出飞入，见 cancel_anim）。
	# 放在下面那个 early return 之前：只被别处搬着、_move_tw 里没有记录的牌
	# 才是「组合卡消失」的那一张，从那儿返回就等于这个口子不存在。
	# snap 的规矩和本文件的补间一致 —— 按到它**本来要去的地方**，
	# 那个坐标记在 dest_pos 上，得在掐之前读（_cancel_fly 会顺手撤掉它）
	if cancel_anim.is_valid() and is_instance_valid(c):
		var away: Variant = c.get_meta("dest_pos") if c.has_meta("dest_pos") else null
		cancel_anim.call(c)
		if snap and away != null and c.is_inside_tree():
			c.global_position = away
	var rec: Variant = _move_tw.get(c)
	if rec == null:
		return
	var live: bool = rec["tw"] != null and is_instance_valid(rec["tw"]) and rec["tw"].is_running()
	if live:
		rec["tw"].kill()
		if snap and is_instance_valid(c) and c.is_inside_tree():
			c.global_position = rec["to"]
	_move_tw.erase(c)

## 某张卡的**静止**位置：有声明落点就读落点，否则返回现位置。
## main 的购牌/产出补间登记在 dest_pos，Board 的编组补间登记在 _move_tw；
## 两条路径都必须识别，否则飞牌经过侧边清单时会把清单顶到半空。
##
## 和 _stop_move(c) 的区别是这一条只读、不掐补间。量别人的高度时必须只读：
## 掐掉一张正在飞的卡等于把它传送到终点，而它可能正被 _settle_pile_heights 挪着，
## 抬升演出就没了。_group_origin 那条要 snap 是因为它量的是自己队首那张
func rest_pos(c: CardEntity) -> Vector3:
	if c.has_meta("dest_pos"):
		return c.get_meta("dest_pos")
	var rec: Variant = _move_tw.get(c)
	if rec != null and rec["tw"] != null and is_instance_valid(rec["tw"]) \
			and rec["tw"].is_running():
		return rec["to"]
	return c.global_position

## _group_origin 的只读版本：不掐队首那张的补间。
## 量**别人**那一组的位置时必须用这个 —— _group_origin 会 _stop_move 把队首
## 按到终点，而那一组可能正被抬升/重排的补间送着，掐了就只有队首一张原地传送
func rest_origin(g) -> Vector3:
	return rest_pos(g["cards"][0]) - _stack_offset(g, 0)

## 平铺在桌面上的浮层（侧边清单、悬停说明）该落多高。
##
## 全场只有这两样东西不属于任何卡，其余元素的高度都是「相对自己所属的结构」。
## 所以它们的高度不能是写死的绝对值（SIDE_Y=0.42 按「八张收拢摞」算，
## DESC_Y=0.32 按「一摞满份的摊开堆」算）：结算带挤起来之后整摞会被抬到别的结构上面
## （见 main._settle_pile_heights），实测顶面能到 y=1.8，两个绝对值全埋在牌底下
## （摞#12 顶 y=1.784，清单还在 0.455；连贴桌的满份摞顶面 0.455
## 都和 SIDE_Y 只差 0.000，照 FACE_SPAN_Y 的规矩就已经算穿）。
##
## 归到和卡与卡之间同一条规矩上：**盖住谁就落在谁上面一级台阶**。
## floor_y 是下限（空桌面上按老值走，观感不变），不递归、不累积。
##
## 浮层没有厚度、也不参与占地避让，所以只量「谁落在我的矩形里、比我高」。
## 手上经过的牌不是已落桌的障碍：吸附高亮退出会刷新原摞，若把手牌也算进去，
## 清单会跳到 DRAG_HEIGHT 上并滞留在那里；真实相邻高摞仍按静止落点避让。
func overlay_y(mid: Vector3, size: Vector2, floor_y: float) -> float:
	var y: float = floor_y
	for c in cards:
		if not is_instance_valid(c) or c.dragging:
			continue
		var p: Vector3 = rest_pos(c)
		if absf(p.x - mid.x) >= size.x / 2.0 + CardEntity.CARD_SIZE.x / 2.0 \
				or absf(p.z - mid.z) >= size.y / 2.0 + CardEntity.CARD_SIZE.z / 2.0:
			continue
		y = maxf(y, p.y + ladder_y(1))
	return y

## 把所有收拢摞的侧边清单按**当前静止位置**重摆一遍。
##
## 为什么要单独来一趟：清单的高度是「盖住谁就落在谁上面」（见 overlay_y），
## 而它只在自己这一组重排时摆一次。结算带是一摞一摞挨着摆的，前一摞的清单
## 摆下时，后面那摞还没摆、更没被抬起来 —— 等它抬到 y=1.8，先摆那条清单
## 就埋在人家牌底下了（实测 摞#6 清单 0.479 被邻列 1.805 压着）。
## 一批摆完之后统一重摆，读到的就是全部落定后的高度。
##
## 单趟就够、不用反复迭代：清单本身不进 cards，overlay_y 只量卡，
## 所以抬高一条清单不会反过来埋掉另一条
func resync_sides() -> void:
	for g in groups:
		if g["cards"].size() < 2 or not bool(g.get("compact", false)):
			continue
		var top: CardEntity = g["cards"][_top_index(g)]
		if not is_instance_valid(top):
			continue
		# 只读的 rest_pos，不用 _group_origin：后者会 _stop_move 掐掉队首那张的
		# 补间，而整摞可能正被 _settle_pile_heights 挪着，掐了就只有它一张原地传送上去
		_sync_side(g, rest_pos(top))

## 组内第 i 张相对组起点的位置偏移。
## 摊开态：沿 z 铺开，每张露出一条标题带。
## 收拢态：几乎只沿 y 摞高，且顺序反过来——index 0（核心卡）要在最顶上，
## 而 y 越大越靠上、越晚画，所以 index 0 拿最大的 y
func _stack_offset(g, i: int) -> Vector3:
	return _stack_offset_of(g, i)

## 收拢态里第 i 张（共 n 张）的偏移。AI 侧的摞不进 board.groups，
## 自己摆位置时要用同一份偏移，否则两边的「一摞」看起来不是一回事
static func compact_offset(n: int, i: int) -> Vector3:
	return COMPACT_GAP * (n - 1 - i)

## 同 compact_offset，但台阶最多只长 cap 级：**摞的占地不随张数无限长**。
##
## 为什么要有上限：compact_offset 每张给一级台阶，一摞的跨度就是
## COMPACT_GAP × (n-1)，n 上没有任何约束。实测 AI 后行那摞现金：
## 40 张 z 跨 1.95 已经压进前行，100 张（= 胜利线 _game.win_cash）
## 爬到 y=4.5、南缘 -1.40 盖在货架牌上，240 张摞顶投到屏幕外。
## 一摞牌的意思是「一类东西收成一个对象」，它该有一个固定的占地。
##
## 超出 cap 的那几张停在**最底那一级**（rank 0，最靠北、最低的那一级）：
## 它们和那一级本来那张完全重合，y 差为 0 —— 这是故意的，代价见
## tests/test_tidy.gd 第 3 节（防穿模那条不变量为此开了一个口子，只对
## 「同一摞、收拢态、摞内次序 ≥ cap-1」的那些放行，且落地必须是真重合或真分开）。
## 张数一张不少地写在侧边清单里
## （side_spec 数的是真牌），点摞攻击也照旧整摞啃（main._attack_pile 按 key 取靶，
## 跟看不看得见无关），所以「多出来的牌看不出是几张」这件事有替代出口。
##
## 队序不变：index 0 仍然拿最高、最南那一级（摞顶那张，唯一完整露出来的）。
## 重合的是队尾那些 —— 摞底本来就只露出一条边
static func capped_offset(n: int, i: int, cap: int) -> Vector3:
	var rungs: int = mini(n, maxi(cap, 1))
	return COMPACT_GAP * maxi(rungs - 1 - i, 0)

## 一叠占地重叠的牌里，从远到近第 rank 张该抬多高（相对最远那张）。
##
## 桌上任何两张占地重叠的卡，y 差都必须大于 CardEntity.FACE_SPAN_Y，
## 否则下面那张的图标/卡名比上面那张的底板还高，从底板里穿出来（穿模）。
## 摊开组靠 _stack_offset 的 STACK_GAP.y 满足这条；结算余数那种「z 不规整、
## 但一列里前后仍然重叠」的摆法没法用 STACK_GAP*i（z 是逐格避让挑出来的，
## 不是等距），所以把台阶单独开成一个接口 —— 高度只有这一个出处，
## 摊开组和余数用的是同一个台阶高，不会一边改了另一边忘了
static func ladder_y(rank: int) -> float:
	return STACK_GAP.y * rank

## 视觉上最上面那张卡的 index（进度条挂在它头顶）。
## 摊开态是队尾（最靠近镜头、露得最全），收拢态是队首（摞在最顶上）
static func _top_index(g) -> int:
	return 0 if g.get("compact", false) else g["cards"].size() - 1

func _set_group_highlight(g, on: bool, color := Color(1.2, 1.2, 0.6)) -> void:
	for c in g["cards"]:
		if is_instance_valid(c):
			c.set_highlight(on, color)

# ---------- 配方进度标签 ----------

## top_pos = 摞顶卡的目标位置；INF 时同样读取静止落点，避免悬停刷新把清单
## 从已确定的新位置拉回归位补间的中途坐标。
func refresh_group(g, top_pos := Vector3.INF) -> bool:  # 返回: 这次更新是否刚凑满配方
	var top_at: Vector3 = top_pos
	if top_at == Vector3.INF and not g["cards"].is_empty() \
		and is_instance_valid(g["cards"][_top_index(g)]):
		top_at = rest_pos(g["cards"][_top_index(g)])
	# 侧边清单放在所有提前返回之前：收拢态把牌面全遮住了，
	# 纯资源摞（8 张用户卡，没有核心卡）恰恰是最需要「×8」这一行的情形
	_sync_side(g, top_at)
	if g["cards"].size() < 2:
		# 金光也要在这里灭。少这一行时，从**同名升级组**里抽走一张的那张会一直亮着：
		# 升级组 2 张就成立（upgrade_dup_n 最小 2），配方组最少要 3 张
		# （recipe_n 最小 2 再加核心），所以只有同名组会走「2 张亮着 → 1 张」
		# 这个跳过清理的转换。配方组降到 1 张前必先经过 2 张那一档，
		# 在下面那条 is_valid=false 的路上就已经灭了，症状因此只在同名组上看得见
		_set_group_highlight(g, false)
		g["was_valid"] = false
		# 这两条提前返回都不会走到 _update_group_progress，D 位得在这里自己退回 0/N
		for c in g["cards"]:
			reset_recipe_progress(c)
		return false
	# 无核心卡（纯资源摞/整理摞）：没有配方可言，不写进度
	var has_core := false
	for c in g["cards"]:
		var k: String = CardDB.get_def(c.def_id).get("kind", "")
		if k in [CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK, CardDB.KIND_LEGEND]:
			has_core = true
			break
	if not has_core:
		_set_group_highlight(g, false)
		g["was_valid"] = false
		for c in g["cards"]:
			reset_recipe_progress(c)
		return false
	var data: Array = []
	for c in g["cards"]:
		data.append({ "uid": c.uid, "def_id": c.def_id })
	var eval := ComboRules.evaluate(data)

	# 配方凑满：整条牌列金色高亮；首次凑满时发信号（音效提示）
	var is_valid: bool = eval["valid"]
	_set_group_highlight(g, is_valid, Color(1.55, 1.3, 0.45))
	var just_completed: bool = is_valid and not g.get("was_valid", false)
	# _pickup_quiet：拎牌途中的凑满不当场报，压到落手时结算（见 _commit_pickup_ding）
	if just_completed and not _pickup_quiet:
		group_completed.emit()
		group_formed.emit(g["cards"].duplicate())
	g["was_valid"] = is_valid

	# 进度只写进卡面 D 位墨团。组上方既不悬浮大字（和牌面重复、挡后排牌列），
	# 也不挂填充进度条（见 _update_group_progress）
	_update_group_progress(g, eval)
	return just_completed

# ---------- 工具 ----------

func _mouse_table_point() -> Vector3:
	if not camera:
		return Vector3.INF
	var mouse := pointer_position()
	var origin := camera.project_ray_origin(mouse)
	var normal := camera.project_ray_normal(mouse)
	if absf(normal.y) < 0.001:
		return Vector3.INF
	var t := (DRAG_HEIGHT - origin.y) / normal.y
	if t < 0:
		return Vector3.INF
	return origin + normal * t

## 一组卡（Array[CardEntity]）当前是否凑满配方。少于两张一律不成立
func _cards_valid(group_cards: Array) -> bool:
	if group_cards.size() < 2:
		return false
	var data: Array = []
	for c in group_cards:
		if not is_instance_valid(c):
			return false
		data.append({ "uid": c.uid, "def_id": c.def_id })
	return bool(ComboRules.evaluate(data)["valid"])

## g 是不是这次拎牌留在桌上的那半截（比对对象身份：
## Dictionary 的 == 是逐键深比较，两个内容一样的组会被判成同一个）
func _is_drag_src(g) -> bool:
	return _drag_src_group != null and is_same(g, _drag_src_group)

## 牌放回源组前，把它的凑满基线还原成「抽走那几张之前」的值。
## 少了这一步：从一组凑满的牌里按住子集再松手，源组先被刷成不成立、
## 放回去又变成立，refresh_group 就当成一次新凑满多响一声风铃，
## 而玩家这个动作前后组合结果根本没变
func _restore_src_baseline(g) -> void:
	if _is_drag_src(g):
		g["was_valid"] = _drag_src_valid

## 结算拎牌时被压住的那一声：抽走几张让留在桌上的半截反而凑满了，
## 且落手后它确实还是凑满的（牌没放回去），这才补报一次
func _commit_pickup_ding() -> void:
	var g: Variant = _drag_src_group
	_drag_src_group = null
	if g == null or _drag_src_valid:
		return
	var alive := false
	for gg in groups:
		if is_same(gg, g):
			alive = true
			break
	if alive and bool(g.get("was_valid", false)):
		group_completed.emit()
		group_formed.emit(g["cards"].duplicate())

## 新建组 dict。was_valid = 凑满基线，默认按当前牌面预评估——
## 整体挪动/退回一组已经凑满的牌时，不会因为组对象重建而重复报"凑满"。
## 拖拽落手那几条路径要显式传 _drag_hand_valid（手上这摞拎起来时是否已凑满）：
## 按最终牌面预评估会把「两张同名 T2 从散卡并成升级组」这种真凑满也一并吞掉
func make_group(group_cards: Array, compact := false, was_valid: Variant = null) -> Dictionary:
	# compact = 收拢态（双击切换，见 toggle_compact）。默认摊开：
	# 只有「整摞收拢态被拎起来又落回桌面」才传 true（见 _end_drag），
	# 这样双击的效果能撑过一次拖拽，直到玩家再双击一下
	var g := { "cards": group_cards, "was_valid": false, "compact": compact,
		"side": [], "side_sig": "" }
	if compact:
		_core_first(g)   # 收拢态只露摞顶，核心卡得在最上面
	if was_valid != null:
		g["was_valid"] = bool(was_valid)
	else:
		g["was_valid"] = _cards_valid(g["cards"])
	return g

# ---------- 双击收拢/摊开 ----------

## 双击组里任意一张卡：在「摊开」和「收拢」之间切换。
## 摊开态每张卡沿 z 露出一条标题带，一列 8 张要占掉三张卡长的桌面；
## 收拢态改为沿高度摞起来，占地缩到单张卡的大小，代价是只看得见最顶上那张。
## 返回是否真的切换了（单张卡没有「摞」可言，直接拒掉）
func toggle_compact(card: CardEntity) -> bool:
	if card == null or not is_instance_valid(card) or card.is_market or not card.draggable:
		return false
	var g: Variant = group_of(card)
	if g == null or g["cards"].size() < 2:
		return false
	# 起点必须在「翻 compact 标志」和「_core_first 换队首」之前算：
	# 这两步都会改变队首那张牌该有的偏移，之后再反推就是拿另一张牌的位置
	# 重新定位整摞，来回双击会让这摞牌一路往 +z 爬（见 _group_origin）
	var origin := _group_origin(g)
	g["compact"] = not g.get("compact", false)
	# 收拢时把核心卡提到队首：收拢态只有最顶上那张露脸，
	# 露的要是「刷不停」而不是随便一张用户卡，否则这摞牌看不出是在做什么
	if g["compact"]:
		_core_first(g)
	_layout_group(g, origin)
	pile_toggled.emit()   # 咔哒一声，凑满与否与这次操作无关
	return true

## 把核心卡（产出/攻击/传奇）挪到队首、Buff 紧随其后，材料留在后面。
## 只在收拢时调用：摊开态队首是露得最少的那张，把核心卡挪过去反而看不清
func _core_first(g) -> void:
	g["cards"] = core_first_order(g["cards"])

## 核心 → buff → 材料 的排序（AI 侧摆摞时复用；那边的卡不进 board.groups）
static func core_first_order(cards: Array) -> Array:
	var core: Array = []
	var buffs: Array = []
	var rest: Array = []
	for c in cards:
		if not is_instance_valid(c):
			continue
		match str(CardDB.get_def(c.def_id).get("kind", "")):
			CardDB.KIND_PRODUCT, CardDB.KIND_ATTACK, CardDB.KIND_LEGEND:
				core.append(c)
			CardDB.KIND_BUFF:
				buffs.append(c)
			_:
				rest.append(c)
	return core + buffs + rest

## 尝试把一张卡与附近的卡合并（附近的组优先，其次是散卡——两张散卡也能组起来）
## 返回 { merged: 是否并入某组/成组, completed: 这次合并是否刚凑满配方 }
func try_merge(card: CardEntity) -> Dictionary:
	if group_of(card) != null:
		return { "merged": true, "completed": false }
	var g: Variant = _nearest_group(card.global_position, [card])
	if g:
		var target_origin := _group_origin(g)
		g["cards"].append(card)
		if g.get("compact", false):
			_core_first(g)   # 见 _end_drag：并进收拢摞的牌落在摞底，核心卡要提回摞顶
		# 这张牌放回刚把它抽走的那一组：还原基线，前后结果没变就不响
		_restore_src_baseline(g)
		var done: bool = _layout_group(g, target_origin)
		return { "merged": true, "completed": done }
	var best: CardEntity = _nearest_loose_card(card.global_position, [card])
	if best:
		# 基线 false：两张散卡并成一个立刻成立的组合（同名 T2×2 之类）是真凑满，要响。
		# 走 make_group 的预评估会吞掉这一声：新组一建出来 was_valid 就是 true
		_stop_move(best)
		var target_origin := best.global_position
		var ng := make_group([best, card], false, false)
		groups.append(ng)
		var done2: bool = _layout_group(ng, target_origin)
		return { "merged": true, "completed": done2 }
	return { "merged": false, "completed": false }
