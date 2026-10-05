# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 生产卡升级规则的专项测试：升传说可同档混名，升对应 T2 仍需同名。
## 规则：只放同档生产卡，不吃现金也不吃用户
##   同名 T1×2                    → 对应的 T2 行业巨头
##   同名 T2×upgrade_dup_n        → 对应传说卡
##   同名 T1×upgrade_dup_n×2      → 同一张传说卡（直达，不必先过 T2）
## 三档张数和三个产物都不手抄：全部从卡表里 `upgrade_from == dup_t2` 那几张的
## upgrade_dup_n 现算（见 harness.dup_ladder）。卡表调了档位，这一整份跟着走
## 跑法：Godot --headless --script tests/test_dup_upgrade.gd


## 卡表里某一档生产卡的 id，排序后取，保证每次跑都是同一张
func _products(tier: int) -> Array:
	var out: Array = []
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if str(d.get("kind", "")) == CardDB.KIND_PRODUCT and int(d.get("tier", 0)) == tier:
			out.append(def_id)
	out.sort()
	return out


func _initialize() -> void:
	CardDB.ensure_loaded()
	test_t2_ladder()
	test_all_t1_have_a_t2()
	test_t1_direct_to_legend()
	test_mixed_name_legends()
	test_no_foreign_cards()
	test_wrong_count()
	test_mixed_counts_and_tiers()
	test_legend_rules_follow_config()
	test_duplicate_uid_rejected()
	test_settle_mixed_legends()
	test_settle_to_legend()
	test_settle_t1_direct()
	test_bot_builds_dup_upgrades()
	finish()


## 造一组同名卡的 evaluate 入参
func _dup(def_id: String, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"uid": i, "def_id": def_id})
	return out


## 同名 T2 的三档产物
func test_t2_ladder() -> void:
	var want := dup_ladder()
	var ns: Array = want.keys()
	ns.sort()
	var rep: String = _products(2)[0]        # 挑一张 T2 当代表
	print("\n【1】同名 T2×%s → %s" % [dup_slashed(ns), CardDB.card_name(want[ns[-1]])])
	check(ns.size() >= 2, "牌表前提：传说卡阶梯有 %d 档（少于 2 档就没有「挑哪档」可言）" % ns.size())
	for n in ns:
		var e := ComboRules.evaluate(_dup(rep, n))
		check(e["valid"] and e["type"] == "upgrade",
			"%s×%d 判成升级（%s）" % [CardDB.card_name(rep), n, e.get("reason", "")])
		check(e.get("output_card", "") == want[n],
			"%s×%d → %s（实际 %s）" % [CardDB.card_name(rep), n, CardDB.card_name(want[n]),
				e.get("output_card", "")])
	# 每张 T2 走的是同一条路线，随便挑一张都该通
	var top: int = ns[-1]
	for def_id in _products(2):
		var e2 := ComboRules.evaluate(_dup(def_id, top))
		check(e2.get("output_card", "") == want[top],
			"%s×%d → %s" % [CardDB.card_name(def_id), top, CardDB.card_name(want[top])])


## 每张能升级的 T1 都有对应 T2，且只认偶数张
func test_all_t1_have_a_t2() -> void:
	print("\n【2】同名 T1×2 → 对应 T2")
	# T1 侧的上界 = 传说卡阶梯最高档 × 最大折算率（配置 _upgrade.routes 里的 per）
	var top2: int = CardDB.max_upgrade_n()
	var odds: Array = []
	for k in range(3, top2 + 1):
		if k % 2 == 1:
			odds.append(k)
	var sources: Dictionary = {}
	for def_id in _products(2):
		var d: Dictionary = CardDB.get_def(def_id)
		var t1: String = d.get("upgrade_from", "")
		check(CardDB.all_cards().has(t1), "%s 的来源 %s 是张真卡" % [d["name"], t1])
		sources[t1] = true
		var e := ComboRules.evaluate(_dup(t1, 2))
		check(e.get("output_card", "") == def_id,
			"%s×2 → %s" % [CardDB.card_name(t1), d["name"]])
		# 奇数张凑不出东西：T1 认的只有偶数那几档
		for odd in odds:
			check(not ComboRules.evaluate(_dup(t1, odd))["valid"],
				"%s×%d 不成立（T1 只认偶数张）" % [CardDB.card_name(t1), odd])
	# 每张 T2 各有**自己**的 T1 来源：两张 T2 共用一个来源的话，
	# 那个 T1×2 只能升成其中一张，另一张就永远合不出来（上面的循环挨个查过，
	# 但两条都指着同一张卡时它每条都过 —— 张数对得上就行）
	check(sources.size() == _products(2).size(),
		"%d 张 T2 各有自己的 T1 来源（去重后 %d 个）" % [_products(2).size(), sources.size()])


