# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 开局角色（README.md §「2.12 角色」）的引擎判据：开局资源、两张专属卡、两类倍率，
## 以及「默认角色不改快照和哈希」这条兼容线。
##
## 数值一律从卡表读（角色的 start_*、倍率，卡的 recipe_n / output_n），不写死：
## 调参只改 cards.json，这里跟着变；写死的数字一调就红，红的却不是规则。
##
## 变异提示：
##   Roles.scale 的 ceili 换成 floori                → 第 3、4 组红
##   ComboRules.evaluate 不把 mods 传给 recipe_need   → 第 3 组红
##   GameState.protect_quota 不读 recipe_need          → 第 3 组「保护额度」红
##   GameState.buy 去掉「给我」那条分支                → 第 5 组红
##   Settle._consume_upgrade_materials 不吃 special    → 第 6 组「Idea 被吃掉」红
##   StateCodec.snapshot 无条件写 roles                → 第 7 组「默认局不多字段」红
##   StateCodec.restore 不复位 roles                   → 第 7 组「覆盖进旧对象」红

func _initialize() -> void:
	print("=== 开局角色 测试 ===\n")
	test_role_table()
	test_start_resources()
	test_hr_recipe()
	test_output_scaling()
	test_grab_card()
	test_idea_card()
	test_snapshot_compat()
	test_tape_roundtrip()
	finish()

var _n := 1000
func _c(def_id: String) -> Dictionary:
	_n += 1
	return { "uid": _n, "def_id": def_id, "locked": false }

func _cards(ids: Array) -> Array:
	return ids.map(func(i): return _c(i))

func _repeat(def_id: String, n: int) -> Array:
	var out: Array = []
	for _i in n: out.append(def_id)
	return out

## 卡表里某个 special 类型的那张卡
func _special(kind: String) -> String:
	for id in CardDB.all_cards():
		if CardDB.special_type(str(id)) == kind:
			return str(id)
	return ""

## 第一个带某张倍率表的角色
func _role_with(key: String, res: String) -> String:
	for id in Roles.ids():
		if Roles.get_def(id).get(key, {}).has(res):
			return id
	return ""

func _role_with_card(def_id: String) -> String:
	for id in Roles.ids():
		if Roles.start_cards(id).has(def_id):
			return id
	return ""

## 一张吃用户的生产卡（配方奇数张，好看出向上取整）
func _user_product(odd := true) -> String:
	for id in CardDB.all_cards():
		var d := CardDB.get_def(str(id))
		if d.get("kind") == CardDB.KIND_PRODUCT and d.get("recipe_res") == CardDB.RES_USER \
				and int(d.get("tier", 0)) == 1 and (int(d["recipe_n"]) % 2 == 1) == odd:
			return str(id)
	return ""

func _game(roles: Dictionary) -> GameState:
	var s := GameState.new()
	s.set_seed(4242)
	for who in roles:
		s.set_role(who, roles[who])
	s.new_game()
	return s

func _count(s: GameState, who: String, def_id: String) -> int:
	return s.players[who]["cards"].filter(func(c): return c["def_id"] == def_id).size()

func _uids_of(s: GameState, who: String, def_id: String, n: int) -> Array:
	var out: Array = []
	for c in s.players[who]["cards"]:
		if c["def_id"] == def_id and out.size() < n:
			out.append(c["uid"])
	return out


func test_role_table() -> void:
	print("【1】角色表")
	var ids := Roles.ids()
	check(ids.size() >= 8, "角色表读得出全部角色（%d 个）" % ids.size())
	check(ids[0] == Roles.DEFAULT, "默认角色排第一（界面列表的首项）")
	for id in ids:
		check(Roles.role_name(id) != id, "角色「%s」有显示名" % id)
		check(Roles.describe(id).size() >= 2, "角色「%s」至少有开局资源和一条效果说明" % id)
		for def_id in Roles.start_cards(id):
			check(not CardDB.get_def(def_id).is_empty(), "角色「%s」开局发的「%s」在卡表里" % [id, def_id])
	check(Roles.mods(Roles.DEFAULT).is_empty(), "默认角色没有任何倍率")
	check(not Roles.exists("_note") and not Roles.exists("nobody"), "说明键和不存在的 id 都不算角色")
	check(Roles.scale(3, {"recipe_mult": {"user": 0.5}}, "recipe_mult", "user") == 2, "3×0.5 向上取整为 2")
	check(Roles.scale(10, {"m": {"cash": 0.3}}, "m", "cash") == 3, "10×0.3 不被浮点误差抬成 4")
	check(Roles.scale(1, {"m": {"cash": 0.1}}, "m", "cash") == 1, "缩放结果至少为 1")


