# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

const Logic = preload("res://tools/balance/logic.gd")
const Scoring = preload("res://tools/balance/scoring.gd")
const EvalReport = preload("res://tools/eval_report.gd")
const Victory = preload("res://tools/balance/victory.gd")
var failed := 0
var passed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	CardDB.load_from("res://data/cards.json")
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/cards.json"))
	check(Logic.validate(base, base).is_empty(), "默认卡表通过白名单")
	var resale := base.duplicate(true)
	resale["yunketang"]["pawn"] = 0
	resale["dujiaoshou"]["pawn"] = 42
	check(Logic.validate(resale, base).is_empty(), "评估接受普通卡出售价格覆盖和传说卡出售价格修改")
	resale["yunketang"]["pawn"] = -1
	check(not Logic.validate(resale, base).is_empty(), "出售价格不接受负数")
	resale = base.duplicate(true)
	resale["user"]["pawn"] = 5
	check(not Logic.validate(resale, base).is_empty(), "资源卡出售语义仍固定")
	var invalid := base.duplicate(true)
	invalid["_game"]["win_cash"] += 1
	check(not Logic.validate(invalid, base).is_empty(), "固定胜利线不可修改")
	invalid = base.duplicate(true)
	invalid["yunketang"]["recipe_n"] = 1.5
	check(not Logic.validate(invalid, base).is_empty(), "可调项要求正整数")
	invalid = base.duplicate(true)
	invalid["_game"]["start_cash"] = invalid["_game"]["win_cash"]
	check(not Logic.validate(invalid, base).is_empty(), "初始现金低于胜利线")
	var games := [
		{"winner":"player","first":"player","end_round":4,"observed_seat_rounds":8,"feedback_rounds":3,"bilateral_attack":true,"upgrade_occurred":false,"upgrade_produced":false,"pawned_seats":[],"used_cards":["yunketang","butie"]},
		{"winner":"ai","first":"player","end_round":6,"observed_seat_rounds":12,"feedback_rounds":5,"bilateral_attack":false,"upgrade_occurred":true,"upgrade_produced":true,"pawned_seats":["ai"],"used_cards":["yunketang","jiaolv"]},
		{"winner":"","first":"ai","end_round":null,"observed_seat_rounds":10,"feedback_rounds":2,"bilateral_attack":false,"upgrade_occurred":false,"upgrade_produced":false,"pawned_seats":[],"used_cards":[]},
	]
	var scores := Scoring.summarize(games,["yunketang","butie","jiaolv","chaping"])
	check(is_equal_approx(scores["Q1"]["value"],50.0), "Q1先手胜率只用已结束局")
	check(scores["Q1"]["numerator"]==1 and scores["Q1"]["denominator"]==2, "Q1显示分子分母")
	check(is_equal_approx(scores["Q2"]["value"],5.0), "Q2平均结束回合")
	check(is_equal_approx(scores["Q3"]["value"],100.0/3.0), "Q3未结束比例")
	check(is_equal_approx(scores["Q4"]["value"],100.0/3.0), "Q4反馈座位回合比例")
	check(is_equal_approx(scores["Q5"]["value"],100.0/3.0), "Q5双方攻击比例")
	check(is_equal_approx(scores["Q6"]["value"],75.0), "Q6去重卡牌覆盖")
	check(is_equal_approx(scores["Q7"]["value"],100.0/3.0), "Q7升级后成功生产比例")
	check(scores["Q7"]["definition"] == "upgrade-production-v1", "Q7自身携带口径标记供进度与历史识别")
	check(scores["Q8"]["value"] == null and scores["Q8"]["denominator"] == 0 \
		and scores["Q9"]["value"] == null and scores["Q9"]["denominator"] == 0,
		"旧记录未采集峰值时显示未观测，不当作零")
	for i in games.size():
		games[i]["max_cash"] = [40,60,20][i]
		games[i]["max_users"] = [12,21,12][i]
	var peaks := Scoring.summarize(games,["yunketang","butie","jiaolv","chaping"])
	check(is_equal_approx(peaks["Q8"]["value"],40.0) and peaks["Q8"]["denominator"] == 3,
		"Q8先取每局最高现金，再跨局平均，包含未结束局")
	check(is_equal_approx(peaks["Q9"]["value"],15.0) and peaks["Q9"]["denominator"] == 3,
		"Q9先取每局最高用户，再跨局平均")
	check(peaks["Q8"]["unit"] == "现金" and peaks["Q9"]["unit"] == "用户", "资源峰值保留各自单位")
	var legacy_unchanged := true
	for q in ["Q1","Q2","Q3","Q4","Q5","Q6","Q7"]:
		legacy_unchanged = legacy_unchanged and scores[q] == peaks[q]
	check(legacy_unchanged, "增加资源峰值不改变Q1-Q7")
	var partial := Scoring.summarize([
		{"max_cash":0,"max_users":4}, {"max_cash":12.0}, {"max_cash":null,"max_users":6},
		{"max_cash":"8","max_users":true}, {"max_cash":-1,"max_users":INF}, {"max_cash":2.5,"max_users":NAN}
	],[])
	check(partial["Q8"]["value"] == 6.0 and partial["Q8"]["denominator"] == 2,
		"Q8只计有效非负整数，已观测的零仍纳入分母")
	check(partial["Q9"]["value"] == 5.0 and partial["Q9"]["denominator"] == 2,
		"Q9独立计有效局数，缺失与非法值不污染均值")
	_test_acquisition_distribution()
	_test_victory_diversity()
	_test_victory_classification()
	_test_upgrade_and_pawn_metrics()
	_test_upgrade_production_collection()
	_test_pawn_collection()
	_test_transient_resource_peak()
	_test_report_output()
	var cfgs := AISearch.duel_seats(AISearch.from_strength(0), AISearch.from_strength(0), false)
	var plain := MatchSimulator.run_rounds(3,93,Callable(),Callable(),Callable(),cfgs,"ai")
	var counts := {"production":0,"attack":0}
	var actual_peaks := {}
	var observed := MatchSimulator.run_rounds(3,93,
		func(s:GameState)->void: EvalReport._observe_resources(actual_peaks,s),
		func(s:GameState)->void: EvalReport._begin_settle_observation(actual_peaks,s),Callable(),cfgs,"ai",
		{"intent":func(s:GameState,intent:Dictionary,result:Dictionary)->void:
			EvalReport._observe_resources(actual_peaks,s)
			EvalReport._observe_pawn(actual_peaks,s,intent,result),
		"settle":func(event:String,s:GameState,d:Dictionary)->void:
			EvalReport._observe_resources(actual_peaks,s)
			if event == "production": EvalReport._observe_upgrade_production(actual_peaks,s,d)
			if counts.has(event):counts[event]+=1})
	check(StateCodec.state_hash(plain)==StateCodec.state_hash(observed),"观测钩子不改变规则或随机流")
	print("balance eval: %d 通过 / %d 失败" % [passed,failed])
	quit(1 if failed else 0)

