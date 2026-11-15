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
const BATCH_GRIP := 0.16
const BATCH_DURATION := 0.74
## 撕开的四拍，合计正好是 TEAR_TIME，整批时长和以前一样：
##   扯开 RIP_SNAP     两只手往斜对角一把扯开，纸片跟着各自那只手甩过去；
##   拖住 RIP_FOLLOW   手和纸片再滑一小段慢下来，看得清撕成了两半；
##   揉团 RIP_CRUMPLE  两片各自在手里揉成纸团；
##   扔掉 RIP_TOSS     纸团沿弧线抛出去，最后一小段才变透明。
## 纸片在扔出去之前一直不透明。原来是「两片慢慢滑开、同时淡出」，读作牌蒸发了，不像被撕了。
const RIP_SNAP := 0.08
const RIP_FOLLOW := 0.10
const RIP_CRUMPLE := 0.10
const RIP_TOSS := TEAR_TIME - RIP_SNAP - RIP_FOLLOW - RIP_CRUMPLE
## 扯开、拖住时下片的位移（上片取反）；撕口是横的，手往斜对角扯。
const RIP_PULL := Vector3(0.20, 0.03, 0.36)
const RIP_DRIFT := Vector3(0.07, -0.02, 0.12)
## 纸片跟在手后面，两片朝同一个方向甩：扯开时甩到 RIP_SWING，拖住时回到 RIP_REST（度）。
const RIP_SWING := -17.0
const RIP_REST := -9.0
## 纸团抛出的水平位移（上片取反）和弧线高度。
const RIP_THROW := Vector3(1.5, 0.0, 1.1)
const RIP_ARC := 0.75
const SUCK_TIME := UIMotion.TRANSFER
const PAWN_TRAVEL_TIME := UIMotion.ANTICIPATE + UIMotion.ACT + UIMotion.SETTLE + UIMotion.SETTLE + SUCK_TIME
## 同批到货逐张升调的步长与封顶张数；再多也停在这个音高，不会尖到刺耳。
const ARRIVAL_PITCH_STEP := 0.045
const ARRIVAL_PITCH_STEPS := 8
var board: Board
var sfx: Sfx
var clamp_to_player := false
var _tear_cards: Array = []
var _tear_tweens: Array[Tween] = []
var _tear_hands: Node
var _tear_hands_mode := Node.PROCESS_MODE_ALWAYS
var _tear_hands_visible := true

func bind(target_board: Board, sound: Sfx, clamp_player := false) -> void:
	board = target_board
	sfx = sound
	clamp_to_player = clamp_player

## 正式对局和独立预览共享整叠抓握、同步撕开及一次音效。
## 抓握到位的一刻是命中：on_impact 在这一拍触发，随后整批顿住 hitstop 秒
## （牌被砸得一扁、双手按住发抖）再撕开。普通一击的顿帧已含在 BATCH_DURATION 内，
## 只有更长的终结顿帧会把整批时长顺延同样的差值。
func tear_batch(members: Array, hands: Node, direction := Vector3(0, 4, 2),
		hitstop := UIMotion.HITSTOP, on_impact := Callable()) -> float:
	var cards := members.filter(func(card): return is_instance_valid(card))
	if cards.is_empty():
		return 0.0
	var hold := maxf(0.0, hitstop)
	var duration := BATCH_DURATION + maxf(0.0, hold - UIMotion.HITSTOP)
	var center := Vector3.ZERO
	for card in cards:
		center += card.global_position
	center /= float(cards.size())
	var packet: Array[Vector3] = []
	for i in cards.size():
		packet.append(center + Vector3((i - (cards.size() - 1) * 0.5) * 0.10, i * 0.008, i * 0.035))
	if is_instance_valid(hands):
		if _tear_hands != hands:
			_tear_hands = hands
			_tear_hands_mode = hands.process_mode
			_tear_hands_visible = hands.visible
		hands.tear(cards, packet, hold, duration)
	_tear_cards = _tear_cards.filter(func(card): return is_instance_valid(card))
	_tear_cards.append_array(cards)
	_tear_tweens = _tear_tweens.filter(func(tween): return tween != null and tween.is_valid())
	for i in cards.size():
		var card: CardEntity = cards[i]
		board.drop_card(card)
		card.reset_interaction_visual()
		_cancel_fly(card)
		card.freeze = true
		card.collision_layer = 0
		card.collision_mask = 0
		# 卡牌与运动节点属于同一个演出宿主；教学暂停时抓握和撕开同时停住。
		var grip := card.create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		grip.tween_property(card, "global_position", packet[i], BATCH_GRIP)
		if hold > 0.0:
			# 砸实的一下：牌面横向一胀、纵向一扁，顿帧结束恰好回到原形再撕。
			grip.tween_property(card._visual, "scale", Vector3(1.08, 1.0, 0.90), hold * 0.35) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			grip.tween_property(card._visual, "scale", Vector3.ONE, hold * 0.65)
		_tear_tweens.append(grip)
		_tear_tweens.append(delayed_tear(card, direction, BATCH_GRIP + hold, false))
	_tear_tweens.append(delayed_sound("attack_tear", BATCH_GRIP + hold))
	if on_impact.is_valid():
		_tear_tweens.append(delayed_call(on_impact, BATCH_GRIP))
	return duration