## 同名 T1×4/6/8 直达传说卡。
## 这条路不在卡表里，是 upgrade_target 按「同名 T1×2 == 一张 T2」换算出来的，
## 所以这里钉的不只是三个产物，还有那条换算恒等式本身
func test_t1_direct_to_legend() -> void:
	var ladder := dup_ladder()
	var t2_ns: Array = ladder.keys()
	t2_ns.sort()
	# T1 侧三档 = T2 侧三档各 ×2
	var want: Dictionary = {}
	var t1_ns: Array = []
	for n in t2_ns:
		want[n * 2] = ladder[n]
		t1_ns.append(n * 2)
	print("\n【2b】同名 T1×%s → %s（直达）" % [dup_slashed(t1_ns), CardDB.card_name(want[t1_ns[-1]])])
	var n_t1 := 0
	for def_id in _products(1):
		var d: Dictionary = CardDB.get_def(def_id)
		n_t1 += 1
		for n in t1_ns:
			var e := ComboRules.evaluate(_dup(def_id, n))
			check(e["valid"] and e["type"] == "upgrade",
				"%s×%d 判成升级（%s）" % [d["name"], n, e.get("reason", "")])
			check(e.get("output_card", "") == want[n],
				"%s×%d → %s（实际 %s）" % [
					d["name"], n, CardDB.card_name(want[n]), e.get("output_card", "")])
			# 换算恒等式：T1×2k 和 T2×k 必须落到同一张卡。
			# 卡表把 dup_t2 那三档的张数一改，T1 这三档就得跟着变 ——
			# 钉住这条等式，两边漂开时这里先响，而不是等玩家发现中间那档突然合不出东西
			check(ComboRules.upgrade_target(def_id, n)
					== ComboRules.upgrade_target(_products(2)[0], n / 2),
				"%s×%d 与 同名T2×%d 同一个产物" % [d["name"], n, n / 2])
	check(n_t1 == _products(1).size(),
		"%d 张 T1 全部走通直达路线（实际 %d）" % [_products(1).size(), n_t1])
	# 没有对应 T2 的那张 T1：低档合不出东西，但直达三档照样走得通。
	# 「哪张卡没有 T2」也从卡表现算 —— 卡表补上它的 T2 之后，
	# 这一节会自动改去考新的那张孤儿卡，而写死卡名只会在这里静默失真
	var sources: Dictionary = {}
	for def_id in _products(2):
		sources[str(CardDB.get_def(def_id).get("upgrade_from", ""))] = true
	var orphans: Array = []
	for def_id in _products(1):
		if not sources.has(def_id):
			orphans.append(def_id)
	for orphan in orphans:
		check(ComboRules.upgrade_target(orphan, 2) == "",
			"%s 没有对应 T2（×2 合不出东西）" % CardDB.card_name(orphan))
		check(ComboRules.upgrade_target(orphan, t1_ns[0]) == want[t1_ns[0]],
			"%s×%d → %s（没有 T2 也能直达）" % [
				CardDB.card_name(orphan), t1_ns[0], CardDB.card_name(want[t1_ns[0]])])
	# tier 1 不等于「生产卡」：攻击卡和 Buff 卡也是 tier 1，不能跟着上车
	var evens: Array = [2]
	evens.append_array(t1_ns)
	for def_id in CardDB.all_cards():
		var d2: Dictionary = CardDB.get_def(def_id)
		if d2.get("kind") not in [CardDB.KIND_ATTACK, CardDB.KIND_BUFF]:
			continue
		for n2 in evens:
			check(ComboRules.upgrade_target(def_id, n2) == "",
				"%s×%d 没有升级路线（tier 1 但不是生产卡）" % [d2["name"], n2])


