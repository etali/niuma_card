# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 战报按视角渲染测试。
## 运行：godot --headless -s tests/test_log_viewpoint.gd
##
## 为什么要有这一条：引擎写战报时如果把「你的公司」直接拼进文本，单机局看不出问题
## —— 拼进去的恰好就是对的。联网局才会露：服务器发的是同一份 state_snapshot，
## 服务器没有视角，同一句「XX 购入卡」在两个客户端要念成不同的公司名（README.md §「3. 文件目录结构」）。
##
## 所以座位在日志里是**字段**不是子串：条目存 { round, fmt, args }，
## args 里的座位写成 { "seat": who }，由 render_entry 按 my_seat 换成公司名。
##
## 这里量四件事：
##   1. 同一条日志，两个视角互为镜像
##   2. 跑多局，条目结构合法且没有一处把公司名拼进 fmt —— 完整性判据
##   3. 渲染不越界：fmt 的 %s 个数与 args 对得上，渲染结果不含残留占位符
##   4. 静态检查：引擎层不许出现公司名字面量（防改回去）

## 扫这些种子。为什么不是 1 个：单局会**整类**漏掉日志。实测种子 1234 那局
## 131 条里只有开局/购入/产出/典当四类，「已被拆散」要到种子 10 才首次出现，
## 「受防御 Buff」要到种子 12。往 settle.gd 注入一处写死的公司名，
## 单种子版本这条根本没红 —— 这个洞是实测出来的，不是猜的
const SEEDS := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

## 日志种类。扫完要确认每一类都真的取到了，否则「违规 0 条」可能只是
## 那类日志压根没出现（真空为真）。
##
## 「资金不足」不在表里：那是装弹付不起钱的分支，BOT 会预判结算护栏所以从不尝试，
## 实测 40 局一次都没出现。它由第 4 段的静态检查兜着
const LOG_KINDS := ["购入", "产出", "典当", "装弹", "攻击", "已被拆散", "受防御 Buff", "作废"]


func _initialize() -> void:
	print("=== 战报视角渲染测试 ===\n")
	_test_render_symmetry()
	_test_entry_shape()
	_test_no_baked_names()
	_test_render_bounds()
	_test_static_no_literal()
	finish()


## --- 1. 两个视角互为镜像 ---
func _test_render_symmetry() -> void:
	var entry := {
		"round": 1,
		"fmt": "%s 购入「%s」，%s 的组合被拆散",
		"args": [GameState.seat_arg(GameState.PLAYER), "测试卡",
			GameState.seat_arg(GameState.BOT)],
	}
	var as_player := GameState.render_entry(entry, GameState.PLAYER)
	var as_bot := GameState.render_entry(entry, GameState.BOT)

	check(as_player == "你的公司 购入「测试卡」，对手公司 的组合被拆散",
		"PLAYER 视角（%s）" % as_player)
	check(as_bot == "对手公司 购入「测试卡」，你的公司 的组合被拆散",
		"BOT 视角：同一条日志念反（%s）" % as_bot)

	# 镜像性单独验：上面两条各自只钉住一个视角，这条要的是
	# 「两个视角除了称呼对调以外完全一致」。
	# 必须借哨兵中转，否则第二步会把第一步刚换出来的词又换回去
	var sentinel := "MINE"
	var mirrored := as_player.replace("你的公司", sentinel) \
		.replace("对手公司", "你的公司").replace(sentinel, "对手公司")
	check(mirrored == as_bot, "两个视角严格互为镜像（%s）" % mirrored)

	# 非座位参数不该被动过
	check("测试卡" in as_player and "测试卡" in as_bot, "普通参数两个视角都原样代入")


## --- 2. 条目结构合法 + 没有一处把公司名拼进 fmt ---
##
## 这是本文件的行为主判据。引擎里只要有一处写 "你的公司" 而不是 seat_arg(who)，
## 它就会进 fmt，在这里被抓到
func _test_entry_shape() -> void:
	var entries := _collect_entries()
	check(entries.size() > 500, "取到足够样本（%d 局共 %d 条）" % [SEEDS.size(), entries.size()])

	var malformed: Array[String] = []
	for e in entries:
		if not (e.has("round") and e.has("fmt") and e.has("args")):
			malformed.append(str(e))
		elif not (e["args"] is Array):
			malformed.append(str(e))
	check(malformed.is_empty(), "每条都是 { round, fmt, args }（%d 条不合规）%s" % [
		malformed.size(),
		("\n      " + "\n      ".join(malformed.slice(0, 3))) if not malformed.is_empty() else ""])

	# 样本要覆盖各类日志，否则下面「0 条违规」可能只是那类没出现。
	#
	# 找的是**渲染后**的文本而不是 fmt：有些词是从 args 进来的，fmt 里没有。
	# 「产出」就是这样 —— 生产那句 fmt 是 "⚙ %s「%s」%s%s+%d"，
	# 「产出」来自 CardDB.res_label()。第一版按 fmt 找，这条就漏报了「缺 产出」
	var missing: Array[String] = []
	for k in LOG_KINDS:
		var hit := false
		for e in entries:
			if k in GameState.entry_text(e):
				hit = true
				break
		if not hit:
			missing.append(k)
	check(missing.is_empty(), "样本覆盖全部 %d 类战报%s" % [
		LOG_KINDS.size(), "" if missing.is_empty() else "，缺：" + "、".join(missing)])


