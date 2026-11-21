# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 竞速条读的是真实牌局：开局张数、双方剩余工作；被甩锅超过开局张数时不能出现负进度。
## 另外钉住侧边清单的人员小图标只取插画头部这件事（区域在 ui.json 的 work.side_heads）。
const RaceBar = preload("res://scenes/off_work_race_bar.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _work(state: OffWorkState, owner: int) -> Array:
	return state.cards.keys().filter(func(id): return state.cards[id].type == "work" and int(state.cards[id].owner) == owner)

## 预计下班时间：按现在的人手估算，写在竞速条本方那一句后面；对手的不给数字。
func _eta() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 200, "employee": 1}]
	config.rules.bot.enabled = false
	var state := OffWorkState.new(config)
	state.new_game(7)
	var header := PanelContainer.new()
	root.add_child(header)
	header.position = Vector2(100, 20)
	header.size = Vector2(900, 60)
	var bar: Control = RaceBar.new()
	root.add_child(bar)
	bar.sync(state, header, 1.0)
	var gid := int(state.cards[_work(state, 0)[0]].group)
	var per_second: float = state.group_work_rate(gid) * float(config.roles.employee.work_capacity)
	_check(per_second > 0.0 and is_equal_approx(bar.clearing_rate(0), per_second), "the rate is batches per second times the sheets one batch clears")
	_check(is_equal_approx(bar.eta_seconds(0), 200.0 / per_second), "at this rate two hundred sheets take remaining / rate seconds")
	# 一秒算钟面上的一分钟，从 18:00 起算。一个员工清两百份要两千秒：两天以后的事。
	var minutes := 18 * 60 + roundi(200.0 / per_second)
	_check(minutes / 1440 >= 2 and bar.eta_text(0) == "预计 %d 天后下班" % (minutes / 1440),
		"one employee alone on two hundred sheets: days away (%s)" % bar.eta_text(0))
	_check(bar._eta_text == bar.eta_text(0), "the bar shows the estimate for the local player")
	# 只剩一百份：明天上午。
	var sheets: Array = _work(state, 0)
	for index in 100: state._consume(sheets[index])
	state._sync_schedule()
	minutes = 18 * 60 + roundi(bar.eta_seconds(0))
	_check(minutes / 1440 == 1 and bar.eta_text(0) == "预计 次日 %02d:%02d 下班" % [(minutes / 60) % 24, minutes % 60],
		"a hundred sheets for one employee end tomorrow, written as a time of day (%s)" % bar.eta_text(0))
	# 人手不变，读条走到一半：钟点不该变（估算按进度折算，不是每结一批跳一下）。
	var before: float = bar.eta_seconds(0) + float(state.time)
	state.advance(config.work_seconds() * 0.5)
	_check(absf(bar.eta_seconds(0) + float(state.time) - before) < 0.5, "with the same people the estimated time of day stays put while a batch is read")
	state.advance(config.work_seconds() * 0.6)
	_check(absf(bar.eta_seconds(0) + float(state.time) - before) < 0.5 and state.work_count(0) < 100, "and it stays put when the batch completes")
	# 加九个卷王：马上提前到今晚。
	for index in 9: state.add_card("grinder", 0, gid)
	state._sync_schedule()
	var faster: float = bar.eta_seconds(0)
	_check(faster < before / 10.0 and bar.eta_text(0).begins_with("预计 ") and not bar.eta_text(0).contains("次日") and bar.eta_text(0).ends_with(" 下班"),
		"more hands bring it forward at once, to a time this evening (%s)" % bar.eta_text(0))
	# 把人都调走：没人干活。
	var people: Array = state.cards.keys().filter(func(id): return int(state.cards[id].owner) == 0 and config.is_person(str(state.cards[id].type)))
	state.move_cards(people, -1)
	_check(is_inf(bar.eta_seconds(0)) and bar.eta_text(0) == "没人干活", "with nobody on the work there is no estimate, and the bar says so")
	state.move_cards(people, gid)
	# 工作量很大时写「几天后」。
	for index in 3000: state.add_card("work", 0, gid)
	state.move_cards(people.slice(1), -1)
	state._sync_schedule()
	_check(bar.eta_text(0).begins_with("预计 ") and bar.eta_text(0).ends_with(" 天后下班"), "a very long way off is given in days (%s)" % bar.eta_text(0))
	bar.queue_free()
	header.queue_free()