func _mixed(tier: int,n: int) -> Array:
	var ids := _products(tier)
	var cards: Array = []
	for i in n: cards.append({"uid":i,"def_id":ids[i % ids.size()]})
	return cards

func _ids(cards: Array) -> Array:
	var ids: Array = []
	for card in cards: ids.append(card["def_id"])
	return ids

func test_mixed_name_legends() -> void:
	print("\n【3】任意同档生产卡可混名升传说，只有对应 T2 仍要求同名")
	for spec in [[1,4,"dujiaoshou"],[1,6,"guomin"],[1,8,"shangshi"],
			[2,2,"dujiaoshou"],[2,3,"guomin"],[2,4,"shangshi"]]:
		var cards := _mixed(spec[0],spec[1])
		var e := ComboRules.evaluate(cards)
		check(e["valid"] and e["type"] == "upgrade" and e["output_card"] == spec[2],
			"异名 T%d×%d → %s" % [spec[0],spec[1],spec[2]])
		check(ComboRules.legend_upgrade_target(spec[0],spec[1]) == spec[2] \
			and ComboRules.upgrade_target_for_ids(_ids(cards)) == spec[2], "档位查询和实际材料查询共享同一目标")
		cards.reverse()
		check(ComboRules.evaluate(cards).get("output_card") == spec[2] \
			and ComboRules.upgrade_target_for_ids(_ids(cards)) == spec[2], "材料输入顺序不影响产物")
		var repeated := _dup(str(cards[0]["def_id"]),spec[1])
		repeated[-1]["def_id"] = cards[-1]["def_id"]
		check(ComboRules.evaluate(repeated).get("output_card") == spec[2], "允许部分同名、部分异名，不要求每张都不同")
	var m2: Array = [{"uid": 0, "def_id": "shuabuting"}, {"uid": 1, "def_id": "pinshaoshao"}]
	check(not ComboRules.evaluate(m2)["valid"], "不同名 T1 两张仍不能升级为 T2")
	# 传说卡互组已经取消
	var m3: Array = [{"uid": 0, "def_id": "dujiaoshou"}, {"uid": 1, "def_id": "guomin"}]
	check(not ComboRules.evaluate(m3)["valid"], "独角兽 + 国民应用 不再能互组")
	var m4: Array = [{"uid": 0, "def_id": "dujiaoshou"}, {"uid": 1, "def_id": "dujiaoshou"}]
	check(not ComboRules.evaluate(m4)["valid"], "独角兽×2 也不成立（传说卡只能典当）")
	check(ComboRules.legend_upgrade_target(1,2) == "", "传说查询不返回同名T1的普通T2路线")