func _test_no_baked_names() -> void:
	var entries := _collect_entries()
	var baked: Array[String] = []
	for e in entries:
		var fmt := str(e["fmt"])
		if "你的公司" in fmt or "对手公司" in fmt or "竞对公司" in fmt:
			baked.append(fmt)
		# args 里也不许直接放公司名（绕过 seat_arg 的另一种写法）
		for a in e["args"]:
			if a is String and ("你的公司" in a or "对手公司" in a):
				baked.append("args: %s ← %s" % [a, fmt])
	# 条数并进判据：取样为空时「违规 0 条」是真空为真
	check(entries.size() > 500 and baked.is_empty(),
		"fmt 和 args 都不含公司名（%d 条里 %d 处违规）%s" % [
			entries.size(), baked.size(),
			("\n      " + "\n      ".join(baked.slice(0, 5))) if not baked.is_empty() else ""])

	# 反过来：确实有日志在用 seat_arg，否则上一条也是真空为真
	var seated := 0
	for e in entries:
		for a in e["args"]:
			if a is Dictionary and a.has(GameState.SEAT_KEY):
				seated += 1
				break
	check(seated > 0, "战报里确实在用 seat_arg（%d/%d 条带座位）" % [seated, entries.size()])


## --- 3. 渲染不越界 ---
##
## 这里替代了「哨兵有没有漏」那类判据 —— 现在没有哨兵可漏了，
## 要防的是另一头：fmt 的 %s 个数与 args 对不上（Godot 会当场报错或吞掉参数）
func _test_render_bounds() -> void:
	var entries := _collect_entries()
	var bad: Array[String] = []
	for e in entries:
		for seat in [GameState.PLAYER, GameState.BOT]:
			var out := GameState.render_entry(e, seat)
			# 占位符没被吃掉（args 少了会留下 %s）
			if "%s" in out or "%d" in out:
				bad.append("[%s] %s ← %s" % [seat, out, e["fmt"]])
			# 座位字典不该以字典形式漏进文本
			if GameState.SEAT_KEY in out:
				bad.append("[%s] 座位字段漏进文本：%s" % [seat, out])
	check(entries.size() > 500 and bad.is_empty(),
		"两个视角都渲染干净（%d 条 ×2 视角，%d 处出错）%s" % [
			entries.size(), bad.size(),
			("\n      " + "\n      ".join(bad.slice(0, 5))) if not bad.is_empty() else ""])

	# 渲染只换称呼：把公司名抹掉之后，剩下的骨架两个视角应当逐字相同。
	# 判据不照抄 render_entry 的实现（那样是恒真）
	var drift: Array[String] = []
	for e in entries:
		var sp := GameState.render_entry(e, GameState.PLAYER) \
			.replace("你的公司", "").replace("对手公司", "")
		var sa := GameState.render_entry(e, GameState.BOT) \
			.replace("你的公司", "").replace("对手公司", "")
		if sp != sa:
			drift.append("%s\n        vs %s" % [sp, sa])
	check(drift.is_empty(), "两个视角除称呼外逐字一致（%d 条不一致）%s" % [
		drift.size(),
		("\n      " + "\n      ".join(drift.slice(0, 3))) if not drift.is_empty() else ""])


