# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Lab = preload("res://tools/balance/off_work_run.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	var metrics := Lab.BalanceMetrics.new({"work":{"name":"工作"}, "money":{"name":"金钱"},
		"employee":{"name":"雇员"}, "coffee":{"name":"咖啡"}, "grinder":{"name":"调参版卷王"}, "strike":{"name":"罢工"}})
	var report := {"games":0, "timeouts":0, "purchases":{}, "market_offers":{"employee":1, "coffee":1, "strike":1},
		"flow":{"work_done":0, "work_income":0, "upgrades":0, "work_transferred":0}}
	var first := _match("a", 30.0, 1, 1)
	Lab._collect_events([
		{"kind":"new_game"},
		{"kind":"work_complete","ids":[1,2],"amount":2},
		{"kind":"buy","card_type":"employee"}, {"kind":"buy","card_type":"coffee"},
		{"kind":"coffee_start"}, {"kind":"coffee_upgrade","to_type":"grinder","coffee_ids":[3,4],"amount":2},
		{"kind":"slack_start"}, {"kind":"slack_complete","coffee_ids":[5,6,7]},
		{"kind":"transfer_start"}, {"kind":"transfer","ids":[8,9,10]}, {"kind":"transfer","ids":[]},
		{"kind":"meeting_start","targets":[11,12]}, {"kind":"meeting_end"},
		{"kind":"strike","targets":[13,14]}, {"kind":"strike","targets":[]}, {"kind":"strike_end"},
	], report, first)
	_check(first.upgrades == 1 and first.tool_generations == 1 and first.interferences == 3, "count completed effects once per batch")
	_check(first.acquisitions == {"employee":1,"coffee":4,"grinder":1}, "buy, produced cards and promotion results contribute their actual quantities")
	var result := _add(metrics, report, first)
	_check(result.version == 2 and result.upgrades_per_minute.value == 2, "30 seconds gives two upgrades per minute")
	_check(result.first_player_win_rate.value == 100, "seat one started and won")
	_check(result.card_acquisitions.total == 6 and result.card_acquisitions.observed_games == 1, "one observed match with six acquisitions")
	var distribution := {}
	for row in result.card_acquisitions.distribution: distribution[row.id] = row
	_check(distribution.size() == 4 and distribution.strike.count == 0 and distribution.strike.percentage == 0, "include all non-resource kinds even when count is zero")
	_check(distribution.grinder.label == "调参版卷王" and is_equal_approx(distribution.coffee.percentage, 100.0 * 4 / 6), "use this card table's labels and acquisition total")
	result = _add(metrics, report, _match("draw", 90.0, 0, 1))
	_check(result.upgrades_per_minute.value == 1 and result.tool_generations_per_minute.value == 1 and result.interferences_per_minute.value == 3, "mean of 30- and 90-second match rates, not a pooled rate")
	_check(result.first_player_win_rate.value == 50 and result.first_player_win_rate.denominator == 2, "natural draw counts in first-player denominator")
	var timeout := _match("timeout", 60.0, 1, 1)
	timeout.interferences = 1
	result = _add(metrics, report, timeout)
	_check(is_equal_approx(result.interferences_per_minute.value, 7.0 / 3.0), "timed-out games contribute observed events and time")
	_check(result.first_player_win_rate.denominator == 2, "timed-out game does not count as a decided opportunity")
	result = _add(metrics, report, _match("b", 10.0, 0, -1))
	_check(result.first_player_win_rate.denominator == 2, "naturally ended game without a first opportunity has no first player")
	result = _add(metrics, report, _match("timeout", 0.0, 0, -1))
	_check(result.upgrades_per_minute.denominator == 4 and result.card_acquisitions.observed_games == 5, "zero-duration observation is valid for acquisition counts only")
	print("WORK_LAB_METRICS %s (%d checks)" % ["PASS" if failures == 0 else "FAIL", checks])
	quit(1 if failures else 0)

func _match(outcome: String, seconds: float, a_seat: int, first_seat: int) -> Dictionary:
	return {"winner":outcome,"seconds":seconds,"a_seat":a_seat,"first_seat":first_seat,
		"upgrades":0,"tool_generations":0,"interferences":0,"acquisitions":{}}

func _add(metrics: RefCounted, report: Dictionary, game: Dictionary) -> Dictionary:
	report.games += 1
	report.timeouts += int(game.winner == "timeout")
	return metrics.add_game(game, report)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
