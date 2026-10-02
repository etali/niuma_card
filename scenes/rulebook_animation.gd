# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends VBoxContainer

const DemoData = preload("res://scenes/rulebook_demo_data.gd")
const Arena = preload("res://scenes/rulebook_arena.gd")

var examples: Array = []
var selected := 0
var playing := true
var _presentation: Node
var _viewport: SubViewport
var _container: SubViewportContainer
var _stage: Node3D
var _caption: Label
var _play: Button
var _choice: OptionButton
var _comparisons: HBoxContainer
var _last_fit_size := Vector2.ZERO
var _last_fit_angle := -1.0
var _progress: ProgressBar
var progress: float:
	get: return _stage.progress if is_instance_valid(_stage) else 0.0

func bind(presentation: Node, section: String) -> void:
	_presentation = presentation
	name = "AnimatedDemo"
	examples = DemoData.examples(section)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	var controls := HBoxContainer.new()
	controls.add_theme_constant_override("separation", 8)
	add_child(controls)
	_choice = OptionButton.new()
	_choice.name = "DemoExample"
	_choice.fit_to_longest_item = false
	_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for example in examples:
		_choice.add_item(example["title"])
	_choice.item_selected.connect(select_example)
	controls.add_child(_choice)
	_play = presentation._button("暂停", 15, true)
	_play.pressed.connect(func():
		if not playing and progress >= 1.0:
			select_example(selected)
		else:
			set_playing(not playing))
	controls.add_child(_play)
	var again: Button = presentation._button("重播", 15, true)
	again.pressed.connect(func(): select_example(selected))
	controls.add_child(again)
	_comparisons = HBoxContainer.new()
	_comparisons.name = "UpgradeComparisons"
	_comparisons.add_theme_constant_override("separation", 8)
	add_child(_comparisons)
	_container = SubViewportContainer.new()
	_container.name = "RealTableDemo"
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_container.custom_minimum_size = Vector2(0, 300)
	_container.set_meta("drawer_min_base", Vector2(0, 300))
	_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.handle_input_locally = true
	_viewport.gui_disable_input = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_viewport.size = Vector2i(720, 320)
	_container.add_child(_viewport)
	_viewport.size_changed.connect(_fit_camera)
	_container.resized.connect(_fit_camera)
	call_deferred("_fit_camera")
	_progress = ProgressBar.new()
	_progress.show_percentage = false
	_progress.max_value = 1.0
	_progress.step = 0.001
	add_child(_progress)
	_caption = presentation._label("", 17)
	_caption.name = "DemoCaption"
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.custom_minimum_size.y = 48
	_caption.set_meta("drawer_min_base", Vector2(0, 48))
	add_child(_caption)
	visibility_changed.connect(_sync_processing)
	select_example(0)

func select_example(index: int) -> void:
	if examples.is_empty():
		return
	selected = clampi(index, 0, examples.size() - 1)
	_choice.select(selected)
	if is_instance_valid(_stage):
		_viewport.remove_child(_stage)
		_stage.free()
	_last_fit_size = Vector2.ZERO
	_stage = Arena.new()
	_viewport.add_child(_stage)
	_stage.replay_requested.connect(func(): select_example.call_deferred(selected))
	_stage.result_styler = _presentation._apply_tree_theme
	_stage.configure(examples[selected], _presentation._main.sfx)
	for child in _comparisons.get_children():
		_comparisons.remove_child(child)
		child.queue_free()
	var variants: Array = examples[selected].get("variants", [])
	_comparisons.visible = not variants.is_empty()
	for variant in variants:
		var cell: Label = _presentation._label("%s ×%d → %s\n%s" % [variant.get("material_label", "同名"), variant["count"],
			CardDB.card_name(variant["target_id"]), variant["description"]], 15)
		cell.name = "Upgrade_%d" % int(variant["count"])
		cell.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_comparisons.add_child(cell)
	_presentation._apply_tree_theme(_comparisons)
	_caption.text = _stage.caption()
	_progress.value = 0
	set_playing(true)
	_fit_camera.call_deferred()

func set_playing(value: bool) -> void:
	playing = value
	_play.text = "暂停" if playing else "播放"
	_sync_processing()

func _sync_processing() -> void:
	if is_instance_valid(_stage):
		_stage.process_mode = Node.PROCESS_MODE_INHERIT if playing and is_visible_in_tree() else Node.PROCESS_MODE_DISABLED

func _fit_camera() -> void:
	if not is_inside_tree() or not is_instance_valid(_viewport) or not is_instance_valid(_stage) or not _stage.is_inside_tree():
		return
	_fit_stage_height()
	# stretch父容器统一管理SubViewport尺寸；在实际尺寸变化后拟合，避免首开旧比例。
	var size := Vector2(_viewport.size)
	var angle: float = _presentation.perspective_angle
	if size == _last_fit_size and is_equal_approx(angle, _last_fit_angle):
		return
	_last_fit_size = size
	_last_fit_angle = angle
	_stage.fit(size, angle)

func _fit_stage_height() -> void:
	var scroll := get_parent().get_parent() as ScrollContainer
	if scroll == null or scroll.size.y <= 0 or not is_instance_valid(_caption):
		return
	var reserved := 0.0
	var visible_count := 0
	for child in get_children():
		if child is Control and child.visible:
			visible_count += 1
			if child != _container:
				reserved += child.get_combined_minimum_size().y
	reserved += get_theme_constant("separation") * maxi(0, visible_count - 1)
	var factor: float = _presentation._responsive_factor()
	var height := maxf(140.0 * factor, scroll.size.y - reserved - 4.0)
	if absf(_container.custom_minimum_size.y - height) > 1.0:
		_container.custom_minimum_size.y = height
		_container.set_meta("drawer_min_base", Vector2(0, height / factor))

func _process(delta: float) -> void:
	if not is_visible_in_tree() or not is_instance_valid(_stage):
		return
	_fit_camera()
	if not playing:
		return
	_stage.advance_time(delta)
	_progress.value = progress
	_caption.text = _stage.caption()
	if progress >= 1.0:
		set_playing(false)
