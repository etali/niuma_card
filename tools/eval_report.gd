# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

const Logic = preload("res://tools/balance/logic.gd")
const Scoring = preload("res://tools/balance/scoring.gd")
const Victory = preload("res://tools/balance/victory.gd")
var _cfg: AISearch
var _options: Dictionary
var _progress := ""
var _completed := 0
var _games: Array = []
var _card_ids: Array = []

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("用法：eval_report.gd -- 手动评估请求.json；旧批量参数已移除")
		quit(2)
		return
	var request := _json(args[0])
	AIConfig._source = "res://data/ai.json"
	if request.get("action") == "metadata":
		var strength := float(request.get("strength", 1.0))
		var profile := AISearch.from_strength(strength)
		_write(str(request["output_path"]), {"schema":AISearch.editable_knobs(profile.model),
			"parameters":profile.resolved_parameters(),"model":profile.model,
			"max_rounds":AIConfig.read_section("simulation").get("max_rounds",80)})
		quit(0)
		return
	if request.get("schema") != "manual-balance-request-v1":
		printerr("不是手动评估请求")
		quit(2)
		return
	var cards_path := str(request.get("cards_path", ""))
	var output := str(request.get("output_path", ""))
	_progress = str(request.get("progress_path", ""))
	_options = request.get("options", {})
	var errors := validate_options(_options)
	errors.append_array(Logic.validate(_json(cards_path), _json("res://data/cards.json")))
	if not errors.is_empty():
		_write(output,{"schema":"manual-balance-eval-v1","status":"invalid","errors":errors})
		quit(2)
		return
	CardDB.reset()
	AIConfig._source = "res://data/ai.json"
	if not CardDB.load_from(cards_path):
		quit(2)
		return
	_cfg = AISearch.from_model(str(_options["model"]), float(_options["strength"]))
	if _cfg == null:
		quit(2)
		return
	for key in _options.get("ai_parameters", {}):
		if not _cfg.apply_override(str(key), _options["ai_parameters"][key]):
			_write(output,{"schema":"manual-balance-eval-v1","status":"invalid","errors":["无效AI参数："+str(key)]})
			quit(2)
			return
	for id in CardDB.all_cards():
		if CardDB.get_def(str(id)).get("kind") != CardDB.KIND_UNIT: _card_ids.append(id)
	var started := Time.get_ticks_usec()
	for pair in int(_options["pairs"]):
		for first in [GameState.PLAYER,GameState.AI]:
			var seed_i := int(_options["seed_start"]) + pair
			_games.append(_run_one(seed_i,first))
			_completed += 1
			_progress_update(seed_i,0)
			print("[进度] %d/%d 局" % [_completed,int(_options["pairs"])*2])
	var result := {"schema":"manual-balance-eval-v1","status":"complete",
		"metrics":Scoring.summarize(_games,_card_ids,Victory.categories()),"games":_games,
		"meta":{"options":_options,"cards_sha256":FileAccess.get_sha256(cards_path),
		"ai_sha256":FileAccess.get_sha256("res://data/ai.json"),"ai_parameters":_cfg.resolved_parameters(),
		"metric_version":"manual-eleven-v4","elapsed_seconds":(Time.get_ticks_usec()-started)/1000000.0}}
	if not _write(output,result):
		quit(3)
		return
	quit(0)

static func validate_options(o: Dictionary) -> Array:
	var errors: Array = []
	for key in ["pairs","max_rounds","seed_start"]:
		var v: Variant = o.get(key)
		if not (v is int or v is float) or not is_finite(float(v)) or float(v) != floorf(float(v)) or float(v) < 1:
			errors.append("要求正整数："+key)
	if not errors.is_empty(): return errors
	if int(o["pairs"]) > 500 or int(o["max_rounds"]) > 500 or int(o["seed_start"])+int(o["pairs"]) > 2147483647:
		errors.append("模拟预算越界")
	var strength: Variant = o.get("strength")
	if not (strength is int or strength is float) or not is_finite(float(strength)) or float(strength)<0 or float(strength)>1:
		errors.append("AI强度须在0到1之间")
	if str(o.get("model", "")) != "ai": errors.append("不支持的AI实现")
	if not o.get("ai_parameters", {}) is Dictionary: errors.append("AI参数必须为对象")
	return errors

