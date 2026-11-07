extends SceneTree

var checks := 0
var failures: Array[String] = []
var stage: Node3D
var config: OffWorkConfig
var views: Array[OffWorkCard] = []

func _initialize() -> void: _run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _run() -> void:
	config = OffWorkConfig.new()
	OffWorkCardDB.configure(config)
	stage = Node3D.new()
	root.add_child(stage)
	for id: String in config.cards:
		var card := _card(id)
		var texture := card._icon.texture
		_check(card.uses_continuous_animation() and card.illustration_ready(), "%s has an immediately available continuous master" % id)
		_check(card.illustration_sample_fps() == 60.0 and card.illustration_sample_count() > 60, "%s inspection samples are separate from source pose count" % id)
		card.set_hover_visual(true, false)
		card.set_process(false)
		card.seek_hover_animation(0.12345)
		_check(is_equal_approx(card.illustration_time(), 0.12345), "%s seek preserves fractional sub-frame time" % id)
		_check(card._icon.texture == texture and card._hover_frames.is_empty(), "%s keeps the same master and never swaps or fabricates pose frames" % id)
		_check(not CardArt._hover_owners.get(id, {}).has(card.get_instance_id()), "%s hover never requests legacy hdelta decoding" % id)
		var preview := card.make_illustration_preview_material()
		_check(preview.shader == OffWorkIconMotion.CANVAS and card._motion_material.shader == OffWorkIconMotion.SPATIAL, "%s supplies both production render adapters" % id)
		_check(preview.get_shader_parameter("art_texture") == texture and is_equal_approx(preview.get_shader_parameter("motion_seconds"), card.illustration_time()), "%s magnifier shares master and exact clock" % id)
		card._icon.modulate = Color(0.6, 0.7, 0.8, 0.4)
		card.sync_illustration_preview_material(preview)
		card.seek_hover_animation(0.12395)
		_check(card._motion_material.get_shader_parameter("motion_tint") == card._icon.modulate and preview.get_shader_parameter("motion_tint") == card._icon.modulate, "%s preserves dimming and exit alpha" % id)
		_check(is_equal_approx(card.illustration_time(), 0.12395) and card._icon.texture == texture, "%s submillisecond seek is not quantized to an inspection sample" % id)
		card._icon.modulate = Color.WHITE
		card.hover_animation_paused = true
		var time := card.illustration_time()
		card._process(1.0)
		_check(card.illustration_time() == time, "%s explicit pause freezes continuous motion" % id)
		card.set_hover_visual(false)
		_check(card.illustration_time() == 0.0 and card._icon.texture == texture, "%s hover exit returns to the unchanged master" % id)
		card.hover_animation_paused = false
		card.set_process(false)
		_check_continuity(id)

	var worker := _find("employee")
	for person in [worker, _find("grinder"), _find("workaholic"), _find("work_emperor")]:
		for activity in ["meeting", "transfer", "slack"]:
			person.update_record(_record(person, activity, 0.35))
			person._process(0.7)
			_check(not person.illustration_is_active() and person.illustration_time() == 0.0, "%s cannot play a work action while doing %s" % [person.type, activity])
			_check(not person._task_progress.visible and is_equal_approx(person.task_progress_display_value(), 0.35), "%s retains real %s progress and hides shared meeting/transfer/slack personnel bars" % [person.type, activity])
		person.update_record(_record(person, "idle", 0.0))
	worker.update_record(_record(worker, "work", 0.35))
	worker._process(0.36789)
	var time := worker.illustration_time()
	_check(is_equal_approx(time, 0.36789), "real work advances continuously without a 12 Hz or 60 Hz time grid")
	worker.set_hover_visual(true, false)
	worker.set_hover_visual(false, false)
	_check(is_equal_approx(worker.illustration_time(), time), "hover entry and exit preserve the ongoing task pose")
	worker.update_record(_record(worker, "work", 0.35, true))
	worker._process(1.0)
	_check(worker.illustration_time() == time and is_equal_approx(worker.task_progress_display_value(), 0.35), "meeting freezes the exact pose without changing gameplay progress")
	worker.update_record(_record(worker, "work", 0.35))
	worker._process(0.25)
	_check(is_equal_approx(worker.illustration_time(), time + 0.25), "returning from a meeting resumes the held clock")
	var boosted := _record(worker, "work", 0.35)
	boosted.rate_multiplier = 100.0
	worker.update_record(boosted)
	time = worker.illustration_time()
	worker._process(0.25)
	_check(is_equal_approx(worker.illustration_time() - time, 0.25 * OffWorkUI.number("animation", "task_playback_speed") * OffWorkUI.number("animation", "motion_speed_scale_max")), "gameplay speed uses the readable animation cap")
	worker.set_drag_visual(true)
	worker._process(0.4)
	_check(worker.illustration_time() == 0.0 and worker._icon.texture == worker._hover_original, "original pickup retains an intact master and stops local motion")
	worker.set_drag_visual(false)
	worker._process(0.25)
	_check(worker.illustration_time() > 0.0, "drop resumes the real task")
	worker.set_process(true)
	await process_frame
	paused = true
	time = worker.illustration_time()
	await create_timer(0.1, true).timeout
	_check(worker.illustration_time() == time, "drawer SceneTree pause freezes the shader clock")
	paused = false
	worker.set_process(false)

	var identity := worker.get_instance_id()
	var bar := worker._task_progress
	var upgraded := _record(worker, "work", 0.35, true)
	upgraded.type = "grinder"
	worker.update_record(upgraded)
	worker.play_event("coffee_upgrade")
	worker._process(0.2)
	_check(worker.get_instance_id() == identity and worker._task_progress == bar, "coffee upgrades the existing card and progress surface")
	_check(worker._hover_original == CardArt.illustration_texture("grinder", OffWorkCardDB) and worker._motion_material.get_meta("work_motion_kind") == "grinder", "upgrade switches master and motion profile together")
	_check(worker._task_progress_paused and is_equal_approx(worker.task_progress_display_value(), 0.35), "upgrade preserves real work and interruption")
	_check(not CardArt._hover_owners.get("employee", {}).has(identity) and worker._hover_frames.is_empty(), "upgrading owns no obsolete pose sequence")

	var leader := _find("leader")
	leader.update_record(_record(leader, "work", 0.4))
	leader._process(0.4)
	_check(not leader.illustration_is_active() and not leader._task_progress.visible, "leader has no false ordinary work animation or bar")
	leader.update_record(_record(leader, "meeting", 0.4))
	leader._process(0.7)
	_check(leader.illustration_time() > 0.0, "leader animates during a real meeting")
	var document := _find("work")
	document.set_task_progress(0.5, true, false)
	document._process(0.7)
	_check(document.illustration_time() > 0.0, "visible group document animates with projected real work")
	time = document.illustration_time()
	document.set_task_progress(0.5, true, true)
	document._process(0.7)
	_check(document.illustration_time() == time, "projected group pause also freezes the top document")
	var meeting := _find("meeting")
	var meeting_record := _record(meeting, "idle", 0.0)
	meeting_record.status = "active"
	meeting.update_record(meeting_record)
	meeting._process(0.7)
	_check(meeting.illustration_time() > 0.0, "active meeting animates without needing hover")
	var duplicate := _card("meeting")
	duplicate.update_record(meeting_record)
	duplicate._process(0.3)
	_check(duplicate._icon.texture == meeting._icon.texture and duplicate._motion_material != meeting._motion_material, "same-kind cards share master pixels but keep independent clocks")
	_check(not is_equal_approx(duplicate.illustration_time(), meeting.illustration_time()) and CardArt._hover_cache.is_empty(), "concurrent cards need no multi-frame texture cache")
	worker.leave()
	_check(worker._retired and worker.stamp_text() == OffWorkUI.section("animation").leave_stamp and not worker._task_progress.visible, "off-work exit retains original stamp and clears task UI")
	worker._icon.modulate.a = 0.25
	worker._process(0.0)
	_check(is_equal_approx(worker._motion_material.get_shader_parameter("motion_tint").a, 0.25), "retired card continues syncing the original exit fade")
	stage.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("CONTINUOUS_ICON_MOTION %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

func _check_continuity(kind: String) -> void:
	var duration := OffWorkIconMotion.duration(kind)
	var epsilon := duration * 0.0001
	var closed := true
	var velocity_closed := true
	var moving := false
	var finite := true
	var max_step := 0.0
	var min_determinant := INF
	for x in range(1, 10):
		for y in range(1, 10):
			var point := Vector2(x, y) / 10.0
			var start := OffWorkIconMotion.source_uv(kind, point, 0.0)
			var end := OffWorkIconMotion.source_uv(kind, point, duration)
			closed = closed and start.distance_to(point) < 0.00001 and end.distance_to(start) < 0.00001
			var outgoing := (OffWorkIconMotion.source_uv(kind, point, epsilon) - start) / epsilon
			var incoming := (end - OffWorkIconMotion.source_uv(kind, point, duration - epsilon)) / epsilon
			velocity_closed = velocity_closed and outgoing.distance_to(incoming) < 0.015
			# Detect folds and duplicate-outline risks in overlapping local joints.
			for phase in range(16):
				var seconds := duration * float(phase) / 16.0
				var origin := OffWorkIconMotion.source_uv(kind, point, seconds)
				var dx := (OffWorkIconMotion.source_uv(kind, point + Vector2(0.0005, 0.0), seconds) - origin) / 0.0005
				var dy := (OffWorkIconMotion.source_uv(kind, point + Vector2(0.0, 0.0005), seconds) - origin) / 0.0005
				min_determinant = minf(min_determinant, dx.cross(dy))
			var previous := start
			for sample in range(1, ceili(duration * 60.0) + 1):
				var current := OffWorkIconMotion.source_uv(kind, point, minf(float(sample) / 60.0, duration))
				moving = moving or current.distance_to(point) > 0.0001
				finite = finite and is_finite(current.x) and is_finite(current.y)
				max_step = maxf(max_step, current.distance_to(previous))
				previous = current
	_check(closed, "%s loop returns to identical master coordinates" % kind)
	_check(velocity_closed, "%s loop boundary has no velocity discontinuity" % kind)
	_check(finite and moving and max_step < 0.05, "%s has actual bounded continuous motion, not duplicate holds" % kind)
	_check(min_determinant > 0.05, "%s local mapping never folds or collapses (minimum determinant %.4f)" % [kind, min_determinant])

func _card(kind: String) -> OffWorkCard:
	var card := OffWorkCard.new()
	stage.add_child(card)
	card.configure({"id": views.size(), "type": kind, "owner": 0, "group": views.size(), "activity": "idle", "status": "ready", "progress": 0.0}, config.cards[kind])
	card.freeze = true
	card.set_process(false)
	views.append(card)
	return card

func _find(kind: String) -> OffWorkCard:
	for card in views:
		if card.type == kind: return card
	return null

func _record(card: OffWorkCard, activity: String, progress: float, stopped := false) -> Dictionary:
	return {"id": card.uid, "type": card.type, "owner": 0, "group": card.group_id, "activity": activity, "status": "ready", "progress": progress, "paused": stopped, "rate_multiplier": 1.0}
