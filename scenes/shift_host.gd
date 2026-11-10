# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Node
## Each table owns its world, GUI focus and input routing. Only the visible table
## can push pixels or pointer events to the native window.
const Slots = preload("res://engine/shift_slot.gd")
const MODE_PREFERENCE := "last_mode"
const Door = preload("res://scenes/shift_door.gd")
const Choreography = preload("res://scenes/shift_choreography.gd")
const Backdrop = preload("res://scenes/table_backdrop.gd")
const Boot = preload("res://scenes/boot.gd")
const Setup = preload("res://scenes/table_setup.gd")

const SCENES := Boot.TABLE_SCENES
var active := 0
var tables: Array[Node] = [null,null]
var views: Array[SubViewportContainer] = [null,null]
var title_slots: Array[Label] = [null, null]
var sign: BaseButton
var backdrop: Node3D
var display := TextureRect.new()
var paused := [false,false]
var frozen_nodes := [{},{}]
var frozen_tweens := [[],[]]
var switching := false
var _handoff_drawer: DrawerWindow
var remember := true
var first_intro := false
var off_work_playtest := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	display.name = "TableDisplay"
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(display)
	display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var args := LaunchConfig.desktop_args()
	off_work_playtest = args.has("--off-work-playtest")
	remember = remembers_mode(args)
	var preference := Boot.starting_mode(args)
	active = maxi(0, preference)
	first_intro = preference < 0
	if first_intro: Slots.save(MODE_PREFERENCE, {"mode": active})
	var first := await Boot.packed_scene(get_tree(), SCENES[active])
	await _create_table(active, first, not remember)
	_install_door(active, tables[active])
	await _present(active)
	_block_input(active, false)
	if DisplayServer.get_name() != "headless":
		# Load the alternate scene's dependencies without starting its game,
		# changing either drawer or claiming the shared backdrop.
		Boot.request_scene(SCENES[1 - active])

func _may_warm_table_effects() -> bool:
	# OpenGL compiles on the render thread. Leave the interval where the
	# player is moving cards, opening the drawer or turning the sign to play.
	if switching or not is_instance_valid(tables[active]) or display.texture == null:
		return false
	var drawer := _drawer(tables[active])
	return drawer != null and not drawer.is_expanded() and not drawer.is_transitioning()

static func remembers_mode(args: PackedStringArray) -> bool:
	return Boot.remembers_mode(args)

func _create_table(mode: int, scene: PackedScene, entering := false) -> void:
	var surface := SubViewportContainer.new()
	surface.name = "OnDuty" if mode == 0 else "OffDuty"
	add_child(surface)
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	surface.stretch = true
	# Input/focus is routed by the engine; one persistent native canvas displays
	# the last fully rendered table, including while a new viewport warms up.
	surface.self_modulate.a = 0.0
	var viewport := SubViewport.new()
	viewport.name = "TableView"
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.audio_listener_enable_2d = true
	viewport.audio_listener_enable_3d = true
	surface.add_child(viewport)
	views[mode] = surface
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.child_entered_tree.connect(func(node: Node):
		# Opening a replay replaces the upper table inside this same viewport.
		if node.scene_file_path == SCENES[mode]:
			node.set_meta("acquire_table_backdrop", _mount_backdrop)
			if is_instance_valid(_handoff_drawer): node.set_meta("previous_drawer", _handoff_drawer)
			if not node.has_meta("shift_session_enabled"):
				node.set_meta("shift_session_enabled",remember)
				node.set_meta("shift_enter_expanded",true)
			tables[mode] = node
			_install_door.call_deferred(mode,node))
	var game: Node = scene.instantiate()
	game.process_mode = Node.PROCESS_MODE_PAUSABLE
	var staged: Setup
	if DisplayServer.get_name() != "headless":
		staged = Setup.new()
		game.set_meta("shift_setup", staged)
		viewport.gui_disable_input = true
	game.set_meta("may_warm_table_effects", _may_warm_table_effects)
	game.set_meta("shift_session_enabled",remember)
	game.set_meta("shift_enter_expanded",entering)
	if mode == 1: game.set_meta("read_playtest_cards",off_work_playtest)
	if mode == 0 and DisplayServer.get_name() == "headless": game.force_drawer_layout = true
	viewport.add_child(game)
	if staged and not staged.complete: await staged.finished

