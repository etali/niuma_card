# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIPanel
extends Control

## 右上角「AI 强度」面板，贴在配色面板下方。
## 结构照着 scenes/palette_panel.gd：折叠标题栏、mouse_filter = STOP、
## _syncing 护栏。AI 参数仅保留在本次运行中，修改立即广播，下次启动恢复默认。
##
## 面板修改 engine/ai_search.gd 中本次运行的设置，不改变卡表或规则指纹。
## 对局中途调整不影响联网握手；下一次新搜索和选靶读取最新参数，
## 已开始的搜索和已生成的行动计划保留原有快照。
##
## 出厂默认强度0.5，1.0启用当前最大能力与计算预算。
## 模型选择与强度独立；模型和逐项控件都由参数元数据提供。
## 详见 `ai.md` §「默认档与局内调档」

## 贴在谁下面（配色面板）。它展开 / 收起会改自己的高度，
## 所以连它的 resized 信号，而不是记一个常量偏移 —— 记常量的话
## 配色面板一展开，两块面板就叠在一起
var above: Control

const GAP := 8               # 与上面那块面板的间距
const LIST_W := 268          # 与配色面板同宽，两块看着是一叠
const KNOBS_H := 280         # 参数再多也只滚动列表，还原按钮始终可见

var _body: VBoxContainer     # 折叠时隐藏的部分
var _toggle: Button
var _status: Label
var _slider: HSlider
var _slider_val: Label       # 收起时也看得见的档位读数
var _rows: Array = []        # [{key, kind, node}]，改强度之后要整体回填
var _model_choice: OptionButton
var _knobs_box: VBoxContainer
var _knobs_scroll: ScrollContainer
var _schema_model := ""
var _syncing := false        # 见 palette_panel.gd 类注释第 2 点


func _ready() -> void:
	name = "AIPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_build()
	AISearch.bus().changed.connect(_on_preferences_changed)
	_sync_rows()
	_relayout()
	if above != null:
		above.resized.connect(_relayout)
	# 内容自己变大变小的时候也要重算框子，不能只在展开/收起时算。
	# 实测漏掉的那处：_sync_rows 把档位读数改成带星号的（有逐项覆盖时），
	# 收起态下内容要 141 宽而框子还是 134，星号被切掉
	get_node("Frame").minimum_size_changed.connect(_relayout)
	get_viewport().size_changed.connect(_relayout)


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
	_body.visible = false        # 与 _build_header 里 _toggle.text = "展开" 对应
	root.add_child(_body)
	_model_choice = OptionButton.new()
	_model_choice.add_theme_font_override("font", Fonts.zh())
	_model_choice.item_selected.connect(_on_model)
	_body.add_child(_model_choice)
	_body.add_child(_build_slider_row())
	_body.add_child(_build_presets())
	_body.add_child(_label("修改立即生效，仅本次运行\n下次启动恢复默认强度", 12, Color(0.72, 0.82, 0.62)))
	_knobs_scroll = ScrollContainer.new()
	_knobs_scroll.custom_minimum_size = Vector2(LIST_W, KNOBS_H)
	_knobs_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_knobs_scroll.follow_focus = true
	_body.add_child(_knobs_scroll)
	_knobs_box = VBoxContainer.new()
	_knobs_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_knobs_box.add_theme_constant_override("separation", 3)
	_knobs_scroll.add_child(_knobs_box)
	_body.add_child(_build_footer())


## 标题栏。档位读数放在这里而不是 _body 里：面板平时是收起的，
## 「现在 AI 有多强」得在收起状态下也看得见
func _build_header() -> HBoxContainer:
	var hb := HBoxContainer.new()
	var title := _label("AI 强度", 16, Color(0.95, 0.93, 0.88))
	hb.add_child(title)

	_slider_val = _label("", 15, Color(0.85, 0.78, 0.55))
	_slider_val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hb.add_child(_slider_val)

	_toggle = Button.new()
	_toggle.text = "展开"
	_toggle.add_theme_font_override("font", Fonts.zh())
	_toggle.add_theme_font_size_override("font_size", 13)
	_toggle.pressed.connect(_on_toggle)
	hb.add_child(_toggle)
	return hb


## 连续强度滑块 —— 这是这个面板的主控件。
## 一个数管全部旋钮（AISearch.from_strength 那张梯子），
## 拖它等于「整档换掉」；下面那些行是想单独抠某一项时才用的
func _build_slider_row() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)

	_slider = HSlider.new()
	_slider.custom_minimum_size = Vector2(LIST_W, 20)
	_slider.min_value = 0.0
	_slider.max_value = 1.0
	_slider.step = 0.01
	_slider.value_changed.connect(_on_strength)
	col.add_child(_slider)
	col.add_child(_label("0 最弱 · 0.5 默认 · 1 最高", 12, Color(0.72,0.82,0.62)))
	return col


## 刻度名称共用 0~1 轴；各模型分别解析自己的预算。
const PRESET_LABELS := {
	"min": "最弱", "low": "低", "mid": "默认", "high": "高", "max": "最高",
}

