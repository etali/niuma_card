# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/support/drawer_fixture.gd"

## 攻击瞄准：点数只写在一张便签上；对手点不了的牌压暗；瞄着一摞时，便签和桌面
## 预告这一下会撕哪几张、剩多少点、会不会让整组作废或终结对手。
## 预告是在局面副本上按真实规则试算的，所以必须和随后真点下去的结果一张不差。
const RED := Color(1.5, 0.55, 0.45)
var main: Node
var state: OnWorkState

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 上班攻击瞄准 ===")
	main = await boot_main()
	if not need(main != null and main.state != null, "主场景可启动"):
		finish()
		return
	main.sfx.set_muted(true)
	# 瞄准由测试给出指针位置，不读无头环境里的真实鼠标。
	main.set_process(false)
	state = main.state
	await _one_readout()
	await _marks_and_preview()
	await _lock_and_finish()
	await _foe_hit_lights_up()
	main.queue_free()
	await physics_frame
	await _compact_piles()
	finish()

## 抽屉布局里对手的摞是收拢的：看不见里面的牌，这一下会少几张写在侧边清单上。
func _compact_piles() -> void:
	main = await boot_drawer(Vector2i(1280, 800), 1.0, true)
	if not need(main != null and main.drawer_presentation != null and main.state != null, "主场景以抽屉布局启动"): return
	main.drawer_presentation._learning_invitation.hide()
	main.sfx.set_muted(true)
	main.set_process(false)
	state = main.state
	var foe: String = main.foe_seat
	var seats := int(OnWorkCardDB.get_def("shuabuting")["recipe_n"])
	var uids: Array = [int(state.add_card(foe, "shuabuting", true)["uid"])]
	# 两张富余：头两点打不破这一组。
	for i in seats + 2: uids.append(int(state.add_card(foe, "user", true)["uid"]))
	check(state.create_combo(foe, uids)["ok"], "对手编成一个带两张富余的组合")
	await _arm(0, 2)
	var key := _pile_key(uids)
	if not need(key != "" and bool(main.layout._bot_pile_compact.get(key, false)), "这一摞是收拢的"): return
	var top: CardEntity = main.entities[main.layout._bot_pile_uids[key][0]]
	check(main._attack_hl.has(top), "收拢的摞只点亮摞顶")
	var cash: Array = _foe_cards().filter(func(card): return card.def_id == "cash")
	check(not cash.is_empty() and cash.all(func(card): return card._dimmed), "没有现金点：对手的现金整摞压暗")
	var labels: Array = main.board.side_nodes_of(key).filter(func(node): return node is Label3D)
	var users := "×%d" % (seats + 2)
	check(labels.any(func(label): return label.text == users), "侧边清单原来写着 %s" % users)
	main._attack_aim = main._table_actions.preview_attack(key, main._attack_pools)
	main._refresh_attack_targets()
	main._refresh_attack_panel()
	check(main._attack_aim.uids.size() == 2 and not main._attack_aim.voids, "两点打掉两张，富余顶上，这一组不作废")
	check(not main.attack_target_text.text.contains("整组作废") and main.attack_target_text.text.contains("撕 2 张"), "便签不预告作废：%s" % main.attack_target_text.text)
	var marked: Array = labels.filter(func(label): return label.text == users + " -2")
	check(marked.size() == 1 and marked[0].modulate.is_equal_approx(Palette.semantic("danger")),
		"瞄着它：清单的用户那一行写成「%s -2」，用危险色" % users)
	check(labels.filter(func(label): return label.text.contains("-")).size() == 1, "别的行不动")
	var area: Rect2 = main.drawer_presentation.content_rect()
	await process_frame
	var note: Rect2 = main.attack_panel.get_global_rect()
	check(note.get_center().y > area.get_center().y and note.end.y <= area.end.y + 1.0 and note.size.y >= 52.0 * main.drawer_presentation._responsive_factor() - 1.0,
		"抽屉布局：便签按界面缩放，贴在我这一侧的桌沿，不被顶栏盖住")
	main._attack_aim = {}
	main._refresh_attack_targets()
	check(labels.all(func(label): return not is_instance_valid(label) or not label.text.contains("-")), "移开后清单恢复原样")
	main._clear_attack_hl()
	main.queue_free()
	await physics_frame