func _metric_record(winner: String, fields: Dictionary) -> Dictionary:
	var record := {"winner":winner,"first":GameState.PLAYER,"end_round":3}
	record.merge(fields)
	return record

func _test_upgrade_and_pawn_metrics() -> void:
	var old := Scoring.summarize([_metric_record("player",{"upgrade_occurred":true})],[])
	check(old["Q7"]["value"] == null and old["Q7"]["denominator"] == 0 \
		and old["Q11"]["value"] == null and old["Q11"]["denominator"] == 0,
		"旧局缺新字段时未观测，旧升级发生不能冒充升级后生产")
	var rows := [
		_metric_record("player",{"upgrade_produced":false,"pawned_seats":["player"]}),
		_metric_record("ai",{"upgrade_produced":false,"pawned_seats":["player"]}),
		_metric_record("player",{"upgrade_produced":true,"pawned_seats":["ai","player"]}),
		_metric_record("",{"upgrade_produced":true,"pawned_seats":["player","ai"]}),
		_metric_record("ai",{"upgrade_produced":false,"pawned_seats":[]}),
		_metric_record("ai",{"upgrade_produced":false,"pawned_seats":["ai","ai"]}),
		_metric_record("player",{"upgrade_occurred":true}),
		_metric_record("player",{"upgrade_produced":1,"pawned_seats":[""]}),
		_metric_record("player",{"upgrade_produced":"true","pawned_seats":"player"}),
		_metric_record("player",{"upgrade_produced":null,"pawned_seats":["bogus"]}),
	]
	var metrics := Scoring.summarize(rows,[])
	check(metrics["Q7"]["numerator"] == 2 and metrics["Q7"]["denominator"] == 6,
		"Q7只接受布尔采集字段，未结束但已经成功生产的局也可计分子")
	check(metrics["Q11"]["numerator"] == 3 and metrics["Q11"]["denominator"] == 6,
		"Q11只看最终赢家是否典当，双方典当和重复典当每局至多1，败者与未结束不计分子")
	check(metrics["Q11"]["value"] == 50.0 and metrics["Q11"]["unit"] == "%",
		"Q11分母含未典当及未结束的已采集局，缺失或非法字段独立排除")