## 组合里混进单位卡/Buff → 不成立
func test_no_foreign_cards() -> void:
	print("\n【4】升级组合里不能有别的卡")
	for extra in ["cash", "user", "liebian", "tuisong"]:
		var cards := _dup("baiyibutie", 2)
		cards.append({"uid": 90, "def_id": extra})
		var e := ComboRules.evaluate(cards)
		check(not e["valid"], "百亿补贴×2 + %s 不成立" % CardDB.card_name(extra))
		check(str(e.get("reason", "")).contains("不能有别的卡"),
			"拒绝理由点明混了别的卡：%s" % e.get("reason", ""))
	for tier in [1,2]:
		var count := 4 if tier == 1 else 2
		for extra in ["cash","user","liebian","tuisong","zuokong","dujiaoshou","missing_card"]:
			var mixed := _mixed(tier,count)
			mixed.append({"uid":90,"def_id":extra})
			check(not ComboRules.evaluate(mixed)["valid"] \
				and ComboRules.upgrade_target_for_ids(_ids(mixed)) == "", "同档异名材料拒绝夹带："+extra)
			mixed.remove_at(0)
			check(not ComboRules.evaluate(mixed)["valid"], "总张数正确也拒绝把外来牌当材料："+extra)
	# 未知卡以前会被分类循环忽略；即使合法牌已经够数，也必须拒绝整组。
	var unknown := _dup("yunketang",2)
	unknown.append({"uid":90,"def_id":"missing_card"})
	check(not ComboRules.evaluate(unknown)["valid"], "同名T1旧路线也不能静默忽略未知卡")
	check(not ComboRules.evaluate([{"uid":0},null])["valid"], "缺def_id或非卡牌输入明确无效")
	CardDB.CARDS["unknown_kind_test"] = {"name":"未知类型","kind":"unsupported","tier":1}
	unknown[-1]["def_id"] = "unknown_kind_test"
	check(not ComboRules.evaluate(unknown)["valid"], "已有定义但未知kind也不能被忽略")
	CardDB.CARDS.erase("unknown_kind_test")
	# 一张 T2 + 一堆资源仍然只是生产，不会偷偷升级。
	# 张数是判据自己挑的填充量（管够就行，不对应任何配置项），但只写一处：
	# 循环和文案各写一遍的话，改了一个忘了另一个，文案就开始说假话
	var pad := 12
	var one := [{"uid": 0, "def_id": "baiyibutie"}]
	for i in pad:
		one.append({"uid": 10 + i, "def_id": "cash"})
	check(ComboRules.evaluate(one)["type"] == "production",
		"单张 T2 + %s×%d 只是生产" % [CardDB.card_label(CardDB.RES_CASH), pad])


## 同名但张数对不上 → 提示该凑几张
func test_wrong_count() -> void:
	print("\n【5】张数对不上时的提示")
	var ladder := dup_ladder()
	var t2_ns: Array = ladder.keys()
	t2_ns.sort()
	var top: int = t2_ns[-1]
	var t1_ns: Array = []                 # T1 侧认的档位 = T2 侧各 ×2
	for n in t2_ns:
		t1_ns.append(n * 2)
	var t2_list := dup_slashed(t2_ns)        # 提示里 T2 那几档，如 "2/3/4"
	var t1_only := dup_slashed(t1_ns)        # 没有 T2 的 T1 只认这几档，如 "4/6/8"
	var t1_all: Array = [2]               # 有 T2 的 T1 认「2 + 直达三档」
	t1_all.append_array(t1_ns)

	var rep: String = _products(2)[0]
	var e := ComboRules.evaluate(_dup(rep, top + 1))
	check(not e["valid"], "%s×%d 不成立（没有这一档）" % [CardDB.card_name(rep), top + 1])
	check(str(e.get("reason", "")).contains(t2_list),
		"提示认 %s 张：%s" % [t2_list, e.get("reason", "")])

	# 没有对应 T2 的那张 T1：提示要把它**真认**的那几档报全。
	# 多报一档「2」会让玩家攒两张干等着，所以顺带钉住「不含 2/」
	var sources: Dictionary = {}
	for def_id in _products(2):
		sources[str(CardDB.get_def(def_id).get("upgrade_from", ""))] = true
	var orphan := ""
	for def_id in _products(1):
		if not sources.has(def_id):
			orphan = def_id
			break
	if orphan != "":
		var e2 := ComboRules.evaluate(_dup(orphan, 2))
		check(not e2["valid"], "%s×2 不成立（这张 T1 没有 T2）" % CardDB.card_name(orphan))
		check(str(e2.get("reason", "")).contains(t1_only)
				and not str(e2.get("reason", "")).contains("2/%d" % t1_ns[0]),
			"%s 的提示只报 %s：%s" % [CardDB.card_name(orphan), t1_only, e2.get("reason", "")])

	# 攻击卡没有升级路线：挑一张真的攻击卡，不写死卡名
	for def_id in CardDB.all_cards():
		if str(CardDB.get_def(def_id).get("kind", "")) == CardDB.KIND_ATTACK:
			var e3 := ComboRules.evaluate(_dup(def_id, 2))
			check(not e3["valid"], "%s×2 不成立（攻击卡没有升级路线）" % CardDB.card_name(def_id))
			break

	# 有 T2 的 T1 认四档，提示要报全，不能停在旧的「只认 2 张」
	var withT2: String = str(CardDB.get_def(_products(2)[0]).get("upgrade_from", ""))
	var e4 := ComboRules.evaluate(_dup(withT2, 3))
	check(not e4["valid"], "%s×3 不成立（奇数张）" % CardDB.card_name(withT2))
	check(str(e4.get("reason", "")).contains(dup_slashed(t1_all)),
		"%s 的提示报全 %s：%s" % [CardDB.card_name(withT2), dup_slashed(t1_all), e4.get("reason", "")])
	# 超出最长路线一张：别静默吃掉一部分凑最高档
	var over: int = t1_ns[-1] + 1
	check(not ComboRules.evaluate(_dup(withT2, over))["valid"],
		"%s×%d 不成立（%d 是上界，不会自动只吃 %d 张）" % [
			CardDB.card_name(withT2), over, t1_ns[-1], t1_ns[-1]])

