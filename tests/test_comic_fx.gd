# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 牌桌特效回归：配置口径、特效生命周期、镜头震动、命中顿帧的节拍、
## 正式牌桌的命中/产出/升级演出、顶栏资源反馈、终局演出与预览页。
## 只验结构与时序；画面好不好看要在动画预览「牌桌特效」页里用眼睛看。
const ComicFx = preload("res://scenes/comic_fx.gd")
const UIMotion = preload("res://scenes/ui_motion.gd")
const CardMotion = preload("res://scenes/card_motion.gd")
const ResultPresentation = preload("res://scenes/result_presentation.gd")
const ResultFx = preload("res://scenes/result_fx.gd")
const HudFx = preload("res://scenes/hud_fx.gd")
const InkStamp = preload("res://scenes/ink_stamp.gd")
const Materials = preload("res://scenes/effect_materials.gd")

class RecordedSound extends Sfx:
	var events: Array[String] = []
	var pitches: Array[float] = []
	func play(action: String, pitch := 1.0) -> void:
		events.append(action)
		pitches.append(pitch)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 牌桌特效 ===")
	CardDB.ensure_loaded()
	_config_rules()
	await _effect_lifecycle()
	await _camera_shake()
	await _hitstop_beat()
	await _table_moments()
	await _seal_layout()
	await _one_stamp()
	await _drawer_hud_and_finale()
	await _preview_page()
	finish()

func _config_rules() -> void:
	print("--- 配置口径 ---")
	var section := UIConfig.read_section("fx")
	var source := FileAccess.get_file_as_string("res://scenes/comic_fx.gd")
	check(not section.has("onomatopoeia") and not section.has("final_word") and not source.contains("func word_for"),
		"拟声字已去掉：配置和代码里都不再有")
	check(ComicFx.hitstop("hit", {"hitstop": {"hit": 0.5}}) <= UIMotion.HITSTOP,
		"普通顿帧再大也截在原撕牌节拍的余量内")
	check(is_equal_approx(ComicFx.hitstop("final", {"hitstop": {"final": 9.0}}), ComicFx.FINAL_HITSTOP_MAX),
		"终结顿帧有上限")
	check(is_equal_approx(ComicFx.hitstop("hit", {"hitstop": {"hit": "很久"}}), float(ComicFx.FALLBACK["hitstop"]["hit"])),
		"非数值的顿帧配置回退到内置默认")
	check(ComicFx.shake_amount("final", {"shake": {"final": -3}}) == 0.0 and ComicFx.shake_amount("hurt") > ComicFx.shake_amount("hit"),
		"震动幅度不为负，自己挨打比打别人震得重")
	check(ComicFx.stamp_text("cash") == str(UIConfig.read_section("fx")["stamps"]["cash"]) and ComicFx.stamp_text("nothing") == "nothing",
		"印章文字取配置，缺项不报错")

func _effect_lifecycle() -> void:
	print("--- 特效自行释放 ---")
	var stage := Node3D.new()
	root.add_child(stage)
	var pop := ComicFx.badge_pop(stage, Vector3(1, 0.05, 2), "+4", CardDB.RES_CASH, Color.YELLOW)
	check(pop.find_child("BadgeText", true, false).text == "+4"
		and pop.find_child("BadgeIcon", true, false).texture == CardArt.res_icon_texture(CardDB.RES_CASH),
		"结算墨团副本写「[金币] +4」，和卡面效果墨团同一种写法")
	var stamp := ComicFx.stamp(stage, Vector3.ZERO, "到账", 0.2)
	var kept := ComicFx.stamp(stage, Vector3(-3, 0, 0), "上市", 0.0, null, true)
	var seal := ComicFx.seal(stage, Vector3(3, 0, 0), "查封", "查封", Color.RED)
	var runners := ComicFx.runaway(stage, Vector3.ZERO, 3, Vector3.RIGHT)
	var coins := ComicFx.coin_spill(stage, Vector3.ZERO, 6, Color.YELLOW)
	var spot := ComicFx.spotlight(stage, Vector3.ZERO, 1.5, 0.1)
	check(runners.get_child_count() == 3, "逃跑的小人按张数出现")
	# 到货落点用全局随机，教学与录像固定全局种子来复现路线；特效不能从里面多抽一次。
	seed(4242)
	var expected := randf()
	seed(4242)
	ComicFx.badge_pop(stage, Vector3.ZERO, "+3", CardDB.RES_CASH, Color.YELLOW)
	ComicFx.stamp(stage, Vector3.ZERO, "到账")
	ComicFx.runaway(stage, Vector3.ZERO, 3)
	ComicFx.seal(stage, Vector3.ZERO, "查封", "查封", Color.RED)
	UIMotion.play(stage, "upgrade", Vector3.ZERO, Color.RED)
	var layer := CanvasLayer.new()
	stage.add_child(layer)
	var readout := Label.new()
	layer.add_child(readout)
	HudFx.collect(layer, Vector2.ZERO, readout, Vector2(100, 10), CardArt.res_icon_texture(CardDB.RES_CASH), -3, 16)
	check(is_equal_approx(randf(), expected), "特效只用自己的随机数，不打乱全局随机序列")
	check(stage.find_children("*", "CollisionObject3D", true, false).is_empty(), "牌桌特效没有碰撞，不挡拖牌")
	var scraps := UIMotion.play(stage, "attack", Vector3.ZERO, Color.RED) as CPUParticles3D
	var users := UIMotion.play(stage, "production", Vector3.ZERO, Color.BLUE, 8, "user") as CPUParticles3D
	check(scraps.mesh.material == Materials.particles("scrap") and users.mesh.material == Materials.particles("user")
		and Materials.particles("coin") != Materials.particles("user"),
		"攻击撒纸屑、产出用户撒小人，同形状共用一份材质")
	check(Materials.particles("user").get_shader_parameter("figure") == CardArt.res_icon_texture(CardDB.RES_USER)
		and Materials.particles("runner_r").get_shader_parameter("figure") == CardArt.res_icon_texture(CardDB.RES_USER)
		and Materials.particles("coin").get_shader_parameter("figure") == CardArt.res_icon_texture(CardDB.RES_CASH),
		"小人与金币粒子直接贴用户牌、现金牌的原图，不另画角色")
	await create_timer(1.8).timeout
	check(not is_instance_valid(pop) and not is_instance_valid(stamp)
		and not is_instance_valid(runners) and not is_instance_valid(coins) and not is_instance_valid(spot),
		"一次性的墨团副本、印章、逃跑小人、硬币与聚光演完自行释放")
	check(is_instance_valid(kept) and is_instance_valid(seal), "终局印章与封条留在桌上，等开新局再清")
	stage.queue_free()
	await process_frame