func _install_metric_cards() -> void:
	CardDB.CARDS["metric_t1"] = {"name":"指标一级","kind":"product","tier":1,"price":2,"weight":1,
		"recipe_res":"user","recipe_n":1,"output_res":"cash","output_n":2}
	CardDB.CARDS["metric_t2"] = {"name":"指标二级","kind":"product","tier":2,"price":2,"weight":1,
		"recipe_res":"user","recipe_n":1,"output_res":"cash","output_n":3,
		"upgrade_from":"metric_t1","upgrade_dup_n":2}

func _metric_combo(s: GameState, who: String, uid: int) -> Array:
	var core := s.find_card(who,uid)
	var def := CardDB.get_def(str(core["def_id"]))
	var uids: Array = [uid]
	for card in s.players[who]["cards"]:
		if bool(card.get("locked",false)): continue
		if CardDB.get_def(str(card["def_id"])).get("res") == def.get("recipe_res"):
			uids.append(card["uid"])
			if uids.size() > int(def["recipe_n"]): break
	check(s.create_combo(who,uids).get("ok",false), "指标夹具可通过真实规则组成生产组合")
	return uids

func _resolve_metric_production(s: GameState,g: Dictionary) -> void:
	var plain := GameState.new()
	StateCodec.restore(plain,StateCodec.snapshot(s))
	EvalReport._begin_settle_observation(g,s)
	Settle.produce(s,func(event:String,state:GameState,d:Dictionary)->void:
		if event == "production": EvalReport._observe_upgrade_production(g,state,d))
	Settle.produce(plain)
	check(StateCodec.state_hash(s) == StateCodec.state_hash(plain), "UID采集不改变结算结果或随机流")

func _metric_upgrade(s: GameState,g: Dictionary,who: String) -> int:
	var a := s.add_card(who,"metric_t1")
	var b := s.add_card(who,"metric_t1")
	check(s.create_combo(who,[a["uid"],b["uid"]]).get("ok",false), "指标夹具真实生成升级组合")
	_resolve_metric_production(s,g)
	Settle.finalize(s)
	check(g.get("upgrade_occurred",false) and not g.get("upgrade_produced",false), "仅完成升级还不算Q7")
	return int(g["upgraded_uids"].keys().back())

