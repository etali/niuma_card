# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends VBoxContainer

## “怎么玩”的单一入口。选择课程后回到原牌桌，由小人对话引导。
const Catalog = preload("res://engine/tutorial_catalog.gd")
const Progress = preload("res://engine/tutorial_progress.gd")
const Content = preload("res://scenes/rulebook_content.gd")
const RuleAnimation = preload("res://scenes/rulebook_animation.gd")
const NAVIGATION := [["home", "hub.courses"], ["cards", "hub.cards"], ["upgrades", "hub.upgrades"]]

signal section_changed(index: int)
var demo: Control
var sections: Array = []
var section_buttons: Array[Button] = []
var current_section := 0
var current_page := "home"
var _presentation: Node
var _navigation: HFlowContainer
var _scroll: ScrollContainer
var _page: VBoxContainer
var _status: Label

func bind(presentation: Node) -> void:
	_presentation = presentation
	name = "Rulebook"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	sections = Content.sections()
	_navigation = HFlowContainer.new()
	_navigation.name = "LearningNavigation"
	add_child(_navigation)
	for entry in NAVIGATION:
		var button := _button(Catalog.ui(entry[1]), _navigate.bind(entry[0]))
		button.name = "Learning_" + entry[0]
		button.toggle_mode = true
		_navigation.add_child(button)
		section_buttons.append(button)
	_status = _label("")
	_status.hide()
	add_child(_status)
	_scroll = ScrollContainer.new()
	_scroll.name = "RulebookScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_scroll)
	_page = VBoxContainer.new()
	_page.name = "SectionContent"
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 12)
	_scroll.add_child(_page)
	show_home()

func _label(value: String, title := false) -> Label:
	var label: Label = _presentation._label(value, 19 if title else 15)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _button(value: String, callback: Callable) -> Button:
	var button: Button = _presentation._button(value, 15, true)
	button.pressed.connect(callback)
	return button

func _clear_page(page_id: String) -> void:
	for child in _page.get_children():
		child.process_mode = Node.PROCESS_MODE_DISABLED
		_page.remove_child(child)
		child.queue_free()
	demo = null
	current_page = page_id
	_status.hide()
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_page.size_flags_vertical = Control.SIZE_FILL
	_scroll.scroll_vertical = 0
	for i in section_buttons.size():
		var chosen: bool = NAVIGATION[i][0] == page_id or (i == 0 and page_id == "demo")
		section_buttons[i].set_pressed_no_signal(chosen)
		section_buttons[i].set_meta("ui_role", "primary" if chosen else "tool")
	_page.set_meta("section_id", page_id)

func _finish_page() -> void:
	_presentation._apply_tree_theme(self)
	_presentation._relayout_utility.call_deferred()

func _navigate(page_id: String) -> void:
	match page_id:
		"home": show_home()
		"cards", "upgrades": show_atlas(page_id)

func show_home() -> void:
	_clear_page("home")
	_page.add_child(_label(Catalog.ui("hub.short_intro")))
	var courses := Catalog.courses()
	if courses.is_empty():
		_page.add_child(_label(Catalog.ui("hub.empty")))
		_finish_page()
		return
	var resume := Progress.resume_id()
	var active: bool = is_instance_valid(_presentation.tutorial)
	if active:
		resume = str(_presentation.tutorial.session.course_id)
	if Catalog.course(resume).is_empty():
		resume = ""
	var start_id: String = resume if not resume.is_empty() else str(courses[0]["id"])
	var caption := Catalog.ui("hub.start") if resume.is_empty() else Catalog.ui("hub.resume", {"title": Catalog.course(resume)["title"]})
	if active:
		caption = Catalog.ui("hub.continue_active", {"title": Catalog.course(resume)["title"]})
	if resume.is_empty() and Progress.course(str(courses[0]["id"])).get("status", "") == "completed":
		caption = Catalog.ui("hub.again")
		for course in courses:
			if Progress.course(str(course["id"])).get("status", "") != "completed":
				start_id = str(course["id"])
				caption = Catalog.ui("hub.next_course", {"title": course["title"]})
				break
	var start := _button(caption, start_course.bind(start_id))
	start.name = "StartTutorial"
	start.set_meta("ui_role", "primary")
	_page.add_child(start)
	if active:
		_page.add_child(_label(Catalog.ui("hub.continue_active_hint")))
	elif not resume.is_empty():
		_page.add_child(_label(Catalog.ui("hub.resume_hint")))
	elif start_id == str(courses[0]["id"]):
		_page.add_child(_label(Catalog.ui("hub.first_round")))
	var course_list := VBoxContainer.new()
	course_list.name = "TutorialCourses"
	course_list.add_theme_constant_override("separation", 12)
	_page.add_child(course_list)
	for course in courses:
		var id := str(course["id"])
		var entry: Dictionary = Progress.course(id)
		var status := str(entry.get("status", "new"))
		var button := _button(str(course["title"]) + "  ·  " + Catalog.ui("hub." + status), start_course.bind(id))
		button.name = "Course_" + id
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		course_list.add_child(button)
	_finish_page()

func show_atlas(mode: String) -> void:
	_clear_page(mode)
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var atlas: Control = load("res://scenes/card_atlas.gd").new()
	_page.add_child(atlas)
	atlas.bind(_presentation, mode)
	_finish_page()

func start_course(id: String) -> void:
	if Catalog.course(id).is_empty(): return
	if not _presentation.start_tutorial(id):
		_status.text = Catalog.ui("hub.practice_blocked")
		_status.show()

## 保留共用动画的内部截图/回归入口，学习中心不提供规则速查页。
func select_section(index: int) -> void:
	if index < 0 or index >= sections.size(): return
	_clear_page("demo")
	current_section = index
	_page.add_child(_button(Catalog.ui("hub.back"), show_home))
	demo = RuleAnimation.new()
	_page.add_child(demo)
	demo.bind(_presentation, str(sections[index]["id"]))
	_finish_page()
	section_changed.emit(index)