func _run_one(seed_i: int, first: String) -> Dictionary:
	var g := {"seed":seed_i,"first":first,"winner":"","end_round":null,"observed_rounds":0,"observed_seat_rounds":0,
		"feedback":{},"attacked":{},"used":{},"upgrade_occurred":false,"upgrade_produced":false,"upgraded_uids":{},
		"pawned_seats":[],"combos_before":[],"max_cash":0,"max_users":0,"legend_uids":{},"winning_pawn_legends":[]}
	var before_action := func(s: GameState,_who: String) -> void:
		g["observed_rounds"] = s.round_num
		g["observed_seat_rounds"] += 1
		g["legend_uids"] = Victory.legend_uids(s,_who)
	var on_intent := func(s: GameState,intent: Dictionary,result: Dictionary) -> void:
		_observe_resources(g,s)
		_observe_pawn(g,s,intent,result)
		if intent["op"] == Intent.OP_BUY:
			# 覆盖率口径：买入、生产/攻击编组有效使用、升级材料/产物任一出现即记使用。
			_use(g,str(result.get("def_id","")))
		elif intent["op"] == Intent.OP_PAWN and s.winner == str(intent["seat"]):
			_feedback(g,str(intent["seat"]),s.round_num)
			g["winning_pawn_legends"] = Victory.sold_legends(intent,g["legend_uids"])
	var on_settle := func(event: String,s: GameState,d: Dictionary) -> void:
		_observe_resources(g,s)
		if event == "production": _observe_upgrade_production(g,s,d)
		if event == "attack":
			g["attacked"][str(d["owner"])] = true
			_feedback(g,str(d["owner"]),s.round_num)
			for combo in g["combos_before"]:
				if combo["owner"] == d["owner"] and combo["type"] == "attack":
					for id in combo["cards"]: _use(g,id)
		elif event == "production" and d["result"].get("resolved",false):
			var ev: Dictionary = d["combo"]["eval"]
			if ev.get("type") == "upgrade" or int(ev.get("output_n",0)) > 0:
				_feedback(g,str(d["combo"]["owner"]),s.round_num)
				_use(g,str(ev.get("leader","")))
				for combo in g["combos_before"]:
					if combo["uids"] == d["combo"]["uids"]:
						for id in combo["cards"]: _use(g,str(id))
			if ev.get("type") == "upgrade":
				g["upgrade_occurred"] = true
				_use(g,str(ev.get("output_card","")))
	var hooks := {"before_action":before_action,"intent":on_intent,"settle":on_settle}
	var final := MatchSimulator.run_rounds(int(_options["max_rounds"]),seed_i,
		func(s: GameState) -> void:
			_observe_resources(g,s)
			_progress_update(seed_i,s.round_num),
		func(s: GameState) -> void:
			_begin_settle_observation(g,s)
			g["combos_before"]=[]
			for combo in s.combos:
				var ids: Array=[]
				for uid in combo["uids"]:
					var card:=s.find_card(str(combo["owner"]),int(uid))
					if not card.is_empty(): ids.append(str(card["def_id"]))
				# 保存外部观测，不修改组合或游戏状态。
				g["combos_before"].append({"owner":combo["owner"],"type":combo["eval"].get("type"),"cards":ids,"uids":combo["uids"].duplicate()}),
		Callable(),{GameState.PLAYER:_cfg,GameState.AI:_cfg},first,hooks)
	_observe_resources(g,final)
	var feedback_count := 0
	for who in g["feedback"]: feedback_count += g["feedback"][who].size()
	return {"seed":seed_i,"first":first,"winner":final.winner,
		"end_round":final.round_num if final.winner!="" else null,
		"observed_rounds":g["observed_rounds"],"observed_seat_rounds":g["observed_seat_rounds"],"feedback_rounds":feedback_count,
		"bilateral_attack":g["attacked"].has(GameState.PLAYER) and g["attacked"].has(GameState.AI),
		"used_cards":g["used"].keys(),"upgrade_occurred":g["upgrade_occurred"],
		"upgrade_produced":g["upgrade_produced"],"pawned_seats":g["pawned_seats"].duplicate(),
		"max_cash":g["max_cash"],"max_users":g["max_users"],
		"victory_method":Victory.classify(final,g["winning_pawn_legends"])}

