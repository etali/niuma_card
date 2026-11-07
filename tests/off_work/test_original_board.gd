extends SceneTree

var checks := 0
var errors: Array[String] = []
var board: OffWorkBoard
var state: OffWorkState

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee": 1, "work": 6}, {"employee": 1, "work": 3}, {"overtime": 1}]
	config.rules.initial.money = 16
	config.rules.bot.enabled = false
	state = OffWorkState.new(config)
	state.new_game(57)
	OffWorkCardDB.configure(config)
	var host := Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	board = OffWorkBoard.new()
	host.add_child(board)
	board.setup(camera, true)
	_check(board.get_script().get_base_script() == preload("res://scenes/board.gd"),
		"实时桌面继承原 Board 的拖拽与摞管理")
	var regions := preload("res://scenes/table_regions.gd")
	var slots: int = config.rules.conveyor.slots
	_check(board.pawn_pos == regions.facility_position(slots, true)
		and board.player_bounds == regions.zone_rect(true, true, slots)
		and board.enemy_board.player_bounds == regions.zone_rect(false, true, slots), "原区域驱动双方边界与设施落点")
	board.set_process(false)
	board.sync_state(state)
	await _settle()
	var employee: int = state.group_people(1)[0]
	var motion := preload("res://scenes/card_motion.gd").new()
	host.add_child(motion)
	board.bind_motion(motion)
	motion.bind(board, null)
	var moving: OffWorkCard = board.by_uid[employee]
	var flight := motion._move_to(moving, moving.position + Vector3.RIGHT, 1.0)
	board.cancel_anim.call(moving)
	_check(not flight.is_valid() and not moving.has_meta("dest_pos") and not moving.has_meta("fly_tw"),
		"原卡牌运动的飞行可由桌面拖拽取消并清理目的地")
	board.bind_motion(null)
	var first: Dictionary = board.group_of(board.by_uid[employee])
	_check(first.cards.size() == 7, "原视觉摞对应真实组全部成员")
	_check(board.cards is Array, "继承原cards数组而非覆盖为字典")
	_check(board.enemy_board.groups.size() == state.groups.values().filter(func(group): return group.owner == 1 and group.cards.size() > 1).size(), "对方也用原Board摞")
	var origin := board.rest_origin(first)
	board.toggle_compact(first.cards[0])
	await _settle()
	_check(not first.compact, "原双击函数展开")
	_check(absf(board.rest_origin(first).x - origin.x) < 0.001, "原边界适配只沿摞方向夹回，不横向漂移")
	var members: Array = first.cards.duplicate()
	var wanted: Array = members.slice(3).map(func(c): return c.uid)
	board._on_card_clicked(members[3])
	_check(board._drag_cards.map(func(c): return c.uid) == wanted, "原中段拖走后半摞")
	_move_hand(Vector3(4.8, Board.DRAG_HEIGHT, 4.0))
	board._end_drag()
	await _settle()
	var split: int = state.cards[wanted[0]].group
	_check(split != 1, "真实规则拆组")
	_check(_same(state.group_cards(split), wanted), "真实拆出的成员等于原Board后半摞")
	_check(state.group_cards(1).size() == 3, "源组留下前半摞")
	var split_view: Dictionary = board.group_of(board.by_uid[wanted[0]])
	board._on_card_clicked(split_view.cards[0])
	var target_view: Dictionary = board.group_of(board.by_uid[employee])
	# 吸附按屏幕上可见牌面命中，抬起的牌应沿相机射线对齐，不能只增加世界 Y。
	var target_screen := camera.unproject_position(target_view.cards[board._top_index(target_view)].global_position)
	var ray_origin := camera.project_ray_origin(target_screen)
	var ray_direction := camera.project_ray_normal(target_screen)
	_move_hand(ray_origin + ray_direction * ((Board.DRAG_HEIGHT - ray_origin.y) / ray_direction.y))
	board._end_drag()
	await _settle()
	_check(state.group_cards(1).size() == 7, "原吸附合组进入真实规则")
	first = board.group_of(board.by_uid[employee])
	if not first.compact: board.toggle_compact(first.cards[0])
	await _settle()
	state.advance(2.0)
	board.sync_state(state)
	var task_before: Dictionary = state.tasks[employee].duplicate(true)
	board._on_card_clicked(first.cards[0])
	_check(board._drag_cards.size() == 7, "收拢后抓整摞")
	_move_hand(Vector3(7.5, Board.DRAG_HEIGHT, 4.0))
	board._end_drag()
	await _settle()
	_check(state.cards[employee].group == 1, "整摞移动保留真实组ID")
	_check(state.tasks[employee] == task_before, "整摞移动保留实际任务和进度")
	first = board.group_of(board.by_uid[employee])
	_check(first.compact, "移动后保留收拢形态")
	var positions: Dictionary = {}
	for card in first.cards: positions[card.uid] = board.rest_pos(card)
	for iteration in 5: board.sync_state(state)
	await _settle()
	for uid in positions:
		_check(board.rest_pos(board.by_uid[uid]).distance_to(positions[uid]) < 0.001, "周期sync保留手摆坐标 %d" % uid)
	# 消耗发生在真实点击快照期间，取消点击不能把已完成工作复活。
	board._snapshot_press(first.cards[0], Vector2.ZERO)
	board._on_card_clicked(first.cards[0])
	state.advance(8.2)
	board.sync_state(state)
	board.cancel_pointer()
	board.sync_state(state)
	await _settle()
	var stale := false
	for group in board.groups:
		for card in group.cards:
			if not state.cards.has(card.uid): stale = true
	_check(not stale, "在手工作完成后点击复位不复活已消耗牌")
	var purchased := [-1]
	board.offer_bought.connect(func(id):
		purchased[0] = state.buy(id, 0, board.purchase_payment_ids)
		board.sync_state(state))
	var offer: Dictionary = state.offers[0]
	# 收入现在汇入独立纯现金堆。单张付款测试应明确创建自己的散钱，
	# 而不是假定运行十秒后的收入仍然是单张钱包。
	var wallet_id := state.add_card("money", 0)
	var budget := 1
	for item in state.offers:
		if not item.is_empty(): budget += int(item.price)
	state.cards[wallet_id].amount = budget
	board.sync_state(state)
	await _settle()
	var wallet: OffWorkCard = board.by_uid[wallet_id]
	var cash := state.money(0)
	_check(state.group_cards(wallet.group_id) == [wallet_id], "单张付款使用明确的散钱fixture")
	var product: CardEntity = board.offers_by_id[int(offer.id)]
	_check(board._market_payment_group(product, wallet.global_position) != null, "单张现金按金额接受反向商品拖拽")
	board._on_card_clicked(product)
	_move_hand(wallet.global_position)
	board._end_drag()
	_check(purchased[0] >= 0, "原购买信号进入唯一真实购买规则")
	_check(state.money(0) == cash - int(offer.price), "购买只扣一次钱")
	await _settle()
	var poor: int = state.add_card("money", 0)
	state.cards[poor].amount = 1
	board.sync_state(state)
	await _settle()
	var other: Dictionary
	for item in state.offers:
		if not item.is_empty():
			other = item
			break
	var product2: CardEntity = board.offers_by_id[int(other.id)]
	var poor_card: CardEntity = board.by_uid[poor]
	var poor_origin := board.rest_pos(poor_card)
	var old_cash := state.money(0)
	board._on_card_clicked(poor_card)
	_move_hand(product2.global_position)
	board._end_drag()
	await _settle()
	_check(state.money(0) == old_cash and board.offers_by_id.has(int(other.id)), "拖不足额现金不会暗中动用别摞钱")
	_check(board.rest_pos(poor_card).distance_to(poor_origin) < 0.001, "购买失败散钱回到原位置")
	board._on_card_clicked(product2)
	_move_hand(poor_origin)
	board._end_drag()
	await _settle()
	_check(state.money(0) == old_cash and board.offers_by_id.has(int(other.id)), "反向拖商品到不足额散钱也拒绝")
	_check(board.rest_pos(product2).distance_to(product2.get_meta("market_slot")) < 0.001, "反向购买失败商品回货架")
	# 拖足额现金走原正向购买路径，与价签/反向路径共享原信号。
	var wallet_amount: int = int(state.cards[wallet.uid].amount)
	board._on_card_clicked(wallet)
	_move_hand(product2.global_position)
	board._end_drag()
	await _settle()
	_check(not board.offers_by_id.has(int(other.id)), "拖足额现金到商品完成真实购买")
	_check(int(state.cards[wallet.uid].amount) == wallet_amount - int(other.price), "指定现金路径只扣所拖的金额")
	# 两张各自不足额的真实现金，按整组余额接原反向购买入口。
	var grouped_offer: Dictionary
	for item in state.offers:
		if not item.is_empty():
			grouped_offer = item
			break
	var grouped_price := int(grouped_offer.price)
	var cash_group := state.create_group(0)
	var cash_a := state.add_card("money", 0, cash_group)
	var cash_b := state.add_card("money", 0, cash_group)
	state.cards[cash_a].amount = 1
	state.cards[cash_b].amount = grouped_price - 1
	board.sync_state(state)
	await _settle()
	var product3: CardEntity = board.offers_by_id[int(grouped_offer.id)]
	var grouped_card: OffWorkCard = board.by_uid[cash_a]
	var selected: Variant = board._market_payment_group(product3, grouped_card.global_position)
	_check(selected != null and _same(selected.cards.map(func(c): return c.uid), [cash_a, cash_b]), "反向购买按两张现金合计金额识别整摞")
	var total_before := state.money(0)
	var unrelated_before := int(state.cards[wallet_id].amount)
	board._on_card_clicked(product3)
	_move_hand(grouped_card.global_position)
	board._end_drag()
	await _settle()
	_check(not board.offers_by_id.has(int(grouped_offer.id)) and state.money(0) == total_before - grouped_price, "整摞现金反向购牌精确扣合计价格")
	_check(not state.cards.has(cash_a) and not state.cards.has(cash_b), "整摞恰好付清时消耗实际两张现金")
	_check(state.cards[wallet_id].amount == unrelated_before, "整摞付款不动其他散钱")
	board.reset_view()
	_check(board.by_uid.is_empty() and board.cards.is_empty() and board.groups.is_empty(), "重开清理原桌面实例")
	host.queue_free()
	await process_frame
	for error in errors: printerr("FAIL ", error)
	print("ORIGINAL_BOARD ", "PASS" if errors.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if errors.is_empty() else 1)

func _move_hand(anchor: Vector3) -> void:
	var delta: Vector3 = anchor - board._drag_cards[0].global_position
	for card in board._drag_cards: card.global_position += delta

func _settle() -> void:
	await create_timer(0.22).timeout
	await process_frame

func _same(a: Array, b: Array) -> bool:
	var left := a.duplicate()
	var right := b.duplicate()
	left.sort()
	right.sort()
	return left == right

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: errors.append(message)
