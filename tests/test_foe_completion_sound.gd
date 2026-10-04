# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	AISearch.set_pref_strength(0.0)
	var main := await boot_main()
	main.sfx.set_user_muted(false)
	main.sfx.set_drawer_suspended(false)
	# 真实 AI 的空行动也要提醒，不依赖买牌、编组或生产附带的声音。
	main.state.market.clear()
	main.state.combos.clear()
	main.state.players[main.foe_seat]["cards"].clear()
	main.state.add_card(main.foe_seat, "cash")
	main.state.add_card(main.foe_seat, "user")
	main.state.draw_first = main.foe_seat
	main._actor = main.foe_seat
	var before: int = main.sfx._next
	await main._run_foe_action()
	check(main._actor == main.my_seat and not main.board.input_locked,
		"真实 AI 行动结束后交回玩家")
	check(main.sfx._next == (before + 1) % Sfx.POOL_SIZE,
		"对手即使没有买牌或编组，行动结束也只提醒一次")
	var notification: Resource = main.sfx._streams[Sfx.action("foe_action_done")["sound"]]
	check(main.sfx._players[before].stream == notification and main.sfx._players[before].playing,
		"完成提醒进入真实音效播放器")

	main.set_foe_remote(true)
	main._actor = main.foe_seat
	main._foe_action_done = false
	before = main.sfx._next
	main._run_foe_action()
	await process_frame
	check(main.sfx._next == before, "远端仍在行动时不提前提醒")
	await main.pipe.submit(Intent.action_done(main.my_seat))
	await process_frame
	check(main.sfx._next == before and main._actor == main.foe_seat,
		"自己的收手消息不会触发对手完成提醒")
	var result: Dictionary = await main.pipe.submit(Intent.action_done(main.foe_seat))
	check(result.get("ok", false), "远端收手经真实管道落地")
	for i in 30:
		await process_frame
		if main._actor == main.my_seat:
			break
	check(main._actor == main.my_seat and main.sfx._next == (before + 1) % Sfx.POOL_SIZE,
		"远端完成后交回玩家且只播放一次提醒")

	main.sfx.set_drawer_suspended(true)
	before = main.sfx._next
	main.sfx.play("buy")
	check(main.sfx._next == before, "收起时仍挂起普通操作音效")
	main.sfx.play("foe_action_done")
	check(main.sfx._next == (before + 1) % Sfx.POOL_SIZE
		and main.sfx._players[before].stream == notification,
		"抽屉收起时完成提醒仍能播放")
	main.sfx.set_user_muted(true)
	before = main.sfx._next
	main.sfx.play("foe_action_done")
	check(main.sfx._next == before, "玩家主动静音时完成提醒也静音")
	main.sfx.set_drawer_suspended(false)
	main.sfx.play("foe_action_done")
	check(main.sfx._next == before, "展开抽屉不会绕过玩家静音")

	main.sfx.set_user_muted(false)
	main._actor = main.foe_seat
	main._foe_action_done = false
	before = main.sfx._next
	main._run_foe_action()
	await process_frame
	main._invalidate_session()
	await process_frame
	await process_frame
	check(main.sfx._next == before, "退出或换局取消等待时不伪报对手已完成")
	main.sfx.set_user_muted(true)
	AISearch.restore_defaults()
	finish()
