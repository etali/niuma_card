# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## The cards exchange two legal stack heights using the real layout tween.
## Compare frozen transit frames, including their text, against a render of
## the front card alone. Node visibility cannot detect a depth-test failure.
var viewport := SubViewport.new()
var camera := Camera3D.new()
var board := OffWorkBoard.new()
var config := OffWorkConfig.new()
var work: OffWorkCard
var worker: OffWorkCard

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		check(false, "文字遮挡测试需要实际图形渲染器")
		finish()
		return
	OffWorkCardDB.configure(config)
	viewport.size = Vector2i(512, 512)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	viewport.add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.4
	camera.current = true
	viewport.add_child(board)
	board.setup(camera, true)
	board.set_process(false)
	work = _card(1, "work")
	worker = _card(2, "employee")
	for angle in [80.0, 45.0]:
		camera.position = Vector3(0, sin(deg_to_rad(angle)), cos(deg_to_rad(angle))) * 7
		camera.look_at(Vector3.ZERO, Vector3.UP)
		await _crossing(angle)
		await _covered_stamp(angle)
	await _flying_income_title()
	viewport.free()
	finish()

func _card(uid: int, kind: String) -> OffWorkCard:
	var card := OffWorkCard.new()
	board.add_child(card)
	card.configure({"id": uid, "type": kind, "owner": 0, "group": 1,
		"status": "ready", "progress": 0.0}, config.cards[kind])
	card.freeze = true
	card.collision_layer = 0
	card.collision_mask = 0
	card.set_process(false)
	return card

func _crossing(angle: float) -> void:
	work.position = Vector3(-0.1, 0.05, 0.03)
	worker.position = Vector3(0.1, 0.05, 0.0) + Vector3.UP * Board.COMPACT_GAP.y
	board._move_to(work, Vector3(0.08, 0.05 + Board.COMPACT_GAP.y, 0))
	board._move_to(worker, Vector3(-0.08, 0.05, 0))
	var a: Tween = board._move_tw[work].tw
	var b: Tween = board._move_tw[worker].tw
	a.pause()
	b.pause()
	# Sample on both sides of the crossing, before labels have a full card
	# thickness of separation. Advance the tweens explicitly for reproducibility.
	var checked := 0
	for _step in 180:
		a.custom_step(0.001)
		b.custom_step(0.001)
		var gap := work.position.y - worker.position.y
		if checked == 0 and gap > -0.006 and gap < -0.001:
			await _compare(worker, work, true, "员工从工作牌上方经过 %d°" % angle)
			checked += 1
		elif checked == 1 and gap > 0.001 and gap < 0.006:
			await _compare(work, worker, true, "工作牌从员工上方经过 %d°" % angle)
			checked += 1
			break
	check(checked == 2, "取到前后两张牌交换层高的两帧")
	a.kill()
	b.kill()

func _covered_stamp(angle: float) -> void:
	work.position = Vector3(0, 0.20, 0)
	worker.position = work.position - Vector3.UP * Board.COMPACT_GAP.y
	worker.flash_stamp("到账", 3.0)
	worker._stamp_tween.pause()
	worker._stamp_tween.custom_step(0.04)
	await _compare(work, worker, false, "盖章过程中上层工作牌遮住下方印泥 %d°" % angle)
	worker._stamp_tween.custom_step(0.46)
	await _compare(work, worker, false, "上层牌盖住下层结算章 %d°" % angle)
	worker._stamp_tween.kill()
	worker._void_stamp.hide()

func _picture(region: Rect2i) -> PackedByteArray:
	await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image().get_region(region).get_data()

func _compare(front: OffWorkCard, behind: OffWorkCard, title_band: bool, caption: String) -> void:
	var near_z := -0.72 if title_band else -0.12
	var far_z := -0.48 if title_band else 0.26
	var face := front._visual.global_transform
	var start := camera.unproject_position(face * Vector3(-0.43, CardEntity.Y_PLATE, near_z))
	var end := camera.unproject_position(face * Vector3(0.43, CardEntity.Y_PLATE, far_z))
	var region := Rect2i(Rect2(start, end - start).abs())
	var both := await _picture(region)
	behind.hide()
	var expected := await _picture(region)
	check(both == expected, caption + "：与上层牌单独渲染逐像素一致")
	if title_band:
		front.label.hide()
		var unprinted := await _picture(region)
		check(unprinted != expected, "上层牌的标题清晰可见，叠牌可以单独收起卡名")
		front.label.show()
	else:
		front.hide()
		behind.show()
		var stamped := await _picture(region)
		behind._void_stamp.hide()
		var unstamped := await _picture(region)
		check(stamped != unstamped, "露出的下层牌仍显示结算章")
		behind._void_stamp.show()
		front.show()
	behind.show()

func _flying_income_title() -> void:
	work.hide()
	worker.hide()
	var money := _card(3, "money")
	money.position = Vector3(0, 0.5, 0)
	var a := camera.unproject_position(money.to_global(Vector3(-0.48, CardEntity.Y_PLATE, -0.72)))
	var b := camera.unproject_position(money.to_global(Vector3(0.48, CardEntity.Y_PLATE, -0.48)))
	var region := Rect2i(Rect2(a, b - a).abs())
	var settled := await _picture(region)
	money.label.hide()
	var blank := await _picture(region)
	money.label.show()
	var note := board._make_cash_note(money)
	note.position = money.position
	board._prepare_cash_opacity(money._visual)
	board._set_cash_opacity(money._visual, 1.0)
	check(settled != blank and await _picture(region) == settled, "飞行现金的完整牌名已印入半透明材质")
	money.hide()
	board._set_cash_opacity(note, 1.0)
	check(await _picture(region) == settled, "现金流里的装饰纸币同样带有完整牌名")
