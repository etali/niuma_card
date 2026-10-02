# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Actions = preload("res://engine/ai_actions.gd")
const Env = preload("res://engine/ai_environment.gd")

## 资源不对称和防御规则（README.md §「2.6 组合与结算」 付款时机 + balance.md §「Buff 卡」 即时保护）
##
## 配方现金会被吃掉，用户不会（席位不是成本）
##   生产组合在 `Settle._resolve_combo` 自己结算那一刻付；
##   攻击组合在 `GameState.arm_attacks`（攻击阶段开场）付。
##   两处都带一条自尽护栏：付完 ≤ 0 就整组不生效 —— 否则「掏空自己开一炮」
##   会把清零即胜变成自杀键。
##
## 防御 Buff 加入有效组合当回合即保护；离组或配方不足时失效。
## 防御效果只覆盖配方额度，富余投料不受保护。
##
## 变异提示：
##   game_state.gd `_attack_recipe_payable` 去掉 `remove_card` 那一行
##       → test_attack_ammo_is_paid 红（弹药白拿）
##   game_state.gd `_attack_recipe_payable` 的 suicide 判据 `- need <= 0` 改成 `< 0`
##       → test_ammo_suicide_guard 红（掏空自己也开火）
##   settle.gd `_pay_recipe` 去掉扣款循环里的 `state.remove_card(owner, u)`
##       → test_production_cash_is_eaten 红（生产配方白吃）
##   combo_rules.gd 给用户配方也填 `recipe_pay_n`
##       → test_user_recipe_seats_survive 红（席位被当成成本吃掉）



func _initialize() -> void:
	print("=== 弹药自付 + 防御即时保护 测试 ===\n")
	test_attack_ammo_is_paid()
	test_ammo_suicide_guard()
	test_production_cash_is_eaten()
	test_user_recipe_seats_survive()
	test_buff_protects_immediately()
	test_protection_survives_recombo()
	test_protection_requires_valid_group()
	test_generated_attack_respects_ammo()
	test_generated_cash_recipe_replays()
	finish()


func _blank_state() -> GameState:
	var s := GameState.new()
	s.players = {
		GameState.PLAYER: { "cards": [] },
		GameState.AI: { "cards": [] },
	}
	s.draw_first = GameState.PLAYER
	return s

## 扫卡表挑一张「kind 对、配方吃 res」的卡，返回 def_id。
## 不写死 def_id：数值一轮一改，写死会让这个文件跟着 cards.json 漂。
## 挑 recipe_n 最小的那张：配方越小，测试要发的散现金越少，牌桌越好读
func _pick_by_recipe(kind: String, res: String) -> String:
	var best := ""
	var best_n := 999
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if d.get("kind") != kind or d.get("recipe_res") != res:
			continue
		var n := int(d.get("recipe_n", 0))
		if n >= 1 and n < best_n:
			best = def_id
			best_n = n
	return best

## 扫当前卡表寻找现金保护 Buff。
func _protect_cash_buff() -> String:
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if d.get("kind") == CardDB.KIND_BUFF and d.get("buff_type") == "protect_cash":
			return def_id
	return ""


