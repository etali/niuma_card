# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 裂变鬼才：从「用户数翻倍」改成「补满」的判据（balance.md §「Buff 卡」）
##
## 旧语义 user_x2 是 `user_n *= 2`：7 人配方要先自己凑 4 张才够，
## 大配方上裂变几乎没用（12 人配方要凑 6 张）。
## 新语义 user_fill 是「组里有 ≥1 张用户卡 且 核心卡吃用户 → 配方视为满」。
##
## 这一组判据要盯住四条边界，因为它们各自对应一条会静默退化的实现错法：
##   1. 有 1 张就够   —— 写成 `>=2` 或忘记 fill 分支，大配方立刻回到旧手感
##   2. 0 张不给过     —— 裂变自己变不出用户；写成「带裂变即满」会凭空产出
##   3. 现金配方不吃    —— 只判 user_fill 不判 recipe_res，裂变会顺手补现金
##   4. 本来就够的不算补满 —— filled_by_fission 决定实际占用及保护额度，
##                          凑满的组应覆盖正常配方量，不能误缩成一张
##
## 变异提示（每条都实跑验证过会红）：
##   _fission_fills 里 `user_n < 1` 改成 `user_n < 2` → 第 1 组红
##   _fission_fills 里去掉 `if not user_fill: return false` → 第 2 组红
##   _fission_fills 里去掉 recipe_res 判断 → 第 3 组红
##   _fission_fills 结尾 `return user_n < recipe_n` 改成 `return true` → 第 4 组红
##   cards.json 里 liebian 的 buff_type 改成 user_x2（V1.0 的值）→ 第 7 组红


func _initialize() -> void:
	print("=== 裂变鬼才补满语义 测试 ===\n")
	test_one_user_fills_big_recipe()
	test_zero_user_never_fills()
	test_cash_recipe_untouched()
	test_exact_recipe_not_marked_filled()
	test_fill_does_not_inflate_output()
	test_attack_core_also_fills()
	test_buff_type_wired_everywhere()
	finish()


## 造裸卡实例：evaluate 只读 def_id，不需要真 GameState
var _n := 0
func _c(def_id: String) -> Dictionary:
	_n += 1
	return { "uid": _n, "def_id": def_id, "locked": false }

func _cards(ids: Array) -> Array:
	return ids.map(func(i): return _c(i))

## 从卡表里挑一张「配方吃用户且 recipe_n >= want」的生产卡，
## 不写死 def_id：数值一轮一改，写死会让这个文件跟着 cards.json 漂
func _user_recipe_card(want: int) -> String:
	var best := ""
	var best_n := 0
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.get_def(def_id)
		if def.get("kind") != CardDB.KIND_PRODUCT:
			continue
		if def.get("recipe_res", "") != CardDB.RES_USER:
			continue
		var n := int(def.get("recipe_n", 0))
		if n >= want and n > best_n:
			best = def_id
			best_n = n
	return best

func _cash_recipe_card(want: int) -> String:
	var best := ""
	var best_n := 0
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.get_def(def_id)
		if def.get("kind") != CardDB.KIND_PRODUCT:
			continue
		if def.get("recipe_res", "") != CardDB.RES_CASH:
			continue
		var n := int(def.get("recipe_n", 0))
		if n >= want and n > best_n:
			best = def_id
			best_n = n
	return best


# ---------- 1. 一张用户 + 裂变 = 大配方补满 ----------

func test_one_user_fills_big_recipe() -> void:
	print("\n【1】1 张用户 + 裂变 → 补满")
	var core := _user_recipe_card(4)
	check(core != "", "卡表里有吃 用户×4+ 的生产卡（实得 %s）" % core)
	if core == "":
		return
	var need := int(CardDB.get_def(core)["recipe_n"])

	# 不带裂变：1 张用户远远不够
	var bare := ComboRules.evaluate(_cards([core, "user"]))
	check(not bare["valid"],
		"不带裂变时 1 张用户凑不出 用户×%d 的配方" % need)

	# 带裂变：同样 1 张用户就该成立
	var ev := ComboRules.evaluate(_cards([core, "user", "liebian"]))
	check(ev["valid"], "带裂变时 1 张用户就补满 用户×%d（reason=%s）" % [
		need, ev.get("reason", "")])
	check(ev["type"] == "production", "补满后是生产组合（实得 %s）" % ev["type"])
	check(ev["filled_by_fission"], "这一组标记为「靠裂变补满」")

	# 补满是「有一张就够」，不是「翻倍」：need 越大越能看出区别。
	# 旧语义下 1×2=2 < need（need>=4），只有新语义能过
	check(need >= 4, "被测配方确实是大配方（用户×%d），旧翻倍语义过不了" % need)


# ---------- 2. 一张用户都没有：裂变救不了 ----------

