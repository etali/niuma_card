# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Config = preload("res://engine/ui_config.gd")
const Drawer = preload("res://scenes/drawer_window.gd")
const Presentation = preload("res://scenes/drawer_presentation.gd")
const PreviewCard = preload("res://scenes/preview_card.gd")
const ALTERNATE := "res://tests/fixtures/ui_alternate.json"
const SPEED_ALTERNATE := "res://tests/fixtures/ui_speed_alternate.json"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== UI启动配置 ===")
	check(FileAccess.file_exists(Config.PATH), "发行资源包含独立UI配置")
	var defaults := Config.read_defaults()
	check(defaults["window_fraction"] == 0.98, "窗口默认98%来自配置")
	check(defaults["perspective_angle"] == 80.0, "透视默认80度来自配置")
	check(defaults["icon_scale"] == 0.75, "入口默认75%来自同一配置")
	check(defaults["hover_animation_speed"] == 2.0, "悬停插画默认二倍速来自同一配置")
	_check_speed_config()

	# 换文件即换启动值：验证窗口和显示层都读取配置，没有各写一个固定默认数。
	for config in [[Config.PATH, 0.98, 80.0, 0.75, Vector2i(1940, 1176)], [ALTERNATE, 0.85, 55.0, 1.25, Vector2i(1683, 1020)]]:
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
	await _check_speed_controls(main)
	_check_shared_ui_actions(main)
	main.queue_free()
	await process_frame
	finish()

func _check_speed_config() -> void:
	var control := Config.hover_speed_control()
	check(control["min"] == 0.5 and control["max"] == 2.0 and control["step"] == 0.1,
		"插画速度范围和步进从UI配置读取")
	for invalid in ["fast", true, NAN, INF, -INF]:
		check(Config.validated_defaults({"hover_animation_speed": invalid})["hover_animation_speed"] == 2.0,
			"非法动画速度 %s 不污染有效配置" % str(invalid))
	check(Config.validated_defaults({"hover_animation_speed": 0.1})["hover_animation_speed"] == 0.5
		and Config.validated_defaults({"hover_animation_speed": 8.0})["hover_animation_speed"] == 2.0,
		"配置速度受滑块范围约束")
	Config.set_hover_animation_speed(1.5)
	for invalid in [NAN, INF, -INF]:
		Config.set_hover_animation_speed(invalid)
		var safe := Config.get_hover_animation_speed()
		check(is_finite(safe) and safe >= 0.5 and safe <= 2.0,
			"实时接口拒绝非有限速度 %s" % str(invalid))
	Config.reset_cache()
	Config._source = SPEED_ALTERNATE
	control = Config.hover_speed_control()
	check(control["min"] == 0.25 and control["max"] == 3.0 and control["step"] == 0.25,
		"外置UI文件可以同时调整动画速度范围和步进")
	check(Config.read_defaults()["hover_animation_speed"] == 2.25
		and Config.get_hover_animation_speed() == 2.25,
		"外置动画速度默认值进入真实运行状态")
	Config.set_hover_animation_speed(9.0)
	check(Config.get_hover_animation_speed() == 3.0, "实时速度跟随外置配置范围截断")
	Config.restore_preferences()
	check(Config.get_hover_animation_speed() == 2.25, "还原默认恢复外置UI指定的速度")
	var malformed_path := "user://invalid_speed_controls.json"
	for invalid in [false, {"min": 0.0, "max": INF, "step": "small"},
			{"min": 3.0, "max": 1.0}, {"step": 10.0}]:
		Config._cache[malformed_path] = {"controls": {"hover_animation_speed": invalid}}
		control = Config.hover_speed_control(malformed_path)
		check(control["min"] == 0.5 and control["max"] == 2.0 and control["step"] == 0.1,
			"无效速度控件配置 %s 回退到可用范围" % str(invalid))
	Config.reset_cache()
	check(Config.get_hover_animation_speed() == 2.0, "重新载入内置配置恢复二倍速并清除旧的实时速度缓存")

