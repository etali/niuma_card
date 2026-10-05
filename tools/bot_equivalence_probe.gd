# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 独立等价探针：同一文件可放入修改前/后的项目，仅使用已有公开入口。
## godot --headless --path PROJECT -s tools/bot_equivalence_probe.gd -- cases|games OUTPUT.json
## 不用当前实现生成期望值；分别保存冻结基线与候选版本，再逐字段比较。
const Eval = preload("res://engine/bot_evaluation.gd")
const Actions = preload("res://engine/bot_actions.gd")
const Plan = preload("res://engine/bot_turn_plan.gd")
const Env = preload("res://engine/bot_environment.gd")

var _failures: Array = []

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or not args[0] in ["cases", "games"]:
		printerr("用法：bot_equivalence_probe.gd -- cases|games OUTPUT.json")
		quit(2)
		return
	CardDB.reset()
	BOTConfig._source = "res://data/bot.json"
	if not CardDB.load_default():
		quit(2)
		return
	var started := Time.get_ticks_usec()
	var payload := _cases() if args[0] == "cases" else _games()
	var report := {"schema":"bot-equivalence-v1", "mode":args[0], "payload":payload,
		"failures":_failures, "elapsed_seconds":(Time.get_ticks_usec()-started)/1000000.0,
		"cards_sha256":FileAccess.get_sha256("res://data/cards.json"),
		"godot":Engine.get_version_info()["string"]}
	var file := FileAccess.open(args[1], FileAccess.WRITE)
	if file == null:
		printerr("不能写探针结果：", args[1])
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  ", true, true) + "\n")
	file.close()
	print(args[0], " cases=", payload.size(), " errors=", _failures.size(),
		" seconds=", report["elapsed_seconds"])
	quit(0 if _failures.is_empty() else 1)

func _check(ok: bool, message: String) -> void:
	if not ok:
		_failures.append(message)
		printerr(message)

func _install_fixture_cards() -> void:
	CardDB.CARDS["eq_a"] = _product(2, 3)
	CardDB.CARDS["eq_b"] = _product(4, 6) # 与 a 相同产能比率，保留平手时的原顺序。
	CardDB.CARDS["eq_cash"] = {"name":"Cash fixture", "kind":"product", "tier":1,
		"price":2,"weight":0,"recipe_res":"cash","recipe_n":2,"output_res":"user","output_n":2}
	CardDB.CARDS["eq_attack"] = {"name":"Attack fixture", "kind":"attack", "tier":1,
		"price":2,"weight":0,"recipe_res":"user","recipe_n":2,"attack_res":"cash","attack_n":3}
	CardDB.CARDS["eq_upgrade"] = {"name":"Upgrade fixture", "kind":"legend", "tier":3,
		"price":-1,"weight":0,"upgrade_from":"eq_a","upgrade_dup_n":2,"pawn":9}
	CardDB.CARDS["eq_output"] = {"name":"Output fixture", "kind":"buff", "tier":0,
		"price":2,"weight":0,"buff_type":"output_x2"}
	CardDB.CARDS["eq_protect"] = {"name":"Protect fixture", "kind":"buff", "tier":0,
		"price":2,"weight":0,"buff_type":"protect_user"}
	CardDB.CARDS["eq_fill"] = {"name":"Fill fixture", "kind":"buff", "tier":0,
		"price":2,"weight":0,"buff_type":"user_fill"}

func _product(need: int, output: int) -> Dictionary:
	return {"name":"Product fixture", "kind":"product", "tier":1, "price":2,
		"weight":0,"recipe_res":"user","recipe_n":need,"output_res":"cash","output_n":output}

