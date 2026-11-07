extends SceneTree

const View = preload("res://scenes/off_work_pile_extract_view.gd")
var checks := 0
var failures: Array[String] = []
var extracted: Array = []
var view: Control
var state: OffWorkState

func _initialize() -> void: _run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func rows(group: int) -> Array:
	return state.group_cards(group).map(func(id): return state.cards[id].duplicate(true))

func press(at: Vector2, down := true) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	view.handle_pointer_event(event)

func move(at: Vector2, held := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	view.handle_pointer_event(event)

func _run() -> void:
	root.size = Vector2i(1100, 720)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 200, "employee": 5, "overtime": 2}]
	config.rules.bot.enabled = false
	OffWorkCardDB.configure(config)
	state = OffWorkState.new(config)
	state.new_game()
	var employee := -1
	for uid in state.cards:
		if int(state.cards[uid].owner) == 0 and state.cards[uid].type == "employee":
			employee = int(uid)
			break
	var group: int = int(state.cards[employee].group)
	var all_ids := state.group_cards(group).duplicate()
	var spec: Dictionary = UIConfig.read_section("board").side_extract
	var layer := CanvasLayer.new()
	root.add_child(layer)
	view = View.new()
	layer.add_child(view)
	view.configure(spec)
	view.extract_requested.connect(func(ids, _at): extracted = ids)
	view.show_cards(group, "employee", rows(group), config.cards, Vector2(900, 680))
	await process_frame
	var opening: Vector2 = view._card_rects[0].get_center()
	view._process(float(spec.open_seconds) + float(spec.stagger_seconds) + 0.2)
	check(opening.distance_to(view._card_rects[0].get_center()) > 1.0, "opening glides card faces outward rather than appearing instantly")
	check(view.find_children("*", "Panel", true, false).is_empty() and view.find_children("*", "Label", true, false).is_empty(), "no backing, title, footer, count input or close-button chrome")
	check(view.is_open() and view.records.size() == 5 and view.preview_cards.size() == 5, "five personnel show as five original card fronts")
	check(root.get_visible_rect().encloses(view.get_global_rect()), "anchored popup stays inside the viewport")
	check(view.preview_cards.all(func(card): return not card.card_mesh.visible and not card.input_ray_pickable and card.collision_layer == 0), "inspection hides dark bodies and owns no physical collisions")
	check(view.preview_cards.all(func(card): return card._plate.material_override.shader == preload("res://shaders/card_face.gdshader")), "inspection uses the original frame shader")
	var point: Vector2 = view.screen_point_for_index(2)
	check(view.index_at_screen_point(point) == 2, "exposed middle personnel is independently hittable")
	press(point)
	press(point, false)
	check(extracted.is_empty() and view.is_open(), "a click never extracts or rearranges the logical group")
	press(point)
	move(point + Vector2(float(spec.drag_threshold) + 1, 0), true)
	check(extracted == all_ids.filter(func(uid): return state.cards[uid].type == "employee").slice(2), "dragging middle emits only the matching real suffix")
	check(not view.is_open() and state.group_cards(group) == all_ids, "view closes on transfer of drag ownership without modifying OffWorkState")
	extracted.clear()
	view.show_cards(group, "work", rows(group), config.cards, Vector2(150, 200))
	check(view.records.size() == 200 and view.preview_cards.size() <= int(spec.max_render_cards), "all 200 UIDs retained while drawing cost and geometry remain bounded")
	view._process(0.6)
	check(view._view_rect.size.y <= float(spec.max_height) + 1.0, "large column has bounded height")
	point = view.screen_point_for_index(100)
	move(point)
	check(view.focus_index >= 99 and view.focus_index <= 100, "pointer at middle maps to middle of the full 200-card stack")
	check(view.rendered_indices.has(view.focus_index - 1) and view.rendered_indices.has(view.focus_index + 1), "hover opens adjacent real cards around the chosen position")
	check(view.index_at_screen_point(point) == view.focus_index, "local spread leaves the logical cut stable under a stationary pointer")
	var pool_ids: Array = (view.preview_cards + view._spare_cards).map(func(card): return card.get_instance_id())
	for sample in [10, 60, 110, 160, 195, 100]:
		move(view.screen_point_for_index(sample))
		view._process(0.08)
	check((view.preview_cards + view._spare_cards).all(func(card): return pool_ids.has(card.get_instance_id())), "sweeping dense cards reuses existing faces without frame-by-frame creation or disposal")
	var chosen: int = view.focus_index
	press(point)
	move(point + Vector2(0, float(spec.drag_threshold) + 1), true)
	check(extracted.size() == 200 - chosen and extracted.all(func(uid): return state.cards[uid].type == "work"), "large-fan drag emits real selected work cards, no personnel or tools")
	view.show_cards(group, "employee", rows(group).filter(func(data): return data.id == employee), config.cards, Vector2.ZERO)
	check(view.records.size() == 1 and view.preview_cards.size() == 1, "a lone personnel remains available in the fan")
	view._process(0.6)
	point = view.screen_point_for_index(0)
	press(point)
	move(point + Vector2(float(spec.drag_threshold) + 1, 0), true)
	check(extracted == [employee], "one-card fan can hand off a single real personnel")
	view.show_cards(group, "work", rows(group), config.cards, Vector2(100, 300))
	state.advance(1.0)
	view.update_cards(rows(group))
	check(state.group_work_progress(group) > 0.0 and state.group_cards(group) == all_ids, "inspection leaves the production clock running and preserves composition")
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	check(view.handle_pointer_event(escape) and not view.is_open(), "Escape closes without touching the group")
	view.show_cards(group, "work", rows(group), config.cards, Vector2(100, 300))
	press(Vector2(1090, 10))
	check(not view.is_open(), "outside press closes without forwarding an accidental pickup")
	view.show_cards(group, "work", rows(group), config.cards, Vector2(100, 300))
	view.update_cards([])
	check(not view.is_open(), "consumed or removed source cards close the view")
	if OS.has_environment("WORK_EXTRACT_SHOT") and DisplayServer.get_name() != "headless":
		view.show_cards(group, "work", rows(group), config.cards, Vector2(150, 330))
		view._process(0.6)
		move(view.screen_point_for_index(100))
		await process_frame
		await process_frame
		await create_timer(0.3).timeout
		RenderingServer.force_draw(false)
		root.get_texture().get_image().save_png(OS.get_environment("WORK_EXTRACT_SHOT"))
	view.close_view()
	layer.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("SIDE_EXTRACT_VIEW %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)
