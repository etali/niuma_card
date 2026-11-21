# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 飞行中的现金要半透明。引擎按参数组合共用着色器，最后一份材质释放时把着色器也丢掉；
## 如果每次起飞都现场复制一份牌身材质再改成透明，每一次清工作、每一次买牌都要重新编译
## 一次着色器，画面卡一两百毫秒。牌身的半透明材质必须来自特效库里常驻的那份模板，
## 新着色器必须登记进开场预热。
const Materials = preload("res://scenes/effect_materials.gd")
const Primer = preload("res://scenes/opening_materials.gd")
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"work": 20, "employee": 1}]
	config.rules.initial.money = 3
	config.rules.bot.enabled = false
	config.rules.conveyor.interval_seconds = 1000.0
	state = OffWorkState.new(config)
	state.new_game(20261121)
	OffWorkCardDB.configure(config)
	host = Node3D.new()
	root.add_child(host)
	board = OffWorkBoard.new(false)
	host.add_child(board)
	board.set_process(false)
	var camera := Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 25, 12)
	camera.look_at(Vector3.ZERO)
	board.setup(camera, true)
	board.sync_state(state)

	var note: OffWorkCard = board.by_uid[state._owner_type(0, "money")[0]]
	var bodies: Array = note._visual.get_children().filter(func(child): return child is MeshInstance3D and child.material_override is BaseMaterial3D)
	check(not bodies.is_empty(), "夹具：金钱牌的牌身是一块平涂的标准材质")
	var body: MeshInstance3D = bodies[0]
	var original: BaseMaterial3D = body.material_override
	check(OffWorkBoard._is_plain_colour(original), "牌身是不受光的纯色，可以由常驻模板代替")
	board._prepare_cash_opacity(note._visual)
	var travelling: BaseMaterial3D = body.material_override
	check(travelling != original and Materials._flat.has(false), "起飞时换上的半透明材质来自特效库的常驻模板")
	var template: BaseMaterial3D = Materials._flat[false]
	check(travelling.transparency == template.transparency and travelling.shading_mode == template.shading_mode \
		and travelling.cull_mode == template.cull_mode and travelling.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA,
		"参数组合和模板完全一样，所以共用模板那份已经编译好的着色器")
	check(Color(travelling.albedo_color, 1.0).is_equal_approx(Color(original.albedo_color, 1.0)), "颜色还是这张牌自己的颜色")
	board._set_cash_opacity(note._visual, 0.5)
	check(is_equal_approx(travelling.albedo_color.a, 0.5) and is_equal_approx(original.albedo_color.a, 1.0), "透明度只改临时的那一份，原材质不动")
	board._restore_cash_opacity(note._visual)
	check(body.material_override == original, "落地后换回原来的材质")
	# The second flight reuses the same retained template: nothing is left to compile.
	board._prepare_cash_opacity(note._visual)
	check(Materials._flat[false] == template and body.material_override != travelling, "再飞一次仍是从同一份模板复制")
	board._restore_cash_opacity(note._visual)
	# A lit or textured material is not a plain colour and keeps the old path.
	var lit := StandardMaterial3D.new()
	check(not OffWorkBoard._is_plain_colour(lit), "受光的材质不由平涂模板代替")

	var samples: Array = Primer.SAMPLES.map(func(shader): return str(shader.resource_path))
	for path in ["res://shaders/off_work_cash_face.gdshader", "res://shaders/off_work_paper_disposal.gdshader", "res://shaders/off_work_task_progress.gdshader"]:
		check(samples.has(path), "%s 在开场预热里，第一次上屏时不现编译" % path.get_file())
	check(Primer.FLAT_SIDES == [false, true], "平涂半透明材质的单面、双面两种也在开场预热里")
	host.queue_free()
	await process_frame
	finish()
