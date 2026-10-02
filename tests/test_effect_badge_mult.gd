# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 卡面 C 位效果格跟着组里的翻倍 Buff 走（996 / 热搜包年）。
##
## 报障原文：「996 buff 没有让用户数产出翻倍」。引擎那头是对的
## （见 test_buff_output_x2.gd：四层都翻），翻不了的是**卡面上那个数** ——
## 地推旁边贴着 996，C 位还写着没翻倍的那个数。玩家在结算之前没有任何地方能读到翻倍生效了，
## 而战报要等结算才出，那时候已经来不及据此决策。
##
## 卡面这一格回答的是「打出去会发生什么」，所以它必须是**当前这一组**的函数，
## 不是卡定义的函数。判据分四段，各自对应一条会静默退化的实现错法：
##   1. 倍数取自 ComboRules.effect_multipliers —— 卡面和结算读同一条规则。
##      分开数就会「卡面翻倍、结算发一份」
##   2. 配方没满时就要显示翻倍 —— 拿 eval["output_n"] 反推倍数的实现会在这里红
##      （eval 对没凑满的组给 output_n=0），而这正是玩家拖进 996 的那一刻
##   3. 离组要还原 —— 不还原的话核心卡带着翻倍值满桌跑，那个数不对应任何一组牌
##   4. 两条乘数不串台 —— 产出卡只吃 output_x2、攻击卡只吃 attack_x2
##
## 变异提示（每条都实跑验证过会红）：
##   combo_rules.gd effect_multipliers 里 `"output_x2": out["output"] = ...` 那支删掉 → 第 1/2 组红
##   board.gd _update_group_progress 里去掉 `_push_effect_mult(g)` → 第 1/2 组红
##   board.gd reset_recipe_progress 里去掉 `c.set_effect_mult(1)` → 第 3 组红
##   board.gd _push_effect_mult 里把 KIND_ATTACK 那支也喂 mult["output"] → 第 4 组红
##   card.gd set_effect_mult 里 `_effect_base_n * m` 改成 `_effect_base_n` → 第 1/2/4 组红


func _initialize() -> void:
	print("=== 卡面效果格跟组翻倍 测试 ===\n")
	test_multipliers_rule()
	await test_face_doubles_in_group()
	await test_face_doubles_before_recipe_full()
	await test_face_restores_on_leave()
	await test_no_cross_wiring()
	finish()


var _n := 0
func _c(def_id: String) -> Dictionary:
	_n += 1
	return { "uid": _n, "def_id": def_id, "locked": false }


# ---------- 第 1 组：规则层 ----------