func _fixture(kind := "ordinary") -> GameState:
	var state := GameState.new()
	state.set_seed(713)
	state.players = {GameState.PLAYER:{"cards":[]},GameState.BOT:{"cards":[]}}
	for who in [GameState.PLAYER, GameState.BOT]:
		for _i in (30 if kind == "rich" else 8):
			state.add_card(who, CardDB.unit_id(CardDB.RES_CASH))
		for _i in (45 if kind == "rich" else 5):
			state.add_card(who, CardDB.unit_id(CardDB.RES_USER))
		for id in (["eq_a", "eq_b"] if who == GameState.BOT else ["eq_a", "eq_attack"]):
			state.add_card(who, id)
	state.market = ["eq_cash", "eq_output"] if kind == "ordinary" else []
	if kind == "upgrade":
		for _i in 6: state.add_card(GameState.BOT, "eq_a")
	if kind == "buffs":
		for id in ["eq_output", "eq_protect", "eq_fill", "eq_cash"]:
			state.add_card(GameState.BOT, id)
	if kind == "reversed":
		state.players[GameState.BOT]["cards"].reverse()
	if kind == "pawn_win":
		for _i in int(CardDB.game_rules()["win_cash"]) - 10:
			state.add_card(GameState.BOT, CardDB.unit_id(CardDB.RES_CASH))
	if kind == "terminal":
		state.winner = GameState.BOT
		state.win_reason = "probe"
	if kind == "targeting":
		var defender := GameState.PLAYER
		var units: Array = []
		var core_a := 0
		var core_attack := 0
		for card in state.players[defender]["cards"]:
			if card["def_id"] == CardDB.unit_id(CardDB.RES_USER): units.append(card["uid"])
			if card["def_id"] == "eq_a": core_a = card["uid"]
			if card["def_id"] == "eq_attack": core_attack = card["uid"]
		var protect := state.add_card(defender,"eq_protect")
		_check(state.create_combo(defender,[core_a,protect["uid"]]+units.slice(0,2))["ok"],"保护靶fixture编组失败")
		_check(state.create_combo(defender,[core_attack]+units.slice(2,4))["ok"],"攻击靶fixture编组失败")
	return state

func _config(strength: float, overrides: Dictionary = {}) -> BOTSearch:
	var cfg := BOTSearch.from_model("bot", strength * 0.5)
	for key in overrides:
		_check(cfg.apply_override(str(key), overrides[key]), "无效探针覆盖："+str(key))
	return cfg

func _cases() -> Array:
	_install_fixture_cards()
	var rows: Array = []
	for strength in [0.0, 0.45, 1.0]:
		rows.append(_case("ordinary-"+str(strength), _fixture(), _config(strength)))
	rows.append(_case("custom", _fixture(), _config(0.45,
		{"engine_horizon":4.17,"risk_weight":1.23,"upgrade_weight":0.91,"attack_discount":0.63,"protection_bonus":0.27})))
	for budget in [1, 7, 29]:
		rows.append(_case("budget-"+str(budget), _fixture(), _config(1.0,{"node_budget":budget})))
	for trials in [0,1]:
		rows.append(_case("target-trials-"+str(trials),_fixture("targeting"),_config(0.0,{"target_trials":trials})))
	for kind in ["reversed","rich","upgrade","buffs","pawn_win","terminal","targeting"]:
		rows.append(_case(kind, _fixture(kind), _config(0.0)))
	var before := _case("rule-A", _fixture("upgrade"), _config(0.0))
	rows.append(before)
	CardDB.CARDS["eq_a"]["pawn"] = 0
	CardDB.CARDS["eq_b"]["pawn"] = 7
	CardDB.GAME["attack_cost_per_card"] = 3
	CardDB.GAME["buff_mult"]["output_x2"] = 3
	CardDB.CARDS["eq_upgrade"]["upgrade_dup_n"] = 3
	CardDB.UPGRADE["routes"].push_front({"kind":"product","tier":1,"key":"self","per":2,"require_multiple":true})
	rows.append(_case("rules-mutated", _fixture("upgrade"), _config(0.0)))
	# 同路径覆盖再加载 A→B→A，避免仅以路径、card ID 或上次搜索建立永久缓存。
	var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/cards.json"))
	var changed := original.duplicate(true)
	changed["yunketang"]["pawn"] = 17
	changed["_game"]["attack_cost_per_card"] = 2
	var temp := OS.get_user_data_dir().path_join("bot-equivalence-reload-"+str(OS.get_process_id())+".json")
	var retained_picker := Plan.target_picker(_config(1.0))
	for table in [original, changed, original]:
		var file := FileAccess.open(temp, FileAccess.WRITE)
		file.store_string(JSON.stringify(table))
		file.close()
		_check(CardDB.load_from(temp), "探针临时卡表加载失败")
		var s := GameState.new()
		s.set_seed(71)
		s.new_game()
		s.market = []
		s.add_card(GameState.BOT, "yunketang")
		var row := _case("reload-"+str(rows.size()), s, _config(0.0))
		row["retained_picker"] = _targets_using(s,retained_picker)
		rows.append(row)
	DirAccess.remove_absolute(temp)
	CardDB.load_default()
	_install_fixture_cards()
	# 同一输入连续与并发运行，配置和状态分别拥有独立副本。
	var repeat: Array = []
	for _i in 2: repeat.append(_decision(_fixture(), GameState.BOT, _config(0.0)))
	_check(repeat[0] == repeat[1], "连续决策不一致")
	var threads: Array = []
	for _i in 2:
		var thread := Thread.new()
		var s := _fixture()
		var cfg := _config(0.0)
		_check(thread.start(func() -> Dictionary: return _decision(s, GameState.BOT, cfg)) == OK, "探针线程启动失败")
		threads.append(thread)
	var parallel: Array = []
	for thread in threads: parallel.append(thread.wait_to_finish())
	_check(parallel[0] == repeat[0] and parallel[1] == repeat[0], "并发决策污染")
	rows.append({"name":"repeat-concurrent", "serial":repeat, "parallel":parallel})
	return rows

