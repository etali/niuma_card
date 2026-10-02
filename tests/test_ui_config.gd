# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Config = preload("res://engine/ui_config.gd")
const Drawer = preload("res://scenes/drawer_window.gd")
const Presentation = preload("res://scenes/drawer_presentation.gd")
const ALTERNATE := "res://tests/fixtures/ui_alternate.json"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== UI启动配置 ===")
	check(FileAccess.file_exists(Config.PATH), "发行资源包含独立UI配置")
	var defaults := Config.read_defaults()
	check(defaults["window_fraction"] == 0.75, "窗口默认75%来自配置")
	check(defaults["perspective_angle"] == 80.0, "透视默认80度来自配置")
	check(defaults["icon_scale"] == 0.75, "入口默认75%来自同一配置")

	# 换文件即换启动值：验证窗口和显示层都读取配置，没有各写一个固定默认数。
	for config in [[Config.PATH, 0.75, 80.0, 0.75, Vector2i(1485, 900)], [ALTERNATE, 0.85, 55.0, 1.25, Vector2i(1683, 1020)]]:
		var drawer := Drawer.new(config[0])
		root.add_child(drawer)
		drawer.setup(false, Rect2i(0, 0, 2000, 1200))
		check(drawer.get_size_ratio() == config[1], "%s窗口构造读取该文件比例" % config[0])
		check(drawer.get_expanded_size() == config[4],
			"配置比例决定窗口高度，横向空白按1.65上限裁剪")
		check(drawer.get_icon_scale() == config[3], "配置入口大小实际生效")
		var presentation := Presentation.new(config[0])
		check(presentation.perspective_angle == config[2], "显示层构造读取该文件角度")
		presentation.free()
		drawer.free()

	var malformed := Config.validated_defaults({"window_fraction": "85%", "perspective_angle": true, "icon_scale": INF})
	check(malformed == Config.FALLBACK, "无效类型和非有限值回退到安全默认")
	var excessive := Config.validated_defaults({"window_fraction": 4.0, "perspective_angle": 120.0, "icon_scale": -1.0})
	check(excessive["window_fraction"] == 1.0 and excessive["perspective_angle"] == 80.0 and excessive["icon_scale"] == 0.5,
		"越界配置按各参数合法范围限制")
	check(Config.read_defaults("res://tests/fixtures/missing_ui_defaults.json") == Config.FALLBACK, "缺文件时仍能用安全默认启动")

	root.size = Vector2i(1600, 1000)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	await create_timer(0.5).timeout
	check(main.drawer_window.get_size_ratio() == defaults["window_fraction"], "真实场景没有覆写配置窗口默认值")
	check(absf(main.board.camera.rotation_degrees.x + float(defaults["perspective_angle"])) < 0.01,
		"真实场景以配置角度渲染")
	main.drawer_presentation._open_utility(3)
	var slider: HSlider = main.drawer_presentation._utility_body.find_child("PerspectiveAngle", true, false)
	check(slider != null and slider.value == defaults["perspective_angle"], "UI滑块与配置初始角度一致")
	main.queue_free()
	await process_frame
	finish()
