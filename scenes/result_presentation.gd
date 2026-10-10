# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 正式对局、教程与规则演示共用的胜负展示，统一创建、挂载、暂停和释放。
const Motion = preload("res://scenes/ui_motion.gd")
const RESULT_HOLD := 1.8
const WIN_TAUNTS: Array[String] = [
	"你赢了。别急着高兴，先看看赢了几分。",
	"赢了。这套牌换个人来，估计能快三回合。",
	"你赢了。运气这东西，也算是一种实力吧。",
	"赢了。对手要是也会双击摞牌，就不好说了。",
]

const LOSE_TAUNTS: Array[String] = [
	"你输了。牌是好牌。",
	"输了。它想了 0.2 秒，你想了半小时。",
	"你输了。至少桌面摆得挺整齐。",
	"输了。要不试试先把配方凑齐再说？",
]

static func create(parent: Node, state: GameState, my_seat: String, sfx: Sfx,
		action: Callable, action_text := "再战一局", compact := true, auto_dismiss := false) -> Dictionary:
	var canvas := CanvasLayer.new()
	canvas.name = "GameOver"
	canvas.layer = 10
	parent.add_child(canvas)
	# 居中基准固定为视口中心，不让正文换行前的临时最小高度撑大容器。
	# use_top_left 按自身原点居中子面板；面板变高时自动向上下两侧展开。
	var center := CenterContainer.new()
	center.use_top_left = true
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 别把面板外的点击也吃掉
	canvas.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var panel := PanelContainer.new()
	panel.name = "ResultPanel"
	panel.custom_minimum_size = Vector2(480, 0) if compact else Vector2(560, 260)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	var won := state.winner == my_seat
	var result_icon := TextureRect.new()
	result_icon.name = "ResultMascot"
	result_icon.texture = load("res://assets/art/app_icon.png")
	result_icon.custom_minimum_size = Vector2(68, 68)
	result_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	result_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	result_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	result_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result_icon.tooltip_text = "胜利" if won else "本局结束"
	vb.add_child(result_icon)
	var title := Label.new()
	title.name = "ResultTitle"
	title.text = "胜利" if won else "失败"
	title.set_meta("drawer_font_base", 21)
	title.add_theme_font_override("font", Fonts.zh_bold())
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var message := Label.new()
	message.name = "ResultMessage"
	message.add_theme_font_override("font", Fonts.zh())
	message.add_theme_font_size_override("font_size", 22)
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.text = WIN_TAUNTS[randi() % WIN_TAUNTS.size()] if won else LOSE_TAUNTS[randi() % LOSE_TAUNTS.size()]
	vb.add_child(message)
	if won:
		sfx.play("win")
	else:
		sfx.play("lose")

	var reason := Label.new()
	reason.name = "ResultReason"
	reason.set_meta("drawer_font_base", 15)
	reason.add_theme_font_override("font", Fonts.zh())
	reason.add_theme_font_size_override("font_size", 20)
	reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reason.text = state.win_reason
	vb.add_child(reason)

	var btn: Button
	if action.is_valid():
		btn = Button.new()
		btn.name = "ResultRestart"
		btn.text = action_text
		btn.set_meta("drawer_primary", true)
		btn.add_theme_font_override("font", Fonts.zh())
		btn.add_theme_font_size_override("font_size", 24)
		btn.custom_minimum_size = Vector2(220, 42)
		btn.pressed.connect(action)
		vb.add_child(btn)
	# 同一段入场动效服务正式终局和教程。教学只多停留、淡出，不另画胜利界面。
	panel.modulate.a = 0.0
	result_icon.scale = Vector2.ONE * 0.8
	result_icon.resized.connect(func(): result_icon.pivot_offset = result_icon.size * 0.5)
	var animation := panel.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	animation.tween_property(panel, "modulate:a", 1.0, Motion.ACT)
	animation.parallel().tween_property(result_icon, "scale", Vector2.ONE, Motion.ACT).set_trans(Tween.TRANS_BACK)
	if auto_dismiss:
		animation.tween_interval(RESULT_HOLD)
		animation.tween_property(panel, "modulate:a", 0.0, Motion.SETTLE)
	canvas.visibility_changed.connect(func():
		if not animation.is_valid(): return
		if canvas.visible:
			animation.play()
		else:
			animation.pause())
	return {"layer": canvas, "panel": panel, "body": vb, "button": btn, "center": center,
		"animation": animation, "auto_dismiss": auto_dismiss}

## 业务方建好附加按钮后统一挂载；教程只指定演出结束后的续课动作。
static func present(result: Dictionary, presentation: Node, completed := Callable()) -> void:
	if presentation != null:
		presentation.register_result_panel(result["layer"])
	else:
		fit(result, result["layer"].get_viewport().get_visible_rect().size)
	if result["auto_dismiss"]:
		result["animation"].finished.connect(func():
			close(result)
			if completed.is_valid(): completed.call(), CONNECT_ONE_SHOT)

static func set_active(result: Dictionary, active: bool) -> void:
	if not result.is_empty():
		result["layer"].visible = active

static func close(result: Dictionary) -> void:
	if result.is_empty(): return
	var animation: Tween = result["animation"]
	if animation != null and animation.is_valid(): animation.kill()
	var layer: CanvasLayer = result["layer"]
	if is_instance_valid(layer):
		layer.hide()
		layer.queue_free()
	result.clear()

static func fit(result: Dictionary, available: Vector2) -> void:
	var panel: PanelContainer = result["panel"]
	panel.custom_minimum_size.x = minf(panel.custom_minimum_size.x, maxf(200.0, available.x - 24.0))
	var canvas: CanvasLayer = result["layer"]
	var center: CenterContainer = result["center"]
	canvas.scale = Vector2.ONE
	center.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	center.position = available * 0.5
	# 自动换行的初始最小高度尚未按面板宽度排版，不能拿它算缩放。
	var tree: SceneTree = canvas.get_tree()
	for i in 2:
		await tree.process_frame
		if not is_instance_valid(canvas):
			return
	var extent := panel.get_combined_minimum_size()
	var factor := minf(1.0, minf((available.x - 16) / extent.x, (available.y - 16) / extent.y))
	canvas.scale = Vector2.ONE * maxf(0.1, factor)
	center.position = available * 0.5 / canvas.scale