## effect_multipliers 只问「组里有没有那张 Buff」，和配方满不满无关。
## 卡面读的是它，结算读的是 evaluate —— 两者必须对同一组牌给出一致的倍数
func test_multipliers_rule() -> void:
	print("-- 1. ComboRules.effect_multipliers --")
	# 两路的倍数读 `_game.buff_mult`：这一节量的是「哪一路吃哪张 Buff」，
	# 翻几倍是数值旋钮。1 不是配置，是「没 Buff」那一路的中性倍数
	var m_out := CardDB.buff_mult("output_x2")
	var m_atk := CardDB.buff_mult("attack_x2")
	var bare := ComboRules.effect_multipliers([_c("ditui"), _c("cash")])
	check(int(bare["output"]) == 1 and int(bare["attack"]) == 1, "没有 Buff：两路都是 1 倍")

	var with996 := ComboRules.effect_multipliers([_c("ditui"), _c("yinqing996")])
	check(int(with996["output"]) == m_out, "带 996：output 路 %d 倍" % m_out)
	check(int(with996["attack"]) == 1, "带 996：attack 路仍是 1 倍")

	var with_resou := ComboRules.effect_multipliers([_c("butie"), _c("resou")])
	check(int(with_resou["attack"]) == m_atk, "带热搜：attack 路 %d 倍" % m_atk)
	check(int(with_resou["output"]) == 1, "带热搜：output 路仍是 1 倍")

	# 配方一张料都没有也照样报出倍数 —— 这是它和 evaluate 的分工
	var empty_recipe := ComboRules.effect_multipliers([_c("liulianghe"), _c("yinqing996")])
	check(int(empty_recipe["output"]) == m_out, "配方空着也报 %d 倍（卡面要在凑满前就显示）" % m_out)

	# 防御 Buff 不是乘数，不该动这两个数
	var prot := ComboRules.effect_multipliers([_c("ditui"), _c("tuisong"), _c("jiangjia")])
	check(int(prot["output"]) == 1 and int(prot["attack"]) == 1, "防御 Buff 不参与翻倍")

	# 和 evaluate 对同一组牌口径一致（配方凑满的情形）。
	# 料给几张读地推的 recipe_n，别写死 —— 少一张这一条就变成量「没满」了
	var full: Array = [_c("ditui")]
	for i in int(CardDB.get_def("ditui")["recipe_n"]):
		full.append(_c("cash"))
	full.append(_c("yinqing996"))
	var ev := ComboRules.evaluate(full)
	var mu := ComboRules.effect_multipliers(full)
	check(int(ev["output_n"]) == int(CardDB.get_def("ditui")["output_n"]) * int(mu["output"]),
		"配方满时 evaluate 的产出 = 卡面值 × effect_multipliers 的倍数")
	print("")


# ---------- 第 2 组：卡面在组里翻倍 ----------

## 桌上真摆一组：地推 + 一份配方的现金 + 996，读核心卡 C 位的字
func test_face_doubles_in_group() -> void:
	print("-- 2. 卡面在组里翻倍 --")
	var main: Node = await boot_main()
	var board: Board = main.board
	# 卡面上那几个数全从卡表推：卡面值 = output_n，翻倍后 = output_n × buff_mult
	var d_core: Dictionary = CardDB.get_def("ditui")
	var out1 := int(d_core["output_n"])
	var m_out := CardDB.buff_mult("output_x2")
	var need := int(d_core["recipe_n"])
	var core: CardEntity = main._spawn_entity(
		{ "uid": 9001, "def_id": "ditui" }, Vector3(-6.0, 0.05, 4.0), true)
	var cash: Array = []
	for i in need:
		cash.append(main._spawn_entity(
			{ "uid": 9010 + i, "def_id": "cash" }, Vector3(-6.0, 0.05, 4.0), true))
	var buff: CardEntity = main._spawn_entity(
		{ "uid": 9020, "def_id": "yinqing996" }, Vector3(-6.0, 0.05, 4.0), true)
	isolate(board, [core] + cash + [buff])

	check(core.has_effect_badge(), "地推有 C 位效果格")
	check(core.effect_text() == "+%d" % out1,
		"单张地推：卡面 +%d（实为 %s）" % [out1, core.effect_text()])
	check(core.effect_mult() == 1, "单张地推：倍数 1")

	_group(board, [core] + cash)
	check(core.effect_text() == "+%d" % out1,
		"地推 + %s×%d（无 996）：卡面仍 +%d（实为 %s）" % [
			CardDB.card_name(str(d_core["recipe_res"])), need, out1, core.effect_text()])

	_group(board, [core] + cash + [buff])
	check(core.effect_text() == "+%d" % (out1 * m_out),
		"地推 + 料 + 996：卡面翻成 +%d（实为 %s）" % [out1 * m_out, core.effect_text()])
	check(core.effect_mult() == m_out, "地推带 996：倍数 %d" % m_out)

	# 换一张产出更大的核心：翻倍后位数变多那一档，字号要重新塞回圆盘。
	# 挑哪张不写死数字 —— 只要求「翻倍后比上面那张多一位」，这才是被测的那一档
	var d_big: Dictionary = CardDB.get_def("liulianghe")
	var out2 := int(d_big["output_n"])
	check(len(str(out2 * m_out)) > len(str(out1 * m_out)),
		"夹具前提：%s 翻倍后 %d 比 %d 多一位（考的是字号回缩）" % [
			d_big["name"], out2 * m_out, out1 * m_out])
	var big: CardEntity = main._spawn_entity(
		{ "uid": 9030, "def_id": "liulianghe" }, Vector3(-6.0, 0.05, 4.0), true)
	var buff2: CardEntity = main._spawn_entity(
		{ "uid": 9031, "def_id": "yinqing996" }, Vector3(-6.0, 0.05, 4.0), true)
	isolate(board, [core] + cash + [buff, big, buff2])
	_group(board, [big, buff2])
	check(big.effect_text() == "+%d" % (out2 * m_out),
		"%s + 996：卡面 %d → +%d（实为 %s）" % [
			d_big["name"], out2, out2 * m_out, big.effect_text()])
	main.queue_free()
	print("")


