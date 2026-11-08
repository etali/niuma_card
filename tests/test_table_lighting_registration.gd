# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only

extends "res://tests/harness.gd"

class CountingLighting extends TableLighting:
	var mesh_visits := 0
	func _disable_mesh_shadows(node: Node) -> void:
		mesh_visits += 1
		super._disable_mesh_shadows(node)

func _initialize() -> void: _run.call_deferred()

func _card(parent: Node3D, uid: int, hidden := false) -> CardEntity:
	var card := CardEntity.new()
	card.uid = uid
	card.freeze = true
	card._ensure_visual()
	card._visual.visible = not hidden
	parent.add_child(card)
	card.position = Vector3(float(uid), 0.05, 0)
	return card

func _same_shadows(light: TableLighting, message: String) -> void:
	light.refresh()
	var expected := TableLighting.contact_footprints(light._board.cards)
	check(light._last_data == expected and light._multimesh.visible_instance_count == expected.size(), message)

func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var board := Board.new()
	scene.add_child(board)
	board.set_process(false)
	for i in 80: board.register_card(_card(scene, i, i != 0))
	var light := CountingLighting.new()
	scene.add_child(light)
	light.bind(board)
	check(light._prepared_cards.size() == 80 and light._visible_order.size() == 1,
		"bind registers all physical sheets but samples only their visible face")
	await process_frame
	var prepared := light.mesh_visits
	for i in 60: light.refresh()
	check(light.mesh_visits == prepared and light._visible_order.size() == 1,
		"60 static frames neither traverse hidden cards nor revisit their mesh trees")
	var older: CardEntity = board.cards[0]
	var newer: CardEntity = board.cards[10]
	newer._visual.show()
	older._visual.hide()
	older._visual.show()
	_same_shadows(light, "revealing an older card retains registration order and identical shadow geometry")
	check(light._visible_order.size() == 2, "visibility events add exactly the newly exposed sheet")
	newer.position.y = TableLighting.MAX_HEIGHT + 1
	_same_shadows(light, "high flying cards retain the existing maximum shadow height")
	newer.position.y = 1
	_same_shadows(light, "flying card re-enters shadow height without requiring a visibility event")
	board.unregister_card(newer)
	_same_shadows(light, "unregistered live cards stop casting immediately")
	newer._visual.hide()
	newer._visual.show()
	check(not light._visible_cards.has(newer.get_instance_id()), "unregistered visibility signals cannot reinsert a card")
	board.register_card(newer)
	_same_shadows(light, "re-registering a flight restores its existing physical card")
	scene.remove_child(newer)
	light.refresh()
	check(not light._visible_cards.has(newer.get_instance_id()), "temporarily detached registered card leaves candidate set")
	scene.add_child(newer)
	_same_shadows(light, "registered card reparenting restores its candidate without another registration")
	var late := CardEntity.new()
	late.freeze = true
	board.register_card(late)
	scene.add_child(late)
	late.position = Vector3(90, 0.05, 0)
	late._ensure_visual()
	late._visual.hide()
	_same_shadows(light, "registration before tree entry and visual creation observes the eventual hidden face")
	late._visual.show()
	_same_shadows(light, "late-created face joins the visible candidates")
	var container := Node3D.new()
	late._visual.add_child(container)
	var added_mesh := MeshInstance3D.new()
	container.add_child(added_mesh)
	await process_frame
	check(added_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"newly constructed face subtree disables nested hard shadows without a per-frame scan")
	var departed := _card(scene, 100)
	board.register_card(departed)
	var departed_id := departed.get_instance_id()
	board.cards.erase(departed)
	departed.free()
	await process_frame
	check(not light._prepared_cards.has(departed_id) and not light._visible_cards.has(departed_id),
		"freeing a card without an explicit unregister cleans registration and candidates")
	var other := Board.new()
	scene.add_child(other)
	other.set_process(false)
	light.bind(other)
	check(light.get_child_count() == 1 and light._prepared_cards.is_empty()
		and light._multimesh.visible_instance_count == 0, "rebinding clears old shadows and reuses the one drawing node")
	board.register_card(_card(scene, 101))
	check(light._prepared_cards.is_empty(), "old board registrations no longer reach a rebound light")
	other.register_card(_card(scene, 102))
	_same_shadows(light, "new board registrations populate the rebound light")
	var registered := other.cards.duplicate()
	other.cards.clear()
	for card in registered: other.unregister_card(card)
	_same_shadows(light, "bulk reset can clear cards before emitting per-card unregister events")
	scene.free()
	await _off_work_lifecycle()
	finish()

func _off_work_lifecycle() -> void:
	var cfg := OffWorkConfig.new()
	cfg.rules.initial.groups = [{"employee": 1, "work": 40}]
	cfg.rules.initial.money = 0
	var state := OffWorkState.new(cfg)
	state.new_game(73)
	var board := OffWorkBoard.new(false)
	root.add_child(board)
	board.set_process(false)
	board.player_bounds = Rect2(-12, -7, 24, 14)
	board.enemy_board.player_bounds = Rect2(-12, -7, 24, 14)
	board.sync_state(state)
	var lights: Array[TableLighting] = []
	for presenter in [board, board.enemy_board]:
		var light := TableLighting.new()
		root.add_child(light)
		light.bind(presenter)
		lights.append(light)
		_same_shadows(light, "actual owner presenter starts with exactly its registered visible shadows")
	check(board.enemy_board.cards.all(func(card): return card.get_parent() == board),
		"enemy registered cards physically belong to the main board in this fixture")
	var delayed: OffWorkCard
	for card in board.cards:
		if card.face_deferred:
			delayed = card
			break
	check(delayed != null, "fixture contains a real deferred printed work face")
	if delayed != null:
		delayed.reveal_stack_face()
		await process_frame
		check(not delayed.face_deferred and delayed.card_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"revealing a deferred work card builds its face and disables the new hard shadow")
		_same_shadows(lights[0], "deferred face reveal appears in the existing contact shadow layer")
	var employee: OffWorkCard
	for card in board.cards:
		if card.type == "employee": employee = card; break
	var promoted := employee.record.duplicate(true)
	promoted.type = "grinder"
	employee.update_record(promoted)
	_same_shadows(lights[0], "employee role upgrade preserves its visible candidate and shadow")
	board.hide()
	for light in lights:
		_same_shadows(light, "mode visibility change hides both physically nested owner surfaces")
		check(light._visible_cards.is_empty(), "hidden mode removes all visible shadow candidates")
	board.show()
	for light in lights: _same_shadows(light, "mode visibility restoration recovers both owner surfaces")
	board.reset_view()
	for light in lights:
		light.refresh()
		check(light._prepared_cards.is_empty() and light._multimesh.visible_instance_count == 0,
			"actual bulk reset clears both presenters before queued cards are freed")
	board.sync_state(state)
	for light in lights: _same_shadows(light, "restoring the same state registers every new visible body")
	for light in lights: light.free()
	board.free()
