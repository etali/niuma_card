# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name Roles
extends RefCounted

## 开局角色（README.md §「2.12 角色」）。数据在 cards.json 的 _roles 段，这里只做查询。
##
## 角色只改三样东西：开局资源、开局多发的卡、两类数值倍率（配方需求 / 生产产出）。
## 倍率不在这里算 —— ComboRules 拿 mods() 的返回值算配方和产出，
## 结算、攻击选靶、卡面墨团、BOT 都问同一处，不各自乘一遍。
##
## 角色属于**座位**，存在 GameState.roles 上：同一张云课堂在 HR 手里要 2 个用户、
## 在牛马手里要 3 个，这个差别跟着牌的主人走，不跟着牌走

## 默认角色。联网与 BOT 固定坐这个角色；它在快照里不占字段（见 StateCodec.snapshot），
## 所以没有角色这回事的旧录像和旧哈希不受影响
const DEFAULT := "niuma"

## 倍率缩放的取整：一律向上取整，结果至少为 1。
## 减一个极小量再取整是为了挡浮点误差：10 × 0.3 = 3.0000000000000004，直接 ceil 会变成 4
const _EPSILON := 0.000001

## 全部角色 id，按配置顺序（界面列表就按这个排）
static func ids() -> Array:
	var out: Array = []
	for id in CardDB.role_rules():
		if not str(id).begins_with("_"):
			out.append(str(id))
	return out

static func exists(id: String) -> bool:
	return not id.begins_with("_") and CardDB.role_rules().get(id) is Dictionary

static func get_def(id: String) -> Dictionary:
	var def: Variant = CardDB.role_rules().get(id)
	return def if def is Dictionary and not id.begins_with("_") else {}

static func role_name(id: String) -> String:
	return str(get_def(id).get("name", id))

## 牌桌读数里跟在公司名后面的短名（「你的公司（HR）」）
static func tag(id: String) -> String:
	return str(get_def(id).get("tag", role_name(id)))

## 开局资源：角色没写就沿用 _game 的同名值（自定义卡表改了 _game.start_cash 时，
## 没有自带开局资源的角色跟着变）
static func start_cash(id: String) -> int:
	return int(get_def(id).get("start_cash", CardDB.game_rules()["start_cash"]))

static func start_user(id: String) -> int:
	return int(get_def(id).get("start_user", CardDB.game_rules()["start_user"]))

static func start_cards(id: String) -> Array:
	var out: Array = []
	for def_id in get_def(id).get("start_cards", []):
		out.append(str(def_id))
	return out

## 交给 ComboRules 的数值修正。没有任何倍率的角色返回空字典 ——
## 空字典就是「按卡面原值算」，ComboRules 不必再判断角色是谁
static func mods(id: String) -> Dictionary:
	var def := get_def(id)
	var out := {}
	for key in ["recipe_mult", "output_mult"]:
		var table: Variant = def.get(key)
		if table is Dictionary and not table.is_empty():
			out[key] = (table as Dictionary).duplicate()
	return out

## 按 mods 里某一张倍率表缩放一个数量。表里没有这种资源 = 不缩放
static func scale(n: int, mods: Dictionary, key: String, res: String) -> int:
	var table: Dictionary = mods.get(key, {})
	if n <= 0 or not table.has(res):
		return n
	return maxi(1, ceili(float(n) * float(table[res]) - _EPSILON))

## 给玩家看的效果说明，一行一条。数值全从字段生成，配置里的 note 只补数值以外的话
static func describe(id: String) -> Array:
	var lines: Array = ["开局 %s %d · %s %d" % [
		CardDB.res_label(CardDB.RES_CASH), start_cash(id),
		CardDB.res_label(CardDB.RES_USER), start_user(id)]]
	for def_id in start_cards(id):
		lines.append("开局多一张「%s」" % CardDB.card_name(def_id))
	var def := get_def(id)
	for res in def.get("recipe_mult", {}):
		lines.append("需要%s的配方，需求 ×%s（向上取整）" % [
			CardDB.card_label(str(res)), _factor(def["recipe_mult"][res])])
	for res in def.get("output_mult", {}):
		var factor: Variant = def["output_mult"][res]
		lines.append("%s产出 ×%s%s" % [CardDB.res_label(str(res)), _factor(factor),
			"" if float(factor) == floorf(float(factor)) else "（向上取整）"])
	if lines.size() == 1 and str(def.get("note", "")) == "":
		lines.append("没有额外效果")
	if str(def.get("note", "")) != "":
		lines.append(str(def["note"]))
	return lines

## 2 写成「2」，0.5 写成「0.5」：配置里的 2 读回来可能是 2.0
static func _factor(value: Variant) -> String:
	var f := float(value)
	return str(int(f)) if f == floorf(f) else str(f)