func _foe_cards() -> Array:
	var out: Array = []
	for record in state.players[main.foe_seat]["cards"]:
		if main.entities.has(record["uid"]) and is_instance_valid(main.entities[record["uid"]]): out.append(main.entities[record["uid"]])
	return out

func _pile_key(uids: Array) -> String:
	for uid in uids:
		var key := str(main.layout._bot_pile_of_uid.get(uid, ""))
		if key != "": return key
	return ""

## 给对手编一个组合：核心 + 配方要的用户，再把攻击阶段摆好。
func _arm(cash_points: int, user_points: int) -> void:
	main._sync_entities()
	main.layout._layout_bot_zone()
	await settle()
	await main._tears_drained()
	main.pipe.applier().seed_pool_for_test(main.my_seat, cash_points, user_points)
	main.phase = main.PHASE_ATTACK
	main.board.attack_mode = true
	main._show_attack_label(main.TXT_ATTACK_MINE, true)
	main._attack_aim = {}
	main._refresh_attack_targets()
	main._refresh_attack_panel()

func _aim(card: CardEntity) -> void:
	main._aim_attack_at(main.board.camera.unproject_position(card.global_position + Vector3(0, CardEntity.Y_TEXT, 0)))
	main._refresh_attack_panel()

func _aim_nothing() -> void:
	main._aim_attack_at(Vector2(-200, -200))
	main._refresh_attack_panel()

func _one_readout() -> void:
	check(not ("lbl_attack" in main), "跟着鼠标的那行大字已经删掉，点数只有便签一处")
	main.phase = main.PHASE_ATTACK
	main.board.attack_mode = false
	main._show_attack_label(main.TXT_ATTACK_FOE, false, {OnWorkCardDB.RES_CASH: 2, OnWorkCardDB.RES_USER: 1})
	check(main.attack_panel.visible and main.attack_title.text == main.TXT_ATTACK_FOE,
		"对手攻击时便签照样在，写着是谁的攻击")
	check(main.attack_pool_text.text == "现金攻击 2    用户攻击 1" and main.attack_target_text.text == "对手正在选择目标",
		"便签上写的是对手的点数")
	main._refresh_attack_panel()
	check(main.attack_panel.visible, "每帧刷新不会把对手的便签收走")
	# 便签贴在出手一方的桌沿：对手攻击在上沿，我攻击在下沿，不盖住正被瞄准的那一侧。
	var area: Rect2 = main.table_content_rect()
	if area.has_area():
		await process_frame
		var foe_rect: Rect2 = main.attack_panel.get_global_rect()
		check(foe_rect.get_center().y < area.get_center().y and foe_rect.position.y >= area.position.y,
			"对手攻击：便签贴在他那一侧的桌沿（上沿）")
		check(absf(foe_rect.get_center().x - main.get_viewport().get_visible_rect().size.x * 0.5) < 2.0, "便签左右居中")
		main.board.attack_mode = true
		main._show_attack_label(main.TXT_ATTACK_MINE, true)
		await process_frame
		var my_rect: Rect2 = main.attack_panel.get_global_rect()
		check(my_rect.get_center().y > area.get_center().y and my_rect.end.y <= area.end.y + 1.0,
			"我攻击：便签贴在我这一侧的桌沿（下沿）")
		check(main.attack_title.text == main.TXT_ATTACK_MINE, "便签写着是我的攻击")
		main.board.attack_mode = false
	main._hide_attack_label()
	main._refresh_attack_panel()
	check(not main.attack_panel.visible, "攻击结束便签收起")
	main.phase = main.PHASE_ACTION

