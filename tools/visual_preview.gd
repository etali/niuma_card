# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 使用正式卡牌、材质和动效生成卡面预览，不修改玩家存档。
## Godot -s tools/visual_preview.gd -- --render <绝对路径png>
const SAMPLE := ["cash", "user", "baoyue", "ditui", "heigongguan", "yinqing996", "shangshi"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	Palette.restore_defaults()
	var args := OS.get_cmdline_user_args()
	var all_cards := args.has("--all")
	var ids: Array = CardDB.all_cards().keys() if all_cards else Array(SAMPLE)
	root.size = Vector2i(2400, 2200) if all_cards else Vector2i(2400, 1200)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	var world := Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = 13.0 if all_cards else 6.5
	camera.position = Vector3(0, 12, 0)
	camera.rotation_degrees.x = -90
	world.add_child(camera)
	var env := WorldEnvironment.new()
	var config := Environment.new()
	config.background_mode = Environment.BG_COLOR
	config.background_color = Palette.get_color("world", "table_felt")
	env.environment = config
	world.add_child(env)
	var index := 0
	for id in ids:
		var card := CardEntity.new()
		card.setup(99000 + index, id)
		card.freeze = true
		world.add_child(card)
		card.position = Vector3((index % 8 - 3.5) * 1.72, 0.05, (index / 8 - 1.5) * 2.3) if all_cards else Vector3((index - 3) * 1.72, 0.05, -0.8)
		var caption := Label3D.new()
		caption.text = "" if all_cards else _caption(id)
		caption.font = Fonts.zh()
		caption.font_size = 48
		caption.pixel_size = 0.003
		caption.outline_size = 0
		caption.modulate = Palette.semantic("surface")
		caption.rotation_degrees.x = -90
		caption.position = Vector3(card.position.x, 0.04, 0.65)
		world.add_child(caption)
		index += 1
	var heading := Label3D.new()
	heading.text = "牛马牌 · 荒诞经营桌游"
	heading.font = Fonts.zh_bold()
	heading.font_size = 64
	heading.pixel_size = 0.006
	heading.modulate = Palette.semantic("surface")
	heading.outline_size = 0
	heading.rotation_degrees.x = -90
	heading.position = Vector3(0, 0.04, -5.5 if all_cards else -2.45)
	world.add_child(heading)
	var note := Label3D.new()
	note.text = "配方在左，结果在右。用户留下来，资金会花掉。"
	note.font = Fonts.zh()
	note.font_size = 48
	note.pixel_size = 0.004
	note.modulate = Palette.semantic("surface")
	note.outline_size = 0
	note.rotation_degrees.x = -90
	note.position = Vector3(0, 0.04, 5.5 if all_cards else 2.1)
	world.add_child(note)
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	if args.size() >= 2 and args[0] == "--render":
		check(root.get_texture().get_image().save_png(args[1]) == OK, "卡面预览已保存")
	world.queue_free()
	await process_frame
	finish()

func _caption(id: String) -> String:
	match id:
		"cash": return "购买 / 发动成本"
		"user": return "配齐后留在组合"
		"baoyue": return "钱包绕不开续费"
		"ditui": return "流量密码是鸡蛋"
		"heigongguan": return "把墨水灌进喇叭"
		"yinqing996": return "轮子转，假期不转"
		"shangshi": return "上市敲钟，响彻全场"
	return ""
