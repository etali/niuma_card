# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Feedback = preload("res://scenes/table_feedback.gd")
const Motion = preload("res://scenes/ui_motion.gd")
const Arena = preload("res://scenes/rulebook_arena.gd")
const DemoData = preload("res://scenes/rulebook_demo_data.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	await _material_lifecycle()
	await _shared_group_signal()
	await _transfers_and_upgrade()
	await _main_upgrade()
	await _attack_and_shield()
	await _feedback_lifecycle()
	finish()

func _material_lifecycle() -> void:
	var card := CardEntity.new()
	card.setup(89001, "yunketang")
	card.freeze = true
	root.add_child(card)
	var before := card.transform
	var face := card._plate.material_override as ShaderMaterial
	card.pulse_feedback("ready")
	var tween := card._feedback_tween
	tween.pause()
	tween.custom_step(0.13)
	check(float(face.get_shader_parameter("feedback_phase")) > 0.0 and float(face.get_shader_parameter("feedback_phase")) < 1.0,
		"组合成立实际推进纸面描边反馈，不只设置一个状态字符串")
	check(card.transform == before and card._visual.transform == Transform3D.IDENTITY, "纸面反馈不改卡体/图标位置、不影响原比例")
	card.pulse_feedback("shield")
	check(not tween.is_valid(), "重复反馈取消旧通道，不叠加无限Tween")
	var shield_tween := card._feedback_tween
	card.set_shield(true)
	shield_tween = card._feedback_tween
	card.set_shield(true)
	check(card._feedback_tween == shield_tween, "每帧刷新已存在的护盾不重新播反馈")
	card.set_drag_visual(true)
	card._handling_tween.pause()
	card._handling_tween.custom_step(Motion.ANTICIPATE + 0.01)
	check(is_equal_approx(float(face.get_shader_parameter("handling_light")), 1.0), "拖起卡牌启用纸面渐变明暗")
	card.reset_interaction_visual()
	check(is_equal_approx(float(face.get_shader_parameter("feedback_phase")), 1.0)
		and is_zero_approx(float(face.get_shader_parameter("handling_light"))), "取消/抽屉收放可清理材质反馈，没有残余高光")
	card.set_face_down(true)
	card.pulse_feedback("consume")
	card._feedback_tween.pause()
	card._feedback_tween.custom_step(0.15)
	card.set_face_down(false)
	check(float((card._plate.material_override as ShaderMaterial).get_shader_parameter("feedback_phase")) < 1.0,
		"翻面后反馈仍位于正确的正面材质，未污染卡背")
	card.queue_free()
	await process_frame
	check(not shield_tween.is_valid(), "卡牌释放后绑定反馈一同释放")

func _arena(section: String, mode: String) -> Node:
	var example: Dictionary = {}
	for candidate in DemoData.examples(section):
		if candidate["mode"] == mode:
			example = candidate
			break
	assert(not example.is_empty())
	var arena := Arena.new()
	root.add_child(arena)
	var sfx := Sfx.new()
	arena.add_child(sfx)
	sfx.set_muted(true)
	arena.configure(example, sfx)
	return arena

func _shared_group_signal() -> void:
	var main: Node = await boot_main()
	var core: Dictionary = main.state.add_card(main.my_seat, "yunketang")
	var cards: Array = [main._spawn_entity(core, Vector3(0, 0.05, 3.5), true)]
	for i in int(CardDB.get_def("yunketang")["recipe_n"]):
		var data: Dictionary = main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_USER))
		cards.append(main._spawn_entity(data, Vector3(0, 0.05, 3.5), true))
	var group: Dictionary = main.board.make_group(cards, true, false)
	main.board.groups.append(group)
	var hash := StateCodec.state_hash(main.state)
	main.board.refresh_group(group)
	check(cards[0].feedback_event == "ready" and cards[0]._feedback_tween != null, "真实Board首次成组信号连接到共享反馈")
	var first: Tween = cards[0]._feedback_tween
	var effects := main.find_children("Outline_ready*", "MeshInstance3D", true, false)
	check(effects.size() == 1, "组合成立一摞只生成一个外围笔触，不刷屏")
	main.board.refresh_group(group)
	check(cards[0]._feedback_tween == first, "刷新有效组、重新理牌不重复触发成立演出")
	check(StateCodec.state_hash(main.state) == hash, "组合视觉反馈完全不改规则状态")
	var arena := _arena("combos", "production")
	check(arena._table_actions.get_script() == main._table_actions.get_script(), "规则书与正式对局的反馈使用同一TableActions")
	arena.assemble()
	check(arena._input_cards[0].feedback_event in ["ready", "shield"], "规则书成组同样经过共享成员反馈")
	arena.queue_free()
	main.queue_free()
	await process_frame