func _install_door(mode: int, game: Node) -> void:
	if not is_instance_valid(game) or tables[mode] != game: return
	if game.has_meta("shift_setup"): return
	if is_instance_valid(title_slots[mode]): return
	var presentation: Node = game.drawer_presentation
	var title: Label
	if presentation != null:
		title = presentation._title_row.get_child(1) as Label
	if title == null:
		var layer := CanvasLayer.new()
		layer.layer = 8
		game.add_child(layer)
		title = Label.new()
		title.text = "牛马牌"
		title.add_theme_font_size_override("font_size",24)
		layer.add_child(title)
		title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP,Control.PRESET_MODE_MINSIZE)
	title_slots[mode] = title
	if active == mode:
		_show_sign(mode)

func _show_sign(mode: int) -> void:
	if not is_instance_valid(sign):
		sign = Door.new()
		sign.shift_requested.connect(func(): switch_mode(1 - active))
		sign.hint_available = _shift_hint_available
	sign.bind(title_slots[mode], mode == 0, first_intro)
	first_intro = false

func _shift_hint_available() -> bool:
	if switching or not is_instance_valid(tables[active]): return false
	var presentation: Node = tables[active].drawer_presentation
	if presentation == null: return true
	var drawer := _drawer(tables[active])
	if drawer and (not drawer.is_expanded() or drawer.is_transitioning()): return false
	return not presentation.is_learning_invitation_open() and not presentation.panels_open()

func _mount_backdrop(game: Node3D, fitted: bool) -> Node3D:
	if not is_instance_valid(backdrop):
		backdrop = Backdrop.new()
		game.add_child(backdrop)
		backdrop.build(fitted)
	elif backdrop.get_parent() != game:
		backdrop.reparent(game, false)
	return backdrop

func _set_surface(mode: int, visible: bool) -> void:
	var surface := views[mode]
	var viewport := surface.get_child(0) as SubViewport
	surface.visible = visible
	surface.set_process_input(visible)
	surface.set_process_unhandled_input(visible)
	viewport.gui_disable_input = not visible
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if visible else SubViewport.UPDATE_DISABLED
	viewport.audio_listener_enable_2d = visible
	viewport.audio_listener_enable_3d = visible
	if not visible: viewport.gui_release_focus()

func _present(mode: int) -> void:
	# Textures are allocated before the first draw. Keep the previous completed
	# frame on screen until the new camera, cloth and deck have reached the GPU.
	if DisplayServer.get_name() != "headless":
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	display.texture = (views[mode].get_child(0) as SubViewport).get_texture()

func _freeze(node: Node, mode: int, top: bool = false) -> void:
	# Drawer controls, table hands and pause UI explicitly run during a normal
	# game pause. Freeze their overrides too, then restore exactly what they used.
	if node == sign: return
	if top or node.process_mode != Node.PROCESS_MODE_INHERIT:
		frozen_nodes[mode][node.get_instance_id()] = node.process_mode
		node.process_mode = Node.PROCESS_MODE_DISABLED
	for child in node.get_children(): _freeze(child,mode)

func _thaw(mode: int) -> void:
	for id in frozen_nodes[mode]:
		if is_instance_id_valid(id):
			var node := instance_from_id(id) as Node
			node.process_mode = frozen_nodes[mode][id]
	frozen_nodes[mode].clear()
	for tween: Tween in frozen_tweens[mode]:
		if tween.is_valid(): tween.play()
	frozen_tweens[mode].clear()

func _drawer(game: Node) -> DrawerWindow:
	return game.drawer_presentation._main.drawer_window if game.drawer_presentation else null

func _network_live(game: Node) -> bool:
	return is_instance_valid(game) and game.has_method("shift_network_live") and game.shift_network_live()