func _test_upgrade_production_collection() -> void:
	var saved := CardDB.CARDS.duplicate(true)
	_install_metric_cards()
	for who in [GameState.PLAYER,GameState.AI]:
		var s := _victory_state(20,20,4,4)
		s.market = ["metric_t2"]
		var bought := IntentApply.new(s).apply(Intent.buy(who,0),who)
		check(bought.get("ok",false), "同名T2实际通过购买获得，不能凭类型算升级产物")
		var ordinary := s.add_card(who,"metric_t1")
		_metric_combo(s,who,int(ordinary["uid"]))
		_metric_combo(s,who,int(bought["new_uid"]))
		var g := {}
		var upgraded_uid := _metric_upgrade(s,g,who)
		check(g["upgraded_uids"].size() == 1 and not g["upgraded_uids"].has(int(bought["new_uid"])) \
			and s.find_card(who,upgraded_uid).get("def_id") == "metric_t2",
			"同轮先有普通生产创建资源UID，仍精确标记唯一升级产物而不误标买来的同名T2")
		_metric_combo(s,who,int(bought["new_uid"]))
		_resolve_metric_production(s,g)
		check(not g["upgrade_produced"], "升级后由别的同名实例生产仍不算Q7")
		Settle.finalize(s)
		s.round_num += 1
		_metric_combo(s,who,upgraded_uid)
		_resolve_metric_production(s,g)
		check(g["upgrade_produced"], "任一座位升级生成的实际UID后续正产出计Q7")
	for scenario in ["interrupted","unpaid","zero","sold_replaced"]:
		_install_metric_cards()
		var s := _victory_state(20,20,4,4)
		var g := {}
		var uid := _metric_upgrade(s,g,GameState.PLAYER)
		if scenario == "sold_replaced":
			check(IntentApply.new(s).apply(Intent.pawn(GameState.PLAYER,[uid]),GameState.PLAYER).get("ok",false),
				"升级产物实际典当成功")
			s.market = ["metric_t2"]
			var bought := IntentApply.new(s).apply(Intent.buy(GameState.PLAYER,0),GameState.PLAYER)
			uid = int(bought["new_uid"])
		elif scenario == "zero":
			CardDB.CARDS["metric_t2"]["output_n"] = 0
		elif scenario == "unpaid":
			CardDB.CARDS["metric_t2"]["recipe_res"] = "cash"
			CardDB.CARDS["metric_t2"]["recipe_n"] = s.resource_count(GameState.PLAYER,CardDB.RES_CASH)
		var uids := _metric_combo(s,GameState.PLAYER,uid)
		if scenario == "interrupted":
			var pools := {CardDB.RES_CASH:0,CardDB.RES_USER:1}
			var attacked := false
			for target in s.affordable_targets(GameState.PLAYER,pools):
				if int(uids[1]) in target["uids"]:
					attacked = s.apply_attack(GameState.AI,target,pools).get("ok",false)
					break
			check(attacked, "通过真实攻击拆散升级产物的生产配方")
		_resolve_metric_production(s,g)
		check(not g["upgrade_produced"], "被打断/付不起/零产出/卖出后同名替代实例均不算Q7："+scenario)
	_install_metric_cards()
	var legend_state := _victory_state(2,2,4,4)
	var materials: Array = []
	for i in 4: materials.append(legend_state.add_card(GameState.PLAYER,"metric_t1")["uid"])
	check(legend_state.create_combo(GameState.PLAYER,materials).get("ok",false), "真实直升传说夹具成立")
	var legend_observation := {}
	_resolve_metric_production(legend_state,legend_observation)
	Settle.finalize(legend_state)
	var legend_uid := int(legend_observation["upgraded_uids"].keys()[0])
	check(IntentApply.new(legend_state).apply(Intent.pawn(GameState.PLAYER,[legend_uid]),GameState.PLAYER).get("ok",false) \
		and not legend_observation["upgrade_produced"], "升级传说再典当仍不算升级后生产")
	CardDB.CARDS = saved

func _test_pawn_collection() -> void:
	var saved := CardDB.CARDS.duplicate(true)
	_install_metric_cards()
	for id in ["metric_t1",CardDB.unit_id(CardDB.RES_USER),"dujiaoshou"]:
		var s := _victory_state(2,2,4,4)
		var g := {"pawned_seats":[]}
		var app := IntentApply.new(s)
		app.landed_intent.connect(func(intent:Dictionary,result:Dictionary,_from:String)->void:
			var before := StateCodec.state_hash(s)
			EvalReport._observe_pawn(g,s,intent,result)
			check(before == StateCodec.state_hash(s), "典当观测不改变局面或随机流"))
		var card := s.add_card(GameState.PLAYER,id)
		var result := app.apply(Intent.pawn(GameState.PLAYER,[card["uid"]]),GameState.PLAYER)
		check(result.get("ok",false) and s.find_card(GameState.PLAYER,card["uid"]).is_empty() \
			and g["pawned_seats"] == [GameState.PLAYER], "普通牌、用户、传说的真实成功典当都采集："+id)
		var other := s.add_card(GameState.PLAYER,"metric_t1")
		app.apply(Intent.pawn(GameState.PLAYER,[other["uid"]]),GameState.PLAYER)
		check(g["pawned_seats"].size() == 1, "同座位反复典当只记录一次")
		var rival := s.add_card(GameState.AI,"metric_t1")
		app.apply(Intent.pawn(GameState.AI,[rival["uid"]]),GameState.AI)
		check(g["pawned_seats"].size() == 2, "赢家未定时双方成功典当都保留，留待终局选择")
	var s := _victory_state(2,2)
	var g := {"pawned_seats":[]}
	var app := IntentApply.new(s)
	app.landed_intent.connect(func(intent:Dictionary,result:Dictionary,_from:String)->void:
		EvalReport._observe_pawn(g,s,intent,result))
	var good := s.add_card(GameState.PLAYER,"metric_t1")
	var cash_uid := int(s.players[GameState.PLAYER]["cards"][0]["uid"])
	for uids in [[],[999999],[good["uid"],cash_uid]]:
		var result := app.apply(Intent.pawn(GameState.PLAYER,uids),GameState.PLAYER)
		EvalReport._observe_pawn(g,s,Intent.pawn(GameState.PLAYER,uids),result)
		check(not result.get("ok",false) and g["pawned_seats"].is_empty() \
			and not s.find_card(GameState.PLAYER,good["uid"]).is_empty(),
			"空典当、不存在卡和含非法卡整批失败不计Q11且合法卡未被移除")
	EvalReport._observe_pawn(g,s,Intent.pawn(GameState.PLAYER,[]),{"ok":true,"uids":[]})
	check(g["pawned_seats"].is_empty(), "没有真实移除卡的空成功结果也不计典当")
	CardDB.CARDS = saved