## --- 4. 静态检查：引擎层不许出现公司名字面量 ---
##
## 与 test_seat_map.gd 第四段同一个思路：行为测试证明现在是对的，
## 静态检查保证不会被改回去。公司名是**视角量**，只该出现在场景层
func _test_static_no_literal() -> void:
	var files := ["res://engine/game_state.gd", "res://engine/settle.gd",
		"res://engine/combo_rules.gd", "res://engine/bot_actions.gd",
		"res://engine/match_simulator.gd"]
	var bad: Array[String] = []
	var scanned := 0
	for path in files:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			bad.append("%s 打不开" % path)
			continue
		scanned += 1
		var n := 0
		while not f.eof_reached():
			var line := f.get_line()
			n += 1
			var code := line.strip_edges()
			if code.begins_with("#"):
				continue   # 注释里解释「为什么不写名字」是要留的
			var hash_at := code.find("#")
			if hash_at >= 0:
				code = code.substr(0, hash_at).strip_edges()
			# seat_name 就是把座位翻成名字的地方，白名单放它
			if code.begins_with("return \"你的公司\" if who == my_seat"):
				continue
			if "你的公司" in code or "对手公司" in code or "竞对公司" in code:
				bad.append("%s:%d  %s" % [path.get_file(), n, code])
		f.close()
	# 扫到的文件数并进判据：路径写错时「违规 0 处」是真空为真
	check(scanned == files.size() and bad.is_empty(),
		"引擎层无公司名字面量（扫 %d/%d 个文件，违规 %d 处）%s" % [
			scanned, files.size(), bad.size(),
			("\n      " + "\n      ".join(bad)) if not bad.is_empty() else ""])


## 跑一批无头对局，收集全部战报条目（不是文本 —— 这里要验的就是条目结构）。
## 用 MatchSimulator 而不是起场景：这条测的是引擎写日志的方式，与摆放、补间无关，
## 无头一局能覆盖买卡 / 典当 / 编组 / 攻击 / 结算全部写日志的路径
var _cache: Array[Dictionary] = []

func _collect_entries() -> Array[Dictionary]:
	if not _cache.is_empty():
		return _cache
	for sd in SEEDS:
		var summary := MatchSimulator.run_game(MatchSimulator.ROUNDS_FROM_CONFIG, sd)
		for e in summary["log"]:
			_cache.append(e)
	_cache.append_array(_protected_production_log())
	_cache.append_array(_armed_attack_log())
	return _cache

## 防御日志在入组当回合就产生，显式夹具避免依赖某个策略恰好买到防御卡。
func _protected_production_log() -> Array:
	var s := GameState.new()
	s.players = {GameState.PLAYER: {"cards": []}, GameState.BOT: {"cards": []}}
	var core := ""
	var buff := ""
	for id in CardDB.all_cards():
		var d := CardDB.get_def(id)
		if d.get("kind") == CardDB.KIND_PRODUCT and d.get("recipe_res") == CardDB.RES_USER:
			core = id
		if d.get("buff_type") == "protect_user":
			buff = id
	if not need(core != "" and buff != "", "防御日志夹具有生产卡与用户保护卡"):
		return []
	var ids: Array = [s.add_card(GameState.PLAYER, core)["uid"], s.add_card(GameState.PLAYER, buff)["uid"]]
	for i in int(CardDB.get_def(core)["recipe_n"]):
		ids.append(s.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_USER))["uid"])
	s.add_card(GameState.PLAYER, CardDB.unit_id(CardDB.RES_CASH))
	check(s.create_combo(GameState.PLAYER, ids)["ok"], "防御日志夹具合法编组")
	Settle.produce(s)
	return s.log

## 现金配方攻击才会写装弹日志；用真实编组和付款保证覆盖，不依赖BOT购买偏好。
func _armed_attack_log() -> Array:
	var s := GameState.new()
	s.players = {GameState.PLAYER:{"cards":[]},GameState.BOT:{"cards":[]}}
	var core := ""
	for id in CardDB.all_cards():
		var d := CardDB.get_def(id)
		if d.get("kind") == CardDB.KIND_ATTACK and d.get("recipe_res") == CardDB.RES_CASH and int(d.get("recipe_n",0)) > 0:
			core = id
			break
	if not need(core != "","装弹日志夹具存在现金配方攻击卡"): return []
	var ids: Array = [s.add_card(GameState.PLAYER,core).uid]
	var cost := int(CardDB.get_def(core).recipe_n)
	for i in cost: ids.append(s.add_card(GameState.PLAYER,CardDB.unit_id(CardDB.RES_CASH)).uid)
	s.add_card(GameState.PLAYER,CardDB.unit_id(CardDB.RES_CASH))
	s.add_card(GameState.PLAYER,CardDB.unit_id(CardDB.RES_USER))
	check(s.create_combo(GameState.PLAYER,ids).ok,"装弹日志夹具合法编组")
	var before := s.resource_count(GameState.PLAYER,CardDB.RES_CASH)
	var pool := s.arm_attacks(GameState.PLAYER)
	check(int(pool.values().reduce(func(a,b):return a+b,0)) > 0 and s.resource_count(GameState.PLAYER,CardDB.RES_CASH)==before-cost,
		"实际装弹产生攻击点并扣除配置规定的现金")
	return s.log
