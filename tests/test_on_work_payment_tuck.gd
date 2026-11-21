# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 上班的付款不缩小：被用掉的牌先靠到用它的那张牌边上、高度低一层，再平着滑到它
## 正下方，被盖住之后才释放。买牌、典当、配方付款、升级材料共用这一段。
const Motion = preload("res://scenes/card_motion.gd")

var main: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 上班付款：压到牌底下 ===")
	main = await boot_main()
	if not need(main != null and main._card_motion != null, "场景和牌的动作控制器启动"):
		finish()
		return
	_from_the_side()
	_from_above()
	_staggered()
	_recipe_target()
	main.queue_free()
	await physics_frame
	finish()

func _cash(at: Vector3) -> CardEntity:
	var record: Dictionary = main.state.add_card(OnWorkState.PLAYER, OnWorkCardDB.unit_id(OnWorkCardDB.RES_CASH))
	return main._spawn_entity(record, at, true)

## 一步一步推进最新那条付款补间，逐步检查这张牌。
func _follow(card: CardEntity, cover: Vector3, label: String, seconds := Motion.SUCK_TIME) -> Dictionary:
	var tween: Tween = main._card_motion._transfers.back()
	tween.pause()
	var steps := 48
	var full_size := true
	var never_through := true
	var lowest_entry := INF
	var farthest := 0.0
	for step in steps:
		tween.custom_step(seconds / float(steps))
		if not is_instance_valid(card) or card.is_queued_for_deletion(): break
		full_size = full_size and card._visual.scale.is_equal_approx(Vector3.ONE) and card.scale.is_equal_approx(Vector3.ONE)
		var offset := Vector2(card.position.x - cover.x, card.position.z - cover.z)
		farthest = maxf(farthest, offset.length())
		var overlapping := absf(offset.x) < CardEntity.CARD_SIZE.x * 0.98 and absf(offset.y) < CardEntity.CARD_SIZE.z * 0.98
		# 和盖住它的牌占地重叠时，它要么明显在上方（刚被放上去），要么已经低一层；
		# 不会在同一层里穿过去。
		if overlapping:
			never_through = never_through and (card.position.y <= cover.y - CardEntity.FACE_SPAN_Y \
				or card.position.y >= cover.y + CardEntity.FACE_SPAN_Y)
			lowest_entry = minf(lowest_entry, card.position.y)
	check(full_size, label + "：全程保持原大小，不缩小")
	check(never_through, label + "：进到那张牌的占地里时已经低一层，图标不会从上面透出来")
	return {"farthest": farthest, "lowest": lowest_entry}

func _from_the_side() -> void:
	var cover := Vector3(-2.0, 0.2, -1.0)
	var card := _cash(Vector3(2.5, 0.05, 2.0))
	main._suck_into(card, cover)
	check(card.collision_layer == 0 and card.collision_mask == 0 and not card.input_ray_pickable,
		"被用掉的牌不再挡点击，也不会把盖住它的牌顶起来")
	check((card.get_meta("dest_pos", Vector3.INF) as Vector3).is_equal_approx(cover), "去向登记的是用它的那张牌")
	var tween: Tween = main._card_motion._transfers.back()
	tween.pause()
	tween.custom_step(Motion.SUCK_TIME * 0.98)
	check(is_instance_valid(card) and not card.is_queued_for_deletion() \
		and Vector2(card.position.x - cover.x, card.position.z - cover.z).length() < CardEntity.CARD_SIZE.x * 0.2 \
		and is_equal_approx(card.position.y, cover.y - Motion.TUCK_DEPTH),
		"最后停在那张牌的正下方，低一层")
	check(card._visual.scale.is_equal_approx(Vector3.ONE), "到位时仍是原大小")
	tween.custom_step(Motion.SUCK_TIME * 0.05)
	check(not is_instance_valid(card) or card.is_queued_for_deletion(), "被盖住之后才释放")
	var again := _cash(Vector3(2.5, 0.05, 2.0))
	main._suck_into(again, cover)
	_follow(again, cover, "从旁边付款")

func _from_above() -> void:
	# 拖到商品或典当行上松手：牌本来就压在上方，要从靠玩家的一侧绕下去。
	var cover := Vector3(1.0, 0.2, -1.0)
	var card := _cash(cover + Vector3(0.1, 0.9, 0.05))
	main._suck_into(card, cover)
	var seen := _follow(card, cover, "从正上方付款")
	check(float(seen.farthest) > CardEntity.CARD_SIZE.z * 0.9, "先绕到那张牌的边上，不是直直穿过去")

func _staggered() -> void:
	# 逐张错开时，后面的牌停在原地等自己那一拍，起点在它出发时才取。
	var cover := Vector3(-2.0, 0.2, -1.0)
	var card := _cash(Vector3(3.0, 0.05, 2.5))
	var start := card.position
	main._suck_into(card, cover, Motion.SUCK_TIME)
	var tween: Tween = main._card_motion._transfers.back()
	tween.pause()
	tween.custom_step(Motion.SUCK_TIME * 0.9)
	check(card.position.is_equal_approx(start), "还没轮到的牌不动")
	tween.custom_step(Motion.SUCK_TIME * 1.05)
	check(is_instance_valid(card) and Vector2(card.position.x - cover.x, card.position.z - cover.z).length() < CardEntity.CARD_SIZE.x * 0.5,
		"轮到之后照样压到那张牌底下")
	tween.custom_step(Motion.SUCK_TIME)

func _recipe_target() -> void:
	# 配方付掉的现金压到用它的那一组的核心牌底下；组不在桌上时退回资源带的落点。
	var actions: Node = main._table_actions
	var members: Array = []
	for index in 3:
		var card := _cash(Vector3(4.0, 0.05 + 0.024 * index, 3.0 + 0.04 * index))
		members.append(card)
	var core: CardEntity = members[2]
	var combo := {"owner": OnWorkState.PLAYER, "uids": members.map(func(card): return card.uid),
		"eval": {"type": "production", "output_res": OnWorkCardDB.RES_CASH, "leader": core.def_id}}
	var leader: CardEntity = actions._leader(members, combo.eval)
	var target: Vector3 = main._payment_animation_target(OnWorkState.PLAYER, combo)
	check(is_equal_approx(target.x, leader.position.x) and is_equal_approx(target.z, leader.position.z) \
		and is_equal_approx(target.y, members[0].position.y),
		"付款目标是这一组的核心牌那一格，高度取整组最低的一张")
	var absent := {"owner": OnWorkState.PLAYER, "uids": [987654321], "eval": {"type": "production", "output_res": OnWorkCardDB.RES_CASH}}
	check(main._payment_animation_target(OnWorkState.PLAYER, absent).is_equal_approx(main.layout.payment_spot(OnWorkState.PLAYER, OnWorkCardDB.RES_CASH)),
		"组不在桌上时退回资源带的落点")
