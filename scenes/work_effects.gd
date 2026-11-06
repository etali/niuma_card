# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Control

## Presentation only: gameplay has already committed before these effects start.
var config: Dictionary
var texts: Dictionary
var items: Array[Dictionary] = []
var ink: Color
var paper: Color
var accent: Color
var cash: Color
var card_position_provider: Callable

func setup(settings: Dictionary, labels: Dictionary) -> void:
	config = settings
	texts = labels
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ink = Palette.get_color("card", "frame")
	paper = Palette.semantic("surface")
	accent = Palette.semantic("danger")
	cash = Palette.semantic("cash")

func emit_effect(kind: String, start: Vector2, finish: Vector2, count := 1, targets: Array = [], source_id := -1, target_ids: Array = []) -> void:
	if items.size() >= int(config.max_events):
		items.pop_front()
	var duration: float = float(config.duration)
	if kind == "transfer": duration = float(config.transfer_duration)
	elif kind == "meeting_start": duration = float(config.meeting_duration)
	elif kind == "work_complete": duration = float(config.coin_duration)
	elif kind == "strike": duration = float(config.stamp_duration)
	items.append({"kind":kind,"from":start,"to":finish,"count":count,"targets":targets,"age":0.0,"duration":duration,
		"source_id": source_id, "target_ids": target_ids.duplicate()})

## Resolve moving meeting cards at draw time, after their actual 3D positions
## update. Other event effects still use their intentional historical origins.
func card_position(id: int, fallback: Vector2) -> Vector2:
	return card_position_provider.call(id) if id >= 0 and card_position_provider.is_valid() else fallback

func clear() -> void:
	items.clear()
	queue_redraw()

func _process(delta: float) -> void:
	for item in items:
		item.age += delta
	items = items.filter(func(item: Dictionary) -> bool: return float(item.age) < float(item.duration))
	if not config.is_empty(): queue_redraw()

func _draw() -> void:
	for item in items:
		var t: float = clampf(float(item.age) / float(item.duration), 0.0, 1.0)
		var origin: Vector2 = item.from
		var end: Vector2 = item.to
		match str(item.kind):
			"transfer":
				# WorkBoard flies the actual card nodes; never draw duplicate work.
				if t > float(config.transfer_impact_fraction):
					_burst(end, (t - float(config.transfer_impact_fraction)) / (1.0 - float(config.transfer_impact_fraction)), ink)
			"meeting_start":
				origin = card_position(int(item.source_id), origin)
				_burst(origin, t, accent)
			"work_complete":
				# 只保留来源的一拍纸张反馈，现金本身是 Board 上的真实卡。
				_burst(origin, t, cash)
			"strike":
				_stamp(origin, str(texts.strike), t, accent)
			"coffee_upgrade":
				_burst(origin, t, cash)
			"outsource":
				_draw_paper(origin.lerp(end, t), 1.0 - t, 0)
			"fire":
				_stamp(origin, str(texts.fired), t, accent)
			_:
				_burst(origin, t, ink)

func _draw_paper(point: Vector2, opacity: float, angle: float) -> void:
	var extent := Vector2(float(config.paper_size[0]), float(config.paper_size[1]))
	draw_set_transform(point, angle)
	var rect := Rect2(-extent * 0.5, extent)
	draw_rect(rect, Color(paper, opacity))
	draw_rect(rect, Color(ink, opacity), false, float(config.line_width))
	for line in int(config.paper_lines):
		var y: float = rect.position.y + float(line + 1) * float(config.paper_line_spacing)
		draw_line(Vector2(rect.position.x + float(config.paper_spacing), y), Vector2(rect.end.x - float(config.paper_spacing), y), Color(ink, opacity), float(config.line_width), true)
	draw_set_transform(Vector2.ZERO)

func _burst(point: Vector2, t: float, color: Color) -> void:
	var radius: float = float(config.burst_radius) * t
	for ray in int(config.burst_rays):
		var direction := Vector2.from_angle(TAU * float(ray) / float(config.burst_rays))
		draw_line(point + direction * radius * 0.5, point + direction * radius, Color(color, 1.0 - t), float(config.line_width), true)

func _stamp(point: Vector2, text: String, t: float, color: Color) -> void:
	var scale_factor: float = lerpf(float(config.stamp_scale_start), 1.0, minf(t / float(config.stamp_impact_fraction), 1.0))
	draw_set_transform(point, float(config.stamp_angle), Vector2.ONE * scale_factor)
	var font_size: int = int(config.stamp_font_size)
	var width: float = Fonts.zh_black().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(Fonts.zh_black(), Vector2(-width * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(color, 1.0 - t))
	draw_set_transform(Vector2.ZERO)
