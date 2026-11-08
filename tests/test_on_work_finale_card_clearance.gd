# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## Follow the real victory presentation, measuring the rendered body and
## printed face throughout the staggered bows rather than only at rest.
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 900)
	for won in [true, false]:
		var main := await boot_main()
		main.sfx.set_muted(true)
		main.board.set_process(false)
		var records: Array = []
		for card: CardEntity in main.entities.values():
			if not is_instance_valid(card) or card.is_market or card._visual == null: continue
			card.freeze = true
			card.reset_interaction_visual()
			records.append({"card": card, "pose": card.global_transform,
				"body_y": _lowest_y(card.card_mesh),
				"body_clearance": INF, "face_clearance": INF, "logical_unchanged": true,
				"peak_lift": 0.0, "peak_tilt": 0.0})
		var layers := _overlapping_layers(records)
		check(not layers.is_empty(), "谢幕夹具包含实际展开且互相覆盖的多层牌列")
		var previous := get_processed_tweens()
		main.state.winner = main.my_seat if won else main.foe_seat
		main.state.win_reason = "测试终局卡片谢幕。"
		main._show_game_over()
		check(main.phase == main.PHASE_OVER and main.game_over_panel != null,
			"%s：通过真实终局入口开始谢幕" % won)
		var motion: Array[Tween] = []
		for tween in get_processed_tweens():
			if previous.has(tween): continue
			tween.pause()
			motion.append(tween)
		check(not motion.is_empty() and not records.is_empty(), "终局保留实际牌和动画")
		for frame in 135:
			for tween in motion:
				if tween.is_valid(): tween.custom_step(0.01)
			for record in records:
				var card: CardEntity = record.card
				record.body_clearance = minf(record.body_clearance, _lowest_y(card.card_mesh) - float(record.body_y))
				record.face_clearance = minf(record.face_clearance, _lowest_y(card._plate) - float(record.body_y))
				record.logical_unchanged = record.logical_unchanged and card.global_transform.is_equal_approx(record.pose)
				record.peak_lift = maxf(record.peak_lift, card._visual.position.y)
				record.peak_tilt = maxf(record.peak_tilt, absf(card._visual.rotation_degrees.x))
			for layer in layers:
				var lower: CardEntity = layer.lower
				var upper: CardEntity = layer.upper
				var normal := lower._plate.global_basis.z.normalized()
				var clearance := (upper._plate.global_position - lower._plate.global_position).dot(normal)
				layer.ordered = layer.ordered and clearance > 0.0001
		for record in records:
			var card: CardEntity = record.card
			var is_winner: bool = (main.my_seat if card.draggable else main.foe_seat) == main.state.winner
			var label := "%s/%s/%d" % ["赢家" if is_winner else "输家", card.def_id, card.uid]
			check(float(record.body_clearance) >= -0.0001, label + "：谢幕全程卡体不低于原静置底面")
			check(float(record.face_clearance) >= -0.0001, label + "：谢幕全程印刷面边缘不穿过原支撑面")
			check(bool(record.logical_unchanged), label + "：谢幕不修改逻辑坐标和碰撞体姿态")
			check(float(record.peak_lift) > 0.30 if is_winner else float(record.peak_lift) > 0.039 and float(record.peak_lift) < 0.05,
				label + "：胜利跳跃与失败轻微起伏保留不同幅度")
			check(float(record.peak_tilt) < 0.001, label + "：谢幕保持卡面平放，不发生俯仰穿层")
			check(card._visual.transform.is_equal_approx(Transform3D.IDENTITY),
				label + "：谢幕后完整回到原始视觉姿态")
		for owner in [true, false]:
			var own_layers: Array = layers.filter(func(layer): return layer.lower.draggable == owner)
			check(not own_layers.is_empty() and own_layers.all(func(layer): return layer.ordered),
				"%s的展开牌列在谢幕全程保持正向层序" % ("我方" if owner else "对手"))
		await _capture(main, "win" if won else "lose")
		var old_fx: Node3D = main._finale_fx
		var restart: Button = main.game_over_panel.find_child("ResultRestart", true, false)
		restart.pressed.emit()
		await settle()
		check(main.state.winner == "" and main._finale_fx == null and not is_instance_valid(old_fx),
			"真实再战按钮清理上一局谢幕效果")
		var neutral := true
		for card: CardEntity in main.entities.values():
			if not is_instance_valid(card) or card.is_market or card._visual == null: continue
			neutral = neutral and card._visual.transform.is_equal_approx(Transform3D.IDENTITY)
		check(neutral, "重新发牌不继承上一局的后仰和抬升")
		main.queue_free()
		await process_frame
	finish()

func _lowest_y(mesh: MeshInstance3D) -> float:
	var lowest := INF
	var bounds := mesh.get_aabb()
	for corner in 8:
		lowest = minf(lowest, (mesh.global_transform * bounds.get_endpoint(corner)).y)
	return lowest

func _overlapping_layers(records: Array) -> Array:
	var layers: Array = []
	for first in records:
		for second in records:
			var lower: CardEntity = first.card
			var upper: CardEntity = second.card
			if lower.draggable != upper.draggable: continue
			var delta: Vector3 = upper.global_position - lower.global_position
			if delta.y <= 0.0001 or delta.y > 0.2: continue
			if absf(delta.x) >= CardEntity.CARD_SIZE.x or absf(delta.z) >= CardEntity.CARD_SIZE.z: continue
			layers.append({"lower": lower, "upper": upper, "ordered": true})
	return layers

func _capture(main: Node, label: String) -> void:
	var folder := OS.get_environment("ON_WORK_FINALE_CAPTURE")
	if folder.is_empty() or DisplayServer.get_name() == "headless": return
	DirAccess.make_dir_recursive_absolute(folder)
	main.game_over_panel.hide()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder.path_join(label + ".png"))
	main.game_over_panel.show()