# ---------- 第 3 组：配方没满也要显示 ----------

## 玩家把 996 拖进来的那一刻配方通常还没满，正是最需要看到翻倍的时刻。
## 拿 eval["output_n"] 反推倍数的实现在这里红（那时候 output_n 是 0）
func test_face_doubles_before_recipe_full() -> void:
	print("-- 3. 配方没满时也显示翻倍 --")
	var main: Node = await boot_main()
	var board: Board = main.board
	var core: CardEntity = main._spawn_entity(
		{ "uid": 9101, "def_id": "liulianghe" }, Vector3(-6.0, 0.05, 4.0), true)
	var buff: CardEntity = main._spawn_entity(
		{ "uid": 9102, "def_id": "yinqing996" }, Vector3(-6.0, 0.05, 4.0), true)
	isolate(board, [core, buff])
	var g = _group(board, [core, buff])

	# 前提：这一组的配方确实没满（否则这一节测的不是「没满」）
	var data: Array = []
	for c in g["cards"]:
		data.append({ "uid": c.uid, "def_id": c.def_id })
	check(not bool(ComboRules.evaluate(data)["valid"]), "前提：这一组配方没满")
	check(int(ComboRules.evaluate(data)["output_n"]) == 0, "前提：没满时 eval 的产出是 0")

	var d_core: Dictionary = CardDB.get_def("liulianghe")
	var want := int(d_core["output_n"]) * CardDB.buff_mult("output_x2")
	check(core.effect_text() == "+%d" % want,
		"配方 0/%d 时卡面已写 +%d（实为 %s）" % [
			int(d_core["recipe_n"]), want, core.effect_text()])
	# D 位仍要如实写「没满」：两格各说一件事（凑满后产多少 / 现在凑了几张）
	check(core.recipe_progress_text().begins_with("0/"),
		"D 位如实写 0/N（实为 %s）" % core.recipe_progress_text())
	main.queue_free()
	print("")


# ---------- 第 4 组：离组还原 ----------

## 不还原的话核心卡带着翻倍值满桌跑，那个数不再对应任何一组牌
func test_face_restores_on_leave() -> void:
	print("-- 4. 离组还原 --")
	var main: Node = await boot_main()
	var board: Board = main.board
	var core: CardEntity = main._spawn_entity(
		{ "uid": 9201, "def_id": "waimai" }, Vector3(-6.0, 0.05, 4.0), true)
	var buff: CardEntity = main._spawn_entity(
		{ "uid": 9202, "def_id": "yinqing996" }, Vector3(-6.0, 0.05, 4.0), true)
	isolate(board, [core, buff])
	# 原值和翻倍值都从卡表推：这一节量的是「退不退回去」，不是退到哪个数字
	var base := int(CardDB.get_def("waimai")["output_n"])
	var doubled := base * CardDB.buff_mult("output_x2")
	_group(board, [core, buff])
	check(core.effect_text() == "+%d" % doubled,
		"外卖 + 996：卡面 %d → +%d（实为 %s）" % [base, doubled, core.effect_text()])

	# 把 996 抽走：组还在，只是不带 Buff 了
	board._detach_from_group(buff)
	board.refresh_group(board.group_of(core))
	check(core.effect_text() == "+%d" % base,
		"996 被抽走：卡面退回 +%d（实为 %s）" % [base, core.effect_text()])

	# 整组散掉：核心卡自己也要退回原值
	_group(board, [core, buff])
	check(core.effect_text() == "+%d" % doubled,
		"重新编上：又是 +%d（实为 %s）" % [doubled, core.effect_text()])
	board._detach_from_group(core)
	Board.reset_recipe_progress(core)
	check(core.effect_text() == "+%d" % base,
		"核心卡离组：卡面退回 +%d（实为 %s）" % [base, core.effect_text()])
	check(core.effect_mult() == 1, "核心卡离组：倍数退回 1")
	main.queue_free()
	print("")


