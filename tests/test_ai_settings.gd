# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Registry = preload("res://engine/ai_strategy_registry.gd")

class ProbeStrategy:
	extends AIStrategy

	func identifier() -> String:
		return "ui_schema_probe"

	func display_name() -> String:
		return "控件接口测试"

	func parameter_schema() -> Array:
		return [
			{"key": "count", "label": "整数", "group": "测试参数", "kind": "int",
				"min": 1, "max": 10, "step": 1, "default": 2, "strength_range": [2, 8]},
			{"key": "weight", "label": "小数", "group": "测试参数", "kind": "float",
				"min": 0.0, "max": 1.0, "step": 0.05, "default": 0.2, "strength_range": [0.2, 0.8]},
			{"key": "enabled", "label": "开关", "group": "测试参数", "kind": "bool", "default": false},
			{"key": "policy", "label": "枚举", "group": "测试参数", "kind": "enum", "default": "first",
				"options": [{"value": "first", "label": "第一项"}, {"value": "second", "label": "第二项"}]},
		]

## 独立起面板，核对注册模型、完整参数 schema、浮点输入与外部同步。
## 备份整份用户文件，保存 / 还原按钮也走真实路径。
var _real := PackedByteArray()
var _had := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_had = FileAccess.file_exists(AISearch.USER_PATH)
	if _had:
		_real = FileAccess.get_file_as_bytes(AISearch.USER_PATH)
	AISearch.restore_defaults()
	AISearch.set_pref_strength(0.45)
	var panel := AIPanel.new()
	root.add_child(panel)
	await process_frame

	_t_models(panel)
	_t_schema(panel)
	_t_external_sync(panel)
	await _t_scroll(panel)
	_t_float_roundtrip(panel)
	_t_additional_model(panel)

	panel.queue_free()
	await process_frame
	Registry.unregister("ui_schema_probe")
	_restore()
	finish()


func _t_models(panel: AIPanel) -> void:
	var registered := AISearch.models()
	check(panel._model_choice.item_count == registered.size(), "模型菜单来自注册列表")
	var ids := []
	for i in panel._model_choice.item_count:
		ids.append(str(panel._model_choice.get_item_metadata(i)))
		check(panel._model_choice.get_item_text(i) == str(registered[i]["label"]),
			"模型名称来自元数据：%s" % str(registered[i]["id"]))
	check(ids.has("ai") and not ids.has("v1") and not ids.has("v2"), "菜单只提供AI，不保留旧版本入口")
	check(panel._model_choice.visible, "只有一个模型也显示当前模型")
	check(str(panel._model_choice.get_item_metadata(panel._model_choice.selected))
		== AISearch.pref_model(), "模型菜单当前项与生效模型一致")
	panel._model_choice.item_selected.emit(panel._model_choice.selected)
	check(AISearch.prefs().model == "ai", "菜单信号选择注册模型")
	panel._slider.value = 0.0
	check(AISearch.prefs().model == "ai" and AISearch.prefs().strength == 0.0,
		"滑块归零使用当前模型的最低档")


func _t_schema(panel: AIPanel) -> void:
	var specs := AISearch.editable_knobs(AISearch.pref_model())
	check(panel._rows.size() == specs.size() and specs.size() > 10,
		"面板显示全部搜索预算与估值系数（%d 项）" % panel._rows.size())
	var wrong := []
	var floats := 0
	for i in mini(panel._rows.size(), specs.size()):
		var row: Dictionary = panel._rows[i]
		var spec: Dictionary = specs[i]
		var node: Control = row["node"]
		if row["key"] != spec["key"] or row["kind"] != spec["kind"]:
			wrong.append(str(spec["key"]))
			continue
		match str(spec["kind"]):
			"int", "float":
				if not node is SpinBox:
					wrong.append(str(spec["key"]))
					continue
				var sb := node as SpinBox
				if not is_equal_approx(sb.min_value, float(spec["min"])) \
						or not is_equal_approx(sb.max_value, float(spec["max"])) \
						or not is_equal_approx(sb.step, float(spec["step"])):
					wrong.append(str(spec["key"]))
				if spec["kind"] == "float":
					floats += 1
			"bool":
				if not node is CheckBox:
					wrong.append(str(spec["key"]))
			"enum":
				if not node is OptionButton:
					wrong.append(str(spec["key"]))
	check(wrong.is_empty(), "控件类型、范围和步进逐项来自 schema（失配：%s）" % str(wrong))
	check(floats > 0, "估值系数提供浮点控件")
	check(not _visible_text(panel).contains(AISearch.prefs().describe()), "AI强度面板不显示无意义的配置摘要")


func _t_external_sync(panel: AIPanel) -> void:
	AISearch.set_pref_strength(0.73)
	check(is_equal_approx(panel._slider.value, 0.73), "外部偏好变化会同步面板")
	check(not AISearch.has_overrides(), "外部同步不会反向写出覆盖")
	var row: Dictionary = panel._rows[0]
	var sb := row["node"] as SpinBox
	var desired := sb.max_value if not is_equal_approx(sb.value, sb.max_value) else sb.min_value
	AISearch.set_override(str(row["key"]), desired)
	check(is_equal_approx(sb.value, desired) and panel._slider_val.text.ends_with("*"),
		"外部自定义参数回填控件并显示星号")
	AISearch.set_pref_strength(0.45)
	check(not AISearch.has_overrides() and not panel._slider_val.text.ends_with("*"),
		"换强度清空覆盖并同步星号")


