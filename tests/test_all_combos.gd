# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 每张核心卡编成组合之后，到底生不生效 —— 全表逐张过一遍（README.md §「2.6 组合与结算」）
##
## 起因是一份实测：「山寨围剿组合已经完成，但是没有发动」。查下来根因不在
## 那张卡，而在**攻击组合的配方料同时是攻击目标**：山寨要 6 个用户当席位，
## 而 `attack_targets` 把组里超出 `protect_quota` 的富余料按 1 点 1 张挂成靶子，
## 配方内那几张也在对手够得着的范围里。谁先攻击谁就能把对方的攻击组吃掉。
##
## 这一份不查那条互动（那是设计，见 game_state.gd `arm_attacks` 的注释），
## 查的是**每张卡自己那条链路走不走得通**：评估 → 编组 → 装弹/结算 → 状态真的变了。
## 一张卡漏一个环节，症状就是「组合摞好了，什么也没发生」，而这种漏是静默的：
## 战报里没有失败行，HUD 也不报错，只有资源数字对不上。
##
## 为什么值得整表拉一遍而不是抽查几张：
## 带配方的核心卡分四类（吃现金生产 / 吃用户生产 / 吃现金攻击 / 吃用户攻击），
## 四类各自走不同分支 —— `recipe_pay_n` 只在吃现金时非零、
## 攻击走 `arm_attacks` 而生产走 `Settle.produce`。上一轮那个 bug
## （AI 预判不累计）只砸中「吃现金」那一类，抽查很容易全抽在另一边。
## 所以判据从卡表现读，卡表加一张卡这里自动多查一张，不用回来补。
##
## 六组判据：
##   T1 生产卡  —— 全部 product：配方够 → 产出准（含吃现金那类要留 1 块）
##   T2 攻击卡  —— 全部 attack：装弹 → 点数池 = attack_n → 真打掉对方的卡
##   T3 升级卡  —— 同名升T2、同档可混名升传说，且吃掉全部参与材料
##   T4 Buff    —— 翻倍/补满/防御各自作用在哪个字段上
##   T5 配方差一 —— 每张卡都要在差 1 张料时判 invalid（不能靠富余料蒙过去）
##   T6 走管道  —— 同样的事经 IntentApply 再来一遍：人和 AI 都走那条路
##
## 变异提示已登记进 tools/mutate_check.py 第 29 组（那里是实跑的，注释不算数）：
##   combo_rules.gd 的 attack_n 去掉 attack_x2 乘数         → 红 4 条
##   combo_rules.gd 的 recipe_pay_n 改成无条件设置          → 红 14 条
##   settle.gd 的 _consume_upgrade_materials 不调用         → 红 10 条
##   game_state.gd 的 _attack_pool 去掉 combo_intact        → 红 2 条（见 _t2b）

const GameState = preload("res://engine/game_state.gd")
const Settle = preload("res://engine/settle.gd")

func _initialize() -> void:
	print("=== 全卡表组合生效 测试 ===\n")
	CardDB.ensure_loaded()
	_t1_production_cards()
	_t2_attack_cards()
	_t3_upgrade_cards()
	_t4_buffs()
	_t5_recipe_short_by_one()
	_t6_through_pipe()
	_t7_with_fixed_rules()
	finish()


# ---------- 夹具 ----------

## 空桌子起一局：清掉双方手牌，开局那份 `_game.start_cash` / `start_user` 会盖掉所有判据。
## 保命现金按需另发 —— 归零是败北条件，`finalize` 每回合无条件判一次
func _bare() -> GameState:
	var s := GameState.new()
	s.new_game()
	for who in [GameState.PLAYER, GameState.AI]:
		s.players[who]["cards"] = []
	return s


## 发 n 张单位卡给 who，返回 uid 列表。locked 默认 true（调用方紧接着 create_combo）
func _units(s: GameState, who: String, res: String, n: int, locked := true) -> Array:
	var out: Array = []
	for i in n:
		out.append(int(s.add_card(who, CardDB.unit_id(res), locked)["uid"]))
	return out


## 保命垫：这一摞资源不进任何组合，纯粹让 check_victory 别当场判负。
## 两种资源都要垫 —— `check_victory` 现金归零和用户归零都判负
func _keepalive(s: GameState, who: String, cash := 3, user := 3) -> void:
	_units(s, who, CardDB.RES_CASH, cash, false)
	_units(s, who, CardDB.RES_USER, user, false)


func _res(s: GameState, who: String, res: String) -> int:
	return s.resource_count(who, res)