func _test_transient_resource_peak() -> void:
	var s := GameState.new()
	s.new_game()
	for who in [GameState.PLAYER,GameState.AI]:
		s.players[who]["cards"].clear()
		for i in 10: s.add_card(who,"cash")
		for i in 5: s.add_card(who,"user")
	# 第一组产出现金 9，第二组消耗现金 8 产出用户 6；结算终点只有现金 11，峰值却是 19。
	CardDB.CARDS["peak_cash_test"] = {"name":"峰值现金测试","kind":"product","tier":1,
		"price":-1,"weight":0,"recipe_res":"user","recipe_n":1,"output_res":"cash","output_n":9}
	CardDB.CARDS["peak_users_test"] = {"name":"峰值用户测试","kind":"product","tier":1,
		"price":-1,"weight":0,"recipe_res":"cash","recipe_n":8,"output_res":"user","output_n":6}
	var source := s.add_card(GameState.PLAYER,"peak_cash_test")
	var source_users := s.add_card(GameState.PLAYER,"peak_users_test")
	var cash_uids: Array = [source_users["uid"]]
	var user_uid := -1
	for card in s.players[GameState.PLAYER]["cards"]:
		if card["def_id"] == "cash" and cash_uids.size() < 9: cash_uids.append(card["uid"])
		if card["def_id"] == "user": user_uid = int(card["uid"])
	check(s.create_combo(GameState.PLAYER,[source["uid"],user_uid]).get("ok",false) \
		and s.create_combo(GameState.PLAYER,cash_uids).get("ok",false), "峰值夹具两组都能真实结算")
	var observed := {}
	EvalReport._observe_resources(observed,s)
	check(observed["max_cash"] == 10 and observed["max_users"] == 5, "开局峰值取任意一方而非双方相加")
	var before := StateCodec.state_hash(s)
	EvalReport._observe_resources(observed,s)
	check(StateCodec.state_hash(s) == before, "峰值观测不改变局面或随机流")
	Settle.produce(s,func(_event:String,state:GameState,_detail:Dictionary)->void:
		EvalReport._observe_resources(observed,state))
	check(s.resource_count(GameState.PLAYER,CardDB.RES_CASH) == 11 and observed["max_cash"] == 19,
		"记录单组结算后的现金瞬时峰值，而非只看回合结束")
	check(s.resource_count(GameState.PLAYER,CardDB.RES_USER) == 11 and observed["max_users"] == 11,
		"各资源峰值独立记录")
	CardDB.CARDS.erase("peak_cash_test")
	CardDB.CARDS.erase("peak_users_test")