func _t_scroll(panel: AIPanel) -> void:
	panel._toggle.pressed.emit()
	await process_frame
	await process_frame
	check(panel._knobs_box.get_parent() == panel._knobs_scroll,
		"参数控件位于滚动列表中")
	check(panel._knobs_scroll.size.y <= 320.0,
		"参数列表高度有界（%.0f 像素）" % panel._knobs_scroll.size.y)
	check(panel._knobs_scroll.get_v_scroll_bar().max_value > panel._knobs_scroll.size.y,
		"所有参数可滚动访问")
	var save := _button(panel, "保存")
	check(save != null and not panel._knobs_scroll.is_ancestor_of(save),
		"保存按钮位于滚动列表外，始终可见")


func _t_float_roundtrip(panel: AIPanel) -> void:
	var float_row := {}
	for row in panel._rows:
		if str(row["kind"]) == "float":
			float_row = row
			break
	if not need(not float_row.is_empty(), "存在可测试的浮点系数"):
		return
	var key := str(float_row["key"])
	var sb := float_row["node"] as SpinBox
	var wanted := sb.value + sb.step
	if wanted > sb.max_value:
		wanted = sb.value - sb.step
	sb.value = wanted
	check(is_equal_approx(float(AISearch.prefs().get_knob(key)), wanted),
		"浮点控件信号把小数系数写入真实配置")
	check(panel._slider_val.text.ends_with("*"), "自定义系数显示星号")
	_button(panel, "保存").pressed.emit()
	AISearch._reset_pref_cache()
	check(is_equal_approx(float(AISearch.prefs().get_knob(key)), wanted),
		"浮点系数保存重读保留精度")
	check(AISearch.prefs().model == "ai", "保存重读保留所选模型")
	_button(panel, "还原默认").pressed.emit()
	check(not AISearch.has_overrides() and not panel._slider_val.text.ends_with("*"),
		"还原按钮清除自定义系数并同步显示")


func _t_additional_model(panel: AIPanel) -> void:
	check(Registry.register(ProbeStrategy.new()), "注册额外模型，验证面板无需模型专用分支")
	panel._sync_rows()
	var index := -1
	var original_index := panel._model_choice.selected
	for i in panel._model_choice.item_count:
		if panel._model_choice.get_item_metadata(i) == "ui_schema_probe":
			index = i
	if not need(index >= 0, "新注册模型自动进入菜单"):
		return
	var old_node: Control = panel._rows[0]["node"]
	panel._model_choice.select(index)
	panel._model_choice.item_selected.emit(index)
	check(AISearch.pref_model() == "ui_schema_probe" and panel._rows.size() == 4,
		"选择另一模型会切换实际配置并重建其四类控件")
	check(not panel.is_ancestor_of(old_node), "切换模型移除前一模型的控件")
	check(not AISearch.has_overrides(), "切换模型从所选强度开始，没有旧覆盖")
	var by_key := {}
	for row in panel._rows:
		by_key[str(row["key"])] = row["node"]
	if not need(by_key.has_all(["count", "weight", "enabled", "policy"]), "新 schema 的键全部出现"):
		return
	(by_key["count"] as SpinBox).value = 4
	(by_key["weight"] as SpinBox).value = 0.35
	(by_key["enabled"] as CheckBox).button_pressed = true
	var choice := by_key["policy"] as OptionButton
	choice.select(1)
	choice.item_selected.emit(1)
	var cfg := AISearch.prefs()
	check(cfg.get_knob("count") == 4 and is_equal_approx(float(cfg.get_knob("weight")), 0.35)
			and cfg.get_knob("enabled") == true and cfg.get_knob("policy") == "second",
		"int / float / bool / enum 的真实控件信号全部写入对应模型参数")
	check(panel._slider_val.text.ends_with("*"), "另一模型的覆盖也显示自定义星号")

	panel._syncing = true
	choice.item_selected.emit(0)
	panel._syncing = false
	check(AISearch.prefs().get_knob("policy") == "second", "枚举同步护栏阻止回填信号写入")
	var emitted := [0]
	var counter := func(_strength: float): emitted[0] += 1
	AISearch.bus().changed.connect(counter)
	AISearch.set_pref_strength(0.0)
	AISearch.bus().changed.disconnect(counter)
	check(emitted[0] == 1 and not AISearch.has_overrides(),
		"跨四类控件的回填只广播一次，不产生递归覆盖")
	check(not (by_key["enabled"] as CheckBox).button_pressed
			and choice.get_item_metadata(choice.selected) == "first", "换档会回填布尔和枚举默认值")

	(by_key["enabled"] as CheckBox).button_pressed = true
	choice.select(1)
	choice.item_selected.emit(1)
	_button(panel, "保存").pressed.emit()
	AISearch._reset_pref_cache()
	check(AISearch.pref_model() == "ui_schema_probe" and AISearch.prefs().get_knob("enabled") == true
			and AISearch.prefs().get_knob("policy") == "second", "额外模型、布尔与枚举覆盖保存重读一致")
	panel._model_choice.select(original_index)
	panel._model_choice.item_selected.emit(original_index)
	check(AISearch.prefs().model == "ai" and panel._rows.size() == AISearch.editable_knobs().size()
			and not AISearch.has_overrides(), "切回原模型重建其参数列表并清理其他模型覆盖")


func _button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child in node.get_children():
		var found := _button(child, text)
		if found != null:
			return found
	return null


func _restore() -> void:
	AISearch.restore_defaults()
	if _had:
		var file := FileAccess.open(AISearch.USER_PATH, FileAccess.WRITE)
		if file != null:
			file.store_buffer(_real)
			file.close()
	AISearch._reset_pref_cache()

func _visible_text(node: Node) -> String:
	var text := ""
	if node is Label:
		text += node.text
	for child in node.get_children():
		text += _visible_text(child)
	return text
