# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 正式对局、教程与规则演示共用的胜负展示，统一创建、挂载、暂停和释放。
## 正式对局另传 finale（见 finale_for）：吉祥物换成欢呼/垂头姿势，标题旁盖章，
## 列出本局数据，输了提示「差一点」；背后撒彩纸或整屏褪色。教程与规则书不传，面板照旧。
const Motion = preload("res://scenes/ui_motion.gd")
const ComicFx = preload("res://scenes/comic_fx.gd")
const ResultFx = preload("res://scenes/result_fx.gd")
const RESULT_HOLD := 1.8
## 面板淡入之后印章落下；失败的长号等印章落定再响。
const STAMP_AT := 0.30
const STAMP_TIME := 0.36
const TROMBONE_AT := 0.75
const FADE_TIME := 1.2
const WIN_TAUNTS: Array[String] = [
	"你赢了。别急着高兴，先看看赢了几分。",
	"赢了。这套牌换个人来，估计能快三回合。",
	"你赢了。运气这东西，也算是一种实力吧。",
	"赢了。对手要是也会双击摞牌，就不好说了。",
]

const LOSE_TAUNTS: Array[String] = [
	"你输了。牌是好牌。",
	"输了。它想了 0.2 秒，你想了半小时。",
	"你输了。至少桌面摆得挺整齐。",
	"输了。要不试试先把配方凑齐再说？",
]