## 手仍是原牌桌那一双；只有当前撕牌宿主临时保管其暂停状态。
func set_tear_active(active: bool) -> void:
	if not is_instance_valid(_tear_hands): return
	_tear_hands.process_mode = _tear_hands_mode if active else Node.PROCESS_MODE_DISABLED
	_tear_hands.visible = _tear_hands_visible if active else false

func cancel_tears() -> void:
	for tween in _tear_tweens:
		if tween != null and tween.is_valid(): tween.kill()
	_tear_tweens.clear()
	for card in _tear_cards:
		if is_instance_valid(card): card.queue_free()
	_tear_cards.clear()
	if is_instance_valid(_tear_hands):
		_tear_hands.clear()
		set_tear_active(true)
	_tear_hands = null

func _fly_from(e: CardEntity, from_pos: Vector3, to_pos: Vector3,
		idx: int = 0, total: int = 1, delay := 0.0) -> Tween:
	e.freeze = true
	var n: int = maxi(total, 1)
	var stagger: float = delay + SPAWN_FLY_SPREAD / float(n) * float(idx)
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
	var tw := create_tween().bind_node(e).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	if idx == 0 and not get_viewport().disable_3d:
		var trace := func(): Feedback.trace(get_parent(), "arrival", from_pos, to_pos + Vector3.UP * 0.08, CardArt.accent_color(e.def_id, e.card_catalog), SPAWN_FLY_TIME)
		if delay > 0.0:
			tw.parallel().tween_callback(trace).set_delay(stagger)
		else:
			trace.call()
	if delay > 0.0:
		e.hide()
		e.set_meta("arrival_hidden", true)
		tw.parallel().tween_callback(func():
			e.show()
			e.remove_meta("arrival_hidden")).set_delay(stagger)
	tw.parallel().tween_property(e, "position", to_pos, SPAWN_FLY_TIME) \
		.set_delay(stagger)
	tw.parallel().tween_property(e._visual, "scale", Vector3.ONE, SPAWN_FLY_TIME) \
		.set_delay(stagger)
	# 落地一声 drop：产出没有独立音效，这一批「几张牌落到桌上」就是它的声音。
	# 音量与手放牌落桌一致 —— 同一件事同一个响度，两个动作在配置里指着同一个
	# 音效同一档 db（见 _sfx.actions 的 produce_land 和 card_drop）。
	# 挂在补间里而不是提前算时刻：飞入被 _cancel_fly 掐掉的那几张就不该响，
	# 牌没落地的声音是假的
	# 同一批逐张升调：一串落地声听得出「越来越多」，像收银机在数钱。
	# 现金再叠一声硬币叮，用户没有这一声 —— 听得出到账的是钱还是人。
	var pitch := 1.0 + ARRIVAL_PITCH_STEP * float(mini(idx, ARRIVAL_PITCH_STEPS))
	var coin: bool = e.card_catalog.get_def(e.def_id).get("res", "") == e.card_catalog.RES_CASH \
		and e.card_catalog.get_def(e.def_id).get("kind", "") == OnWorkCardDB.KIND_UNIT
	tw.parallel().tween_callback(func() -> void:
		sfx.play("produce_land", pitch)
		if coin:
			sfx.play("produce_coin", pitch)) \
		.set_delay(stagger + SPAWN_FLY_TIME)
	# 落地撤掉归宿：此后实时坐标就是答案（见 _move_to）
	tw.parallel().tween_callback(func() -> void:
		_clear_dest(e)
		e.pulse_feedback("arrive", CardArt.accent_color(e.def_id, e.card_catalog))) \
		.set_delay(stagger + SPAWN_FLY_TIME)
	# 记在卡上，好让后面搬它的人（_move_to_spot）先掐掉这一段。
	# Godot 不会因为同一个属性又被补间就作废前一条，两条一起跑会互相拉扯；
	# 而 _layout_group 是直接赋值坐标的，会被没跑完的飞入补间逐帧盖回去。
	# 眼下 _resolve_combo_visual 尾部等 0.7s、飞入只要 0.34s，实际撞不上，
	# 但那是两个不相干的常量正好错开，不是约束 —— 这里把它变成约束
	e.set_meta("fly_tw", tw)
	return tw

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
	if e.has_meta("arrival_hidden"):
		e.show()
		e.remove_meta("arrival_hidden")
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

	# 扯开、拖住、揉团、扔掉（时长见 RIP_* 的说明）。四拍加起来正好是 TEAR_TIME。
	var tw := create_tween().bind_node(card).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var crumple_at := RIP_SNAP + RIP_FOLLOW
	for i in halves.size():
		var piece: Node3D = halves[i]
		var sign := -1.0 if i == 0 else 1.0
		var mat := (piece.get_child(0) as MeshInstance3D).material_override as ShaderMaterial
		var p0: Vector3 = piece.position
		var torn := p0 + Vector3(sign * RIP_PULL.x, RIP_PULL.y, sign * RIP_PULL.z)
		var held := torn + Vector3(sign * RIP_DRIFT.x, RIP_DRIFT.y, sign * RIP_DRIFT.z)
		var landing := held + Vector3(sign * RIP_THROW.x, RIP_THROW.y, sign * RIP_THROW.z)
		# 扯开：快出慢收，一下子就分开了；纸片绕竖轴甩一下，像被手带着走。
		tw.parallel().tween_property(piece, "position", torn, RIP_SNAP) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(piece, "rotation_degrees:y", RIP_SWING, RIP_SNAP) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		# 拖住：再滑一小段慢下来。
		tw.parallel().tween_property(piece, "position", held, RIP_FOLLOW).set_delay(RIP_SNAP) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(piece, "rotation_degrees:y", RIP_REST, RIP_FOLLOW).set_delay(RIP_SNAP) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		# 揉团：卡名、墨团这些贴在纸上的字跟不了顶点形变，揉的那一刻就收进纸团里。
		var overlays: Array = piece.get_children().filter(func(n): return n is Label3D or n is Sprite3D)
		tw.parallel().tween_callback(func() -> void:
			for n in overlays:
				if is_instance_valid(n): n.hide()).set_delay(crumple_at)
		tw.parallel().tween_method(func(v: float) -> void: mat.set_shader_parameter("ball", v),
			0.0, 1.0, RIP_CRUMPLE).set_delay(crumple_at).set_trans(Tween.TRANS_LINEAR)
		# 扔掉：沿弧线抛出去，飞过六成才开始变透明。淡出走 shader 的 fade（MeshInstance3D 没有 modulate）。
		tw.parallel().tween_method(func(v: float) -> void:
			piece.position = held.lerp(landing, v) + Vector3.UP * sin(v * PI) * RIP_ARC
			mat.set_shader_parameter("fade", 1.0 - smoothstep(0.62, 1.0, v)),
			0.0, 1.0, RIP_TOSS).set_delay(crumple_at + RIP_CRUMPLE).set_trans(Tween.TRANS_LINEAR)
	# 整张卡跟着朝受击方向飘一点，别让两片在原地对称展开（太机械）
	tw.parallel().tween_property(card, "position",
		card.position + dir.normalized() * 0.35 + Vector3(0, 0.12, 0), TEAR_TIME)
	tw.chain().tween_callback(card.queue_free)
	transferring()
	_transfers.append(tw)
	if _tear_cards.has(card): _tear_tweens.append(tw)