## UID 单调发号；在结算前及每组结算后推进水位，只记录本次成功升级新生的实体。
## 不按卡面类型猜来源：同名的买入/初始卡，以及别的升级产物，不能替它记成功生产。
static func _begin_settle_observation(g: Dictionary,s: GameState) -> void:
	g["settle_next_uid"] = s.peek_uid()
	if not g.has("upgraded_uids"): g["upgraded_uids"] = {}
	if not g.has("upgrade_produced"): g["upgrade_produced"] = false

static func _observe_upgrade_production(g: Dictionary,s: GameState,d: Dictionary) -> void:
	var next_uid := s.peek_uid()
	var previous_uid := int(g.get("settle_next_uid",next_uid))
	g["settle_next_uid"] = next_uid
	if not d.get("result",{}).get("resolved",false): return
	var combo: Dictionary = d.get("combo",{})
	var ev: Dictionary = combo.get("eval",{})
	var owner := str(combo.get("owner",""))
	if ev.get("type") == "upgrade":
		g["upgrade_occurred"] = true
		for uid in range(previous_uid,next_uid):
			var card := s.find_card(owner,uid)
			if not card.is_empty() and str(card["def_id"]) == str(ev.get("output_card","")):
				g["upgraded_uids"][uid] = owner
	elif ev.get("type") == "production" and int(ev.get("output_n",0)) > 0:
		for uid in combo.get("uids",[]):
			if g.get("upgraded_uids",{}).get(int(uid),"") != owner: continue
			var card := s.find_card(owner,int(uid))
			if not card.is_empty() and str(card["def_id"]) == str(ev.get("leader","")):
				g["upgrade_produced"] = true
				break

## landed_intent 的成功典当结果带真实移除的 uids；空动作、拒绝或未移除卡牌不计。
## 与本次是否获胜无关，整局结束后再将典当座位与最终赢家比较。
static func _observe_pawn(g: Dictionary,s: GameState,intent: Dictionary,result: Dictionary) -> void:
	if intent.get("op") != Intent.OP_PAWN or not result.get("ok",false): return
	var owner := str(intent.get("seat",""))
	if owner not in [GameState.PLAYER,GameState.AI] or not result.get("uids") is Array: return
	for uid in result["uids"]:
		if s.find_card(owner,int(uid)).is_empty():
			if not g.has("pawned_seats"): g["pawned_seats"] = []
			if owner not in g["pawned_seats"]: g["pawned_seats"].append(owner)
			return

## 每局取任意一方曾持有的最高数量，包含开局及未结束局；不合计双方资产。
## 调用点只挂真实模拟的现有钩子，不进入 AI 的搜索副本，也不改变局面。
static func _observe_resources(g: Dictionary,s: GameState) -> void:
	for who in [GameState.PLAYER,GameState.AI]:
		g["max_cash"] = maxi(int(g.get("max_cash",0)),s.resource_count(who,CardDB.RES_CASH))
		g["max_users"] = maxi(int(g.get("max_users",0)),s.resource_count(who,CardDB.RES_USER))

func _use(g: Dictionary,id: String) -> void:
	if id in _card_ids: g["used"][id]=true

static func _feedback(g: Dictionary,who: String,round_num: int) -> void:
	if not g["feedback"].has(who): g["feedback"][who]={}
	g["feedback"][who][str(round_num)]=true

func _progress_update(seed_i: int,round_num: int) -> void:
	_write(_progress,{"schema":"manual-progress-v1","completed":_completed,"total":int(_options["pairs"])*2,
		"seed":seed_i,"round":round_num,"metrics":Scoring.summarize(_games,_card_ids,Victory.categories()) if not _games.is_empty() else {}})

static func _json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var value: Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}

static func _write(path: String,value: Dictionary) -> bool:
	if path.is_empty(): return false
	var full:=ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(full.get_base_dir())
	var f:=FileAccess.open(full+".tmp",FileAccess.WRITE)
	if f==null:return false
	f.store_string(JSON.stringify(value,"  ",false)+"\n")
	f.close()
	return DirAccess.rename_absolute(full+".tmp",full)==OK
