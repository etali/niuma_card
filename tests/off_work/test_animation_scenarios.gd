extends SceneTree
const Runner = preload("res://scenes/off_work_animation_scenario.gd")
var failures: Array[String] = []
var checks := 0
var foreign_position := 0.0
func _initialize() -> void: _run.call_deferred()
func _check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.own_world_3d = true
	root.add_child(viewport)
	var runner := Runner.new()
	viewport.add_child(runner)
	var foreign_tween := create_tween()
	foreign_tween.tween_method(func(value): foreign_position = value, 0.0, 1.0, 20.0)
	var rng = preload("res://scenes/effect_materials.gd").rng()
	var external_rng_state: int = rng.state
	var external_speed: float = UIConfig._hover_animation_speed
	var external_shake: float = UIConfig._screen_shake
	var external_database: Dictionary = runner._database_snapshot()
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="): only = arg.trim_prefix("--scenario=")
	for entry in runner.catalog.scenarios:
		if not only.is_empty() and str(entry.id) != only: continue
		runner.load_scenario(str(entry.id))
		await process_frame
		_check(runner.state == null or runner.state.config.errors.is_empty(), "%s uses valid formal rules" % entry.id)
		_check(runner.selected_id == str(entry.id), "%s loads through the common interface" % entry.id)
		runner.advance(float(entry.duration))
		var snapshot: Dictionary = runner.snapshot()
		_check(is_equal_approx(runner.time(), float(entry.duration)), "%s reaches its exact preview duration" % entry.id)
		var kinds: Array = snapshot.events.map(func(item): return item.kind)
		for kind in entry.get("expects", []):
			_check(kinds.has(kind), "%s triggers the actual %s event" % [entry.id, kind])
			if kind in ["work_complete", "coffee_upgrade", "slack_complete", "transfer", "outsource", "strike", "fire", "buy"]:
				_check(snapshot.events.any(func(event): return str(event.kind) == str(kind) and int(event.get("owner", -1)) == 0), "%s demonstrated action originates from the fixture player" % entry.id)
		print("SCENARIO ", entry.id, " ", kinds)
		if str(entry.id) == "coffee_upgrade_chain":
			var upgrades: Array = snapshot.events.filter(func(event): return event.kind == "coffee_upgrade" and int(event.owner) == 0)
			_check(upgrades.size() == 3, "seven-cup preview completes three distinct real upgrades")
			_check(upgrades.map(func(event): return str(event.to_type)) == ["grinder", "workaholic", "work_emperor"], "upgrade preview shows every intermediate tier in order")
			_check(upgrades.map(func(event): return event.coffee_ids.size()) == [1, 2, 4], "upgrade preview consumes one, two, then four cups")
			_check(upgrades.map(func(event): return snappedf(float(event.time), 0.01)) == [5.5, 10.5, 15.5], "each stage reads its full five-second bar before changing role")
		if str(entry.id) == "employee_tier_income":
			var settlements: Array = snapshot.events.filter(func(event): return event.kind == "work_complete" and int(event.owner) == 0)
			_check(settlements.size() == 1 and settlements[0].participants.size() == 4 and settlements[0].ids.size() == 4, "four tiers complete one shared batch of four work cards")
			_check(settlements.size() == 1 and settlements[0].money_ids.size() == 15, "four-tier preview produces fifteen real money cards in one batch")
		if str(entry.id) == "side_extract":
			_check(runner.state.group_people(runner._groups.source).size() == 2 and runner.state.group_people(runner._groups.target).size() == 3, "side preview commits the exact three-person suffix through native drag")
			_check(runner.state.group_work(runner._groups.source).size() == 198, "source personnel keep working after the extraction")
			runner.seek(1.5)
			var fan: Control = runner.board.side_extract.view
			_check(fan.is_open() and fan.kind == "employee" and fan.records.size() == 5, "side preview exposes only the five real personnel at its first inspection")
			_check(fan.find_children("*", "Panel", true, false).is_empty() and fan.find_children("*", "Label", true, false).is_empty(), "side preview contains only card faces, with no panel, heading or instruction bar")
			var first_face: Rect2 = fan._card_rects[0]
			var last_face: Rect2 = fan._card_rects[4]
			_check(last_face.get_center().y > first_face.get_center().y and absf(last_face.get_center().x - first_face.get_center().x) < 1.0, "five personnel form a vertical offset stack beside the original group")
			_check(fan.preview_cards.all(func(card): return not card.card_mesh.visible), "side preview never stacks thick black card bodies")
			_check(fan.preview_cards[1].position.y - fan.preview_cards[0].position.y > CardEntity.FACE_SPAN_Y, "each complete face occludes the previous card icon and text instead of interleaving their layers")
			_check(runner.state.group_people(runner._groups.source).size() == 5 and runner.state.group_people(runner._groups.target).is_empty(), "looking inside the fan has not already moved personnel")
			var fan_times: Array = fan.preview_cards.map(func(card): return card.illustration_time())
			var fan_positions: Array = fan.preview_cards.map(func(card): return card.position)
			await process_frame
			await process_frame
			_check(fan.preview_cards.map(func(card): return card.illustration_time()) == fan_times, "paused preview does not advance its duplicated card illustrations")
			_check(fan.preview_cards.map(func(card): return card.position) == fan_positions, "paused preview freezes the side-opening motion as well as icons")
			runner.seek(1.08)
			fan = runner.board.side_extract.view
			var early_positions: Array = fan.preview_cards.map(func(card): return card.position)
			runner.seek(1.25)
			fan = runner.board.side_extract.view
			_check(fan.preview_cards.map(func(card): return card.position) != early_positions, "side stack glides out over time rather than appearing at its destination instantly")
			runner.seek(1.08)
			fan = runner.board.side_extract.view
			_check(fan.preview_cards.map(func(card): return card.position) == early_positions, "seeking the opening motion reproduces the same card positions")
			runner.seek(7.5)
			fan = runner.board.side_extract.view
			_check(fan.is_open() and fan.kind == "work" and fan.records.size() == 200, "side preview includes the two-hundred-work inspection")
			_check(fan.focus_index >= 0 and fan.preview_cards.size() <= int(fan.settings.max_render_cards), "large work fan opens local cards with bounded visual cost")
		if entry.has("expected_winner"):
			_check(snapshot.winner == int(entry.expected_winner), "%s reaches its intended actual result" % entry.id)
			_check(bool(snapshot.ui.result_visible), "%s includes the formal result panel" % entry.id)
			_check(runner.board.by_uid.values().all(func(card): return not card._task_progress_active and not card._task_progress.visible), "%s clears task bars from both sides at match end" % entry.id)
		if bool(entry.get("hands", false)):
			var hand_checks: Dictionary = entry.get("hand_checks", {})
			runner.seek(float(hand_checks.get("drag_at", 2.5)))
			_check(bool(runner.snapshot().hand.visible), "drag demonstration draws the original gripping hand")
			_check(int(runner.snapshot().hand.native_cursor_requests) == 0, "drag demonstration never changes the system cursor")
			runner.seek(float(hand_checks.get("released_at", 4.0)))
			_check(not bool(runner.snapshot().hand.visible), "gripping hand disappears after release")
		var seek_started := Time.get_ticks_usec()
		runner.seek(float(entry.duration) * 0.5)
		print("SEEK_MS ", entry.id, " ", (Time.get_ticks_usec() - seek_started) / 1000.0)
		var previous: Dictionary = runner.snapshot()
		var previous_foreign := foreign_position
		await process_frame
		await process_frame
		_check(foreign_position > previous_foreign or not foreign_tween.is_running(), "%s never pauses an unrelated tween" % entry.id)
		_check(runner.snapshot().get("ui", {}) == previous.get("ui", {}), "%s render frames cannot advance UI animations" % entry.id)
		_check(runner.snapshot() == previous, "%s pauses card, conveyor, camera, effect and UI clocks together" % entry.id)
		_check(runner.time() == previous.time, "%s cannot advance while controls are paused" % entry.id)
		_check(runner.snapshot().get("poses", {}) == previous.get("poses", {}), "%s render frames cannot advance its manually controlled card animations" % entry.id)
		var target := runner.time()
		runner.seek(0.0)
		runner.seek(target)
		_check(runner.snapshot().get("work", []) == previous.get("work", []) and runner.snapshot().events == previous.events, "%s repeated seek reproduces rules and emitted events" % entry.id)
		_check(runner.snapshot().get("ui", {}) == previous.get("ui", {}), "%s repeated seek reproduces drawer, mascot and result states" % entry.id)
		_check(runner._database_snapshot() == external_database, "%s restores the live card database" % entry.id)
		_check(rng.state == external_rng_state, "%s restores shared effect randomness" % entry.id)
		_check(UIConfig._hover_animation_speed == external_speed and UIConfig._screen_shake == external_shake, "%s restores shared UI preferences" % entry.id)
	foreign_tween.kill()
	var data := OS.get_environment("WORK_DATA_DIR")
	if not data.is_empty(): _check(not DirAccess.dir_exists_absolute(data), "scenario playback writes no preference or match data")
	viewport.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("ANIMATION_SCENARIOS ", "PASS" if failures.is_empty() else "FAIL", " (", checks, " checks)")
	quit(0 if failures.is_empty() else 1)