func _run() -> void:
	_eta()
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 200, "employee": 1}]
	config.rules.bot.enabled = false
	var state := OffWorkState.new(config)
	state.new_game(7)
	OffWorkCardDB.configure(config)
	var header := PanelContainer.new()
	root.add_child(header)
	header.position = Vector2(100, 20)
	header.size = Vector2(900, 60)
	var bar: Control = RaceBar.new()
	root.add_child(bar)
	bar.sync(state, header, 1.0)
	_check(bar.remaining(0) == 200 and bar.remaining(1) == 200, "bar reads each side's real remaining work")
	_check(is_zero_approx(bar.cleared_fraction(0)) and is_zero_approx(bar.cleared_fraction(1)), "nothing is cleared at the start")
	_check(bar.mouse_filter == Control.MOUSE_FILTER_IGNORE, "bar never intercepts the pointer")
	var rect: Rect2 = bar._bar_rect()
	_check(rect.position.y >= header.get_global_rect().end.y and rect.size.x < header.size.x and rect.size.x > header.size.x * 0.7,
		"bar hangs below the header and stays within its width")
	# Clearing work advances only that side.
	for id in _work(state, 0).slice(0, 50): state.cards.erase(id)
	state._rebuild_membership() if state.has_method("_rebuild_membership") else null
	var mine_left := int(state.work_count(0))
	bar.sync(state, header, 1.0)
	_check(mine_left < 200 and is_equal_approx(bar.cleared_fraction(0), 1.0 - float(mine_left) / 200.0),
		"cleared share follows the real count (%d left)" % mine_left)
	_check(is_zero_approx(bar.cleared_fraction(1)), "the other side is unchanged")
	# A transfer can push one side above its opening count: the scale grows, progress never goes negative.
	bar._total = 200.0
	var fake := FakeState.new()
	fake.config = state.config
	fake.counts = [260, 120]
	bar.sync(fake, header, 1.0)
	_check(is_zero_approx(bar.cleared_fraction(0)) and bar.cleared_fraction(1) > 0.5 and bar.cleared_fraction(1) < 0.6,
		"extra transferred work enlarges the scale instead of going negative")
	fake.counts = [0, 0]
	bar.sync(fake, header, 1.0)
	_check(is_equal_approx(bar.cleared_fraction(0), 1.0) and is_equal_approx(bar.cleared_fraction(1), 1.0), "an empty pile reaches the goal")
	# A new table (different state object) measures its own total again.
	var small := OffWorkConfig.new()
	small.rules.initial.groups = [{"work": 48, "employee": 1}]
	small.rules.bot.enabled = false
	var next := OffWorkState.new(small)
	next.new_game(9)
	bar.sync(next, header, 1.0)
	_check(is_zero_approx(bar.cleared_fraction(0)) and bar.remaining(0) == 48, "a new game resets the scale to its own opening count")
	bar.queue_free()
	header.queue_free()

	# Side list icons for people show the head only; other cards keep the whole illustration.
	OffWorkCardDB.configure(config)
	for kind in ["employee", "grinder", "workaholic", "work_emperor", "leader", "boss"]:
		var full := CardArt.icon_texture(kind, OffWorkCardDB)
		var side := CardArt.side_icon_texture(kind, OffWorkCardDB)
		_check(side is AtlasTexture and (side as AtlasTexture).atlas == full, "%s side icon is a crop of its own illustration" % kind)
		if side is AtlasTexture:
			var region: Rect2 = (side as AtlasTexture).region
			_check(region.size.x < float(full.get_width()) * 0.7 and region.position.y < float(full.get_height()) * 0.25
				and Rect2(Vector2.ZERO, full.get_size()).encloses(region), "%s crop is the head at the top of the picture" % kind)
		_check(CardArt.side_icon_texture(kind, OffWorkCardDB) == side, "%s crop is cached, so side rows stay stable" % kind)
		_check(CardArt.icon_preserves_color(side) == CardArt.icon_preserves_color(full), "%s crop keeps the illustration's own colours" % kind)
	for kind in ["work", "money", "overtime", "coffee"]:
		_check(CardArt.side_icon_texture(kind, OffWorkCardDB) == CardArt.icon_texture(kind, OffWorkCardDB), "%s side icon is the whole illustration" % kind)
	_check(CardArt.side_icon_texture("yunketang") == CardArt.icon_texture("yunketang"), "on-work side icons are unchanged")

	await process_frame
	for failure in failures: push_error(failure)
	print("OFF_WORK_RACE_BAR %s (%d checks)" % ["PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

class FakeState extends RefCounted:
	var time := 0.0
	var config: OffWorkConfig
	var counts := [0, 0]
	func work_count(owner: int) -> int:
		return int(counts[owner])
