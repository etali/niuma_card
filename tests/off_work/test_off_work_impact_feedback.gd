# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

## 清掉工作和人员升级要「有分量」：
## 清掉工作时，牌摞看得见的每一层都被撑开再弹回（一批越大越重），旁边的数量跳一下，
## 本方的镜头轻轻一震；升级的牌被抛起来转一圈再拍回桌上，落地那一刻才盖新头衔的章，
## 周围的牌摞被震得一跳。动的只有牌面，牌的位置、牌摞的排布都不变；不往桌上添东西。
const ComicFx = preload("res://scenes/comic_fx.gd")
var state: OffWorkState
var board: OffWorkBoard
var host: Node3D
var camera: Camera3D

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	await _cleared_pile_takes_the_hit()
	await _bigger_batches_hit_harder()
	await _promotion_leaps_and_lands()
	await _buried_or_held_cards_stay_put()
	_sound_and_config()
	await _dispose()
	finish()

func _fixture(groups: Array) -> void:
	await _dispose()
	var config := OffWorkConfig.new()
	config.rules.initial.groups = groups
	config.rules.initial.money = 0
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
	camera = Camera3D.new()
	host.add_child(camera)
	camera.position = Vector3(0, 25, 12)
	camera.look_at(Vector3.ZERO)
	board.setup(camera, true)
	board.sync_state(state)
	_settle()

func _dispose() -> void:
	if is_instance_valid(host):
		host.queue_free()
		await process_frame
	host = null
	board = null

func _settle() -> void:
	for presenter in [board, board.enemy_board]:
		for item in presenter._move_tw.values():
			if item.tw != null and item.tw.is_valid():
				item.tw.pause()
				item.tw.custom_step(1.0)

func _spec() -> Dictionary:
	return OffWorkUI.section("clear_feedback")

func _owned(owner: int, kind: String) -> Array:
	return state._owner_type(owner, kind)

func _drawn(owner: int, kind: String) -> Array:
	return _owned(owner, kind).map(func(id): return board.by_uid[id]).filter(func(card): return not board._stack_occluded.has(card.uid))

## Advances only the faces' own emphasis tweens.
func _step(cards: Array, seconds: float) -> void:
	for card in cards:
		if card._drag_visual_tween != null and card._drag_visual_tween.is_valid(): card._drag_visual_tween.custom_step(seconds)

func _present() -> Array:
	var events: Array = state.drain_events()
	board.sync_state(state)
	for event in events: board.play_event(event)
	return events

func _cleared_pile_takes_the_hit() -> void:
	await _fixture([{"work": 40, "employee": 1}])
	var mine: int = int(state.cards[_owned(0, "work")[0]].group)
	var layers: Array = _drawn(0, "work")
	var before := state.work_count(0)
	state.drain_events()
	state.advance(10.5)
	var events := _present()
	var cleared: Array = events.filter(func(event): return event.kind == "work_complete" and int(event.owner) == 0)
	check(cleared.size() == 1 and state.work_count(0) < before, "夹具：本方清掉了一批工作")
	layers = layers.filter(func(card): return is_instance_valid(card) and board.by_uid.has(card.uid))
	# The pile closes the gap its cleared sheets left; that is its ordinary layout, done first.
	_settle()
	var places := {}
	for card in layers: places[card.uid] = card.global_position
	check(layers.size() >= 2 and layers.all(func(card): return card._drag_visual_tween != null and card._drag_visual_tween.is_valid()),
		"牌摞看得见的每一层都挨了这一下（%d 层）" % layers.size())
	var top: OffWorkCard = layers.reduce(func(a, b): return a if a.global_position.y > b.global_position.y else b)
	var bottom: OffWorkCard = layers.reduce(func(a, b): return a if a.global_position.y < b.global_position.y else b)
	_step(layers, float(_spec().thump_in_seconds))
	var strength := OffWorkBoard.clear_strength((cleared[0].ids as Array).size())
	check(top._visual.scale.x > 1.0 + float(_spec().thump_scale) * strength * 0.9 and is_equal_approx(top._visual.scale.y, 1.0) and top._visual.position.y > 0.0,
		"最上面一层先被撑开、抬起（%.3f）" % top._visual.scale.x)
	check(bottom._visual.scale.x < top._visual.scale.x, "下面的层一层比一层晚：这一下是从上往下传的")
	check(layers.all(func(card): return card.global_position.is_equal_approx(places[card.uid])), "动的只是牌面；每张牌的位置和牌摞的排布都没变")
	_step(layers, 1.0)
	check(layers.all(func(card): return card._visual.scale.is_equal_approx(Vector3.ONE) and card._visual.position.is_equal_approx(Vector3.ZERO)),
		"弹回之后牌面恢复原样，不留下放大或抬起")
	check(camera.has_meta("fx_shake") or UIConfig.get_screen_shake() <= 0.0, "本方清掉工作，镜头轻轻一震（受「画面震动」设置控制）")
	# The count beside the pile takes the hit too.
	var group: Dictionary = board.group_of(board.by_uid[_owned(0, "work")[0]])
	var punched: Array = (group.side as Array).filter(func(node): return node is Label3D and node.scale.x > 1.2)
	check(punched.size() == 1 and str(punched[0].text).begins_with("×"), "旁边的工作数量跳大了一下再落回（人员那一行不跳）")
	check(mine == int(state.cards[_owned(0, "work")[0]].group), "夹具：还是那一组")
	# The opponent's pile shows the same hit, without the knock to the local view.
	if camera.has_meta("fx_shake"): camera.get_meta("fx_shake").kill()
	camera.remove_meta("fx_shake")
	var foe_events: Array = events.filter(func(event): return event.kind == "work_complete" and int(event.owner) == 1)
	check(not foe_events.is_empty(), "夹具：对手同时也清掉了一批")
	var foe_layers: Array = _drawn(1, "work")
	board.play_event(foe_events[0])
	check(foe_layers.any(func(card): return card._drag_visual_tween != null and card._drag_visual_tween.is_valid()) and not camera.has_meta("fx_shake"),
		"对手清掉工作，对手的牌摞同样挨一下，但本方的镜头不震")

