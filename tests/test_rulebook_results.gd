# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const DemoData = preload("res://scenes/rulebook_demo_data.gd")
const Arena = preload("res://scenes/rulebook_arena.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	paused = false
	var main: Node = await boot_main()
	main.sfx.set_user_muted(true)
	main.state.winner = main.my_seat
	main.state.win_reason = "对手资金归零"
	main._show_game_over()
	var actual: PanelContainer = main.game_over_panel
	for example in DemoData.examples("victory"):
		var viewport := SubViewport.new()
		viewport.size = Vector2i(760, 280)
		viewport.own_world_3d = true
		root.add_child(viewport)
		var arena := Arena.new()
		viewport.add_child(arena)
		arena.result_styler = main.drawer_presentation._apply_tree_theme if main.drawer_presentation else Callable()
		arena.configure(example, main.sfx)
		arena.assemble()
		arena.elapsed = 2.2
		arena.resolve()
		for i in 150:
			arena.advance_time(0.1)
			if is_instance_valid(arena.result_panel):
				break
		check(is_instance_valid(arena.result_panel), "%s由真实裁决触发结算组件" % example["title"])
		if is_instance_valid(arena.result_panel):
			var title: Label = arena.result_panel.find_child("ResultTitle", true, false)
			var reason: Label = arena.result_panel.find_child("ResultReason", true, false)
			check(title.text == ("失败" if example.get("lose", false) else "胜利"), "演示胜负按真实玩家视角展示")
			check(reason.text == arena.state.win_reason and not reason.text.is_empty(), "原因使用真实引擎结算文案")
			for name in ["ResultMascot", "ResultTitle", "ResultMessage", "ResultReason", "ResultRestart"]:
				check(arena.result_panel.find_child(name, true, false).get_class() == actual.find_child(name, true, false).get_class(), "%s与正式结算同一个控件结构" % name)
			for frame in 4:
				await process_frame
			var panel_size: Vector2 = arena.result_panel.size * arena._result_view["layer"].scale
			check(panel_size.x <= viewport.size.x and panel_size.y <= viewport.size.y, "共享结算组件适配演示视口且不裁切")
			var rendered_rect := Rect2(arena.result_panel.get_global_transform_with_canvas().origin, panel_size)
			check(rendered_rect.get_center().distance_to(Vector2(viewport.size) * 0.5) < 1.0,
				"共享结算组件缩放后仍居中于演示视口")
			check(panel_size.x > 300, "结算面板不能按未排版的长文本错误缩成小方块")
		viewport.queue_free()
		await process_frame
	main.queue_free()
	await process_frame
	finish()
