# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends Control

## 示意手势只画影子，不驱动输入、不搬动实体。每帧重投影，跟随缩放、移镜与窗口变化。
const HandArt = preload("res://scenes/hand_art.gd")
var player: Control
var cue: Dictionary = {}
var _elapsed := 0.0
var _idle := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_as_top_level(true)
	z_index = 4
	position = Vector2.ZERO

func set_cue(value: Dictionary) -> void:
	if value != cue: _elapsed = 0.0
	cue = value
	queue_redraw()

func active() -> bool:
	return is_instance_valid(player) and player.is_visible_in_tree() and not player._reference_open \
		and not player._awaiting_result and not player._closing and not player.arena.operation_pending \
		and player.arena.board._drag_cards.is_empty() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

func _process(delta: float) -> void:
	if active():
		_idle += delta
		_elapsed += delta
	else:
		_idle = 0.0
		_elapsed = 0.0
	queue_redraw()

func anchor(node: Node) -> Vector2:
	if node is Control: return node.get_global_rect().get_center()
	var at: Vector3 = node.global_position
	var group: Variant = player.arena.board.group_of(node)
	if group != null and not group.get("compact", false) and group["cards"].back() != node:
		at += node.global_basis * Vector3(0, 0.06, -CardEntity.CARD_SIZE.z * 0.4)
	return player.arena.camera.unproject_position(at)

func _draw() -> void:
	if not active() or cue.is_empty() or _idle < 0.5: return
	var source: Node = cue.get("source")
	if not is_instance_valid(source) or not source.is_visible_in_tree(): return
	var start := anchor(source)
	var end := start
	var target: Node = cue.get("target")
	if is_instance_valid(target): end = anchor(target)
	elif cue.has("target_world"): end = player.arena.camera.unproject_position(cue["target_world"])
	var factor: float = maxf(0.8, player._presentation._responsive_factor())
	var color := Palette.semantic("warning")
	var cycle := fmod(_elapsed, 3.4)
	var progress := smoothstep(0.55, 2.1, cycle)
	var hand := start
	var dragging: bool = cue.get("gesture") == "drag"
	draw_arc(start, 18 * factor, 0, TAU, 40, Color(color, 0.8), 2 * factor, true)
	if source is Control:
		draw_rect(source.get_global_rect().grow(3 * factor), Color(color, 0.8), false, 2 * factor)
	if dragging:
		draw_dashed_line(start, end, Color(color, 0.45), 2 * factor, 7 * factor, true)
		draw_arc(end, 23 * factor, 0, TAU, 40, Color(color, 0.8), 2 * factor, true)
		hand = start.lerp(end, progress)
		if cycle > 0.55 and cycle < 2.6:
			draw_rect(Rect2(hand - Vector2(15, 23) * factor, Vector2(30, 46) * factor), Color(color, 0.18), true)
	else:
		var taps: Array = [0.65, 0.95] if cue.get("gesture") == "double_click" else [0.65]
		for tap in taps:
			var age: float = cycle - float(tap)
			if age >= 0 and age < 0.35:
				draw_arc(start, (10 + age * 45) * factor, 0, TAU, 32, Color(color, 1 - age / 0.35), 2 * factor, true)
	HandArt.draw(self, hand, -0.12, 0.65 * factor, dragging and cycle > 0.55 and cycle < 2.6, false, 0.9)
	draw_set_transform(Vector2.ZERO)