func _camera_shake() -> void:
	print("--- 镜头震动 ---")
	var camera := Camera3D.new()
	root.add_child(camera)
	UIConfig.set_screen_shake(1.0)
	var tween := ComicFx.shake(camera, 0.2, 0.3)
	await process_frame
	await process_frame
	check(tween != null and absf(camera.h_offset) + absf(camera.v_offset) > 0.0, "震动只改镜头的 h/v 偏移")
	await create_timer(0.5).timeout
	check(camera.h_offset == 0.0 and camera.v_offset == 0.0 and not camera.has_meta("fx_shake_amplitude"),
		"震动结束偏移归零，不留残差")
	UIConfig.set_screen_shake(0.0)
	check(ComicFx.shake(camera, 0.2) == null and camera.h_offset == 0.0, "UI 页把画面震动拉到 0 时完全不震")
	UIConfig.set_screen_shake(1.0)
	camera.queue_free()
	await process_frame

func _hitstop_beat() -> void:
	print("--- 命中顿帧 ---")
	var main: Node = await boot_main()
	main.sfx.set_muted(true)
	var speed := Engine.time_scale
	# 这一节量的是帧内先后（抓握到位→顿住→撕开），用真实速度量，避免五倍速一帧跨过整个顿帧。
	Engine.time_scale = 1.0
	# 直接调整批撕牌：先像 animate_removed 一样从实体表摘掉，撕完释放不留野引用。
	var cards := _foe_users(main, 3)
	for card in cards:
		main.entities.erase(card.uid)
	var hit_at := [-1.0]
	var intact_at_hit := [false]
	var started := Time.get_ticks_msec()
	var duration: float = main._card_motion.tear_batch(cards, null, Vector3(0, 4, -2), UIMotion.HITSTOP,
		func() -> void:
			hit_at[0] = float(Time.get_ticks_msec() - started) / 1000.0
			intact_at_hit[0] = cards.all(func(card): return is_instance_valid(card) and not card._visual_retired))
	check(is_equal_approx(duration, CardMotion.BATCH_DURATION), "普通一击的顿帧包含在原整批节拍内（%.2f s）" % duration)
	await create_timer(CardMotion.BATCH_GRIP + 0.03).timeout
	# 补间按帧推进：首帧的 delta 含补间建立前的那段时间，忙时游戏时间可领先墙钟一帧，留一帧余量。
	check(hit_at[0] >= CardMotion.BATCH_GRIP - 0.07 and intact_at_hit[0],
		"抓握到位那一拍才触发命中，此时牌还没撕（%.3f s）" % hit_at[0])
	check(cards.all(func(card): return is_instance_valid(card) and not card._visual_retired), "顿帧期间牌被按住、还没撕开")
	await create_timer(UIMotion.HITSTOP + 0.06).timeout
	check(cards.all(func(card): return not is_instance_valid(card) or card._visual_retired), "顿帧结束才撕开")
	var final_cards := _foe_users(main, 2)
	for card in final_cards:
		main.entities.erase(card.uid)
	var final_duration: float = main._card_motion.tear_batch(final_cards, null, Vector3(0, 4, -2), ComicFx.hitstop("final"))
	check(is_equal_approx(final_duration, CardMotion.BATCH_DURATION + ComicFx.hitstop("final") - UIMotion.HITSTOP),
		"终结一击的定格按多出的顿帧顺延整批时长（%.2f s）" % final_duration)
	await create_timer(final_duration + 0.1).timeout
	Engine.time_scale = speed
	main.queue_free()
	await process_frame

func _foe_users(main: Node, count: int) -> Array:
	var cards: Array = []
	for i in count:
		var record: Dictionary = main.state.add_card(main.foe_seat, CardDB.unit_id(CardDB.RES_USER), true)
		cards.append(main._spawn_entity(record, Vector3(-1.5 + i * 1.5, 0.05, -3.5), false))
	return cards

