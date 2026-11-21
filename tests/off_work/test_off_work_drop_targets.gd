# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 落点在松手之前就看得见：拖着罢工牌时，能打的对方组合画上铅笔虚线框，对准的那个
## 变成实线；拖到会拒绝这张牌的己方组合上，那一组变成警示色；把人拖到开除入口上，
## 入口写出能换回多少钱。
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D
var facility_label: Label3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	await _strike_frames()
	await _refused_pile()
	await _dismissal_refund()
	await _dispose()
	finish()

func _fixture(groups: Array) -> void:
	await _dispose()
	var config := OffWorkConfig.new()
	config.rules.initial.groups = groups
	config.rules.initial.money = 6
	config.rules.bot.enabled = false
	config.rules.conveyor.pool = {"employee": 1}
	config.rules.conveyor.interval_seconds = 1000.0
	state = OffWorkState.new(config)
	state.new_game(20261121)
	OffWorkCardDB.configure(config)
	host = Node3D.new()
	root.add_child(host)
	# The dismissal entrance's label, where the main scene puts it.
	var facility := Node3D.new()
	facility.name = "MarketFacility"
	host.add_child(facility)
	facility_label = Label3D.new()
	facility_label.name = "FacilityAction"
	facility.add_child(facility_label)
	board = OffWorkBoard.new(false)
	host.add_child(board)
	board.set_process(false)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 25, 12)
	camera.look_at(Vector3.ZERO)
	board.setup(camera, true)
	board.sync_state(state)
	for presenter in [board, board.enemy_board]:
		for item in presenter._move_tw.values():
			if item.tw != null and item.tw.is_valid():
				item.tw.pause()
				item.tw.custom_step(1.0)

func _dispose() -> void:
	if is_instance_valid(host):
		host.queue_free()
		await process_frame
	host = null
	board = null

func _hold(cards: Array, at: Vector3) -> void:
	board._drag_cards.assign(cards)
	for card in cards: card.global_position = at
	board._sync_drop_targets()

func _let_go() -> void:
	board._drag_cards.clear()
	board.clear_hover_group()
	board._sync_drop_targets()

func _owned(owner: int, kind: String) -> Array:
	return state._owner_type(owner, kind)

