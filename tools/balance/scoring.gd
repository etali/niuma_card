# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

# 每局只累计一次。指标快照只遍历卡种和获胜类别，不保存或重扫历史对局。
var n := 0
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

var _card_count := 0
var _card_set := {}
var _card_labels := {}
var _acquired := {}
var _acquisition_total := 0
var _acquisition_observed := 0
var _victories := {}
var _fixed_victories := false
var _classified := 0
var _unclassified := 0

func _init(card_ids: Array = [], victory_types: Array = []) -> void:
	_card_count = card_ids.size()
	for id in card_ids:
		_card_set[id] = true
		var definition := CardDB.get_def(str(id))
		if definition.get("kind") != CardDB.KIND_UNIT:
			_acquired[id] = 0
			_card_labels[id] = definition.get("name",str(id))
	_fixed_victories = not victory_types.is_empty()
	for category in victory_types:
		_victories[str(category["id"])] = {"id":category["id"],"label":category["label"],"count":0}

func add_game(g: Dictionary) -> void:
	n += 1
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
		if _card_set.has(id): used[id] = true
	_add_victory(g)
	_add_acquisitions(g)

func snapshot() -> Dictionary:
	var upgrade_metric := metric("升级后成功生产", upgrade_produced, upgrade_observed, "%", 100.0)
	upgrade_metric["definition"] = "upgrade-production-v1"
	var coverage := metric("卡牌使用覆盖", used.size(), _card_count, "%", 100.0)
	coverage["acquisitions"] = _acquisition_metric()
	return {
		"Q1": metric("先手胜率", first_wins, decided, "%", 100.0),
		"Q2": metric("平均结束回合", finished_rounds, decided, "回合", 1.0),
		"Q3": metric("未结束比例", n - decided, n, "%", 100.0),
		"Q4": metric("有效反馈比例", feedback_rounds, observed_seat_rounds, "%", 100.0),
		"Q5": metric("双方攻击比例", bilateral, n, "%", 100.0),
		"Q6": coverage,
		"Q7": upgrade_metric,
		"Q8": metric("局均最大现金数", max_cash_total, max_cash_observed, "现金", 1.0),
		"Q9": metric("局均最大用户数", max_users_total, max_users_observed, "用户", 1.0),
		"Q10": _victory_metric(),
		"Q11": metric("典当后获胜比例", pawn_wins, pawn_observed, "%", 100.0),
	}

# 离线重算与实时累计共用相同口径。
static func summarize(games: Array, card_ids: Array, victory_types: Array = []) -> Dictionary:
	var accumulator = load("res://tools/balance/scoring.gd").new(card_ids,victory_types)
	for g in games: accumulator.add_game(g)
	return accumulator.snapshot()

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


func _add_victory(game: Dictionary) -> void:
	if str(game.get("winner", "")) == "": return
	var method: Variant = game.get("victory_method")
	if not method is Dictionary or not method.get("id") is String or str(method.get("id", "")) == "" \
			or not method.get("label") is String or str(method.get("label", "")) == "":
		_unclassified += 1
		return
	var id := str(method["id"])
	if not _victories.has(id):
		if _fixed_victories:
			_unclassified += 1
			return
		_victories[id] = {"id":id,"label":method["label"],"count":0}
	_victories[id]["count"] += 1
	_classified += 1

func _victory_metric() -> Dictionary:
	var entropy := 0.0
	var observed := 0
	var rows: Array = []
	for entry in _victories.values():
		var row: Dictionary = entry.duplicate()
		rows.append(row)
		row["percentage"] = 0.0 if _classified > 0 else null
		if int(row["count"]) == 0: continue
		observed += 1
		var proportion := float(row["count"]) / _classified
		row["percentage"] = 100.0 * proportion
		entropy -= proportion * log(proportion)
	return {"label":"获胜方式多样性", "unit":"种", "value":exp(entropy) if _classified > 0 else null,
		"numerator":null, "denominator":_classified, "classified_games":_classified,
		"unclassified_wins":_unclassified, "observed_categories":observed,
		"category_count":_victories.size(), "distribution":rows}


static func victory_diversity(games: Array, victory_types: Array = []) -> Dictionary:
	var accumulator = load("res://tools/balance/scoring.gd").new([],victory_types)
	for g in games: accumulator._add_victory(g)
	return accumulator._victory_metric()

func _add_acquisitions(game: Dictionary) -> void:
	var acquisitions: Variant = game.get("acquisitions")
	if not acquisitions is Dictionary: return
	for count in acquisitions.values():
		if not valid_peak(count): return
	_acquisition_observed += 1
	for id in acquisitions:
		if not _acquired.has(id): continue
		_acquired[id] += int(acquisitions[id])
		_acquisition_total += int(acquisitions[id])

func _acquisition_metric() -> Dictionary:
	var rows: Array = []
	for id in _acquired:
		rows.append({"id":id,"label":_card_labels[id],
			"count":_acquired[id],"percentage":100.0 * _acquired[id] / _acquisition_total if _acquisition_total > 0 else null})
	return {"observed_games":_acquisition_observed,"missing_games":n-_acquisition_observed,
		"total":_acquisition_total,"distribution":rows}

static func acquisition_distribution(games: Array, card_ids: Array) -> Dictionary:
	var accumulator = load("res://tools/balance/scoring.gd").new(card_ids)
	accumulator.n = games.size()
	for g in games: accumulator._add_acquisitions(g)
	return accumulator._acquisition_metric()
