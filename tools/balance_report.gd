# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 平衡性采集器：批量跑无头对局，输出“好玩对局”指标（设计文档第十一节）
## 用法：godot --headless -s tools/balance_report.gd [局数=500] [标签]

var _n := 500
var _tag := "baseline"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		_n = int(args[0])
	if args.size() >= 2:
		_tag = args[1]

	var games: Array = []
	for seed_i in range(1, _n + 1):
		games.append(_run_one(seed_i))
	_report(games)
	quit(0)

# ---------- 单局采集（跑 MatchSimulator.run_rounds，用它的三个钩子逐回合埋点） ----------
#
# 原先这里照抄了一份主循环（连 end_round/start_round 和回合上限一起），
# 于是「一回合是什么」有两份定义，改一处忘一处就是静默的口径偏差。
# 现在只出钩子不出循环：回合上限传 ROUNDS_FROM_CONFIG，跟 _sim.max_rounds 走。
#
# 三个钩子分别停在哪一刻、为什么必须是那一刻，见 engine/match_simulator.gd

func _run_one(rng_seed: int) -> Dictionary:
	var g := {
		"winner": "", "win_path": "超时", "rounds": 0,
		"draw_first_won": false,
		"diffs": [],              # 每回合结算后 玩家资金 - BOT资金
		"offered": 0, "bought": 0,
		"combos": 0, "attacks": 0, "upgrades": 0, "productions": 0,
		"protects": 0, "leaders": {}, "t2_made": 0, "t3_made": 0,
		"poor_rounds": 0, "side_rounds": 0,  # 张力：买不起任何卡的（方·回合）数
		"idle_units": 0, "total_units": 0, "idle_per_round": [],
		# M14/M16 的原料，见 _measure_seal()
		"first_seen": {},   # uid -> 第一次在桌上看到它的回合（只记核心卡和 Buff）
		"seal_t0": {},      # who -> 该方首个无解组合里「最早落桌的零件」的回合
		"seal_t1": {},      # who -> 该方第一次成型的回合
	}
	# g 是字典（引用类型），三个 lambda 直接往里写就行，不用回传
	var state := MatchSimulator.run_rounds(MatchSimulator.ROUNDS_FROM_CONFIG, rng_seed,
		func(s: GameState) -> void: _measure_poor(s, g),
		func(s: GameState) -> void:
			_measure_combos(s, g)
			_measure_seal(s, g),
		func(s: GameState) -> void: _measure_diff(s, g))
	g["winner"] = state.winner
	g["rounds"] = state.round_num
	g["draw_first_won"] = state.winner == state.draw_first
	if state.winner != "":
		var w_cash := state.resource_count(state.winner, CardDB.RES_CASH)
		var loser := GameState.opponent(state.winner)
		if w_cash >= int(CardDB.game_rules()["win_cash"]):
			g["win_path"] = "资金破百"
		elif state.resource_count(loser, CardDB.RES_CASH) <= 0:
			g["win_path"] = "资金归零"
		else:
			g["win_path"] = "用户归零"
	return g

## 张力（M8）：这一刻双方各自买不买得起公共区最便宜的卡。
## 必须停在行动阶段之前 —— 买过之后钱就少了，量出来的是「买完还剩多少」，不是张力。
## cash - 1 是因为留一块钱不能花光（对应环境的买卡归零护栏）
func _measure_poor(state: GameState, g: Dictionary) -> void:
	var min_price := 999
	for def_id in state.market:
		min_price = mini(min_price, int(CardDB.get_def(def_id).get("price", 999)))
	for who in [GameState.PLAYER, GameState.BOT]:
		g["side_rounds"] += 1
		if min_price < 999 and state.resource_count(who, CardDB.RES_CASH) - 1 < min_price:
			g["poor_rounds"] += 1

