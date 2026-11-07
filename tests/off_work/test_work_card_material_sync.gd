extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func record(kind := "employee", activity := "work", paused := false) -> Dictionary:
	return {"id": 1, "type": kind, "owner": 0, "group": 1, "status": "ready", "activity": activity, "paused": paused, "progress": 0.2}

func _run() -> void:
	var config := OffWorkConfig.new()
	OffWorkCardDB.configure(config)
	var stage := Node3D.new()
	root.add_child(stage)
	var card := OffWorkCard.new()
	stage.add_child(card)
	card.configure(record(), config.cards.employee)
	card.freeze = true
	card.set_process(false)
	card._process(0.125)
	var elapsed := card.illustration_time()
	check(is_equal_approx(elapsed, 0.125), "working illustration advances its exact fractional clock")
	card._visual.hide()
	card._process(0.25)
	check(is_equal_approx(card.illustration_time(), elapsed + 0.25), "covered personnel keep advancing rather than freezing until revealed")
	check(is_equal_approx(float(card._motion_material.get_shader_parameter("motion_seconds")), card.illustration_time()), "covered worker still owns its truthful shader clock")
	card._visual.show()
	check(is_equal_approx(float(card._motion_material.get_shader_parameter("motion_seconds")), card.illustration_time()), "revealing a card needs no stale-frame catch-up")
	card.update_record(record("employee", "work", true))
	elapsed = card.illustration_time()
	card._process(0.5)
	check(card.illustration_time() == elapsed, "logical meeting pause still freezes even after the visibility fast path")

	# Native hover/face routines may clear the override while input values are
	# unchanged. Reattach the original material/master before the cache return.
	var master := card._hover_original
	card._icon.texture = CardArt.illustration_texture("coffee", OffWorkCardDB)
	card._icon.material_override = null
	card._process(0.0)
	check(card._icon.texture == master and card._icon.material_override == card._motion_material, "unchanged appearance restores an externally cleared material and texture")
	card._icon.modulate = Color(0.3, 0.6, 0.8, 0.4)
	card._process(0.0)
	check(card._motion_material.get_shader_parameter("motion_tint") == card._icon.modulate, "dimming and opacity upload while the motion clock is paused")
	card.refresh_palette()
	check(card._motion_material.get_shader_parameter("motion_tint") == card._icon.modulate, "palette refresh synchronizes immediately without an animation tick")

	card.seek_hover_animation(0.123456)
	check(is_equal_approx(card.illustration_time(), 0.123456) and is_equal_approx(float(card._motion_material.get_shader_parameter("motion_seconds")), 0.123456), "manual seeks immediately upload sub-frame time")
	var preview := card.make_illustration_preview_material()
	check(is_equal_approx(float(preview.get_shader_parameter("motion_seconds")), card.illustration_time()), "magnifier retains the same exact source clock")
	card._icon.modulate.a = 0.27
	card.sync_illustration_preview_material(preview)
	check(preview.get_shader_parameter("motion_tint") == card._icon.modulate, "canvas adapter does not inherit a stale production-material cache")

	var previous_material := card._motion_material
	card.update_record(record("grinder", "work", true))
	check(card._motion_material != previous_material and card._motion_material.get_meta("work_motion_kind") == "grinder", "role upgrades invalidate material identity and profile together")
	check(card._motion_material.get_shader_parameter("art_texture") == CardArt.illustration_texture("grinder", OffWorkCardDB), "role upgrades immediately install the new master texture")
	card.set_strike_participant(true)
	check(card._motion_material.get_meta("work_motion_kind") == "striking/grinder", "switching to dance updates a profile even when time stays zero")
	card._visual.hide()
	card._process(0.3)
	check(card.illustration_time() > 0.0, "covered striking staff still dance on their own clock")
	card.set_strike_participant(false)
	check(card._motion_material.get_meta("work_motion_kind") == "grinder" and card.illustration_time() == 0.0, "dance expiry returns to the normal profile and initial pose")
	card.update_record(record("grinder", "work", false))
	card.set_task_progress(0.25, true)
	check(card._task_progress.visible and is_equal_approx(float(card._task_progress_material.get_shader_parameter("progress")), 0.25), "visible task surface receives the current progress")
	card.set_meeting_participant(true)
	card.set_task_progress(0.6, true, true, "coffee")
	check(not card._task_progress.visible and is_equal_approx(card.task_progress_display_value(), 0.6), "hidden task surface retains truthful logical progress")
	check(is_equal_approx(float(card._task_progress_material.get_shader_parameter("progress")), 0.25), "hidden task surface skips redundant shader uploads")
	card.set_debug_timer(true, 4.0)
	check(card._debug_timer.visible and not card._debug_timer.is_visible_in_tree() and card._debug_timer.text.contains("4.0"), "hidden task keeps Debug current beneath its hidden parent")
	card.set_meeting_participant(false)
	check(card._task_progress.visible and is_equal_approx(float(card._task_progress_material.get_shader_parameter("progress")), 0.6) and card._task_progress_material.get_shader_parameter("fill_color") == Palette.semantic(str(OffWorkUI.section("task_progress").paused_color)), "revealing a task immediately restores current progress and phase color")
	card._retired = true
	card._icon.modulate.a = 0.12
	card._process(0.0)
	check(is_equal_approx(float((card._motion_material.get_shader_parameter("motion_tint") as Color).a), 0.12), "retired cards still synchronize the final fade")

	stage.queue_free()
	await process_frame
	for failure in failures: printerr("FAIL ", failure)
	print("WORK_CARD_MATERIAL_SYNC %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
