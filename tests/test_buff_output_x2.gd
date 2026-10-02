# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 996 引擎（output_x2）的翻倍判据。
##
## 为什么单开一个文件：这条规则原先全套断言一条都没碰过
## （`grep -rn output_x2 tests/` 只有 test_audit_fixes 拿它当货架填充物）。
## 「全绿」对这条规则等于没说话 —— 翻倍被改掉、或者只对现金线生效，
## 整套测试一条都不会红。用户报的正是「用户数产出没翻倍」，
## 所以两个币种的核心卡一张不漏地过一遍：实现里一旦按 output_res 分了岔，
## 只测一侧就抓不到。
##
## 四层各测一遍，因为它们各自能独立坏掉：
##   1. ComboRules.evaluate   —— 规则本身（output_n 有没有 ×2）
##   2. GameState.create_combo —— 编组时存进 combo["eval"] 的是不是翻倍后的值
##   3. Settle._resolve_combo  —— 结算按 eval["output_n"] 发牌，实际到账几张
##   4. IntentApply / Transport —— 玩家实际走的那条管道（engine/intent.gd 与 engine/intent_apply.gd的七个入口）
## 只测第 1 层是不够的：结算若改成重新 evaluate 存活的卡、
## 或者管道里某处拿 def["output_n"] 而不是 eval["output_n"]，第 1 层照样绿。
##
## 变异提示（每条都实跑验证过会红）：
##   combo_rules.gd 的 `evaluate()`：`ldef["output_n"] * (CardDB.buff_mult("output_x2") if output_x2 else 1)`
##     改成 `ldef["output_n"]`                        → 第 1/2/3/4 组全红
##     条件上再加 `and ldef["output_res"] == CardDB.RES_CASH`
##                                                    → 只有产用户的那几条红（这就是本次报障的形状）
##   combo_rules.gd 的 `evaluate()`：`"output_x2": output_x2 = true` 删掉 → 全红
##   engine/settle.gd 的 `_resolve_combo()`：`for i in eval["output_n"]`
##     改成 `for i in CardDB.get_def(eval["leader"])["output_n"]`
##                                                    → 第 3/4 组红（第 1/2 组绿：eval 自己是对的）
##   cards.json 里 yinqing996 的 buff_type 改成 user_fill → 全红

## 产用户 / 产现金的核心各取全部，避免「挑了一张恰好没事的」。
## 名单从卡表现算，不手抄 id：卡表加一张产用户的生产卡，这一节自动把它也过一遍，
## 而手抄的名单只会静默地漏掉新卡（本次报障漏的正是「某一侧没测到」）
var USER_CORES: Array = _cores_of(CardDB.RES_USER)
var CASH_CORES: Array = _cores_of(CardDB.RES_CASH)

## 卡表里所有产出该币种的生产核心
func _cores_of(res: String) -> Array:
	var out: Array = []
	for id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(id)
		if str(d.get("kind", "")) == CardDB.KIND_PRODUCT and str(d.get("output_res", "")) == res:
			out.append(id)
	out.sort()
	return out

func _initialize() -> void:
	print("=== 996 引擎（output_x2）翻倍 测试 ===\n")
	check(not USER_CORES.is_empty() and not CASH_CORES.is_empty(),
		"卡表前提：两个币种各有生产核心（产用户 %d 张 / 产现金 %d 张）" % [
			USER_CORES.size(), CASH_CORES.size()])
	test_rule_doubles_both_resources()
	test_rule_does_not_cross_wires()
	test_create_combo_stores_doubled()
	test_settle_delivers_doubled()
	test_pipeline_delivers_doubled()
	test_buff_type_wired()
	finish()

## 996 翻几倍读 `_game.buff_mult.output_x2`：这一节量的是「翻没翻」，倍数是数值旋钮
var M: int = CardDB.buff_mult("output_x2")

var _n := 0
func _c(def_id: String) -> Dictionary:
	_n += 1
	return { "uid": _n, "def_id": def_id, "locked": false }

## 数值判据：失败时把实到值一起印出来。harness 的 check 只收一个 bool，
## 「翻倍失败」的时候光看消息不知道实际发了几张 —— 这条报障要的正是那个数
func eq(got: int, want: int, msg: String) -> bool:
	var ok := got == want
	check(ok, msg if ok else "%s（实为 %d，应为 %d）" % [msg, got, want])
	return ok

## check 是 void 的，不能写 `if not check(...)`。要按结果分支的地方走这个

## 一个核心卡凑满配方所需的裸卡（不含核心、不含 996）
func _recipe_cards(core: String) -> Array:
	var def: Dictionary = CardDB.get_def(core)
	var out: Array = []
	for i in int(def["recipe_n"]):
		out.append(_c(CardDB.unit_id(def["recipe_res"])))
	return out

# ---------- 第 1 组：规则层 ----------