static func create(parent: Node, state: GameState, my_seat: String, sfx: Sfx,
		action: Callable, action_text := "再战一局", compact := true, auto_dismiss := false,
		finale: Dictionary = {}) -> Dictionary:
	var canvas := CanvasLayer.new()
	canvas.name = "GameOver"
	canvas.layer = 10
	parent.add_child(canvas)
	var won := state.winner == my_seat
	# 背景层先于面板加入，画在面板下面；随结果层一起隐藏、暂停和释放。
	var backdrop: Control = null
	if not finale.is_empty():
		backdrop = ResultFx.Confetti.new() if won else ResultFx.Desaturate.new()
		# 铺满整屏但只是画面：抽屉判断「指针在不在面板上」时不能把它算成面板。
		backdrop.set_meta("pointer_passthrough", true)
		canvas.add_child(backdrop)
	# 居中基准固定为视口中心，不让正文换行前的临时最小高度撑大容器。
	# use_top_left 按自身原点居中子面板；面板变高时自动向上下两侧展开。
	var center := CenterContainer.new()
	center.use_top_left = true
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 别把面板外的点击也吃掉
	canvas.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var panel := PanelContainer.new()
	panel.name = "ResultPanel"
	panel.custom_minimum_size = Vector2(480, 0) if compact else Vector2(560, 260)
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)

	var result_icon := ResultFx.MascotPose.new()
	result_icon.set_pose("idle" if finale.is_empty() else ("cheer" if won else "slump"))
	result_icon.custom_minimum_size = Vector2(68, 68) if finale.is_empty() else Vector2(96, 96)
	result_icon.tooltip_text = "胜利" if won else "本局结束"
	vb.add_child(result_icon)
	var title := Label.new()
	title.name = "ResultTitle"
	title.text = "胜利" if won else "失败"
	title.set_meta("drawer_font_base", 21)
	title.add_theme_font_override("font", Fonts.zh_bold())
	title.add_theme_font_size_override("font_size", 32)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var stamp: ResultFx.ResultStamp = null
	if not finale.is_empty():
		stamp = ResultFx.ResultStamp.new()
		stamp.text = str(finale.get("stamp", ""))
		title.add_child(stamp)

	var message := Label.new()
	message.name = "ResultMessage"
	message.add_theme_font_override("font", Fonts.zh())
	message.add_theme_font_size_override("font_size", 22)
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.text = WIN_TAUNTS[randi() % WIN_TAUNTS.size()] if won else LOSE_TAUNTS[randi() % LOSE_TAUNTS.size()]
	vb.add_child(message)
	# 资金冲线的胜利换成上市敲钟；正式对局的失败换成泄气的长号（印章落定后才响）。
	if won and str(finale.get("kind", "")) == "listing":
		sfx.play("listing_bell")
	elif won:
		sfx.play("win")
	elif finale.is_empty():
		sfx.play("lose")

	var reason := Label.new()
	reason.name = "ResultReason"
	reason.set_meta("drawer_font_base", 15)
	reason.add_theme_font_override("font", Fonts.zh())
	reason.add_theme_font_size_override("font_size", 20)
	reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reason.text = state.win_reason
	vb.add_child(reason)
	for entry in [["ResultStats", "stats", "muted"], ["ResultHint", "hint", "danger"]]:
		var text := str(finale.get(entry[1], ""))
		if text.is_empty():
			continue
		var line := Label.new()
		line.name = entry[0]
		line.set_meta("drawer_font_base", 15)
		line.set_meta("drawer_ink", Palette.readable_ink(Palette.semantic(entry[2]), Palette.semantic("surface")))
		line.add_theme_font_override("font", Fonts.zh_bold() if entry[1] == "hint" else Fonts.zh())
		line.add_theme_font_size_override("font_size", 18)
		line.add_theme_color_override("font_color", line.get_meta("drawer_ink"))
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.text = text
		vb.add_child(line)

	var btn: Button
	if action.is_valid():
		btn = Button.new()
		btn.name = "ResultRestart"
		btn.text = action_text
		btn.set_meta("drawer_primary", true)
		btn.add_theme_font_override("font", Fonts.zh())
		btn.add_theme_font_size_override("font_size", 24)
		btn.custom_minimum_size = Vector2(220, 42)
		btn.pressed.connect(action)
		vb.add_child(btn)
	# 同一段入场动效服务正式终局和教程。教学只多停留、淡出，不另画胜利界面。
	panel.modulate.a = 0.0
	result_icon.scale = Vector2.ONE * 0.8
	result_icon.resized.connect(func(): result_icon.pivot_offset = result_icon.size * 0.5)
	var animation := panel.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	animation.tween_property(panel, "modulate:a", 1.0, Motion.ACT)
	animation.parallel().tween_property(result_icon, "scale", Vector2.ONE, Motion.ACT).set_trans(Tween.TRANS_BACK)
	# 终局的印章、褪色与长号挂在同一条补间上：抽屉收起时一起暂停，展开后从停下处接着演。
	if stamp != null:
		animation.parallel().tween_property(stamp, "slam", 1.0, STAMP_TIME).set_delay(STAMP_AT)
		animation.parallel().tween_callback(func() -> void: sfx.play("stamp")).set_delay(STAMP_AT + STAMP_TIME * 0.7)
	if backdrop is ResultFx.Desaturate:
		animation.parallel().tween_method(backdrop.set_amount, 0.0, 0.85, FADE_TIME).set_trans(Tween.TRANS_SINE)
		animation.parallel().tween_callback(func() -> void: sfx.play("defeat_trombone")).set_delay(TROMBONE_AT)
	if auto_dismiss:
		animation.tween_interval(RESULT_HOLD)
		animation.tween_property(panel, "modulate:a", 0.0, Motion.SETTLE)
	canvas.visibility_changed.connect(func():
		if not animation.is_valid(): return
		if canvas.visible:
			animation.play()
		else:
			animation.pause())
	return {"layer": canvas, "panel": panel, "body": vb, "button": btn, "center": center,
		"animation": animation, "auto_dismiss": auto_dismiss, "backdrop": backdrop}

## 正式对局的终局演出内容：胜因、印章字、本局数据与输家的「差一点」。
## stats 为 TableActions.match_stats() 的结果；记不全时为空，只显示终局读数。
static func finale_for(state: GameState, my_seat: String, stats: Dictionary = {}) -> Dictionary:
	if state == null or state.winner == "":
		return {}
	var won := state.winner == my_seat
	var kind := victory_kind(state)
	var config := ComicFx.rules()
	var lines: Array[String] = ["第 %d 回合收官 · %s %d · %s %d" % [state.round_num,
		CardDB.res_label(CardDB.RES_CASH), state.resource_count(my_seat, CardDB.RES_CASH),
		CardDB.res_label(CardDB.RES_USER), state.resource_count(my_seat, CardDB.RES_USER)]]
	if not stats.is_empty():
		var mine: Dictionary = stats.get(my_seat, {})
		lines.append("本局产出 %s +%d · %s +%d · 撕掉对手 %d 张牌" % [
			CardDB.res_label(CardDB.RES_CASH), int(mine.get(CardDB.RES_CASH, 0)),
			CardDB.res_label(CardDB.RES_USER), int(mine.get(CardDB.RES_USER, 0)), int(mine.get("torn", 0))])
	return {"kind": kind, "won": won,
		"stamp": ComicFx.stamp_text(("win_" + kind) if won else "lose", config),
		"stats": "\n".join(lines), "hint": "" if won else near_miss(state, my_seat)}

