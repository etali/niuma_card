# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 用工作次数验证空闲帧预算，避免机器速度或并行测试负载造成偶发超时。
class CountingLighting extends TableLighting:
	var builds := 0
	func _build_contacts(positions: PackedVector3Array) -> Array:
		builds += 1
		return super._build_contacts(positions)

class CountingPresentation extends "res://scenes/drawer_presentation.gd":
	var layouts := 0
	func _fit_detail_content() -> void:
		layouts += 1
		super._fit_detail_content()

class DetailHost extends Node3D:
	var mobile_mode := false
	var web_mode := false
	var lbl_msg: Label
	var board: Board

class DetailBoard extends Board:
	var descriptions := 0
	func describe_def(id: String) -> String:
		descriptions += 1
		return super.describe_def(id)

class HoverBoard extends Board:
	var target: CardEntity
	var descriptions := 0
	func _pick_card(_screen_pos: Vector2) -> CardEntity:
		return target
	func _show_desc(_text: String, _card: CardEntity, _at_z := INF) -> void:
		descriptions += 1
	func _mouse_table_point() -> Vector3:
		return Vector3.ZERO

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_shadow_cache()
	_test_detail_cache()
	_test_single_hover_description()
	await process_frame
	finish()

func _test_shadow_cache() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var board := Board.new()
	stage.add_child(board)
	var card := CardEntity.new()
	card.freeze = true
	stage.add_child(card)
	card.position = Vector3(0, 0.05, 0)
	card._visual = Node3D.new()
	card.add_child(card._visual)
	board.register_card(card)
	var light := CountingLighting.new()
	stage.add_child(light)
	light.bind(board)
	for frame in 60:
		light._process(0.0)
	check(light.builds == 1, "静止 60 帧只构建一次投影，不重复排序和分配")
	var first_center: Vector3 = light._last_data[0].center
	card.position.x += 2.0
	light._process(0.0)
	check(light.builds == 2 and light._last_data[0].center.x > first_center.x + 1.9,
		"卡牌移动当帧更新投影")
	var opacity: float = light._last_data[0].opacity
	card._visual.position.y = 0.2
	light._process(0.0)
	check(light.builds == 3 and light._last_data[0].opacity < opacity,
		"仅卡面悬停抬起也使投影失效")
	card.hide()
	light._process(0.0)
	check(light._multimesh.visible_instance_count == 0, "隐藏卡牌当帧清掉投影")
	card.show()
	light._process(0.0)
	check(light._multimesh.visible_instance_count == 1, "重新显示后恢复投影")
	card._visual_retired = true
	light._process(0.0)
	check(light._multimesh.visible_instance_count == 0, "退场动画不会命中旧投影缓存")
	card._visual_retired = false
	light._process(0.0)
	board.unregister_card(card)
	light._process(0.0)
	check(light._multimesh.visible_instance_count == 0, "注销最后一张卡清掉投影")
	stage.free()

func _test_detail_cache() -> void:
	var host := DetailHost.new()
	root.add_child(host)
	host.board = DetailBoard.new()
	host.add_child(host.board)
	var view := CountingPresentation.new()
	host.add_child(view)
	view.set_process(false)
	view._main = host
	view._last_size = Vector2(1280, 800)
	view._content = Rect2(16, 100, 1248, 600)
	view._build_details()
	var card := CardEntity.new()
	card.freeze = true
	host.add_child(card)
	card.setup(990201, "shuabuting")
	view.show_card_detail(card, Vector2(500, 300))
	var first_position: Vector2 = view._detail.position
	var first_size: Vector2 = view._detail.size
	for frame in 60:
		view.show_card_detail(card, Vector2(510 + frame, 310))
	check(view.layouts == 1 and view._detail.size == first_size and host.board.descriptions == 1,
		"同卡鼠标移动 60 帧复用升级说明、文字尺寸和主题")
	check(view._detail.position != first_position, "缓存排版仍逐帧跟随鼠标")
	card.set_recipe_progress(card._recipe_need, true)
	view.show_card_detail(card, Vector2(550, 320))
	check(view.layouts == 2 and view._detail_status.text.begins_with("可生产"),
		"同名实体配方状态改变当帧刷新说明")
	card.set_effect_mult(2)
	view.show_card_detail(card, Vector2(550, 320))
	check(view.layouts == 3 and str(card._effect_base_n * 2) in view._detail_effect.text,
		"同一张卡效果倍数改变使布局失效")
	card.is_market = true
	view.show_card_detail(card, Vector2(550, 320))
	check(view.layouts == 4 and view._detail_facts.get_child(0).text == "购买",
		"同名卡切到市场时重建价格信息")
	view._content.size.y -= 100
	view.show_card_detail(card, Vector2(550, 320))
	check(view.layouts == 5, "可用高度改变时重新计算滚动区")
	var original_ink := Palette.get_color("card", "body")
	Palette.set_color("card", "body", Color("#123456"))
	view.show_card_detail(card, Vector2(550, 320))
	check(view.layouts == 6 and view._detail_title.get_theme_color("font_color") == Color("#123456"),
		"配色改变使主题缓存失效")
	Palette.set_color("card", "body", original_ink)
	view._ui_scale = 2.0
	view.show_card_detail(card, Vector2(550, 320))
	check(view.layouts == 7, "DPI 改变时重设实际字号并重测")
	view.show_facility_detail(Vector2(550, 320))
	for frame in 60:
		view.show_facility_detail(Vector2(560 + frame, 320))
	check(view.layouts == 8 and view._detail_facts.get_child_count() == 0,
		"设施说明也复用排版，不每帧删除重建内容")
	check(view._detail_flavor.text == "" and view._detail_status.text == "",
		"设施说明不被上一张卡的隐藏文本撑宽")
	view.show_card_detail(card, Vector2(550, 320))
	var definition := CardDB.get_def(card.def_id)
	var old_flavor := str(definition.get("flavor", ""))
	definition.flavor = "同名卡重新导入后的新说明"
	view.show_card_detail(card, Vector2(550, 320))
	check(view._detail_flavor.text == definition.flavor,
		"同名卡配置内容变化后静态事实与说明缓存立即失效")
	definition.flavor = old_flavor
	host.free()

func _test_single_hover_description() -> void:
	var board := HoverBoard.new()
	root.add_child(board)
	var card := CardEntity.new()
	card.freeze = true
	board.add_child(card)
	# 空模型不会请求插画；仍通过真实悬停状态入口验证交互保留。
	card.def_id = "cash"
	board.target = card
	board._update_hover_hint()
	check(board.descriptions == 1, "普通牌桌保留 3D 悬停说明")
	board.hover_description_enabled = false
	for frame in 60:
		board._update_hover_hint()
	check(board.descriptions == 1 and board._hover_card == card,
		"抽屉关闭重复 3D 文案后仍更新真实悬停卡")
	board.free()