## 攻击组合的配方现金在 arm_attacks 时被真扣掉，而 attack_pool 只读、不花钱
func test_attack_ammo_is_paid() -> void:
	print("【1】攻击弹药在装弹时被扣掉；attack_pool 只读不扣")
	var def_id := _pick_by_recipe(CardDB.KIND_ATTACK, CardDB.RES_CASH)
	check(def_id != "", "卡表里有吃现金的攻击卡")
	var d: Dictionary = CardDB.get_def(def_id)
	var need := int(d["recipe_n"])

	var s := _blank_state()
	var core := s.add_card(GameState.PLAYER, def_id)
	var ammo: Array = []
	for i in need: ammo.append(s.add_card(GameState.PLAYER, "cash")["uid"])
	for i in 2: s.add_card(GameState.PLAYER, "cash")   # 散现金：付完还得剩
	var before := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	check(s.create_combo(GameState.PLAYER, [core["uid"]] + ammo)["ok"], "攻击组合编组成立")

	# 读两次点数池：一分钱都不该动（否则任何「显示一下点数」的调用都在偷偷收费）
	var peek1: Dictionary = s.attack_pool(GameState.PLAYER)
	var peek2: Dictionary = s.attack_pool(GameState.PLAYER)
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == before,
		"attack_pool 读两次不扣款（%d → %d）" % [
			before, s.resource_count(GameState.PLAYER, CardDB.RES_CASH)])
	check(peek1 == peek2, "两次读到同一个池子")
	check(int(peek1[d["attack_res"]]) == int(d["attack_n"]),
		"池子 = 卡面攻击量 %d" % int(d["attack_n"]))

	# 装弹：扣掉 need 张，池子不变
	var armed: Dictionary = s.arm_attacks(GameState.PLAYER)
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == before - need,
		"arm_attacks 扣掉配方那 %d 张现金（%d → %d）" % [
			need, before, s.resource_count(GameState.PLAYER, CardDB.RES_CASH)])
	check(int(armed[d["attack_res"]]) == int(d["attack_n"]),
		"付了钱的组合照常出 %d 点" % int(d["attack_n"]))
	var logged := false
	for e in s.log:
		if "装弹" in GameState.entry_text(e):
			logged = true
	check(logged, "战报有一条装弹记录")


## 付掉弹药会让资金归零 → 整组不开火（掏空自己开一炮不该是合法操作）
func test_ammo_suicide_guard() -> void:
	print("\n【2】付弹药会让资金归零 → 这回合不开火")
	var def_id := _pick_by_recipe(CardDB.KIND_ATTACK, CardDB.RES_CASH)
	var d: Dictionary = CardDB.get_def(def_id)
	var need := int(d["recipe_n"])

	var s := _blank_state()
	var core := s.add_card(GameState.PLAYER, def_id)
	var ammo: Array = []
	for i in need: ammo.append(s.add_card(GameState.PLAYER, "cash")["uid"])
	# 手里正好只有配方那几张：付完就是 0
	check(s.create_combo(GameState.PLAYER, [core["uid"]] + ammo)["ok"], "攻击组合编组成立")
	check(int(s.attack_pool(GameState.PLAYER)[d["attack_res"]]) == 0,
		"资金刚好等于配方量 → 池子读出来就是 0（付不起）")

	var pools: Dictionary = s.arm_attacks(GameState.PLAYER)
	check(int(pools[d["attack_res"]]) == 0, "装弹被护栏拦下，0 点")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == need,
		"钱一分没扣（不开火也就不付款）：仍为 %d" % s.resource_count(GameState.PLAYER, CardDB.RES_CASH))
	var hinted := false
	for e in s.log:
		if "归零" in GameState.entry_text(e):
			hinted = true
	check(hinted, "战报说清了「开火会让资金归零」")

	# 多一张散现金就付得起了：护栏卡的是「归零」，不是「有攻击组合」
	s.add_card(GameState.PLAYER, "cash")
	check(int(s.arm_attacks(GameState.PLAYER)[d["attack_res"]]) == int(d["attack_n"]),
		"多一张散现金 → 付得起，正常开火 %d 点" % int(d["attack_n"]))


## 生产组合的配方现金在自己结算那一刻被吃掉，产出照常
func test_production_cash_is_eaten() -> void:
	print("\n【3】生产配方的现金结算时被吃掉")
	var def_id := _pick_by_recipe(CardDB.KIND_PRODUCT, CardDB.RES_CASH)
	check(def_id != "", "卡表里有吃现金的生产卡")
	var d: Dictionary = CardDB.get_def(def_id)
	var need := int(d["recipe_n"])

	var s := _blank_state()
	var core := s.add_card(GameState.PLAYER, def_id)
	var feed: Array = []
	for i in need: feed.append(s.add_card(GameState.PLAYER, "cash")["uid"])
	for i in 2: s.add_card(GameState.PLAYER, "cash")   # 付完还得剩
	var cash_before := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var out_res: String = d["output_res"]
	var out_before := s.resource_count(GameState.PLAYER, out_res)
	check(s.create_combo(GameState.PLAYER, [core["uid"]] + feed)["ok"], "生产组合编组成立")

	Settle.produce(s)
	var delta_out := s.resource_count(GameState.PLAYER, out_res) - out_before
	check(delta_out == int(d["output_n"]), "产出 %s+%d（实际 %+d）" % [
		out_res, int(d["output_n"]), delta_out])
	var eaten := cash_before - s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	if out_res == CardDB.RES_CASH:
		eaten += int(d["output_n"])   # 产出也是现金，得把它加回来才看得见净吃掉多少
	check(eaten == need, "配方那 %d 张现金被吃掉（实际 %d）" % [need, eaten])