func _strike_frames() -> void:
	await _fixture([{"employee": 1, "work": 6}, {"work": 5}])
	var strike: int = state.add_card("strike", 0)
	board.sync_state(state)
	# 对手有两组：一组有人在干活（能打），一组只有工作（打不了）。
	var busy: int = int(state.cards[_owned(1, "employee")[0]].group)
	var idle := -1
	for gid in state.groups:
		if int(state.groups[gid].owner) == 1 and gid != busy and not state.group_work(gid).is_empty(): idle = gid
	check(state.can_strike_group(busy, 0) and idle >= 0 and not state.can_strike_group(idle, 0), "夹具：一组能打，一组打不了")
	check(board._drop_frames.is_empty(), "没有拖牌时桌上没有落点框")
	var card: OffWorkCard = board.by_uid[strike]
	_hold([card], card.global_position + Vector3.UP)
	check(board._drop_frames.keys() == [busy], "拖起罢工牌：只有能打的那一组画上框")
	var frame: Node3D = board._drop_frames[busy]
	check(is_zero_approx(frame.material_override.get_shader_parameter("opacity")), "框是画出来的，不是整块跳出来")
	board._sync_drop_targets(0.3)
	check(is_equal_approx(frame.material_override.get_shader_parameter("opacity"), 1.0) and not frame.is_processing(),
		"框跟着牌桌的时钟显形，不靠实时帧")
	check(frame.material_override.render_priority > -48 and frame.material_override.render_priority < -32, "框画在分区和空槽之上、牌之下")
	var front: OffWorkCard = board.enemy_board.groups.filter(func(group): return int(group.work_group_id) == busy)[0].cards[0]
	check(frame.material_override.get_shader_parameter("dashed") == true \
		and is_zero_approx(frame.material_override.get_shader_parameter("fill_color").a),
		"框是一圈铅笔虚线，不铺底色")
	check(absf(frame.global_position.x - front.global_position.x) < CardEntity.CARD_SIZE.x \
		and absf(frame.global_position.z - front.global_position.z) < CardEntity.CARD_SIZE.z \
		and frame.global_position.y < front.global_position.y,
		"框围着那一组，画在牌的下面")
	var extent: Vector2 = frame.get_meta("extent")
	check(extent.x > CardEntity.CARD_SIZE.x and extent.y > CardEntity.CARD_SIZE.z, "框比牌大一圈")
	# 对准它：虚线变实线。
	board._hover_group = board.enemy_board.groups.filter(func(group): return int(group.work_group_id) == busy)[0]
	board._sync_drop_targets()
	check(frame.material_override.get_shader_parameter("dashed") == false, "对准的那一组，虚线变成实线")
	board._hover_group = null
	board._sync_drop_targets()
	check(frame.material_override.get_shader_parameter("dashed") == true, "移开后回到虚线")
	# 用牌桌自己的悬停逻辑走一遍：罢工牌移开之后，对方那一组要回到它原来的颜色。
	var pile: Dictionary = board.enemy_board.groups.filter(func(group): return int(group.work_group_id) == busy)[0]
	var own_colour: Color = pile.cards[0]._hl_color
	var was_lit: bool = pile.cards[0].highlighted
	var screen: Vector2 = board.camera.unproject_position(front.global_position)
	var above: Vector3 = Plane(Vector3.UP, Board.DRAG_HEIGHT).intersects_ray(board.camera.project_ray_origin(screen), board.camera.project_ray_normal(screen))
	_hold([card], above)
	board._sync_hover_target(above)
	check(is_same(board._hover_group, pile), "罢工牌盖在那一组上方：它就是松手的目标")
	_hold([card], Vector3(0.0, Board.DRAG_HEIGHT, 4.0))
	board._sync_hover_target(card.global_position)
	check(board._hover_group == null and pile.cards[0].highlighted == was_lit and (not was_lit or pile.cards[0]._hl_color.is_equal_approx(own_colour)),
		"移开之后对方那一组回到原来的颜色，不留着被对准时的颜色")
	# 那一组加了工会之后不再能打，框当场撤掉。
	state.move_cards([state.add_card("union", 1)], busy)
	board.sync_state(state)
	board._sync_drop_targets()
	check(not state.can_strike_group(busy, 0) and board._drop_frames.is_empty(), "有工会的组打不了，不画框")
	check(board._leaving_frames == [frame] and not frame.is_queued_for_deletion(), "撤掉的框先淡出")
	board._sync_drop_targets(0.3)
	check(board._leaving_frames.is_empty() and frame.is_queued_for_deletion(), "淡出之后才释放")
	_let_go()
	# 拖别的牌不画罢工的框。
	var person: OffWorkCard = board.by_uid[_owned(0, "employee")[0]]
	_hold([person], person.global_position + Vector3.UP)
	check(board._drop_frames.is_empty(), "拖的不是罢工牌时不画框")
	_let_go()
	check(board._drop_frames.is_empty(), "松手后桌上不留框")

