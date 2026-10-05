# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

const Cancellation = preload("res://engine/bot_cancellation.gd")

## 保有牌的可行资源分配。每个核心可不用；用户、现金席位与每张Buff只分配一次。
## 现金席位来自已有牌，付款余额则遵守先攻击、再免现金生产、最后付费生产的顺序。
var _work_check: Callable = Callable()
var _cancelled_check: Callable = Callable()
var _rows: Array = []
var _memo := {}
var _production := true
var _attack_weights: Array = []
var _pawn_user := 1.0
var _attack_cost := 1
var _cash_caps: Array[int] = []
var _user_caps: Array[int] = []

static func value(summary: Dictionary, attack_weights: Array, production: bool,
		cache: Dictionary, stats: Dictionary, cancelled_check: Callable = Callable(), work_check: Callable = Callable()) -> float:
	if Cancellation.probe_requested(cancelled_check): return 0.0
	stats["calls"] = int(stats.get("calls",0)) + 1
	var key := var_to_bytes([summary["cash"],summary["users"],StateCodec.canon(summary["inventory"]),
		attack_weights,production])
	if cache.has(key):
		stats["hits"] = int(stats.get("hits",0)) + 1
		return float(cache[key])
	var solver = new()
	solver._cancelled_check = cancelled_check
	solver._work_check = work_check
	solver._production = production
	solver._attack_weights = attack_weights
	solver._pawn_user = float(CardDB.pawn_user())
	solver._attack_cost = maxi(1,int(CardDB.game_rules()["attack_cost_per_card"]))
	for d in summary["cores"]:
		if production or d.get("kind") == CardDB.KIND_ATTACK:
			solver._rows.append(d)
	# 相同核心相邻；新增可选牌不会改变原有核心之间的结算顺序。
	solver._rows.sort_custom(func(a: Dictionary,b: Dictionary):
		var sa := _stage(a); var sb := _stage(b)
		return sa < sb if sa != sb else StateCodec.canon(a) < StateCodec.canon(b))
	solver._cash_caps.resize(solver._rows.size()+1)
	solver._user_caps.resize(solver._rows.size()+1)
	for i in range(solver._rows.size()-1,-1,-1):
		var d: Dictionary = solver._rows[i]
		var user_recipe: bool = d.get("recipe_res") == CardDB.RES_USER
		solver._cash_caps[i] = solver._cash_caps[i+1] + (0 if user_recipe else int(d.get("recipe_n",0)))
		solver._user_caps[i] = solver._user_caps[i+1] + (int(d.get("recipe_n",0)) if user_recipe else 0)
	var mults: Dictionary = summary["mults"]
	var result: float = solver._best(0,int(summary["cash"]),int(summary["cash"]),int(summary["users"]),
		int(mults["output_x2"]),int(mults["attack_x2"]),int(mults["user_fill"]),0,0)
	if Cancellation.probe_requested(cancelled_check): return 0.0
	cache[key] = result
	stats["states"] = int(stats.get("states",0)) + solver._memo.size()
	stats["max_states"] = maxi(int(stats.get("max_states",0)),solver._memo.size())
	return result

static func _stage(d: Dictionary) -> int:
	if d.get("kind") == CardDB.KIND_ATTACK: return 0
	return 1 if d.get("recipe_res") == CardDB.RES_USER else 2

func _best(index: int, slots: int, wallet: int, users: int, outputs: int, attacks: int,
		fills: int, cash_remainder: int, user_remainder: int) -> float:
	if Cancellation.probe_requested(_cancelled_check) or index >= _rows.size(): return 0.0
	# 超出剩余配方总需求的资源等价，避免大现金/用户库存把DP撑大。
	slots = mini(slots,_cash_caps[index])
	wallet = mini(wallet,_cash_caps[index]+1)
	users = mini(users,_user_caps[index])
	var key := str([index,slots,wallet,users,outputs,attacks,fills,cash_remainder,user_remainder])
	if _memo.has(key): return float(_memo[key])
	if _work_check.is_valid() and not _work_check.call(): return 0.0
	var best := _best(index+1,slots,wallet,users,outputs,attacks,fills,cash_remainder,user_remainder)
	var d: Dictionary = _rows[index]
	var user_recipe: bool = d.get("recipe_res") == CardDB.RES_USER
	var attack: bool = d.get("kind") == CardDB.KIND_ATTACK
	var buff_count := attacks if attack else outputs
	var bt := "attack_x2" if attack else "output_x2"
	for fill in range(2 if user_recipe and fills > 0 and int(d.get("recipe_n",0)) > 1 else 1):
		var need := 1 if fill else int(d.get("recipe_n",0))
		var pay := 0 if user_recipe else need
		if need > (users if user_recipe else slots) or (pay > 0 and wallet <= pay): continue
		for buffs in range(buff_count+1):
			if Cancellation.probe_requested(_cancelled_check): return 0.0
			if _work_check.is_valid() and not _work_check.call(): return 0.0
			var multiplier := ComboRules.stacked_multiplier(bt,buffs)
			var income := 0
			var cash_points := cash_remainder
			var user_points := user_remainder
			var gain := -float(pay) if _production else 0.0
			if attack:
				var points := int(d.get("attack_n",0))*multiplier
				if d.get("attack_res") == CardDB.RES_CASH:
					cash_points += points
				else: user_points += points
				gain += float(cash_points/_attack_cost)*float(_attack_weights[0])
				gain += float(user_points/_attack_cost)*float(_attack_weights[1])
				cash_points %= _attack_cost
				user_points %= _attack_cost
			elif d.get("output_res") == CardDB.RES_CASH:
				income = int(d.get("output_n",0))*multiplier
				gain += income
			else:
				# 招新只计真实资产增量；激活其他核心的后续收益交给实际前推。
				# 若用随当前用户减少的缺口溢价，会把典当用户误算成产能增长。
				gain += int(d.get("output_n",0))*multiplier*_pawn_user
			best = maxf(best,gain+_best(index+1,slots-pay,wallet-pay+income,
				users-(need if user_recipe else 0),outputs-(0 if attack else buffs),
				attacks-(buffs if attack else 0),fills-fill,cash_points,user_points))
	if Cancellation.probe_requested(_cancelled_check): return 0.0
	_memo[key] = best
	return best