func _table_moments() -> void:
	print("--- 正式牌桌：命中、连击、终结、产出、升级 ---")
	var main: Node = await boot_main()
	var sound := RecordedSound.new()
	main.add_child(sound)
	main.sfx = sound
	# 同名节点会被引擎改名，按特效登记的 motion_event 认，不按节点名认。
	var added: Array[String] = []
	main.child_entered_tree.connect(func(node: Node) -> void:
		added.append(str(node.get_meta("motion_event")) if node.has_meta("motion_event") else str(node.name)))
	var actions: Node = main._table_actions
	var current := func() -> bool: return true
	var durations: Array = []
	var track := func(value: float) -> void: durations.append(value)
	var max_offset := [0.0]
	var camera: Camera3D = main.board.camera
	var watching := [true]
	var damaged := {}
	var torn_crumpled := {}
	# 折痕强度撕开后仍留在牌上（交给了两片撕片）。不逐帧轮询：并行跑时一帧可能比整批撕牌还长，
	# 牌在被采样前就已释放。改为逐帧读一次、离场那一刻再读一次。
	var sample := func(card: Variant) -> void:
		if not is_instance_valid(card) or card.damage_amount() <= 0.9:
			return
		damaged[card.get_instance_id()] = true
		var halves: Array = card.find_children("*", "MeshInstance3D", true, false).filter(func(mesh):
			return mesh.material_override is ShaderMaterial \
				and mesh.material_override.shader == load(CardEntity.TEAR_SHADER))
		if not halves.is_empty():
			torn_crumpled[card.get_instance_id()] = halves.all(func(mesh):
				return float(mesh.material_override.get_shader_parameter("crumple")) > 0.9)
	var watch := func(cards: Array) -> void:
		for card in cards:
			card.tree_exiting.connect(sample.bind(card))
		while watching[0]:
			max_offset[0] = maxf(max_offset[0], absf(camera.h_offset) + absf(camera.v_offset))
			for card in cards:
				sample.call(card)
			await process_frame

	var first := _foe_users(main, 2)
	watch.call(first)
	var scraps_before := _scrap_bursts(main)
	await actions.present_attack(first.map(func(card): return card.uid), first[0].global_position, main.my_seat,
		CardDB.RES_USER, null, main._drawer_timer, current, [], track)
	check(damaged.size() == 2, "命中那一拍，被抓住的牌起折痕、撕口先裂开（%d / 2 张）" % damaged.size())
	check(torn_crumpled.size() == 2 and torn_crumpled.values().all(func(v): return v),
		"撕开后两片撕片接着带着折痕")
	check(not added.has("impact") and not added.has("focus") and main.find_children("*", "Label3D", false, false).is_empty(),
		"不再画冲击星、放射线和拟声字")
	check(added.has("runaway"), "被打掉的用户跑出牌桌")
	var scraps := _scrap_bursts(main).slice(scraps_before.size())
	check(not scraps.is_empty() and scraps.all(func(p): return p.color.is_equal_approx(CardArt.face_color(CardDB.unit_id(CardDB.RES_USER)))),
		"纸屑用被撕那张牌的底色，不再是红色")
	check(max_offset[0] > 0.0 and camera.h_offset == 0.0 and camera.v_offset == 0.0, "命中时镜头震一下并回正")
	check(durations.size() == 1 and is_equal_approx(durations[0], CardMotion.BATCH_DURATION), "普通命中不拖慢原撕牌节拍")
	var second := _foe_users(main, 1)
	added.clear()
	watching[0] = false
	await process_frame
	watching[0] = true
	watch.call(second)
	await actions.present_attack(second.map(func(card): return card.uid), second[0].global_position, main.my_seat,
		CardDB.RES_CASH, null, main._drawer_timer, current, [], track)
	await process_frame
	var hits: Array = []
	for i in sound.events.size():
		if sound.events[i] == "attack":
			hits.append(sound.pitches[i])
	check(hits.size() == 2 and hits[1] > hits[0], "连着打的第二批命中音升调（%s）" % [hits])
	check(added.has("coin_spill"), "打掉现金撒出一把硬币")

	var last := _foe_users(main, 1)
	main.state.winner = main.my_seat
	await actions.present_attack(last.map(func(card): return card.uid), last[0].global_position, main.my_seat,
		CardDB.RES_USER, null, main._drawer_timer, current, [], track)
	await process_frame
	check(is_equal_approx(durations.back(), CardMotion.BATCH_DURATION + ComicFx.hitstop("final") - UIMotion.HITSTOP),
		"分出胜负的那一击定格更久（%.2f s）" % durations.back())
	var again := _foe_users(main, 1)
	await actions.present_attack(again.map(func(card): return card.uid), again[0].global_position, main.my_seat,
		CardDB.RES_USER, null, main._drawer_timer, current, [], track)
	check(is_equal_approx(durations.back(), CardMotion.BATCH_DURATION), "同一局终结演出只播一次")
	main.state.winner = ""
	watching[0] = false

	print("--- 产出：方案 P ---")
	added.clear()
	sound.events.clear()
	var core_record: Dictionary = main.state.add_card(main.my_seat, "yunketang")
	var core: CardEntity = main._spawn_entity(core_record, Vector3(2.0, 0.05, 3.0), true)
	var at: Vector3 = core.global_position + Vector3(0, 0.6, 0)
	var output := int(CardDB.get_def("yunketang")["output_n"])
	actions.combo_feedback({"type": "production", "output_res": CardDB.RES_CASH, "output_n": output, "leader": "yunketang"},
		at, {"owner": main.my_seat, "uids": [core.uid]})
	check(_receipts(main).is_empty() and not added.has("receipt"), "不再弹出小票")
	var pops := main.get_children().filter(func(node): return node.get_meta("motion_event", "") == "badge_pop")
	var pop: Node3D = pops[0] if not pops.is_empty() else null
	check(pop != null and pop.find_child("BadgeText", true, false).text == core.effect_text(),
		"核心牌右下的效果墨团「%s」弹起" % core.effect_text())
	if pop != null:
		var anchor: Vector3 = pop.get_meta("target")
		check(anchor.distance_to(core.effect_badge_anchor()) < 0.01, "弹起的就是这张牌自己那枚效果墨团的位置")
		var coins := main.find_children("*", "CPUParticles3D", true, false).filter(func(p): return p.mesh.material == Materials.particles("coin"))
		check(not coins.is_empty() and coins.back().global_position.distance_to(pop.global_position) < 0.05,
			"金币从这枚墨团里抛出来，不从牌中心喷")
	check(core.stamp_showing() and core.stamp_text() == ComicFx.stamp_text("cash"),
		"核心牌上盖「%s」章" % ComicFx.stamp_text("cash"))
	core.set_void_stamp(false)
	var stamp_mesh: MeshInstance3D = core._void_stamp
	var stamp_material := stamp_mesh.material_override as ShaderMaterial
	var ink := Color(stamp_material.get_shader_parameter("ink"))
	var face := CardArt.face_color("yunketang")
	check(ink.is_equal_approx(InkStamp.seal_ink()) and _contrast(ink, face) >= 3.0,
		"朱红印泥直接盖在牌面上，对比度 %.1f:1" % _contrast(ink, face))
	var width: float = (stamp_mesh.mesh as QuadMesh).size.x
	var screen_width := camera.unproject_position(core.global_position - Vector3(width * 0.5, 0, 0)) \
		.distance_to(camera.unproject_position(core.global_position + Vector3(width * 0.5, 0, 0)))
	var screen_card := camera.unproject_position(core.global_position - Vector3(0.6, 0, 0)) \
		.distance_to(camera.unproject_position(core.global_position + Vector3(0.6, 0, 0)))
	# 外框线占章宽 30/1000（tools/gen_stamp_art.py）。
	check(screen_width > screen_card * 1.3 and screen_width * 0.03 >= 2.5,
		"牌上的章约一张半牌宽（章 %.0f px，牌 %.0f px），外框线不细成一两个像素（%.1f px）" % [
		screen_width, screen_card, screen_width * 0.03])
	await create_timer(0.3).timeout
	check(sound.events.has("stamp"), "印章落定有一声")
	await create_timer(1.2).timeout
	check(not core.stamp_showing(), "「到账」停一会儿后收起")
	# 落袋：资金摞侧边清单的「×N」变大时那一行弹一下；第一次挂清单不弹。
	var pile: Array = []
	for i in 3:
		pile.append(main._spawn_entity(main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_CASH)),
			Vector3(-3.0, 0.05, 4.0), true))
	var group: Dictionary = main.board.make_group(pile, true, false)
	main.board.groups.append(group)
	main.board.refresh_group(group)
	var row_label: Label3D = group["side"][1]
	check(row_label.text == "×3" and row_label.scale.is_equal_approx(Vector3.ONE), "第一次挂上「×3」不弹")
	var extra: CardEntity = main._spawn_entity(main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_CASH)),
		Vector3(-3.0, 0.05, 4.0), true)
	group["cards"].append(extra)
	main.board.refresh_group(group)
	row_label = group["side"][1]
	check(row_label.text == "×4" and row_label.scale.x > 1.2, "到账后「×4」那一行弹一下（%.2f 倍）" % row_label.scale.x)
	core.set_void_stamp(true)
	check(core.stamp_showing() and core.stamp_text() == "作废" and core._void_stamp == stamp_mesh,
		"同一张牌失败时盖回「作废」：与「到账」是同一枚章（同一张面片，只换字）")
	core.set_void_stamp(false)
	actions.combo_feedback({"type": "production", "output_res": CardDB.RES_USER, "output_n": 3, "leader": "yunketang"},
		at, {"owner": main.my_seat, "uids": [core.uid]})
	check(core.stamp_text() == ComicFx.stamp_text("user"), "产出用户盖「%s」章" % ComicFx.stamp_text("user"))
	check(_particle_materials(main).has(Materials.particles("user")), "产出用户撒的是小人")
	var legend := ""
	for id in CardDB.all_cards():
		if CardDB.get_def(str(id)).get("kind", "") == CardDB.KIND_LEGEND:
			legend = str(id)
			break
	added.clear()
	actions.combo_feedback({"type": "upgrade", "output_card": legend, "leader": "yunketang"}, at,
		{"owner": main.my_seat, "uids": []})
	check(not added.has("spotlight"), "升级的聚光不在材料原处亮，等新牌出来")
	# 模拟结算同步：新牌从材料处飞到别处的落点。
	var record: Dictionary = main.state.add_card(main.my_seat, legend)
	var landing := Vector3(-6.0, 0.05, 3.5)
	var arrived: CardEntity = main._spawn_entity(record, landing, true, at)
	for i in 200:
		await process_frame
		if added.has("spotlight"):
			break
	var light: Node3D = null
	for node in main.get_children():
		if node.has_meta("motion_event") and node.get_meta("motion_event") == "spotlight":
			light = node
	var target: Vector3 = light.get_meta("target") if light != null else Vector3.INF
	check(light != null and Vector2(target.x - arrived.global_position.x, target.z - arrived.global_position.z).length() < 0.05
		and Vector2(target.x - at.x, target.z - at.z).length() > 3.0,
		"传说牌落定后，聚光对准它的落点而不是材料原处")
	if light != null:
		var on_screen := camera.unproject_position(light.global_position)
		var card_screen := camera.unproject_position(arrived.global_position)
		check(on_screen.distance_to(card_screen) < 3.0, "聚光圈在屏幕上正好套住新牌（差 %.1f px）" % on_screen.distance_to(card_screen))
	check(arrived.stamp_showing() and arrived.stamp_text() == ComicFx.stamp_text("legend"), "传说牌落定后在它身上盖「传奇」章")
	var lifted := ComicFx.badge_pop(main, landing, "+1", CardDB.RES_CASH, Color.YELLOW)
	var lifted_screen := camera.unproject_position(lifted.global_position)
	var ground_screen := camera.unproject_position(Vector3(landing.x, ComicFx.GROUND_Y, landing.z))
	check(lifted.global_position.y > 0.5 and lifted_screen.distance_to(ground_screen) < 2.0,
		"抬高的特效沿视线挪上去，屏幕上仍压在目标上（差 %.1f px）" % lifted_screen.distance_to(ground_screen))
	var stats: Dictionary = actions.match_stats()
	check(int(stats.get(main.my_seat, {}).get(CardDB.RES_CASH, 0)) == output
		and int(stats.get(main.my_seat, {}).get(CardDB.RES_USER, 0)) == 3
		and int(stats.get(main.my_seat, {}).get("torn", 0)) == 5,
		"本局战绩记下自己的产出与撕掉的牌（%s）" % [stats])
	var later := GameState.new()
	later.new_game()
	later.round_num = 5
	main.state = later
	actions.track_match(later)
	check(actions.match_stats().is_empty(), "中途接手的局不显示半截战绩")
	main.queue_free()
	await process_frame

