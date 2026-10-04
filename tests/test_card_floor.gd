# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 散卡先自然落桌，再让真实收拢现金摞从侧面覆盖：不能被夹到托盘下面。
## 可选 GPU 截图：Godot -s tests/test_card_floor.gd -- --render <输出png>
const TableScene = preload("res://scenes/table_scene.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	CardDB.ensure_loaded()
	var world := Node3D.new()
	root.add_child(world)
	var table := TableScene.new(world,true)
	table._setup_environment()
	table._setup_table()
	var board := table.create_board()
	board.set_process(false)
	var clear := _card(world,board,96000,"zuokong",Vector3(-3,Board.DRAG_HEIGHT,3))
	var covered := _card(world,board,96001,"zuokong",Vector3(1,Board.DRAG_HEIGHT,3))
	for frame in 150: await physics_frame
	for card in [clear,covered]:
		check(card.position.y >= 0.0 and card._plate.global_position.y > 0.005,
			"散卡%d自然落桌后卡身中心及底板高于托盘" % card.uid)
	var settled := covered.global_position
	var members: Array = []
	for i in 8:
		var cash := _card(world,board,96100+i,"cash",Vector3(4.5,0.05+Board.COMPACT_GAP.y*i,3.2+Board.COMPACT_GAP.z*i))
		cash.freeze = true
		members.append(cash)
	var pile := board.make_group(members,true)
	board.groups.append(pile)
	board._layout_group(pile,Vector3(1.5,0.05,3.2))
	var minimum_y := covered.position.y
	var minimum_plate := covered._plate.global_position.y
	var last_min := INF
	var last_max := -INF
	for frame in 180:
		await physics_frame
		minimum_y = minf(minimum_y,covered.position.y)
		minimum_plate = minf(minimum_plate,covered._plate.global_position.y)
		if frame >= 120:
			last_min = minf(last_min,covered.position.y)
			last_max = maxf(last_max,covered.position.y)
	check(minimum_y >= 0.0,"冻结现金摞从侧面重叠后，散卡全过程不被压入桌下")
	check(minimum_plate > 0.005,"重叠全过程底板始终在托盘之上，不出现只剩文字图标的空壳")
	check(last_max-last_min < 0.001 and covered.linear_velocity.length() < 0.001,
		"重叠后高度和速度稳定，不在桌面与冻结摞之间抖动")
	check(Vector2(covered.position.x-settled.x,covered.position.z-settled.z).length() < 0.03,
		"散卡保持原水平位置，不靠弹出或移走规避遮挡")
	# 现金摞覆盖右侧，左侧露出的卡面仍须被真实物理射线选中。
	var exposed := settled + Vector3(-0.4,0,0)
	var ray := PhysicsRayQueryParameters3D.create(Vector3(exposed.x,2,exposed.z),Vector3(exposed.x,-0.2,exposed.z))
	var hit := world.get_world_3d().direct_space_state.intersect_ray(ray)
	check(hit.get("collider") == covered,"原位置露出的卡面仍可通过碰撞射线拾取")
	check(clear.position.y >= 0.0 and clear._plate.global_position.y > 0.005,
		"无重叠对照卡持续保持完整可见的落桌高度")
	print("CARD_FLOOR y=%.6f plate=%.6f icon=%.6f text=%.6f min_y=%.6f range=%.6f" % [
		covered.position.y,covered._plate.global_position.y,covered._icon.global_position.y,
		covered.label.global_position.y,minimum_y,last_max-last_min])
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2 and args[0] == "--render":
		root.size = Vector2i(1280,720)
		table.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		table.camera.size = 4.5
		table.camera.position = Vector3(0,10,3)
		table.camera.rotation_degrees = Vector3(-90,0,0)
		table.camera.current = true
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(args[1]) == OK,"保存真实牌桌物理落定截图")
	world.queue_free()
	await process_frame
	finish()

func _card(world: Node3D,board: Board,uid: int,id: String,at: Vector3) -> CardEntity:
	var card := CardEntity.new()
	card.setup(uid,id)
	card.position = at
	world.add_child(card)
	board.register_card(card)
	return card
