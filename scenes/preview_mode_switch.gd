# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends HBoxContainer

const ButtonTheme = preload("res://scenes/ui_button_theme.gd")
const ON_WORK := "res://scenes/animation_preview.tscn"
const OFF_WORK := "res://scenes/work_animation_preview.tscn"

static func configure_window(window: Window, title: String, minimum: Vector2i, dimensions: Vector2i) -> void:
	var bootstrap_window := window.size.x <= 64
	window.title = title
	window.transparent = false
	window.transparent_bg = false
	window.borderless = false
	window.always_on_top = false
	window.unresizable = false
	window.content_scale_size = Vector2i.ZERO
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.min_size = minimum
	window.size = dimensions
	if bootstrap_window: window.move_to_center()

signal mode_selected(off_duty: bool)

func _init() -> void:
	name = "PreviewModeSwitch"
	add_theme_constant_override("separation", 8)
	for path: String in [ON_WORK, OFF_WORK]:
		var button := Button.new()
		button.name = "OnWork" if path == ON_WORK else "OffWork"
		button.text = "上班" if path == ON_WORK else "下班"
		button.set_meta("ui_role", "tool")
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_override("font", Fonts.zh())
		ButtonTheme.apply(button, 1.0, 8, 8)
		button.toggle_mode = true
		button.pressed.connect(func(): mode_selected.emit(path == OFF_WORK))
		add_child(button)

func select(off_duty: bool) -> void:
	for button in get_children():
		var selected: bool = (button.name == &"OffWork") == off_duty
		button.set_pressed_no_signal(selected)
		button.set_meta("ui_role", "primary" if selected else "tool")
		ButtonTheme.apply(button, 1.0, 8, 8)