func _marks_and_preview() -> void:
	var foe: String = main.foe_seat
	var seats := int(OnWorkCardDB.get_def("shuabuting")["recipe_n"])
	var uids: Array = [int(state.add_card(foe, "shuabuting", true)["uid"])]
	for i in seats: uids.append(int(state.add_card(foe, "user", true)["uid"]))
	check(state.create_combo(foe, uids)["ok"], "对手编成一个 %d 席的组合" % seats)
	# 用户点比席位少一点：这一下撕不完，但第一张就让整组作废。
	await _arm(3, seats - 1)
	var key := _pile_key(uids)
	if not need(key != "", "找得到对手那一摞组合"): return
	var compact: bool = bool(main.layout._bot_pile_compact.get(key, true))
	var lit: Array = main._attack_hl
	var cards := _foe_cards()
	check(not lit.is_empty() and lit.all(func(card): return card.highlighted and card._hl_color.is_equal_approx(RED)), "点得起的靶是红的")
	var covered := true
	for card in cards:
		var pile := str(main.layout._bot_pile_of_uid.get(card.uid, ""))
		var top_lit: bool = pile != "" and lit.any(func(other): return str(main.layout._bot_pile_of_uid.get(other.uid, "")) == pile)
		covered = covered and (lit.has(card) or top_lit or card._dimmed)
		if card._dimmed: check(not card.highlighted, "压暗的牌不同时是红的（%s）" % card.def_id)
	check(covered, "对手的每张牌要么是靶、要么在点得动的摞里、要么被压暗")
	var core: CardEntity = main.entities[uids[0]]
	check(not lit.has(core) or compact, "核心卡不是靶：摊开时不亮")
	if not compact: check(core._dimmed, "摊开的组合里，点不了的核心卡被压暗")
	for record in state.players[main.my_seat]["cards"]:
		if main.entities.has(record["uid"]): check(not main.entities[record["uid"]]._dimmed, "自己的牌不压暗")
	check(main.attack_target_text.text.contains("可攻击目标"), "没瞄着谁时便签写可攻击目标数")

	# 试算：这一摞点下去会怎样。
	var pools: Dictionary = main._attack_pools.duplicate(true)
	var preview: Dictionary = main._table_actions.preview_attack(key, pools)
	check(preview.uids.size() == seats - 1 and int(preview[OnWorkCardDB.RES_USER]) == seats - 1 and int(preview[OnWorkCardDB.RES_CASH]) == 0,
		"试算：%d 点用户攻击撕 %d 张用户" % [seats - 1, seats - 1])
	check(int(preview.pools[OnWorkCardDB.RES_USER]) == 0 and int(preview.pools[OnWorkCardDB.RES_CASH]) == 3, "试算给出打完剩下的点数")
	check(preview.voids and not preview.finishes, "试算知道这一下让整组作废，但不终结对手")
	check(main._attack_pools == pools and state.find_card(foe, uids[1]).size() > 0 and state.combo_intact(foe, state.combos.filter(func(combo): return combo["uids"].has(uids[0]))[0]),
		"试算不动真实的点数和局面")

	# 瞄上去：便签和桌面一起预告。
	var top: CardEntity = main.entities[main.layout._bot_pile_uids[key][0]]
	_aim(top)
	check(str(main._attack_aim.get("aim", "")) == key and main._attack_aim.uids == preview.uids, "指针停在这一摞上：瞄准的就是它")
	var text: String = main.attack_target_text.text
	check(text.contains("撕 %d 张" % (seats - 1)) and text.contains("用户攻击 0") and text.contains("现金攻击 3"), "便签写这一下撕几张、剩多少点：%s" % text)
	check(text.contains("整组作废"), "便签预告整组会作废")
	if compact:
		var nodes: Array = main.board.side_nodes_of(key)
		var marked: Array = nodes.filter(func(node): return node is Label3D and node.text == "×%d -%d" % [seats, seats - 1])
		check(marked.size() == 1 and marked[0].modulate.is_equal_approx(Palette.semantic("danger")),
			"收拢的摞：侧边清单的用户那一行写成「×%d -%d」，用危险色" % [seats, seats - 1])
	else:
		var torn_lit: bool = preview.uids.all(func(uid): return main._attack_hl.has(main.entities[uid]))
		var spared: Array = uids.slice(1).filter(func(uid): return not preview.uids.has(uid))
		check(torn_lit and spared.all(func(uid): return not main.entities[uid].highlighted and main.entities[uid]._dimmed),
			"摊开的摞：只有这一下会撕的那几张是红的，轮不到的那一张压暗")
	_aim_nothing()
	check(main._attack_aim.is_empty() and main.attack_target_text.text.contains("可攻击目标"), "指针移开：便签回到可攻击目标数")
	if compact:
		check(main.board.side_nodes_of(key).all(func(node): return not (node is Label3D) or not node.text.contains("-")), "指针移开：侧边清单恢复原样")

	# 真点下去：结果必须和预告一张不差。
	_aim(top)
	await main._attack_pile(key)
	var gone: Array = uids.filter(func(uid): return state.find_card(foe, uid).is_empty())
	gone.sort()
	var predicted: Array = preview.uids.duplicate()
	predicted.sort()
	check(gone == predicted, "真点下去撕掉的正是预告的那几张（%s）" % str(gone))
	check(int(main._attack_pools[OnWorkCardDB.RES_USER]) == int(preview.pools[OnWorkCardDB.RES_USER])
		and int(main._attack_pools[OnWorkCardDB.RES_CASH]) == int(preview.pools[OnWorkCardDB.RES_CASH]), "剩下的点数和预告一致")
	check(not state.combo_intact(foe, state.combos.filter(func(combo): return combo["uids"].has(uids[0]))[0]), "那一组确实作废了")
	main._clear_attack_hl()
	check(_foe_cards().all(func(card): return not card._dimmed and not card.highlighted), "撤掉标记后没有牌还红着或暗着")

