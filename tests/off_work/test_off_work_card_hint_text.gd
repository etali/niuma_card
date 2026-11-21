# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 牌的悬停提示里不能出现没填的占位符。
## 说明文字写在卡表里，数字用 {seconds} 这样的占位符，由卡牌库填成本局规则里的真实数值。
## 桌上的牌另有一行「状态」；没有自己计时的牌（摸鱼、罢工、加班、甩锅、工会、钱、工作）
## 没有状态可说，这一行就不显示——它曾经把没填数字的说明原样又写了一遍。
const HUD = preload("res://scenes/off_work_hud.gd")
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 5, "employee": 1}]
	config.rules.initial.money = 2
	config.rules.bot.enabled = false
	config.rules.conveyor.interval_seconds = 1000.0
	state = OffWorkState.new(config)
	state.new_game(20261121)
	OffWorkCardDB.configure(config)

	# Every card's description, as the card database hands it to the screen.
	for id in config.cards:
		var text := str(OffWorkCardDB.get_def(str(id)).description)
		check(not text.contains("{") and not text.contains("}"), "%s 的说明里没有没填的占位符" % id)
		check(not _whole_number_with_decimals(text), "%s 的说明里整数不带「.0」（%s）" % [id, text.left(40)])
	var slack := str(OffWorkCardDB.get_def("slack").description)
	var strike := str(OffWorkCardDB.get_def("strike").description)
	check(slack.contains("%d 秒" % int(config.rules.slack.seconds)) and slack.contains("乘 %s" % str(config.rules.slack.speed_multiplier)) \
		and slack.contains("产 %d 杯" % int(config.rules.slack.coffee_per_person)), "摸鱼的说明写着本局的周期、倍率和产量（%s）" % slack)
	check(strike.contains("罢工 %d 秒" % int(config.rules.strike.duration_seconds)), "罢工的说明写着本局的罢工时长（%s）" % strike)
	# A fractional rule keeps its digits.
	config.rules.slack.seconds = 7.5
	OffWorkCardDB.configure(config)
	check(str(OffWorkCardDB.get_def("slack").description).contains("7.5 秒"), "不是整数的数值照原样写")

	host = Node3D.new()
	root.add_child(host)
	board = OffWorkBoard.new(false)
	host.add_child(board)
	board.set_process(false)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 25, 12)
	camera.look_at(Vector3.ZERO)
	board.setup(camera, true)
	var made := {}
	for kind in ["slack", "strike", "overtime", "transfer", "union", "meeting", "coffee", "outsource"]: made[kind] = state.add_card(kind, 0)
	board.sync_state(state)
	# What a card lying on the table says about itself.
	for kind in ["slack", "strike", "overtime", "transfer", "union"]:
		var status: String = board.by_uid[made[kind]].recipe_status_text()
		check(status == "", "桌上的%s没有自己的计时，状态行不显示（原来是带占位符的说明：%s）" % [config.cards[kind].name, status.left(24)])
	for kind in ["money", "work"]:
		var status: String = board.by_uid[state._owner_type(0, kind)[0]].recipe_status_text()
		check(not status.contains("{") and status != str(config.cards[kind].description), "%s的状态行不重复它的说明" % config.cards[kind].name)
	for kind in ["meeting", "coffee", "outsource"]:
		var status: String = board.by_uid[made[kind]].recipe_status_text()
		check(status == str(OffWorkUI.section("timer_status")[kind].ready), "有自己计时的%s仍然写它的状态（%s）" % [config.cards[kind].name, status])
	var person: OffWorkCard = board.by_uid[state._owner_type(0, "employee")[0]]
	var doing := str(OffWorkUI.section("card_status").get(str(person.record.get("activity", "idle")), ""))
	check(doing != "" and person.recipe_status_text() == doing, "人员仍然写他在做什么（%s）" % doing)
	# Nothing a card says about itself may carry a placeholder, whatever its type.
	for uid in board.by_uid:
		var words: String = board.by_uid[uid].recipe_status_text()
		check(not words.contains("{") and not words.contains("%"), "%s 的状态行里没有占位符" % board.by_uid[uid].type)
	host.queue_free()
	await process_frame
	finish()

## "14.0 秒" or "1.0 杯": a whole number written with a decimal point.
func _whole_number_with_decimals(text: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile("\\d+\\.0(?!\\d)")
	return pattern.search(text) != null
