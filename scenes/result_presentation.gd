# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 对局、规则演示共用的胜负结算视图：文案、图案、按钮与声音只有一个实现。
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
		action: Callable, action_text := "再战一局", compact := true) -> Dictionary:
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

	var btn := Button.new()
	btn.name = "ResultRestart"
	btn.text = action_text
	btn.set_meta("drawer_primary", true)
	btn.add_theme_font_override("font", Fonts.zh())
	btn.add_theme_font_size_override("font_size", 24)
	btn.custom_minimum_size = Vector2(220, 42)
	btn.pressed.connect(action)
	vb.add_child(btn)
	return {"layer": canvas, "panel": panel, "body": vb, "button": btn, "center": center}

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
