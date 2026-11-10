# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 900)
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":1, "work":12}]
	config.rules.initial.money = 6
	config.rules.bot.enabled = false
	state = OffWorkState.new(config)
	state.new_game(80)
	OffWorkCardDB.configure(config)
	host = Node3D.new()
	root.add_child(host)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 16, 5.5)
	camera.rotation_degrees.x = -71
	board = OffWorkBoard.new()
	host.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	board.sync_state(state)
	await create_timer(0.25).timeout
	for owner in [0, 1]:
		await _buy_from_six(owner)
	await _deferred_expand_and_collapse()
	host.queue_free()
	await process_frame
	finish()

func _buy_from_six(owner: int) -> void:
	var presenter: Board = board if owner == 0 else board.enemy_board
	var payment: Array = state._owner_type(owner, "money").duplicate()
	var group: Dictionary = presenter.group_of(board.by_uid[payment[0]])
	var gid := int(state.cards[payment[0]].group)
	check(state.money(owner) == 6 and payment.size() == 6 and group.compact,
		"玩家%d：六张独立现金组成收拢钱堆" % owner)
	var label: Label3D = _cash_label(group)
	check(label != null and label.is_visible_in_tree() and label.text == "×6",
		"玩家%d：购买前侧栏显示真实六金" % owner)
	var old_layer: Node3D = group.get("side_layer")
	var at := board.camera.unproject_position(label.global_position)
	if owner == 0:
		check(board.side_extract.hit_test(at).get("group", -1) == gid,
			"购买前旧金额位置确实是可点击的侧栏入口")
	var offer := {"id":state._next_offer, "type":"overtime", "price":int(state.config.cards.overtime.price)}
	state._next_offer += 1
	state.offers.append(offer)
	check(int(offer.price) == 5 and state.buy(int(offer.id), owner, payment) > 0,
		"玩家%d：指定现金按真实五金报价购买加班" % owner)
	board.sync_state(state)
	# No frame/timer/income is allowed between the authoritative buy and these
	# assertions: the final batch resync must retire the stale side immediately.
	check(state.money(owner) == 1 and state._owner_type(owner, "money").size() == 1,
		"玩家%d：扣款后真实余额立即为一金" % owner)
	check(payment.slice(0, 5).all(func(uid): return not state.cards.has(uid) and not board.by_uid.has(uid)),
		"玩家%d：五个付款UID同时退出规则与可选牌视图" % owner)
	_check_side_cleared(group, old_layer, "玩家%d六变一" % owner)
	if owner == 0:
		check(board.side_extract.hit_test(at).is_empty(), "扣款同帧旧金额位置不再命中虚假侧栏")
		await _click_at(at)
		check(not board.side_extract.is_open(), "点击旧六金位置不会打开过期现金列表")
		board.cancel_pointer()
	var credited: Array = state._credit(owner, 2)
	board.sync_state(state)
	var growing: Dictionary = presenter.group_of(board.by_uid[credited[0]])
	var fresh: Label3D = _cash_label(growing)
	check(state.money(owner) == 3 and fresh != null and fresh.text == "×3" and fresh.is_visible_in_tree(),
		"玩家%d：再收入两金后侧栏从真实一金更新为三金" % owner)
	if owner == 0:
		check(growing.extract_rows.size() == 1 and growing.extract_rows[0].ids.size() == 3
			and growing.extract_rows[0].ids.all(func(uid): return state.cards.has(uid)),
			"重新建立的侧栏只绑定三张现存现金")
	var empty_layer: Node3D = growing.get("side_layer")
	var empty_at := board.camera.unproject_position(fresh.global_position)
	var all_cash: Array = state._owner_type(owner, "money").duplicate()
	check(state._spend(owner, 3, all_cash), "玩家%d：全额支付剩余三金" % owner)
	board.sync_state(state)
	check(state.money(owner) == 0 and all_cash.all(func(uid): return not board.by_uid.has(uid)),
		"玩家%d：全额付款后没有现金牌视图残留" % owner)
	check(not is_instance_valid(empty_layer) or not empty_layer.is_visible_in_tree(),
		"玩家%d：全额付款同帧隐藏旧侧栏" % owner)
	check(presenter.groups.all(func(current): return int(current.get("work_group_id", -1)) != gid),
		"玩家%d：空钱包不再保留可操作的视觉组" % owner)
	if owner == 0:
		check(board.side_extract.hit_test(empty_at).is_empty(), "空钱包旧侧栏不能被命中")

func _deferred_expand_and_collapse() -> void:
	var cash: Array = state._credit(0, 3)
	board.sync_state(state)
	var group: Dictionary = board.group_of(board.by_uid[cash[0]])
	var old_layer: Node3D = group.get("side_layer")
	check(group.compact and _cash_label(group).text == "×3", "展开测试由真实三金收拢堆开始")
	# Use the ordinary Board layout/toggle, with the same batching gate used by
	# sync_state. The final resync must also clear noncompact groups.
	board._defer_side_refresh = true
	check(board.toggle_compact(group.cards[0]), "原牌桌布局入口可以展开现金堆")
	board._defer_side_refresh = false
	board.resync_sides()
	check(not group.compact, "现金堆进入展开状态")
	_check_side_cleared(group, old_layer, "批量展开")
	board._defer_side_refresh = true
	check(board.toggle_compact(group.cards[0]), "原牌桌布局入口可以重新收拢现金堆")
	board._defer_side_refresh = false
	board.resync_sides()
	var label: Label3D = _cash_label(group)
	check(group.compact and label != null and label.is_visible_in_tree() and label.text == "×3",
		"批量收拢后重新显示当前三金而非旧金额")
	check(group.extract_rows.size() == 1 and group.extract_rows[0].ids.size() == 3,
		"批量收拢重新建立当前现金的提取入口")

func _cash_label(group: Dictionary) -> Label3D:
	var texture := CardArt.res_icon_texture(OffWorkCardDB.RES_CASH, OffWorkCardDB)
	var nodes: Array = group.get("side", [])
	for index in range(0, nodes.size() - 1, 2):
		if is_instance_valid(nodes[index]) and nodes[index] is Sprite3D and nodes[index].texture == texture:
			return nodes[index + 1] as Label3D
	return null

func _check_side_cleared(group: Dictionary, old_layer: Node3D, label: String) -> void:
	check(group.get("side", []).is_empty() and str(group.get("side_sig", "")).is_empty(),
		label + "同帧清空旧侧栏内容")
	check(not is_instance_valid(old_layer) or not old_layer.is_visible_in_tree(),
		label + "同帧隐藏待释放侧栏节点")
	check(group.get("extract_rows", []).is_empty(), label + "同帧清空过期提取入口")

func _click_at(at: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = at
		event.global_position = at
		event.pressed = pressed
		root.push_input(event, true)
		await process_frame
