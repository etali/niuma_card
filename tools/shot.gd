# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 开窗跑一遍 main.tscn 并抓帧，用来肉眼验收素材接入效果
## 用法：Godot --rendering-driver opengl3 -s tools/shot.gd -- <输出png> [等待帧数]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://shot.png"
	var wait: int = int(args[1]) if args.size() > 1 else 90

	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in wait:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var err := img.save_png(out)
	print("saved=", out, " err=", err, " size=", img.get_size())
	quit(0)