func test_mixed_counts_and_tiers() -> void:
	for tier in [1,2]:
		var legal := [4,6,8] if tier == 1 else [2,3,4]
		for count in range(0,11):
			var cards := _mixed(tier,count)
			var expected := count in legal
			check((ComboRules.legend_upgrade_target(tier,count) != "") == expected \
				and (ComboRules.upgrade_target_for_ids(_ids(cards)) != "") == expected,
				"异名T%d严格检查全部%d张，不补料、不截取一部分" % [tier,count])
		for count in legal:
			var cards := _mixed(tier,count)
			cards[-1]["def_id"] = _products(2 if tier == 1 else 1)[0]
			check(not ComboRules.evaluate(cards)["valid"] and ComboRules.upgrade_target_for_ids(_ids(cards)) == "",
				"T%d档位%d张混进另一档也不成立" % [tier,count])
			cards.reverse()
			check(not ComboRules.evaluate(cards)["valid"], "混档拒绝不受第一个材料的档位影响")
	for tier in [-1,0,3,99]:
		check(ComboRules.legend_upgrade_target(tier,4) == "", "传说查询不接受T1/T2以外档位")

func test_legend_rules_follow_config() -> void:
	var saved_cards := CardDB.CARDS.duplicate(true)
	var saved_rules := CardDB.UPGRADE.duplicate(true)
	CardDB.CARDS["dujiaoshou"]["upgrade_dup_n"] = 5
	for route in CardDB.UPGRADE["routes"]:
		if route.get("key") == "dup_key" and int(route.get("tier",0)) == 1:
			route["per"] = 3
			route["require_multiple"] = false
	# 同占位键的非传说目标排在最前，也不得截走传说查询。
	var with_decoy := {"not_legend_test":{"kind":"product","tier":2,"upgrade_from":CardDB.dup_key(),"upgrade_dup_n":5}}
	with_decoy.merge(CardDB.CARDS)
	CardDB.CARDS = with_decoy
	check(ComboRules.legend_upgrade_target(1,15) == "dujiaoshou" \
		and ComboRules.legend_upgrade_target(2,5) == "dujiaoshou", "共享查询遵循旧dup_t2键、产物门槛与路线折算率，不写死4/6/8")
	check(ComboRules.evaluate(_mixed(1,15)).get("output_card") == "dujiaoshou" \
		and ComboRules.upgrade_target(str(_products(1)[0]),15) == "dujiaoshou", "同名和异名查询同时遵循修改后的配置，非传说候选不能截走结果")
	check(ComboRules.legend_upgrade_target(1,14) == "" and ComboRules.legend_upgrade_target(1,16) == "" \
		and not ComboRules.evaluate(_mixed(1,16))["valid"], "旧require_multiple=false也不能吞掉不整除的多余材料")
	CardDB.CARDS = saved_cards
	CardDB.UPGRADE = saved_rules