## 卡表里所有 kind == k 的卡（按 def_id 排序，让失败行的次序稳定）
func _cards_of_kind(k: String) -> Array:
	var out: Array = []
	var all: Dictionary = CardDB.all_cards()
	var ids: Array = all.keys()
	ids.sort()
	for def_id in ids:
		if str(all[def_id].get("kind", "")) == k:
			out.append(def_id)
	return out


## 摞一组并注册：核心卡 + 配方料（按卡表的 recipe_res/recipe_n 现取）。
## extra_units：额外富余料 [[res, n], …]；extra_ids：额外具体卡（Buff 等）
func _build(
	s: GameState, who: String, core_id: String,
	extra_ids: Array = [], extra_units: Array = []
) -> Dictionary:
	var def: Dictionary = CardDB.get_def(core_id)
	var uids: Array = [int(s.add_card(who, core_id, true)["uid"])]
	if def.get("recipe_res", "") != "":
		uids += _units(s, who, str(def["recipe_res"]), int(def["recipe_n"]))
	for eid in extra_ids:
		uids.append(int(s.add_card(who, eid, true)["uid"]))
	for pair in extra_units:
		uids += _units(s, who, str(pair[0]), int(pair[1]))
	var r := s.create_combo(who, uids)
	r["uids"] = uids
	return r


# ---------- T1 生产卡：配方够 → 产出准 ----------

## 卡表里的 product 全部走一遍：编组 → Settle.produce → 数产出。
##
## 吃现金那几张要多备 1 块：付完归零的护栏会让整组作废
## （tests/test_recipe_pay_order.gd 专门查那条，这里只是别撞上它）
func _t1_production_cards() -> void:
	print("\n-- T1 生产卡逐张：配方够就该产出 --")
	var ids := _cards_of_kind(CardDB.KIND_PRODUCT)
	# 升级产物（有 upgrade_from 的 T2）也是 product，但它们的「生效」是被升级出来，
	# 单张摞起来同样该生产 —— 所以这里不排除，只按有没有 output_res 分流
	var checked := 0
	for core_id in ids:
		var def: Dictionary = CardDB.get_def(core_id)
		if str(def.get("output_res", "")) == "":
			continue
		var s := _bare()
		var who := GameState.PLAYER
		var name: String = def.get("name", core_id)
		# 吃现金的组：护栏念的是「付完还剩几块」，垫够再加 1
		var pay_cash: bool = str(def.get("recipe_res", "")) == CardDB.RES_CASH
		_keepalive(s, who, 2 if pay_cash else 2, 2)
		var before_out := _res(s, who, str(def["output_res"]))
		var r := _build(s, who, core_id)
		check(r["ok"], "%s（%s）编得成：%s" % [name, core_id, r.get("reason", "")])
		if not r["ok"]:
			continue
		var ev: Dictionary = s.combos[0]["eval"]
		check(ev["type"] == "production",
			"%s 判成生产（实 %s）" % [name, ev["type"]])
		check(int(ev["output_n"]) == int(def["output_n"]),
			"%s 产出量 %d（卡表 %d）" % [name, int(ev["output_n"]), int(def["output_n"])])
		# 吃现金 → recipe_pay_n 非零；吃用户 → 必须是 0（席位不是成本）
		var want_pay: int = int(def["recipe_n"]) if pay_cash else 0
		check(int(ev.get("recipe_pay_n", 0)) == want_pay,
			"%s 待付现金 %d（该是 %d —— 用户配方是席位，不该被吃掉）" % [
				name, int(ev.get("recipe_pay_n", 0)), want_pay])
		Settle.produce(s)
		var after_out := _res(s, who, str(def["output_res"]))
		check(after_out == before_out + int(def["output_n"]),
			"%s 真产出了：%s %d → %d（+%d）" % [
				name, str(def["output_res"]), before_out, after_out,
				int(def["output_n"])])
		checked += 1
	# 该查几张从卡表数，并且判**相等**：原先写的是 `>= 11`、文案却说「应有 15 张」，
	# 两个数互相矛盾 —— 悄悄少掉 4 张生产卡这条照旧绿，而文案还在报 15。
	# 松量在这儿没有用处：这个循环只跳过「没有 output_res 的 product」，
	# 跳过几张是卡表说了算的确定值
	var want_checked := 0
	for core_id in ids:
		if str(CardDB.get_def(core_id).get("output_res", "")) != "":
			want_checked += 1
	check(checked == want_checked, "带产出的生产卡逐张都查了：%d / 卡表 %d 张" % [
		checked, want_checked])


# ---------- T2 攻击卡：装弹 → 点数池 → 真打掉东西 ----------

