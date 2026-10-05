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
	_check_pattern_controls(main)
	_check_shared_ui_actions(main)
	main.queue_free()
	await process_frame
	finish()

func _check_pattern_controls(main: Node) -> void:
	var page: Node = main.drawer_presentation._utility_body
	var density: SpinBox = page.find_child("PatternDensity", true, false)
	var spacing: SpinBox = page.find_child("PatternSpacing", true, false)
	check(density != null and spacing != null, "UI页包含配色中的纹理密度和间隔参数")
	var popup: PopupMenu = main.drawer_presentation._menu.get_popup()
	var standalone := false
	for index in popup.item_count:
		standalone = standalone or popup.get_item_text(index) == "配色"
	check(not standalone, "配色不再占用独立选项入口")
	if density == null or spacing == null:
		return
	var surface: MeshInstance3D = main.find_child("PaperDesktop", true, false)
	var material: ShaderMaterial = surface.material_override
	density.value = 1.75
	spacing.value = 0.35
	check(is_equal_approx(float(material.get_shader_parameter("pattern_density")), 1.75), "调整密度即时更新桌面材质")
	check(is_equal_approx(float(material.get_shader_parameter("pattern_spacing")), 0.35), "调整間隔即时更新桌面材质")
	var panel: PalettePanel = main.drawer_presentation._palette
	var ink := Color("#735A42")
	for picker in panel._pickers:
		if picker["section"] == "pattern" and picker["key"] == "ink":
			picker["btn"].color_changed.emit(ink)
	check((material.get_shader_parameter("doodle_ink") as Color).is_equal_approx(ink), "纹理色通过原配色取色器即时生效")
	check(Palette.save(), "纹理参数与配色共用保存入口")
	Palette._loaded = false
	check(is_equal_approx(Palette.get_number("pattern", "density"), 1.75)
		and is_equal_approx(Palette.get_number("pattern", "spacing"), 0.35)
		and Palette.get_color("pattern", "ink").is_equal_approx(ink), "重新读取配色保留纹理数值和颜色")
	Palette.set_number("pattern", "density", -1)
	Palette.set_number("pattern", "spacing", 8)
	check(Palette.get_number("pattern", "density") == 0.25 and Palette.get_number("pattern", "spacing") == 1.0, "越界纹理参数限制在可调范围")
	panel._on_reset()
	check(density.value == 1.0 and spacing.value == 0.0, "还原默认同步纹理控件")
	check(float(material.get_shader_parameter("pattern_density")) == 1.0
		and float(material.get_shader_parameter("pattern_spacing")) == 0.0, "还原默认同步桌面纹理")
	main.drawer_presentation.close_panels()
	main.drawer_presentation._open_utility(3)
	check(main.drawer_presentation._utility_body.find_child("PatternDensity", true, false) != null, "反复开关UI后配色控件仍存在")

func _check_shared_ui_actions(main: Node) -> void:
	var page: Node = main.drawer_presentation
	check(not page._palette._footer.visible and page._ui_footer.visible,
		"保存和还原位于UI外层，不再位于配色内部")
	check(page._utility_body.find_child("ResetTableView", true, false) == null,
		"UI没有仅还原镜头的独立按钮")
	page.set_perspective_angle(55)
	page.set_table_zoom(1.5)
	main.drawer_window.set_size_fraction(0.85)
	main.drawer_window.set_icon_scale(1.25)
	Palette.set_number("pattern", "density", 2.0)
	Palette.set_color("pattern", "ink", Color("#78604B"))
	page._ui_footer.get_node("SaveUISettings").pressed.emit()
	var saved := Config.read_defaults()
	check(saved["perspective_angle"] == 55.0 and saved["table_zoom"] == 1.5
		and saved["window_fraction"] == 0.85 and saved["icon_scale"] == 1.25,
		"统一保存覆盖透视、缩放、窗口比例及入口大小")
	var next_window := Drawer.new()
	var next_page := Presentation.new()
	check(next_window.get_size_ratio() == 0.85 and next_window.get_icon_scale() == 1.25
		and next_page.perspective_angle == 55.0 and next_page.camera_view.zoom == 1.5,
		"重新创建窗口和显示层读取全部已保存UI偏好")
	next_window.free()
	next_page.free()
	Palette._loaded = false
	check(Palette.get_number("pattern", "density") == 2.0
		and Palette.get_color("pattern", "ink").is_equal_approx(Color("#78604B")),
		"统一保存同时持久化背景纹理与配色")
	page._ui_footer.get_node("ResetUISettings").pressed.emit()
	var defaults := Config.validated_defaults(Config.read_section("defaults"))
	check(not FileAccess.file_exists(Config.USER_PATH) and not FileAccess.file_exists(Palette.USER_PATH),
		"统一还原清除显示和配色的玩家覆盖")
	check(page.perspective_angle == defaults["perspective_angle"]
		and page.camera_view.zoom == defaults["table_zoom"]
		and main.drawer_window.get_size_ratio() == defaults["window_fraction"]
		and main.drawer_window.get_icon_scale() == defaults["icon_scale"],
		"统一还原即时恢复所有显示参数")
	check(Palette.get_number("pattern", "density") == 1.0
		and page._utility_body.find_child("PatternDensity", true, false).value == 1.0,
		"统一还原同时恢复纹理和配色控件")