func test_start_resources() -> void:
	print("\n【2】开局资源与专属卡")
	var rules := CardDB.game_rules()
	for id in Roles.ids():
		var s := _game({GameState.PLAYER: id})
		var want_cash := int(Roles.get_def(id).get("start_cash", rules["start_cash"]))
		var want_user := int(Roles.get_def(id).get("start_user", rules["start_user"]))
		check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == want_cash
			and s.resource_count(GameState.PLAYER, CardDB.RES_USER) == want_user,
			"「%s」开局 资金%d 用户%d" % [Roles.role_name(id), want_cash, want_user])
		for def_id in Roles.start_cards(id):
			check(_count(s, GameState.PLAYER, def_id) == 1, "「%s」开局拿到「%s」" % [Roles.role_name(id), CardDB.card_name(def_id)])
		check(s.resource_count(GameState.BOT, CardDB.RES_CASH) == int(rules["start_cash"])
			and s.players[GameState.BOT]["cards"].size() == int(rules["start_cash"]) + int(rules["start_user"]),
			"「%s」不影响对手：对手仍是默认开局" % Roles.role_name(id))
	var s := GameState.new()
	s.set_role(GameState.PLAYER, "nobody")
	check(s.role_of(GameState.PLAYER) == Roles.DEFAULT, "认不出的角色退回默认角色")


func test_hr_recipe() -> void:
	print("\n【3】配方需求倍率（HR）")
	var hr := _role_with("recipe_mult", CardDB.RES_USER)
	check(hr != "", "卡表里有缩放用户配方的角色")
	var mods := Roles.mods(hr)
	var core := _user_product()
	var def := CardDB.get_def(core)
	var need := Roles.scale(int(def["recipe_n"]), mods, "recipe_mult", CardDB.RES_USER)
	check(need < int(def["recipe_n"]), "「%s」配方 %d → %d" % [def["name"], def["recipe_n"], need])
	var short := _cards([core] + _repeat(CardDB.unit_id(CardDB.RES_USER), need))
	check(not ComboRules.evaluate(short)["valid"], "默认角色：%d 张用户不够" % need)
	var ev := ComboRules.evaluate(short, mods)
	check(ev["valid"] and int(ev.get("recipe_need", -1)) == need, "该角色：%d 张用户就成立，eval 记下改后的需求" % need)
	check(GameState.protect_quota(ev) == need, "保护额度跟着改后的需求走（%d）" % need)
	check(not ComboRules.evaluate(short).has("recipe_need"), "默认角色的 eval 不多 recipe_need 这个键")
	# 攻击卡的用户配方同样缩放
	for id in CardDB.all_cards():
		var d := CardDB.get_def(str(id))
		if d.get("kind") == CardDB.KIND_ATTACK and d.get("recipe_res") == CardDB.RES_USER:
			var n := Roles.scale(int(d["recipe_n"]), mods, "recipe_mult", CardDB.RES_USER)
			check(ComboRules.evaluate(_cards([id] + _repeat(CardDB.unit_id(CardDB.RES_USER), n)), mods)["valid"],
				"攻击卡「%s」%d 张用户即可装弹" % [d["name"], n])
			break
	# 现金配方不受用户倍率影响
	for id in CardDB.all_cards():
		var d := CardDB.get_def(str(id))
		if d.get("kind") == CardDB.KIND_PRODUCT and d.get("recipe_res") == CardDB.RES_CASH:
			var ev2 := ComboRules.evaluate(_cards([id] + _repeat(CardDB.unit_id(CardDB.RES_CASH), int(d["recipe_n"]))), mods)
			check(ev2["valid"] and int(ev2["recipe_pay_n"]) == int(d["recipe_n"]) and not ev2.has("recipe_need"),
				"现金配方「%s」照付 %d 张" % [d["name"], d["recipe_n"]])
			break
	# 实局：编组 → 攻击选靶的保护额度 → 结算产出
	var s := _game({GameState.PLAYER: hr})
	var core_uid: int = s.add_card(GameState.PLAYER, core)["uid"]
	var guard := ""
	for id in CardDB.all_cards():
		if CardDB.get_def(str(id)).get("buff_type", "") == CardDB.protect_key(CardDB.RES_USER):
			guard = str(id)
	var guard_uid: int = s.add_card(GameState.PLAYER, guard)["uid"]
	var users := _uids_of(s, GameState.PLAYER, CardDB.unit_id(CardDB.RES_USER), need + 1)
	var made := s.create_combo(GameState.PLAYER, [core_uid, guard_uid] + users)
	check(made.get("ok", false), "该角色按改后的需求编得成组")
	var core_targets := s.attack_targets(GameState.PLAYER).filter(func(t): return t["kind"] == "combo")
	var spare_targets := s.attack_targets(GameState.PLAYER).filter(func(t): return t["kind"] == "spare")
	check(core_targets.is_empty() and spare_targets.size() == 1,
		"防御 Buff 护住改后的 %d 张配方，多放的 1 张仍可被打" % need)
	var before := s.resource_count(GameState.PLAYER, def["output_res"])
	Settle.produce(s)
	check(s.resource_count(GameState.PLAYER, def["output_res"]) == before + int(def["output_n"]),
		"结算照常产出 %d" % int(def["output_n"]))


