# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

## 真实抽屉场景的状态栏回归：长消息不能把顶部撑高，重复布局不能累积改变主题。
## 尺寸均为输出像素；2560×1600@2x 对应 1280×800 逻辑像素。
const LONG_MESSAGE := "资金不足，购买未完成；本回合仍可调整组合、补充现金或典当闲置卡牌。"
const MULTILINE_MESSAGE := "对手已经离线，请等待重新连接。\n当前回合、攻击点数和已经放好的组合均已保留。\n连接恢复后可以继续当前对局。"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉顶部与单行状态栏回归 ===")
	# 只改进程内主题，确保判的是奶油底；不读取截图流程，也不写用户配置或字体资源。
	Palette.set_color("world", "table_frame", Color("#F0E8D4"))
	for spec in DRAWER_VIEWPORT_CASES:
		var pixels: Vector2i = spec["pixels"]
		var dpi: float = spec["dpi"]
		var main: Node = await boot_drawer(pixels, dpi)
		if not need(is_instance_valid(main) and main.drawer_presentation != null,
				"%s：force_drawer_layout 建立真实展示层" % spec["name"]):
			if main != null:
				await dispose_drawer(main)
			continue
		await _exercise_messages(main, dpi, "%s 初始化" % spec["name"])

		# 先缩到另一尺寸，再恢复目标尺寸，真实触发 size_changed 与字体重新计算。
		await _resize(main, Vector2i(roundi(960 * dpi), roundi(600 * dpi)))
		await _resize(main, pixels)
		check(root.size == pixels, "%s：resize 后处于目标输出尺寸" % spec["name"])
		await _exercise_messages(main, dpi, "%s resize后" % spec["name"])
		await dispose_drawer(main)
	finish()

func _resize(main: Node, pixels: Vector2i) -> void:
	root.size = pixels
	main.drawer_presentation.relayout()
	for frame in 3:
		await process_frame

func _exercise_messages(main: Node, dpi: float, prefix: String) -> void:
	var view: Node = main.drawer_presentation
	var header: Control = view._header
	var footer: Control = view._footer
	var status: Label = main.lbl_msg
	main._show_message("轮到你行动", Palette.get_color("card", "body"))
	view.relayout()
	for frame in 3:
		await process_frame
	var header_height := header.size.y
	var footer_height := footer.size.y
	var footer_style: StyleBoxFlat = footer.get_theme_stylebox("panel")
	check(footer_style.bg_color.is_equal_approx(Color("#F0E8D4")),
		"%s：对比度判据使用实际奶油色底栏" % prefix)
	check(header_height / dpi < 80.0,
		"%s：顶部高度小于80逻辑像素（%.1f）" % [prefix, header_height / dpi])
	check(footer.is_ancestor_of(status) and not header.is_ancestor_of(status),
		"%s：即时提示位于底栏，不占顶部第二行" % prefix)
	check(status.mouse_filter != Control.MOUSE_FILTER_IGNORE,
		"%s：状态标签允许悬停查看完整提示" % prefix)

	var messages := [
		{ "name": "长黄色提示", "text": LONG_MESSAGE.repeat(8), "color": Color("#FFE66A") },
		{ "name": "多行绿色提示", "text": MULTILINE_MESSAGE, "color": Color("#A5F5C4") },
		{ "name": "多行白色提示", "text": MULTILINE_MESSAGE + "\n" + LONG_MESSAGE.repeat(3), "color": Color.WHITE },
	]
	for item in messages:
		var text: String = item["text"]
		main._show_message(text, item["color"])
		for frame in 2:
			await process_frame
		var before := _snapshot_text_theme([header, footer])
		var no_growth := true
		var stable_theme := true
		var single_line := true
		var usable_width := true
		var tooltip_complete := true
		var readable := true
		var inside_footer := true
		var minimum_width := INF
		var minimum_contrast := INF
		for pass_index in 10:
			view.relayout()
			await process_frame
			no_growth = no_growth and absf(header.size.y - header_height) <= 0.5 \
				and header.size.y / dpi < 80.0 and absf(footer.size.y - footer_height) <= 0.5
			stable_theme = stable_theme and _same_text_theme(before)
			single_line = single_line and status.is_visible_in_tree() \
				and status.text.contains(text.get_slice("\n", 0)) and status.get_line_count() == 1 \
				and not status.text.contains("\n") and status.size.y < 36.0 * dpi
			minimum_width = minf(minimum_width, status.size.x / dpi)
			usable_width = usable_width and status.size.x / dpi >= 200.0
			tooltip_complete = tooltip_complete and status.tooltip_text == text
			var panel: StyleBoxFlat = footer.get_theme_stylebox("panel")
			var actual_ink := status.get_theme_color("font_color") * status.modulate * status.self_modulate
			var ratio := _contrast(actual_ink, panel.bg_color)
			minimum_contrast = minf(minimum_contrast, ratio)
			readable = readable and ratio >= 4.5 and is_equal_approx(actual_ink.a, 1.0)
			inside_footer = inside_footer and footer.get_global_rect().grow(0.5).encloses(status.get_global_rect())
		var label := "%s %s，连续10次relayout" % [prefix, item["name"]]
		check(no_growth, "%s：顶部和底栏不随消息变高" % label)
		check(single_line, "%s：消息实际只占一行" % label)
		check(usable_width and inside_footer,
			"%s：状态位至少200逻辑像素宽且位于底栏内（最小%.1f）" % [label, minimum_width])
		check(tooltip_complete, "%s：tooltip逐字保留完整原文和换行" % label)
		check(readable, "%s：亮色消息与奶油底对比度至少4.5（最小%.2f）" % [label, minimum_contrast])
		check(stable_theme, "%s：顶部和底栏的字体、字号和颜色不漂移" % label)

func _snapshot_text_theme(roots: Array) -> Array:
	var result: Array = []
	for node: Node in roots:
		if node is Label or node is Button:
			result.append({ "control": node, "font": node.get_theme_font("font"),
				"size": node.get_theme_font_size("font_size"), "color": node.get_theme_color("font_color") })
		result.append_array(_snapshot_text_theme(node.get_children()))
	return result

func _same_text_theme(before: Array) -> bool:
	if before.is_empty():
		return false
	for item in before:
		var control: Control = item["control"]
		if control.get_theme_font("font") != item["font"] \
				or control.get_theme_font_size("font_size") != item["size"] \
				or not control.get_theme_color("font_color").is_equal_approx(item["color"]):
			return false
	return true

# 独立计算 sRGB 相对亮度，不用被测 readable_ink 返回的结果作为预期值。
func _linear_channel(channel: float) -> float:
	return channel / 12.92 if channel <= 0.04045 else pow((channel + 0.055) / 1.055, 2.4)

func _luminance(color: Color) -> float:
	return 0.2126 * _linear_channel(color.r) + 0.7152 * _linear_channel(color.g) + 0.0722 * _linear_channel(color.b)

func _contrast(ink: Color, surface: Color) -> float:
	var ink_luminance := _luminance(ink)
	var surface_luminance := _luminance(surface)
	return (maxf(ink_luminance, surface_luminance) + 0.05) / (minf(ink_luminance, surface_luminance) + 0.05)
