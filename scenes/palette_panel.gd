# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name PalettePanel
extends Control

## 右上角选色面板。按 Palette.editable_groups() 分组列出所有可调色项，
## 拖一下颜色就通过 Palette.set_color / set_plate_color 写进配置并广播，
## 主场景收到广播后重刷世界材质和场上每张卡（见 main.gd _refresh_world_palette）。
##
## 两个必须注意的点：
## 1. mouse_filter = STOP。取牌是 board.gd 在 _unhandled_input 里打射线做的，
##    面板不吃掉事件的话，在面板上点一下会顺带把桌上的牌抓起来
## 2. _syncing 护栏。restore_defaults 之后要把所有取色器拨回新值，
##    而拨动取色器本身会触发 color_changed，不挡一下就会自己写回自己

const LIST_H := 420          # 43 项列不完，列表固定高度 + 滚动
const SWATCH_W := 54
const ROW_H := 26

var _body: VBoxContainer            # 折叠时隐藏的部分（列表 + 页脚）
var _toggle: Button
var _status: Label
var _pickers: Array = []            # [{btn, section, key, slot}]，restore 后要整体回填
var _syncing := false               # 见类注释第 2 点


func _ready() -> void:
	name = "PalettePanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_build()
	_relayout()
	# 内容自己变大变小的时候也要重算框子（同 ai_panel.gd 里那条）
	get_node("Frame").minimum_size_changed.connect(_relayout)


func _build() -> void:
	var pc := PanelContainer.new()
	pc.name = "Frame"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.12, 0.90)
	sb.border_color = Color(0.55, 0.52, 0.45, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	pc.add_theme_stylebox_override("panel", sb)
	pc.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(pc)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	pc.add_child(root)

	root.add_child(_build_header())

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	# 默认收起：展开时 420px 高的列表会压住右上角的牌，平时只留一行标题栏
	_body.visible = false
	root.add_child(_body)

	_body.add_child(_build_list())
	_body.add_child(_build_footer())


func _build_header() -> HBoxContainer:
	var hb := HBoxContainer.new()
	var title := Label.new()
	title.text = "配色"
	title.add_theme_font_override("font", Fonts.zh())
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.95, 0.93, 0.88))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(title)

	_toggle = Button.new()
	_toggle.text = "展开"          # 与 _build 里 _body.visible = false 对应
	_toggle.add_theme_font_override("font", Fonts.zh())
	_toggle.add_theme_font_size_override("font_size", 13)
	_toggle.pressed.connect(_on_toggle)
	hb.add_child(_toggle)
	return hb


func _build_list() -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(268, LIST_H)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(col)

	for grp in Palette.editable_groups():
		var head := Label.new()
		head.text = str(grp["title"])
		head.add_theme_font_override("font", Fonts.zh())
		head.add_theme_font_size_override("font_size", 14)
		head.add_theme_color_override("font_color", Color(0.72, 0.82, 0.62))
		col.add_child(head)
		for item in grp["items"]:
			col.add_child(_build_row(item))
	return sc


func _build_row(item: Dictionary) -> HBoxContainer:
	var slot := str(item.get("slot", ""))
	var section := str(item["section"])
	var key := str(item["key"])

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)

	var lbl := Label.new()
	lbl.text = str(item["label"])
	lbl.add_theme_font_override("font", Fonts.zh())
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.88, 0.86, 0.82))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(lbl)

	var btn := ColorPickerButton.new()
	btn.custom_minimum_size = Vector2(SWATCH_W, ROW_H)
	btn.edit_alpha = false
	btn.color = _current(section, key, slot)
	btn.color_changed.connect(_on_color_changed.bind(section, key, slot))
	hb.add_child(btn)

	_pickers.append({ "btn": btn, "section": section, "key": key, "slot": slot })
	return hb


func _build_footer() -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)

	var save := Button.new()
	save.text = "保存"
	save.add_theme_font_override("font", Fonts.zh())
	save.add_theme_font_size_override("font_size", 13)
	save.pressed.connect(_on_save)
	hb.add_child(save)

	var reset := Button.new()
	reset.text = "还原默认"
	reset.add_theme_font_override("font", Fonts.zh())
	reset.add_theme_font_size_override("font_size", 13)
	reset.pressed.connect(_on_reset)
	hb.add_child(reset)

	_status = Label.new()
	_status.add_theme_font_override("font", Fonts.zh())
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color(0.65, 0.75, 0.6))
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(_status)
	return hb


## 图标前景色留空表示「跟随底板墨色」，此时取色器显示现金卡的墨色当代表值
func _current(section: String, key: String, slot: String) -> Color:
	if slot != "":
		return Palette.plate_color(slot, key)
	if section == "icon" and key == "foreground" \
		and Palette.get_string(section, key) == "":
		return Palette.plate_color("plate_cash", "ink")
	return Palette.get_color(section, key)


func _on_color_changed(c: Color, section: String, key: String, slot: String) -> void:
	if _syncing:
		return
	if slot != "":
		Palette.set_plate_color(slot, key, c)
	else:
		Palette.set_color(section, key, c)
	_status.text = ""


## 显隐、按钮文案、框子尺寸同一帧做完，不许 await 一帧去等 min size ——
## 理由写在 ai_panel.gd 的 _on_toggle 上（这块是同一个 bug 的两处）
func _on_toggle() -> void:
	_body.visible = not _body.visible
	_toggle.text = "收起" if _body.visible else "展开"
	_relayout()


func _on_save() -> void:
	_status.text = "已保存" if Palette.save() else "保存失败"


func _on_reset() -> void:
	Palette.restore_defaults()
	_sync_pickers()
	_status.text = "已还原"


## 把所有取色器拨回配置当前值（还原默认之后用）
func _sync_pickers() -> void:
	_syncing = true
	for p in _pickers:
		var btn: ColorPickerButton = p["btn"]
		if is_instance_valid(btn):
			btn.color = _current(str(p["section"]), str(p["key"]), str(p["slot"]))
	_syncing = false


## 面板锚在右上角，高度按内容实算：不设 offset_bottom 的话 Control 高度是 0，
## 里头的 PanelContainer 撑不开就整块看不见
func _relayout() -> void:
	var pc := get_node_or_null("Frame") as PanelContainer
	if pc == null:
		return
	var want := pc.get_combined_minimum_size()
	var margin := 12.0
	offset_left = -want.x - margin
	offset_right = -margin
	offset_top = margin
	offset_bottom = margin + want.y