func _check_speed_controls(main: Node) -> void:
	var page: Node = main.drawer_presentation
	var speed: HSlider = page._utility_body.find_child("HoverAnimationSpeed", true, false)
	var value: Label = page._utility_body.find_child("HoverAnimationSpeedValue", true, false)
	if not need(speed != null and value != null, "选项→UI包含插画速度滑块和倍速读数"):
		return
	check(speed.min_value == 0.5 and speed.max_value == 2.0 and is_equal_approx(speed.step, 0.1)
		and speed.value == 2.0, "速度滑块使用配置范围、步进和默认二倍速")
	# 以下比较明确从一倍速起步，不把产品默认速度当作测试前提。
	speed.value = 1.0
	var engine_speed := Engine.time_scale
	var card := CardEntity.new()
	card.freeze = true
	root.add_child(card)
	card.setup(998800, "user")
	card.set_hover_visual(true, false)
	card.set_process(false)
	var deadline := Time.get_ticks_msec() + 10000
	while CardArt.hover_frames("user").is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	card._process(0)
	if not need(not card._hover_frames.is_empty(), "实时速度回归加载真实用户牌动画"):
		card.queue_free()
		return
	card._process(0.65)
	var elapsed: float = card._hover_elapsed
	var texture: Texture2D = card._icon.texture
	var frame: int = card._hover_frame
	speed.value = 2.0
	check(Config.get_hover_animation_speed() == 2.0 and value.text.contains("2.0"),
		"拖动滑块立即更新运行速度和倍速读数，无需保存")
	check(card._hover_elapsed == elapsed and card._hover_frame == frame and card._icon.texture == texture,
		"切换速度保持当前进度和画面，不重启动画")
	card._process(0.1)
	check(is_equal_approx(card._hover_elapsed, elapsed + 0.2)
		and card._hover_frame == 8 and card._icon.texture == card._hover_frames[8],
		"正在悬停的插画下一次更新即按二倍速度推进到正确帧")
	elapsed = card._hover_elapsed
	speed.value = 0.5
	card._process(0.2)
	check(is_equal_approx(card._hover_elapsed, elapsed + 0.1) and card._hover_frame == 9,
		"同一次悬停改为半速后立即减速，保持动作连续")
	check(not FileAccess.file_exists(Config.USER_PATH), "实时调速不会提前写入玩家保存文件")
	page.close_panels()
	page._open_utility(3)
	speed = page._utility_body.find_child("HoverAnimationSpeed", true, false)
	check(speed.value == 0.5 and Config.get_hover_animation_speed() == 0.5,
		"关闭再打开UI保留尚未保存的实时速度")
	var another_page := Presentation.new()
	check(Config.get_hover_animation_speed() == 0.5, "新建显示层不把尚未保存的实时速度重置")
	another_page.free()
	card.hover_animation_paused = true
	elapsed = card._hover_elapsed
	speed.value = 2.0
	card._process(0.2)
	check(card._hover_elapsed == elapsed, "暂停时调速不会偷偷推进插画")
	card.hover_animation_paused = false
	card._process(0.1)
	check(is_equal_approx(card._hover_elapsed, elapsed + 0.2), "继续播放立即采用暂停期间设定的新速度")
	var preview := PreviewCard.new()
	preview.freeze = true
	root.add_child(preview)
	preview.setup(998801, "user")
	preview.set_hover_visual(true, false)
	preview.set_process(false)
	preview._process(0)
	preview._process(0.4)
	check(is_equal_approx(preview._hover_elapsed, 0.4), "独立预览正常速度不叠乘游戏中的二倍速")
	preview.hover_animation_speed = 0.25
	elapsed = preview._hover_elapsed
	preview._process(0.4)
	check(is_equal_approx(preview._hover_elapsed, elapsed + 0.1), "独立预览四分之一慢放保持自身倍率")
	check(Engine.time_scale == engine_speed, "插画速度设置不修改全局时间或撕牌速度")
	preview.queue_free()
	card.queue_free()
	await process_frame

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
	page.set_hover_animation_speed(1.7)
	main.drawer_window.set_size_fraction(0.85)
	main.drawer_window.set_icon_scale(1.25)
	Palette.set_number("pattern", "density", 2.0)
	Palette.set_color("pattern", "ink", Color("#78604B"))
	page._ui_footer.get_node("SaveUISettings").pressed.emit()
	var saved := Config.read_defaults()
	check(saved["perspective_angle"] == 55.0 and saved["table_zoom"] == 1.5
		and saved["window_fraction"] == 0.85 and saved["icon_scale"] == 1.25
		and is_equal_approx(saved["hover_animation_speed"], 1.7),
		"统一保存覆盖透视、缩放、窗口比例、入口大小及插画速度")
	Config.reset_cache()
	check(is_equal_approx(Config.get_hover_animation_speed(), 1.7), "重新加载时读取已保存的插画速度")
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
		and main.drawer_window.get_icon_scale() == defaults["icon_scale"]
		and Config.get_hover_animation_speed() == 2.0
		and page._utility_body.find_child("HoverAnimationSpeed", true, false).value == 2.0,
		"统一还原即时恢复所有显示参数")
	check(Palette.get_number("pattern", "density") == 1.0
		and page._utility_body.find_child("PatternDensity", true, false).value == 1.0,
		"统一还原同时恢复纹理和配色控件")