func test_settle_mixed_legends() -> void:
	for spec in [[1,4,"dujiaoshou"],[1,6,"guomin"],[1,8,"shangshi"],
			[2,2,"dujiaoshou"],[2,3,"guomin"],[2,4,"shangshi"]]:
		for who in [GameState.PLAYER,GameState.BOT]:
			var s := GameState.new()
			s.players = {GameState.PLAYER:{"cards":[]},GameState.BOT:{"cards":[]}}
			for seat in [GameState.PLAYER,GameState.BOT]:
				for i in 3:
					s.add_card(seat,"cash")
					s.add_card(seat,"user")
			var uids: Array = []
			for card in _mixed(spec[0],spec[1]): uids.append(s.add_card(who,card["def_id"])["uid"])
			var spare := s.add_card(who,str(_products(spec[0])[0]))
			var count_before: int = s.players[who]["cards"].size()
			check(s.create_combo(who,uids).get("ok",false), "异名升级通过真实GameState编组")
			Settle.produce(s)
			var all_consumed := true
			for uid in uids: all_consumed = all_consumed and s.find_card(who,uid).is_empty()
			var products := 0
			for card in s.players[who]["cards"]:
				if card["def_id"] == spec[2]:
					products += 1
					check(card["locked"], "新传说按正常结算锁定，不能同轮重复使用")
			check(all_consumed and products == 1 and s.players[who]["cards"].size() == count_before-spec[1]+1,
				"T%d×%d全部不同名材料消耗，仅产出一张%s" % [spec[0],spec[1],spec[2]])
			check(not s.find_card(who,spare["uid"]).is_empty() \
				and s.resource_count(who,CardDB.RES_CASH) == 3 and s.resource_count(who,CardDB.RES_USER) == 3,
				"未参加的同名卡、现金和用户原样保留")

func test_duplicate_uid_rejected() -> void:
	var s := GameState.new()
	s.set_seed(415)
	s.players = {GameState.PLAYER:{"cards":[]},GameState.BOT:{"cards":[]}}
	for seat in [GameState.PLAYER,GameState.BOT]:
		for i in 3:
			s.add_card(seat,"cash")
			s.add_card(seat,"user")
	var first := s.add_card(GameState.PLAYER,"yunketang")
	var second := s.add_card(GameState.PLAYER,"baoyue")
	var uid := int(first["uid"])
	var other_uid := int(second["uid"])
	var before := StateCodec.state_hash(s)
	var log_before := s.log.duplicate(true)
	for uids in [[uid,uid],[uid,uid,uid,uid],[uid,other_uid,uid,other_uid],
			[uid,float(uid),other_uid,other_uid]]:
		var result := s.create_combo(GameState.PLAYER,uids)
		check(not result.get("ok",false) and result.get("code") == "duplicate_uid" \
			and result.get("reason") == ComboRules.REASON_DUPLICATE_CARD,
			"引擎入口明确拒绝重复实体，不能用引用次数凑T2或传说门槛")
		check(StateCodec.state_hash(s) == before and s.log == log_before \
			and s.combos.is_empty() and not first["locked"] and not second["locked"],
			"拒绝重复材料时卡牌、资源、组合、锁定、日志和随机流完全不变")
	var app := IntentApply.new(s)
	var applied := app.apply(Intent.create_combo(GameState.PLAYER,[uid,uid,uid,uid]),GameState.PLAYER)
	check(not applied.get("ok",false) and applied.get("code") == "duplicate_uid" \
		and StateCodec.state_hash(s) == before, "真实意图管道也不能绕过重复UID校验")
	Settle.produce(s)
	check(StateCodec.state_hash(s) == before, "拒绝后即使继续结算也不会消费材料或凭空生成传说")
	var copies: Array = [first,first,first,first]
	check(not ComboRules.evaluate(copies)["valid"], "规则预览也拒绝同一实体重复引用")
	copies = [first.duplicate(true),first.duplicate(true),first.duplicate(true),first.duplicate(true)]
	check(not ComboRules.evaluate(copies)["valid"], "复制字典不改变UID身份，仍不能算四张卡")
	var descriptors: Array = []
	for i in 4: descriptors.append({"def_id":"yunketang"})
	check(ComboRules.evaluate(descriptors).get("output_card") == "dujiaoshou", "不强制纯规则描述提供UID，四份无UID描述仍可查询路线")
	var distinct: Array = [uid,other_uid]
	for id in ["ditui","pinshaoshao"]: distinct.append(s.add_card(GameState.PLAYER,id)["uid"])
	check(s.create_combo(GameState.PLAYER,distinct).get("ok",false), "四张不同真实实体仍可正常混名升级")
	Settle.produce(s)
	var consumed := true
	for material_uid in distinct: consumed = consumed and s.find_card(GameState.PLAYER,material_uid).is_empty()
	var legends := 0
	for card in s.players[GameState.PLAYER]["cards"]:
		if card["def_id"] == "dujiaoshou": legends += 1
	check(consumed and legends == 1, "合法四实体全部消耗且只产出一个传说，重复UID修复不拦正常升级")


