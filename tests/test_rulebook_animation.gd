# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Demos = preload("res://scenes/rulebook_demo_data.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	for section in ["victory", "purchase", "combos", "attack", "pawn", "buffs"]:
		var examples := Demos.examples(section)
		check(not examples.is_empty(), "%s有可选动画例子" % section)
		for example in examples:
			check(not example["inputs"].is_empty() and example["captions"].size() == 3, "%s演示有输入与三步讲解" % example["title"])
			if example.has("effect"):
				check(example["effect"]["valid"], "%s演示使用有效的真实组合" % example["title"])
	check(Demos.examples("victory").size() == 6, "分别演示三种获胜与三种失败")
	var original: Dictionary = CardDB.CARDS["yunketang"].duplicate(true)
	CardDB.CARDS["yunketang"]["recipe_n"] = 17
	CardDB.CARDS["yunketang"]["output_n"] = 31
	var found := false
	for example in Demos.examples("combos"):
		if example["mode"] == "production" and example["inputs"][0]["id"] == "yunketang":
			found = example["inputs"][1]["count"] == 17 and example["output"]["count"] == 31
	check(found, "动画的材料与产出数字随配置变化")
	CardDB.CARDS["yunketang"] = original
	root.size = Vector2i(1280, 800)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	await settle()
	var view: Node = main.drawer_presentation
	view._rulebook_button.pressed.emit()
	var book: Node = view._rulebook
	for section in book.sections.size():
		book.select_section(section)
		await process_frame
		var demo: Node = book.demo
		demo.set_playing(false)
		var first: String = demo._caption.text
		check(demo._stage.motions.get_script() == main._card_motion.get_script(),
			"演示与对局使用同一张CardMotion脚本")
		check(demo._stage.sfx == main.sfx, "规则演示和游玩直接共用当前音效服务与静音开关")
		var cards: Array = demo._stage.entities.values()
		check(not cards.is_empty() and cards.all(func(card): return card is CardEntity),
			"每张演示卡都是正式CardEntity而非另画的Control")
		check(cards[0]._plate.material_override.shader == load(CardEntity.PLATE_SHADER),
			"演示卡使用对局原有卡面Shader")
		var state_hash := StateCodec.state_hash(main.state)
		demo.set_playing(true)
		demo._process(1.0)
		check(demo._stage.phase == 1 and demo._caption.text != first, "第%d章真实编组推进且解说同步" % section)
		demo._process(1.3)
		check(demo._stage.phase >= 2, "第%d章真实裁决与动画已启动" % section)
		check(StateCodec.state_hash(main.state) == state_hash, "演示不改变真实牌局")
		demo.select_example(0)
		check(demo.progress == 0 and demo.playing, "重播创建独立初始牌桌")
		demo._play.pressed.emit()
		check(not demo.playing and demo._stage.process_mode == Node.PROCESS_MODE_DISABLED, "可暂停真实卡牌动画")
		var t: float = demo.progress
		demo._process(0.25)
		check(demo.progress == t, "暂停时进度不变化")
		demo._play.pressed.emit()
		main.drawer_window.collapse_now()
		demo._process(0.25)
		check(demo.progress == t and demo._stage.process_mode == Node.PROCESS_MODE_DISABLED, "抽屉收起时动画与场景一起暂停")
		main.drawer_window.pin()
	book.select_section(2)
	var upgrade_demo: Node = book.demo
	for index in upgrade_demo.examples.size():
		var example: Dictionary = upgrade_demo.examples[index]
		if example["mode"] != "upgrade":
			continue
		upgrade_demo.select_example(index)
		upgrade_demo.set_playing(false)
		for i in example["variants"].size():
			var variant: Dictionary = example["variants"][i]
			var label: Label = upgrade_demo._comparisons.get_child(i)
			check(label.text.contains(variant["material_label"]) and label.text.contains("×%d" % variant["count"]),
				"动画路线标签展示当前材料种类和精确张数")
			if CardDB.get_def(variant["target_id"]).get("kind") == CardDB.KIND_LEGEND:
				check(label.text.contains("同档") and label.text.contains("可异名"), "动画传说路线不再要求同名材料")
		break
	book.select_section(0)
	var ended_demo: Node = book.demo
	ended_demo.set_playing(false)
	ended_demo._stage.state.winner = ended_demo._stage.my_seat
	ended_demo._stage.state.win_reason = "资金达标"
	ended_demo._stage._announce_victory()
	for frame in 5:
		await process_frame
	var old_stage_id: int = ended_demo._stage.get_instance_id()
	var restart: Button = ended_demo._stage.result_panel.find_child("ResultRestart", true, false)
	var click_at: Vector2 = ended_demo._container.global_position + restart.get_global_transform_with_canvas() * (restart.size / 2)
	var motion := InputEventMouseMotion.new()
	motion.position = click_at
	root.push_input(motion)
	for pressed in [true, false]:
		var mouse := InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.position = click_at
		mouse.pressed = pressed
		root.push_input(mouse)
		await process_frame
	for frame in 2:
		await process_frame
	check(ended_demo._stage.get_instance_id() != old_stage_id, "结束后演示已暂停，共享结算面板的重播按钮仍能真实点击")
	view.close_panels()
	main.save_notice.show_saved("/tmp/test.record", 12)
	check(not main.save_notice._hint.visible and main.save_notice._hint.text.is_empty(), "保存成功只展示路径及按钮，不显示无用说明")
	for id in [0, 1, 3, 4, 5]:
		view._open_utility(id)
		check(view.find_child("OptionTabs", true, false) == null, "%d选项页无重复tab入口" % id)
	main.queue_free()
	await process_frame
	paused = false
	finish()
