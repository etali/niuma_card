# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name ResourceHUD
extends PanelContainer

## 双方共用的结构化资源卡；summary 是抽屉首行与旧调用方共用的完整摘要。
## 数值与风险独立布局，长预警不再挤进资金读数，也不改变牌桌鼠标事件路由。
var summary: Label
var title: Label
var cash_value: Label
var user_value: Label
var due_value: Label
var deployment: Label
var warning: Label
var warning_frame: PanelContainer
var _cash_caption: Label
var _user_caption: Label
var _content: VBoxContainer
var _identity := "player"

func setup(company: String, identity: String, compact: bool) -> void:
	_identity = identity
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	custom_minimum_size = Vector2(240, 0)
	_content = VBoxContainer.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_theme_constant_override("separation", 2)
	add_child(_content)
	var heading := HBoxContainer.new()
	heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heading.alignment = BoxContainer.ALIGNMENT_CENTER
	heading.add_theme_constant_override("separation", 12)
	_content.add_child(heading)
	title = _label(heading, company, 15, true)
	title.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	due_value = _label(heading, "", 14, true)
	due_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	due_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var metrics := HBoxContainer.new()
	metrics.mouse_filter = Control.MOUSE_FILTER_IGNORE
	metrics.add_theme_constant_override("separation", 10)
	_content.add_child(metrics)
	var cash := _metric(metrics, CardDB.res_label(CardDB.RES_CASH))
	_cash_caption = cash[0]
	cash_value = cash[1]
	var users := _metric(metrics, CardDB.res_label(CardDB.RES_USER))
	_user_caption = users[0]
	user_value = users[1]
	var footer := HBoxContainer.new()
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 8)
	_content.add_child(footer)
	deployment = _label(footer, "", 13)
	deployment.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	deployment.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	deployment.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	warning_frame = PanelContainer.new()
	warning_frame.name = "RiskBadge"
	warning_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	warning_frame.visible = false
	footer.add_child(warning_frame)
	warning = _label(warning_frame, "", 13, true)
	warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warning.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	warning.tooltip_text = "待付后资金归零，相关组合无法支付配方并会作废"
	# Label 引用仍提供完整事实摘要。桌面卡使用结构化控件；抽屉会收养这个 Label。
	summary = _label(self, "", 18)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary.visible = compact
	_content.visible = not compact
	refresh_palette()

func _metric(parent: Node, caption: String) -> Array[Label]:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 7)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	parent.add_child(row)
	var label := _label(row, caption, 14)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var value := _label(row, "0", 25, true)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return [label, value]

func _label(parent: Node, text: String, font_size: int, bold := false) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.add_theme_font_override("font", Fonts.zh_bold() if bold else Fonts.zh())
	label.add_theme_font_size_override("font_size", font_size)
	parent.add_child(label)
	return label

func set_resources(cash: int, users: int, due: int, on_duty: int, idle: int,
		has_deployment: bool, at_risk: bool) -> void:
	cash_value.text = str(cash)
	user_value.text = str(users)
	due_value.text = "待付  %d" % due
	deployment.text = "在岗 %d / 闲置 %d" % [on_duty, idle] if has_deployment else "在岗状态待提交"
	warning.text = "! 付完归零" if at_risk else ""
	warning_frame.visible = at_risk
	refresh_palette()

func refresh_palette() -> void:
	var surface := Palette.semantic("surface")
	var ink := Palette.readable_ink(Palette.semantic("ink"), surface)
	var style := StyleBoxFlat.new()
	style.bg_color = surface
	style.border_color = Palette.get_color("hud", _identity)
	style.set_border_width_all(1)
	style.border_width_top = 3
	style.set_corner_radius_all(8)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)
	for label in [title, cash_value, user_value]:
		label.add_theme_color_override("font_color", ink)
	_cash_caption.add_theme_color_override("font_color", Palette.readable_ink(Palette.semantic("cash"), surface))
	_user_caption.add_theme_color_override("font_color", Palette.readable_ink(Palette.semantic("user"), surface))
	deployment.add_theme_color_override("font_color", Palette.readable_ink(Palette.semantic("muted"), surface))
	due_value.add_theme_color_override("font_color", Palette.readable_ink(Palette.semantic("pending"), surface))
	warning.add_theme_color_override("font_color", Palette.readable_ink(Palette.semantic("danger"), surface))
	var alert := StyleBoxFlat.new()
	alert.bg_color = Color(Palette.semantic("danger"), 0.1)
	alert.border_color = Palette.semantic("danger")
	alert.border_width_left = 3
	alert.set_corner_radius_all(3)
	alert.content_margin_left = 5
	alert.content_margin_right = 4
	alert.content_margin_top = 3
	alert.content_margin_bottom = 3
	warning_frame.add_theme_stylebox_override("panel", alert)
