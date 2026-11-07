# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Game = preload("res://scenes/off_work_main.tscn")
const Progress = preload("res://engine/tutorial_progress.gd")
var game: Node

func _initialize() -> void:
	OS.set_environment("WORK_DATA_DIR", _test_data_dir.path_join("courses"))
	_run.call_deferred()

func _run() -> void:
	_open_game()
	var original: OffWorkState = game.state
	var prior_rng := original._rng.state
	var prior_time := original.time
	var on_work_progress := Progress.read()
	game.hud._offer_learning_invitation()
	check(game.hud.is_learning_invitation_open(), "首次进入有可跳过的下班学习邀请")
	game.hud._learning_invitation.find_child("InvitationStart",true,false).pressed.emit()
	check(game.lesson.lesson.id == "first" and game.practice_stage == 0 and game.state != original,"邀请进入独立下班练习牌桌")
	check(game.hud._practice_panel.find_child("WorkLessonHint",true,false).text.contains("员工"), "第一步可直接读到派工操作")
	check(game.hud._practice_gesture.cue.gesture == "drag" and game.hud._practice_gesture.cue.source.type == "employee"
		and game.hud._practice_gesture.cue.target.type == "work", "原教程的手势提示绑定真实员工与工作牌")
	game._process(8.0)
	check(game.practice_stage == 0,"没有派工就不会随时间跳步")
	game.demonstrate_practice_step()
	game._process(0.1)
	check(game.practice_stage == 1,"演示通过真实拖牌派工")
	game._process(2.0)
	check(game.practice_stage == 2,"收入由真实结算触发下一步")
	game.demonstrate_practice_step()
	game._process(0.01)
	check(game.lesson.complete() and Progress.course("first",true).status == "viewed","观看演示不记为亲手结业")
	game.begin_practice("first")
	check(game.practice_stage == 0 and not game.lesson.used_demo,"重练获得干净牌局")
	game.state.move_cards(game.state._owner_type(0,"employee"), game.state.cards[game.state._owner_type(0,"work")[0]].group)
	game._process(0.1)
	game._process(2.0)
	game._on_buy(game.state.offers[0].id)
	game._process(0.01)
	check(Progress.course("first",true).status == "completed","亲手派工、收钱并购牌才记录毕业")
	game.hud._open_utility(game.hud.UTILITY_RULEBOOK)
	var stopped: float = game.state.time
	game._process(4.0)
	check(game.state.time == stopped,"参考或选课界面暂停练习计时")
	game.hud._utility_body.find_child("WorkLesson_overtime",true,false).pressed.emit()
	var worker: int = game.state._owner_type(0, "employee")[0]
	var group: int = game.state.cards[worker].group
	var base_rate: float = game.state.group_work_rate(group)
	check(game.state._owner_type(0, "coffee").is_empty(), "加班课只提供提效所需的牌")
	game.demonstrate_practice_step()
	game._process(0.01)
	check(game.practice_stage == 1 and game.state.group_work_rate(group) > base_rate, "加班与开工员工同组后真实提效")
	game._process(2.0)
	check(game.lesson.complete() and game.state.cards[worker].type == "employee", "加班课观察提效结算后独立结束，人员卷度未变")
	var next: Button = game.hud._practice_panel.find_children("*", "Button", true, false).filter(func(button): return button.text == "下一课")[0]
	next.pressed.emit()
	check(game.lesson.lesson.id == "upgrade" and game.state._owner_type(0, "overtime").is_empty(), "下一课单独学习咖啡提升卷度")
	check(game.hud._practice_gesture.cue.has("target_world"), "咖啡课先指引把员工从工作堆拆到空位")
	var teaching_worker = game.hud._practice_gesture.cue.source
	var teaching_group = game.board.group_of(teaching_worker)
	check(teaching_group != null and not teaching_group.compact and teaching_group.cards.back() == teaching_worker,
		"咖啡课展开工作堆并将员工放在末端，拖员工只取出本人")
	game.demonstrate_practice_step()
	game._process(0.01)
	check(game.practice_stage == 1 and game.lesson.separate_worker(game.state) >= 0, "人员实际与工作分开后才提示加咖啡")
	game.demonstrate_practice_step()
	game._process(0.01)
	check(game.practice_stage == 2,"咖啡任务已真正开始")
	game._process(5.0)
	check(game.lesson.complete() and not game.state._owner_type(0,"grinder").is_empty(),"卷度在喝咖啡计时结束后提升")
	game.begin_practice("interrupt")
	game.demonstrate_practice_step()
	game._process(0.01)
	check(game.practice_stage == 1,"只认打断对手的真实罢工")
	game.demonstrate_practice_step()
	game._process(2.1)
	check(game.lesson.complete(),"趁停工完成己方工作")
	game.begin_practice("solo")
	check(game.state.config.rules.bot.enabled and not game.lesson.demonstrate(game.state),"独立对局使用正式BOT且不能代打")
	var stock := OffWorkConfig.new()
	var formal_rules := stock.rules.duplicate(true)
	formal_rules.initial.groups[0].work = 48
	check(game.state.config.rules == formal_rules and game.state.config.roles == stock.roles and game.state.config.cards == stock.cards
		and game.state.work_count(0) == 48 and game.state.work_count(1) == 48,
		"独立对局双方各带48份工作，其他规则、卡牌和计时参数与正式对局一致")
	# Fast-forward to the final real job without creating every intermediate animation.
	for id in game.state._owner_type(0, "work").slice(1): game.state._consume(id)
	game.state.move_cards(game.state._owner_type(0, "employee"), game.state.cards[game.state._owner_type(0, "work")[0]].group)
	game._process(float(stock.roles.employee.work_seconds) + 0.1)
	check(game.lesson.complete() and Progress.course("solo",true).status == "completed" and not is_instance_valid(game.result_layer),"获胜进入课末反馈，不弹正式结算")
	game.finish_practice()
	check(game.state == original and game.state.time == prior_time and original._rng.state == prior_rng, "回到被暂存的牌局、时钟与随机状态")
	check(Progress.read() == on_work_progress, "下班学习记录与上班分开保存")
	original.advance(1.25)
	var parked_time := original.time
	var parked_rng := original._rng.state
	game.begin_practice("upgrade")
	game.free()
	_open_game()
	check(game.practice.is_empty() and game.state.time == parked_time and game.state._rng.state == parked_rng,
		"练习中退出应用重新打开仍是进入前最新的正式牌局")
	game.free()
	finish()

func _open_game() -> void:
	game = Game.instantiate()
	game.set_meta("shift_session_enabled", true)
	game.set_meta("shift_enter_expanded", true)
	root.add_child(game)
	game.set_process(false)