func _test_report_output() -> void:
	var folder := ProjectSettings.globalize_path("user://test-eleven-metrics-%d" % OS.get_process_id())
	var output := folder.path_join("result.json")
	var request := folder.path_join("request.json")
	var progress := folder.path_join("progress.json")
	EvalReport._write(request,{"schema":"manual-balance-request-v1",
		"cards_path":ProjectSettings.globalize_path("res://data/cards.json"),"output_path":output,"progress_path":progress,
		"options":{"pairs":1,"max_rounds":1,"seed_start":93,"model":"ai","strength":0,"ai_parameters":{}}})
	var logs: Array = []
	var code := OS.execute(OS.get_executable_path(),PackedStringArray(["--headless","--path",
		ProjectSettings.globalize_path("res://"),"--script","res://tools/eval_report.gd","--",request]),logs,true)
	var report := EvalReport._json(output)
	check(code == 0 and report.get("status") == "complete", "真实评估命令输出完成的报告")
	check(report.get("meta",{}).get("metric_version") == "manual-eleven-v4", "新报告指标版本为manual-eleven-v4")
	var collected: Array = report.get("games",[])
	var valid := collected.size() == 2
	var cash_sum := 0
	var users_sum := 0
	for game in collected:
		valid = valid and game.get("max_cash",-1) >= CardDB.game_rules()["start_cash"] \
			and game.get("max_users",-1) >= CardDB.game_rules()["start_user"]
		valid = valid and game.get("victory_method") is Dictionary and game.get("acquisitions") is Dictionary
		valid = valid and game.get("upgrade_produced") is bool and Scoring.valid_pawned_seats(game.get("pawned_seats"))
		cash_sum += int(game.get("max_cash",0))
		users_sum += int(game.get("max_users",0))
	check(valid, "真实逐局记录包含开局及过程资源峰值")
	var metrics: Dictionary = report.get("metrics",{})
	check(metrics.get("Q8",{}).get("numerator") == cash_sum and metrics.get("Q8",{}).get("denominator") == 2 \
		and metrics.get("Q9",{}).get("numerator") == users_sum and metrics.get("Q9",{}).get("denominator") == 2,
		"真实Q8/Q9从逐局峰值汇总并包含未结束局")
	var acquisition_total := 0
	var acquired_ids := {}
	for game in collected:
		for id in game.get("acquisitions",{}):
			check(CardDB.get_def(str(id)).get("kind") != CardDB.KIND_UNIT, "真实获得卡牌字段没有资源卡")
			acquisition_total += int(game["acquisitions"][id])
			acquired_ids[id] = true
	var acquisition_metric: Dictionary = metrics.get("Q6",{}).get("acquisitions",{})
	check(acquisition_total > 0 and acquisition_metric.get("total") == acquisition_total \
		and acquisition_metric.get("observed_games") == 2,
		"真实发牌观测有非零记录且Q6分布由逐局张数汇总")
	for row in acquisition_metric.get("distribution",[]):
		if int(row["count"]) > 0: check(acquired_ids.has(row["id"]), "分布正数只来自实际获得卡牌")
	check(metrics.has("Q10") and metrics["Q10"]["category_count"] == Victory.categories().size(),
		"真实报告包含Q10及当前卡表支持的获胜分类")
	var classified := 0
	for game in collected:
		if game.get("victory_method",{}).has("id"): classified += 1
	check(metrics.get("Q10",{}).get("denominator") == classified, "Q10分母来自真实逐局获胜归类")
	var rebuilt := Scoring.summarize(collected,[],Victory.categories())
	var same_new_metrics := true
	# JSON 将整数解成 float；逐字段比较数值，避免 Dictionary 的类型严格比较造成假失败。
	for q in ["Q7","Q11"]:
		for key in rebuilt[q]:
			same_new_metrics = same_new_metrics and metrics.get(q,{}).get(key) == rebuilt[q][key]
	check(same_new_metrics and metrics["Q7"]["denominator"] == 2 and metrics["Q11"]["denominator"] == 2,
		"真实Q7/Q11可以从逐局新字段重算且未结束局也纳入分母")
	check(EvalReport._json(progress).get("metrics") == metrics, "最终进度与报告所有指标及Q7口径标记一致")
	if code != 0: printerr("\n".join(logs))
	for path in [output,request,progress]: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(folder)

