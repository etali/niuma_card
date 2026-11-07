# SPDX-License-Identifier: AGPL-3.0-only
extends "res://scenes/rulebook.gd"

func show_home() -> void:
	_clear_page("home")
	_page.add_child(_label("引导课可以慢慢操作，需要观察生产、道具生效或冷却时才计时。独立对局按正式节奏进行，退出教学会回到原局。"))
	var host: Node = _presentation.host
	var active: bool = not host.practice.is_empty()
	var start := _button("继续本课" if active else "开始学习", _presentation.close_panels if active else start_course.bind("first"))
	start.name = "StartTutorial"
	start.set_meta("ui_role", "primary")
	start.disabled = host.replay.playing or host.shift_network_live()
	_page.add_child(start)
	var course_list := VBoxContainer.new()
	course_list.name = "TutorialCourses"
	course_list.add_theme_constant_override("separation", 12)
	_page.add_child(course_list)
	for course in host.lesson.courses():
		var saved := Progress.course(str(course.id), true)
		var status := str(saved.get("status", "new"))
		var button := _button(str(course.title) + "  ·  " + Catalog.ui("hub." + status), start_course.bind(str(course.id)))
		button.name = "PracticeWork" if course.id == "first" else "WorkLesson_" + str(course.id)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.disabled = start.disabled
		course_list.add_child(button)
		course_list.add_child(_label(str(course.goal)))
	_finish_page()

func show_atlas(mode: String) -> void:
	_clear_page(mode)
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var atlas := preload("res://scenes/off_work_card_atlas.gd").new()
	_page.add_child(atlas)
	atlas.bind(_presentation, mode)
	_finish_page()

func start_course(id: String) -> void:
	_presentation.host.begin_practice(id)
