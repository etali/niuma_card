# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

class CountingState extends GameState:
	var lookups := 0
	func find_card(who: String, uid: int) -> Dictionary:
		lookups += 1
		return super.find_card(who, uid)

class CountingScene extends "res://scenes/main.gd":
	var evaluations := 0
	func _cache_group_shields(group: Dictionary, records: Dictionary, grouped: Dictionary) -> void:
		evaluations += 1
		super._cache_group_shields(group, records, grouped)

func _initialize() -> void:
	CardDB.ensure_loaded()
	# 不建渲染场景，直接量业务计算次数：判据不依赖机器速度或测试并发负载。
	var main := CountingScene.new()
	main.board = Board.new()
	main.add_child(main.board)
	var state := CountingState.new()
	state.new_game()
	state.players[GameState.PLAYER]["cards"].clear()
	main.state = state
	var cards: Array = []
	for i in 100:
		var record := state.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_USER))
		var card := CardEntity.new()
		card.uid = record["uid"]
		card.def_id = record["def_id"]
		card.draggable = true
		main.add_child(card)
		main.entities[card.uid] = card
		cards.append(card)
	main.board.groups.append({"cards": cards})
	state.lookups = 0
	main._refresh_shields()
	check(main.evaluations == 1, "100张用户的一摞只评估一次，未按每张牌重算整摞")
	check(state.lookups < 200, "组装护盾查询使用UID索引，不逐卡扫描全手牌")
	for i in 10:
		main._refresh_shields()
	check(main.evaluations == 1, "局面没变时连续十帧复用护盾结果")
	cards.pop_back()
	main._refresh_shields()
	check(main.evaluations == 2, "牌摞成员变化立即使缓存失效")
	state.players[GameState.PLAYER]["cards"].pop_back()
	main._refresh_shields()
	check(main.evaluations == 3, "权威卡牌变化立即使缓存失效")
	state.combos.append({"owner": GameState.PLAYER, "uids": [cards[0].uid]})
	main._refresh_shields()
	check(not cards[0]._shield_on, "只有布局信息、缺少eval的占位组不产生护盾")
	main.free()
	finish()
