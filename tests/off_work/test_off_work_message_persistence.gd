# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 下班的提示不会自己消失：一条提示留到被下一条替换，并进提示记录；
## 操作说明在它下面另占一行小字，不再过几秒就把提示顶掉。
var game: Node

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	game.audio.muted = true
	game.sfx.user_muted = true
	game.state.config.rules.bot.enabled = false
	game._new_game()
	await process_frame
	var hud: Node = game.hud
	var guide: String = str(game.settings.text.hint)
	check(is_instance_valid(hud.lbl_guide) and hud.lbl_guide.text == guide, "操作说明有自己的一行")
	check(hud.lbl_msg.get_parent() == hud.lbl_guide.get_parent() and hud.lbl_guide.get_index() == hud.lbl_msg.get_index() + 1,
		"操作说明紧挨在提示的下面")
	check(game.message.text == guide and not hud.lbl_guide.visible, "开局还没有提示：主行写操作说明，不重复写第二遍")
	check(hud.lbl_guide.get_theme_font_size("font_size") < hud.lbl_msg.get_theme_font_size("font_size"), "操作说明是小一号的字")
	var logged: int = hud.msg_log.total()
	game._notify("钱还不够，差 3 元", true)
	check(game.message.text == "钱还不够，差 3 元" and hud.lbl_guide.visible, "来了提示：主行是提示，操作说明退到下面一行")
	check(hud.msg_log.total() == logged + 1, "提示记进了提示记录")
	# 以前 3.2 秒后提示会被操作说明覆盖。多等一会儿，它必须还在。
	for step in 40: game._process(0.25)
	await create_timer(0.3).timeout
	check(game.message.text == "钱还不够，差 3 元" and hud.lbl_guide.visible, "十秒之后还是那一条提示，没有被操作说明顶掉")
	game._notify("开除 1 人，返还 2 元")
	check(game.message.text == "开除 1 人，返还 2 元" and hud.msg_log.total() == logged + 2, "只有下一条提示才替换它")
	# 选靶的说明用完即收；别的提示不受影响。
	var strike: int = game.state.add_card("strike", 0)
	game.board.sync_state(game.state)
	game._on_activate(strike, -1)
	check(game.message.text == str(game.settings.text.target) and game._selected_tool == strike, "选罢工目标时显示选靶说明")
	var cancel := InputEventKey.new()
	cancel.keycode = KEY_ESCAPE
	cancel.pressed = true
	game._input(cancel)
	check(game._selected_tool < 0 and game.message.text == guide and not hud.lbl_guide.visible, "取消选靶后回到操作说明，仍然只写一遍")
	game._notify("第三条")
	game._new_game()
	await process_frame
	check(game.message.text == guide and not hud.lbl_guide.visible, "新的一局从操作说明开始")
	game.queue_free()
	await process_frame
	finish()