## 6 张 attack 全部走一遍。**这一组是那个 bug 的直接归属地**。
##
## 对手侧只发散卡：散卡 1 点 1 张（`attack_targets` 的 "loose" 那支），
## 所以「点数池 = attack_n」和「打掉 attack_n 张」是同一句话的两头。
## 靶子给够 attack_n + 2，免得判据变成「对手没料了」
func _t2_attack_cards() -> void:
	print("\n-- T2 攻击卡逐张：装弹就该开火 --")
	var checked := 0
	var atk_ids: Array = _cards_of_kind(CardDB.KIND_ATTACK)
	for core_id in atk_ids:
		var def: Dictionary = CardDB.get_def(core_id)
		var s := _bare()
		var who := GameState.PLAYER
		var foe := GameState.AI
		var name: String = def.get("name", core_id)
		var atk_res := str(def["attack_res"])
		var atk_n := int(def["attack_n"])
		# 我方保命 + 弹药（吃现金的攻击卡要付 recipe_n，且付完不能归零）
		_keepalive(s, who, 3, 3)
		# 对手：靶子只发散卡，且两种资源都垫住 —— 打光某一种会触发「清零即胜」，
		# 攻击循环当场 break，后面的判据就读不到完整战果了
		_units(s, foe, atk_res, atk_n + 2, false)
		var other := CardDB.RES_USER if atk_res == CardDB.RES_CASH else CardDB.RES_CASH
		_units(s, foe, other, 3, false)
		var r := _build(s, who, core_id)
		check(r["ok"], "%s（%s）编得成：%s" % [name, core_id, r.get("reason", "")])
		if not r["ok"]:
			continue
		var ev: Dictionary = s.combos[0]["eval"]
		check(ev["type"] == "attack", "%s 判成攻击（实 %s）" % [name, ev["type"]])
		check(int(ev["attack_n"]) == atk_n,
			"%s 攻击点 %d（卡表 %d）" % [name, int(ev["attack_n"]), atk_n])
		check(s.combo_intact(who, s.combos[0]), "%s 组合齐整（不齐整就不会开火）" % name)
		# 装弹前先读一次纯读的池子：两者必须一致，否则 HUD 显示的和实际开火的不是一回事
		var peek: Dictionary = s.attack_pool(who)
		check(int(peek[atk_res]) == atk_n,
			"%s 点数池（纯读）%s×%d（该是 %d）" % [name, atk_res, int(peek[atk_res]), atk_n])
		var foe_before := _res(s, foe, atk_res)
		Settle.attack_phase(s, who)
		var foe_after := _res(s, foe, atk_res)
		check(foe_before - foe_after == atk_n,
			"%s 真打掉了 %d 张：对手 %s %d → %d" % [
				name, atk_n, atk_res, foe_before, foe_after])
		checked += 1
	# 该查几张从卡表数，别写死：这个循环只在「编不成组」时跳过（那种情况上面已经报错），
	# 全绿时逐张都该查到。原先钉着 6 并且文案也复述 6，加一张攻击卡就得改两处
	check(checked == atk_ids.size(), "攻击卡逐张都查了：%d / 卡表 %d 张" % [
		checked, atk_ids.size()])
	_t2b_broken_combo_cannot_fire()


## 被拆散的攻击组不许出点数（`_attack_pool` 的 combo_intact 那道闸）。
##
## 单独立一条是因为上面那一圈**盯不住这道闸** —— 实跑验证过：把
## `if not combo_intact(...)` 整行删掉，上面 6 张全绿照旧。那一圈里组合
## 从头到尾都是齐整的，闸门永远为真，删掉自然没人喊。
## 攻击卡的配方料被对手啃掉一张是常规局面，这道闸漏了就等于「组已经散了还在开火」
func _t2b_broken_combo_cannot_fire() -> void:
	var s := _bare()
	var who := GameState.PLAYER
	var foe := GameState.AI
	_keepalive(s, who, 3, 3)
	_units(s, foe, CardDB.RES_USER, 8, false)
	var r := _build(s, who, "shanzhai")
	check(r["ok"], "拆散前：山寨编得成：%s" % r.get("reason", ""))
	var attack_n := int(CardDB.get_def("shanzhai")["attack_n"])
	check(int(s.attack_pool(who)[CardDB.RES_USER]) == attack_n, "拆散前有卡表规定的 %d 点" % attack_n)
	# 抽掉配方里的一张用户 → 6 席只剩 5，组合不再成立
	var victim := -1
	for u in (s.combos[0]["uids"] as Array):
		var c := s.find_card(who, int(u))
		if not c.is_empty() and CardDB.get_def(c["def_id"]).get("res", "") == CardDB.RES_USER:
			victim = int(u)
			break
	check(victim != -1, "找得到一张配方用户卡")
	check(s.remove_card(who, victim), "抽掉那张")
	check(not s.combo_intact(who, s.combos[0]), "组合判为已拆散")
	check(int(s.attack_pool(who)[CardDB.RES_USER]) == 0,
		"拆散后点数池归零（实 %d）" % int(s.attack_pool(who)[CardDB.RES_USER]))
	var before := _res(s, foe, CardDB.RES_USER)
	Settle.attack_phase(s, who)
	check(_res(s, foe, CardDB.RES_USER) == before,
		"拆散的组一张也打不掉（对手 user %d → %d）" % [before, _res(s, foe, CardDB.RES_USER)])


