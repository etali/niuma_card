# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name SaveNotice
extends CanvasLayer

## 存完录像之后报路径的那一小块面板（scenes/main.gd 的 HUD 与面板实现）。
##
## 为什么不用 _show_message：那条路是**一行画在 3D 画面上的字**。
## 对「购入某卡」那类提示是对的（读一眼就完事），对一条绝对路径不行 ——
##   1. **抄不走**。路径是要拿去 Finder / 命令行用的，而画在画面上的字选不中、
##      复制不了，玩家只能盯着屏幕一个字一个字往别处敲（用户原话
##      「当前保存路径的提示是直接渲染到画面，这个不合适」）
##   2. **一行装不下**。提示条定宽 440 折行，一条绝对路径会折成三四行，
##      把资源面板顶开老高
##
## 第 1 条是这块面板存在的**唯一**理由，也是它每一样零件的来由。
## 从前这里还列着第 3 条「会跑：MSG_HOLD 2 秒之后淡出」—— 那条**已经不成立**：
## 提示条现在不淡出了（main._show_message）。留着一条失效的理由比没有理由更糟：
## 下一个读到的人会以为「不淡出了那这块面板可以删了」，而第 1 条依然要它
##
## 所以这里给它一个框、一个只读但**选得中**的输入框、一颗复制按钮。
## 面板**不模态**：存录像本来就不打断对局（见 main._save_replay），
## 挡住桌面等于把「随时能存」变成「存完得先关窗」

## 放在左下角那列按钮**上方** —— 它是 btn_save 按出来的东西，
## 结果就该出现在按钮附近。居中的话会盖住公共区那排卡，
## 而这个面板不模态、玩家可能开着它继续打
const MARGIN_X := 24.0
const BOTTOM_Y := -232.0     ## 三颗按钮最高那颗（存录像）在 -172，高 44 → -216
const PANEL_W := 560.0

var _title: Label
var _path_edit: LineEdit
var _hint: Label
var _copy_btn: Button
var _close_btn: Button

func _init() -> void:
	# 压在终局面板（layer 10）之上、联网面板（layer 20）之下：
	# 存录像在终局界面上也能按，而联网面板是模态的，它该盖住这个
	layer = 15

func _ready() -> void:
	var pc := PanelContainer.new()
	pc.name = "Frame"
	pc.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	pc.position = Vector2(MARGIN_X, BOTTOM_Y)
	pc.custom_minimum_size = Vector2(PANEL_W, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.94)
	sb.border_color = Color(0.55, 0.75, 0.6, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	pc.add_theme_stylebox_override("panel", sb)
	add_child(pc)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	pc.add_child(vb)

	_title = _label("", 20, Color(0.7, 1.0, 0.7))
	vb.add_child(_title)

	# 只读**但选得中**。editable=false 的 LineEdit 在 Godot 4 里照旧能选、能
	# Ctrl-C，两样都显式写出来（默认值是引擎那边的事，而这两样正是这个面板的理由）。
	# 用 LineEdit 而不是 Label：Label 一个字都选不中
	_path_edit = LineEdit.new()
	_path_edit.name = "PathEdit"
	_path_edit.editable = false
	_path_edit.selecting_enabled = true
	_path_edit.shortcut_keys_enabled = true
	_path_edit.caret_blink = false
	_path_edit.add_theme_font_override("font", Fonts.zh())
	_path_edit.add_theme_font_size_override("font_size", 16)
	_path_edit.custom_minimum_size = Vector2(PANEL_W - 24.0, 34)
	_path_edit.tooltip_text = "选中可复制（也可以按右边那颗按钮）"
	vb.add_child(_path_edit)

	_hint = _label("", 15, Color(0.75, 0.75, 0.8))
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(PANEL_W - 24.0, 0)
	vb.add_child(_hint)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)
	_copy_btn = _button("复制路径", _on_copy)
	row.add_child(_copy_btn)
	_close_btn = _button("知道了", _on_close)
	row.add_child(_close_btn)

	visible = false

func set_embedded(on: bool) -> void:
	_close_btn.visible = not on
	_path_edit.custom_minimum_size.x = 0 if on else PANEL_W - 24.0
	_hint.custom_minimum_size.x = 0 if on else PANEL_W - 24.0
	get_node("Frame").custom_minimum_size.x = 0 if on else PANEL_W

func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", Fonts.zh())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", Fonts.zh())
	b.add_theme_font_size_override("font_size", 17)
	b.custom_minimum_size = Vector2(110, 36)
	b.pressed.connect(cb)
	return b

## 存成功了：报**绝对路径**。录像存在 `~/.niumapai_record` 底下
## （engine/tape.gd），而 `~` 在各平台展开成什么不一样 ——
## 只念一句「存在 ~/.niumapai_record 里」的话玩家还得自己拼一遍
func show_saved(abs_path: String, steps: int) -> void:
	_title.text = "录像已存（%d 步）" % steps
	_title.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
	_path_edit.text = abs_path
	_path_edit.editable = false
	_hint.text = ""
	_hint.hide()
	_copy_btn.disabled = false
	visible = true

## 存不下来：**把要写的那个目录也报出来**。「存不下来」单独一句没有排查价值，
## 而路径在手上就能去看是不是磁盘满了 / 没有写权限
func show_failed(dir_path: String, why := "") -> void:
	_title.text = "录像存不下来"
	_title.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))
	_path_edit.text = dir_path
	_hint.show()
	_hint.text = "写不进这个目录%s —— 看看磁盘满不满、有没有写权限" \
		% ("" if why == "" else "（%s）" % why)
	_copy_btn.disabled = false
	visible = true

## 复制到系统剪贴板。按完**改一下按钮文案**：剪贴板是看不见的，
## 不给回执的话玩家不知道按生效了没有，会连按几次
func _on_copy() -> void:
	DisplayServer.clipboard_set(_path_edit.text)
	_copy_btn.text = "已复制 ✓"
	# 复制走的是 DisplayServer，无头模式下没有剪贴板也不该崩 ——
	# 上面那句在无头下是空操作，按钮文案照旧改（测试认的就是这个）
	var tw := create_tween()
	tw.tween_interval(1.4)
	tw.tween_callback(func() -> void:
		if is_instance_valid(_copy_btn):
			_copy_btn.text = "复制路径")

func _on_close() -> void:
	visible = false