func _test_victory_diversity() -> void:
	var categories := [{"id":"cash_threshold","label":"普通现金达标"},
		{"id":"cash_depletion","label":"对手现金清零"},{"id":"user_depletion","label":"对手用户清零"}]
	var a := {"winner":"player","victory_method":categories[0]}
	var b := {"winner":"ai","victory_method":categories[1]}
	var c := {"winner":"ai","victory_method":categories[2]}
	var one := Scoring.victory_diversity([a,a,a],categories)
	check(is_equal_approx(one["value"],1.0), "Q10单一胜法为1，与重复局数无关")
	check(one["distribution"].size() == 3 and one["distribution"][1]["count"] == 0,
		"分布保留配置支持但未出现的胜法")
	var two := Scoring.victory_diversity([a,b],categories)
	check(is_equal_approx(two["value"],2.0), "两种各一半时有效种数为2")
	check(two["distribution"][0]["percentage"] == 50.0 and two["denominator"] == 2
		and two["numerator"] == null and two["unit"] == "种", "Q10保留分布与样本数，不伪装成比例")
	check(is_equal_approx(Scoring.victory_diversity([a,b,c],categories)["value"],3.0), "三种均匀分布为3")
	check(absf(Scoring.victory_diversity([a,a,a,b],categories)["value"] - 1.7547653506) < 0.000001,
		"75/25分布有效种数约1.755，小于均匀分布")
	var missing := Scoring.victory_diversity([{"winner":""}, {"winner":"player"}],categories)
	check(missing["value"] == null and missing["denominator"] == 0 and missing["unclassified_wins"] == 1,
		"旧记录与未结束局不当成一种胜法，无已归类样本时未观测")
	check(missing["distribution"][0]["percentage"] == null, "零已归类样本时每类占比同样未观测")
	var mixed := Scoring.victory_diversity([a,{"winner":"","victory_method":categories[1]},
		{"winner":"ai","victory_method":{}},{"winner":"ai","victory_method":{"id":"bogus","label":"非法"}}],categories)
	check(mixed["value"] == 1.0 and mixed["classified_games"] == 1 and mixed["unclassified_wins"] == 2,
		"未结束和无效分类不污染Q10，有效样本独立计数")
	check(Scoring.victory_diversity([a,b])["value"] == two["value"], "独立逐局记录可重算同一多样性")

func _victory_state(cash_a: int, cash_b: int, user_a := 2, user_b := 2) -> GameState:
	var s := GameState.new()
	s.players = {GameState.PLAYER:{"cards":[]},GameState.AI:{"cards":[]}}
	for index in 2:
		var who: String = [GameState.PLAYER,GameState.AI][index]
		for i in [cash_a,cash_b][index]: s.add_card(who,CardDB.unit_id(CardDB.RES_CASH))
		for i in [user_a,user_b][index]: s.add_card(who,CardDB.unit_id(CardDB.RES_USER))
	return s

func _test_victory_classification() -> void:
	var limit := int(CardDB.game_rules()["win_cash"])
	for sample in [[limit,2,2,2,"cash_threshold"],[2,0,2,2,"cash_depletion"],
		[2,2,2,0,"user_depletion"],[0,2,2,2,"cash_depletion"],[2,2,0,2,"user_depletion"],
		[limit,0,2,0,"cash_threshold"],[2,0,2,0,"cash_depletion"]]:
		var s := _victory_state(sample[0],sample[1],sample[2],sample[3])
		s.check_victory()
		var before := StateCodec.state_hash(s)
		check(Victory.classify(s).get("id") == sample[4], "资源状态归类遵循引擎胜负优先级，且不受座位文案影响")
		check(StateCodec.state_hash(s) == before, "获胜分类不修改规则、状态或随机流")
	var running := _victory_state(2,2)
	check(Victory.classify(running).is_empty(), "未结束局没有获胜方式")
	running.winner = GameState.PLAYER
	check(Victory.classify(running).is_empty(), "无资源终局条件的胜利不伪装成现金/用户清零")
	var legend_ids: Array = []
	for id in CardDB.all_cards():
		if CardDB.get_def(id).get("kind") == CardDB.KIND_LEGEND and CardDB.pawn_value(id) > 0: legend_ids.append(id)
	for id in legend_ids:
		var s := _victory_state(maxi(1,limit-CardDB.pawn_value(id)),2)
		var card := s.add_card(GameState.PLAYER,id)
		var known := Victory.legend_uids(s,GameState.PLAYER)
		var intent := Intent.pawn(GameState.PLAYER,[card["uid"]])
		var result := IntentApply.new(s).apply(intent,GameState.PLAYER)
		check(result["ok"] and s.winner == GameState.PLAYER, "传说典当夹具经真实管道获胜："+str(id))
		check(Victory.classify(s,Victory.sold_legends(intent,known)).get("id") == "legend_cashout:"+str(id),
			"典当后传说已不在手中，仍按行动前UID正确归类："+str(id))
	if legend_ids.size() >= 2:
		var id_a: String = legend_ids[0]
		var id_b: String = legend_ids[1]
		var s := _victory_state(maxi(1,limit-CardDB.pawn_value(id_a)-CardDB.pawn_value(id_b)),2)
		var a := s.add_card(GameState.PLAYER,id_a)
		var b := s.add_card(GameState.PLAYER,id_b)
		var known := Victory.legend_uids(s,GameState.PLAYER)
		var intent := Intent.pawn(GameState.PLAYER,[a["uid"],b["uid"]])
		var result := IntentApply.new(s).apply(intent,GameState.PLAYER)
		check(result["ok"] and Victory.classify(s,Victory.sold_legends(intent,known)).get("id") == "legend_cashout:mixed",
			"同次典当多种传说触发资金胜利时独立归类，不任意归给其中一种")
		check(Victory.sold_legends({"uids":[a["uid"],a["uid"]]},known).size() == 1,
			"同种传说按种类去重，不误记为混合传说路线")
	var plain := _victory_state(limit,2)
	plain.check_victory()
	check(Victory.classify(plain).get("id") == "cash_threshold", "此前曾经典当传说不自动归因于此次现金达标")

