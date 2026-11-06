extends "res://tests/realtime/test_continuous_icon_motion.gd"

## Real personnel keep their complete card geometry. Only immutable illustration
## sampling changes while the authoritative twenty-second strike is active.
func _run() -> void:
	config = WorkConfig.new()
	config.rules.initial.groups = [{"employee": 1, "grinder": 1, "workaholic": 1, "work_emperor": 1, "leader": 1, "work": 20}]
	config.rules.bot.enabled = false
	WorkCardDB.configure(config)
	var state := WorkState.new(config)
	state.new_game()
	stage = Node3D.new()
	root.add_child(stage)
	var people: Array = []
	var group := -1
	for uid in state.cards:
		if int(state.cards[uid].owner) == 0 and config.is_person(str(state.cards[uid].type)):
			people.append(uid)
			group = int(state.cards[uid].group)
	var tool := state.add_card("strike", 1)
	_check(state.activate(tool, group), "real strike starts against a working group")
	var snapshots: Dictionary = {}
	for index in people.size():
		var uid: int = people[index]
		var card := WorkCard.new()
		stage.add_child(card)
		card.configure(state.cards[uid], config.cards[state.cards[uid].type])
		card.freeze = true
		card.position.x = float(index - 1) * 2.1
		card.set_process(false)
		views.append(card)
		var kind := card.type
		var profile_key := WorkIconMotion.profile_key(kind, "striking")
		_check(card._strike_participant and card.illustration_profile() == profile_key, "%s adopts a dedicated dance from its real strike state" % kind)
		_check(card._motion_material.get_meta("work_motion_kind") == profile_key, "%s shader receives its dance profile" % kind)
		_check(not card._task_progress.visible, "%s has no stale work bar while dancing" % kind)
		snapshots[uid] = [card.global_transform, card._visual.transform, card.card_mesh.transform, card.label.transform, card._icon.transform, card._icon.texture]
		card._process(0.28)
		var snapshot: Array = snapshots[uid]
		_check(card.global_transform == snapshot[0] and card._visual.transform == snapshot[1] and card.card_mesh.transform == snapshot[2] and card.label.transform == snapshot[3], "%s dance never transforms the whole card, frame or title" % kind)
		_check(card._icon.transform == snapshot[4] and card._icon.texture == snapshot[5], "%s uses continuous UV motion with the exact same GPT texture" % kind)
		var uv := Vector2(0.42, 0.85)
		_check(WorkIconMotion.source_uv(profile_key, uv, card.illustration_time()).distance_to(uv) > 0.005, "%s visible leg movement differs from its ordinary portrait" % kind)
		var time := card.illustration_time()
		card.update_record(state.cards[uid])
		_check(card.illustration_time() == time, "%s repeated state sync does not restart its dance" % kind)
		card.set_drag_visual(true)
		_check(card.illustration_time() == time, "%s pickup preserves the dancing pose" % kind)
		card._process(0.025)
		_check(card.illustration_time() > time, "%s person keeps dancing while the card is dragged" % kind)
		card.set_drag_visual(false)
		time = card.illustration_time()
		card.pulse_landed()
		_check(card.illustration_time() == time, "%s landing feedback preserves the dancing pose" % kind)
		card.reset_interaction_visual()
		card.set_process(false)
		card._process(0.28)
		time = card.illustration_time()
		card.hover_animation_paused = true
		card._process(0.5)
		_check(card.illustration_time() == time, "%s explicit pause freezes its dance" % kind)
		card.hover_animation_paused = false
		var preview := card.make_illustration_preview_material()
		_check(preview.get_meta("work_motion_kind") == profile_key and preview.get_shader_parameter("art_texture") == snapshot[5] and preview.get_shader_parameter("motion_seconds") == time, "%s magnifier uses the same dance, original art and clock" % kind)
		_check_continuity(profile_key)
	for card in views: card.set_process(true)
	await process_frame
	paused = true
	var times: Array = views.map(func(card): return card.illustration_time())
	await create_timer(0.06, true).timeout
	_check(views.map(func(card): return card.illustration_time()) == times, "SceneTree pause freezes all dancing portraits")
	paused = false
	for card in views: card.set_process(false)
	if OS.get_environment("WORK_STRIKE_ICON_CAPTURE") == "1" and DisplayServer.get_name() != "headless":
		await _capture()
	state.advance(config.number("strike", "duration_seconds"))
	for card in views:
		card.update_record(state.cards[card.uid])
		_check(not card._strike_participant and card.illustration_profile() == card.type and card.illustration_time() == 0.0, "%s expiry restores the ordinary idle portrait" % card.type)
		_check(card._motion_material.get_meta("work_motion_kind") == card.type, "%s expiry clears its activity-specific shader parameters" % card.type)
		card.set_strike_participant(true)
		card._process(0.3)
		card.leave()
		_check(not card._strike_participant and card._motion_material.get_meta("work_motion_kind") == card.type and card.illustration_time() == 0.0, "%s leaving clears the dance before the departure animation" % card.type)
	stage.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("STRIKE_ICON_MOTION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _capture() -> void:
	root.size = Vector2i(1280, 720)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("56695e")
	stage.add_child(environment)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 7.0
	camera.position = Vector3(0, 8, 2.2)
	stage.add_child(camera)
	camera.look_at(Vector3.ZERO)
	camera.make_current()
	for frame in 3:
		for card in views: card.seek_hover_animation(card.illustration_duration() * float(frame) / 3.0)
		await process_frame
		await process_frame
		RenderingServer.force_draw(false)
		DirAccess.make_dir_recursive_absolute("res://reports")
		_check(root.get_texture().get_image().save_png("res://reports/strike-icon-dance-%d.png" % frame) == OK, "dance sample image saved")