var _transfers: Array[Tween] = []

## 典当先展示完整正面，抵达柜台后再吸收；与付款共用吸收收尾。
func pawn_into(card: CardEntity, target: Vector3, delay := 0.0) -> Tween:
	board.drop_card(card)
	var tween := move_above_table(card, target, delay)
	tween.tween_interval(UIMotion.SETTLE)
	tween.tween_callback(func(): card.pulse_feedback("consume"))
	_consume(tween, card, target, 0.0)
	return tween

func _suck_into(card: CardEntity, target: Vector3, delay := 0.0) -> void:
	# 付款与攻击一样要补齐剩余层位；只注销会让新队首停在旧层，
	# 下次点击按新层数反推起点时，收拢摞可能被排到桌面以下。
	board.drop_card(card)
	card.freeze = true
	card.set_meta("dest_pos", target)
	card.pulse_feedback("consume", Color.TRANSPARENT, delay)
	var tw := create_tween().bind_node(card).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	_consume(tw, card, target, delay)

func _consume(tw: Tween, card: CardEntity, target: Vector3, delay: float) -> void:
	# 错开用每条补间自己的 set_delay，不用 tween_interval：
	# interval 之后紧跟 parallel() 会和 interval **并行**（那就等于没有延迟），
	# 得写成 chain() 才是串行 —— 两个 parallel 各自带 delay 更不容易读错
	# （_tear_out 里那两条淡出也是这么错开的）
	tw.chain().tween_property(card, "position", target, SUCK_TIME).set_delay(delay)
	tw.parallel().tween_property(card._visual, "scale",
		Vector3.ONE * 0.1, SUCK_TIME).set_delay(delay)
	# 错开期间这张牌不会被别人搬走：上面已经 unregister + freeze，
	# 它就停在原地等自己那一拍
	tw.chain().tween_callback(card.queue_free)
	transferring()
	_transfers.append(tw)