# ---------- T3 升级卡：纯生产卡 → 出产物，且吃掉全部源卡 ----------

## 卡表里所有带 upgrade_from 的卡，逐张反推「要几张什么」再摞出来。
## 判据从 upgrade_from/upgrade_dup_n 现读 —— 写死 [2,3,4] 会和卡表漂开
## （combo_rules.gd `_upgrade_miss_reason` 的注释就是在说这件事）
func _t3_upgrade_cards() -> void:
	print("\n-- T3 升级卡逐张：同名升T2、混名同档升传说 --")
	var all: Dictionary = CardDB.all_cards()
	var ids: Array = all.keys()
	ids.sort()
	var checked := 0
	for target_id in ids:
		var tdef: Dictionary = all[target_id]
		var src_key := str(tdef.get("upgrade_from", ""))
		if src_key == "":
			continue
		var need_n := int(tdef.get("upgrade_dup_n", 0))
		var tname: String = tdef.get("name", target_id)
		# self 来源保持同名；旧 dup_t2 键现在表示任意同档生产卡的传说路线。
		var sources: Array = [src_key]
		if src_key == CardDB.dup_key():
			sources.clear()
			for cand in ids:
				var cd: Dictionary = all[cand]
				if cd.get("kind") == CardDB.KIND_PRODUCT and int(cd.get("tier", 0)) == 2:
					sources.append(cand)
		var s := _bare()
		var who := GameState.PLAYER
		_keepalive(s, who, 3, 3)
		var uids: Array = []
		for i in need_n:
			uids.append(int(s.add_card(who, sources[i % sources.size()], true)["uid"]))
		var r := s.create_combo(who, uids)
		check(r["ok"], "%s：%d 张所需生产卡编得成：%s" % [tname, need_n, r.get("reason", "")])
		if not r["ok"]:
			continue
		var ev: Dictionary = s.combos[0]["eval"]
		check(ev["type"] == "upgrade", "%s 判成升级（实 %s）" % [tname, ev["type"]])
		check(str(ev["output_card"]) == target_id,
			"%s 产物是 %s（实 %s）" % [tname, target_id, str(ev["output_card"])])
		Settle.produce(s)
		# 产物到手
		var got := 0
		for c in s.players[who]["cards"]:
			if c["def_id"] == target_id:
				got += 1
		check(got == 1, "%s 仅产出一张" % tname)
		# 逐个实际 UID 检查，异名材料也必须全部消耗，不只查领头那张卡的类型。
		var left := 0
		for uid in uids:
			if not s.find_card(who,uid).is_empty(): left += 1
		check(left == 0, "%s 的 %d 张源卡被吃掉了（还剩 %d）" % [tname, need_n, left])
		checked += 1
	# 条数从卡表现数：加一张 T2 就该自动多查一条，写死数字只会拦住加卡
	var routes := 0
	for id in CardDB.all_cards():
		if str(CardDB.get_def(id).get("upgrade_from", "")) != "":
			routes += 1
	# 判**相等**而不是 `>=`：这个循环只跳过「没有 upgrade_from」（那些 routes 也不数）
	# 和「编不成组」（上面已经报错），全绿时逐条都该查到。
	# 松成 `>=` 的话悄悄少查几条照旧绿，而文案还在报卡表的条数
	check(checked == routes, "升级路线逐条都查了：%d / 卡表 %d 条" % [checked, routes])


# ---------- T4 Buff：各自作用在哪个字段上 ----------

