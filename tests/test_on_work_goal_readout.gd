# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 胜利线一直写在资金读数后面（「资金 12 / 100」），双方都写；
## 资金或用户快归零（归零即输）时，那个读数用危险色。
var main: Node

func _initialize() -> void:
	call_deferred("_run")

func _give(seat: String, res: String, count: int) -> void:
	var unit := OnWorkCardDB.unit_id(res)
	main.state.players[seat]["cards"] = main.state.players[seat]["cards"].filter(func(card): return card["def_id"] != unit)
	for i in count:
		main.state.add_card(seat, unit)

## 摘要读数的完整写法：抽屉首行把它压短，完整的一句留在悬停提示里。
func _full(label: Label) -> String:
	return label.tooltip_text if main.drawer_presentation != null else label.text

func _run() -> void:
	print("=== 胜利线进顶栏 ===")
	# 普通横屏用资源卡，抽屉布局用首行的短读数：两种都要写胜利线、都要描红。
	for drawer in [false, true]:
		await _layout(drawer)
	finish()

func _layout(drawer: bool) -> void:
	main = load("res://scenes/on_work_main.tscn").instantiate()
	main.force_drawer_layout = drawer
	root.add_child(main)
	main.sfx.set_muted(true)
	_booted = main
	await settle()
	if not need(main.state != null and (main.drawer_presentation != null) == drawer, "主场景以%s布局启动" % ("抽屉" if drawer else "普通横屏")):
		return
	if drawer:
		main.drawer_presentation.relayout()
		for i in 3: await process_frame
	var goal := int(OnWorkCardDB.game_rules()["win_cash"])
	var cash := OnWorkCardDB.res_label(OnWorkCardDB.RES_CASH)
	var alarm: int = main.RESOURCE_ALARM
	_give(main.my_seat, OnWorkCardDB.RES_CASH, 12)
	_give(main.my_seat, OnWorkCardDB.RES_USER, 8)
	_give(main.foe_seat, OnWorkCardDB.RES_CASH, 40)
	_give(main.foe_seat, OnWorkCardDB.RES_USER, 9)
	main._update_hud()
	check(_full(main.lbl_player_res).contains("%s 12 / %d" % [cash, goal]), "我方读数写出胜利线：%s" % _full(main.lbl_player_res))
	check(_full(main.lbl_bot_res).contains("%s 40 / %d" % [cash, goal]), "对手读数同样写出胜利线：%s" % _full(main.lbl_bot_res))
	check(not main.resource_low(main.my_seat, OnWorkCardDB.RES_CASH) and not main.resource_low(main.foe_seat, OnWorkCardDB.RES_USER), "12 和 9 都不算快归零")
	if drawer: _drawer_readout(cash, goal, alarm)
	else: _card_readout(goal, alarm)
	main.queue_free()
	await physics_frame