func delayed_sound(action: String, delay: float) -> Tween:
	if delay <= 0:
		sfx.play(action)
		return null
	var tween := create_tween()
	tween.tween_interval(delay)
	tween.tween_callback(func(): sfx.play(action))
	transferring()
	_transfers.append(tween)
	return tween

## 与延迟音同一条可取消队列：回滚或换局时一起撤掉，教学暂停时一起停住。
func delayed_call(callback: Callable, delay: float) -> Tween:
	if delay <= 0:
		callback.call()
		return null
	var tween := create_tween()
	tween.tween_interval(delay)
	tween.tween_callback(callback)
	transferring()
	_transfers.append(tween)
	return tween

func delayed_tear(card: CardEntity, direction: Vector3, delay: float, with_sound: bool) -> Tween:
	var tween := create_tween().bind_node(card)
	tween.tween_interval(delay)
	tween.tween_callback(func():
		if with_sound:
			sfx.play("attack_tear")
		_tear_out(card, direction))
	return tween

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
	# 玩家已经把商品拖到目标上方时，只需落桌，不能再绕回货架或换一个位置。
	if not Vector2(card.position.x, card.position.z).is_equal_approx(Vector2(target.x, target.z)):
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

## 回滚前由运动组件撤销自己持有的转移与延迟音，调用方随后恢复实体快照。
func cancel_transfers() -> void:
	for tween in _transfers:
		if tween != null and tween.is_valid(): tween.kill()
	_transfers.clear()
