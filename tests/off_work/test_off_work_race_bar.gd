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

func _run() -> void:
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