## 普通横屏：结构化的资源卡。
func _card_readout(goal: int, alarm: int) -> void:
	var player: ResourceHUD = main.hud_player_card
	var bot: ResourceHUD = main.hud_bot_card
	var surface := Palette.semantic("surface")
	var ink := Palette.readable_ink(Palette.semantic("ink"), surface)
	var danger := Palette.readable_ink(Palette.semantic("danger"), surface)
	check(player.cash_goal.visible and player.cash_goal.text == "/ %d" % goal and bot.cash_goal.text == "/ %d" % goal,
		"资源卡在资金数值后面用小字写胜利线")
	check(player.cash_value.text == "12" and player.cash_goal.get_parent() == player.cash_value.get_parent() \
		and player.cash_goal.get_index() == player.cash_value.get_index() + 1
		and player.cash_goal.get_theme_font_size("font_size") < player.cash_value.get_theme_font_size("font_size"),
		"资金数值仍是纯数字，胜利线紧跟其后、字小一号")
	check(player.cash_value.get_theme_color("font_color").is_equal_approx(ink) and player.user_value.get_theme_color("font_color").is_equal_approx(ink),
		"资源充裕时读数是普通墨色")
	# 资金快归零：只有资金描红。
	_give(main.my_seat, OnWorkCardDB.RES_CASH, alarm)
	main._update_hud()
	check(main.resource_low(main.my_seat, OnWorkCardDB.RES_CASH) and player.cash_value.get_theme_color("font_color").is_equal_approx(danger) \
		and player.user_value.get_theme_color("font_color").is_equal_approx(ink),
		"资金剩 %d：资金读数描红，用户读数不变" % alarm)
	check(bot.cash_value.get_theme_color("font_color").is_equal_approx(ink) and bot.user_value.get_theme_color("font_color").is_equal_approx(ink),
		"对手那一侧不受影响")
	# 回到安全线以上就恢复；换成对手的用户快归零。
	_give(main.my_seat, OnWorkCardDB.RES_CASH, alarm + 1)
	_give(main.foe_seat, OnWorkCardDB.RES_USER, 1)
	main._update_hud()
	check(player.cash_value.get_theme_color("font_color").is_equal_approx(ink), "资金回到 %d：不再描红" % (alarm + 1))
	check(bot.user_value.get_theme_color("font_color").is_equal_approx(danger) and bot.cash_value.get_theme_color("font_color").is_equal_approx(ink),
		"对手用户剩 1：对手的用户读数描红")
	# 危险色取自配色。
	var saved: Color = Palette.semantic("danger")
	Palette.set_color("semantic", "danger", Color("#8A1F5C"))
	check(bot.user_value.get_theme_color("font_color").is_equal_approx(Palette.readable_ink(Color("#8A1F5C"), Palette.semantic("surface"))),
		"改配色后描红的颜色立即跟着变")
	Palette.set_color("semantic", "danger", saved)

## 抽屉布局：首行一句短读数，完整的一句在悬停提示里。
func _drawer_readout(cash: String, goal: int, alarm: int) -> void:
	var presentation: Node = main.drawer_presentation
	check(main.lbl_player_res.text.contains("%s12/%d" % [cash, goal]) and main.lbl_bot_res.text.contains("%s40/%d" % [cash, goal]),
		"首行的短读数带胜利线：%s" % main.lbl_player_res.text)
	check(main.lbl_player_res.get_theme_color("font_color").is_equal_approx(Palette.get_color("hud", "player")) \
		and main.lbl_bot_res.get_theme_color("font_color").is_equal_approx(Palette.get_color("hud", "bot")),
		"资源充裕时两行各用自己一方的颜色")
	# 窗口窄到两边放不下时只写余额，读数仍然完整地在一行里；变宽后胜利线回来。
	presentation._fit_header_width(120.0)
	check(main.lbl_player_res.text.contains("%s12 " % cash) and not main.lbl_player_res.text.contains("/%d" % goal) \
		and main.lbl_player_res.tooltip_text.contains("%s 12 / %d" % [cash, goal]),
		"放不下时短读数只写余额，完整的一句仍在悬停提示里：%s" % main.lbl_player_res.text)
	presentation._fit_header_width(4000.0)
	check(main.lbl_player_res.text.contains("%s12/%d" % [cash, goal]), "放得下了，胜利线回到短读数上")
	presentation.relayout()
	_give(main.my_seat, OnWorkCardDB.RES_CASH, alarm)
	main._update_hud()
	check(main.lbl_player_res.get_theme_color("font_color").is_equal_approx(Palette.semantic("danger")) \
		and main.lbl_bot_res.get_theme_color("font_color").is_equal_approx(Palette.get_color("hud", "bot")),
		"资金剩 %d：快归零的那一方整行用危险色，另一方保持自己的颜色" % alarm)
	_give(main.my_seat, OnWorkCardDB.RES_CASH, alarm + 1)
	_give(main.foe_seat, OnWorkCardDB.RES_USER, 1)
	main._update_hud()
	check(main.lbl_player_res.get_theme_color("font_color").is_equal_approx(Palette.get_color("hud", "player")) \
		and main.lbl_bot_res.get_theme_color("font_color").is_equal_approx(Palette.semantic("danger")),
		"我方回到安全线以上、对手用户剩 1：描红换到对手那一行")
