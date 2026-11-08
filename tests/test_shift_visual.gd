# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## Hold the real boot's window setup at the scene-loading stage. Its root
## viewport texture excludes native letterboxing, so alpha checks alone would
## miss the two opaque strips surrounding the old 64×64 startup surface.
class LoadingBoot extends "res://scenes/boot.gd":
	func _ready() -> void: pass

## Read the native compositor: inspecting either child viewport alone cannot
## detect a blank frame while the shared display changes its source texture.
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		check(false, "需要桌面渲染器")
		finish()
		return
	OS.set_environment("CARD_DRAWER_SIZE", "1280x800")
	var loading := LoadingBoot.new()
	root.add_child(loading)
	if OS.get_name() == "macOS":
		var native_size := DisplayServer.window_get_size()
		check(native_size.x <= 2 and native_size.y <= 2 and root.min_size == Vector2i.ONE,
			"资源加载期间原生窗口维持一像素，不扩大为64×64")
		check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED and root.content_scale_size == Vector2i.ZERO,
			"资源加载期间不生成16:9画面外的上下黑边")
	await RenderingServer.frame_post_draw
	var boot := root.get_texture().get_image()
	if OS.get_name() == "macOS":
		check(boot.get_used_rect().size == Vector2i.ZERO, "原生首帧完全透明")
	loading.queue_free()
	change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene"))
	while current_scene == null or not current_scene.has_method("switch_mode"):
		await process_frame
	var host := current_scene
	while not is_instance_valid(host.sign) or host.display.texture == null:
		await process_frame
	var drawer: DrawerWindow = host.tables[0].drawer_window
	drawer.pin()
	while not drawer.is_pinned() or not drawer.is_expanded() or drawer.is_transitioning() or drawer._warming:
		await process_frame
	await RenderingServer.frame_post_draw
	var on := root.get_texture().get_image()
	# A strip outside all playing areas contains the embossed pattern on the felt.
	var sample := Rect2i(1, on.get_height() / 4, 4, on.get_height() / 4)
	var background := on.get_region(sample).get_data()
	var sign_at: Vector2 = host.sign.get_global_rect().get_center()
	for mode in [1, 0]:
		host.switch_mode(mode)
		var clean := true
		var rendered := 0
		while host.switching:
			await RenderingServer.frame_post_draw
			var frame := root.get_texture().get_image()
			clean = clean and frame.get_size() == on.get_size() and frame.get_region(sample).get_data() == background
			rendered += 1
		check(clean and rendered > 3, "每帧保持桌布印花、原生窗口尺寸与不透明度（班次 %d）" % mode)
		check(host.sign.get_global_rect().get_center().distance_to(sign_at) <= 1.0, "翻牌后的招牌保持中轴位置")
	await _check_deck_ink(host)
	finish()

func _next_picture() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _check_deck_ink(host: Node) -> void:
	var game: Node3D = host.tables[host.active]
	host._suspend(host.active)
	var flight := preload("res://scenes/shift_choreography.gd").new()
	flight.capture(game)
	var original: Node3D = flight.faces.back()
	for progress in [0.92, 1.0]:
		flight.pose(progress, 0.0)
		var printed := flight.deck.front if flight.deck.visible else original
		var pose: Transform3D = printed.global_transform
		var camera: Camera3D = game.board.camera
		# Sample the interior, including the printed title, central art and pips.
		var a := camera.unproject_position(pose * Vector3(-0.48, CardEntity.Y_ICON, -0.69))
		var b := camera.unproject_position(pose * Vector3(0.48, CardEntity.Y_ICON, 0.69))
		var region := Rect2i(Rect2(a, b - a).abs())
		var stacked := await _next_picture()
		for face in flight.faces: face.hide()
		flight.deck.hide()
		var uncovered := await _next_picture()
		original.global_transform = pose
		original.show()
		var alone := await _next_picture()
		var ink := stacked.get_region(region).get_data()
		check(region.has_area() and ink == alone.get_region(region).get_data() and ink != uncovered.get_region(region).get_data(),
			"收牌进度 %.0f%% 时顶牌与单独绘制的同一牌面逐像素一致" % (progress * 100))
	flight.restore()
	flight.deck.free()
