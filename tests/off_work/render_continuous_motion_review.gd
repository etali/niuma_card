extends SceneTree
## Real OffWorkCard/Compatibility renderer capture. No drawn replacement images.
## Offline sample cadence is separate from the warmed real-time benchmark.
const IDS := ["employee", "grinder", "leader", "work", "money", "coffee", "overtime", "meeting", "outsource", "strike", "transfer", "slack"]
const OUTPUT := "res://reports/continuous-motion-frames"
const SIZE := Vector2i(1920, 1080)
const FPS := 60.0
const EXPORT_SECONDS := 3.6
const WARMUP_SECONDS := 2.0
const BENCHMARK_SECONDS := 4.0
var cards: Array[OffWorkCard] = []
var camera: Camera3D
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	OS.set_environment("WORK_UI_TEST", "1")
	OffWorkCardDB.configure(OffWorkConfig.new())
	Palette._cfg = UIConfig.read_section("palette")
	Palette._loaded = true
	root.title = "连续动画渲染检查 · 12张正式卡"
	root.transparent = false
	root.transparent_bg = false
	root.borderless = false
	root.unresizable = true
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.size = SIZE
	var stage := Node3D.new()
	root.add_child(stage)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Palette.get_color("world", "table_felt")
	stage.add_child(world)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = 5.6
	camera.position = Vector3(0, 10, 0)
	camera.rotation_degrees.x = -90
	stage.add_child(camera)
	camera.make_current()
	for index in IDS.size():
		var card := OffWorkCard.new()
		stage.add_child(card)
		card.configure({"id": index + 1, "type": IDS[index], "owner": 0, "group": -1,
			"status": "ready", "activity": "idle", "progress": 0.0}, OffWorkCardDB.get_def(IDS[index]))
		card.freeze = true
		card.draggable = false
		card.position = Vector3((index % 7 - 3) * 1.35, 0.05, (index / 7 - 0.5) * 2.25)
		card.set_hover_visual(true, false)
		card.hover_animation_paused = true
		card.set_process(false)
		cards.append(card)
	var overlay := CanvasLayer.new()
	root.add_child(overlay)
	var title := Label.new()
	title.text = "同一张 GPT 主图 · 连续动作 · 12 张正式卡面"
	title.add_theme_font_override("font", Fonts.zh())
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Palette.semantic("surface"))
	title.position = Vector2(38, 28)
	overlay.add_child(title)
	var note := Label.new()
	note.text = "动作按真实时间求值，录制按 60 Hz 采样；单步采样数不代表生成姿势数。"
	note.add_theme_font_override("font", Fonts.zh())
	note.add_theme_font_size_override("font_size", 22)
	note.add_theme_color_override("font_color", Palette.semantic("surface"))
	note.position = Vector2(38, SIZE.y - 58)
	overlay.add_child(note)
	await _draw()
	var benchmark := await _benchmark()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	_set_time(0.0)
	await _draw()
	var first := _image()
	first.save_png("res://reports/continuous-motion-start.png")
	var image_rects: Array[Rect2i] = []
	var card_records: Array[Dictionary] = []
	for card in cards:
		var rect := _icon_rect(card)
		image_rects.append(rect)
		var ink := _ink_pixels(first.get_region(rect))
		if ink < 24: failures.append(card.type + " has no visible icon ink")
		card_records.append({"card": card.type, "visible_ink_pixels": ink,
			"icon_rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
			"changed_adjacent_samples": 0, "max_adjacent_mean_rgb_delta": 0.0})
	for card in cards: card.seek_hover_animation(card.illustration_duration())
	await _draw()
	var endpoint := _image()
	endpoint.save_png("res://reports/continuous-motion-loop-end.png")
	var seam := _delta(first, endpoint, 1)
	for index in cards.size():
		var card_seam := _delta(first.get_region(image_rects[index]), endpoint.get_region(image_rects[index]), 1)
		card_records[index]["loop_endpoint"] = card_seam
		if card_seam.max_channel_delta > 2: failures.append(cards[index].type + " endpoint differs by more than two 8-bit levels")
	var count := roundi(EXPORT_SECONDS * FPS) + 1
	var previous: Image
	var peak_adjacent := 0.0
	var export_start := Time.get_ticks_usec()
	for index in count:
		_set_time(float(index) / FPS)
		await _draw()
		var image := _image()
		var error := image.save_png(OUTPUT + "/%04d.png" % index)
		if error != OK: failures.append("capture failed at " + str(index))
		if index == roundi(FPS): image.save_png("res://reports/continuous-motion-review.png")
		if previous != null:
			var comparison := _delta(previous, image, 32)
			peak_adjacent = maxf(peak_adjacent, comparison.mean_rgb_delta)
			for card_index in cards.size():
				var old_region := previous.get_region(image_rects[card_index])
				var region := image.get_region(image_rects[card_index])
				var change := _delta(old_region, region, 4)
				if change.changed_samples > 0: card_records[card_index].changed_adjacent_samples += 1
				card_records[card_index].max_adjacent_mean_rgb_delta = maxf(card_records[card_index].max_adjacent_mean_rgb_delta, change.mean_rgb_delta)
		previous = image
		if index % 60 == 0: print("CONTINUOUS_CAPTURE ", index, "/", count - 1)
	for item in card_records:
		if item.changed_adjacent_samples < count / 2: failures.append(str(item.card) + " has too many unchanged adjacent samples")
		if item.max_adjacent_mean_rgb_delta > 5.0: failures.append(str(item.card) + " large adjacent-frame change")
	var report := {"scene": "12 production OffWorkCard instances; original frames, titles, icons and shared continuous material",
		"resolution": [SIZE.x, SIZE.y], "renderer": RenderingServer.get_current_rendering_method(),
		"real_time_benchmark": benchmark,
		"offline_export": {"sample_fps": FPS, "seconds": EXPORT_SECONDS, "png_count": count,
			"wall_seconds": (Time.get_ticks_usec() - export_start) / 1000000.0,
			"note": "Explicit 1/60 s shader time samples rendered by Godot. Export readback/PNG encoding time is not real-time frame rate."},
		"loop_endpoint": seam, "max_adjacent_whole_image_mean_rgb_delta": peak_adjacent,
		"cards": card_records, "errors": failures}
	var file := FileAccess.open("res://reports/continuous-motion-validation.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("CONTINUOUS_RENDER_REVIEW ", failures.is_empty(), " fps=", benchmark.average_fps,
		" endpoint_max_delta=", seam.max_channel_delta, " png_count=", count, " errors=", failures)
	quit(0 if failures.is_empty() else 1)

