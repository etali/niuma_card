# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 主操作、工具、危险操作共用按钮几何；角色色只表达操作语义。
static func apply(button: Button, factor := 1.0, margin := 9.0, radius := 10.0) -> void:
	var role := str(button.get_meta("ui_role", "tool"))
	var surface := Palette.semantic("surface", Palette.get_color("world", "table_frame"))
	var ink := Palette.semantic("ink", Palette.get_color("card", "body"))
	var accent := Palette.semantic("primary", Palette.plate_color("plate_cash", "band"))
	if role == "danger":
		accent = Palette.semantic("danger", Color("#B8493E"))
		ink = accent
	elif role == "primary":
		surface = accent
	elif role == "tool":
		accent = Palette.get_color("card", "frame")
	var armed := bool(button.get_meta("danger_armed", false))
	if armed and role == "danger":
		surface = accent
		ink = Palette.readable_ink(Color.WHITE, surface)
	ink = Palette.readable_ink(ink, surface)
	button.add_theme_color_override("font_color", ink)
	button.add_theme_color_override("font_focus_color", ink)
	button.add_theme_color_override("font_hover_color", Palette.readable_ink(ink, surface.lerp(accent, 0.10)))
	button.add_theme_color_override("font_pressed_color", Palette.readable_ink(ink, surface.lerp(accent, 0.22)))
	button.add_theme_color_override("font_hover_pressed_color", Palette.readable_ink(ink, surface.lerp(accent, 0.22)))
	button.add_theme_color_override("font_disabled_color", Palette.readable_ink(Palette.semantic("disabled"), surface.darkened(0.05)))
	var normal := _style(surface, accent, factor, margin, radius)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", _style(surface.lerp(accent, 0.10), accent, factor, margin, radius))
	button.add_theme_stylebox_override("pressed", _style(surface.lerp(accent, 0.22), accent, factor, margin, radius))
	button.add_theme_stylebox_override("hover_pressed", _style(surface.lerp(accent, 0.22), accent, factor, margin, radius))
	button.add_theme_stylebox_override("disabled", _style(surface.darkened(0.05), Palette.semantic("disabled", accent), factor, margin, radius))
	var focus := _style(Color.TRANSPARENT, Palette.semantic("focus", accent), factor, margin, radius)
	focus.set_border_width_all(maxi(2, roundi(3.0 * factor)))
	focus.expand_margin_left = 3.0 * factor
	focus.expand_margin_right = 3.0 * factor
	focus.expand_margin_top = 3.0 * factor
	focus.expand_margin_bottom = 3.0 * factor
	button.add_theme_stylebox_override("focus", focus)
	button.accessibility_name = button.text
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

static func _style(fill: Color, border: Color, factor: float, margin: float, radius: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(maxi(1, roundi(factor)))
	style.set_corner_radius_all(roundi(radius * factor))
	style.set_content_margin_all(roundi(margin * factor))
	return style