func _transfers_and_upgrade() -> void:
	var arena := _arena("combos", "upgrade")
	await create_timer(0.5).timeout
	arena.assemble()
	var cards: Array = arena._input_cards.duplicate()
	arena.elapsed = 2.2
	arena.resolve()
	check(cards.all(func(card): return not card._visual_retired), "合成材料走收束吸入，不误用攻击撕毁")
	check(cards.all(func(card): return card.has_meta("dest_pos")), "每张合成材料都有真实吸入目标")
	check(arena.lanes.all(func(lane): return lane["result_uid"] >= 0), "每一档升级产物仍由真实配置和裁决生成")
	while arena.elapsed < arena.duration + 0.8:
		arena.advance_time(0.1)
		await create_timer(0.1).timeout
	for lane in arena.lanes:
		check(arena.entities.has(lane["result_uid"]), "收束后对应升级产物留在桌面")
	var all_gone := true
	for index in cards.size():
		all_gone = all_gone and not is_instance_valid(cards[index])
	check(all_gone, "升级吸入的全部旧卡最终释放，没有残影或残留碰撞")
	arena.queue_free()
	await process_frame
	arena = _arena("combos", "production")
	var record: Dictionary = arena.state.add_card(arena.my_seat, CardDB.unit_id(CardDB.RES_CASH))
	var origin := Vector3(0, 0.2, 3)
	var target := Vector3(-4, 0.05, 4)
	var arriving: CardEntity = arena._spawn_entity(record, target, true, origin)
	var trace: MeshInstance3D = arena.get_node_or_null("Trace_arrival")
	check(trace != null and trace.get_meta("from") == origin and trace.get_meta("to").distance_to(target) < 0.1,
		"产出笔触连接真实组合源点与实际落点")
	await create_timer(0.8).timeout
	check(arriving.position.is_equal_approx(target) and arriving._visual.scale.is_equal_approx(Vector3.ONE), "产出反馈不改变最终位置或卡牌大小")
	check(arriving.feedback_event == "arrive", "新卡落地时有共享的短促完成反馈")
	arena.queue_free()
	await process_frame

func _main_upgrade() -> void:
	var main: Node = await boot_main()
	main.set_foe_remote(true)
	main.sfx.set_muted(true)
	main.phase = main.PHASE_SETTLING
	var example: Dictionary = DemoData.examples("combos").filter(func(item): return item["mode"] == "upgrade")[0]
	var variant: Dictionary = example["variants"][0]
	var cards: Array = []
	for i in int(variant["count"]):
		var record: Dictionary = main.state.add_card(main.my_seat, str(example["source_id"]))
		cards.append(main._spawn_entity(record, Vector3(0, 0.05 + i * 0.025, 3), true))
	var made: Dictionary = main.state.create_combo(main.my_seat, cards.map(func(card): return card.uid))
	check(made.get("ok", false), "正式对局升级组合由配置材料成立")
	var done := [false]
	_finish_main_combo(main, done)
	var gathered := false
	var tore := false
	var deadline := Time.get_ticks_msec() + 10000
	while not done[0] and Time.get_ticks_msec() < deadline:
		for card in cards:
			if is_instance_valid(card):
				gathered = gathered or (card.has_meta("dest_pos") and not main.entities.has(card.uid))
				tore = tore or card._visual_retired
		await process_frame
	check(done[0] and gathered and not tore, "正式结算实际播放材料收束而非撕毁，且按节拍完成")
	check(cards.all(func(card): return not is_instance_valid(card)), "正式升级移除全部旧卡及其碰撞")
	check(main.entities.values().any(func(card): return card.def_id == variant["target_id"] and card.feedback_event == "arrive"),
		"正式结算产物按共享飞入与落地反馈出现")
	main.queue_free()
	await process_frame