## 产用户和产现金都要翻倍。这一组是「按 output_res 分岔」那种实现错法的判据 ——
## 只测现金线的话，把用户线的翻倍去掉整套测试不会红
func test_rule_doubles_both_resources() -> void:
	print("-- 1. ComboRules：两种产出币种都翻倍 --")
	for core in USER_CORES + CASH_CORES:
		var def: Dictionary = CardDB.get_def(core)
		var base: Array = [_c(core)] + _recipe_cards(core)
		var bare := ComboRules.evaluate(base)
		check(bare["valid"], "%s 裸配方成立" % core)
		eq(int(bare["output_n"]), int(def["output_n"]),
			"%s 不带 996 产出 = 卡面值" % core)

		var buffed := ComboRules.evaluate(base + [_c("yinqing996")])
		check(buffed["valid"], "%s 带 996 仍成立（996 不占配方位）" % core)
		eq(int(buffed["output_n"]), int(def["output_n"]) * M,
			"%s（产%s）带 996 产出翻 %d 倍：%d → %d" % [
				core, def["output_res"], M, int(def["output_n"]), int(def["output_n"]) * M])
		# 币种和类型不能被 996 改掉
		check(str(buffed["output_res"]) == str(def["output_res"]),
			"%s 带 996 产出币种不变" % core)
		check(str(buffed["type"]) == "production", "%s 带 996 仍是生产组合" % core)
	print("")

## 996 不该碰攻击量，热搜包年也不该碰产出量。
## 两个乘数隔着 if/else 的两支（combo_rules.gd 的 `evaluate()` 里
## `kind == KIND_PRODUCT` 那支算 output_n、else 那支算 attack_n），串台是很自然的错法：
## 把 output_x2 写进攻击那支，「996 没让产出翻倍」正好就是它的症状之一
func test_rule_does_not_cross_wires() -> void:
	print("-- 1b. 两个乘数不串台 --")
	var atk := "butie"
	var adef: Dictionary = CardDB.get_def(atk)
	if adef.is_empty() or str(adef.get("kind", "")) != CardDB.KIND_ATTACK:
		# 攻击卡换了卡面 id 就跳过这一节，但要说出来（静默跳过等于判据消失）
		check(false, "找不到攻击核心卡 %s，1b 节没跑到" % atk)
		return
	var base: Array = [_c(atk)] + _recipe_cards(atk)
	var with996 := ComboRules.evaluate(base + [_c("yinqing996")])
	eq(int(with996["attack_n"]), int(adef["attack_n"]),
		"996 不放大攻击量（那是热搜包年的活）")
	# 配方料走 _recipe_cards：地推吃的是现金×3，手写一张 user 会因为配方没满
	# 而拿到 output_n=0 —— 那是「配方不成立」，不是「乘数没串台」，判据会假绿
	var with_resou := ComboRules.evaluate(
		[_c("ditui")] + _recipe_cards("ditui") + [_c("resou")])
	eq(int(with_resou["output_n"]), int(CardDB.get_def("ditui")["output_n"]),
		"热搜包年不放大产出量")
	print("")

# ---------- 第 2 组：编组层 ----------

## create_combo 存进 combo["eval"] 的必须是翻倍后的值。
## 结算读的是这份快照（engine/settle.gd 的 `_resolve_combo()`：`for i in eval["output_n"]`），
## 这里存了卡面值的话，规则层再对也白搭
func test_create_combo_stores_doubled() -> void:
	print("-- 2. create_combo：存进 eval 的是翻倍后的值 --")
	for core in USER_CORES:
		var def: Dictionary = CardDB.get_def(core)
		var state := _fresh_state()
		var uids := _place(state, core, true)
		var r: Dictionary = state.create_combo(GameState.PLAYER, uids)
		if not need(r["ok"], "%s + 996 编组成功：%s" % [core, r.get("reason", "")]):
			continue
		eq(int(state.combos[0]["eval"]["output_n"]), int(def["output_n"]) * M,
			"%s 组合快照里的 output_n 已翻倍" % core)
	print("")

# ---------- 第 3 组：结算层 ----------

## 结算实际发几张牌。前两组都对、这一组红 = 结算没按 eval 发牌
func test_settle_delivers_doubled() -> void:
	print("-- 3. Settle：实际到账张数翻倍 --")
	for core in USER_CORES + CASH_CORES:
		var def: Dictionary = CardDB.get_def(core)
		for with996 in [false, true]:
			var state := _fresh_state()
			var uids := _place(state, core, with996)
			var r: Dictionary = state.create_combo(GameState.PLAYER, uids)
			if not need(r["ok"], "%s（996=%s）编组成功：%s" % [
					core, with996, r.get("reason", "")]):
				continue
			var before := state.resource_count(GameState.PLAYER, def["output_res"])
			Settle._resolve_combo(state, state.combos[0])
			var got := state.resource_count(GameState.PLAYER, def["output_res"]) - before
			var want := int(def["output_n"]) * (M if with996 else 1)
			eq(got, want, "%s（产%s，996=%s）到账 %d 张" % [
				core, def["output_res"], with996, want])
	print("")