func _case(label: String, state: GameState, cfg: BOTSearch) -> Dictionary:
	var before := _state(state)
	var parameters := cfg.resolved_parameters()
	var row := {"name":label, "parameters":parameters, "features":{}, "score":{}, "capacity":{}, "user_price":{}}
	for who in [GameState.PLAYER,GameState.BOT]:
		row["features"][who] = _exact(Eval.features(state,who,parameters))
		row["score"][who] = _exact(Eval.score(state,who,parameters))
		row["capacity"][who] = _exact(Eval.capacity(state,who,parameters))
		row["user_price"][who] = _exact(Eval.user_price(state,who))
	if state.winner == "":
		var generated: Array = []
		var p := cfg.resolved_parameters()
		p["_work"] = [int(p["node_budget"])]
		for node in Actions.generate(state,GameState.BOT,p):
			generated.append({"intents":node["intents"], "rank":_exact(node["rank"]), "state":_state(node["state"])})
		row["candidates"] = generated
		row["generation_remaining"] = p["_work"][0]
		row["decision"] = _decision(state,GameState.BOT,cfg)
		row["target_picker"] = _targets(state,cfg)
	_check(before == _state(state), "探针改变原状态："+label)
	row["input"] = before
	return row

func _decision(state: GameState, who: String, cfg: BOTSearch) -> Dictionary:
	var selected := Plan.choose_plan(state,who,cfg)
	var diagnostics: Dictionary = selected.get("diagnostics",{}).duplicate(true)
	diagnostics.erase("elapsed_ms")
	var after := Env.copy(state)
	var valid := Env.replay(after,selected["intents"])
	return {"intents":selected["intents"],"diagnostics":_exact(diagnostics),"valid":valid,"after":_state(after)}

func _targets(state: GameState, cfg: BOTSearch) -> Dictionary:
	var picker := Plan.target_picker(cfg)
	return _targets_using(state,picker)

func _targets_using(state: GameState, picker: Callable) -> Dictionary:
	var s := Env.copy(state)
	var pools := {CardDB.RES_CASH:3*int(CardDB.game_rules()["attack_cost_per_card"]),CardDB.RES_USER:2*int(CardDB.game_rules()["attack_cost_per_card"])}
	var choices: Array = []
	for _i in 3:
		var targets := s.affordable_targets(GameState.PLAYER,pools)
		if targets.is_empty() or s.winner != "": break
		var picked: Dictionary = picker.call(s,GameState.BOT,targets,pools)
		choices.append(picked.duplicate(true))
		if picked.is_empty(): break
		_check(bool(s.apply_attack(GameState.BOT,picked,pools).get("ok",false)), "选靶结果不合法")
		s.check_victory()
	return {"choices":choices,"after":_state(s),"pools":pools}

func _state(state: GameState) -> Dictionary:
	return {"players":state.players.duplicate(true),"combos":state.combos.duplicate(true),
		"market":state.market.duplicate(),"round":state.round_num,"first":state.draw_first,
		"winner":state.winner,"win_reason":state.win_reason,"uid":state.peek_uid(),
		"rng":state.rng_snapshot(),"stats":state.stats.duplicate(true)}

## 把浮点原始位模式写入JSON，避免序列化精度隐藏评分/平手差异。
func _exact(value: Variant) -> Variant:
	if value is float: return {"float64":var_to_bytes(value).hex_encode()}
	if value is Dictionary:
		var out := {}
		for key in value: out[key] = _exact(value[key])
		return out
	if value is Array:
		var out: Array = []
		for item in value: out.append(_exact(item))
		return out
	return value

func _games() -> Array:
	var rows: Array = []
	var cfg := _config(1.0)
	for first in [GameState.PLAYER,GameState.BOT]:
		var trace: Array = []
		var hooks := {"intent":func(s: GameState,intent: Dictionary,result: Dictionary) -> void:
			trace.append({"intent":intent.duplicate(true),"result":result.duplicate(true),"state":_state(s)})}
		var final := MatchSimulator.run_rounds(4,1001,
			func(s: GameState) -> void: trace.append({"round_start":_state(s)}),Callable(),
			func(s: GameState) -> void: trace.append({"settled":_state(s)}),
			{GameState.PLAYER:cfg,GameState.BOT:cfg},first,hooks)
		rows.append({"first":first,"trace":trace,"final":_state(final)})
	return rows