## 破产封条：章、两行字、两条纸各占各的地方，在屏幕上不互相穿插；绘制顺序严格错开。
func _seal_layout() -> void:
	print("--- 破产封条的版面 ---")
	var main: Node = await boot_main()
	main.sfx.set_muted(true)
	var camera: Camera3D = main.board.camera
	var stage := Node3D.new()
	main.add_child(stage)
	var spots: Array[Vector3] = [main.layout._unit_anchor(main.foe_seat, CardDB.unit_id(CardDB.RES_CASH)),
		main.layout._unit_anchor(main.my_seat, CardDB.unit_id(CardDB.RES_CASH))]
	for at in spots:
		ComicFx.seal(stage, at, "破产清算", ComicFx.stamp_text("bankrupt"), Palette.semantic("danger"))
	await create_timer(1.2).timeout
	var seals := stage.get_children().filter(func(node): return node.get_meta("motion_event", "") == "seal")
	var stamps := stage.get_children().filter(func(node): return node.get_meta("motion_event", "") == "stamp")
	check(seals.size() == 2 and stamps.size() == 2, "两处封条各带一枚章")
	for i in mini(seals.size(), stamps.size()):
		var where := "对手" if i == 0 else "我方"
		# 同名兄弟节点会被引擎改名：纸条直接取封条的子节点，字取每条纸里的那个 Label3D。
		var strips: Array = seals[i].get_children()
		var captions: Array = strips.map(func(strip): return strip.find_children("*", "Label3D", false, false)[0])
		var parts: Dictionary = stamps[i].get_meta("stamp_parts", {})
		var mesh: MeshInstance3D = parts.get("mesh")
		if not need(captions.size() == 2 and strips.size() == 2 and mesh != null, where + "：封条部件齐全"):
			continue
		# 外框离贴图边各 16/1000（tools/gen_stamp_art.py）。
		var stamp_shape := _screen_quad(camera, mesh, Vector2(0.968, 0.913))
		var texts := captions.map(func(label): return _screen_quad(camera, label))
		check(not _overlap(stamp_shape, texts[0]) and not _overlap(stamp_shape, texts[1]),
			where + "：章不压在封条的字上")
		check(not _overlap(texts[0], texts[1]), where + "：两行字不互相交叉")
		check(not _overlap(texts[0], _screen_quad(camera, strips[1].get_child(0))) \
			and not _overlap(texts[1], _screen_quad(camera, strips[0].get_child(0))),
			where + "：每行字只写在自己那条纸上，不跨到另一条纸")
		var stamp_center := _center(stamp_shape)
		var cross := camera.unproject_position(seals[i].global_position)
		check(stamp_center.distance_to(cross) < 6.0, where + "：章压在交叉处（差 %.1f px）" % stamp_center.distance_to(cross))
		check(captions.all(func(label): return label.text == "破产清算") and str(parts["text"]) == ComicFx.stamp_text("bankrupt"),
			where + "：纸条写事由、章写处置，不重复同一个词")
		var order: Array = [
			strips[0].get_child(0).material_override.render_priority, captions[0].render_priority,
			strips[1].get_child(0).material_override.render_priority, captions[1].render_priority,
			mesh.material_override.render_priority]
		var strictly := true
		for k in order.size() - 1:
			strictly = strictly and order[k] < order[k + 1]
		check(strictly, where + "：纸条一 < 字一 < 纸条二 < 字二 < 章，绘制顺序不会翻转（%s）" % [order])
	main.queue_free()
	await process_frame

