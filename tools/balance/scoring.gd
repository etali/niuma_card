# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

# 手动调参指标 v4：直接观测与有效获胜方式数，无加权总分、无额外续局。
static func summarize(games: Array, card_ids: Array, victory_types: Array = []) -> Dictionary:
	var n := games.size()
	var decided := 0
	var first_wins := 0
	var finished_rounds := 0
	var feedback_rounds := 0
	var observed_seat_rounds := 0
	var bilateral := 0
	var upgrade_produced := 0
	var upgrade_observed := 0
	var pawn_wins := 0
	var pawn_observed := 0
	var max_cash_total := 0
	var max_cash_observed := 0
	var max_users_total := 0
	var max_users_observed := 0
	var used := {}
	for g in games:
		if str(g.get("winner", "")) != "":
			decided += 1
			first_wins += int(g["winner"] == g["first"])
			finished_rounds += int(g["end_round"])
		feedback_rounds += int(g.get("feedback_rounds", 0))
		observed_seat_rounds += int(g.get("observed_seat_rounds", 0))
		bilateral += int(g.get("bilateral_attack", false))
		# 新口径只用实际采集到的新字段；旧局的缺失不能补成 false。
		if g.get("upgrade_produced") is bool:
			upgrade_observed += 1
			upgrade_produced += int(g["upgrade_produced"])
		if valid_pawned_seats(g.get("pawned_seats")):
			pawn_observed += 1
			pawn_wins += int(str(g.get("winner", "")) in g["pawned_seats"])
		# 旧记录未采集峰值，不能用 0 补齐拉低平均数；两项各用自己的有效局数。
		if valid_peak(g.get("max_cash")):
			max_cash_total += int(g["max_cash"])
			max_cash_observed += 1
		if valid_peak(g.get("max_users")):
			max_users_total += int(g["max_users"])
			max_users_observed += 1
		for id in g.get("used_cards", []):
			if id in card_ids: used[id] = true
	var upgrade_metric := metric("升级后成功生产", upgrade_produced, upgrade_observed, "%", 100.0)
	upgrade_metric["definition"] = "upgrade-production-v1"
	return {
		"Q1": metric("先手胜率", first_wins, decided, "%", 100.0),
		"Q2": metric("平均结束回合", finished_rounds, decided, "回合", 1.0),
		"Q3": metric("未结束比例", n - decided, n, "%", 100.0),
		"Q4": metric("有效反馈比例", feedback_rounds, observed_seat_rounds, "%", 100.0),
		"Q5": metric("双方攻击比例", bilateral, n, "%", 100.0),
		"Q6": metric("卡牌使用覆盖", used.size(), card_ids.size(), "%", 100.0),
		"Q7": upgrade_metric,
		"Q8": metric("局均最大现金数", max_cash_total, max_cash_observed, "现金", 1.0),
		"Q9": metric("局均最大用户数", max_users_total, max_users_observed, "用户", 1.0),
		"Q10": victory_diversity(games, victory_types),
		"Q11": metric("典当后获胜比例", pawn_wins, pawn_observed, "%", 100.0),
	}

static func valid_pawned_seats(value: Variant) -> bool:
	if not value is Array: return false
	for seat in value:
		if not seat is String or seat not in [GameState.PLAYER, GameState.AI]: return false
	return true

static func valid_peak(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and float(value) >= 0 and float(value) == floorf(float(value))

static func metric(label: String, numerator: int, denominator: int, unit: String, scale: float) -> Dictionary:
	return {"label":label,"value":scale * numerator / denominator if denominator > 0 else null,
		"numerator":numerator,"denominator":denominator,"unit":unit}

## Shannon 熵的指数（有效种数）：1 为单一方式，k 类均匀分布为 k。
## 已结束但未记录/无法归类的旧局不补成某一类，也不把未结束局当作一种胜法。
static func victory_diversity(games: Array, victory_types: Array = []) -> Dictionary:
	var distribution := {}
	for category in victory_types:
		distribution[str(category["id"])] = {"id":category["id"], "label":category["label"], "count":0, "percentage":null}
	var classified := 0
	var unclassified := 0
	for game in games:
		if str(game.get("winner", "")) == "": continue
		var method: Variant = game.get("victory_method")
		if not method is Dictionary or not method.get("id") is String or str(method.get("id", "")) == "" \
				or not method.get("label") is String or str(method.get("label", "")) == "":
			unclassified += 1
			continue
		var id := str(method["id"])
		if not distribution.has(id):
			if not victory_types.is_empty():
				unclassified += 1
				continue
			distribution[id] = {"id":id, "label":method["label"], "count":0, "percentage":null}
		distribution[id]["count"] += 1
		classified += 1
	var entropy := 0.0
	var observed := 0
	for row in distribution.values():
		row["percentage"] = 0.0 if classified > 0 else null
		if int(row["count"]) == 0: continue
		observed += 1
		var proportion := float(row["count"]) / classified
		row["percentage"] = 100.0 * proportion
		entropy -= proportion * log(proportion)
	return {"label":"获胜方式多样性", "unit":"种", "value":exp(entropy) if classified > 0 else null,
		"numerator":null, "denominator":classified, "classified_games":classified,
		"unclassified_wins":unclassified, "observed_categories":observed,
		"category_count":distribution.size(), "distribution":distribution.values()}
