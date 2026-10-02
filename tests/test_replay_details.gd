# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Replay = preload("res://engine/replay_session.gd")
const Snapshot = preload("res://scenes/table_snapshot.gd")
const Regions = preload("res://scenes/table_regions.gd")
var _done := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	await _local_recording()
	await _payment_completion()
	await _remote_recording()
	finish()

func _local_recording() -> void:
	paused = false
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.state.market.fill("yunketang")
	main._respawn_all()
	main._rebuild_pipe()
	await settle()
	main.tape.update_view()
	var first: Dictionary = Snapshot.capture(main)
	check(main.tape.configuration["rules"]["cards"] == CardDB.all_cards(), "完整有效卡牌配置随录像保存")
	check(main.tape.configuration["cards_json"].get("_game") is Dictionary and main.tape.configuration["settings"].has("ai_parameters"), "原cards.json与AI设置均已dump")
	# 买走中间卡，再买一张：它们必须是两个操作，剩余商品原槽位保持不变。
	for index in [3, 1]:
		var old_entities: Dictionary = main.entities.duplicate()
		var bought: Dictionary = await main._try_buy(index)
		check(bought.get("ok", false), "真实购卡成功")
		await settle()
		main.tape.update_view()
	check(main.tape.steps.filter(func(e): return e["intent"]["op"] == Intent.OP_BUY).size() == 2, "连续购买两张保留两个独立步骤")
	# 拖动和收拢不通过裁决器，也应各有一步。
	var group: Dictionary = main.board.groups[0]
	var card: CardEntity = group["cards"][0]
	var at: Vector3 = card.position
	var uid := card.uid
	main._on_drag_broadcast(Protocol.DRAG_PICKUP, [uid], at + Vector3.UP)
	main._on_drag_broadcast(Protocol.DRAG_MOVE, [uid], at + Vector3(1, 1, 0))
	main.board._detach_from_group(card)
	main.board._stop_move(card, false)
	card.position = main.board.clamp_player_position(at + Vector3(1, 0, 0))
	main.board.card_dropped_table.emit()
	main._on_drag_broadcast(Protocol.DRAG_CANCEL, [uid], Vector3.ZERO)
	main._flush_record_view()
	check(main.tape.steps[-1]["kind"] == "layout" and main.tape.steps[-1]["gesture"]["points"].size() == 2, "拖牌保留完整路径和最终布局")
	group = main.board.groups[0]
	main.board.toggle_compact(group["cards"][0])
	main._flush_record_view()
	await settle()
	main.tape.update_view()
	var final_view: Dictionary = Snapshot.capture(main)
	check(main.tape.steps[-1]["kind"] == "layout" and main.tape.steps[-1]["view"]["groups"] == final_view["groups"], "收拢独立记录分组形态")
	var data: Dictionary = main.tape.to_dict().duplicate(true)
	var path := "user://replay-details.json"
	_save(path, data)
	# 留一份可用于验证导出程序的实际场景录像。
	_save("/tmp/card-replay-details.json", data)
	var loaded := Replay.load_path(path)
	check(loaded.get("ok", false), "包含购买、拖动、收拢的录像校验通过")
	var bad: Dictionary = data.duplicate(true)
	bad["configuration"]["rules"]["cards"]["yunketang"]["price"] += 1
	_save("user://replay-details-bad.json", bad)
	var rejected := Replay.load_path("user://replay-details-bad.json")
	check(not rejected["ok"] and rejected["reason"] == "卡牌规则不一致，不能载入", "配置一项不同也明确拒绝，即使旧table指纹没变")
	main.queue_free()
	await process_frame
	if loaded.get("ok", false):
		var replay: Node = load("res://scenes/main.tscn").instantiate()
		replay.force_drawer_layout = true
		replay.replay_session = loaded["session"]
		root.add_child(replay)
		_booted = replay
		replay.drawer_window.set_process(false)
		replay.drawer_window.animations_enabled = false
		replay.drawer_window.pin()
		await settle()
		check(Snapshot.capture(replay)["market"] == first["market"], "载入初态市场卡对齐原框")
		for landing_card in replay.market_cards:
			var landing: Tween = landing_card.get_meta("fly_tw")
			if landing.is_valid() and landing.is_running():
				await landing.finished
		for index in replay.market_cards.size():
			var slot_card: CardEntity = replay.market_cards[index]
			var frame: Node3D = replay.get_node("MarketSlot_%d" % index)
			var camera: Camera3D = replay.board.camera
			var face: Vector2 = camera.unproject_position(slot_card.position + Vector3(0, CardEntity.Y_PLATE, 0))
			check(face.distance_to(camera.unproject_position(frame.position)) < 0.5, "货架卡%d的卡面与槽框投影误差小于半像素" % index)
		var action_total: int = replay.replay_session.action_count()
		for action_index in action_total:
			var action_group: Dictionary = replay.replay_session.action_groups[action_index]
			var last_raw: int = int(action_group["end"]) - 1
			var market: Array = replay.market_cards.duplicate()
			replay.btn_pass.pressed.emit()
			check(replay._replay_busy and replay.btn_pass.disabled, "下一行动先播放动画，期间按钮防止跳帧")
			await _await_step(replay)
			var expected: Dictionary = data["steps"][last_raw].get("view", {})
			var actual: Dictionary = Snapshot.capture(replay)
			check(actual["market"] == expected["market"], "前进后剩余商品精确留在原槽位")
		check(_positions_match(Snapshot.capture(replay), final_view), "播放完整文件后所有双方牌位与录制时一致")
		for action_index in range(action_total - 1, -1, -1):
			replay._replay_previous_button.pressed.emit()
			await settle()
			var start_raw: int = int(replay.replay_session.action_groups[action_index]["start"])
			var expected: Dictionary = data["head_view"] if start_raw == 0 else data["steps"][start_raw - 1]["view"]
			check(_positions_match(Snapshot.capture(replay), expected), "后退%d所有双方牌位精确恢复且不会被布局Tween改写" % action_index)
		replay.queue_free()
		await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://replay-details-bad.json"))