## 用户配方是永久席位：结算完一张不少
func test_user_recipe_seats_survive() -> void:
	print("\n【4】用户配方的席位不被消耗")
	var def_id := _pick_by_recipe(CardDB.KIND_PRODUCT, CardDB.RES_USER)
	check(def_id != "", "卡表里有吃用户的生产卡")
	var d: Dictionary = CardDB.get_def(def_id)
	var need := int(d["recipe_n"])

	var s := _blank_state()
	var core := s.add_card(GameState.PLAYER, def_id)
	var feed: Array = []
	for i in need: feed.append(s.add_card(GameState.PLAYER, "user")["uid"])
	s.add_card(GameState.PLAYER, "cash")   # 防清零即胜误触发
	var users_before := s.resource_count(GameState.PLAYER, CardDB.RES_USER)
	var out_res: String = d["output_res"]
	var out_before := s.resource_count(GameState.PLAYER, out_res)
	check(s.create_combo(GameState.PLAYER, [core["uid"]] + feed)["ok"], "生产组合编组成立")

	Settle.produce(s)
	# 先确认这一组真的产出了。只断言「席位没少」的话，整组作废也满足 ——
	# 「用户配方被当成成本」的错法会把组合卡在付不起（组里没现金），席位一样不少
	var delta_out := s.resource_count(GameState.PLAYER, out_res) - out_before
	check(delta_out == int(d["output_n"]), "组合正常产出 %s+%d（实际 %+d）" % [
		out_res, int(d["output_n"]), delta_out])
	for e in s.log:
		check(not ("整组作废" in GameState.entry_text(e)), "用户配方不该触发付款失败：%s" % GameState.entry_text(e))
	var users_now := s.resource_count(GameState.PLAYER, CardDB.RES_USER)
	var expect := users_before + (int(d["output_n"]) if out_res == CardDB.RES_USER else 0)
	check(users_now == expect, "用户席位一张不少（%d → %d，期望 %d）" % [
		users_before, users_now, expect])


## 防御 Buff：编组当回合即保护，跨回合保持同样额度
func test_buff_protects_immediately() -> void:
	print("\n【5】防御 Buff 编组当回合立即保护")
	var def_id := _pick_by_recipe(CardDB.KIND_PRODUCT, CardDB.RES_CASH)
	var buff_id := _protect_cash_buff()
	check(buff_id != "", "卡表里有护现金的防御 Buff")
	var d: Dictionary = CardDB.get_def(def_id)
	var need := int(d["recipe_n"])

	var s := _blank_state()
	var core := s.add_card(GameState.AI, def_id)
	var b := s.add_card(GameState.AI, buff_id)
	var feed: Array = []
	for i in need: feed.append(s.add_card(GameState.AI, "cash")["uid"])
	s.add_card(GameState.AI, "user")   # 防清零即胜误触发
	var r := s.create_combo(GameState.AI, [core["uid"], b["uid"]] + feed)
	check(r["ok"], "带防御 Buff 的生产组合编组成立")
	check(r["eval"].get("protect_cash", false), "组合带现金保护标记")

	var round1 := 0
	for u in feed:
		if s.is_protected(GameState.AI, u, CardDB.RES_CASH):
			round1 += 1
	check(round1 == need, "编组当回合 %d 张（配方量）受保护（实际 %d）" % [need, round1])
	check(s.buff_armed(GameState.AI, b["uid"]), "防御 Buff 当回合已生效")
	check(not b.has("armed_round"), "新编组不再记录装机回合")

	s.round_num += 1
	var round2 := 0
	for u in feed:
		if s.is_protected(GameState.AI, u, CardDB.RES_CASH):
			round2 += 1
	check(round2 == need, "下一回合仍有 %d 张（配方量）受保护（实际 %d）" % [need, round2])
	check(s.buff_armed(GameState.AI, b["uid"]), "防御 Buff 下一回合仍生效")


