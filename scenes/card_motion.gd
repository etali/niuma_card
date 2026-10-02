# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends Node

## 对局与规则演示共用的卡牌运动。几何、节拍、材质与淡出只在这里实现。
const Feedback = preload("res://scenes/table_feedback.gd")
const UIMotion = preload("res://scenes/ui_motion.gd")
const SPAWN_FLY_TIME := UIMotion.ACT
const SPAWN_FLY_SPREAD := 0.3
const SPAWN_FLY_RING := 0.85
const TEAR_TIME := UIMotion.TEAR
const SUCK_TIME := UIMotion.TRANSFER
var board: Board
var sfx: Sfx
var clamp_to_player := false

func bind(target_board: Board, sound: Sfx, clamp_player := false) -> void:
	board = target_board
	sfx = sound
	clamp_to_player = clamp_player

func _fly_from(e: CardEntity, from_pos: Vector3, to_pos: Vector3,
		idx: int = 0, total: int = 1) -> void:
	e.freeze = true
	var n: int = maxi(total, 1)
	var stagger: float = SPAWN_FLY_SPREAD / float(n) * float(idx)
	# 等角度铺一圈，半径交替大小免得 n 大时相邻两张贴太近
	var ang: float = TAU * float(idx) / float(n)
	var r: float = SPAWN_FLY_RING * (1.0 if idx % 2 == 0 else 0.6)
	var off := Vector3(cos(ang) * r, 0.35 + 0.06 * float(idx % 3),
		sin(ang) * r * 0.7)
	e.position = from_pos + off
	# 归宿先宣告出去（同 _move_to 的理由）：这一批是同时出生的，
	# 实时坐标全在出发点上，后面几张问落点时得看得见前面几张要去哪
	e.set_meta("dest_pos", to_pos)
	# 起飞时小一点、落地长回原大小：远近感，也让密集产出的那一堆卡不糊成一片
	e._visual.scale = Vector3.ONE * 0.55
	if idx == 0 and not get_viewport().disable_3d:
		Feedback.trace(get_parent(), "arrival", from_pos, to_pos + Vector3.UP * 0.08, CardArt.accent_color(e.def_id), SPAWN_FLY_TIME)
	var tw := create_tween().bind_node(e).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(e, "position", to_pos, SPAWN_FLY_TIME) \
		.set_delay(stagger)
	tw.parallel().tween_property(e._visual, "scale", Vector3.ONE, SPAWN_FLY_TIME) \
		.set_delay(stagger)
	# 落地一声 drop：产出没有独立音效，这一批「几张牌落到桌上」就是它的声音。
	# 音量与手放牌落桌一致 —— 同一件事同一个响度，两个动作在配置里指着同一个
	# 音效同一档 db（见 _sfx.actions 的 produce_land 和 card_drop）。
	# 挂在补间里而不是提前算时刻：飞入被 _cancel_fly 掐掉的那几张就不该响，
	# 牌没落地的声音是假的
	tw.parallel().tween_callback(func() -> void: sfx.play("produce_land")) \
		.set_delay(stagger + SPAWN_FLY_TIME)
	# 落地撤掉归宿：此后实时坐标就是答案（见 _move_to）
	tw.parallel().tween_callback(func() -> void:
		_clear_dest(e)
		e.pulse_feedback("arrive", CardArt.accent_color(e.def_id))) \
		.set_delay(stagger + SPAWN_FLY_TIME)
	# 记在卡上，好让后面搬它的人（_move_to_spot）先掐掉这一段。
	# Godot 不会因为同一个属性又被补间就作废前一条，两条一起跑会互相拉扯；
	# 而 _layout_group 是直接赋值坐标的，会被没跑完的飞入补间逐帧盖回去。
	# 眼下 _resolve_combo_visual 尾部等 0.7s、飞入只要 0.34s，实际撞不上，
	# 但那是两个不相干的常量正好错开，不是约束 —— 这里把它变成约束
	e.set_meta("fly_tw", tw)

func _clear_dest(e: CardEntity) -> void:
	if is_instance_valid(e) and e.has_meta("dest_pos"):
		e.remove_meta("dest_pos")

