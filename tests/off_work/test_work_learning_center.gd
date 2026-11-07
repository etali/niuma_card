# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

var game: Node

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1440, 810)
	game = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(game)
	game.set_process(false)
	game.hud._rulebook_button.pressed.emit()
	var book: Node = game.hud._rulebook
	check(book.get_script().get_base_script().resource_path == "res://scenes/rulebook.gd",
		"下班怎么玩复用上班学习中心的导航与滚动组件")
	check(book._navigation.get_child_count() == 3 and book.current_page == "home",
		"初始进入课程，可切换卡牌总览和升级关系")
	check(book._page.find_child("TutorialCourses", true, false).get_child_count() == game.lesson.courses().size() * 2
		and book._page.find_child("WorkLesson_overtime", true, false) != null
		and book._page.find_child("WorkLesson_upgrade", true, false) != null
		and book._page.find_child("WorkLesson_extract", true, false) != null
		and book._page.find_child("WorkLesson_meeting", true, false) != null
		and book._page.find_child("WorkLesson_transfer", true, false) != null,
		"课程逐项展示，加班、咖啡、按类型抽牌、开会和甩锅各有独立入口")
	book.get_node("LearningNavigation/Learning_cards").pressed.emit()
	var atlas: Node = book._page.get_child(0)
	check(atlas.get_script().get_base_script().resource_path == "res://scenes/card_atlas.gd"
		and atlas._grid.get_child_count() == game.state.config.cards.size(),
		"卡牌总览复用上班图鉴网格，并完整显示当前下班卡表")
	var preview: Node = atlas._tiles.employee.get_child(0)
	check(preview.card is OffWorkCard and preview.card.def_id == "employee"
		and preview.card.card_catalog == OffWorkCardDB, "图鉴实际使用下班正式牌面和人员实体")
	for button in atlas._filters.get_children():
		if button.text == "人员": button.pressed.emit()
	check(atlas._grid.get_children().filter(func(tile): return tile.visible).size() == game.state.config.roles.size(),
		"图鉴可以按人员类别筛选")
	game.state.config.cards.employee.name = "调参员工"
	game.state.config.rules.coffee.upgrades.employee.cost = 2
	game.state.config.rules.coffee.upgrades.employee.seconds = 7.5
	OffWorkCardDB.configure(game.state.config)
	book.get_node("LearningNavigation/Learning_upgrades").pressed.emit()
	atlas = book._page.get_child(0)
	check(atlas.ordinary_routes.size() == game.state.config.rules.coffee.upgrades.size(),
		"升级关系按当前咖啡规则生成完整人员路径")
	var route: Node = atlas._ordinary_grid.get_node("Ordinary_employee")
	check(route.get_meta("route").target_id == "grinder"
		and route.find_child("CoffeeCost", true, false).text == "2 杯咖啡"
		and route.find_child("CoffeeTime", true, false).text == "7.5 秒",
		"关系图使用当前配置的目标、咖啡数量和时长")
	var source_preview: Node = route.get_child(0).get_child(0)
	check(source_preview.accessibility_name == "调参员工" and source_preview.card.label.text == "调参员工",
		"改名后关系图沿用当前人员卡名")
	check(atlas._map.get_node("WorkCombination").text.contains("人员＋工作")
		and atlas._map.get_node("CoffeeCombination").text.contains("单独成堆"),
		"关系图明确区分工作堆和喝咖啡的独立牌堆")
	for dimensions in [Vector2i(1440, 810), Vector2i(960, 540)]:
		root.size = dimensions
		game.hud.relayout()
		for frame in 5: await process_frame
		check(root.get_visible_rect().encloses(game.hud._utility.get_global_rect())
			and root.get_visible_rect().encloses(book._navigation.get_global_rect()),
			"图鉴关系及导航在窗口范围内，溢出关系由滚动承载 %s" % dimensions)
	book.get_node("LearningNavigation/Learning_home").pressed.emit()
	book._page.find_child("WorkLesson_overtime", true, false).pressed.emit()
	check(game.lesson.lesson.id == "overtime" and not game.hud._utility.visible,
		"从共用课程页开始加班课后回到实际练习牌桌")
	game.demonstrate_practice_step()
	game._process(0.01)
	var active_world: OffWorkState = game.state
	var active_step: int = game.lesson.step
	game.hud._open_utility(game.hud.UTILITY_RULEBOOK)
	game.hud._rulebook._page.get_node("StartTutorial").pressed.emit()
	check(game.state == active_world and game.lesson.step == active_step and not game.hud._utility.visible,
		"从学习中心继续本课时回到现有步骤和练习牌桌")
	game.free()
	finish()
