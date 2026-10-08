# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 悬浮说明按文字宽度排版 ===")
	for dpi in [1.0, 2.0]:
		root.size = Vector2i(roundi(1280 * dpi), roundi(800 * dpi))
		root.content_scale_size = Vector2i.ZERO
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		var main: Node = load("res://scenes/main.tscn").instantiate()
		main.force_drawer_layout = true
		main.drawer_ui_scale = dpi
		root.add_child(main)
		await create_timer(0.6).timeout
		main.drawer_window.set_process(false)
		main.drawer_presentation.set_process(false)
		var view: Node = main.drawer_presentation
		var cards: Array = []
		for id in ["cash", "user", "shuabuting"]:
			var data: Dictionary = main.state.add_card(main.my_seat, id)
			var card: CardEntity = main._spawn_entity(data, Vector3(0, 0.05, 3.0), true)
			card.freeze = true
			cards.append(card)
		var short_width := 0.0
		var prefix := "%s倍DPI" % dpi
		for index in [0, 2, 1, 0]:
			view.show_card_detail(cards[index], Vector2(root.size) - Vector2(3, 150))
			var initial_size: Vector2 = view._detail.size
			check(Rect2(Vector2.ZERO, Vector2(root.size)).grow(1).encloses(view._detail.get_global_rect()),
				"%s%s：首帧已完成文字换行，不撑出窗口" % [prefix, cards[index].def_id])
			await process_frame
			view.show_card_detail(cards[index], Vector2(root.size) - Vector2(3, 150))
			var actual: Vector2 = view._detail.size
			check(actual.is_equal_approx(initial_size), "%s%s：首帧与稳定后尺寸相同" % [prefix, cards[index].def_id])
			var style: StyleBox = view._detail.get_theme_stylebox("panel")
			var natural := 0.0
			for label: Label in [view._detail_title, view._detail_flavor, view._detail_status, view._detail_text]:
				var font := label.get_theme_font("font")
				var fs := label.get_theme_font_size("font_size")
				for line in label.text.split("\n"):
					natural = maxf(natural, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
			var maximum := minf(view._px(300), root.size.x / 3.0)
			var expected := maxf(minf(ceilf(natural) + style.get_minimum_size().x, maximum),
				view._detail_facts.get_combined_minimum_size().x + style.get_minimum_size().x)
			check(absf(actual.x - expected) <= 1.0, "%s%s：宽度容纳文案、事实行和边距，长文按上限换行" % [prefix, cards[index].def_id])
			check(actual.x <= maximum + 1.0, "%s%s：事实行没有重复乘 DPI 撑破详情宽度上限" % [prefix, cards[index].def_id])
			check(Rect2(Vector2.ZERO, Vector2(root.size)).grow(1).encloses(view._detail.get_global_rect()), "%s%s：悬浮说明完整位于窗口内" % [prefix, cards[index].def_id])
			check(view._detail_text.get_global_transform_with_canvas().get_scale().is_equal_approx(Vector2.ONE), "%s%s：按原生字号排版而不缩放文字" % [prefix, cards[index].def_id])
			if index == 0:
				if short_width > 0:
					check(is_equal_approx(actual.x, short_width), "%s长说明切回短说明后恢复紧凑宽度" % prefix)
				short_width = actual.x
			if index == 2:
				check(actual.x > short_width + 30 * dpi, "%s长说明比资源说明更宽" % prefix)
		var long_card: CardEntity = cards[2]
		# 同名市场卡和自有卡应刷新是否显示价格，不能只按def_id缓存。
		long_card.is_market = true
		view.show_card_detail(long_card, Vector2(5, 150))
		check(view._detail_facts.get_child(0).text == "购买"
			and view._detail_facts.get_child(1).text == "%d 资金" % int(CardDB.get_def(long_card.def_id).price),
			"%s同名卡切到市场时显示实际购买价格" % prefix)
		long_card.is_market = false
		view.show_card_detail(long_card, Vector2(5, 150))
		check(view._detail_facts.get_child(0).text != "购买", "%s同名卡切回手牌不残留售价" % prefix)
		main.queue_free()
		await process_frame
		await process_frame
	finish()
