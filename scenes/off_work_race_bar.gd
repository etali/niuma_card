# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Control

## 下班的竞速条：贴在顶栏下面的一条细带。左边是我方、右边是对手，各自按
## 「工作清掉了多少」从两端向中间的「下班」推进，每 100 份一个刻度。
## 顶栏上的「工作 611」要自己做减法才知道谁领先；这一条一眼就看得出。
## 只画，不拦鼠标；数字来自 OffWorkState，颜色取界面语义色和卡框墨线色。

## 条和它上面的间距加起来不超过 26：顶栏下沿到牌桌取景区之间留的空就这么多，
## 条不能压到对手理牌区里的牌。
const HEIGHT := 22.0          # 设计像素；实际尺寸乘 unit
const GAP := 4.0              # 与顶栏下沿的间距
const INSET := 34.0           # 比顶栏两端各缩进这么多
const TICK_WORK := 100        # 每多少份工作一个刻度
const MAX_TICKS := 12         # 一侧最多画这么多刻度，再多就不画（条太碎）

var state: RefCounted
var anchor: Control           # 顶栏；条贴在它下面，跟着它的位置和宽度走
var unit := 1.0               # 设计像素到屏幕像素的倍率
var local_owner := 0
var opponent_owner := 1
## 这一局的工作总量：开局张数；中途被甩锅超过开局张数时取见过的最大值，条不会倒退到负数。
var _total := 0.0
var _source := [0, 0]
var _last_time := -1.0
var _drawn := []

func _init() -> void:
	name = "OffWorkRaceBar"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

## 每次 HUD 刷新时调用：换了牌局或时间倒回去（重开、录像回拖）就重新量总量。
func sync(game_state: RefCounted, header: Control, scale_factor: float) -> void:
	state = game_state
	anchor = header
	unit = maxf(0.5, scale_factor)
	if state == null:
		return
	var source := [state.get_instance_id(), state.config.get_instance_id()]
	if source != _source or float(state.time) < _last_time - 0.5:
		_source = source
		_total = 0.0
	_last_time = float(state.time)
	_total = maxf(_total, float(_initial_work()))
	for owner in [local_owner, opponent_owner]:
		_total = maxf(_total, float(state.work_count(owner)))
	var shown := [remaining(local_owner), remaining(opponent_owner), _total, _bar_rect(), unit]
	if shown != _drawn:
		_drawn = shown
		queue_redraw()

func _initial_work() -> int:
	var count := 0
	for group in state.config.rules.initial.groups:
		count += int(group.get("work", 0))
	return count

func remaining(owner: int) -> int:
	return int(state.work_count(owner)) if state != null else 0

## 这一方清掉了几成（0～1）。
func cleared_fraction(owner: int) -> float:
	if state == null or _total <= 0.0:
		return 0.0
	return clampf(1.0 - float(remaining(owner)) / _total, 0.0, 1.0)

func _bar_rect() -> Rect2:
	if not is_instance_valid(anchor):
		return Rect2()
	var header := anchor.get_global_rect()
	var inset := minf(INSET * unit, header.size.x * 0.08)
	return Rect2(header.position.x + inset, header.end.y + GAP * unit, header.size.x - inset * 2.0, HEIGHT * unit)

func _draw() -> void:
	if state == null or _total <= 0.0:
		return
	var rect := _bar_rect()
	if rect.size.x < 120.0 * unit:
		return
	var ink := Palette.get_color("card", "frame")
	var paper := Palette.semantic("surface")
	var border := maxf(1.0, roundf(2.0 * unit))
	var track := StyleBoxFlat.new()
	track.bg_color = paper
	track.border_color = ink
	track.set_border_width_all(int(border))
	track.set_corner_radius_all(roundi(rect.size.y * 0.5))
	track.shadow_color = Color(ink, 0.28)
	track.shadow_size = 0
	track.shadow_offset = Vector2(0, 2.0 * unit)
	draw_style_box(track, rect)
	var half := rect.size.x * 0.5 - border
	var radius := roundi(rect.size.y * 0.5 - border)
	for side in 2:
		var owner := local_owner if side == 0 else opponent_owner
		var amount := cleared_fraction(owner)
		if amount <= 0.004:
			continue
		var fill := StyleBoxFlat.new()
		fill.bg_color = Palette.get_color("hud", "player" if side == 0 else "bot")
		var width := maxf(half * amount, float(radius) * 2.0)
		var inner := Rect2(rect.position.x + border, rect.position.y + border, width, rect.size.y - border * 2.0)
		if side == 0:
			fill.corner_radius_top_left = radius
			fill.corner_radius_bottom_left = radius
		else:
			fill.corner_radius_top_right = radius
			fill.corner_radius_bottom_right = radius
			inner.position.x = rect.end.x - border - width
		draw_style_box(fill, inner)
	# 刻度：每 TICK_WORK 份一格，从两端往中间数。
	var ticks := ceili(_total / float(TICK_WORK))
	if ticks >= 2 and ticks <= MAX_TICKS:
		for index in range(1, ticks):
			var offset := half * float(index * TICK_WORK) / _total
			for sign in [-1.0, 1.0]:
				var x: float = rect.get_center().x + float(sign) * (half - offset)
				draw_line(Vector2(x, rect.position.y + rect.size.y * 0.30), Vector2(x, rect.end.y - rect.size.y * 0.30),
					Color(ink, 0.38), maxf(1.0, 1.2 * unit), true)
	var font := Fonts.zh_bold()
	var size := maxi(9, roundi(13.0 * unit))
	var baseline := rect.position.y + rect.size.y * 0.5 + float(size) * 0.36
	var goal := "下班"
	var goal_size := maxi(10, roundi(14.0 * unit))
	var goal_width := Fonts.zh_black().get_string_size(goal, HORIZONTAL_ALIGNMENT_LEFT, -1, goal_size).x
	var pill := Rect2(rect.get_center().x - goal_width * 0.5 - 9.0 * unit, rect.position.y - 3.0 * unit,
		goal_width + 18.0 * unit, rect.size.y + 6.0 * unit)
	var left := "我方 剩 %d" % remaining(local_owner)
	var right := "对手 剩 %d" % remaining(opponent_owner)
	var right_width := font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var margin := 14.0 * unit
	# 条太窄时两边的字会撞上中间的「下班」，那就只留条和刻度。
	if font.get_string_size(left, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + margin < pill.position.x - rect.position.x \
			and right_width + margin < rect.end.x - pill.end.x:
		draw_string(font, Vector2(rect.position.x + margin, baseline), left, HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
		draw_string(font, Vector2(rect.end.x - margin - right_width, baseline), right, HORIZONTAL_ALIGNMENT_LEFT, -1, size, ink)
	var sign_box := StyleBoxFlat.new()
	sign_box.bg_color = paper
	sign_box.border_color = ink
	sign_box.set_border_width_all(int(border))
	sign_box.set_corner_radius_all(roundi(7.0 * unit))
	draw_style_box(sign_box, pill)
	draw_string(Fonts.zh_black(), Vector2(pill.get_center().x - goal_width * 0.5, pill.get_center().y + float(goal_size) * 0.36),
		goal, HORIZONTAL_ALIGNMENT_LEFT, -1, goal_size, ink)