func _bigger_batches_hit_harder() -> void:
	var one := OffWorkBoard.clear_strength(1)
	var ten := OffWorkBoard.clear_strength(10)
	var thousand := OffWorkBoard.clear_strength(1000)
	check(is_equal_approx(one, 1.0) and ten > one and thousand >= ten, "一批越大力度越大（1 份 %.2f，10 份 %.2f）" % [one, ten])
	check(is_equal_approx(thousand, float(_spec().strength_max)), "力度有上限，再大的批次也不会把牌撑到离谱")
	check(1.0 + float(_spec().thump_scale) * float(_spec().strength_max) <= 1.3, "最重的一下也只把牌面撑大三成以内")
	check(float(_spec().thump_in_seconds) + float(_spec().thump_out_seconds) <= 0.4, "一下的全程不超过 0.4 秒，赶得上连续结算")

func _promotion_leaps_and_lands() -> void:
	await _fixture([{"employee": 1, "coffee": 1}, {"work": 30, "employee": 1}])
	var upgrade := OffWorkUI.section("upgrade")
	var person: int = _owned(0, "employee").filter(func(id): return state.group_cards(int(state.cards[id].group)).any(func(other): return state.cards[other].type == "coffee"))[0]
	var card: OffWorkCard = board.by_uid[person]
	var place := card.global_position
	var neighbours: Array = _drawn(0, "work")
	state.drain_events()
	state.advance(float(state.config.rules.coffee.seconds) + 0.2)
	var events := _present()
	check(events.any(func(event): return event.kind == "coffee_upgrade" and int(event.person) == person) and str(state.cards[person].type) != "employee",
		"夹具：这名员工升级了")
	var landed: Array = []
	board.upgrade_landed.connect(func(id): landed.append(id))
	check(card.is_upgrade_leaping() and not card.stamp_showing(), "升级的牌先被抛起来；章不在半空中盖")
	var total := float(upgrade.leap_seconds) + float(upgrade.slam_seconds)
	_step([card], float(upgrade.leap_seconds))
	check(card._visual.position.y > float(upgrade.leap_height) * 0.9 and absf(card._visual.rotation.y) > 0.5, "到最高点时离桌面约 %.2f，并且正在转" % card._visual.position.y)
	check(card.global_position.is_equal_approx(place), "抛起来的是牌面；牌在牌桌上的位置没有动")
	check(landed.is_empty() and not card.stamp_showing(), "还没落地：没有章，也没有震")
	_step([card], float(upgrade.slam_seconds) + 0.001)
	check(not card.is_upgrade_leaping() and card._visual.position.is_equal_approx(Vector3.ZERO) and card._visual.rotation.is_equal_approx(Vector3.ZERO),
		"转满 %d 圈，正着拍回桌面" % int(upgrade.spin_turns))
	check(card.stamp_showing() and card.stamp_text() == str(card.definition.name), "落地的那一刻盖上新头衔「%s」" % card.stamp_text())
	check(card._visual.scale.x > 1.0 + float(upgrade.squash) * 0.5 and landed == [person], "落地时牌面被拍得撑开，并通知一次（配落地声）")
	check(total <= 0.4, "从升级到落地盖章不超过 0.4 秒（%.2f）" % total)
	check(camera.has_meta("fx_shake") or UIConfig.get_screen_shake() <= 0.0, "本方升级，落地时镜头一震")
	check(neighbours.any(func(other): return other._drag_visual_tween != null and other._drag_visual_tween.is_valid()),
		"落地把周围的牌摞震得一跳：用的是桌上真实的牌，没有另画一圈东西")
	_step([card], 1.0)
	check(card._visual.scale.is_equal_approx(Vector3.ONE), "弹回原大小")
	check(float(upgrade.stamp_seconds) >= 1.0, "章停留一秒以上，看得清升成了什么")
	# The top of the ladder lands harder.
	check(float(upgrade.shake_top) > float(upgrade.shake) and float(upgrade.shake) > float(_spec().shake_max), "升级比清工作震得重，升到顶级最重")