## 四种 Buff 各查一条，判的是「作用点没串线」：
## 996 只该动 output_n、热搜只该动 attack_n、裂变只该动配方门槛、
## 防御只该动 protect_* —— 串线的典型症状是「热搜给生产组翻倍」
func _t4_buffs() -> void:
	print("\n-- T4 Buff 各自的作用点 --")
	# 996 引擎：生产翻倍，不碰攻击
	var s := _bare()
	_keepalive(s, GameState.PLAYER, 3, 3)
	var r := _build(s, GameState.PLAYER, "yunketang", ["yinqing996"])
	check(r["ok"], "云课堂 + 996 编得成：%s" % r.get("reason", ""))
	var ev: Dictionary = s.combos[0]["eval"]
	# 期望值按「卡面 × _game.buff_mult」现算：这一条量的是作用点没串线，倍数是旋钮
	var yun_out := int(CardDB.get_def("yunketang")["output_n"])
	var m_out := CardDB.buff_mult("output_x2")
	check(int(ev["output_n"]) == yun_out * m_out, "996 让云课堂产出 %d→%d（实 %d）" % [
		yun_out, yun_out * m_out, int(ev["output_n"])])
	# 生产组根本不该有 attack_n 这个键（combo_rules 只在攻击分支写它），
	# 所以判 get 默认值 —— 写 ev["attack_n"] 会直接报错而不是判假
	check(int(ev.get("attack_n", 0)) == 0, "996 不该给生产组凭空造攻击点")
	# 热搜包年：攻击翻倍，不碰产出
	s = _bare()
	_keepalive(s, GameState.PLAYER, 3, 3)
	r = _build(s, GameState.PLAYER, "shanzhai", ["resou"])
	check(r["ok"], "山寨 + 热搜 编得成：%s" % r.get("reason", ""))
	ev = s.combos[0]["eval"]
	var sz_atk := int(CardDB.get_def("shanzhai")["attack_n"])
	var m_atk := CardDB.buff_mult("attack_x2")
	check(int(ev["attack_n"]) == sz_atk * m_atk, "热搜让山寨攻击 %d→%d（实 %d）" % [
		sz_atk, sz_atk * m_atk, int(ev["attack_n"])])
	check(int(ev.get("output_n", 0)) == 0, "热搜不该给攻击组造产出")
	check(int(s.attack_pool(GameState.PLAYER)[CardDB.RES_USER]) == sz_atk * m_atk,
		"翻倍要进点数池 —— %d 点才啃得动更大的组（README.md §「2.9 攻击」的攻击池规则）" % (sz_atk * m_atk))
	# 裂变鬼才：1 张用户顶满配方
	s = _bare()
	_keepalive(s, GameState.PLAYER, 3, 3)
	var uids: Array = [int(s.add_card(GameState.PLAYER, "shuabuting", true)["uid"])]
	uids.append(int(s.add_card(GameState.PLAYER, "liebian", true)["uid"]))
	uids += _units(s, GameState.PLAYER, CardDB.RES_USER, 1)
	r = s.create_combo(GameState.PLAYER, uids)
	check(r["ok"], "刷不停（用户×7）+ 裂变 + 1 用户 编得成：%s" % r.get("reason", ""))
	if r["ok"]:
		ev = s.combos[0]["eval"]
		check(ev.get("filled_by_fission", false), "标成了裂变补满")
		check(GameState.protect_quota(ev) == 1,
			"补满组的保护额度是 1 不是 7（实 %d）" % GameState.protect_quota(ev))
	# 防御 Buff：编组当回合即保护，之后按同样的配方额度持续保护
	s = _bare()
	_keepalive(s, GameState.PLAYER, 3, 3)
	r = _build(s, GameState.PLAYER, "yunketang", ["tuisong"])
	check(r["ok"], "云课堂 + 推送弹窗 编得成：%s" % r.get("reason", ""))
	ev = s.combos[0]["eval"]
	check(ev.get("protect_user", false), "标记了 protect_user")
	var quota := GameState.protect_quota(ev)
	var actually_protected: int = s.protected_uids(
		GameState.PLAYER, s.combos[0], CardDB.RES_USER).size()
	check(actually_protected == quota,
		"入组当回合即护满额度（额度 %d，实际保护 %d）" % [quota, actually_protected])
	s.round_num += 1
	actually_protected = s.protected_uids(
		GameState.PLAYER, s.combos[0], CardDB.RES_USER).size()
	check(actually_protected == quota,
		"下一回合继续护满额度 %d（实 %d）" % [quota, actually_protected])


# ---------- T5 差一张：每张带配方的卡都要在 n-1 处判废 ----------

