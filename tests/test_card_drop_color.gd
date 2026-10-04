# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 单卡落桌后仍保持纸色；可选 --render <目录> 用实际 GPU 像素比较提放前后。
const TableScene = preload("res://scenes/table_scene.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var render := args.size() >= 2 and args[0] == "--render"
	if render:
		root.size = Vector2i(1000,700)
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		root.content_scale_size = Vector2i.ZERO
		DirAccess.make_dir_recursive_absolute(args[1])
	var world := Node3D.new()
	root.add_child(world)
	var table := TableScene.new(world,true)
	table._setup_environment()
	table._setup_table()
	var board := table.create_board()
	board.set_process(false)
	table.camera.position = Vector3(0,10,3)
	table.camera.rotation_degrees = Vector3(-90,0,0)
	table.camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	table.camera.size = 3.2
	var control: CardEntity = table.spawn_card(board,{"uid":96200,"def_id":"baoyue"},Vector3(-1,0.05,3),true)
	var card: CardEntity = table.spawn_card(board,{"uid":96201,"def_id":"baoyue"},Vector3(1,0.05,3),true)
	control.freeze = true
	card.freeze = true
	var lighting: TableLighting = world.get_node("TableContactShadows")
	var before: Image
	if render:
		before = await _capture()
		check(before.save_png(args[1].path_join("before.png")) == OK,"保存拖放前纸色截图")
	for cycle in 3:
		board._on_card_clicked(card)
		card.position.y = Board.DRAG_HEIGHT
		await create_timer(0.16).timeout
		check(card.dragging and card.freeze,"第%d次提起走真实拖拽路径" % (cycle+1))
		board._end_drag()
		for frame in 120: await physics_frame
		lighting._process(0.0)
		check(not card.freeze and not card.dragging and card.linear_velocity.length() < 0.001,
			"第%d次放下恢复物理并稳定落桌" % (cycle+1))
		# headless 的 dummy renderer 不保留 MultiMesh 变换，读取实际提交的实例数据。
		var shadow: Vector3 = lighting._last_data[1]["center"]
		check(shadow.y > 0.0 and shadow.y < card._plate.global_position.y,
			"第%d次落桌后软阴影留在托盘之上、纸面之下，不给卡牌蒙灰" % (cycle+1))
		var material := card._plate.material_override as ShaderMaterial
		check(material.get_shader_parameter("tint") == Vector3.ONE
				and is_zero_approx(float(material.get_shader_parameter("handling_light"))),
			"第%d次落桌清除拖拽光照且保持原始纸色参数" % (cycle+1))
		if render:
			var after := await _capture()
			var sample := table.camera.unproject_position(card._plate.to_global(Vector3(-0.45,-0.10,0)))
			var delta := _pixel_delta(_sample(before,sample),_sample(after,sample))
			print("DROP_COLOR cycle=%d y=%.6f plate=%.6f shadow=%.6f pixel_delta=%.6f" % [
				cycle+1,card.position.y,card._plate.global_position.y,shadow.y,delta])
			check(delta < 2.0/255.0,"第%d次落桌的实际纸色像素与拖放前一致" % (cycle+1))
			if cycle == 2:
				check(after.save_png(args[1].path_join("after.png")) == OK,"保存反复拖放后纸色截图")
				# 还须确实保留桌面软影；把阴影降到透明托盘下不能让它消失。
				lighting.hide()
				var hidden := await _capture()
				var shadow_sample := table.camera.unproject_position(card.global_position + Vector3(0,0,0.9))
				check(_pixel_delta(_sample(after,shadow_sample),_sample(hidden,shadow_sample)) > 2.0/255.0,
					"降低阴影平面后，卡牌外侧桌面仍保留可见软影")
	world.queue_free()
	await process_frame
	finish()

func _capture() -> Image:
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _sample(image: Image,at: Vector2) -> Color:
	var sum := Color(0,0,0,0)
	for x in range(-2,3):
		for y in range(-2,3):
			sum += image.get_pixel(roundi(at.x)+x,roundi(at.y)+y)
	return sum/25.0

func _pixel_delta(a: Color,b: Color) -> float:
	return maxf(absf(a.r-b.r),maxf(absf(a.g-b.g),absf(a.b-b.b)))
