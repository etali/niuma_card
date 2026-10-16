# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const Materials = preload("res://scenes/effect_materials.gd")

## 资源读数的顶栏反馈。读数文字始终是规则状态的实数，这里不改它，只补「钱和人往哪儿去了」：
## 涨的时候，资源牌上那枚图标（¥ 金币 / 小人）从牌桌上对应的那摞飞进顶栏读数，
## 一枚一枚落进去，读数随之亮一下；跌的时候图标从读数里掉出来、往下坠着淡掉。
## 旁边贴一枚小标签「[图标] +3」，写法和卡面效果墨团一致，不写「资金」「用户」二字。
const MAX_PIECES := 5
const FLIGHT := 0.46
const STAGGER := 0.07
const DROP := 0.55
const CHIP_LIFE := 1.1

## 一次资源变化。origin 是这摞资源在屏幕上的位置，target_point 是读数里对应那一段的位置。
## gain 时图标从 origin 飞向 target_point（delay 后出发，等牌先落到牌桌上）；loss 时从读数往下掉。
static func collect(layer: CanvasLayer, origin: Vector2, target: Control, target_point: Vector2,
		icon: Texture2D, delta: int, font_size: int, delay := 0.0) -> void:
	var gain := delta > 0
	var count := mini(absi(delta), MAX_PIECES)
	var piece_size := Vector2.ONE * roundf(font_size * 1.35)
	for i in count:
		var piece := TextureRect.new()
		piece.name = "ResourcePiece"
		# 同名兄弟节点会被引擎改名；按标记认，不按名字认。
		piece.set_meta("hud_fx", "piece")
		piece.texture = icon
		piece.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		piece.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		piece.mouse_filter = Control.MOUSE_FILTER_IGNORE
		piece.size = piece_size
		piece.pivot_offset = piece_size * 0.5
		piece.visible = false
		layer.add_child(piece)
		var start := origin if gain else target_point
		var spread := Materials.rng().randf_range(-0.5, 0.5) * piece_size.x * 1.6
		var finish := target_point if gain else target_point + Vector2(spread, piece_size.y * 3.2)
		# 飞进去走一条往外鼓的弧，像被抛进钱袋；掉出来先往上蹦一下再坠。
		var bulge := Vector2(spread * 2.0, -absf(start.y - finish.y) * 0.25) if gain \
			else Vector2(spread, -piece_size.y * 1.4)
		var control := (start + finish) * 0.5 + bulge
		var tween := piece.create_tween()
		tween.tween_interval(delay + STAGGER * i)
		tween.tween_callback(piece.show)
		tween.tween_method(func(t: float) -> void:
			var eased := t * t if gain else t
			var u := 1.0 - eased
			piece.position = u * u * start + 2.0 * u * eased * control + eased * eased * finish - piece_size * 0.5
			piece.scale = Vector2.ONE * (lerpf(0.75, 1.0, sin(t * PI)) if gain else lerpf(1.0, 0.7, t))
			piece.rotation = (t - 0.5) * 0.5 * (1.0 if spread >= 0.0 else -1.0)
			piece.modulate.a = 1.0 if gain else 1.0 - t * t, 0.0, 1.0, FLIGHT if gain else DROP)
		if gain:
			tween.tween_callback(func() -> void: flash(target, true))
		tween.tween_callback(piece.queue_free)
	if not gain:
		flash(target, false)
	chip(layer, target_point + Vector2(0, font_size * 1.3), icon, delta, font_size,
		delay + (FLIGHT * 0.9 if gain else 0.0))

## 读数下方的小标签「[图标] +3」：弹出、停一会儿、淡掉。涨用成功色，跌用危险色。
static func chip(layer: CanvasLayer, at: Vector2, icon: Texture2D, delta: int, font_size: int,
		delay := 0.0) -> Control:
	var gain := delta > 0
	var box := HBoxContainer.new()
	box.name = "ResourceChip"
	box.set_meta("hud_fx", "chip")
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", maxi(2, font_size / 6))
	var picture := TextureRect.new()
	picture.texture = icon
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.custom_minimum_size = Vector2.ONE * roundf(font_size * 1.15)
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(picture)
	var label := Label.new()
	label.name = "ChipAmount"
	# 跌用 U+2212 减号，与卡面攻击墨团「−N」同一个字符。
	label.text = "+%d" % delta if gain else "−%d" % absi(delta)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", Fonts.zh_bold())
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Palette.semantic("success" if gain else "danger"))
	label.add_theme_color_override("font_outline_color", Palette.semantic("surface"))
	label.add_theme_constant_override("outline_size", maxi(4, font_size / 3))
	box.add_child(label)
	layer.add_child(box)
	var extent := box.get_combined_minimum_size()
	box.size = extent
	box.pivot_offset = extent * 0.5
	box.position = at - extent * 0.5
	box.scale = Vector2.ONE * 0.4
	box.modulate.a = 0.0
	var tween := box.create_tween()
	tween.tween_interval(delay)
	tween.tween_property(box, "modulate:a", 1.0, 0.06)
	tween.parallel().tween_property(box, "scale", Vector2.ONE * 1.1, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(box, "scale", Vector2.ONE, 0.08)
	tween.tween_interval(CHIP_LIFE * 0.55)
	tween.tween_property(box, "position:y", box.position.y + (-8.0 if gain else 8.0), CHIP_LIFE * 0.35)
	tween.parallel().tween_property(box, "modulate:a", 0.0, CHIP_LIFE * 0.35)
	tween.tween_callback(box.queue_free)
	return box

## 读数亮一下：涨偏暖、跌偏红；只动 modulate，不改字号、颜色覆盖或缩放。
static func flash(control: Control, gain: bool) -> void:
	if not is_instance_valid(control):
		return
	var previous: Variant = control.get_meta("hud_flash") if control.has_meta("hud_flash") else null
	if previous is Tween and previous.is_valid():
		previous.kill()
	control.modulate = Color(1.35, 1.25, 0.85) if gain else Color(1.45, 0.72, 0.68)
	var tween := control.create_tween()
	tween.tween_property(control, "modulate", Color.WHITE, 0.4).set_trans(Tween.TRANS_SINE)
	control.set_meta("hud_flash", tween)