func _lock_and_finish() -> void:
	var foe: String = main.foe_seat
	# 攻击锁：组合打到一半（只发一条意图），别处都点不了。
	var seats := int(OnWorkCardDB.get_def("shuabuting")["recipe_n"])
	var uids: Array = [int(state.add_card(foe, "shuabuting", true)["uid"])]
	for i in seats: uids.append(int(state.add_card(foe, "user", true)["uid"]))
	check(state.create_combo(foe, uids)["ok"], "对手再编一个组合")
	await _arm(2, seats)
	var first := {}
	for target in state.attack_targets(foe):
		if target["kind"] == "combo" and uids.has(target["uids"][0]):
			first = target
			break
	var result: Dictionary = await main.pipe.submit(OnWorkIntent.apply_attack(main.my_seat, first), main.my_seat)
	check(result.get("ok", false) and OnWorkState.attack_lock(main._attack_pools) != "", "打掉组合里的一张：攻击锁上了")
	main._sync_entities()
	main.layout._layout_bot_zone()
	await settle()
	await main._tears_drained()
	main._refresh_attack_targets()
	main._refresh_attack_panel()
	var name := OnWorkCardDB.card_name("shuabuting")
	check(main.attack_target_text.text.contains("得先打完手上这一组") and main.attack_target_text.text.contains(name),
		"便签写明得先打完这一组：%s" % main.attack_target_text.text)
	var key := _pile_key(uids)
	var elsewhere: Array = _foe_cards().filter(func(card): return str(main.layout._bot_pile_of_uid.get(card.uid, "")) != key)
	check(not elsewhere.is_empty() and elsewhere.all(func(card): return card._dimmed and not card.highlighted),
		"锁着的时候，别的摞（包括还有现金点可打的现金）全部压暗")
	# 瞄着被锁挡住的现金摞：试算知道这一下点不动。
	var cash_key := _pile_key(state.players[foe]["cards"].filter(func(card): return card["def_id"] == "cash").map(func(card): return card["uid"]))
	if cash_key != "":
		var blocked: Dictionary = main._table_actions.preview_attack(cash_key, main._attack_pools)
		check(blocked.uids.is_empty(), "试算也认攻击锁：别的摞现在点不动")
		main._attack_aim = blocked
		main._refresh_attack_panel()
		check(main.attack_target_text.text == "这一摞现在点不动", "便签照实说点不动")
	main._clear_attack_hl()

	# 终结：对手只剩两个用户，手上正好两点用户攻击。
	state.combos = state.combos.filter(func(combo): return combo["owner"] != foe)
	var kept := 0
	var cards: Array = []
	for card in state.players[foe]["cards"]:
		if card["def_id"] == "user":
			kept += 1
			if kept > 2: continue
		elif card["def_id"] != "cash": continue
		cards.append(card)
	state.players[foe]["cards"] = cards
	main._respawn_all()
	await _arm(0, 2)
	var user_key := _pile_key(state.players[foe]["cards"].filter(func(card): return card["def_id"] == "user").map(func(card): return card["uid"]))
	var aim: String = user_key if user_key != "" else "uid:%d" % int(state.players[foe]["cards"].filter(func(card): return card["def_id"] == "user")[0]["uid"])
	var ending: Dictionary = main._table_actions.preview_attack(aim, main._attack_pools)
	if user_key != "":
		check(ending.uids.size() == 2 and ending.finishes, "试算：这两点正好把对手的用户打光")
		main._attack_aim = ending
		main._refresh_attack_panel()
		check(main.attack_target_text.text.contains("这一下终结对手") and not main.attack_target_text.text.contains("整组作废"), "便签预告这一下终结对手")
		# 这一摞是收拢的：看不见里面的牌，会少几张写在侧边清单那一行上。
		main._refresh_attack_targets()
		var labels: Array = main.board.side_nodes_of(user_key).filter(func(node): return node is Label3D)
		if bool(main.layout._bot_pile_compact.get(user_key, true)) and not labels.is_empty():
			check(labels.any(func(label): return label.text == "×2 -2" and label.modulate.is_equal_approx(Palette.semantic("danger"))),
				"收拢的摞：侧边清单那一行写成「×2 -2」，用危险色（%s）" % str(labels.map(func(label): return label.text)))
			main._clear_attack_hl()
			check(labels.all(func(label): return not is_instance_valid(label) or label.text == "×2"), "撤掉标记后清单恢复「×2」")
	else:
		check(ending.uids.size() == 1 and not ending.finishes, "散卡一张就是一张：一下打不光")
	check(state.winner == "" and state.resource_count(foe, OnWorkCardDB.RES_USER) == 2, "试算没有真的结束这一局")
	main._clear_attack_hl()
	main._hide_attack_label()
	main.board.attack_mode = false
	main.phase = main.PHASE_ACTION

func _foe_hit_lights_up() -> void:
	# 对手（联网对手也走这一条）打中我的牌：牌先变红亮出来，这一批撕的时候才动。
	var mine: Array = state.players[main.my_seat]["cards"].filter(func(card): return card["def_id"] == "cash")
	if not need(mine.size() >= 2, "我有现金可挨打"): return
	var uid := int(mine[0]["uid"])
	var card: CardEntity = main.entities[uid]
	var target := {}
	for candidate in state.attack_targets(main.my_seat):
		if candidate["uids"].has(uid): target = candidate
	state.remove_card(main.my_seat, uid)
	main._render_foe_attack({"target": target, "removed": [uid]})
	check(is_instance_valid(card) and card.highlighted and card._hl_color.is_equal_approx(RED) and main._foe_tear_cards.has(card),
		"被对手打中的牌先亮成红色，还留在桌上")
	await main._flush_foe_attack()
	await main._tears_drained()
	check(not main.entities.has(uid), "这一批随后被撕掉")