func test_zero_user_never_fills() -> void:
	print("\n【2】0 张用户 → 裂变不生效")
	var core := _user_recipe_card(2)
	if core == "":
		check(false, "卡表里找不到吃用户的生产卡")
		return
	var ev := ComboRules.evaluate(_cards([core, "liebian"]))
	check(not ev["valid"], "只有核心卡 + 裂变、没有用户卡 → 不成立")
	check(not ev["filled_by_fission"], "不成立的组不许标补满")
	check(str(ev["reason"]).contains("至少要放一张"),
		"拒绝理由点明门槛是「至少一张」：%s" % ev["reason"])

	# 混一张现金也不算：补满认的是用户卡，不是「随便一张单位卡」
	var ev2 := ComboRules.evaluate(_cards([core, "liebian", "cash"]))
	check(not ev2["valid"], "拿现金卡冒充用户卡 → 仍不成立")


# ---------- 3. 现金配方不吃补满 ----------

func test_cash_recipe_untouched() -> void:
	print("\n【3】现金配方与裂变无关")
	var core := _cash_recipe_card(3)
	check(core != "", "卡表里有吃 现金×3+ 的生产卡（实得 %s）" % core)
	if core == "":
		return
	var need := int(CardDB.get_def(core)["recipe_n"])

	var ev := ComboRules.evaluate(_cards([core, "cash", "liebian"]))
	check(not ev["valid"],
		"裂变不补现金配方：1 张现金凑不出 现金×%d（reason=%s）" % [
			need, ev.get("reason", "")])
	check(not ev["filled_by_fission"], "现金配方组不许标补满")

	# 混一张用户卡也不行：用户卡不能当现金用，裂变也不搭桥
	var ev2 := ComboRules.evaluate(_cards([core, "cash", "user", "liebian"]))
	check(not ev2["valid"], "现金配方里混用户卡 + 裂变 → 仍不成立")

	# 现金真凑够了才成立，且要报出这一组该付多少现金
	var ids: Array = [core]
	for i in need:
		ids.append("cash")
	var ev3 := ComboRules.evaluate(_cards(ids))
	check(ev3["valid"], "现金凑够 %d 张 → 成立" % need)
	check(ev3["recipe_res"] == CardDB.RES_CASH,
		"现金配方组报出 recipe_res=cash（实得 %s）" % ev3["recipe_res"])
	check(int(ev3["recipe_pay_n"]) == need,
		"现金配方组要付 %d（实得 %d）" % [need, int(ev3["recipe_pay_n"])])


# ---------- 4. 本来就凑够的组不算「补满」 ----------

func test_exact_recipe_not_marked_filled() -> void:
	print("\n【4】自己凑够的组不标补满")
	var core := _user_recipe_card(2)
	if core == "":
		check(false, "卡表里找不到吃用户的生产卡")
		return
	var need := int(CardDB.get_def(core)["recipe_n"])
	var ids: Array = [core, "liebian"]
	for i in need:
		ids.append("user")
	var ev := ComboRules.evaluate(_cards(ids))
	check(ev["valid"], "凑够 %d 张用户 + 裂变 → 成立" % need)
	check(not ev["filled_by_fission"],
		"用户本来就够（%d 张）时不算补满，保留正常配方保护额度" % need)

	# 用户配方永久驻场：这一组不该产生任何现金扣款
	check(int(ev["recipe_pay_n"]) == 0,
		"用户配方组不付现金（实得 %d）" % int(ev["recipe_pay_n"]))
	check(ev["recipe_res"] == CardDB.RES_USER,
		"用户配方组报出 recipe_res=user（实得 %s）" % ev["recipe_res"])


# ---------- 5. 补满只管配方，不放大产出 ----------

func test_fill_does_not_inflate_output() -> void:
	print("\n【5】补满不改产出")
	var core := _user_recipe_card(4)
	if core == "":
		check(false, "卡表里找不到大用户配方的生产卡")
		return
	var base := int(CardDB.get_def(core)["output_n"])
	var ev := ComboRules.evaluate(_cards([core, "user", "liebian"]))
	check(ev["valid"], "补满成立")
	check(int(ev["output_n"]) == base,
		"补满后产出仍是卡面值 %d（实得 %d）" % [base, int(ev["output_n"])])

	# 叠两张裂变也不该有额外收益（补满不叠加）
	var ev2 := ComboRules.evaluate(_cards([core, "user", "liebian", "liebian"]))
	check(ev2["valid"], "两张裂变仍成立")
	check(int(ev2["output_n"]) == base,
		"两张裂变产出不变（实得 %d）" % int(ev2["output_n"]))


# ---------- 6. 攻击卡的用户配方同样能补满 ----------

