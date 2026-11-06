# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name WorkCardDB
extends RefCounted

## 将下班规则转换为共享 CardEntity、Board 与抽屉使用的卡牌字段。
## 收益、升级、购买及时间推进统一由 WorkState 按 WorkConfig 处理。
const KIND_UNIT := "unit"
const KIND_PRODUCT := "product"
const KIND_ATTACK := "attack"
const KIND_BUFF := "buff"
const KIND_LEGEND := "legend"
const KIND_SPECIAL := "special"
const SPECIAL_GRAB := "grab"
const SPECIAL_IDEA := "idea"
const RES_CASH := "money"
const RES_USER := "work"
const DUP_T2 := "dup_t2"

static var CARDS: Dictionary = {}
static var GAME: Dictionary = {}
static var UPGRADE: Dictionary = {}
static var SFX: Dictionary = {}
static var SIM: Dictionary = {}
static var ROLES: Dictionary = {}
static var UNITS: Dictionary = {}
static var loaded_from := ""
static var config: WorkConfig
static var display: Dictionary = {}

static func configure(work_config: WorkConfig) -> void:
	config = work_config
	CARDS.clear()
	display = UIConfig.read_section("card_display")
	for id in config.cards:
		var def: Dictionary = config.cards[id].duplicate(true)
		def.merge(display.get(id, {}), true)
		def["description"] = _description(str(id))
		def["plate_slot"] = WorkUI.section("card_plates").get(id, "plate_t1_money")
		if not def.has("source_art_id"):
			def["art_file"] = "work/%s.svg" % str(def.art)
		def["weight"] = int(config.rules.conveyor.pool.get(id, 0))
		def["tier"] = 1
		if config.category(str(id)) == "person":
			# Personnel still use the original product layout, but only workers
			# advertise a work-to-income recipe in the shared detail/stack UI.
			if bool(config.roles[id].get("can_work", true)):
				def["recipe_res"] = RES_USER
				def["recipe_n"] = int(config.roles[id].work_capacity)
				def["output_res"] = RES_CASH
				def["output_n"] = def.recipe_n * config.income_per_work(str(id))
			else:
				for key in ["recipe_res", "recipe_n", "output_res", "output_n"]:
					def.erase(key)
			def["pawn"] = int(config.cards[id].refund)
		else:
			def["pawn"] = 0
		CARDS[id] = def
	UNITS = {RES_CASH: "money", RES_USER: "work"}
	GAME = {"market_size": int(config.rules.conveyor.slots),
		"res_labels": {RES_CASH: config.cards.money.name, RES_USER: config.cards.work.name}}
	UPGRADE = {"routes": []}
	SFX = UIConfig.read_section("sfx")
	SIM = config.rules.simulation.duplicate(true)
	ROLES = config.roles.duplicate(true)
	loaded_from = WorkConfig.FILES.cards

## 工具说明使用同名规则节的占位符，人员的批次收益和升级材料随卡表计算。
static func _description(id: String) -> String:
	var words := str(config.cards[id].description).format(config.rules.get(id, {}))
	if not config.is_person(id):
		return words
	var role: Dictionary = config.roles[id]
	if config.can_work(id):
		words += " 无加班时每 %s 秒最多处理 %d 份工作，每份赚 %d 钱。" % [
			role.work_seconds, role.work_capacity, config.income_per_work(id)]
	else:
		words += " 不处理普通工作。"
	words += " 每批甩锅 %d 份，主持会议最多拉 %d 人。" % [role.transfer_capacity, config.meeting_capacity(id)]
	if not config.can_be_meeting_target(id):
		words += " 免疫对方会议。"
	var upgrade := config.coffee_upgrade(id)
	if not upgrade.is_empty():
		words += " 用 %d 杯咖啡可升为%s。" % [upgrade.cost, config.cards[upgrade.to].name]
	return words

static func ensure_loaded() -> void:
	if CARDS.is_empty(): configure(WorkConfig.new())

static func load_default() -> bool:
	configure(WorkConfig.new())
	return config.errors.is_empty()

static func reset() -> void:
	CARDS.clear()
	GAME.clear()
	UPGRADE.clear()
	SFX.clear()
	SIM.clear()
	ROLES.clear()
	UNITS.clear()
	config = null
	loaded_from = ""

static func game_rules() -> Dictionary:
	ensure_loaded()
	return GAME

static func sim_rules() -> Dictionary:
	ensure_loaded()
	return SIM

static func role_rules() -> Dictionary:
	ensure_loaded()
	return ROLES

static func upgrade_rules() -> Dictionary:
	ensure_loaded()
	return UPGRADE

static func sfx_rules() -> Dictionary:
	ensure_loaded()
	return SFX

static func all_cards() -> Dictionary:
	ensure_loaded()
	return CARDS

static func get_def(def_id: String) -> Dictionary:
	ensure_loaded()
	return CARDS.get(def_id, {})

static func card_name(def_id: String) -> String:
	return str(get_def(def_id).get("name", def_id))

static func unit_id(res: String) -> String:
	ensure_loaded()
	return str(UNITS.get(res, res))

static func res_label(res: String) -> String:
	ensure_loaded()
	return str(GAME.res_labels.get(res, res))

static func card_label(res: String) -> String:
	return card_name(unit_id(res))

static func protect_key(res: String) -> String:
	return "protect_%s" % res

static func special_type(def_id: String) -> String:
	return str(get_def(def_id).get("special", ""))

static func pawn_value(def_id: String) -> int:
	return int(get_def(def_id).get("pawn", 0))

static func market_pool() -> Array:
	ensure_loaded()
	var pool: Array = []
	for id in CARDS:
		if int(CARDS[id].weight) > 0:
			pool.append({"def_id": id, "weight": int(CARDS[id].weight)})
	return pool

static func total_weight() -> int:
	var weight := 0
	for entry in market_pool(): weight += int(entry.weight)
	return weight

# 共享牌桌查询回合制升级与 Buff 参数，下班的连续时间倍率由 WorkState 提供。
static func buff_mult(_buff_type: String) -> int: return 1
static func max_upgrade_n() -> int: return 0
static func max_upgrade_dup_n() -> int: return 0
static func max_upgrade_per() -> int: return 0
static func dup_key() -> String: return DUP_T2
static func _check_buff_types(_path: String) -> void: pass