# ---------- 第 5 组：两条乘数不串台 ----------

## 一组里同时有 996 和热搜时，产出核心和攻击核心各认自己那一路。
## 引擎不许一个组有两个核心，所以分两组摆 —— 测的是「喂给卡面的是哪一路」
func test_no_cross_wiring() -> void:
	print("-- 5. 两条乘数不串台 --")
	var main: Node = await boot_main()
	var board: Board = main.board
	# 攻击核心 + 996：996 不该放大攻击量
	var atk: CardEntity = main._spawn_entity(
		{ "uid": 9301, "def_id": "butie" }, Vector3(-6.0, 0.05, 4.0), true)
	var b996: CardEntity = main._spawn_entity(
		{ "uid": 9302, "def_id": "yinqing996" }, Vector3(-6.0, 0.05, 4.0), true)
	# 产出核心 + 热搜：热搜不该放大产出量
	var prod: CardEntity = main._spawn_entity(
		{ "uid": 9303, "def_id": "waimai" }, Vector3(-6.0, 0.05, 4.0), true)
	var resou: CardEntity = main._spawn_entity(
		{ "uid": 9304, "def_id": "resou" }, Vector3(-6.0, 0.05, 4.0), true)
	isolate(board, [atk, b996, prod, resou])

	var atk_n := int(CardDB.get_def("butie")["attack_n"])
	var out_n := int(CardDB.get_def("waimai")["output_n"])
	var m_out := CardDB.buff_mult("output_x2")
	var m_atk := CardDB.buff_mult("attack_x2")
	_group(board, [atk, b996])
	check(atk.effect_text() == "−%d" % atk_n,
		"补贴大战 + 996：攻击量不变（实为 %s，应为 −%d）" % [atk.effect_text(), atk_n])

	_group(board, [prod, resou])
	check(prod.effect_text() == "+%d" % out_n,
		"外卖 + 热搜：产出量不变（实为 %s，应为 +%d）" % [prod.effect_text(), out_n])

	# 各自配上对的那张 Buff：这一条保证上面两条不是「谁都不翻」的假绿
	isolate(board, [atk, b996, prod, resou])
	_group(board, [atk, resou])
	check(atk.effect_text() == "−%d" % (atk_n * m_atk),
		"补贴大战 + 热搜：攻击量翻 %d 倍（实为 %s，应为 −%d）" % [
			m_atk, atk.effect_text(), atk_n * m_atk])
	_group(board, [prod, b996])
	check(prod.effect_text() == "+%d" % (out_n * m_out),
		"外卖 + 996：产出量翻 %d 倍（实为 %s，应为 +%d）" % [
			m_out, prod.effect_text(), out_n * m_out])
	main.queue_free()
	print("")


# ---------- 工具 ----------

## 把这些卡编成一组并刷新。先把每张从旧组里摘出来，
## 否则牌还挂在上一组上，新组会和旧组同时持有同一张卡
func _group(board: Board, cards: Array) -> Dictionary:
	for c in cards:
		board._detach_from_group(c)
	var g := board.make_group(cards.duplicate())
	board.groups.append(g)
	board.refresh_group(g)
	return g