## 每回合 combos.clear() 后无保护；重注册立即恢复，额度不变
func test_protection_survives_recombo() -> void:
	print("\n【6】跨回合重新编组立即保护")
	var def_id := _pick_by_recipe(CardDB.KIND_PRODUCT, CardDB.RES_CASH)
	var buff_id := _protect_cash_buff()
	var d: Dictionary = CardDB.get_def(def_id)
	var need := int(d["recipe_n"])

	var s := _blank_state()
	var core := s.add_card(GameState.AI, def_id)
	var b := s.add_card(GameState.AI, buff_id)
	var feed: Array = []
	for i in need + 3: feed.append(s.add_card(GameState.AI, "cash")["uid"])
	s.add_card(GameState.AI, "user")
	var uids: Array = [core["uid"], b["uid"]] + feed
	check(s.create_combo(GameState.AI, uids)["ok"], "第 1 回合编组成立")

	# 模拟一个回合过去：finalize 清空 combos，场景层从牌摞重新注册同一批 uid
	Settle.finalize(s)
	s.round_num += 1
	check(s.combos.is_empty(), "finalize 清空了 combos")
	check(not s.is_protected(GameState.AI, feed[0], CardDB.RES_CASH), "清组后的散卡不受保护")
	check(s.create_combo(GameState.AI, uids)["ok"], "第 2 回合同一批卡重新注册成立")
	check(s.buff_armed(GameState.AI, b["uid"]),
		"重注册当回合立即恢复保护")
	var prot := 0
	for u in feed:
		if s.is_protected(GameState.AI, u, CardDB.RES_CASH):
			prot += 1
	check(prot == need, "重注册后照常保护 %d 张（实际 %d）" % [need, prot])


## 场景拖牌时会先评估临时牌摞，再向引擎注册；两条路径必须同回合一致。
func test_protection_requires_valid_group() -> void:
	print("\n【7】保护要求有效组合，离组、配方不足和富余卡不受保护")
	for res in [CardDB.RES_CASH, CardDB.RES_USER]:
		var s := _blank_state()
		var owner := GameState.PLAYER
		var core := s.add_card(owner, _pick_by_recipe(CardDB.KIND_PRODUCT, res))
		var required := int(CardDB.get_def(core["def_id"])["recipe_n"])
		var buff_id := ""
		for id in CardDB.all_cards():
			if CardDB.get_def(id).get("buff_type") == CardDB.protect_key(res):
				buff_id = str(id)
				break
		if not need(buff_id != "", "%s 存在对应保护 Buff" % res):
			continue
		var buff := s.add_card(owner, buff_id)
		var units: Array = []
		for i in required + 1:
			units.append(s.add_card(owner, CardDB.unit_id(res))["uid"])
		check(not s.is_protected(owner, units[0], res), "%s：散放的 Buff 不保护散资源" % res)
		check(not s.buff_armed(owner, core["uid"]) and not s.buff_armed(owner, units[0])
				and not s.buff_armed(owner, -1), "%s：只有防御 Buff 能提供保护" % res)
		var ids: Array = [core["uid"], buff["uid"]] + units
		var preview := _preview_combo(s, owner, ids)
		var protected := s.protected_uids(owner, preview, res)
		check(protected.size() == required and protected.has(units[0]),
			"%s：尚未 create_combo 的有效临时牌摞立即获得配方量保护" % res)
		check(not protected.has(units[-1]), "%s：富余投料不在保护额度内" % res)
		var short_ids: Array = [core["uid"], buff["uid"]] + units.slice(0, required - 1)
		check(s.protected_uids(owner, _preview_combo(s, owner, short_ids), res).is_empty(),
			"%s：临时牌摞配方不足时不产生保护" % res)
		var no_buff: Array = [core["uid"]] + units
		check(s.protected_uids(owner, _preview_combo(s, owner, no_buff), res).is_empty(),
			"%s：Buff 离开临时牌摞后保护立即消失" % res)
		check(s.create_combo(owner, ids)["ok"], "%s：相同牌摞完成注册" % res)
		var combo: Dictionary = s.combos[0]
		check(s.protected_uids(owner, combo, res) == protected,
			"%s：注册前后保护集合一致" % res)
		s.remove_card(owner, buff["uid"])
		check(s.protected_uids(owner, combo, res).is_empty(),
			"%s：已注册组合中 Buff 被移除后，历史标记不能延续保护" % res)
		var fresh_buff := s.add_card(owner, buff_id)
		ids = [core["uid"], fresh_buff["uid"]] + units
		s.combos.clear()
		check(s.create_combo(owner, ids)["ok"], "%s：替换的新 Buff 同回合可重新编组" % res)
		s.remove_card(owner, units[0])
		s.remove_card(owner, units[1])
		check(s.protected_uids(owner, s.combos[0], res).is_empty(),
			"%s：已注册组合配方被削减至不足后保护立即消失" % res)

