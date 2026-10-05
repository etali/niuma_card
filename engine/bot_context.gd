# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 单次决策内的卡表派生值。调用方在下一次决策重新建立，不跨配置或线程共享。
## 这里只缓存规则查询、材料计数 DP 和库存特征，不保存可变的牌局/卡牌实例。
var work_check: Callable = Callable()

func _charge() -> bool:
	return not work_check.is_valid() or bool(work_check.call())

var _pawn_values: Dictionary = {}
var _upgrade_limit := -1
var _upgrade_targets: Dictionary = {}
var _upgrade_dp: Dictionary = {}
var _ordinary_upgrade_dp: Dictionary = {}
var _legend_targets: Dictionary = {}
var _pooled_values: Dictionary = {}
var _semantic_keys: Dictionary = {}
## 只缓存本次搜索的资源配置，不含UID/编组顺序；同库存的候选共用结果。
var allocation_values: Dictionary = {}
var allocation_stats: Dictionary = {}
var feature_values: Dictionary = {}
var feature_calls := 0
var feature_hits := 0

func pawn_value(id: String) -> int:
	if not _pawn_values.has(id):
		_pawn_values[id] = CardDB.pawn_value(id)
	return int(_pawn_values[id])

func max_upgrade_n() -> int:
	if _upgrade_limit < 0:
		_upgrade_limit = CardDB.max_upgrade_n()
	return _upgrade_limit

func upgrade_target(id: String, n: int) -> String:
	if not _upgrade_targets.has(id):
		_upgrade_targets[id] = {}
	var targets: Dictionary = _upgrade_targets[id]
	if not targets.has(n):
		# 保留 ComboRules 原来的路线和卡表首次匹配顺序。
		targets[n] = ComboRules.upgrade_target(id, n)
	return str(targets[n])

func upgrade_value(id: String, count: int) -> float:
	return _same_name_value(id, count, true)

func _same_name_value(id: String, count: int, include_legends: bool) -> float:
	var cache := _upgrade_dp if include_legends else _ordinary_upgrade_dp
	if not cache.has(id):
		cache[id] = [0.0]
	var dp: Array = cache[id]
	# 只延长缺少的后缀；n/k 次序和每一步浮点计算都与原有递推一致。
	for n in range(dp.size(), count + 1):
		var best: float = dp[n - 1]
		for k in range(2, mini(n, max_upgrade_n()) + 1):
			if not _charge(): return 0.0
			var target := upgrade_target(id, k)
			if target == "" or (not include_legends and CardDB.get_def(target).get("kind") == CardDB.KIND_LEGEND):
				continue
			var gain := maxf(0.0, pawn_value(target) - k * pawn_value(id))
			best = maxf(best, float(dp[n - k]) + gain)
		if work_check.is_valid() and not _charge(): return 0.0
		dp.append(best)
	return float(dp[count])

func legend_upgrade_target(tier: int, count: int) -> String:
	if not _legend_targets.has(tier):
		_legend_targets[tier] = {}
	var targets: Dictionary = _legend_targets[tier]
	if not targets.has(count):
		targets[count] = ComboRules.legend_upgrade_target(tier, count)
	return str(targets[count])

## 同档生产卡共享传说材料池；其他卡仍仅查询自己的同名路线。
## 每个 ID 的材料只能分配给普通升级或传说一次，不能将两条潜力直接相加。
func inventory_upgrade_value(inventory: Dictionary) -> float:
	var tiers := {}
	var value := 0.0
	for id in inventory:
		var d := CardDB.get_def(str(id))
		var tier := int(d.get("tier", 0))
		if d.get("kind") == CardDB.KIND_PRODUCT and tier in [1, 2]:
			if not tiers.has(tier): tiers[tier] = {}
			tiers[tier][id] = int(inventory[id])
		else:
			value += upgrade_value(str(id), int(inventory[id]))
	for tier in tiers:
		value += _pooled_upgrade_value(int(tier), tiers[tier])
	return value

func _pooled_upgrade_value(tier: int, inventory: Dictionary) -> float:
	var key := str(tier) + ":" + StateCodec.canon(inventory)
	if _pooled_values.has(key): return float(_pooled_values[key])
	# 当前普通 T1 升级用 2 张，传说用 4/6/8 张，两类门槛不重叠。
	# 若未来开放可重叠的自定义门槛，需扩展状态以处理同名路线的优先级。
	# allocated[n]：保留 n 张原卡给传说，其余各 ID 做普通升级的最大增值，
	# 同时扣掉这 n 张材料已有的出售底价。按数量分配，不枚举 UID 子集。
	var allocated: Array = [0.0]
	for id in inventory:
		var count := int(inventory[id])
		var next: Array = []
		next.resize(allocated.size() + count)
		next.fill(-INF)
		for used in allocated.size():
			for reserved in range(count + 1):
				if not _charge(): return 0.0
				var value := float(allocated[used]) + _same_name_value(str(id), count - reserved, false) \
					- reserved * pawn_value(str(id))
				next[used + reserved] = maxf(float(next[used + reserved]), value)
		allocated = next
	# 传说材料必须恰好耗尽于合法组，不把不足张数的尾数也折现。
	var payouts: Array = [0.0]
	var best := float(allocated[0])
	for count in range(1, allocated.size()):
		var payout := -INF
		for size in range(2, mini(count, max_upgrade_n()) + 1):
			if not _charge(): return 0.0
			var target := legend_upgrade_target(tier, size)
			if target != "":
				payout = maxf(payout, float(payouts[count - size]) + pawn_value(target))
		payouts.append(payout)
		best = maxf(best, float(allocated[count]) + payout)
	_pooled_values[key] = best
	return best

func semantic_key(id: String) -> String:
	if _semantic_keys.has(id):
		return str(_semantic_keys[id])
	var d := CardDB.get_def(id)
	var data := {}
	for key in ["kind", "tier", "price", "recipe_res", "recipe_n", "output_res", "output_n", "attack_res", "attack_n", "buff_type"]:
		data[key] = d.get(key)
	data["pawn"] = pawn_value(id)
	var upgrades: Array = []
	for n in range(2, max_upgrade_n() + 1):
		var target := upgrade_target(id, n)
		if target != "":
			var td := CardDB.get_def(target)
			upgrades.append([n, td.get("kind"), pawn_value(target), td.get("recipe_res"), td.get("recipe_n"), td.get("output_res"), td.get("output_n")])
	data["upgrades"] = upgrades
	var key := StateCodec.canon(data)
	_semantic_keys[id] = key
	return key
