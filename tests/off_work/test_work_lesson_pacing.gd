# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Game = preload("res://scenes/off_work_main.tscn")
var game: Node

func _initialize() -> void:
	OS.set_environment("WORK_DATA_DIR", _test_data_dir.path_join("lesson-pacing"))
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 810)
	game = Game.instantiate()
	game.set_meta("shift_session_enabled", true)
	game.set_meta("shift_enter_expanded", true)
	root.add_child(game)
	game.set_process(false)
	game.hud._rulebook_button.pressed.emit()
	check(game.hud._rulebook_button.text == "怎么玩" and game.hud._utility_title.text == "下班 · 学习中心",
		"从实际牌桌的「怎么玩」按钮打开下班学习中心")
	game.hud._utility_body.find_child("PracticeWork", true, false).pressed.emit()
	_first_lesson()
	_overtime_separate_lesson()
	_coffee_with_work()
	_cancel_coffee_midway()
	_interrupt_after_reading()
	game.free()
	finish()

func _first_lesson() -> void:
	# Enough time for the opening employee to leave the normal conveyor while reading the instructions.
	game._process(61.0)
	var worker: int = game.state._owner_type(0, "employee")[0]
	var work: int = game.state._owner_type(0, "work")[0]
	game.state.move_cards([worker], game.state.cards[work].group)
	game._process(0.05)
	game._process(2.05)
	if not need(game.lesson.step == 2, "读完派工说明后仍能拿到第一笔收入"): return
	game._process(125.0)
	if not need(game.state.winner < 0 and game.lesson.step == 2, "读采购说明期间不会提前清盘"): return
	var employees: Array = game.state.offers.filter(func(offer): return offer.get("type") == "employee")
	if not need(not employees.is_empty(), "完成派工和收入后有可购买的员工"): return
	var offer_id: int = employees[0].id
	var market: CardEntity = game.board.offers_by_id[offer_id]
	var cue: Dictionary = game.hud._practice_gesture.cue
	if not need(is_instance_valid(cue.get("source")), "采购手势绑定当前货架上的实体"): return
	var at: Vector2 = game.hud._practice_gesture.anchor(cue.source)
	check(game.board._price_tag_contains(market, at), "教学手势指在能单击成交的价签内")
	var people: int = game.state.people_count(0)
	game._on_buy(offer_id)
	game._on_buy(offer_id)
	game._process(0.05)
	check(game.lesson.complete() and game.state.people_count(0) == people + 1, "连点同一名员工只买一次，正确结束课程")

func _overtime_separate_lesson() -> void:
	game.begin_practice("overtime")
	game._process(125.0)
	check(game.lesson.step == 0 and game.state.time == 0.0, "加班课等待放牌，不因慢读而耗尽工作")
	game.demonstrate_practice_step()
	game._process(0.01)
	var tool: int = game.state._owner_type(0, "overtime")[0]
	game.state.move_cards([tool])
	game._process(0.1)
	check(game.lesson.step == 0, "提效途中拆走加班牌会退回组牌步骤")
	game.demonstrate_practice_step()
	game._process(0.01)
	game._process(2.0)
	check(game.lesson.complete() and game.state._owner_type(0, "coffee").is_empty(),
		"加班课恢复组合后完成真实提效结算")

func _coffee_with_work() -> void:
	game.begin_practice("upgrade")
	var worker: int = game.state._owner_type(0, "employee")[0]
	var coffee: int = game.state._owner_type(0, "coffee")[0]
	game.state.move_cards([coffee], game.state.cards[worker].group, worker)
	game._process(5.1)
	check(game.lesson.step == 0 and game.state.cards[worker].type == "employee" and game.state.tasks[worker].kind == "work",
		"把咖啡先塞进工作堆仍然只处理工作，教程继续提示拆出人员")
	# Recover by following the same separation and coffee actions the learner sees.
	for attempt in 6:
		if game.lesson.complete(): break
		game.demonstrate_practice_step()
		game._process(1.0)
		game._process(5.1)
	check(game.lesson.complete() and not game.state._owner_type(0, "grinder").is_empty(),
		"误把咖啡放入工作堆后，按提示拆出人员仍可完成卷度课")

func _cancel_coffee_midway() -> void:
	game.begin_practice("upgrade")
	game.demonstrate_practice_step()
	game._process(0.1)
	game.demonstrate_practice_step()
	game._process(0.1)
	if not need(game.lesson.step == 2, "等待阶段的员工正在喝咖啡"): return
	var coffee: int = game.state._owner_type(0, "coffee")[0]
	game.state.move_cards([coffee])
	game._process(0.1)
	game.demonstrate_practice_step()
	game._process(5.1)
	game._process(0.1)
	check(game.lesson.complete() and not game.state._owner_type(0, "grinder").is_empty(),
		"提升卷度途中误拆组合后，照提示和演示仍能恢复并在本次练习结业")

func _interrupt_after_reading() -> void:
	game.begin_practice("interrupt")
	game._process(125.0)
	if not need(game.state.winner < 0, "读罢工目标时对手会留在可打断的生产组"): return
	game.demonstrate_practice_step()
	game._process(0.05)
	game.demonstrate_practice_step()
	game._process(2.05)
	check(game.lesson.complete(), "慢读提示后，仍可打断对手并收入结算")