func test_output_scaling() -> void:
	print("\n【4】产出倍率（用增 / 财务）")
	var boost := ""
	var buff := ""
	for id in CardDB.all_cards():
		if CardDB.get_def(str(id)).get("buff_type", "") == "output_x2":
			buff = str(id)
	for res in [CardDB.RES_CASH, CardDB.RES_USER]:
		for key in ["output_mult"]:
			for role in Roles.ids():
				var table: Dictionary = Roles.get_def(role).get(key, {})
				if not table.has(res):
					continue
				var factor := float(table[res])
				var mods := Roles.mods(role)
				for id in CardDB.all_cards():
					var d := CardDB.get_def(str(id))
					if d.get("kind") != CardDB.KIND_PRODUCT or d.get("output_res") != res:
						continue
					var recipe := _repeat(CardDB.unit_id(str(d["recipe_res"])), int(d["recipe_n"]))
					var ev := ComboRules.evaluate(_cards([id] + recipe), mods)
					var want := maxi(1, ceili(float(d["output_n"]) * factor - 0.000001))
					check(int(ev["output_n"]) == want, "「%s」的「%s」产出 %d → %d" % [
						Roles.role_name(role), d["name"], d["output_n"], want])
					if buff != "":
						var ev2 := ComboRules.evaluate(_cards([id, buff] + recipe), mods)
						var want2 := maxi(1, ceili(float(d["output_n"]) * CardDB.buff_mult("output_x2") * factor - 0.000001))
						check(int(ev2["output_n"]) == want2, "带 Buff 先乘倍率再缩放：%d" % want2)
					boost = role
					break
	check(boost != "", "卡表里有缩放产出的角色")
	# 升级组合不受产出倍率影响
	var t1 := _user_product()
	var ev := ComboRules.evaluate(_cards([t1, t1]), Roles.mods(boost))
	check(ev["valid"] and ev["type"] == "upgrade", "两张同名 T1 照常升级，产出倍率不碰升级")


