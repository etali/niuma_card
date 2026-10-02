# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends VBoxContainer

## 章节只展示真实牌桌组件驱动的动画，没有独立绘制的卡牌和静态规则区块。
## 父容器需要提供有限高度并使用 SIZE_EXPAND_FILL，长章节由内部滚动区承载。
const Content = preload("res://scenes/rulebook_content.gd")
const RuleAnimation = preload("res://scenes/rulebook_animation.gd")
var demo: Control

signal section_changed(index: int)

var sections: Array = []
var section_buttons: Array[Button] = []
var current_section := 0
var _presentation: Node
var _navigation: HFlowContainer
var _scroll: ScrollContainer
var _page: VBoxContainer


func bind(presentation: Node) -> void:
	_presentation = presentation
	name = "Rulebook"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 12)
	sections = Content.sections()
	_build_navigation()
	_scroll = ScrollContainer.new()
	_scroll.name = "RulebookScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.follow_focus = true
	add_child(_scroll)
	_page = VBoxContainer.new()
	_page.name = "SectionContent"
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 14)
	_scroll.add_child(_page)
	select_section(0)


func _build_navigation() -> void:
	_navigation = HFlowContainer.new()
	_navigation.name = "ChapterTabs"
	_navigation.add_theme_constant_override("h_separation", 6)
	_navigation.add_theme_constant_override("v_separation", 6)
	add_child(_navigation)
	var group := ButtonGroup.new()
	for index in sections.size():
		var section: Dictionary = sections[index]
		var button: Button = _presentation._button(str(section.get("title", "")), 15, true)
		button.name = "Chapter_" + str(section.get("id", index))
		button.toggle_mode = true
		button.button_group = group
		button.pressed.connect(select_section.bind(index))
		button.tooltip_text = str(section.get("summary", ""))
		_navigation.add_child(button)
		section_buttons.append(button)


func select_section(index: int) -> void:
	if index < 0 or index >= sections.size():
		return
	current_section = index
	for button_index in section_buttons.size():
		var button: Button = section_buttons[button_index]
		var selected := button_index == index
		button.set_pressed_no_signal(selected)
		button.set_meta("ui_role", "primary" if selected else "tool")
		_presentation._apply_tree_theme(button)
	for child in _page.get_children():
		_page.remove_child(child)
		child.queue_free()
	var section: Dictionary = sections[index]
	_page.set_meta("section_id", section.get("id", ""))
	demo = RuleAnimation.new()
	_page.add_child(demo)
	demo.bind(_presentation, str(section["id"]))
	_presentation._apply_tree_theme(self)
	_scroll.scroll_vertical = 0
	section_changed.emit(index)