# ---------- 第 4 组：意图管道 ----------

## 玩家实际走的那条路：Intent → LocalTransport → IntentApply → Settle。
## 单机局也走这条管道（README.md §「3. 文件目录结构」），所以它才是「玩家看到的数」。
## 上面三组全绿而这组红 = 管道里某处绕过了 eval
func test_pipeline_delivers_doubled() -> void:
	print("-- 4. 意图管道：玩家实际走的那条路 --")
	for core in USER_CORES:
		var def: Dictionary = CardDB.get_def(core)
		var state := _fresh_state()
		var uids := _place(state, core, true)
		var applier := IntentApply.new(state)
		var tp := LocalTransport.new(applier)

		var cr: Dictionary = await tp.submit(
			Intent.create_combo(GameState.PLAYER, uids), GameState.PLAYER)
		if not need(cr.get("ok", false), "%s + 996 过管道编组成功：%s" % [
				core, cr.get("reason", "")]):
			continue
		var before := state.resource_count(GameState.PLAYER, def["output_res"])
		var n := applier.production_count()
		eq(n, 1, "%s 本回合只有这一组要结算" % core)
		for i in n:
			var pr: Dictionary = await tp.submit(Intent.produce(i))
			check(pr.get("ok", false), "%s produce#%d 落地" % [core, i])
		await tp.submit(Intent.finalize())
		var got := state.resource_count(GameState.PLAYER, def["output_res"]) - before
		eq(got, int(def["output_n"]) * M,
			"%s（产%s）过管道到账 %d 张（= 卡面 %d 的 %d 倍）" % [
				core, def["output_res"], int(def["output_n"]) * M, int(def["output_n"]), M])
	print("")

# ---------- 第 5 组：配置接线 ----------

## buff_type 的字面值是规则和配置之间的唯一契约。
## cards.json 里改错一个字（output_x2 → user_x2）不会有任何报错，
## 只会静默地让这张卡变成一张空白 Buff
func test_buff_type_wired() -> void:
	print("-- 5. 配置接线 --")
	var def: Dictionary = CardDB.get_def("yinqing996")
	check(str(def.get("buff_type", "")) == "output_x2",
		"cards.json 里 yinqing996 的 buff_type 是 output_x2")
	check(str(def.get("kind", "")) == CardDB.KIND_BUFF, "996 是 Buff 卡")
	# 端到端一条：产出最小的那张产用户核心，也是用户报障时最容易看到的一组。
	# 挑哪张按 output_n 现算 —— 「最小」是个关系，不是某张卡的名字
	var small := ""
	for id in USER_CORES:
		if small == "" or int(CardDB.get_def(id)["output_n"]) < int(CardDB.get_def(small)["output_n"]):
			small = id
	var d_small: Dictionary = CardDB.get_def(small)
	var by_type := ComboRules.evaluate(
		[_c(small)] + _recipe_cards(small) + [_c("yinqing996")])
	check(by_type["valid"], "%s + %s×%d + 996 配方成立" % [
		d_small["name"], CardDB.card_name(str(d_small["recipe_res"])), int(d_small["recipe_n"])])
	eq(int(by_type["output_n"]), int(d_small["output_n"]) * M,
		"%s + 996 → 产用户翻倍（%d → %d）" % [
			d_small["name"], int(d_small["output_n"]), int(d_small["output_n"]) * M])
	print("")

# ---------- 工具 ----------

## 干净的局：清掉开局手牌，只留下这一节要摆的。
## 现金另给一笔厚底，免得付配方时撞上「付完归零整组作废」那条护栏
func _fresh_state() -> GameState:
	var state := GameState.new()
	state.set_seed(20260826)
	state.new_game()
	state.players[GameState.PLAYER]["cards"].clear()
	state.combos.clear()
	return state

## 摆一组：核心 + 配方料（+ 996），返回这一组的 uids。
## 现金配方额外补一笔散钱当底（不进组合，只为过归零护栏）。
## 补多少是判据自己的规模：只要够厚就行
func _place(state: GameState, core: String, with996: bool) -> Array:
	var def: Dictionary = CardDB.get_def(core)
	var uids: Array = [int(state.add_card(GameState.PLAYER, core)["uid"])]
	for i in int(def["recipe_n"]):
		uids.append(int(state.add_card(
			GameState.PLAYER, CardDB.unit_id(def["recipe_res"]))["uid"]))
	if str(def["recipe_res"]) == CardDB.RES_CASH:
		for i in 30:
			state.add_card(GameState.PLAYER, "cash")
	if with996:
		uids.append(int(state.add_card(GameState.PLAYER, "yinqing996")["uid"]))
	return uids