func test_grab_card() -> void:
	print("\n【5】「给我」")
	var grab := _special(CardDB.SPECIAL_GRAB)
	var role := _role_with_card(grab)
	check(grab != "" and role != "", "卡表里有「给我」以及开局发它的角色")
	var s := _game({GameState.PLAYER: role})
	# 挑公共区里最贵的一张
	var idx := 0
	for i in s.market.size():
		if int(CardDB.get_def(s.market[i]).get("price", 0)) > int(CardDB.get_def(s.market[idx]).get("price", 0)):
			idx = i
	var target: String = s.market[idx]
	var grab_uid: int = _uids_of(s, GameState.PLAYER, grab, 1)[0]
	var cash := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var cash_uid: int = _uids_of(s, GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH), 1)[0]
	var mixed := s.buy(GameState.PLAYER, idx, [grab_uid, cash_uid])
	check(not mixed.get("ok", false) and _count(s, GameState.PLAYER, grab) == 1, "和现金混在一起付会被拒，「给我」还在")
	var pawned := s.pawn(GameState.PLAYER, [grab_uid])
	check(not pawned.get("ok", false) and str(pawned["reason"]).contains("不能典当"), "「给我」不能典当：%s" % pawned.get("reason", ""))
	check(CardDB.pawn_value(grab) == 0, "「给我」回收价为 0")
	check(not ComboRules.evaluate(_cards([grab, _user_product()]))["valid"], "「给我」编不进组合")
	var market_size := s.market.size()
	var ap := IntentApply.new(s)
	var r := ap.apply(Intent.buy(GameState.PLAYER, idx, [grab_uid]), GameState.PLAYER)
	check(r.get("ok", false), "拖「给我」到「%s」上：拿到手" % CardDB.card_name(target))
	check(r.get("removed_uids", []) == [grab_uid], "付掉的那张就是「给我」（购买演出照常吸走它）")
	check(s.find_card(GameState.PLAYER, int(r.get("new_uid", -1))).get("def_id", "") == target, "新卡归自己")
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash, "不花现金（标价 %d）" % int(CardDB.get_def(target)["price"]))
	check(_count(s, GameState.PLAYER, grab) == 0 and s.market.size() == market_size - 1, "「给我」用完即消失，公共区少一格")
	check(s.attack_targets(GameState.PLAYER).all(func(t): return CardDB.get_def(t["leader"]).get("kind") != CardDB.KIND_SPECIAL),
		"专属卡不会成为攻击目标")


func test_idea_card() -> void:
	print("\n【6】Idea")
	var idea := _special(CardDB.SPECIAL_IDEA)
	var role := _role_with_card(idea)
	check(idea != "" and role != "", "卡表里有 Idea 以及开局发它的角色")
	var t1 := ""
	var orphan := ""
	var t2 := ""
	for id in CardDB.all_cards():
		var d := CardDB.get_def(str(id))
		if d.get("kind") != CardDB.KIND_PRODUCT: continue
		if int(d.get("tier", 0)) == 2 and t2 == "": t2 = str(id)
		if int(d.get("tier", 0)) == 1:
			if ComboRules.upgrade_target(str(id), 2) != "":
				if t1 == "": t1 = str(id)
			elif orphan == "":
				orphan = str(id)
	var direct := ComboRules.upgrade_target(t1, 2)
	var ev := ComboRules.evaluate(_cards([idea, t1]))
	check(ev["valid"] and ev["type"] == "upgrade" and ev["output_card"] == direct,
		"Idea + 「%s」→「%s」" % [CardDB.card_name(t1), CardDB.card_name(direct)])
	check(ev["leader"] == t1, "领头记真生产卡，不记 Idea")
	check(not ComboRules.evaluate(_cards([idea]))["valid"], "Idea 单独不成组")
	check(not ComboRules.evaluate(_cards([idea, t2]))["valid"], "Idea 不能顶替 T2")
	if orphan != "":
		check(not ComboRules.evaluate(_cards([idea, orphan]))["valid"], "没有 T2 的「%s」配 Idea 也升不了" % CardDB.card_name(orphan))
	check(not ComboRules.evaluate(_cards([idea, t1, CardDB.unit_id(CardDB.RES_USER)]))["valid"], "升级组里不能夹资源")
	# 传说：同档 T1 张数里顶一张
	var mixed: Array = []
	for id in CardDB.all_cards():
		var d := CardDB.get_def(str(id))
		if d.get("kind") == CardDB.KIND_PRODUCT and int(d.get("tier", 0)) == 1 and not mixed.has(str(id)):
			mixed.append(str(id))
	for n in range(2, CardDB.max_upgrade_n() + 1):
		var legend := ComboRules.legend_upgrade_target(1, n)
		if legend == "" or mixed.size() < n - 1: continue
		var ids: Array = [idea] + mixed.slice(0, n - 1)
		var e := ComboRules.evaluate(_cards(ids))
		check(e["valid"] and e["output_card"] == legend, "Idea + %d 张异名 T1 →「%s」" % [n - 1, CardDB.card_name(legend)])
		check(not ComboRules.evaluate(_cards([idea] + mixed.slice(0, n)))["valid"], "多一张就不成立（张数仍须精确）")
		break
	# 实局：结算吃掉 Idea
	var s := _game({GameState.PLAYER: role})
	var idea_uid: int = _uids_of(s, GameState.PLAYER, idea, 1)[0]
	var core_uid: int = s.add_card(GameState.PLAYER, t1)["uid"]
	check(not s.pawn(GameState.PLAYER, [idea_uid]).get("ok", false), "Idea 不能典当")
	check(s.create_combo(GameState.PLAYER, [idea_uid, core_uid]).get("ok", false), "Idea + T1 编得成升级组")
	Settle.produce(s)
	check(_count(s, GameState.PLAYER, idea) == 0 and _count(s, GameState.PLAYER, t1) == 0
		and _count(s, GameState.PLAYER, direct) == 1, "结算吃掉 Idea 和 T1，得到「%s」" % CardDB.card_name(direct))


