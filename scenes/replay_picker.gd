# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends CanvasLayer

## 与选项/联网表单相同的游戏内窗口，不创建 macOS 原生子窗口。
## 避免原生菜单关闭、FileDialog取得焦点和抽屉收放在同一回调中重入。
signal file_selected(path: String)

var _directory := ""
var _files: ItemList
var _path_edit: LineEdit
var _status: Label
var _main: Node
var _entries: Array[String] = []
var _directories: Array[bool] = []
var _frame: PanelContainer

func bind(main: Node) -> void:
	_main = main
	layer = 22
	name = "ReplayPicker"

func _ready() -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_frame = PanelContainer.new()
	_frame.name = "ReplayFilePanel"
	_frame.custom_minimum_size = Vector2(600, 380)
	center.add_child(_frame)
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.get_color("world", "table_frame")
	style.border_color = Palette.get_color("card", "frame")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(12)
	_frame.add_theme_stylebox_override("panel", style)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	_frame.add_child(body)
	body.add_child(_label("读入录像", 21))
	var location := HBoxContainer.new()
	body.add_child(location)
	location.add_child(_button("上一级", func(): _browse(_directory.get_base_dir())))
	location.add_child(_button("录像目录", func(): _browse(Tape.path_dir())))
	_path_edit = LineEdit.new()
	_path_edit.name = "ReplayPath"
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.placeholder_text = "录像文件或目录路径"
	_path_edit.text_submitted.connect(func(_text): _open_selected())
	body.add_child(_path_edit)
	_files = ItemList.new()
	_files.name = "ReplayFiles"
	_files.custom_minimum_size = Vector2(540, 240)
	_files.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_files.item_selected.connect(_select)
	_files.item_activated.connect(_activate)
	_files.add_theme_font_override("font", Fonts.zh())
	_files.add_theme_font_size_override("font_size", 17)
	_files.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	body.add_child(_files)
	_status = _label("", 15)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_status)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	body.add_child(actions)
	actions.add_child(_button("取消", close))
	var load_button := _button("读入", _open_selected)
	load_button.name = "ReplayLoad"
	actions.add_child(load_button)
	DirAccess.make_dir_recursive_absolute(Tape.path_dir())
	_browse(Tape.path_dir())
	if _main.drawer_presentation:
		_main.drawer_presentation.register_result_panel(self)

func _label(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.set_meta("drawer_font_base", font_size)
	label.add_theme_font_override("font", Fonts.zh())
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Palette.get_color("card", "body"))
	return label

func _button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(90, 38)
	button.pressed.connect(callback)
	return button

func _browse(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		_status.text = "无法打开目录"
		return
	_directory = directory.get_current_dir()
	_path_edit.text = _directory
	_files.clear()
	_entries.clear()
	_directories.clear()
	var directories := directory.get_directories()
	var files := directory.get_files()
	directories.sort()
	files.sort()
	for name in directories:
		_add_entry(name, true)
	for name in files:
		if name.get_extension().to_lower() == "json":
			_add_entry(name, false)
	_status.text = "此目录没有录像" if files.is_empty() and directories.is_empty() else ""

func _add_entry(file: String, directory: bool) -> void:
	_entries.append(_directory.path_join(file))
	_directories.append(directory)
	_files.add_item(file + "/" if directory else file)

func _select(index: int) -> void:
	if index >= 0 and index < _entries.size():
		_path_edit.text = _entries[index]
		_status.text = ""

func _activate(index: int) -> void:
	_select(index)
	_open_selected()

func _open_selected() -> void:
	var path := _path_edit.text.strip_edges()
	if path.begins_with("~/"):
		path = OS.get_environment("HOME").path_join(path.substr(2))
	if DirAccess.dir_exists_absolute(path):
		_browse(path)
		return
	if not FileAccess.file_exists(path):
		_status.text = "找不到这份录像"
		return
	var loaded: Dictionary = _main._load_replay(path)
	if not loaded.get("ok", false):
		_status.text = str(loaded.get("reason", "录像读取失败"))
		return
	file_selected.emit(path)
	hide()

func close() -> void:
	if _main.drawer_presentation:
		_main.drawer_presentation._suspended_panels.erase(self)
	queue_free()