## 全游戏只有一枚章：牌上的「到账 / 升级 / 作废」、牌桌上的「上市 / 人去楼空 / 查封」、结果面板的「上市成功」
## 用同一个着色器、同一张框、同一张印泥纹理和同一盒印泥；桌上不垫小票、不垫纸，只有大小按场合不同。
func _one_stamp() -> void:
	print("--- 同一枚章 ---")
	var stage := Node3D.new()
	root.add_child(stage)
	var card := CardEntity.new()
	card.setup(99501, "yunketang")
	card.freeze = true
	stage.add_child(card)
	card.flash_stamp(ComicFx.stamp_text("upgrade"))
	var stamps := {"升级（牌上）": card._stamp_parts}
	for key in ["listing", "exodus", "bankrupt"]:
		var made := ComicFx.stamp(stage, Vector3(4, 0, 0), ComicFx.stamp_text(key))
		stamps[ComicFx.stamp_text(key) + "（牌桌）"] = made.get_meta("stamp_parts")
	var panel := ResultFx.ResultStamp.new()
	panel.text = ComicFx.stamp_text("win_listing")
	panel.slam = 1.0
	var host := Label.new()
	host.text = "你赢了"
	stage.add_child(CanvasLayer.new())
	stage.get_child(-1).add_child(host)
	host.add_child(panel)
	await process_frame
	await process_frame
	var materials := {}
	for name in stamps:
		materials[name] = InkStamp.material_of(stamps[name])
	materials["上市成功（结果面板）"] = panel.material
	var same := func(key: String) -> bool:
		var first: Variant = materials.values()[0].get_shader_parameter(key)
		return materials.values().all(func(m): return m.get_shader_parameter(key) == first)
	check(materials.values().all(func(m): return m is ShaderMaterial)
		and stamps.values().all(func(parts): return InkStamp.material_of(parts).shader == InkStamp.spatial_shader())
		and panel.material.shader == InkStamp.canvas_shader()
		and InkStamp.spatial_shader().code.contains(InkStamp.STAMP_BODY) and InkStamp.canvas_shader().code.contains(InkStamp.STAMP_BODY),
		"牌上、牌桌、结果面板用同一段着色器")
	check(same.call("frame_tex") and same.call("grain_tex") and materials.values()[0].get_shader_parameter("frame_tex") == InkStamp.frame_texture(),
		"同一张长方形双框、同一张印泥纹理")
	check(materials.values().all(func(m): return Color(m.get_shader_parameter("ink")).is_equal_approx(InkStamp.seal_ink())),
		"同一盒印泥（%s）" % InkStamp.seal_ink().to_html())
	var tilts := stamps.values().map(func(parts): return float(parts["mesh"].get_meta("stamp_tilt")))
	check(tilts.all(func(t): return t >= InkStamp.TILT_MIN and t <= InkStamp.TILT_MAX),
		"手盖的章都往同一个方向歪 %.0f°～%.0f°（%s）" % [InkStamp.TILT_MIN, InkStamp.TILT_MAX, tilts])
	var widths := {}
	for name in stamps:
		widths[name] = snappedf((stamps[name]["mesh"].mesh as QuadMesh).size.x, 0.001)
	check(widths["升级（牌上）"] == InkStamp.CARD_WIDTH
		and stamps.keys().filter(func(k): return k.ends_with("（牌桌）")).all(func(k): return widths[k] == InkStamp.TABLE_WIDTH),
		"大小只按场合分：牌上 %.2f、牌桌 %.2f（%s）" % [InkStamp.CARD_WIDTH, InkStamp.TABLE_WIDTH, widths])
	check(stamps.values().all(func(parts): return is_equal_approx((parts["mesh"].mesh as QuadMesh).size.y,
		(parts["mesh"].mesh as QuadMesh).size.x * InkStamp.ASPECT)), "框按原图比例，不拉伸")
	var tape := ComicFx._shader("tape")
	check(not stage.find_children("*", "MeshInstance3D", true, false).any(func(mesh): return mesh.material_override is ShaderMaterial \
		and mesh.material_override.shader == tape),
		"牌桌上的章不垫手撕小票，也不垫纸")
	var texture := InkStamp.text_texture(ComicFx.stamp_text("exodus"))
	check(texture == InkStamp.text_texture(ComicFx.stamp_text("exodus")) and texture.get_width() == InkStamp.TEXT_SIZE.x
		and texture.get_height() == InkStamp.TEXT_SIZE.y,
		"每个词只排一次字，之后共用同一张字贴图")
	stage.queue_free()
	await process_frame

