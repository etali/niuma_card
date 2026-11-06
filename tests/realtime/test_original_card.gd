extends SceneTree

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)

func _run() -> void:
	var config := WorkConfig.new()
	WorkCardDB.configure(config)
	var stage := Node3D.new()
	root.add_child(stage)
	var cards: Array[WorkCard] = []
	var id := 0
	for kind in config.cards:
		var card := WorkCard.new()
		stage.add_child(card)
		card.configure({"id": id, "type": kind, "owner": 0, "group": id,
			"status": "ready", "activity": "work", "progress": 0.5}, config.cards[kind])
		card.freeze = true
		cards.append(card)
		id += 1
		check(card is CardEntity and card is RigidBody3D, "%s retains original rigid card" % kind)
		check(card.label.text == config.cards[kind].name, "%s original title" % kind)
		check(card._plate.mesh.size == CardArt.FRAME_SIZE, "%s original frame dimensions" % kind)
		check(card._plate.material_override.shader.resource_path == CardEntity.PLATE_SHADER, "%s original plate shader" % kind)
		check(card.get_node_or_null("CardVisual/RealtimeLayers") != null, "%s added layers live inside original visual" % kind)
		check(CardArt.illustration_texture(str(kind), WorkCardDB) != null or CardArt.icon_texture(str(kind), WorkCardDB) != null, "%s has original-compatible illustration or icon" % kind)
		check(card.card_mesh.mesh.size.y == CardEntity.CARD_SIZE.y, "%s original body/collision thickness" % kind)
		check(not card.has_recipe_badge() and not card.has_effect_badge() and card._badge_icons.is_empty(), "%s has no lower corner badges" % kind)
		var labels := card._realtime.find_children("*", "Label3D", true, false)
		check(labels.size() == 1 and labels[0] == card._debug_timer and not card._debug_timer.visible,
			"%s only exposes a timer when debug mode is enabled" % kind)
		if config.category(str(kind)) == "person":
			check(not card._task_progress.visible and is_equal_approx(card._task_progress_value, 0.5), "%s retains shared work value but leaves the single combination bar to Board" % kind)
			var bar_top: float = card._realtime.position.y + card._task_progress.position.y * card._realtime.scale.y
			check(bar_top <= CardEntity.Y_OVERLAY + 0.000001, "%s truthful overlay cannot bleed through the next stack card" % kind)
		check(card._icon.visible and card._realtime.find_children("*", "Sprite3D", true, false).is_empty(), "%s uses one complete original-player illustration without rig fragments" % kind)
		check(is_equal_approx(card._icon.position.x, 0.0) and is_equal_approx(card._icon.position.z / CardEntity.CARD_SIZE.z + 0.5, WorkUI.number("frame", "art_cy")), "%s illustration is centered independently of the removed badges" % kind)
		check(is_equal_approx(card._icon.pixel_size * card._icon.texture.get_width(), CardEntity.CARD_SIZE.x * WorkUI.number("frame", "art_width") * float(WorkUI.section("frame").art_scale_by_type.get(kind, 1.0))), "%s illustration follows configurable card-specific width" % kind)
	var worker := cards[config.cards.keys().find("employee")]
	var leader := cards[config.cards.keys().find("leader")]
	leader._process(0.037)
	check(leader._icon.visible and leader._hover_original == CardArt.illustration_texture("leader", WorkCardDB), "leader retains its own complete leadership illustration")
	check(not leader.illustration_is_active(), "leader never auto-works even if a stale record claims ordinary work")
	check(not WorkCardDB.get_def("leader").has("recipe_res") and not WorkCardDB.get_def("leader").has("output_n"), "leader advertises no work-to-money recipe")
	check(WorkCardDB.pawn_value("leader") == config.cards.leader.refund, "leader retains original resale presentation")
	check(not WorkCardDB.all_cards().has("fire") and not WorkUI.section("card_plates").has("fire"), "dismissal has no card or palette entry")
	worker.set_recipe_progress(24, true)
	check(worker.recipe_progress_text().is_empty(), "original Board recipe updates cannot recreate removed corner text")
	var money := cards[config.cards.keys().find("money")]
	var cash_icon: Texture2D = load("res://assets/art/icon/icon_cash.png")
	check(money._icon.texture == cash_icon, "money card uses the original cash PNG, not a new money bag")
	check(CardArt.icon_texture("money", WorkCardDB) == cash_icon and CardArt.res_icon_texture(WorkCardDB.RES_CASH, WorkCardDB) == cash_icon, "cash side-list and price-tag resource lookup share the original icon")
	check(CardArt.illustration_texture("money", WorkCardDB) == null, "cash uses the original icon fallback rather than an unrelated illustration")
	check(CardArt.hover_config(CardArt.source_art_id("money", WorkCardDB)) == UIConfig.read_section("art").hover.cards.cash, "money shares the original cash hover registration")
	check(CardArt.icon_tint(cash_icon, Color.RED) == Color.WHITE, "cash icon keeps original paper-and-ink colors")
	var side := Board.side_spec([money])
	check(side.size() == 1 and side[0].tex == cash_icon, "original Board cash side list renders the original icon")
	check(worker._badge_labels.is_empty(), "worker face contains no effect/recipe text or connecting arrow")

	money.update_record({"id": money.uid, "type": "money", "amount": 8, "group": money.group_id})
	check(money._badge_labels.is_empty(), "cash face has no amount badge below its original icon")
	money.update_record({"id": money.uid, "type": "money", "amount": 12, "group": money.group_id})
	check(money._badge_labels.is_empty() and int(money.record.amount) == 12, "cash changes preserve real amount without recreating its removed badge")
	worker.set_hover_visual(true)
	check(worker.is_processing(), "hover does not stop full-frame task animation")
	worker.set_drag_visual(true)
	worker.update_drag_motion(Vector3(20, 0, -15), 0.1)
	check(worker._visual.rotation.length() > 0.0, "original drag tilt responds to pointer velocity")
	worker.set_drag_visual(false)
	worker.set_hover_visual(false)
	check(worker.is_processing(), "ending hover/drag does not stop full-frame task animation")
	worker.play_event("work_complete")
	check(worker.stamp_text() == WorkUI.section("rig").stamp_word, "completion uses original InkStamp")
	var evaluation := WorkComboRules.evaluate([
		{"uid": 1, "def_id": "employee"}, {"uid": 2, "def_id": "leader"},
		{"uid": 3, "def_id": "work"}, {"uid": 4, "def_id": "work"}])
	check(evaluation.valid and evaluation.output_n == int(config.cards.work.income), "mixed group only advertises the actual worker's production")
	var no_worker := WorkComboRules.evaluate([{"uid": 1, "def_id": "leader"}, {"uid": 2, "def_id": "work"}])
	check(not no_worker.valid and int(no_worker.output_n) == 0, "leader and work alone never advertise a valid production group")
	check(WorkCardDB.RES_CASH == "money" and WorkCardDB.RES_USER == "work", "original board resources map to new cards")
	check(WorkCardDB.sfx_rules() == UIConfig.read_section("sfx"), "original audio config is retained")
	check(WorkCardDB.game_rules().market_size == config.rules.conveyor.slots, "original market geometry follows configured conveyor size")
	var instance := worker.get_instance_id()
	var visual_count := worker._visual.get_child_count()
	var child_count := worker.get_child_count()
	var bar := worker._task_progress
	worker.update_record({"id": worker.uid, "type": "grinder", "owner": 0, "group": worker.group_id,
		"status": "ready", "activity": "work", "progress": 0.45, "paused": true})
	check(worker.get_instance_id() == instance and worker.def_id == "grinder" and worker.type == "grinder", "upgrade refreshes the same original physics card and pointer identity")
	check(worker.label.text == config.cards.grinder.name and worker._icon.texture == CardArt.illustration_texture("grinder", WorkCardDB), "upgraded employee exposes the new title and character art")
	check(worker._task_progress == bar and is_equal_approx(worker._task_progress_value, 0.45) and worker._task_progress_paused, "upgrade retains current task progress and meeting pause")
	check(worker.get_child_count() == child_count and worker._visual.get_child_count() == visual_count, "identity refresh creates no duplicate collider or visual layers")
	worker.play_event("coffee_upgrade")
	worker._process(WorkUI.number("upgrade", "duration_seconds") * 0.4)
	check(worker.stamp_text() == config.cards.grinder.name and worker._upgrade_ring.visible and worker._icon.scale.x > 1.0, "coffee upgrade uses the original stamp with a visible ring and character response")
	check(is_equal_approx(worker.task_progress_display_value(), 0.45), "upgrade animation cannot fake a completed work bar")
	worker._process(WorkUI.number("upgrade", "duration_seconds"))
	check(not worker._upgrade_ring.visible and worker._icon.scale == Vector3.ONE, "upgrade visual settles without replacing the card or leaving an overlay")
	var overtime := cards[config.cards.keys().find("overtime")]
	check(overtime._realtime.get_child_count() == 1 and not overtime._task_progress.visible, "permanent overtime has no fake duration graphics")
	check(config.category("coffee") == "ingredient" and WorkCardDB.get_def("coffee").kind == WorkCardDB.KIND_SPECIAL, "coffee is displayed as an upgrade ingredient rather than a buff")
	worker.play_event("coffee_upgrade")
	worker.leave()
	check(not worker._upgrade_ring.visible and not worker._task_progress.visible, "finishing during upgrade clears transient upgrade graphics")
	await process_frame
	stage.queue_free()
	await process_frame
	if failures.is_empty(): print("ORIGINAL_CARD PASS (%d checks)" % checks)
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