func _preview_combo(s: GameState, who: String, ids: Array) -> Dictionary:
	var cards: Array = []
	for uid in ids:
		cards.append(s.find_card(who, int(uid)))
	return {"owner": who, "uids": ids, "eval": ComboRules.evaluate(cards)}


## 候选生成沿用环境的装弹护栏；对边界两侧都检查，避免空候选假绿。
func test_generated_attack_respects_ammo() -> void:
	var id := _pick_by_recipe(CardDB.KIND_ATTACK, CardDB.RES_CASH)
	var d := CardDB.get_def(id)
	var need := int(d["recipe_n"])
	for extra in [0, 1]:
		var s := _blank_state()
		s.add_card(GameState.AI, id)
		for i in need + extra:
			s.add_card(GameState.AI, CardDB.unit_id(CardDB.RES_CASH))
		s.add_card(GameState.AI, CardDB.unit_id(CardDB.RES_USER))
		for i in int(d["attack_n"]) + 1:
			s.add_card(GameState.PLAYER, CardDB.unit_id(str(d["attack_res"])))
		s.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_USER))
		s.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH))
		var built := false
		for node in Actions.generate(s, GameState.AI, _candidate_profile()):
			var candidate: GameState = node["state"]
			if candidate.combos.is_empty():
				continue
			built = true
			var replay := Env.copy(s)
			check(Env.replay(replay, node["intents"]), "生成的攻击意图能通过环境回放")
			var pool := replay.arm_attacks(GameState.AI)
			check(int(pool[d["attack_res"]]) == int(d["attack_n"]), "攻击候选均付得起弹药")
		check(built == (extra == 1), "现金=配方+%d 时攻击候选存在=%s" % [extra, built])

func test_generated_cash_recipe_replays() -> void:
	var id := _pick_by_recipe(CardDB.KIND_PRODUCT, CardDB.RES_CASH)
	var d := CardDB.get_def(id)
	var s := _blank_state()
	s.add_card(GameState.AI, id)
	for who in [GameState.AI, GameState.PLAYER]:
		s.add_card(who, CardDB.unit_id(CardDB.RES_USER))
		s.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
	for i in int(d["recipe_n"]):
		s.add_card(GameState.AI, CardDB.unit_id(CardDB.RES_CASH))
	var found := false
	for node in Actions.generate(s, GameState.AI, _candidate_profile()):
		var candidate: GameState = node["state"]
		if candidate.combos.is_empty():
			continue
		found = true
		var replay := Env.copy(s)
		check(Env.replay(replay, node["intents"]), "现金配方的生成意图能回放")
		var before := replay.resource_count(GameState.AI, str(d["output_res"]))
		Settle.produce(replay)
		var expected := before + int(d["output_n"])
		if d["output_res"] == CardDB.RES_CASH:
			expected -= int(d["recipe_n"])
		check(replay.resource_count(GameState.AI, str(d["output_res"])) == expected,
			"现金配方候选按当前卡表付款并产出")
	check(found, "料齐的现金配方仍存在合法生产候选")

func _candidate_profile() -> Dictionary:
	var profile := AISearch.from_model("ai", 0.0).resolved_parameters()
	profile.merge({"plans": 64, "sales": 0, "buy_beam": 64, "build_beam": 64}, true)
	return profile