## 上界（够就成）T1/T2 已经查过了，这里查下界。
## 两头都钉住，`_recipe_miss_reason` 的比较符写成 >= 还是 > 才跑不掉
func _t5_recipe_short_by_one() -> void:
	print("\n-- T5 配方差一张：必须判废 --")
	var all: Dictionary = CardDB.all_cards()
	var ids: Array = all.keys()
	ids.sort()
	var checked := 0
	for def_id in ids:
		var cdef: Dictionary = all[def_id]
		if not cdef.has("recipe_res"):
			continue
		var need := int(cdef.get("recipe_n", 0))
		if need <= 0:
			continue
		var s := _bare()
		var who := GameState.PLAYER
		_keepalive(s, who, 3, 3)
		var uids: Array = [int(s.add_card(who, def_id, true)["uid"])]
		uids += _units(s, who, str(cdef["recipe_res"]), need - 1)
		var r := s.create_combo(who, uids)
		check(not r["ok"], "%s：配方要 %d 只给 %d，必须编不成" % [
			CardDB.card_name(def_id), need, need - 1])
		checked += 1
	# 应查张数从卡表数一遍，不写死：加卡不用回来改这个数，
	# 但「一张都没查到」（比如 recipe_res 改了键名）还是会红
	var expect := 0
	for def_id in ids:
		if int(all[def_id].get("recipe_n", 0)) > 0:
			expect += 1
	check(expect > 0, "卡表里确实有带配方的卡")
	check(checked == expect, "带配方的卡查了 %d 张（卡表里共 %d 张）" % [checked, expect])


# ---------- T6 走 IntentApply：人和 AI 实际走的那条管子 ----------

## T1-T5 都是直接调 create_combo/attack_pool，绕开了意图层。
## 但玩家点「完成行动」走的是 IntentApply，AI 也走它 —— 引擎对了而管子接错，
## 上面全绿也照样是「组合完成了但没发动」。这一组就为了堵这个缺口
func _t6_through_pipe() -> void:
	print("\n-- T6 意图层：编组→保护→结算 整条链 --")
	var s := _bare()
	var who := GameState.PLAYER
	var foe := GameState.AI
	_keepalive(s, who, 3, 3)
	var atk_n := int(CardDB.get_def("shanzhai")["attack_n"])
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	# 对手摊开够花完的散用户（散卡按 attack_cost_per_card 一张一份），多垫几张
	_units(s, foe, CardDB.RES_USER, atk_n / per_card + 4, false)
	_units(s, foe, CardDB.RES_CASH, 3, false)
	var r := _build(s, who, "shanzhai")
	check(r["ok"], "意图层前置：山寨编得成：%s" % r.get("reason", ""))
	var before := _res(s, foe, CardDB.RES_USER)
	# IntentApply 是实例方法，池子存在实例里；意图走 {op, seat} 的字典形式
	var ia := IntentApply.new(s)
	var arm: Dictionary = ia.apply({"op": Intent.OP_ARM, "seat": who})
	check(arm.get("ok", false), "arm 成功：%s" % str(arm.get("reason", "")))
	check(int(ia.pools(who)[CardDB.RES_USER]) == atk_n,
		"意图层的池子里有 %d 点" % atk_n)
	# 同回合第二次装弹要被拒（_arm 会真扣配方钱，发两次等于付两次）
	var arm2: Dictionary = ia.apply({"op": Intent.OP_ARM, "seat": who})
	check(not arm2.get("ok", true), "同回合重复装弹被拒")
	check(str(arm2.get("code", "")) == "already_armed",
		"拒的理由是 already_armed（实 %s）" % str(arm2.get("code", "")))
	# 逐个靶子打完整池：靶子从状态重算，不从包里读 cost
	for i in atk_n / per_card:
		var ts: Array = s.attack_targets(foe)
		var picked := {}
		for t in ts:
			if str(t["res"]) == CardDB.RES_USER and int(t["cost"]) <= per_card:
				picked = t
				break
		check(not picked.is_empty(), "第 %d 点有散卡靶子可点" % (i + 1))
		if picked.is_empty():
			break
		var ar: Dictionary = ia.apply({
			"op": Intent.OP_ATTACK, "seat": who, "target": picked})
		check(ar.get("ok", false), "第 %d 点打出去了：%s" % [i + 1, str(ar.get("reason", ""))])
	var after := _res(s, foe, CardDB.RES_USER)
	check(before - after == atk_n / per_card, "走管子也真打掉 %d 张：对手 user %d → %d" % [
		atk_n / per_card, before, after])
	# 用户配方是永久席位：打完自己那几张席位还在，下回合能白开火
	var seats := int(CardDB.get_def("shanzhai")["recipe_n"])
	check(_res(s, who, CardDB.RES_USER) >= seats,
		"吃用户的攻击卡不付钱，%d 张席位打完还在（实 %d）" % [
			seats, _res(s, who, CardDB.RES_USER)])


# ---------- T7 钉住「组合完成了但没发动」那个场面 ----------

