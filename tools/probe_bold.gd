# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree
## 量不同 embolden 下卡名在屏上的墨占比，找出真正「看着粗」的档位
## 用法：Godot --rendering-driver opengl3 -s tools/probe_bold.gd -- <out.png> <raster> <e1,e2,...> [卡 id]
##
## 判据用墨占比而不是「有没有加粗」：和图标同理，alpha 管浓淡、占比才管粗细。
func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://bold.png"
	# 保留这个参数只为命令行兼容：光栅字号在 _text_scale 里被除掉了，改它不影响上屏粗细
	var raster: int = int(args[1]) if args.size() > 1 else 28
	var list: Array = []
	if args.size() > 2:
		for s in str(args[2]).split(","):
			list.append(float(s))
	else:
		list = [0.0, 0.45, 0.9, 1.4, 2.0]
	# 默认用 6 字最密的「自动续费矩阵」：字数最多、笔画最挤，糊不糊先看它
	var card_id: String = args[3] if args.size() > 3 else "xufei"

	var cam := Camera3D.new()
	cam.position = Vector3(0, 16, 5.5)
	cam.rotation_degrees = Vector3(-71, 0, 0)
	cam.fov = 50
	root.add_child(cam)

	# 同一张卡只换 embolden，横排开
	for i in list.size():
		var fv := FontVariation.new()
		fv.base_font = Fonts.zh()
		fv.variation_embolden = float(list[i])
		Fonts._bold = fv
		var e := CardEntity.new()
		e.setup(8000 + i, card_id)
		e.position = Vector3((i - (list.size() - 1) / 2.0) * 1.45, 0, 0)
		root.add_child(e)

	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	print("saved=", out, " err=", img.save_png(out), " raster=", raster, " list=", list)
	quit(0)