func _finish_main_combo(main: Node, done: Array) -> void:
	await main._resolve_combo_visual(0)
	done[0] = true

func _attack_and_shield() -> void:
	var arena := _arena("attack", "attack")
	await create_timer(0.5).timeout
	arena.assemble()
	arena.resolve()
	var network_state := GameState.new()
	StateCodec.restore(network_state, JSON.parse_string(JSON.stringify(StateCodec.snapshot(arena.state))))
	arena.state = network_state
	var target: CardEntity = arena._attack_targets[0]
	var before := StateCodec.state_hash(arena.state)
	var at: Vector3 = target.position
	arena._table_actions.attack_feedback(at, arena.my_seat, str(arena.demo["effect"]["attack_res"]))
	var trace: MeshInstance3D = arena.get_node_or_null("Trace_attack")
	check(trace != null and trace.get_meta("to").distance_to(at) < 0.2, "攻击笔触落向真实受击卡，而不是固定桌面位置")
	var weapon: CardEntity = arena._input_cards[0]
	check(weapon.feedback_event == "attack" and trace.get_meta("from").distance_to(weapon.position) < 0.2,
		"过网络JSON快照后实际已装弹武器仍响应并连接攻击目标")
	check(StateCodec.state_hash(arena.state) == before, "命中笔触本身不扣血、不消耗额外点数")
	arena.queue_free()
	await process_frame
	arena = _arena("buffs", "protect")
	await create_timer(0.5).timeout
	arena.assemble()
	var protected: Array = arena._input_cards.filter(func(card): return card._shield_on)
	check(not protected.is_empty(), "保护夹具使用真实生效的防御Buff")
	before = StateCodec.state_hash(arena.state)
	arena._table_actions.shield_feedback(arena._input_cards)
	var outline: MeshInstance3D = arena.get_node_or_null("Outline_shield")
	check(outline != null and outline.position.y > protected[0].position.y, "护盾轮廓在整摞顶部可见，不被核心卡遮挡")
	check(StateCodec.state_hash(arena.state) == before and protected.all(func(card): return not card._visual_retired), "护盾只做拒挡反馈，不演出虚假的成功攻击")
	await create_timer(Motion.ACT + Motion.SETTLE + 0.1).timeout
	root.disable_3d = true
	var count: int = arena.get_child_count()
	arena._table_actions.shield_feedback(arena._input_cards)
	arena._table_actions.group_ready(arena._input_cards)
	check(arena.get_child_count() == count, "抽屉禁用3D时不创建新反馈节点")
	root.disable_3d = false
	arena.queue_free()
	await process_frame

func _feedback_lifecycle() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var trace := Feedback.trace(stage, "test", Vector3.ZERO, Vector3(3,0.1,2), Color.RED)
	var outline := Feedback.outline(stage, "test", Vector3.ZERO, Vector2(1.2,1.6), Color.BLUE)
	check(trace.get_children().is_empty() and outline.get_children().is_empty(), "桌面笔触没有物理碰撞或可点击控件")
	await create_timer(Motion.ACT + Motion.SETTLE + 0.1).timeout
	check(stage.get_child_count() == 0, "动作结束全部特效自行清除，不在牌桌留垃圾")
	var before := get_processed_tweens()
	var early := Feedback.trace(stage, "test", Vector3.ZERO, Vector3.RIGHT, Color.RED)
	var added: Array[Tween] = []
	for tween in get_processed_tweens():
		if not before.has(tween):
			added.append(tween)
	early.queue_free()
	await process_frame
	await process_frame
	check(added.all(func(tween): return not tween.is_valid()), "切换规则页提前销毁特效时，不回调已释放的节点")
	stage.queue_free()
	await process_frame