func _refused_pile() -> void:
	await _fixture([{"employee": 1, "work": 6}])
	var mine: int = int(state.cards[_owned(0, "employee")[0]].group)
	state.move_cards([state.add_card("union", 0)], mine)
	var overtime: int = state.add_card("overtime", 0)
	var coffee: int = state.add_card("coffee", 0)
	board.sync_state(state)
	var group: Dictionary = board.groups.filter(func(item): return int(item.work_group_id) == mine)[0]
	var warning: Array = board._settings.drop_targets.refused_tint
	var refused := Color(float(warning[0]), float(warning[1]), float(warning[2]))
	_hold([board.by_uid[overtime]], group.cards[0].global_position + Vector3.UP)
	board._hover_group = group
	board._set_group_highlight(group, true)
	check(board._drop_refused(group) and group.cards.all(func(card): return card.highlighted and card._hl_color.is_equal_approx(refused)),
		"加班牌对着有工会的组：那一组是警示色，不是「可以放」的颜色")
	# 手上的牌盖住了下面那一组的大半，所以警示色也上到手上的牌。
	board._sync_drop_targets()
	var held: OffWorkCard = board.by_uid[overtime]
	check(held.highlighted and held._hl_color.is_equal_approx(refused), "手上的那张牌也是警示色")
	check(state.move_cards([overtime], mine) < 0, "规则确实会拒绝这一下")
	board.clear_hover_group()
	board._sync_drop_targets()
	check(not held.highlighted, "移开之后手上的牌恢复原样")
	check(group.cards.all(func(card): return not card.highlighted or not card._hl_color.is_equal_approx(refused)),
		"移开之后那一组也回到自己的颜色，不留着警示色")
	_let_go()
	_hold([board.by_uid[coffee]], group.cards[0].global_position + Vector3.UP)
	board._hover_group = group
	board._set_group_highlight(group, true)
	check(not board._drop_refused(group) and group.cards.all(func(card): return card.highlighted and not card._hl_color.is_equal_approx(refused)),
		"同一组对别的牌照常是「可以放」的颜色")
	board._sync_drop_targets()
	check(not board.by_uid[coffee].highlighted, "能放的牌不上警示色")
	_let_go()

func _dismissal_refund() -> void:
	await _fixture([{"employee": 2, "work": 6}, {"grinder": 1}])
	board.pawn_pos = Vector3(6.0, 0.2, -1.6)
	facility_label.text = ""
	var employee: OffWorkCard = board.by_uid[_owned(0, "employee")[0]]
	var grinder: OffWorkCard = board.by_uid[_owned(0, "grinder")[0]]
	var over := board.pawn_pos + Vector3(0.2, 1.0, 0.1)
	_hold([employee], employee.global_position + Vector3.UP)
	check(facility_label.text == "", "人还没到入口上方：入口不写返款")
	_hold([employee], over)
	var refund := int(state.config.cards.employee.refund)
	check(facility_label.text == str(board._settings.drop_targets.refund_format) % refund, "人到了入口上方：入口写出这一下能换回多少钱")
	_hold([employee, grinder], over)
	check(facility_label.text == str(board._settings.drop_targets.refund_format) % (refund + int(state.config.cards.grinder.refund)),
		"拖着几个人就写几个人的返款之和")
	_let_go()
	check(facility_label.text == "", "松手后入口恢复原样")
	# 不是人、或者会被规则拒绝的，都不写。
	var work: OffWorkCard = board.by_uid[_owned(0, "work")[0]]
	_hold([work], over)
	check(facility_label.text == "", "工作牌拖到入口上不写返款")
	_let_go()
	# 卡表要求至少留一个人时，把所有人一起拖上去会被规则拒绝，入口也就不写。
	state.config.rules.fire.minimum_people = 1
	var everyone: Array = (_owned(0, "employee") + _owned(0, "grinder")).map(func(uid): return board.by_uid[uid])
	_hold(everyone, over)
	check(facility_label.text == "" and not state.dismiss_people(everyone.map(func(card): return card.uid), 0),
		"开除后达不到保留人数：规则会拒绝，入口也不写返款")
	_let_go()
	state.config.rules.fire.minimum_people = 0
	_hold([employee], over)
	check(state.dismiss_people([employee.uid], 0) and state.money(0) == 6 + refund, "写的数就是实际到账的数")
	board._drag_cards.clear()
	board.sync_state(state)
	board._sync_drop_targets()
	check(facility_label.text == "", "开除之后入口恢复原样")