## 钉的是**核心的定价**：组内配方核心按 `_game.attack_cost_per_card` 逐张独立可点
## （README.md §「2.9 攻击」）。所以对满席的刷不停：一份点数就啃掉一张、配方告破，
## 山寨那一池更是绰绰有余。
##
## 这条原先钉的是反过来的门槛（核心是「一减到底」的整体靶，cost=席位数，
## 山寨那一池一张也碰不到）。那个定价被判为 bug —— 「组合完成了却一张都打不掉」，
## 而且余点永远凑不满下一个组的整份核心。改价之后「点数正好够啃穿全席」和
## 「翻倍后超出」两个对照组照旧留着：它们保证「攻击真的会生效」，
## 不然「一份点数就够」这半边在攻击系统整个坏掉时也绿
## 这组边界需要「原攻击不足、两组恰好够、翻倍超过」三种关系。
## 只在测试内明确构造，避免把当前平衡表的数值关系当成游戏规则。
func _t7_with_fixed_rules() -> void:
	var saved_cards := CardDB.CARDS
	var saved_game := CardDB.GAME
	CardDB.CARDS = saved_cards.duplicate(true)
	CardDB.GAME = saved_game.duplicate(true)
	CardDB.GAME["attack_cost_per_card"] = 1
	CardDB.GAME["buff_mult"]["attack_x2"] = 2
	CardDB.CARDS["shanzhai"].merge({"recipe_res": "user", "recipe_n": 3, "attack_res": "user", "attack_n": 4}, true)
	CardDB.CARDS["butie"].merge({"recipe_res": "cash", "recipe_n": 3, "attack_res": "user", "attack_n": 3}, true)
	CardDB.CARDS["shuabuting"].merge({"recipe_res": "user", "recipe_n": 7, "output_res": "cash", "output_n": 10}, true)
	_t7_core_is_one_point_each()
	CardDB.CARDS = saved_cards
	CardDB.GAME = saved_game

