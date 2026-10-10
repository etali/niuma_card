# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/support/drawer_fixture.gd"

const Session = preload("res://engine/tutorial_session.gd")
var _punctuation := RegEx.new()
var _quantities := RegEx.new()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# 编辑器内置 ICU 数据，即使漏导出也能通过中文排版测试；必须另守住发布配置。
	check(ProjectSettings.get_setting("internationalization/locale/include_text_server_data", false),
		"发布包携带ICU中文断词数据，不把空格后的整句当成一个长词")
	_punctuation.compile("[\\p{P}\\p{Z}\\p{C}]")
	_quantities.compile("[0-9]+\\x{2060}张")
	var examples := _examples()
	check(examples.size() == 124, "覆盖42步目标、40句完成结果和42句回滚说明")
	var main: Node = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null, "真实牌桌启动用于验证Label实际字形断行"): return
	var p: Node = main.drawer_presentation
	p.start_tutorial("income")
	var player: Node = p.tutorial
	for cfg in [
		[Vector2i(1280, 800), 1.0, false], [Vector2i(960, 600), 1.0, false],
		[Vector2i(844, 390), 1.0, true], [Vector2i(390, 844), 1.0, true],
		[Vector2i(2560, 1600), 2.0, false], [Vector2i(2358, 846), 2.0, false]
	]:
		root.size = cfg[0]
		p._ui_scale = cfg[1]
		main.mobile_mode = cfg[2]
		var orphaned: Array = []
		var split_quantities: Array = []
		var outside: Array = []
		var modified: Array = []
		for example in examples:
			var label: Label = player._goal
			label.text = example.text
			await relayout_drawer(main)
			var lines := _actual_lines(label)
			if lines.size() > 1:
				for index in [0, lines.size() - 1]:
					if _punctuation.sub(lines[index], "", true).length() <= 1:
						orphaned.append({"id": example.id, "width": label.size.x, "lines": lines})
						break
			for quantity in _quantities.search_all(label.text):
				if not is_equal_approx(label.get_character_bounds(quantity.get_start()).position.y,
					label.get_character_bounds(quantity.get_end() - 1).position.y):
					split_quantities.append(example.id)
			if not player._bubble.get_global_rect().grow(1).encloses(label.get_global_rect()) \
				or label.get_minimum_size().y > label.size.y + 1:
				outside.append(example.id)
			if label.text != example.text: modified.append(example.id)
			if example.id == "buff.spare.goal":
				print("SCREENSHOT_SENTENCE ", JSON.stringify({"screen": str(cfg[0]), "dpi": cfg[1],
					"font_size": label.get_theme_font_size("font_size"), "width": label.size.x, "lines": lines}))
		var title := "%s@%sx" % [cfg[0], cfg[1]]
		check(orphaned.is_empty(), title + "全部实际Label首尾行不留单字：" + JSON.stringify(orphaned))
		check(split_quantities.is_empty(), title + "数量和张保持同一行：" + JSON.stringify(split_quantities))
		check(outside.is_empty(), title + "气泡包住全部真实文字：" + JSON.stringify(outside))
		check(modified.is_empty(), title + "排版不改配置内容，不插入手工换行")
	p.finish_tutorial(false)
	await dispose_drawer(main)
	finish()

func _examples() -> Array:
	var examples: Array = []
	for course in TutorialCatalog.courses():
		var session := Session.new(course.id)
		for index in course.steps.size():
			session.step_index = index
			var step := session.current_step()
			examples.append({"id": step.id + ".goal", "text": step.goal})
			if not str(step.get("completion_goal", "")).is_empty():
				examples.append({"id": step.id + ".completion_goal", "text": TutorialCatalog.ui("coach.tap_continue", {"goal": step.completion_goal})})
			examples.append({"id": step.id + ".rollback", "text": TutorialCatalog.ui("operation_rollback", {"goal": step.goal})})
	return examples

func _actual_lines(label: Label) -> Array:
	# get_character_bounds读取真实Label排版结果，不能仅凭同一测量函数自证正确。
	var rows := {}
	for index in label.text.length():
		if label.text[index] == "\u2060": continue
		var y := roundi(label.get_character_bounds(index).position.y)
		if not rows.has(y): rows[y] = ""
		rows[y] += label.text[index]
	return rows.values()
