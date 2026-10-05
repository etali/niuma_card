# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

func _initialize() -> void:
	CardDB.ensure_loaded()
	for use_cfg in [false, true]:
		var s := _table()
		var cfgs := {}
		if use_cfg:
			cfgs[GameState.PLAYER] = BOTSearch.from_strength(1.0)
		print("\n=== cfgs %s ===" % ("满档" if use_cfg else "空（=权重表）"))
		print("行动次序 %s" % [s.action_order()])
		var before: Array = []
		for c in s.combos:
			before.append("%s:%d" % [c["eval"].get("leader", ""), c["uids"].size()])
		print("结算前的组 %s" % [before])
		Settle.run(s, cfgs)
		# finalize 清了 combos，所以看牌面：哪个产品卡的用户卡少了
		var left := {}
		for c in s.players[GameState.BOT]["cards"]:
			var d: Dictionary = CardDB.get_def(c["def_id"])
			left[c["def_id"]] = int(left.get(c["def_id"], 0)) + 1
		print("BOT 牌面 %s" % [left])
		print("BOT 现金 %d 用户 %d" % [
			s.resource_count(GameState.BOT, CardDB.RES_CASH),
			s.resource_count(GameState.BOT, CardDB.RES_USER)])
		for line in s.log:
			if "点选" in str(line) or "攻击" in str(line) or "组合" in str(line):
				print("   | %s" % line)
	quit()

func _table() -> GameState:
	var s := GameState.new()
	s.set_seed(1)
	s.players = {
		GameState.PLAYER: { "cards": [] },
		GameState.BOT: { "cards": [] },
	}
	s.draw_first = GameState.PLAYER
	for i in 5:
		s.add_card(GameState.PLAYER, CardDB.RES_CASH)
		s.add_card(GameState.BOT, CardDB.RES_CASH)
	# PLAYER 的攻击组：差评轰炸（配方 3 用户，出 2 点用户攻击）
	var atk := "chaping"
	var need := int(CardDB.get_def(atk).get("recipe_n", 0))
	var ids: Array = [s.add_card(GameState.PLAYER, atk)["uid"]]
	for i in need:
		ids.append(s.add_card(GameState.PLAYER, CardDB.RES_USER)["uid"])
	# 多给几张，免得 PLAYER 用户归零判负
	for i in 3:
		s.add_card(GameState.PLAYER, CardDB.RES_USER)
	var r := s.create_combo(GameState.PLAYER, ids)
	print("PLAYER 攻击组 ok=%s type=%s attack=%s×%d" % [r.get("ok", false),
		(r.get("eval", {}) as Dictionary).get("type", "?"),
		(r.get("eval", {}) as Dictionary).get("attack_res", "?"),
		int((r.get("eval", {}) as Dictionary).get("attack_n", 0))])
	for id in ["shuabuting", "xinxijianfang"]:
		var g: Array = [s.add_card(GameState.BOT, id)["uid"]]
		for i in int(CardDB.get_def(id).get("recipe_n", 0)):
			g.append(s.add_card(GameState.BOT, CardDB.RES_USER)["uid"])
		s.create_combo(GameState.BOT, g)
	return s