## 档位快捷键。取的是 AISearch.PRESETS 里那几个名字 ——
## `tools/eval.sh` 的档位参数认的是同一批名字，面板和命令行说的是一种话
func _build_presets() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 4)
	for key in AISearch.PRESETS:
		var b := Button.new()
		b.text = str(PRESET_LABELS.get(key, key))
		b.tooltip_text = "强度 %.2f" % float(AISearch.PRESETS[key])
		b.add_theme_font_override("font", Fonts.zh())
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_on_preset.bind(float(AISearch.PRESETS[key])))
		hb.add_child(b)
	col.add_child(hb)
	return col


## 切换模型时按该模型的元数据重建；不保留上个模型的控件或信号。
func _rebuild_knobs(model: String) -> void:
	_rows.clear()
	for child in _knobs_box.get_children():
		_knobs_box.remove_child(child)
		child.queue_free()
	_schema_model = model
	_knobs_scroll.scroll_vertical = 0
	_knobs_box.add_child(_label("逐项（改任一项 = 自定义）", 13, Color(0.72, 0.82, 0.62)))
	var grouped := {}
	for spec in AISearch.editable_knobs(model):
		var group := str(spec.get("group", ""))
		if not grouped.has(group): grouped[group] = []
		grouped[group].append(spec)
	var groups := grouped.keys()
	var group_order := groups.duplicate()
	groups.sort_custom(func(a,b):
		if a.begins_with("设计能力") != b.begins_with("设计能力"): return a.begins_with("设计能力")
		return group_order.find(a) < group_order.find(b))
	for group in groups:
		if group != "": _knobs_box.add_child(_label(group,13,Color(0.85,0.78,0.55)))
		for spec in grouped[group]: _knobs_box.add_child(_build_knob_row(spec))


func _build_knob_row(k: Dictionary) -> HBoxContainer:
	var key := str(k["key"])
	var kind := str(k["kind"])
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)

	var lbl := _label(str(k["label"]), 12, Color(0.88, 0.86, 0.82))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.tooltip_text = str(k.get("hint", ""))
	lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	hb.add_child(lbl)

	var node: Control
	match kind:
		"bool":
			var cb := CheckBox.new()
			cb.toggled.connect(_on_knob_bool.bind(key))
			node = cb
		"enum":
			var choice := OptionButton.new()
			choice.add_theme_font_override("font", Fonts.zh())
			for option in k.get("options", []):
				choice.add_item(str(option["label"]))
				choice.set_item_metadata(choice.item_count - 1, option["value"])
			choice.item_selected.connect(_on_knob_enum.bind(key, choice))
			node = choice
		_:
			var sb := SpinBox.new()
			sb.min_value = float(k.get("min", 0))
			sb.max_value = float(k.get("max", 99))
			sb.step = float(k.get("step", 1.0 if kind == "int" else 0.01))
			sb.rounded = kind == "int"
			sb.custom_minimum_size = Vector2(86, 0)
			sb.value_changed.connect(_on_knob_number.bind(key, kind))
			sb.get_line_edit().text_changed.connect(_on_knob_text.bind(key, kind, sb))
			node = sb
	node.tooltip_text = str(k.get("hint", ""))
	hb.add_child(node)
	_rows.append({ "key": key, "kind": kind, "node": node })
	return hb


func _build_footer() -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)

	var reset := Button.new()
	reset.text = "还原默认"
	reset.add_theme_font_override("font", Fonts.zh())
	reset.add_theme_font_size_override("font_size", 13)
	reset.pressed.connect(_on_reset)
	hb.add_child(reset)

	_status = _label("", 12, Color(0.65, 0.75, 0.6))
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(_status)
	return hb