## 一个平铺部件在屏幕上的四个角：取它本地包围盒在自身平面上的四角，经真实镜头投影。
## keep 把包围盒绕中心缩到这个比例（贴图只有一部分是墨迹时用）。
func _screen_quad(camera: Camera3D, node: VisualInstance3D, keep := Vector2.ONE) -> PackedVector2Array:
	var box := node.get_aabb()
	var grown := box.size * Vector3(keep.x, keep.y, keep.y if box.size.y < box.size.z else 1.0)
	box = AABB(box.get_center() - grown * 0.5, grown)
	var quad := PackedVector2Array()
	var flat := box.size.y < box.size.z
	for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
		var local := box.position + Vector3(box.size.x * corner.x, box.size.y * 0.5 if flat else box.size.y * corner.y,
			box.size.z * corner.y if flat else box.size.z * 0.5)
		quad.append(camera.unproject_position(node.global_transform * local))
	return quad

func _center(quad: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for point in quad:
		sum += point
	return sum / float(quad.size())

## 两个凸四边形是否相交（分离轴）。
func _overlap(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for shape in [a, b]:
		for i in shape.size():
			var edge: Vector2 = shape[(i + 1) % shape.size()] - shape[i]
			var axis := Vector2(-edge.y, edge.x)
			var a_lo := INF
			var a_hi := -INF
			var b_lo := INF
			var b_hi := -INF
			for point in a:
				a_lo = minf(a_lo, axis.dot(point))
				a_hi = maxf(a_hi, axis.dot(point))
			for point in b:
				b_lo = minf(b_lo, axis.dot(point))
				b_hi = maxf(b_hi, axis.dot(point))
			if a_hi < b_lo or b_hi < a_lo:
				return false
	return true

func _scrap_bursts(main: Node) -> Array:
	return main.find_children("*", "CPUParticles3D", true, false).filter(func(p): return p.mesh.material == Materials.particles("scrap"))

func _receipts(main: Node) -> Array:
	return main.get_children().filter(func(node): return node.has_meta("motion_event") \
		and node.get_meta("motion_event") == "receipt" and not node.is_queued_for_deletion())

static func _contrast(a: Color, b: Color) -> float:
	var la := a.srgb_to_linear().get_luminance()
	var lb := b.srgb_to_linear().get_luminance()
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)

func _stamp_words(main: Node) -> Array:
	var words: Array = []
	for node in main.get_children():
		if node.has_meta("motion_event") and node.get_meta("motion_event") == "stamp" and not node.is_queued_for_deletion():
			for label in node.find_children("*", "Label3D", true, false):
				words.append(label.text)
	return words

func _particle_materials(main: Node) -> Array:
	var materials: Array = []
	for node in main.find_children("*", "CPUParticles3D", true, false):
		materials.append(node.mesh.material)
	return materials

func _boot_drawer() -> Node:
	root.size = Vector2i(1280, 800)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.force_drawer_layout = true
	root.add_child(main)
	_booted = main
	for i in 180:
		await physics_frame
		if i > 12 and not _anim_busy(main):
			break
	main.drawer_window.set_process(false)
	main.drawer_window.animations_enabled = false
	main.drawer_window.pin()
	main.drawer_presentation.relayout()
	await process_frame
	return main

func _drawer_hud_and_finale() -> void:
	print("--- 顶栏资源反馈与终局演出 ---")
	var main: Node = await _boot_drawer()
	var sound := RecordedSound.new()
	main.add_child(sound)
	main.sfx = sound
	var win_cash := int(CardDB.game_rules()["win_cash"])
	main._update_hud()
	check(main.lbl_player_res.get_parent().get_node_or_null("CashMeter") == null, "顶栏不再挂资金进度条")
	await _check_no_pile_badge(main)
	var before: int = _chips(main).size()
	for i in 3:
		main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_CASH))
	main._update_hud()
	var pieces: Array = main._hud_fx_layer.get_children().filter(func(node): return node.get_meta("hud_fx", "") == "piece" \
		and not node.is_queued_for_deletion())
	check(pieces.size() == 3 and pieces.all(func(piece): return piece.texture == CardArt.res_icon_texture(CardDB.RES_CASH)),
		"资金到账：三枚现金牌上的金币飞向顶栏读数")
	var cash_pile: CardEntity = main._resource_pile_top(main.my_seat, CardDB.RES_CASH)
	check(cash_pile != null, "找得到我方资金主摞")
	await create_timer(main.HUD_COLLECT_DELAY + 0.05).timeout
	if cash_pile != null and not pieces.is_empty() and is_instance_valid(pieces[0]):
		var pile_screen: Vector2 = main.board.camera.unproject_position(main._card_rest(cash_pile))
		var piece_center: Vector2 = pieces[0].position + pieces[0].size * 0.5
		check(piece_center.distance_to(pile_screen) < 40.0, "金币从牌桌上的资金摞起飞（差 %.0f px）" % piece_center.distance_to(pile_screen))
	await create_timer(0.6).timeout
	var chips := _chips(main)
	var chip_texts: Array = chips.map(func(chip): return chip.find_child("ChipAmount", true, false).text)
	check(chips.size() == before + 1 and chip_texts.has("+3")
		and chips.back().get_child(0).texture == CardArt.res_icon_texture(CardDB.RES_CASH),
		"读数下贴「[金币] +3」，不写「资金」二字（%s）" % [chip_texts])
	check(main.lbl_player_res.text.contains(str(main.state.resource_count(main.my_seat, CardDB.RES_CASH))),
		"读数文字仍是规则状态的实数，飞入的图标不改读数")
	var foe_users: Array = main.state.players[main.foe_seat]["cards"].filter(
		func(card): return card["def_id"] == CardDB.unit_id(CardDB.RES_USER))
	main.state.players[main.foe_seat]["cards"] = main.state.players[main.foe_seat]["cards"].filter(
		func(card): return not foe_users.slice(0, 2).has(card))
	main._update_hud()
	await process_frame
	chip_texts = _chips(main).map(func(chip): return chip.find_child("ChipAmount", true, false).text)
	check(chip_texts.has("−2"), "对手掉用户：小人从对手读数里掉出来，贴「[小人] −2」")
	var replaced := GameState.new()
	replaced.new_game()
	var count: int = _chips(main).size()
	main.state = replaced
	main._update_hud()
	await process_frame
	check(_chips(main).size() == count, "换了一局只记读数，不把差值当成到账")
	main.state = replaced

	print("--- 终局面板与谢幕 ---")
	var cases := [["listing", true], ["bankrupt", true], ["exodus", true], ["defeat", false]]
	for entry in cases:
		var kind: String = entry[0]
		var won: bool = entry[1]
		main._teardown_for_new_game(true)
		main._reset_session_flags()
		main.state = GameState.new()
		main.state.new_game()
		main._rebuild_pipe()
		main._sync_round()
		await process_frame
		var me: String = main.my_seat
		var foe: String = main.foe_seat
		match kind:
			"listing": _set_count(main.state, me, CardDB.RES_CASH, win_cash)
			"bankrupt": _set_count(main.state, foe, CardDB.RES_CASH, 0)
			"exodus": _set_count(main.state, foe, CardDB.RES_USER, 0)
			_:
				_set_count(main.state, me, CardDB.RES_CASH, win_cash - 2)
				_set_count(main.state, foe, CardDB.RES_CASH, win_cash)
		main.state.check_victory()
		check(ResultPresentation.victory_kind(main.state) == ("listing" if kind == "defeat" else kind),
			"%s：胜因按终局读数判出" % kind)
		sound.events.clear()
		main._show_game_over()
		await process_frame
		var panel: Control = main.game_over_panel
		var stamp := panel.find_child("ResultStamp", true, false) as ResultFx.ResultStamp
		var mascot := panel.find_child("ResultMascot", true, false) as ResultFx.MascotPose
		var finale_stamp := ComicFx.stamp_text(("win_" + kind) if won else "lose")
		check(stamp != null and stamp.text == finale_stamp, "%s：标题旁盖「%s」章" % [kind, finale_stamp])
		check(mascot != null and mascot.pose == ("cheer" if won else "slump")
			and mascot.figure == CardArt.res_icon_texture(CardDB.RES_USER),
			"%s：吉祥物就是用户牌的小人，%s" % [kind, "蹦着欢呼" if won else "缩着淋雨"])
		var stats := panel.find_child("ResultStats", true, false) as Label
		check(stats != null and stats.text.contains("回合"), "%s：列出本局终局读数" % kind)
		var layer: CanvasLayer = main._game_over_result["layer"]
		var backdrop: Node = layer.get_child(0)
		check((backdrop is ResultFx.Confetti) if won else (backdrop is ResultFx.Desaturate),
			"%s：%s垫在面板底下" % [kind, "彩纸" if won else "褪色"])
		var finale: Node = main._finale_fx
		check(is_instance_valid(finale), "%s：牌桌上有终局谢幕" % kind)
		if kind == "listing":
			check(sound.events.has("listing_bell") and not sound.events.has("win"), "上市胜利敲钟代替普通胜利音")
		elif won:
			check(sound.events.has("win"), "%s：普通胜利音" % kind)
		if kind == "bankrupt":
			check(finale.get_node_or_null("Seal") != null, "对手破产：现金堆上贴封条")
		if kind == "exodus":
			check(finale.get_node_or_null("Runaway") != null, "对手跑光：用户堆里的人跑出牌桌")
		if not won:
			var hint := panel.find_child("ResultHint", true, false) as Label
			check(hint != null and hint.text == "差 2 %s就上市了。" % CardDB.res_label(CardDB.RES_CASH),
				"失败面板提示离赢只差多少（%s）" % (hint.text if hint else "无"))
			await create_timer(ResultPresentation.TROMBONE_AT + 0.2).timeout
			check(sound.events.has("defeat_trombone") and not sound.events.has("lose"), "失败用泄气的长号，不叠原失败音")
		await create_timer(ResultPresentation.STAMP_AT + ResultPresentation.STAMP_TIME + 0.1).timeout
		check(stamp.slam >= 1.0 and sound.events.has("stamp"), "%s：印章砸下并发声" % kind)
	var center: Vector2 = Vector2(root.size) * 0.5
	var away := Vector2(8, 8)
	check(not main.drawer_presentation.pointer_over_panels(away),
		"整屏的终局背景只是画面，不让抽屉把整张牌桌当成面板")
	check(main.drawer_presentation.pointer_over_panels(main.game_over_panel.get_global_rect().get_center()),
		"结果面板本身仍算面板（%s）" % center)
	# 联网 rematch 把新局快照还原进同一个 GameState：走真实的跨局清理后，
	# 战绩、终结记录与读数基线都要从头来。
	var same: GameState = main.state
	main._table_actions._record(main.my_seat, CardDB.RES_CASH, 99)
	main._table_actions._final_state_id = same.get_instance_id()
	main._reset_session_flags(true)
	check(main._table_actions.match_stats().is_empty() and main._table_actions._final_state_id == 0 and main._hud_seen.is_empty(),
		"同一 GameState 开新局（rematch）时清空战绩、终结记录与读数基线")
	main._on_restart()
	await process_frame
	await process_frame
	check(main._finale_fx == null and main.find_children("FinaleFx*", "Node3D", false, false).all(
		func(node): return node.is_queued_for_deletion()), "开下一局清掉终局谢幕")
	main.queue_free()
	await process_frame