func _t7_core_is_one_point_each() -> void:
	print("\n-- T7 配方核心按 attack_cost_per_card 逐张计价（CardDB.game_rules 的 attack_cost_per_card 字段）--")
	var per_card := int(CardDB.game_rules()["attack_cost_per_card"])
	var seats := int(CardDB.get_def("shuabuting")["recipe_n"])
	var atk_n := int(CardDB.get_def("shanzhai")["attack_n"])
	var s := _bare()
	var who := GameState.PLAYER
	var foe := GameState.AI
	_keepalive(s, who, 3, 3)
	_keepalive(s, foe, 3, 0)
	# 对手把配方要的用户全摞进刷不停 —— 场上没有一张散用户
	var foe_uids: Array = [int(s.add_card(foe, "shuabuting", true)["uid"])]
	foe_uids += _units(s, foe, CardDB.RES_USER, seats)
	var fr := s.create_combo(foe, foe_uids)
	check(fr["ok"], "对手刷不停（用户×%d）编得成：%s" % [seats, fr.get("reason", "")])
	var r := _build(s, who, "shanzhai")
	check(r["ok"], "山寨编得成：%s" % r.get("reason", ""))
	check(int(s.attack_pool(who)[CardDB.RES_USER]) == atk_n, "点数池确实有 %d 点" % atk_n)
	# 每张核心各自成靶，每个一份
	var targets: Array = s.attack_targets(foe)
	var combo_targets: Array = []
	for t in targets:
		if str(t.get("kind", "")) == "combo" and str(t["res"]) == CardDB.RES_USER:
			combo_targets.append(t)
	check(combo_targets.size() == seats, "%d 张核心各自成靶（实 %d）" % [
		seats, combo_targets.size()])
	var all_one := true
	for t in combo_targets:
		if int(t["cost"]) != per_card:
			all_one = false
	check(all_one, "每个核心靶都要价 %d 点" % per_card)
	# 这一池够不够点满全席，由数值决定；不够也不影响下面「一份点数就啃掉一张」
	var afford := 0
	for t in targets:
		if str(t["res"]) == CardDB.RES_USER and int(t.get("cost", 99)) <= atk_n:
			afford += 1
	check(afford >= mini(seats, atk_n / per_card),
		"%d 点点得起 %d 个核心靶（实 %d 个点得起）" % [
			atk_n, mini(seats, atk_n / per_card), afford])
	# 一份点数就够啃掉一张 → 满席少 1 张 → 配方告破
	var pools := { CardDB.RES_CASH: 0, CardDB.RES_USER: per_card }
	var one: Dictionary = combo_targets[0]
	var ar: Dictionary = s.apply_attack(who, one, pools)
	check(ar["ok"], "%d 点点掉一张核心：%s" % [per_card, ar.get("reason", "")])
	check(int(pools[CardDB.RES_USER]) == 0, "只扣 %d 点" % per_card)
	check(not s.combo_intact(foe, s.combos[0]), "%d 席少 1 张 → 配方告破" % seats)
	# 走完整条攻击阶段：一池点数该实打实掉那么多张用户，不再作废
	var kill := atk_n / per_card
	var s4 := _bare()
	_keepalive(s4, who, 3, 3)
	_keepalive(s4, foe, 3, 0)
	var f4: Array = [int(s4.add_card(foe, "shuabuting", true)["uid"])]
	f4 += _units(s4, foe, CardDB.RES_USER, seats)
	check(s4.create_combo(foe, f4)["ok"], "对手刷不停编得成（第四局）")
	check(_build(s4, who, "shanzhai")["ok"], "山寨编得成（第四局）")
	var b4 := _res(s4, foe, CardDB.RES_USER)
	Settle.run(s4)
	var a4 := _res(s4, foe, CardDB.RES_USER)
	check(b4 - a4 == kill, "%d 点花得完，对手掉 %d 张用户（user %d → %d）" % [
		atk_n, kill, b4, a4])
	# 对照组一：两摞攻击卡凑够整席的点数就该把全席啃掉 —— 这半边保证
	# 「攻击真的会生效」，上面那半边才有意义（都不生效时它也会是 0 掉 0）
	var butie: Dictionary = CardDB.get_def("butie")
	var pool_two := (atk_n + int(butie["attack_n"])) / per_card
	check(pool_two >= seats,
		"夹具前提：山寨+补贴的点数够啃穿 %d 席（能点 %d 张）" % [seats, pool_two])
	var s3 := _bare()
	_keepalive(s3, who, 3, 3)
	_keepalive(s3, foe, 3, 0)
	var f3: Array = [int(s3.add_card(foe, "shuabuting", true)["uid"])]
	f3 += _units(s3, foe, CardDB.RES_USER, seats)
	check(s3.create_combo(foe, f3)["ok"], "对手刷不停编得成（第三局）")
	# 两个攻击组的点数并进同一个池子（README.md §「2.9 攻击」的攻击池汇总规则）。
	# 补贴大战的配方吃现金，得比配方量多备钱：付完归零的护栏会让整组作废
	_keepalive(s3, who, int(butie["recipe_n"]) + 3, 3)
	var r3 := _build(s3, who, "shanzhai")
	check(r3["ok"], "山寨编得成（第三局）：%s" % r3.get("reason", ""))
	var r3b := _build(s3, who, "butie")
	check(r3b["ok"], "补贴大战也编得成：%s" % r3b.get("reason", ""))
	var p3 := int(s3.attack_pool(who)[CardDB.RES_USER])
	check(p3 == atk_n + int(butie["attack_n"]),
		"两摞的点数池累加成 %d（实 %d）" % [atk_n + int(butie["attack_n"]), p3])
	var b3 := _res(s3, foe, CardDB.RES_USER)
	Settle.run(s3)
	var a3 := _res(s3, foe, CardDB.RES_USER)
	check(b3 - a3 == seats, "点数够就真啃穿 %d 席：user %d → %d" % [seats, b3, a3])
	# 对照组二：同一摞牌配热搜包年（attack_x2）翻倍后也啃穿
	# （顺带回归 buff_mult 进池子）
	var dbl := atk_n * CardDB.buff_mult("attack_x2")
	check(dbl / per_card >= seats,
		"夹具前提：山寨翻倍后够啃穿 %d 席（能点 %d 张）" % [seats, dbl / per_card])
	var s2 := _bare()
	_keepalive(s2, who, 3, 3)
	_keepalive(s2, foe, 3, 0)
	var f2: Array = [int(s2.add_card(foe, "shuabuting", true)["uid"])]
	f2 += _units(s2, foe, CardDB.RES_USER, seats)
	check(s2.create_combo(foe, f2)["ok"], "对手刷不停编得成（第二局）")
	var r2 := _build(s2, who, "shanzhai", ["resou"])
	check(r2["ok"], "山寨 + 热搜 编得成：%s" % r2.get("reason", ""))
	check(int(s2.attack_pool(who)[CardDB.RES_USER]) == dbl, "翻倍后 %d 点" % dbl)
	var b2 := _res(s2, foe, CardDB.RES_USER)
	Settle.run(s2)
	var a2 := _res(s2, foe, CardDB.RES_USER)
	check(b2 - a2 == seats, "%d 点啃穿 %d 席：user %d → %d" % [dbl, seats, b2, a2])