func _move_to(card: CardEntity, target: Vector3, time := 0.35,
		trans := Tween.TRANS_BACK) -> Tween:
	# 先掐掉这张牌上一段还没跑完的位移：同一个属性两条补间会互相拉扯
	# （见 _cancel_fly 的说明）。连着搬同一张牌是有的 —— 买到手飞向落点的
	# 途中被理牌挪走就是
	_cancel_fly(card)
	if clamp_to_player and card.draggable and not card.is_market:
		target = board.clamp_player_position(target)
	card.set_meta("dest_pos", target)
	var tw := create_tween().bind_node(card).set_trans(trans).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "position", target, time)
	# 落地就把归宿撤掉：之后它的实时坐标就是答案，留着反而会在牌被别处搬走
	# （拖拽、组合、理牌）之后指着一个它已经不在的地方
	tw.tween_callback(func() -> void: _clear_dest(card))
	# 登记进 fly_tw：那个 meta 的含义是「这张牌身上有一段没跑完的位移」，
	# 买卡飞的这 0.35s 和产出飞入是同一件事。**不登记就掐不掉** ——
	# 而掐不掉的后果是「组合卡有时候会消失」：玩家把一摞资源拖到一张刚买到手
	# （还在飞）的组合卡上，board 编组时按它此刻的中间坐标排好整摞，
	# 这条补间接着跑完，把核心卡一路搬去 target，摞里剩下的留在原地 ——
	# 屏幕上就是「组合卡不见了」，实测核心卡离组内第二张 0.89 远
	# （tests/test_merge.gd 的「拖到在飞的组合卡上」一节）
	card.set_meta("fly_tw", tw)
	return tw

func _cancel_fly(e: CardEntity) -> void:
	if not is_instance_valid(e):
		return
	# 归宿要撤：掐掉补间意味着它不会飞到那儿去了，留着会让避让绕开一个空位。
	# 放在 fly_tw 的判断之外 —— 走 _move_to 搬的牌没有 fly_tw，但一样宣告过归宿
	_clear_dest(e)
	if not e.has_meta("fly_tw"):
		return
	var tw = e.get_meta("fly_tw")
	if tw is Tween and tw.is_valid():
		tw.kill()
		e.reset_interaction_visual()   # 起飞效果也只复位视觉容器
	e.remove_meta("fly_tw")

func _shake(card: CardEntity) -> void:
	card.reset_interaction_visual()
	var tw := create_tween().bind_node(card)
	for i in 3:
		tw.tween_property(card._visual, "position:x", 0.06, 0.05)
		tw.tween_property(card._visual, "position:x", -0.06, 0.05)
	tw.tween_property(card._visual, "position:x", 0.0, 0.05)

func _fly_out(card: CardEntity, target := Vector3(0, 4, 2)) -> void:
	board.unregister_card(card)
	card.freeze = true
	card.set_face_down(true)   # 离场翻卡背；缺少卡背插画时使用程序化卡背。
	var tw := create_tween().bind_node(card).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(card, "position", card.position + target, 0.4)
	tw.parallel().tween_property(card, "rotation_degrees:z", 60, 0.4)
	tw.tween_callback(card.queue_free)

func _tear_out(card: CardEntity, dir: Vector3) -> void:
	board.unregister_card(card)
	card.freeze = true
	var halves: Array = card.tear_apart()
	if halves.is_empty():
		_fly_out(card, dir)
		return

	# 文字类元素按位置跟着自己那半张纸走：撕口在卡面 UV.y≈0.5，
	# 在它上头的归上片（halves[0]，side=-1），下头的归下片
	for n in card.face_overlays():
		var piece: Node3D = halves[0] if card.overlay_uv_y(n) < 0.5 else halves[1]
		var keep: Vector3 = n.position - piece.position
		n.get_parent().remove_child(n)
		piece.add_child(n)
		n.position = keep      # 换了父节点，减掉父节点偏移才留在原来的视觉位置

	# 两片各自朝上下翻出去：沿卡面纵向（z）平移 + 绕横轴（x）翻 + 略微下沉
	var tw := create_tween().bind_node(card).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	for i in halves.size():
		var piece: Node3D = halves[i]
		var sign := -1.0 if i == 0 else 1.0
		var mat := (piece.get_child(0) as MeshInstance3D).material_override as ShaderMaterial
		var p0: Vector3 = piece.position
		tw.parallel().tween_property(piece, "position",
			p0 + Vector3(0.0, -0.05, sign * 0.55), TEAR_TIME)
		# 绕 x 轴翻：撕口是横的，两片该像书页一样朝上下掀开
		tw.parallel().tween_property(piece, "rotation_degrees:x", sign * 34.0, TEAR_TIME)
		# 淡出走 shader 的 fade，不用 modulate —— MeshInstance3D 没有 modulate
		# 淡出要和撕开的位移同时收尾：延迟 0.35 之后只剩 0.65 可用，
		# 若还按 TEAR_TIME 整段淡，收尾会拖到 1.35 倍时长（0.62s），
		# 两片早就飞停了还挂在桌上，最后一下才闪掉。
		# 缓动也不能沿用外层的 EASE_IN：那样大半程都是满不透明，
		# 观感是「突然消失」而不是「渐变消失」，这里单独压成线性
		tw.parallel().tween_method(
			func(v: float): mat.set_shader_parameter("fade", v),
			1.0, 0.0, TEAR_TIME * 0.65).set_delay(TEAR_TIME * 0.35) \
			.set_trans(Tween.TRANS_LINEAR)
		# 跟着走的文字一起淡：它们是 Label3D/Sprite3D，吃不到 shader 的 fade
		for n in piece.get_children():
			if n is Label3D or n is Sprite3D:
				tw.parallel().tween_property(n, "modulate:a", 0.0,
					TEAR_TIME * 0.65).set_delay(TEAR_TIME * 0.35) \
					.set_trans(Tween.TRANS_LINEAR)
	# 整张卡跟着朝受击方向飘一点，别让两片在原地对称展开（太机械）
	tw.parallel().tween_property(card, "position",
		card.position + dir.normalized() * 0.35 + Vector3(0, 0.12, 0), TEAR_TIME)
	tw.chain().tween_callback(card.queue_free)
	transferring()
	_transfers.append(tw)