func _label(txt: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_override("font", Fonts.zh())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


# ---------- 改了之后 ----------

func _on_strength(v: float) -> void:
	if _syncing:
		return
	AISearch.set_pref_strength(v)   # 会清掉逐项覆盖：拖滑块 = 整档换掉
	_sync_rows()
	_status.text = ""

func _on_preset(v: float) -> void:
	AISearch.set_pref_strength(v)
	_sync_rows()
	_status.text = ""

func _on_knob_bool(on: bool, key: String) -> void:
	if _syncing:
		return
	AISearch.set_override(key, on)
	_sync_rows()
	_status.text = ""

func _on_knob_number(v: float, key: String, kind: String) -> void:
	if _syncing:
		return
	AISearch.set_override(key, int(v) if kind == "int" else v)
	_sync_rows()
	_status.text = ""


## 数字键入也立即生效；保留未完成的文本与光标，不把刚输入的首位夹取成最小值。
## apply() 让 SpinBox 自己完成步长量化并更新内部显示缓存，随后还原正在编辑的文本。
func _on_knob_text(text: String, key: String, kind: String, spinbox: SpinBox) -> void:
	if _syncing or not text.is_valid_float():
		return
	var value := text.to_float()
	if not is_finite(value) or value < spinbox.min_value or value > spinbox.max_value:
		return
	if kind == "int" and value != roundf(value):
		return
	var edit := spinbox.get_line_edit()
	var caret := edit.caret_column
	_syncing = true
	spinbox.apply()
	edit.text = text
	edit.caret_column = caret
	_syncing = false
	AISearch.set_override(key, int(spinbox.value) if kind == "int" else spinbox.value)
	_status.text = ""


func _on_knob_enum(index: int, key: String, choice: OptionButton) -> void:
	if _syncing:
		return
	AISearch.set_override(key, choice.get_item_metadata(index))
	_sync_rows()
	_status.text = ""


func _on_preferences_changed(_strength: float) -> void:
	_sync_rows()


## 把滑块和每一行拨回「偏好当前值」。
## 改强度会连带改所有旋钮，所以每次改动之后都整体回填一遍 ——
## 这也是 _syncing 护栏存在的理由：回填本身会触发 value_changed / toggled
func _sync_rows() -> void:
	_syncing = true
	var cfg := AISearch.prefs()
	var s := AISearch.pref_strength()
	if _model_choice != null:
		_sync_model_choices()
		for i in _model_choice.item_count:
			if str(_model_choice.get_item_metadata(i)) == cfg.model:
				_model_choice.select(i)
				break
	if _schema_model != cfg.model:
		_rebuild_knobs(cfg.model)
	if _slider != null:
		_slider.value = s
	for r in _rows:
		var node: Control = r["node"]
		if not is_instance_valid(node):
			continue
		var value: Variant = cfg.get_knob(str(r["key"]))
		match str(r["kind"]):
			"bool":
				(node as CheckBox).button_pressed = bool(value)
			"enum":
				var choice := node as OptionButton
				for i in choice.item_count:
					if choice.get_item_metadata(i) == value:
						choice.select(i)
						break
			_:
				(node as SpinBox).value = float(value)
	# 有逐项覆盖时给档位读数加个星号：那时候滑块的数已经不能完整描述 AI 的强度了，
	# 不标出来的话「滑块在 0 但 AI 在搜索」看着像 bug
	var star := "*" if AISearch.has_overrides() else ""
	if _slider_val != null:
		_slider_val.text = "%.2f%s" % [s, star]
	_syncing = false


func _sync_model_choices() -> void:
	var models := AISearch.models()
	var changed := models.size() != _model_choice.item_count
	if not changed:
		for i in models.size():
			if _model_choice.get_item_metadata(i) != models[i]["id"] \
					or _model_choice.get_item_text(i) != models[i]["label"]:
				changed = true
				break
	if not changed:
		return
	_model_choice.clear()
	for spec in models:
		_model_choice.add_item(str(spec["label"]))
		_model_choice.set_item_metadata(_model_choice.item_count - 1, str(spec["id"]))


## 三件事必须在同一帧里做完：body 的显隐、按钮文案、框子尺寸。
##
## 这里**不许**为了等 min size 去 await 一帧 —— 试过，那是个 bug：
## get_combined_minimum_size() 在改完 visible 的同一帧就已经是新值了
## （实测 134x44 → 284x440，同一帧就变，minimum_size_changed 晚一帧发但用不着它）。
## await 什么也没买到，代价是留出一帧：这一帧里 visible 和按钮文案都翻了、
## 框子还是旧的，协程要是没能恢复就永久停在这个样子 ——
## 「按钮写着展开、底下压着一大片空框子」正是这么来的
func _on_toggle() -> void:
	_body.visible = not _body.visible
	_toggle.text = "收起" if _body.visible else "展开"
	_relayout()


func _on_reset() -> void:
	AISearch.restore_defaults()
	_sync_rows()
	# 念的是还原之后**真正的**档位，不写死一个名字：出厂默认改过一次
	# （0 档贪心 → 满档），写死的那个字面量当时就地变成了假话
	_status.text = "已还原（强度 %.2f）" % AISearch.pref_strength()


## 锚在右上角、贴在 above 下方。理由同 palette_panel.gd 的 _relayout：
## 不设 offset_bottom 的话 Control 高度是 0，里头的 PanelContainer 撑不开
func _relayout() -> void:
	var pc := get_node_or_null("Frame") as PanelContainer
	if pc == null:
		return
	var want := pc.get_combined_minimum_size()
	var margin := 12.0
	var top := margin
	if above != null and is_instance_valid(above):
		top = above.offset_bottom + GAP
	if _body.visible:
		var available := get_viewport_rect().size.y - top - margin
		var fixed_height := want.y - _knobs_scroll.custom_minimum_size.y
		var scroll_height := clampf(available - fixed_height, 80.0, KNOBS_H)
		if not is_equal_approx(_knobs_scroll.custom_minimum_size.y, scroll_height):
			_knobs_scroll.custom_minimum_size.y = scroll_height
			want = pc.get_combined_minimum_size()
	offset_left = -want.x - margin
	offset_right = -margin
	offset_top = top
	offset_bottom = top + want.y


func _on_model(index: int) -> void:
	if _syncing:
		return
	AISearch.set_pref_model(str(_model_choice.get_item_metadata(index)))
	_sync_rows()
	_status.text = ""