## 走完整结算：同名 T2 攒满最高档真的变出传说卡，且资源一张不掉
func test_settle_to_legend() -> void:
	var ladder := dup_ladder()
	var top: int = CardDB.max_upgrade_dup_n()
	var legend: String = ladder[top]
	var core: String = _products(2)[0]
	print("\n【6】结算：同名 T2×%d → %s" % [top, CardDB.card_name(legend)])
	var s := GameState.new()
	s.set_seed(2026)
	s.new_game()
	s.players[GameState.PLAYER]["cards"].clear()
	var uids: Array = []
	for i in top:
		uids.append(s.add_card(GameState.PLAYER, core)["uid"])
	# 现金正好摆一份该卡的配方：升级组要是错按配方付账，这笔就会被扣光，
	# 下面那条「现金没掉」才抓得住（多备几张的话扣掉一部分也还剩着）
	for i in int(CardDB.get_def(core)["recipe_n"]):
		s.add_card(GameState.PLAYER, "cash")
	var n_user := 4        # 摆几张用户是判据自己的规模，升级不看用户
	for i in n_user:
		s.add_card(GameState.PLAYER, "user")
	var cash_before := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var user_before := s.resource_count(GameState.PLAYER, CardDB.RES_USER)
	var r := s.create_combo(GameState.PLAYER, uids)
	check(r["ok"], "编组成立：%s" % r.get("reason", ""))
	Settle.run(s)
	var n_legend := 0
	var n_t2 := 0
	for c in s.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == legend:
			n_legend += 1
		elif c["def_id"] == core:
			n_t2 += 1
	check(n_legend == 1, "场上多出 1 张%s（实际 %d）" % [CardDB.card_name(legend), n_legend])
	check(n_t2 == 0, "%d 张%s全部消耗（剩 %d）" % [top, CardDB.card_name(core), n_t2])
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_before,
		"现金没掉（%d → %d）" % [cash_before, s.resource_count(GameState.PLAYER, CardDB.RES_CASH)])
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == user_before,
		"用户没掉（%d → %d）" % [user_before, s.resource_count(GameState.PLAYER, CardDB.RES_USER)])
	# 升级不吃资源，那「升上去」的收益就全在回收价里：几张 T2 并成一张传说卡，
	# 典当价必须高过被吃掉的那几张之和，否则升级是净亏、这条路没人会走。
	# 具体数值钉在 test_pawn（那儿是价目表），这里只钉这个不等式
	var eaten: int = CardDB.pawn_value(core) * top
	check(CardDB.pawn_value(legend) > eaten,
		"升级划算：%s回收 %d > 吃掉的 %d 张共 %d" % [
			CardDB.card_name(legend), CardDB.pawn_value(legend), top, eaten])