func _remote_recording() -> void:
	var clients := await net_seated_pair(48410, 123, "REPLAY-DETAILS")
	if clients.is_empty():
		return
	var a: NetTransport = clients[0]
	var b: NetTransport = clients[1]
	await net_until(clients, func(): return a.phase() != "")
	var record := Tape.new()
	record.start_remote(b)
	_done = false
	net_pump_until(clients, func(): return _done)
	var active: NetTransport = a if a.actor() == a.my_seat else b
	var index := -1
	for i in active.state().market.size():
		if int(CardDB.get_def(active.state().market[i]).get("price", -1)) in range(1, 10):
			index = i
			break
	var bought: Dictionary = await active.submit(Intent.buy(active.my_seat, index))
	await net_until(clients, func(): return record.size() >= 1)
	check(bought.get("ok", false) and record.size() == 1, "纯客户端录制自己或对手逐张购买的服务器回执")
	var pawned: Dictionary = await active.submit(Intent.pawn(active.my_seat, [bought["new_uid"]]))
	await net_until(clients, func(): return record.size() >= 2)
	check(pawned.get("ok", false) and record.size() == 2, "纯客户端独立记录典当步骤")
	record.rebind_remote(a)
	check(record.size() == 2 and record.recording(), "切换联网连接不丢失已录制步骤")
	_done = true
	var decoded := Tape.from_dict(JSON.parse_string(JSON.stringify(record.to_dict())))
	check(decoded.get("ok", false), "联网录像落盘后可解码")
	if decoded.get("ok", false):
		var tape: Tape = decoded["tape"]
		var replay := Tape.replay(tape)
		check(replay["ok"] and StateCodec.state_hash(replay["state"]) == StateCodec.state_hash(b.state()), "客户端录像完整恢复服务器末态")
		check(tape.steps[0]["result"]["new_uid"] is int and tape.steps[1]["result"]["uids"][0] is int, "联网录像UID从JSON正确还原为整数，供动画查找实体")
	record.stop()
	for client in clients:
		client.close()
	net_stop()

func _save(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _await_step(main: Node) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while main._replay_busy and Time.get_ticks_msec() < deadline:
		await process_frame
	check(not main._replay_busy, "录像动画完整结束")

func _positions_match(actual: Dictionary, expected: Dictionary) -> bool:
	if actual["market"] != expected["market"] or actual["groups"] != expected["groups"]:
		return false
	if actual["positions"].size() != expected["positions"].size():
		return false
	for uid in expected["positions"]:
		var a: Array = actual["positions"].get(uid, [])
		var b: Array = expected["positions"][uid]
		if a.size() != 3 or Vector3(a[0], a[1], a[2]).distance_to(Vector3(b[0], b[1], b[2])) > 0.001:
			return false
	return true

func _payment_completion() -> void:
	var main: Node = await boot_main()
	var before := GameState.new()
	StateCodec.restore(before, StateCodec.snapshot(main.state))
	var def := CardDB.get_def("butie")
	var payment := int(def["recipe_n"])
	# 这里验证三组错峰付款动画；夹具要按当前配方提供完整弹药，并留一现金通过护栏。
	while before.resource_count(main.foe_seat,CardDB.RES_CASH) < payment * 3 + 1:
		before.add_card(main.foe_seat,CardDB.unit_id(CardDB.RES_CASH))
	var cash: Array = []
	for card in before.players[main.foe_seat]["cards"]:
		if card["def_id"] == CardDB.unit_id(CardDB.RES_CASH):
			cash.append(card["uid"])
	for i in 3:
		var weapon := before.add_card(main.foe_seat, "butie")
		var uids: Array = [weapon["uid"]]
		for j in payment:
			uids.append(cash.pop_front())
		check(before.create_combo(main.foe_seat,uids).get("ok",false), "错峰付款夹具第%d组配方有效" % (i+1))
	main.state = before
	main._rebuild_pipe()
	main._respawn_all()
	await settle()
	var current := GameState.new()
	StateCodec.restore(current, StateCodec.snapshot(before))
	var applier := IntentApply.new(current)
	var result := applier.apply(Intent.arm_attacks(main.foe_seat))
	var consumed: Array = []
	for uid in main.entities:
		if before.find_card(main.foe_seat, uid).is_empty() or not current.find_card(main.foe_seat, uid).is_empty():
			continue
		consumed.append(main.entities[uid])
	check(consumed.size() == payment * 3, "装弹产生多张错峰付款动画")
	main.state = current
	var player := preload("res://scenes/replay_presentation.gd").new()
	main.add_child(player)
	player.bind(main)
	await player.play({"result": result, "intent": Intent.arm_attacks(main.foe_seat)}, before)
	await process_frame
	check(consumed.all(func(card): return not is_instance_valid(card)), "下一步解锁前全部错峰付款已结束，没有跳过末尾卡牌")
	main.queue_free()
	await process_frame