## 组合构成（M9/M10/M12）+ 用户席位部署（M13a/M13b）+ 公共区利用率（M7）。
## 必须停在结算之前：Settle.finalize 会清空 state.combos，结算完就什么都数不到了
func _measure_combos(state: GameState, g: Dictionary) -> void:
	g["offered"] += CardDB.game_rules()["market_size"]
	g["bought"] += CardDB.game_rules()["market_size"] - state.market.size()
	var in_combo := {}
	for combo in state.combos:
		g["combos"] += 1
		var ev: Dictionary = combo["eval"]
		match ev["type"]:
			"attack": g["attacks"] += 1
			"production": g["productions"] += 1
			"upgrade":
				g["upgrades"] += 1
				if ev["output_card"] != "":
					var tier := int(CardDB.get_def(ev["output_card"]).get("tier", 0))
					if tier == 2:
						g["t2_made"] += 1
					elif tier >= 3:
						g["t3_made"] += 1
				else:
					g["t3_made"] += 1  # 上市钟声（独角兽+国民应用）
		if ev.get("protect_user", false) or ev.get("protect_cash", false):
			g["protects"] += 1
		g["leaders"][ev["leader"]] = true
		for u in combo["uids"]:
			in_combo[u] = true
	# 用户席位部署（M13a/M13b）。
	# 旧口径是「闲置占比 ≤70%」，前提假设「闲置 = 浪费」。资源不对称之后这个假设不成立：
	# 用户是不可消耗的资本，只进不出（只会被对手打掉或典当），闲置率天然会更高。
	# 该问的是**席位供给够不够玩家把资本部署出去** —— 那是市场核心卡供给说话，是可调的设计变量。
	#
	# 两条一起看：只留 M13a 可以靠「用户总量压到很小」刷高比率，
	# 只留 M13b 可以靠「大量用户但都不部署」蒙过去
	var idle_now := 0
	for who in [GameState.PLAYER, GameState.BOT]:
		for c in state.players[who]["cards"]:
			var def: Dictionary = CardDB.get_def(c["def_id"])
			if def.get("kind") == CardDB.KIND_UNIT and def.get("res") == CardDB.RES_USER:
				g["total_units"] += 1
				if not in_combo.has(c["uid"]):
					g["idle_units"] += 1
					idle_now += 1
	# M13b 的口径是「每回合闲置用户卡数」的中位，所以要逐回合留一个样本，
	# 不能只留全局累加值 —— 累加值除以回合数是均值，会被长尾局拉走
	(g["idle_per_round"] as Array).append(idle_now)

## 组装期（M14/M16）：什么时候出现了一条「无解 build」，以及攒它花了几回合。
##
## 此历史诊断的「成型」由 `GameState.sealed_combos()` 判定：受保护的生产组合。
## 保护规则见 README.md §「2.8 Buff」。这里仅配时间戳：t0 = 最早落桌的零件，t1 = 成型回合。
## 当前 `tools/eval_report.gd` 的 Q1–Q9 不采集成型率或组装时间，也不把它们算作体验评分。
##
## 必须停在结算之前、且和 `_measure_combos` 同一刻：state.combos 结算后就清空了。
## 防御 Buff 在有效组合内立即保护；此处统计的是行动前仍有保护的生产组合。
func _measure_seal(state: GameState, g: Dictionary) -> void:
	var first_seen: Dictionary = g["first_seen"]
	for who in [GameState.PLAYER, GameState.BOT]:
		# t0 的口径只看核心卡和 Buff，**不看单位卡**：双方开局就各有一把现金/用户卡，
		# 算进去 t0 恒等于第 1 回合，M14 就退化成「第几回合成型」，量不到组装本身
		for c in state.players[who]["cards"]:
			var kind: Variant = CardDB.get_def(c["def_id"]).get("kind", "")
			if kind != CardDB.KIND_PRODUCT and kind != CardDB.KIND_BUFF:
				continue
			if not first_seen.has(c["uid"]):
				first_seen[c["uid"]] = state.round_num
		if g["seal_t1"].has(who):
			continue  # 只记第一次成型
		for combo in state.sealed_combos(who):
			var t0: int = state.round_num
			for u in combo["uids"]:
				if first_seen.has(u):
					t0 = mini(t0, int(first_seen[u]))
			g["seal_t0"][who] = t0
			g["seal_t1"][who] = state.round_num
			break

## 领先易手 / 翻盘幅度（M4/M3）的原料：每回合结算后的资金差。
## 停在结算之后、推进下一回合之前 —— 量的是「这回合打完谁领先」
func _measure_diff(state: GameState, g: Dictionary) -> void:
	g["diffs"].append(state.resource_count(GameState.PLAYER, CardDB.RES_CASH)
		- state.resource_count(GameState.BOT, CardDB.RES_CASH))

# ---------- 汇总报告 ----------