func _buried_or_held_cards_stay_put() -> void:
	await _fixture([{"employee": 3, "coffee": 3}, {"work": 30, "employee": 1}])
	var people: Array = _owned(0, "employee").filter(func(id): return state.group_cards(int(state.cards[id].group)).any(func(other): return state.cards[other].type == "coffee"))
	var held: OffWorkCard = board.by_uid[people[0]]
	held.dragging = true
	held.play_upgrade()
	check(not held.is_upgrade_leaping() and held.stamp_showing() and held._visual.position.is_equal_approx(Vector3.ZERO),
		"手里拿着的牌不被抛走：原地盖章")
	held.dragging = false
	held.thump(2.0)
	var hovered: OffWorkCard = board.by_uid[people[1]]
	hovered._visual_hovered = true
	hovered.thump(2.0)
	check(hovered._drag_visual_tween == null or not hovered._drag_visual_tween.is_valid(), "指针正停在上面的牌不被这一下打断")
	hovered._visual_hovered = false
	# Several people promoted by one batch take off one after another.
	state.drain_events()
	state.advance(float(state.config.rules.coffee.seconds) * 4.0 + 0.2)
	var events := _present()
	var promoted: Array = events.filter(func(event): return event.kind == "coffee_upgrade").map(func(event): return int(event.person))
	var leaping: Array = promoted.map(func(id): return board.by_uid[id]).filter(func(card): return card.is_upgrade_leaping())
	if leaping.size() >= 2:
		_step(leaping, float(OffWorkUI.section("upgrade").wave_stagger_seconds) * 0.5)
		var heights: Array = leaping.map(func(card): return card._visual.position.y)
		check(heights.max() > 0.0 and heights.min() < heights.max(), "同一批升级的几个人依次起跳，不是糊成一团")
		# The first to land bumps the pile; whoever is still in the air must come down all the same.
		for card in leaping: _step([card], 1.0)
		check(leaping.all(func(card): return not card.is_upgrade_leaping() and card.stamp_showing() and card._visual.position.is_equal_approx(Vector3.ZERO)),
			"先落地的人震到牌摞时，还在空中的人不被打断：每个人都落回桌面、盖上章")
	else:
		check(promoted.size() >= 1, "夹具：这一批至少升级了一个人")

func _sound_and_config() -> void:
	var actions: Dictionary = UIConfig.read_section("presentation").audio.actions
	check(str(actions.coffee_upgrade.file) == "upgrade.wav" and FileAccess.file_exists("res://assets/sfx/upgrade.wav"), "升级用升级的那一声，不再是普通的完成音")
	check(actions.has("upgrade_land") and FileAccess.file_exists("res://assets/sfx/" + str(actions.upgrade_land.file)), "落地另有一声低沉的落章")
	check(float(actions.work_complete.db) >= -13.0, "清掉工作的落章声比原来响（%.0f dB）" % float(actions.work_complete.db))
	check(float(_spec().sound_db_per_doubling) > 0.0 and float(_spec().sound_pitch_per_doubling) < 0.0, "一批越大，落章声越响、越沉")
	var paper: Dictionary = UIConfig.read_section("board").paper_disposal
	check(float(paper.ball_size) >= 0.24 and float(paper.throw_distance) >= 5.0, "纸团更大、扔得更远")