## 走完整结算：同名 T1 攒满上界一步变出传说卡（不必先合成 T2）
func test_settle_t1_direct() -> void:
	var ladder := dup_ladder()
	var top: int = CardDB.max_upgrade_dup_n()
	var legend: String = ladder[top]
	var n_t1_need: int = top * 2
	# 挑一张有对应 T2 的 T1：这一节考的是「有低档路线也不绕」
	var core: String = str(CardDB.get_def(_products(2)[0]).get("upgrade_from", ""))
	print("\n【6b】结算：同名 T1×%d → %s（一步）" % [n_t1_need, CardDB.card_name(legend)])
	var s := GameState.new()
	s.set_seed(2027)
	s.new_game()
	s.players[GameState.PLAYER]["cards"].clear()
	var uids: Array = []
	for i in n_t1_need:
		uids.append(s.add_card(GameState.PLAYER, core)["uid"])
	# 现金摆一份该 T1 的配方：它的配方吃现金，升级组错按配方付账就会扣光
	for i in int(CardDB.get_def(core)["recipe_n"]):
		s.add_card(GameState.PLAYER, "cash")
	var n_user := 3        # 判据自己的规模
	for i in n_user:
		s.add_card(GameState.PLAYER, "user")
	var cash_before := s.resource_count(GameState.PLAYER, CardDB.RES_CASH)
	var user_before := s.resource_count(GameState.PLAYER, CardDB.RES_USER)
	var r := s.create_combo(GameState.PLAYER, uids)
	check(r["ok"], "%d 张%s编成一组：%s" % [
		n_t1_need, CardDB.card_name(core), r.get("reason", "")])
	Settle.run(s)
	var n_legend := 0
	var n_t1 := 0
	for c in s.players[GameState.PLAYER]["cards"]:
		if c["def_id"] == legend:
			n_legend += 1
		elif c["def_id"] == core:
			n_t1 += 1
	check(n_legend == 1, "场上多出 1 张%s（实际 %d）" % [CardDB.card_name(legend), n_legend])
	check(n_t1 == 0, "%d 张%s全部消耗（剩 %d）" % [n_t1_need, CardDB.card_name(core), n_t1])
	# 直达也是纯卡面合成：这张 T1 的配方吃现金，但升级组不该按配方付账
	check(s.resource_count(GameState.PLAYER, CardDB.RES_CASH) == cash_before,
		"现金没掉（%d → %d）" % [cash_before, s.resource_count(GameState.PLAYER, CardDB.RES_CASH)])
	check(s.resource_count(GameState.PLAYER, CardDB.RES_USER) == user_before,
		"用户没掉（%d → %d）" % [user_before, s.resource_count(GameState.PLAYER, CardDB.RES_USER)])
	# 直达和两步走必须是同一个终点：一步 T1×2k 和两步（T1×2 → T2，再 T2×k）
	# 落到同一张卡，回收价自然同一个。钉「终点相同」而不是钉某个数字 ——
	# 两条路各自换了产物时这里响，而回收价只要还相等就照样过
	check(ComboRules.upgrade_target(core, n_t1_need)
			== ComboRules.upgrade_target(_products(2)[0], top),
		"一步和两步走同一个终点（%s）" % CardDB.card_name(legend))
	var eaten_t1: int = CardDB.pawn_value(core) * n_t1_need
	check(CardDB.pawn_value(legend) > eaten_t1,
		"升级划算：%s %d > %d 张%s共 %d" % [
			CardDB.card_name(legend), CardDB.pawn_value(legend),
			n_t1_need, CardDB.card_name(core), eaten_t1])


## 每条数据定义的升级路线都应进入候选，并由环境验证其意图。
func test_bot_builds_dup_upgrades() -> void:
	var Actions = preload("res://engine/bot_actions.gd")
	var Env = preload("res://engine/bot_environment.gd")
	for core in _products(1) + _products(2):
		for count in range(2, CardDB.max_upgrade_n() + 1):
			var target := ComboRules.upgrade_target(str(core), count)
			if target == "":
				continue
			var s := GameState.new()
			s.players = {GameState.PLAYER: {"cards": []}, GameState.BOT: {"cards": []}}
			for i in count:
				s.add_card(GameState.BOT, core)
			var found := false
			var profile := BOTSearch.from_model("bot", 0.0).resolved_parameters()
			profile.merge({"plans": 256, "sales": 0, "buy_beam": 256, "build_beam": 256}, true)
			for node in Actions.generate(s, GameState.BOT, profile):
				var candidate: GameState = node["state"]
				for combo in candidate.combos:
					if combo["eval"].get("output_card", "") == target and combo["uids"].size() == count:
						found = true
						var replay := Env.copy(s)
						check(Env.replay(replay, node["intents"]), "升级候选意图可由环境回放")
			check(found, "%s×%d 有通向 %s 的零资源升级候选" % [core, count, target])
