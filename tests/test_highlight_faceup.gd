# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 金光要真的写进材质，不能只记在 highlighted 上。
## 正面和背面均为程序化 ShaderMaterial，翻面期间切换高亮/调暗后，
## 翻回正面仍须恢复当前状态；测试不再依赖旧卡背的 StandardMaterial3D。

const HL := Color(1.55, 1.3, 0.45)   # Board.refresh_group 用的凑满金


## 卡面材质上当前的 tint。缺少程序化卡面返回 INF，让前置条件明确失败。
func plate_tint(e: CardEntity) -> Vector3:
	var plate: MeshInstance3D = e._plate
	if plate == null or not (plate.material_override is ShaderMaterial):
		return Vector3.INF
	var v: Variant = (plate.material_override as ShaderMaterial) \
		.get_shader_parameter("tint")
	return v if v is Vector3 else Vector3.INF


func _initialize() -> void:
	print("=== 高亮跨翻面测试 ===")
	var main: Node = await boot_main()
	var cs: Array = main.state.players[GameState.PLAYER]["cards"]
	var e: CardEntity = main.entities[cs[0]["uid"]]

	# 底板着色器是这条路的前提，缺了下面每一条查的都是别的事
	if not need(plate_tint(e) != Vector3.INF, "牌有底板着色器材质（tint 通道存在）"):
		finish()
		return

	# 1. 正面态：高亮该立刻写进材质
	e.set_highlight(true, HL)
	var lit := plate_tint(e)
	check(lit.x > 1.2 and lit.y > 1.1,
		"正面态高亮写进底板 tint（实际 %.2f, %.2f, %.2f）" % [lit.x, lit.y, lit.z])

	e.set_highlight(false)
	var off := plate_tint(e)
	check(absf(off.x - 1.0) < 0.01, "灭灯回到白（实际 %.2f）" % off.x)

	# 2. 背面态点亮 → 翻回正面：金光必须补上
	# 这是「牌还在飞、组合已经成立」那一刻的形状
	e.set_face_down(true)
	check(e._face_down, "先确认真翻到背面了（否则下面查的是正面态，白测）")
	e.set_highlight(true, HL)
	e.set_face_down(false)
	check(not e._face_down, "翻回正面")

	check(e.highlighted, "highlighted 仍是 true（状态没丢，丢的是画面）")
	var back := plate_tint(e)
	check(back.x > 1.2 and back.y > 1.1,
		"背面期间点亮的金光，翻回正面后写进了 tint（实际 %.2f, %.2f, %.2f）"
			% [back.x, back.y, back.z])

	# 3. 反向：背面态灭灯 → 翻回正面不该留着上一次的金光
	# 先在**正面**把金光真写进材质，否则材质上本来就是白的，
	# 这一条不修也过 —— 判据看着绿，其实什么都没查（见 memory: vacuous-mutation-two-flavors）
	e.set_face_down(false)
	e.set_highlight(true, HL)
	check(plate_tint(e).x > 1.2, "先让材质上真有金光（否则下一条白测）")
	e.set_face_down(true)
	e.set_highlight(false)
	e.set_face_down(false)
	var back_off := plate_tint(e)
	check(absf(back_off.x - 1.0) < 0.01,
		"背面期间灭的灯，翻回正面后也不留金光（实际 %.2f）" % back_off.x)

	# 4. 调暗（BOT 的牌）也走同一条通道，一起钉住：
	#    只补 highlighted 不补 _dimmed 的话，对手的牌翻回正面就变亮了
	e.set_face_down(true)
	e.set_dimmed(true)
	e.set_face_down(false)
	var dim := plate_tint(e)
	check(dim.x < 0.95,
		"背面期间调暗，翻回正面后 tint 也压下来了（实际 %.2f）" % dim.x)
	e.set_dimmed(false)

	finish()
