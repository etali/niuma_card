# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 配方支付与资源产出的演出坐标回归。
## 现金→用户时，付款 tween 的实际终点必须等于下一张用户卡通过 arrival_spot
## 得到的真实结算带落点，而不是只落在同一条资源带的粗略锚点。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 现金支付 / 用户产出动画落点回归 ===")
	var main: Node = await boot_main()
	if not need(main != null and main.layout != null, "场景和结算布局启动"):
		finish()
		return
	var layout: Node = main.layout
	layout.begin_arrivals()

	var combo := {"eval": {"type": "production", "output_res": CardDB.RES_USER}}
	var preview: Vector3 = layout.preview_band_arrival_spot(CardDB.RES_USER)
	var payment: Vector3 = main._payment_animation_target(main.my_seat, combo)
	check(payment.distance_to(preview) < 0.0001,
		"现金付款目标与下一张用户卡预览落点重合（差 %.5f）" % payment.distance_to(preview))

	# 用真实 arrival_spot 提交一张用户产出卡；预览不能推进台账，
	# 因此这里仍应得到同一个具体组位，而不是只同 x/z 粗略相近。
	var output_card := {"uid": 900001, "def_id": CardDB.unit_id(CardDB.RES_USER)}
	var actual_output: Vector3 = layout.arrival_spot(main.my_seat, output_card)
	check(payment.distance_to(actual_output) < 0.0001,
		"现金吸入 tween 终点与用户产出实际落点重合（差 %.5f）" % payment.distance_to(actual_output))
	check(payment.is_equal_approx(actual_output),
		"现金与用户使用完全相同的三维坐标（x/y/z 全部一致）")
	var foe_preview: Vector3 = layout.preview_arrival_spot(GameState.BOT,
		{"def_id": CardDB.unit_id(CardDB.RES_USER)})
	var foe_combo := {"eval": {"type": "production", "output_res": CardDB.RES_USER}}
	check(main._payment_animation_target(GameState.BOT, foe_combo).is_equal_approx(foe_preview),
		"对手现金→用户也使用对手实际用户产出落点")

	# _suck_into 会把最终 tween 目标写入 dest_pos，验证不是只测了一个辅助函数返回值。
	var pay_state: Dictionary = main.state.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH))
	var pay_entity: CardEntity = main._spawn_entity(pay_state, Vector3(-4, 0.05, 2.0), true)
	main._suck_into(pay_entity, payment)
	var tween_target: Vector3 = pay_entity.get_meta("dest_pos", Vector3.INF)
	check(tween_target.is_equal_approx(payment),
		"现金卡实际 tween 的 dest_pos 与用户产出落点一致")

	layout.end_arrivals()
	finish()