func _suspend(mode: int) -> void:
	var game := tables[mode]
	var drawer := _drawer(game)
	if drawer: drawer.set_shift_active(false)
	game.set_shift_hidden(true)
	if _network_live(game):
		game.process_mode = Node.PROCESS_MODE_ALWAYS
		if drawer: _freeze(drawer, mode, true)
		if game.table_hands: _freeze(game.table_hands, mode, true)
	else:
		_freeze(game, mode, true)
		if not _network_live(tables[1 - mode]):
			for tween in get_tree().get_processed_tweens():
				if tween.is_running():
					tween.pause()
					frozen_tweens[mode].append(tween)

func _block_input(mode: int, blocked: bool) -> void:
	var viewport := views[mode].get_child(0) as SubViewport
	viewport.gui_disable_input = blocked
	if blocked: viewport.gui_release_focus()

func switch_mode(next: int) -> void:
	if switching or next == active or next not in [0, 1]: return
	switching = true
	if views[next] == null and DisplayServer.get_name() != "headless":
		Boot.request_scene(SCENES[next])
	var previous := active
	var old := tables[previous]
	old.save_shift_session()
	paused[previous] = get_tree().paused
	_handoff_drawer = _drawer(old)
	_block_input(previous, true)
	_suspend(previous)
	var leaving := Choreography.new()
	leaving.capture(old)
	var gather := create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	gather.tween_method(func(t: float): leaving.pose(t, 0.0), 0.0, 1.0, 0.24)
	gather.tween_method(func(t: float):
		leaving.pose(1.0, t)
		sign.set_turn(t * PI * 0.5), 0.0, 1.0, 0.21).set_trans(Tween.TRANS_SINE)
	await gather.finished
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		# Keep the last rendered GPU texture at its current size until the next
		# viewport presents. A full-window GPU readback stalls this handoff.
		views[previous].stretch = false
	_set_surface(previous, false)
	leaving.restore()

	active = next
	get_tree().paused = paused[next]
	if views[next] == null:
		var scene := await Boot.packed_scene(get_tree(), SCENES[next])
		await _create_table(next, scene, true)
		_suspend(next)
	else:
		_mount_backdrop(tables[next], true)
		views[next].stretch = true
		_set_surface(next, true)
	var game := tables[next]
	var drawer := _drawer(game)
	if drawer and _handoff_drawer: drawer.take_window_layout(_handoff_drawer)
	_handoff_drawer = null
	var previous_ui: Node = old.drawer_presentation
	var current_ui: Node = game.drawer_presentation
	if previous_ui and current_ui:
		current_ui.perspective_angle = previous_ui.perspective_angle
		current_ui.camera_view.zoom = previous_ui.camera_view.zoom
		current_ui.camera_view.offset = previous_ui.camera_view.offset
		current_ui.relayout()
	_block_input(next, true)
	if not is_instance_valid(title_slots[next]): _install_door(next, game)
	else: _show_sign(next)
	sign.set_turn(-PI * 0.5)
	var arriving := Choreography.new()
	arriving.capture(game, leaving.deck)
	arriving.pose(1.0, 1.0)
	await _present(next)
	var deal := create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	deal.tween_method(func(t: float):
		arriving.pose(1.0, 1.0 - t)
		sign.set_turn((t - 1.0) * PI * 0.5), 0.0, 1.0, 0.19).set_trans(Tween.TRANS_SINE)
	deal.tween_method(arriving.deck.turn, 0.0, 1.0, 0.23).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	deal.tween_method(func(t: float): arriving.pose(t, 0.0), 1.0, 0.0, 0.25)
	await deal.finished
	arriving.restore()
	arriving.deck.queue_free()
	_thaw(next)
	game.process_mode = Node.PROCESS_MODE_PAUSABLE
	if drawer: drawer.set_shift_active(true)
	game.set_shift_hidden(false)
	_block_input(next, false)
	if remember: Slots.save(MODE_PREFERENCE, {"mode": active})
	switching = false