func test_attack_core_also_fills() -> void:
	print("\n【6】攻击卡配方同样补满")
	var core := ""
	var need := 0
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.get_def(def_id)
		if def.get("kind") != CardDB.KIND_ATTACK:
			continue
		if def.get("recipe_res", "") != CardDB.RES_USER:
			continue
		if int(def.get("recipe_n", 0)) > need:
			core = def_id
			need = int(def["recipe_n"])
	if core == "":
		print("  [skip] 卡表里没有吃用户配方的攻击卡")
		return
	var ev := ComboRules.evaluate(_cards([core, "user", "liebian"]))
	check(ev["valid"], "攻击卡 用户×%d 被补满（reason=%s）" % [
		need, ev.get("reason", "")])
	check(ev["type"] == "attack", "仍是攻击组合（实得 %s）" % ev["type"])
	check(ev["filled_by_fission"], "攻击组也标记补满")


# ---------- 7. buff_type 三处消费方都接住了 ----------

## 这一组不测「补满」，测的是**数据和代码没对上时会不会静默**。
##
## 起因是一次真实误报：新脚本 + V1.0 的 cards.json（裂变鬼才 buff_type=user_x2），
## 三处消费方一处都没接住，于是「卡没效果 + C 位标成×2 + 悬停只剩典当+3」
## 三条症状同时出现，而且零报错 —— 从游戏里看完全像是补满功能没做。
##
## 每一条都按行为查，不读 KNOWN_BUFF_TYPES 那个清单本身：
## 判据读被测常量的话，把常量改错、判据跟着改错，这一组会全绿。
func test_buff_type_wired_everywhere() -> void:
	print("\n【7】每张 Buff 卡的 buff_type 都被三处接住")
	var board: Variant = load("res://scenes/board.gd").new()
	var no_effect: Array = []
	var no_desc: Array = []
	for def_id in CardDB.all_cards():
		var def: Dictionary = CardDB.get_def(def_id)
		if def.get("kind", "") != CardDB.KIND_BUFF:
			continue
		# (a) 悬停说明不能空 —— 这条是纯行为判据，也是三条症状里最好查的那个：
		# describe_def 的内层 match 没有兜底分支，不认识的 buff_type 会一路掉到
		# 函数末尾 `return ""`，于是 hover 只剩「典当 +N」。
		# 任何「数据写了、代码没接住」的 buff_type 都会在这里露出来
		if board.describe_def(def_id).strip_edges() == "":
			no_desc.append("%s(%s)" % [def_id, str(def.get("buff_type", ""))])
		# (b) 再和 CardDB 的清单对一遍。这条确实读了被测常量，作用是**交叉**：
		# 单靠 (a) 抓不到「说明写了分支、引擎没写分支」那半边
		# （反过来单靠清单也抓不到清单自己漏登记），两条一起才闭合
		if not CardDB.KNOWN_BUFF_TYPES.has(str(def.get("buff_type", ""))):
			no_effect.append(def_id)
	board.free()
	check(no_effect.is_empty(),
		"没有代码不认识的 buff_type（越界：%s）" % str(no_effect))
	check(no_desc.is_empty(),
		"每张 Buff 卡都有效果说明，不会只剩典当行（空的：%s）" % str(no_desc))

	# (c) 校验本身要真的会响：喂一张 buff_type 认不出来的表进去，
	# CardDB 必须点名警告。这条防的是「校验函数写了但没接进 load_from」
	var bogus := {
		"_game": CardDB.GAME.duplicate(true),
		"cash": CardDB.get_def("cash").duplicate(true),
		"user": CardDB.get_def("user").duplicate(true),
		"_probe_buff": {
			"name": "假 Buff", "kind": CardDB.KIND_BUFF,
			"tier": 1, "price": 6, "weight": 1, "buff_type": "user_x2",
		},
	}
	var tmp := "user://_probe_bad_buff.json"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	check(f != null, "能写临时配置（%s）" % tmp)
	if f != null:
		f.store_string(JSON.stringify(bogus))
		f.close()
		var keep: String = CardDB.loaded_from
		# push_warning 在测试里截不住，所以这条不验「响没响」，验的是
		# 「认不出的 buff_type 会造成什么」—— 也就是用户看到的那个空说明
		var ok: bool = CardDB.load_from(ProjectSettings.globalize_path(tmp)) \
			or CardDB.load_from(tmp)
		check(ok, "临时配置能加载")
		var probe: Dictionary = CardDB.get_def("_probe_buff")
		check(not CardDB.KNOWN_BUFF_TYPES.has(str(probe.get("buff_type", ""))),
			"user_x2 确实不在认得的清单里（V1.0 的旧值）")
		check(board_desc_empty_for("_probe_buff"),
			"认不出的 buff_type 说明为空 —— 这正是「只剩典当+3」的成因")
		# 还原真表，后面的用例还要用
		CardDB.load_from(keep)
		check(CardDB.get_def("liebian").get("buff_type", "") == "user_fill",
			"真卡表已还原（liebian=user_fill）")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))


## 单独开一个 Board 问说明，避免和上面那个实例的生命周期缠在一起
func board_desc_empty_for(def_id: String) -> bool:
	var b: Variant = load("res://scenes/board.gd").new()
	var t: String = b.describe_def(def_id)
	b.free()
	return t.strip_edges() == ""
