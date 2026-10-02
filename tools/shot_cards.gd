# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree
## 拍指定卡牌，用来像素级验收卡面文字/图标
##
## 用法：Godot --rendering-driver opengl3 -s tools/shot_cards.gd -- <输出png> <near|game> <def_id...>
##   near  正俯拍贴近，墨团上屏约 150px，够量清笔画边界
##   game  复刻 main.gd 的游戏相机（y=16 / -71° / fov 50），
##         卡上屏尺寸与实际开局一致 —— 货架是随机的，按 id 指定才能前后对比同一张卡
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://cards.png"
	var mode: String = args[1] if args.size() > 1 else "near"
	var ids: Array = args.slice(2)
	if ids.is_empty():
		ids = ["dujiaoshou", "yunketang", "dashuaimai"]

	var n := ids.size()
	var cam := Camera3D.new()
	var gap := 1.45
	if mode == "game":
		# 与 main.gd 的相机一致，且把卡摆在原点附近（货架所在的一带）
		cam.position = Vector3(0, 16, 5.5)
		cam.rotation_degrees = Vector3(-71, 0, 0)
	else:
		cam.position = Vector3(0, 1.15 * maxf(n, 1), 0)
		cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.fov = 50
	root.add_child(cam)

	for i in n:
		var e := CardEntity.new()
		e.setup(9000 + i, str(ids[i]))
		e.position = Vector3((i - (n - 1) / 2.0) * gap, 0, 0)
		root.add_child(e)

	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	print("saved=", out, " err=", img.save_png(out), " size=", img.get_size())
	quit(0)