var _transfers: Array[Tween] = []

func _suck_into(card: CardEntity, target: Vector3, delay := 0.0) -> void:
	# 付款与攻击一样要补齐剩余层位；只注销会让新队首停在旧层，
	# 下次点击按新层数反推起点时，收拢摞可能被排到桌面以下。
	board.drop_card(card)
	card.freeze = true
	card.set_meta("dest_pos", target)
	card.pulse_feedback("consume", Color.TRANSPARENT, delay)
	var tw := create_tween().bind_node(card).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	# 错开用每条补间自己的 set_delay，不用 tween_interval：
	# interval 之后紧跟 parallel() 会和 interval **并行**（那就等于没有延迟），
	# 得写成 chain() 才是串行 —— 两个 parallel 各自带 delay 更不容易读错
	# （_tear_out 里那两条淡出也是这么错开的）
	tw.parallel().tween_property(card, "position", target, SUCK_TIME).set_delay(delay)
	tw.parallel().tween_property(card._visual, "scale",
		Vector3.ONE * 0.1, SUCK_TIME).set_delay(delay)
	# 错开期间这张牌不会被别人搬走：上面已经 unregister + freeze，
	# 它就停在原地等自己那一拍
	tw.chain().tween_callback(card.queue_free)
	transferring()
	_transfers.append(tw)

func delayed_sound(action: String, delay: float) -> void:
	if delay <= 0:
		sfx.play(action)
		return
	var tween := create_tween()
	tween.tween_interval(delay)
	tween.tween_callback(func(): sfx.play(action))

func delayed_tear(card: CardEntity, direction: Vector3, delay: float, with_sound: bool) -> void:
	var tween := create_tween().bind_node(card)
	tween.tween_interval(delay)
	tween.tween_callback(func():
		if with_sound:
			sfx.play("attack_tear")
		_tear_out(card, direction))

## 教学的拖动输入和真实购买到货都在牌面上方移动，避免图标与下方牌面同高穿插。
func move_above_table(card: CardEntity, target: Vector3, delay := 0.0) -> Tween:
	_cancel_fly(card)
	board._stop_move(card, false)
	card.freeze = true
	card.set_meta("dest_pos", target)
	var lift := maxf(Board.DRAG_HEIGHT, maxf(card.position.y, target.y) + CardEntity.FACE_SPAN_Y)
	var tween := create_tween().bind_node(card)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if delay > 0.0:
		tween.tween_interval(delay)
	tween.tween_property(card, "position:y", lift, UIMotion.ANTICIPATE)
	tween.tween_property(card, "position", Vector3(target.x, lift, target.z), UIMotion.ACT)
	tween.tween_property(card, "position", target, UIMotion.SETTLE)
	tween.tween_callback(func(): _clear_dest(card))
	card.set_meta("fly_tw", tween)
	return tween

func drag_stack(cards: Array, at: Vector3) -> void:
	if cards.is_empty():
		return
	var origins: Array[Vector3] = []
	for card in cards:
		board._stop_move(card)
		origins.append(card.position)
	for card in cards:
		board._detach_from_group(card)
	for i in cards.size():
		var card: CardEntity = cards[i]
		board._stop_move(card, false)
		card.position = origins[i]
		var offset := origins[i] - origins[0]
		var target := at + offset
		target.y = maxf(Board.DRAG_HEIGHT, at.y + CardEntity.CARD_SIZE.y + CardEntity.FACE_SPAN_Y) + offset.y
		move_above_table(card, target)

func transferring() -> bool:
	_transfers = _transfers.filter(func(tween): return tween != null and tween.is_valid() and tween.is_running())
	return not _transfers.is_empty()
