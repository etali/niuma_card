# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

func _initialize() -> void:
	OnWorkCardDB.ensure_loaded()
	for use_cfg in [false, true]:
		var s := _table()
		var cfgs := {}
		if use_cfg:
			cfgs[OnWorkState.PLAYER] = OnWorkBOTSearch.from_strength(1.0)
		print("\n=== cfgs %s ===" % ("满档" if use_cfg else "空（=权重表）"))
		print("行动次序 %s" % [s.action_order()])
		var before: Array = []
		for c in s.combos:
			before.append("%s:%d" % [c["eval"].get("leader", ""), c["uids"].size()])
		print("结算前的组 %s" % [before])
		OnWorkSettle.run(s, cfgs)
		# finalize 清了 combos，所以看牌面：哪个产品卡的用户卡少了
		var left := {}
		for c in s.players[OnWorkState.BOT]["cards"]:
			var d: Dictionary = OnWorkCardDB.get_def(c["def_id"])
			left[c["def_id"]] = int(left.get(c["def_id"], 0)) + 1
		print("BOT 牌面 %s" % [left])
		print("BOT 现金 %d 用户 %d" % [
			s.resource_count(OnWorkState.BOT, OnWorkCardDB.RES_CASH),
			s.resource_count(OnWorkState.BOT, OnWorkCardDB.RES_USER)])
		for line in s.log:
			if "点选" in str(line) or "攻击" in str(line) or "组合" in str(line):
				print("   | %s" % line)
	quit()

func _table() -> OnWorkState:
	var s := OnWorkState.new()
	s.set_seed(1)
	s.players = {
		OnWorkState.PLAYER: { "cards": [] },
		OnWorkState.BOT: { "cards": [] },
	}
	s.draw_first = OnWorkState.PLAYER
	for i in 5:
		s.add_card(OnWorkState.PLAYER, OnWorkCardDB.RES_CASH)
		s.add_card(OnWorkState.BOT, OnWorkCardDB.RES_CASH)
	# PLAYER 的攻击组：差评轰炸（配方 3 用户，出 2 点用户攻击）
	var atk := "chaping"
	var need := int(OnWorkCardDB.get_def(atk).get("recipe_n", 0))
	var ids: Array = [s.add_card(OnWorkState.PLAYER, atk)["uid"]]
	for i in need:
		ids.append(s.add_card(OnWorkState.PLAYER, OnWorkCardDB.RES_USER)["uid"])
	# 多给几张，免得 PLAYER 用户归零判负
	for i in 3:
		s.add_card(OnWorkState.PLAYER, OnWorkCardDB.RES_USER)
	var r := s.create_combo(OnWorkState.PLAYER, ids)
	print("PLAYER 攻击组 ok=%s type=%s attack=%s×%d" % [r.get("ok", false),
		(r.get("eval", {}) as Dictionary).get("type", "?"),
		(r.get("eval", {}) as Dictionary).get("attack_res", "?"),
		int((r.get("eval", {}) as Dictionary).get("attack_n", 0))])
	for id in ["shuabuting", "xinxijianfang"]:
		var g: Array = [s.add_card(OnWorkState.BOT, id)["uid"]]
		for i in int(OnWorkCardDB.get_def(id).get("recipe_n", 0)):
			g.append(s.add_card(OnWorkState.BOT, OnWorkCardDB.RES_USER)["uid"])
		s.create_combo(OnWorkState.BOT, g)
	return s