func _chips(main: Node) -> Array:
	if main._hud_fx_layer == null:
		return []
	return main._hud_fx_layer.get_children().filter(func(node): return node.get_meta("hud_fx", "") == "chip" \
		and not node.is_queued_for_deletion())

## 现金摞成一摞时，牌面只有现金牌自己的图：不在左下角另挂墨团或数字。
func _check_no_pile_badge(main: Node) -> void:
	for i in 4:
		main.state.add_card(main.my_seat, CardDB.unit_id(CardDB.RES_CASH))
	main._sync_entities()
	for i in 3:
		await process_frame
	var cash: Array = main.entities.values().filter(func(card): return is_instance_valid(card) \
		and card.def_id == CardDB.unit_id(CardDB.RES_CASH))
	var extra := cash.filter(func(card): return card.face_overlays().any(func(node): return node is Label3D \
		and node != card.label and node.text.contains("/")))
	check(cash.size() >= 4 and extra.is_empty() and not cash.any(func(card): return card.has_recipe_badge()),
		"现金摞在一起时牌面不另挂墨团和数字（%d 张现金，%d 张带了）" % [cash.size(), extra.size()])
	# 这几张是摆场用的，不算一次到账：清掉读数基线后重记，后面量的「+3」不混进这 4 张。
	main._hud_seen.clear()
	main._update_hud()

