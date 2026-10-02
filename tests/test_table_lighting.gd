# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 柔和接触阴影 ===")
	var scene := Node3D.new()
	root.add_child(scene)
	var board := Board.new()
	scene.add_child(board)
	for i in 20:
		var card := CardEntity.new()
		card.setup(88000 + i, "cash")
		card.freeze = true
		scene.add_child(card)
		card.position = Vector3(0.0, 0.05, 0.0) + Board.capped_offset(20, i, 8)
		board.register_card(card)
	var resting := TableLighting.contact_footprints(board.cards)
	check(resting.size() == 1, "20 张收拢牌共用一片阴影，不再投出 20 级锯齿")
	var settled: Dictionary = resting[0]
	var settled_center: Vector3 = settled["center"]
	for card in board.cards:
		card.position += Vector3(4.0, Board.DRAG_HEIGHT, 2.0)
	var lifted := TableLighting.contact_footprints(board.cards)
	check(lifted.size() == 1, "拿起整摞仍只有一片影")
	check(lifted[0]["softness"] > settled["softness"], "离桌时投影半影变宽")
	check(lifted[0]["opacity"] < settled["opacity"], "离桌时投影变淡")
	check(lifted[0]["center"].x > settled_center.x + 3.5, "投影跟随真实卡牌横向移动")
	check(is_equal_approx(lifted[0]["center"].y, TableLighting.CONTACT_Y),
		"卡牌拿起后阴影留在桌面")
	for i in board.cards.size():
		board.cards[i].position = Vector3(0.0, 0.05, 0.0) + Board.capped_offset(20, i, 8)
	var lone := CardEntity.new()
	lone.setup(88100, "cash")
	lone.freeze = true
	scene.add_child(lone)
	lone.position = Vector3(0.0, 0.05, 4.0)
	board.register_card(lone)
	var separated := TableLighting.contact_footprints(board.cards)
	check(separated.size() == 2, "同列中相隔很远的两摞有独立阴影，不涂黑中间空白")
	lone.hide()
	check(TableLighting.contact_footprints(board.cards).size() == 1, "隐藏卡不留下幽灵阴影")
	lone.show()
	lone._visual_retired = true
	check(TableLighting.contact_footprints(board.cards).size() == 1, "退场卡不会保留完整卡片形状的影")
	var lighting := TableLighting.new()
	scene.add_child(lighting)
	lighting.bind(board)
	check(lighting._multimesh.visible_instance_count == 1, "同一摞只提交一个 GPU 实例")
	check(lighting.get_children().size() == 1 and lighting.get_child(0) is MultiMeshInstance3D,
		"绘制层只有 MultiMesh，没有阻挡卡牌输入的碰撞或 UI")
	check(lighting._instances.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"接触阴影不再次投射影子")
	check(board.cards[0].card_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"卡牌实体不再向桌面投射粗糙的层层硬阴影")
	var mesh := lighting._multimesh
	lighting._process(0.0)
	check(lighting._multimesh == mesh, "静止帧复用网格，不重建绘制节点")
	scene.free()
	finish()
