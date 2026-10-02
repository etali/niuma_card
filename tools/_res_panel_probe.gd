# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 手跑探针：左上角资源面板到右侧那两块面板之间还剩多少。
##
## 判据里那句「不会横过去压到右上角选色面板」是**几何断言**，
## 而 headless 下窗口尺寸是默认值、右侧面板贴的是右边缘 —— 量出来的数
## 和真窗口下不一样。所以这一条不进 tests/：它是一次性的量尺，
## 结论写进代码注释（RES_PANEL_W 那条）。
##
## 跑法（**要开窗口，别加 --headless**）：
##   /Applications/Godot.app/Contents/MacOS/Godot -s tools/_res_panel_probe.gd

func _initialize() -> void:
	print("=== 资源面板横向余量 ===")
	var main: Node = await boot_main()
	if not need(main != null, "场景起得来"):
		finish()
		return
	# 把两条读数灌成最长那个形态，逼出面板的真实宽度
	main.lbl_player_res.text = "你的公司 · 资金 10（本回合待付 10）⚠ 付完归零，整组会作废 · 用户 12（在岗 7 / 闲置 5）"
	main.lbl_ai_res.text = "对手公司 · 资金 10（本回合待付 10）⚠ 他付完归零，整组会作废 · 用户 12（在岗 7 / 闲置 5）"
	for i in 6:
		await process_frame

	var vp := main.get_viewport().get_visible_rect().size
	var pc: Control = null
	for c in main.find_children("ResPanel", "PanelContainer", true, false):
		pc = c
		break
	var res_right := pc.position.x + pc.size.x
	print("视口 %.0f x %.0f" % [vp.x, vp.y])
	print("资源面板 pos=%s size=%s → 右缘 %.0f" % [pc.position, pc.size, res_right])

	# 右侧那两块：选色面板和 AI 强度面板。按脚本文件名认，不按节点名 ——
	# 那两个 CanvasLayer 是 new() 出来的，名字是引擎给的 @CanvasLayer@NNN
	# 那两块是 Control（不是 CanvasLayer —— 找错类型的话这个循环一条都不进，
	# 而「一条都没打印」和「量出来没重叠」在输出里长得一样）
	for c in main.find_children("*", "Control", true, false):
		var s: Script = c.get_script()
		if s == null:
			continue
		var who: String = s.resource_path.get_file()
		if who not in ["palette_panel.gd", "ai_panel.gd"]:
			continue
		var f: Node = c.get_node_or_null("Frame")
		if f == null or not (f is Control):
			print("%s 没有 Frame" % who)
			continue
		var fc := f as Control
		print("%s 收起态 Frame left=%.0f width=%.0f → 间距 %.0f"
			% [who, fc.global_position.x, fc.size.x,
				fc.global_position.x - res_right])
		# **展开态才是要量的那个**：收起态量出来的余量偏大，
		# 而两块面板都是能展开的（见 scenes/main.gd 的 _setup_res_panel）
		var tg: Node = c.get_node_or_null("Frame/VB/Toggle")
		if tg == null:
			for b in c.find_children("*", "Button", true, false):
				if (b as Button).text in ["展开", "收起"]:
					tg = b
					break
		if tg == null:
			print("  %s 找不到展开按钮 —— 这一块的展开态没量到" % who)
			continue
		if (tg as Button).text == "展开":
			(tg as Button).emit_signal("pressed")
			for i in 4:
				await process_frame
		print("  展开态 left=%.0f width=%.0f → 间距 %.0f"
			% [fc.global_position.x, fc.size.x,
				fc.global_position.x - res_right])
		check(fc.global_position.x > res_right,
			"%s 展开之后也在资源面板右边（没重叠）" % who)
	check(res_right < vp.x, "资源面板右缘没出视口")
	finish()
