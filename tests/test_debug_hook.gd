# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## scenes/debug_shot.gd 的动作钩子跑不跑得起来
##
## 那个文件只在 CARD_SHOT=... 时才被 main 调到，而截图那一步要等
## RenderingServer.frame_post_draw —— headless 下永远不来，所以整个钩子
## 进不了 run_tests.sh。于是它一直是「改了没人管」的状态：这次把摆放那一层
## 搬去 settle_layout.gd，钩子里 11 处调用跟着改，check-only 只能保证语法过，
## 保不了 m.layout.xxx 这个名字在运行时真找得到（GDScript 动态派发，
## 名字写错要到调用那一刻才报）。
##
## 这里绕开截图，直接调 _action()：动作本身不需要渲染。


func _initialize() -> void:
	print("=== 截图钩子动作可用性 测试 ===")
	var main: Node = await boot_main()

	var hook = load("res://scenes/debug_shot.gd").new()
	hook.m = main
	hook.board = main.board

	# settle 这一条动作面最宽：走 _sync_entities → layout._layout_bot_idle →
	# layout._bot_piles → 真结算，把搬走的那一层从头到尾过一遍
	await hook._action("settle:20:12")
	check(true, "settle:20:12 跑完没崩（layout.* 的名字运行时都找得到）")

	var piles: Array = main.layout._bot_piles()
	check(piles.size() > 0, "BOT 摞得出东西：%d 坨" % piles.size())

	# 玩家侧：结算产出该摞在左边那一带
	var left := 0
	for uid in main.entities:
		var e = main.entities[uid]
		if is_instance_valid(e) and not e.is_market and e.global_position.x < -6.0:
			left += 1
	check(left > 0, "结算产出落在左侧（%d 张 x < -6.0）" % left)

	finish()