## 胜因按终局读数判，与 GameState.check_victory 的先后一致：先看冲线，再看清零。
static func victory_kind(state: GameState) -> String:
	if state == null or state.winner == "":
		return ""
	var loser := _other_seat(state, state.winner)
	if state.resource_count(state.winner, CardDB.RES_CASH) >= int(CardDB.game_rules()["win_cash"]):
		return "listing"
	if state.resource_count(loser, CardDB.RES_CASH) <= 0:
		return "bankrupt"
	if state.resource_count(loser, CardDB.RES_USER) <= 0:
		return "exodus"
	return "resign"

## 输家离哪条胜利路线最近：自己差多少冲线、对手还剩多少钱或用户，取数字最小的一条。
static func near_miss(state: GameState, my_seat: String) -> String:
	var foe := _other_seat(state, my_seat)
	var options: Array = []
	var gap := int(CardDB.game_rules()["win_cash"]) - state.resource_count(my_seat, CardDB.RES_CASH)
	if gap > 0:
		options.append([gap, "差 %d %s就上市了。" % [gap, CardDB.res_label(CardDB.RES_CASH)]])
	for res in [CardDB.RES_CASH, CardDB.RES_USER]:
		var left := state.resource_count(foe, res)
		if left > 0:
			options.append([left, "对手只剩 %d %s。" % [left, CardDB.res_label(res)]])
	if options.is_empty():
		return ""
	options.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	return str(options[0][1])

static func _other_seat(state: GameState, seat: String) -> String:
	for key in state.players:
		if str(key) != seat:
			return str(key)
	return GameState.BOT if seat == GameState.PLAYER else GameState.PLAYER

## 业务方建好附加按钮后统一挂载；教程只指定演出结束后的续课动作。
static func present(result: Dictionary, presentation: Node, completed := Callable()) -> void:
	if presentation != null:
		presentation.register_result_panel(result["layer"])
	else:
		fit(result, result["layer"].get_viewport().get_visible_rect().size)
	if result["auto_dismiss"]:
		result["animation"].finished.connect(func():
			close(result)
			if completed.is_valid(): completed.call(), CONNECT_ONE_SHOT)

static func set_active(result: Dictionary, active: bool) -> void:
	if not result.is_empty():
		result["layer"].visible = active

static func close(result: Dictionary) -> void:
	if result.is_empty(): return
	var animation: Tween = result["animation"]
	if animation != null and animation.is_valid(): animation.kill()
	var layer: CanvasLayer = result["layer"]
	if is_instance_valid(layer):
		layer.hide()
		layer.queue_free()
	result.clear()

static func fit(result: Dictionary, available: Vector2) -> void:
	var panel: PanelContainer = result["panel"]
	panel.custom_minimum_size.x = minf(panel.custom_minimum_size.x, maxf(200.0, available.x - 24.0))
	var canvas: CanvasLayer = result["layer"]
	var center: CenterContainer = result["center"]
	canvas.scale = Vector2.ONE
	center.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	center.position = available * 0.5
	# 自动换行的初始最小高度尚未按面板宽度排版，不能拿它算缩放。
	var tree: SceneTree = canvas.get_tree()
	for i in 2:
		await tree.process_frame
		if not is_instance_valid(canvas):
			return
	var extent := panel.get_combined_minimum_size()
	var factor := minf(1.0, minf((available.x - 16) / extent.x, (available.y - 16) / extent.y))
	canvas.scale = Vector2.ONE * maxf(0.1, factor)
	center.position = available * 0.5 / canvas.scale