func test_snapshot_compat() -> void:
	print("\n【7】快照与哈希")
	var plain := _game({})
	check(not StateCodec.snapshot(plain).has("roles"), "默认局不多 roles 字段（旧录像的哈希不变）")
	var hr := _role_with("recipe_mult", CardDB.RES_USER)
	var custom := _game({GameState.PLAYER: hr})
	var snap := StateCodec.snapshot(custom)
	check(snap.get("roles", {}).get(GameState.PLAYER, "") == hr, "非默认角色写进快照")
	check(StateCodec.snapshot_issue(snap) == "", "带角色的快照通过边界校验")
	var copy := GameState.new()
	StateCodec.restore(copy, JSON.parse_string(JSON.stringify(snap)))
	check(copy.role_of(GameState.PLAYER) == hr and StateCodec.state_hash(copy) == StateCodec.state_hash(custom),
		"过一趟 JSON 还原角色，状态哈希一致")
	StateCodec.restore(copy, StateCodec.snapshot(plain))
	check(copy.role_of(GameState.PLAYER) == Roles.DEFAULT, "覆盖进旧对象时，没写角色的快照复位成默认角色")
	var plain_twin := _game({GameState.PLAYER: Roles.DEFAULT})
	check(StateCodec.state_hash(plain_twin) == StateCodec.state_hash(plain), "显式设成默认角色和不设，哈希相同")
	check(StateCodec.state_hash(custom) != StateCodec.state_hash(_game({})) , "角色参与状态哈希")
	var bad := snap.duplicate(true)
	bad["roles"][GameState.PLAYER] = "nobody"
	check(StateCodec.snapshot_issue(bad) != "", "快照里的未知角色被拒")
	check(BOTEnvironment.copy(custom).role_of(GameState.PLAYER) == hr, "BOT 搜索副本带着角色")


func test_tape_roundtrip() -> void:
	print("\n【8】录像重放")
	var grab := _special(CardDB.SPECIAL_GRAB)
	var s := _game({GameState.PLAYER: _role_with_card(grab)})
	var ap := IntentApply.new(s)
	var tape := Tape.new()
	tape.start(ap, "角色测试")
	var grab_uid: int = _uids_of(s, GameState.PLAYER, grab, 1)[0]
	check(ap.apply(Intent.buy(GameState.PLAYER, 0, [grab_uid]), GameState.PLAYER).get("ok", false), "录制中用「给我」拿牌")
	tape.stop()
	var loaded := Tape.from_dict(JSON.parse_string(JSON.stringify(tape.to_dict())))
	check(loaded.get("ok", false), "录像过一趟 JSON 读得回来")
	if loaded.get("ok", false):
		var rp := Tape.replay(loaded["tape"])
		check(rp["ok"], "重放逐步哈希一致：%s" % Tape.verdict(rp))