func _draw() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func _set_time(seconds: float) -> void:
	for card in cards: card.seek_hover_animation(fposmod(seconds, card.illustration_duration()))

func _image() -> Image:
	var image := root.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	return image

func _icon_rect(card: OffWorkCard) -> Rect2i:
	var center := camera.unproject_position(card._icon.global_position)
	var width := card._icon.texture.get_width() * card._icon.pixel_size * float(SIZE.y) / camera.size
	return Rect2i(Vector2i(center - Vector2.ONE * width * 0.5), Vector2i.ONE * ceili(width))

func _ink_pixels(image: Image) -> int:
	var data := image.get_data()
	var count := 0
	for offset in range(0, data.size(), 4):
		if data[offset] < 100 and data[offset + 1] < 100 and data[offset + 2] < 100: count += 1
	return count

func _delta(a: Image, b: Image, pixel_stride: int) -> Dictionary:
	var left := a.get_data()
	var right := b.get_data()
	var total := 0.0
	var changed := 0
	var maximum := 0
	var samples := 0
	for index in range(0, mini(left.size(), right.size()), 4 * pixel_stride):
		var difference := 0
		for channel in 3:
			var value := absi(int(left[index + channel]) - int(right[index + channel]))
			total += value
			maximum = maxi(maximum, value)
			difference += value
		if difference > 0: changed += 1
		samples += 1
	return {"mean_rgb_delta": total / float(maxi(samples * 3, 1)), "max_channel_delta": maximum,
		"changed_samples": changed, "samples": samples, "exact_bytes_equal": left == right}

func _benchmark() -> Dictionary:
	var warmup := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - warmup) / 1000000.0 < WARMUP_SECONDS:
		_set_time((Time.get_ticks_usec() - warmup) / 1000000.0)
		await _draw()
	var intervals: Array[float] = []
	var start := Time.get_ticks_usec()
	var last := start
	while (Time.get_ticks_usec() - start) / 1000000.0 < BENCHMARK_SECONDS:
		_set_time((Time.get_ticks_usec() - start) / 1000000.0)
		await _draw()
		var now := Time.get_ticks_usec()
		intervals.append((now - last) / 1000.0)
		last = now
	var elapsed := (last - start) / 1000000.0
	intervals.sort()
	var result := {"warmup_seconds": WARMUP_SECONDS, "measurement_seconds": elapsed,
		"rendered_frames": intervals.size(), "average_fps": intervals.size() / elapsed,
		"median_frame_ms": intervals[intervals.size() / 2],
		"p95_frame_ms": intervals[mini(intervals.size() - 1, floori(intervals.size() * 0.95))],
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"readback_during_measurement": false,
		"scope": "13 animated production cards at 1920×1080 in a visible Compatibility window; machine/display-specific measurement, not a full-game benchmark"}
	print("CONTINUOUS_REALTIME_BENCHMARK ", JSON.stringify(result))
	return result