func _report(games: Array) -> void:
	var n := games.size()
	var rounds: Array = []
	var timeouts := 0
	var paths := {}
	var first_wins := 0
	var lead_changes: Array = []
	var comebacks := 0      # 胜者曾落后 ≥10 资金最终翻盘
	var deficits: Array = [] # 胜者曾落后的最大资金差
	var decided := 0
	var offered := 0
	var bought := 0
	var combos := 0
	var attacks := 0
	var attack_games := 0
	var productions := 0
	var upgrades := 0
	var t2_games := 0
	var t3_games := 0
	var protects := 0
	var protect_games := 0
	var leader_diversity: Array = []
	var poor := 0
	var side_rounds := 0
	var idle := 0
	var total_units := 0
	var idle_samples: Array = []   # M13b：全局所有「局·回合」的闲置用户数
	# M14 两方都采（样本更多）；M16 只采胜者那一方 ——
	# 「成型到终局」量的是 build 成型之后多久收场，输的那方成型了也没收场，算进去没有意义
	var assemble: Array = []       # M14：t1 - t0
	var seal_to_end: Array = []    # M16：终局回合 - t1
	var seal_games := 0            # 至少一方成型过的对局数（M14/M16 的分母）

	for g in games:
		rounds.append(g["rounds"])
		if g["winner"] == "":
			timeouts += 1
			continue
		decided += 1
		paths[g["win_path"]] = paths.get(g["win_path"], 0) + 1
		if g["draw_first_won"]:
			first_wins += 1
		# 领先易手 + 翻盘
		var changes := 0
		var prev := 0
		var winner_sign: int = 1 if g["winner"] == GameState.PLAYER else -1
		var max_behind := 0
		for d in g["diffs"]:
			var s: int = signi(d)
			if s != 0 and prev != 0 and s != prev:
				changes += 1
			if s != 0:
				prev = s
			max_behind = maxi(max_behind, -d * winner_sign)
		lead_changes.append(changes)
		deficits.append(max_behind)
		if max_behind >= 10:
			comebacks += 1
		offered += g["offered"]
		bought += g["bought"]
		combos += g["combos"]
		attacks += g["attacks"]
		if g["attacks"] > 0:
			attack_games += 1
		productions += g["productions"]
		upgrades += g["upgrades"]
		if g["t2_made"] > 0:
			t2_games += 1
		if g["t3_made"] > 0:
			t3_games += 1
		protects += g["protects"]
		if g["protects"] > 0:
			protect_games += 1
		leader_diversity.append((g["leaders"] as Dictionary).size())
		poor += g["poor_rounds"]
		side_rounds += g["side_rounds"]
		idle += g["idle_units"]
		total_units += g["total_units"]
		idle_samples.append_array(g["idle_per_round"])
		var t1s: Dictionary = g["seal_t1"]
		if not t1s.is_empty():
			seal_games += 1
		for who in t1s:
			assemble.append(int(t1s[who]) - int(g["seal_t0"][who]))
			if who == g["winner"]:
				seal_to_end.append(g["rounds"] - int(t1s[who]))

	print("\n========== 平衡性报告 · %s · %d 局 ==========" % [_tag, n])
	print("【节奏】回合数 中位 %d | P10 %d | P90 %d | 超时被系统终结 %d (%.1f%%)" % [
		_med(rounds), _pct(rounds, 0.10), _pct(rounds, 0.90), timeouts, 100.0 * timeouts / n])
	print("【翻盘】曾落后≥10资金最终翻盘 %.1f%% | 领先易手 中位 %d | 胜者最大落后 中位 %d / P90 %d" % [
		100.0 * comebacks / decided, _med(lead_changes), _med(deficits), _pct(deficits, 0.90)])
	print("【胜利路径】" + _fmt_paths(paths, decided))
	print("【先手】抽卡先手胜率 %.1f%%" % [100.0 * first_wins / decided])
	print("【经济】公共区利用率 %.1f%%（%d/%d）| 买不起任何卡的回合占比 %.1f%%" % [
		100.0 * bought / maxi(offered, 1), bought, offered, 100.0 * poor / maxi(side_rounds, 1)])
	print("【组合】场均组合 %.1f（生产 %.1f / 攻击 %.1f / 升级 %.1f）| 场均核心卡种类 %.1f" % [
		float(combos) / n, float(productions) / n, float(attacks) / n, float(upgrades) / n,
		_med(leader_diversity)])
	print("【互动】有攻击的对局 %.1f%% | 有防御贴膜的对局 %.1f%%" % [
		100.0 * attack_games / n, 100.0 * protect_games / n])
	print("【养成】有 T2 登场的对局 %.1f%% | 有 T3 登场的对局 %.1f%%" % [
		100.0 * t2_games / n, 100.0 * t3_games / n])
	# M13a 是主判据（资本部署得出去），M13b 是兜底（防「总量小所以比率好看」的假达标）。
	# 现金不计：现金闲置 = 在攒上市资金，那是正经打法不是浪费
	print("【席位】用户席位部署率 %.1f%%（已入组 %d / 全部 %d）| 每回合闲置用户 中位 %d / P90 %d" % [
		100.0 * (total_units - idle) / maxi(total_units, 1), total_units - idle, total_units,
		_med(idle_samples), _pct(idle_samples, 0.90)])
	# 成型对局占比是 M14/M16 的分母，也是读它俩的前提：
	# 占比很低的时候那两个中位只代表少数几局，别拿来下结论
	print("【组装期】组装期长度 中位 %d（M14）| 成型到终局 中位 %d（M16）| 成型对局占比 %.1f%%（%d/%d）" % [
		_med(assemble), _med(seal_to_end),
		100.0 * seal_games / maxi(decided, 1), seal_games, decided])

func _fmt_paths(paths: Dictionary, decided: int) -> String:
	var out: Array = []
	for k in ["资金破百", "资金归零", "用户归零"]:
		var c: int = paths.get(k, 0)
		out.append("%s %.1f%%（%d）" % [k, 100.0 * c / maxi(decided, 1), c])
	return " | ".join(out)

func _med(a: Array) -> int:
	return _pct(a, 0.5)

func _pct(a: Array, p: float) -> int:
	if a.is_empty():
		return 0
	var b := a.duplicate()
	b.sort()
	return int(b[clampi(int(floor(p * (b.size() - 1))), 0, b.size() - 1)])