func _test_acquisition_distribution() -> void:
	var s := _victory_state(40,40,10,10)
	var g := {}
	EvalReport._observe_acquisitions(g,s)
	check(g["acquisitions"].is_empty(), "开局现金与用户均不计获得")
	var materials: Array = []
	for who in [GameState.PLAYER,GameState.PLAYER,GameState.AI]:
		s.market = ["yunketang"]
		var result := IntentApply.new(s).apply(Intent.buy(who,0),who)
		check(result.get("ok",false), "获得指标通过真实购买发牌")
		if who == GameState.PLAYER: materials.append(result["new_uid"])
		EvalReport._observe_acquisitions(g,s)
	var snapshot := StateCodec.state_hash(s)
	EvalReport._observe_acquisitions(g,s)
	check(snapshot == StateCodec.state_hash(s) and g["acquisitions"] == {"yunketang":3},
		"双方同名牌按张累计，重复观察不重计且不改变局面")
	check(not IntentApply.new(s).apply(Intent.buy(GameState.PLAYER,99),GameState.PLAYER).get("ok",false),
		"失败购买没有实际发牌")
	EvalReport._observe_acquisitions(g,s)
	check(s.create_combo(GameState.PLAYER,materials).get("ok",false), "获得指标真实创建升级组合")
	Settle.produce(s,func(_event:String,state:GameState,_detail:Dictionary)->void:
		EvalReport._observe_acquisitions(g,state))
	Settle.finalize(s)
	EvalReport._observe_acquisitions(g,s)
	check(g["acquisitions"] == {"yunketang":3,"jiaolv":1},
		"升级产物计获得且材料消耗不扣历史次数，失败购买未计数")
	for card in s.players[GameState.PLAYER]["cards"].duplicate():
		if card["def_id"] == "jiaolv":
			check(s.pawn(GameState.PLAYER,[card["uid"]]).get("ok",false), "实际出售升级产物")
	EvalReport._observe_acquisitions(g,s)
	check(g["acquisitions"] == {"yunketang":3,"jiaolv":1}, "出售和产生现金不改变非资源牌获得量")
	g = {"acquisitions":{"yunketang":2,"butie":1}}
	var dist := Scoring.acquisition_distribution([g,{"acquisitions":{}},{},
		{"acquisitions":{"butie":-1}},{"acquisitions":{"cash":99,"user":40,"yunketang":1}}],
		["yunketang","butie","jiaolv","cash","user"])
	check(dist["observed_games"] == 3 and dist["missing_games"] == 2 and dist["total"] == 4,
		"获得卡牌分母只计实际非资源卡张数；旧局不补零，未获得的观测局保留")
	var rows: Array = dist["distribution"]
	check(rows.size() == 3 and rows[0]["count"] == 3 and rows[0]["percentage"] == 75.0,
		"获得卡牌分布按张数计算占比，排除现金和用户")
	check(rows[2]["count"] == 0 and rows[2]["percentage"] == 0.0, "未获得卡仍保留零值行")
	var empty := Scoring.acquisition_distribution([{"acquisitions":{}}],["yunketang"])
	check(empty["observed_games"] == 1 and empty["total"] == 0 and empty["distribution"][0]["percentage"] == null,
		"零获得不伪造百分比，区别旧记录未采集")
