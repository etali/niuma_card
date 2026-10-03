# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends SceneTree

const Scoring = preload("res://tools/balance/scoring.gd")
const EvalReport = preload("res://tools/eval_report.gd")
var failed := 0
var passed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ",label)

func _initialize() -> void:
	CardDB.load_from("res://data/cards.json")
	_test_limits()
	_test_accumulation()
	print("incremental balance: %d 通过 / %d 失败" % [passed,failed])
	quit(1 if failed else 0)

func _test_limits() -> void:
	var options := {"pairs":5001,"max_rounds":10000,"seed_start":2147483648,
		"model":"ai","strength":0.0,"ai_parameters":{}}
	check(EvalReport.validate_options(options).is_empty(), "允许超过旧500对、500回合及32位种子上限")
	for key in ["pairs","max_rounds","seed_start"]:
		for bad in [0,-1,1.5,INF,NAN,true,"1000",9007199254740992]:
			var changed := options.duplicate(true)
			changed[key] = bad
			check(not EvalReport.validate_options(changed).is_empty(), "保留精确正整数约束：%s=%s" % [key,bad])
	options["pairs"] = 1
	options["seed_start"] = EvalReport.MAX_SAFE_INTEGER
	check(EvalReport.validate_options(options).is_empty(), "最后一个可精确表示的种子可使用，末项没有多减1")
	options["pairs"] = 2
	check(not EvalReport.validate_options(options).is_empty(), "种子区间不能溢出精确整数范围")
	options["seed_start"] = 1
	options["pairs"] = 4503599627370495
	check(EvalReport.validate_options(options).is_empty(), "总局数在精确边界内可接受")
	options["pairs"] += 1
	check(not EvalReport.validate_options(options).is_empty(), "总局数乘二也检查精度")

func _test_accumulation() -> void:
	var ids := ["yunketang","butie","jiaolv"]
	var categories := [{"id":"cash","label":"现金"},{"id":"attack","label":"攻击"}]
	var games := [
		{"winner":"player","first":"player","end_round":4,"observed_seat_rounds":8,"feedback_rounds":3,
		"bilateral_attack":true,"upgrade_produced":false,"pawned_seats":["player"],"used_cards":["yunketang"],
		"max_cash":40,"max_users":8,"acquisitions":{"yunketang":2},"victory_method":categories[0]},
		{"winner":"ai","first":"player","end_round":6,"observed_seat_rounds":12,"feedback_rounds":5,
		"bilateral_attack":false,"upgrade_produced":true,"pawned_seats":["ai"],"used_cards":["butie","jiaolv"],
		"max_cash":60,"max_users":21,"acquisitions":{"butie":1,"jiaolv":1},"victory_method":categories[1]},
		{"winner":"","first":"ai","observed_seat_rounds":10,"feedback_rounds":2,"upgrade_produced":false,
		"pawned_seats":[],"max_cash":20,"max_users":13,"acquisitions":{}}
	]
	var accumulator = Scoring.new(ids,categories)
	var prefix: Array = []
	for g in games:
		accumulator.add_game(g)
		prefix.append(g)
		check(accumulator.snapshot() == Scoring.summarize(prefix,ids,categories), "逐局进度和离线重算完全一致")
	var snapshot: Dictionary = accumulator.snapshot()
	check(snapshot["Q1"]["numerator"] == 1 and snapshot["Q1"]["denominator"] == 2, "增量先手胜率排除未结束局")
	check(snapshot["Q2"]["value"] == 5.0 and snapshot["Q3"]["numerator"] == 1, "局长及超时计数正确")
	check(snapshot["Q4"]["numerator"] == 10 and snapshot["Q4"]["denominator"] == 30, "反馈计数正确")
	check(snapshot["Q5"]["numerator"] == 1 and snapshot["Q6"]["numerator"] == 3, "攻击及覆盖去重正确")
	check(snapshot["Q7"]["numerator"] == 1 and snapshot["Q11"]["numerator"] == 2, "升级和典当获胜计数正确")
	check(snapshot["Q8"]["value"] == 40.0 and snapshot["Q9"]["value"] == 14.0, "资源峰值增量均值正确")
	check(snapshot["Q10"]["value"] == 2.0 and snapshot["Q6"]["acquisitions"]["total"] == 4, "分布及熵只由类别计数计算")
	# 重复刷新不改变累计量；外部修改输入或旧快照不能污染后续统计。
	games[0]["acquisitions"]["yunketang"] = 99
	games[0]["victory_method"]["label"] = "外部修改"
	snapshot["Q10"]["distribution"][0]["count"] = 999
	snapshot["Q6"]["acquisitions"]["distribution"][0]["count"] = 999
	var stable: Dictionary = accumulator.snapshot()
	check(stable["Q10"]["distribution"][0]["count"] == 1 and stable["Q10"]["distribution"][0]["label"] == "现金",
		"获胜快照和输入没有共享可变状态")
	check(stable["Q6"]["acquisitions"]["distribution"][0]["count"] == 2, "获得张数快照和输入不共享状态")
	accumulator.add_game({})
	accumulator.add_game({"upgrade_produced":"bad","pawned_seats":["unknown"],"max_cash":-1,
		"acquisitions":{"butie":-1}})
	var mixed: Dictionary = accumulator.snapshot()
	check(mixed["Q7"]["denominator"] == 3 and mixed["Q11"]["denominator"] == 3 \
		and mixed["Q6"]["acquisitions"]["missing_games"] == 2, "旧记录与非法观测独立排除，不补零")
	check(stable["Q3"]["denominator"] == 3 and mixed["Q3"]["denominator"] == 5, "旧快照保持不变")
	var large = Scoring.new(ids,categories)
	var sample: Dictionary = games[1]
	var start := Time.get_ticks_usec()
	for i in 10000:
		large.add_game(sample)
		large.snapshot()
	var early := Time.get_ticks_usec()-start
	for i in 90000: large.add_game(sample)
	start = Time.get_ticks_usec()
	for i in 10000:
		large.add_game(sample)
		large.snapshot()
	var late := Time.get_ticks_usec()-start
	var final: Dictionary = large.snapshot()
	check(final["Q3"]["denominator"] == 110000 and final["Q6"]["acquisitions"]["total"] == 220000,
		"11万局无需持有历史数组，累计结果正确")
	print("增量统计：前1万次累计+快照 %.1fms；已有10万局后1万次 %.1fms" % [early/1000.0,late/1000.0])