func _set_count(state: GameState, seat: String, res: String, count: int) -> void:
	var unit := CardDB.unit_id(res)
	state.players[seat]["cards"] = state.players[seat]["cards"].filter(func(card): return card["def_id"] != unit)
	for i in count:
		state.add_card(seat, unit)

func _preview_page() -> void:
	print("--- 动画预览：牌桌特效页 ---")
	var preview: Node = load("res://scenes/animation_preview.tscn").instantiate()
	root.add_child(preview)
	await physics_frame
	preview.set_page(preview.FX_PAGE)
	check(preview._fx_controls.visible and not preview._list.visible and is_instance_valid(preview._fx_root),
		"特效页显示演出按钮并摆好背景牌")
	var core: CardEntity = preview._fx_cards("yunketang")[0] if not preview._fx_cards("yunketang").is_empty() else null
	preview.play_fx("cash")
	check(core != null and core.stamp_showing() and core.stamp_text() == ComicFx.stamp_text("cash"),
		"「产出资金」在台面那张生产牌上盖「到账」")
	var targets: Array = preview._fx_cards(CardDB.unit_id(CardDB.RES_USER))
	preview.play_fx("hit")
	await create_timer(CardMotion.BATCH_DURATION + 0.6).timeout
	var restocked: Array = preview._fx_cards(CardDB.unit_id(CardDB.RES_USER))
	check(targets.all(func(card): return not is_instance_valid(card) or card._visual_retired)
		and not restocked.is_empty() and not restocked.any(func(card): return targets.has(card)),
		"「撕掉用户」真的撕掉台面那叠用户牌，撕完再补一张")
	for demo in preview.FX_DEMOS:
		preview.play_fx(str(demo[0]))
		for i in 3:
			await process_frame
	check(not preview._fx_result.is_empty() and preview._fx_result["panel"].find_child("ResultStamp", true, false) != null,
		"终局按钮弹出正式结果面板")
	await create_timer(1.5).timeout
	preview.reset_fx()
	check(preview._fx_result.is_empty(), "清空桌面同时关掉结果面板")
	preview.set_page(0)
	check(preview._fx_root == null and preview._camera.h_offset == 0.0, "离开特效页清掉特效并让镜头回正")
	preview.queue_free()
	await process_frame
