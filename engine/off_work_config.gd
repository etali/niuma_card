# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
class_name OffWorkConfig
extends RefCounted

# 每份工作、现金和咖啡都是独立的牌实体。加载配置前先限制一次性分配的规模。
const MAX_CARD_ALLOCATION := 4096
const MAX_CONVEYOR_SLOTS := 64
const MAX_EXACT_INTEGER := 9007199254740991
const LEGACY_DECISION_BUDGET_MS := 12
const MIN_DECISION_BUDGET_RATIO := 0.01
const DEFAULT_DECISION_BUDGET_RATIO := 0.5
const MAX_DECISION_BUDGET_RATIO := 0.9
const BOT_SEARCH_DEFAULTS := {"search_max_depth": 4, "search_root_width": 3, "search_reply_width": 2}
const MAX_BOT_SEARCH_DEPTH := 16
const MAX_BOT_SEARCH_WIDTH := 16

const ConfigData = preload("res://engine/config_data.gd")
const FILES := {
	"cards": ConfigData.OFF_WORK_CARDS,
	"bot": ConfigData.OFF_WORK_BOT,
}

var cards: Dictionary = {}
var roles: Dictionary = {}
var rules: Dictionary = {}
var bot_preferences: Dictionary = {}
## Historical algorithm values are versioned in JSON, separately from editable
## current defaults. An imported document cannot redefine validation ranges.
var bot_algorithm_defaults: Dictionary = {}
var _bot_algorithm_specs: Dictionary = {}
var errors: Array[String] = []
var _load_errors: Array[String] = []

## 实验室可以提供完整候选文档。每局使用独立副本，偏好与策略可在局内调整。
func _init(balance_document: Variant = null, bot_document: Variant = null) -> void:
	var balance: Variant = normalize_balance_document(_read(FILES.cards) if balance_document == null else balance_document)
	var bundled_bot := _read(FILES.bot)
	var bot: Variant = bundled_bot if bot_document == null else bot_document
	cards = _section(balance, "cards", "off_work_cards.json")
	roles = _section(balance, "roles", "off_work_cards.json")
	rules = _section(balance, "rules", "off_work_cards.json")
	if rules.has("bot"):
		_load_errors.append("off_work_cards.json.rules.bot：电脑对手配置应放在 off_work_bot.json.bot")
	rules.bot = _section(bot, "bot", "off_work_bot.json")
	bot_preferences = _section(bot, "preferences", "off_work_bot.json")
	_load_bot_algorithm(bundled_bot)
	# Earlier strategies used these exact constants. Add their effective values
	# to the loaded copy without changing the archived document or budget mode.
	for key in BOT_SEARCH_DEFAULTS:
		if not rules.bot.has(key): rules.bot[key] = BOT_SEARCH_DEFAULTS[key]
	# Old sessions and full experiment documents retain their original fixed budget.
	if not rules.bot.has("decision_budget_ratio") and not rules.bot.has("decision_budget_ms"):
		rules.bot.decision_budget_ms = LEGACY_DECISION_BUDGET_MS
	if rules.bot.has("decision_budget_ms") and bot_preferences.get("knobs") is Array:
		var has_ratio := func(knob): return knob is Dictionary and knob.get("key") == "decision_budget_ratio"
		if not bot_preferences.knobs.any(has_ratio):
			bot_preferences.knobs = bot_preferences.knobs.filter(func(knob):
				return not knob is Dictionary or knob.get("key") != "decision_budget_ms")
			bot_preferences.knobs.append({"key":"decision_budget_ratio", "label":"决策预算占行动间隔的比例",
				"kind":"float", "min":MIN_DECISION_BUDGET_RATIO, "max":MAX_DECISION_BUDGET_RATIO,
				"step":0.01, "group":"决策时限"})
			bot_preferences.help = "选用强度档后，决策时限按行动间隔的比例换算。"
	validate()

func _load_bot_algorithm(document: Dictionary) -> void:
	var compatibility: Variant = document.get("compatibility")
	if not compatibility is Dictionary or not compatibility.get("algorithm_defaults") is Dictionary:
		_load_errors.append("off_work_bot.json.compatibility.algorithm_defaults：必须提供历史算法默认值")
		return
	bot_algorithm_defaults = compatibility.algorithm_defaults.duplicate(true)
	var preferences: Variant = document.get("preferences")
	if not preferences is Dictionary or not preferences.get("knobs") is Array:
		_load_errors.append("off_work_bot.json.preferences.knobs：缺少算法参数规格")
		return
	for knob in preferences.knobs:
		if not knob is Dictionary or not bot_algorithm_defaults.has(knob.get("key")): continue
		var key: String = knob.key
		if _bot_algorithm_specs.has(key) or knob.get("kind") not in ["int", "float"] or \
				not _is_number(knob.get("min")) or not _is_number(knob.get("max")) or \
				float(knob.min) > float(knob.max):
			_load_errors.append("off_work_bot.json.preferences.knobs.%s：算法参数规格无效或重复" % key)
			continue
		_bot_algorithm_specs[key] = knob.duplicate(true)
	for key in bot_algorithm_defaults:
		if not _bot_algorithm_specs.has(key):
			_load_errors.append("off_work_bot.json.preferences.knobs.%s：缺少算法参数规格" % key)
		if not rules.bot.has(key): rules.bot[key] = bot_algorithm_defaults[key]
	# Historical documents did not contain these controls. Always use the
	# installed schema so a supplied label/range cannot weaken validation.
	if bot_preferences.get("knobs") is Array:
		bot_preferences.knobs = bot_preferences.knobs.filter(func(knob):
			return not knob is Dictionary or not bot_algorithm_defaults.has(knob.get("key")))
		for knob in _bot_algorithm_specs.values(): bot_preferences.knobs.append(knob.duplicate(true))

func _validate_bot_algorithm() -> void:
	for key in _bot_algorithm_specs:
		var spec: Dictionary = _bot_algorithm_specs[key]
		for source in [{"data":rules.bot,"path":"bot"}, {"data":bot_algorithm_defaults,"path":"off_work_bot.json.compatibility.algorithm_defaults"}]:
			if _number_field(source.data, key, source.path, float(spec.min), false, spec.kind == "int"):
				if float(source.data[key]) > float(spec.max):
					errors.append("%s.%s：不能超过 %s" % [source.path, key, str(spec.max)])

## Historical fixed policies and new interval-based policies are mutually exclusive.
static func merge_bot_policy(base: Dictionary, overrides: Dictionary) -> Dictionary:
	var merged := base.merged(overrides, true)
	if overrides.has("decision_budget_ratio") and not overrides.has("decision_budget_ms"):
		merged.erase("decision_budget_ms")
	elif overrides.has("decision_budget_ms") and not overrides.has("decision_budget_ratio"):
		merged.erase("decision_budget_ratio")
	return merged

static func decision_budget_ms(policy: Dictionary) -> int:
	if policy.has("decision_budget_ratio"):
		var ms := float(policy.think_seconds) * 1000.0 * float(policy.decision_budget_ratio)
		# Two multiplications can land just below a whole millisecond (2.8s × 70%).
		var rounding_error := minf(0.00000001, absf(ms) * 4.440892098500626e-16)
		return maxi(1, floori(ms + rounding_error))
	return int(policy.get("decision_budget_ms", LEGACY_DECISION_BUDGET_MS))

## 旧实验和导入卡表在读取时迁移。新字段优先，调用者传入的数据不会被修改。
static func normalize_balance_document(document: Variant) -> Variant:
	if not document is Dictionary:
		return document
	var normalized: Dictionary = document.duplicate(true)
	var definitions: Variant = normalized.get("cards")
	if not definitions is Dictionary:
		return normalized
	var rule_sections: Variant = normalized.get("rules")
	if rule_sections is Dictionary and rule_sections.get("simulation") is Dictionary:
		var simulation: Dictionary = rule_sections.simulation
		if definitions.get("work") is Dictionary and simulation.has("work_income"):
			if not definitions.work.has("income"):
				definitions.work.income = simulation.work_income
			simulation.erase("work_income")
	var role_sections: Variant = normalized.get("roles")
	if role_sections is Dictionary:
		for kind in role_sections:
			var role: Variant = role_sections[kind]
			if not role is Dictionary or not definitions.get(kind) is Dictionary:
				continue
			if role.has("refund"):
				if not definitions[kind].has("refund"):
					definitions[kind].refund = role.refund
				role.erase("refund")
	return normalized

## 返回可导出的规范卡表；局内对手参数属于 off_work_bot.json。
func balance_document() -> Dictionary:
	var balance_rules := rules.duplicate(true)
	balance_rules.erase("bot")
	return {"cards": cards.duplicate(true), "roles": roles.duplicate(true), "rules": balance_rules}

func _section(document: Variant, key: String, path: String) -> Dictionary:
	if not document is Dictionary or not document.get(key) is Dictionary:
		_load_errors.append("%s.%s：必须是配置对象" % [path, key])
		return {}
	return document[key].duplicate(true)

func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_load_errors.append("无法读取配置：" + path)
		return {}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		_load_errors.append("配置不是有效对象：" + path)
		return {}
	return parser.data

func validate() -> bool:
	errors = _load_errors.duplicate()
	_validate_bot_algorithm()
	var expected: Dictionary = {"work": "work", "money": "money", "employee": "person", "leader": "person", "grinder": "person", "workaholic": "person", "work_emperor": "person",
		"overtime": "tool", "coffee": "ingredient", "transfer": "tool", "meeting": "tool", "slack": "tool", "outsource": "tool", "strike": "tool"}
	if cards.size() != expected.size():
		errors.append("cards：卡池必须含约定的 14 种牌")
	for kind in expected:
		var card: Dictionary = _object(cards, str(kind), "cards")
		for field in ["name", "description", "art"]:
			if not card.get(field) is String or str(card.get(field, "")).is_empty():
				errors.append("cards.%s.%s：必须是非空文本" % [kind, field])
		if not card.get("category") is String or card.category != expected[kind]:
			errors.append("cards.%s.category：必须为 %s" % [kind, expected[kind]])
		if not card.get("purchasable") is bool:
			errors.append("cards.%s.purchasable：必须是布尔值" % kind)
		elif kind in ["work", "money", "grinder", "workaholic", "work_emperor"] and bool(card.purchasable):
			errors.append("cards.%s.purchasable：该卡种不能直接购买" % kind)
		_number_field(card, "price", "cards." + str(kind), 0.0, expected[kind] == "person", true)
		if kind == "work":
			_number_field(card, "income", "cards.work", 0.0, true, true)
		if expected[kind] == "person" and _number_field(card, "refund", "cards." + str(kind), 0.0, false, true):
			if _is_number(card.get("price")) and float(card.refund) >= float(card.price):
				errors.append("cards.%s.refund：必须低于购入价" % kind)
	for role in ["employee", "leader", "grinder", "workaholic", "work_emperor"]:
		var spec: Dictionary = _object(roles, role, "roles")
		for field in ["can_work", "can_be_meeting_target"]:
			if not spec.get(field) is bool:
				errors.append("roles.%s.%s：必须是布尔值" % [role, field])
		_number_field(spec, "work_seconds", "roles." + role, 0.0, true)
		_number_field(spec, "work_capacity", "roles." + role, 0.0, true, true)
		_number_field(spec, "work_income_multiplier", "roles." + role, 0.0, true, true)
		_number_field(spec, "meeting_multiplier", "roles." + role, 0.0)
		_number_field(spec, "transfer_capacity", "roles." + role, 0.0, true, true)
	if roles.size() != 5:
		errors.append("roles：必须正好定义员工、领导、卷王、肝帝、打工皇帝五类人员")
	for section in ["simulation", "initial", "income", "overtime", "coffee", "transfer", "meeting", "slack", "outsource", "strike", "fire", "conveyor", "bot"]:
		_object(rules, section, "rules")
	# Stop before accessing a malformed object, with a useful path instead of a
	# runtime conversion error. Values are never silently replaced by defaults.
	if not errors.is_empty():
		return false
	_validate_bot_preferences()
	for section in ["meeting", "outsource"]:
		_number_field(rules[section], "recovery_seconds", section, 0.0, true)
	for pair in [["strike", "duration_seconds"], ["coffee", "seconds"], ["outsource", "seconds"], ["transfer", "seconds"], ["meeting", "duration_seconds"], ["slack", "seconds"], ["conveyor", "interval_seconds"], ["bot", "think_seconds"]]:
		_number_field(rules[pair[0]], pair[1], pair[0], 0.0, true)
	for pair in [["simulation", "maximum_events_per_advance"], ["meeting", "base_targets"], ["meeting", "minimum_targets"], ["outsource", "cost_per_work"], ["conveyor", "slots"], ["conveyor", "employee_every"], ["bot", "desired_people"]]:
		_number_field(rules[pair[0]], pair[1], pair[0], 0.0, true, true)
	for pair in [["initial", "money"], ["fire", "minimum_people"], ["bot", "min_reserve"], ["bot", "max_tool_copies"], ["bot", "max_support_people"], ["simulation", "default_seed"]]:
		_number_field(rules[pair[0]], pair[1], pair[0], 0.0, false, true)
	for field in ["production_reserve_people", "transfer_batch_size"]:
		_number_field(rules.bot, field, "bot", 1.0, false, true)
	_number_field(rules.bot, "first_action_seconds", "bot", 0.0)
	for key in BOT_SEARCH_DEFAULTS:
		if _number_field(rules.bot, key, "bot", 1.0, false, true):
			var limit := MAX_BOT_SEARCH_DEPTH if key == "search_max_depth" else MAX_BOT_SEARCH_WIDTH
			if int(rules.bot[key]) > limit:
				errors.append("bot.%s：不能超过 %d" % [key, limit])
	var policy: Dictionary = rules.bot
	if policy.has("decision_budget_ratio") and policy.has("decision_budget_ms"):
		errors.append("bot：decision_budget_ratio 与 decision_budget_ms 只能使用一个")
	elif policy.has("decision_budget_ratio"):
		if _number_field(policy, "decision_budget_ratio", "bot", MIN_DECISION_BUDGET_RATIO):
			if float(policy.decision_budget_ratio) > MAX_DECISION_BUDGET_RATIO:
				errors.append("bot.decision_budget_ratio：预算占比须在 0.01 至 0.90 之间")
			elif _is_number(policy.get("think_seconds")) and float(policy.think_seconds) * 1000000.0 * float(policy.decision_budget_ratio) > MAX_EXACT_INTEGER:
				errors.append("bot.think_seconds：换算的决策时限超出可精确表示的微秒范围")
	elif _number_field(policy, "decision_budget_ms", "bot", 1.0, false, true):
		if int(policy.decision_budget_ms) > 32:
			errors.append("bot.decision_budget_ms：旧版固定预算须在 1 至 32 毫秒之间")
	_number_field(rules.overtime, "speed_multiplier", "overtime", 1.0, true)
	_number_field(rules.slack, "speed_multiplier", "slack", 1.0, true)
	_number_field(rules.slack, "coffee_per_person", "slack", 0.0, true, true)
	_unit_interval(rules.simulation, "epsilon", "simulation", true)
	_unit_interval(rules.bot, "buy_chance", "bot")
	var upgrades: Dictionary = _object(rules.coffee, "upgrades", "coffee")
	var chain := {"employee": "grinder", "grinder": "workaholic", "workaholic": "work_emperor"}
	if upgrades.size() != chain.size():
		errors.append("coffee.upgrades：必须定义三次逐级升级")
	for kind in chain:
		var step: Dictionary = _object(upgrades, kind, "coffee.upgrades")
		if not step.get("to") is String or step.to != chain[kind]:
			errors.append("coffee.upgrades.%s.to：必须逐级升级为 %s" % [kind, chain[kind]])
		_number_field(step, "cost", "coffee.upgrades." + kind, 0.0, true, true)
		if step.has("seconds"):
			_number_field(step, "seconds", "coffee.upgrades." + kind, 0.0, true)
	var copy_limits: Dictionary = _object(rules.bot, "max_card_copies", "bot")
	for kind in copy_limits:
		if not cards.has(kind) or category(str(kind)) not in ["tool", "ingredient"]:
			errors.append("bot.max_card_copies：只能配置工具或材料")
		_number_field(copy_limits, str(kind), "bot.max_card_copies", 0.0, false, true)
	var owner_list: Variant = rules.simulation.get("owners")
	if not owner_list is Array or owner_list.size() != 2 or not _is_number(owner_list[0]) or not _is_number(owner_list[1]) or float(owner_list[0]) != 0.0 or float(owner_list[1]) != 1.0:
		errors.append("simulation.owners：当前为双人对局，必须为 [0, 1]")
	if not _is_number(rules.simulation.get("tie_winner")) or float(rules.simulation.tie_winner) != 2.0:
		errors.append("simulation.tie_winner：平局状态标识必须为 2")
	if not rules.meeting.get("auto_repeat") is bool:
		errors.append("meeting.auto_repeat：必须是布尔值")
	if not rules.bot.get("enabled") is bool:
		errors.append("bot.enabled：必须是布尔值")
	if not ["largest_work_queue", "new_group"].has(rules.transfer.get("destination_policy")):
		errors.append("transfer.destination_policy：必须是 largest_work_queue 或 new_group")
	if not ["oldest_cash_pile", "newest_cash_pile"].has(rules.income.get("destination_policy")):
		errors.append("income.destination_policy：必须是 oldest_cash_pile 或 newest_cash_pile")
	var bot_owner: Variant = rules.bot.get("owner")
	if not _is_number(bot_owner) or (float(bot_owner) != 0.0 and float(bot_owner) != 1.0):
		errors.append("bot.owner：必须是 0 或 1")
	_validate_initial()
	_validate_conveyor()
	for field in ["purchase_priority", "tool_priority"]:
		var priority: Variant = rules.bot.get(field)
		if not priority is Array:
			errors.append("bot.%s：必须是卡种列表" % field)
			continue
		for kind in priority:
			if not kind is String or not cards.has(kind) or category(str(kind)) in ["work", "money"]:
				errors.append("bot.%s：无效卡种 %s" % [field, str(kind)])
			elif field == "purchase_priority" and not can_purchase(str(kind)):
				errors.append("bot.purchase_priority：不能购买 %s" % str(kind))
			elif field == "tool_priority" and category(str(kind)) not in ["tool", "ingredient"]:
				errors.append("bot.tool_priority：只能包含工具或材料")
	if errors.is_empty():
		if integer("conveyor", "slots") > MAX_CONVEYOR_SLOTS:
			errors.append("conveyor.slots：不能超过 %d 格" % MAX_CONVEYOR_SLOTS)
		if integer("slack", "coffee_per_person") > MAX_CARD_ALLOCATION:
			errors.append("slack.coffee_per_person：每人每批不能超过 %d 张咖啡" % MAX_CARD_ALLOCATION)
		for role in roles:
			var spec: Dictionary = roles[role]
			var full_payment := float(cards.work.income) * float(spec.work_income_multiplier) * float(spec.work_capacity)
			if full_payment > MAX_CARD_ALLOCATION or float(cards[role].refund) > MAX_CARD_ALLOCATION:
				errors.append("roles.%s：每人单批完整工作收入与开除返款均不得超过 %d 张现金" % [role, MAX_CARD_ALLOCATION])
			var rate: float = work_rate(str(role), 1)
			if not is_finite(rate) or (can_work(str(role)) and rate <= 0.0) or (not can_work(str(role)) and rate != 0.0):
				errors.append("roles.%s：组合后工作速度必须为有限正数" % role)
		for section in ["transfer", "slack", "coffee"]:
			if not is_finite(1.0 / number(section, "seconds")):
				errors.append("%s.seconds：数值过小，任务速度溢出" % section)
		if not is_finite(slack_rate(2)) or slack_rate(2) <= 0.0:
			errors.append("slack：组合后生产速度必须为有限正数")
	return errors.is_empty()

func _validate_bot_preferences() -> void:
	var path := "off_work_bot.json.preferences"
	for key in ["help", "model_label"]:
		if not bot_preferences.get(key) is String:
			errors.append("%s.%s：必须是文本" % [path, key])
	if _number_field(bot_preferences, "default_strength", path, 0.0, true) and float(bot_preferences.default_strength) >= 1.0:
		errors.append(path + ".default_strength：必须小于 1")
	var presets := _object(bot_preferences, "presets", path)
	for key in presets:
		_unit_interval(presets, str(key), path + ".presets")
	var knobs: Variant = bot_preferences.get("knobs")
	if not knobs is Array:
		errors.append(path + ".knobs：必须是设置项列表")
		return
	for knob in knobs:
		if not knob is Dictionary or not knob.get("key") is String or not knob.get("label") is String:
			errors.append(path + ".knobs：每项必须提供 key 和 label")
			continue
		var field: Variant = rules.get("bot", {}).get(knob.key)
		# A complete strategy has exactly one budget mode; the opposite mode's
		# control can still be present in the settings metadata.
		if not rules.bot.has(knob.key) and knob.key in ["decision_budget_ratio", "decision_budget_ms"]:
			field = DEFAULT_DECISION_BUDGET_RATIO if knob.key == "decision_budget_ratio" else LEGACY_DECISION_BUDGET_MS
		if knob.get("kind") is String and knob.kind == "bool" and field is bool:
			continue
		if knob.get("kind") not in ["int", "float"] or not _is_number(field):
			errors.append("%s.knobs.%s：类型与策略字段不符" % [path, knob.key])
			continue
		if not _is_number(knob.get("min")) or not _is_number(knob.get("max")) or not _is_number(knob.get("step")):
			errors.append("%s.knobs.%s：必须提供数值范围与步长" % [path, knob.key])
		elif float(knob.min) > float(knob.max) or float(knob.step) <= 0:
			errors.append("%s.knobs.%s：无效的范围或步长" % [path, knob.key])

func _validate_initial() -> void:
	var initial_groups: Variant = rules.initial.get("groups")
	if not initial_groups is Array or initial_groups.is_empty():
		errors.append("initial.groups：需要至少一个初始组")
		return
	var work := 0
	var people := 0
	var total := 0.0
	if _is_number(rules.initial.get("money")):
		total = float(rules.initial.money)
	for index in range(initial_groups.size()):
		var group: Variant = initial_groups[index]
		if not group is Dictionary or group.is_empty():
			errors.append("initial.groups[%d]：必须是非空卡种数量对象" % index)
			continue
		for kind in group:
			if not cards.has(kind) or kind == "money":
				errors.append("initial.groups[%d]：未知卡种或金钱应配置在 initial.money" % index)
				continue
			if _number_field(group, str(kind), "initial.groups[%d]" % index, 0.0, false, true):
				total += float(group[kind])
				if kind == "work":
					work += int(group[kind])
				elif is_person(str(kind)):
					people += int(group[kind])
	if total > MAX_CARD_ALLOCATION or initial_groups.size() > MAX_CARD_ALLOCATION:
		errors.append("initial：每方开局的组数与实体牌总数（含现金）不得超过 %d" % MAX_CARD_ALLOCATION)
	if work <= 0 or people <= 0:
		errors.append("initial.groups：每方开局必须拥有工作和至少一名人员")

func _validate_conveyor() -> void:
	var pool: Dictionary = _object(rules.conveyor, "pool", "conveyor")
	var sum_weight := 0.0
	for kind in pool:
		if not cards.has(kind) or not can_purchase(str(kind)):
			errors.append("conveyor.pool：不是可购买卡种 %s" % str(kind))
		elif _number_field(pool, str(kind), "conveyor.pool", 0.0):
			sum_weight += float(pool[kind])
	if sum_weight <= 0.0 or not is_finite(sum_weight):
		errors.append("conveyor.pool：总权重必须为正且有限")
	if not can_purchase("employee"):
		errors.append("conveyor.employee_every：定期补给的员工必须可购买")
	var opening: Variant = rules.conveyor.get("opening")
	if not opening is Array:
		errors.append("conveyor.opening：必须是卡种列表")
		return
	for kind in opening:
		if not kind is String or not cards.has(kind) or not can_purchase(str(kind)):
			errors.append("conveyor.opening：无效商品 %s" % str(kind))

func _object(parent: Dictionary, key: String, path: String) -> Dictionary:
	if not parent.get(key) is Dictionary:
		errors.append("%s.%s：必须是配置对象" % [path, key])
		return {}
	return parent[key]

func _is_number(value_to_check: Variant) -> bool:
	return (typeof(value_to_check) == TYPE_FLOAT or typeof(value_to_check) == TYPE_INT) and is_finite(float(value_to_check))

func _number_field(parent: Dictionary, key: String, path: String, minimum: float, strict: bool = false, integral: bool = false) -> bool:
	var candidate: Variant = parent.get(key)
	if not _is_number(candidate):
		errors.append("%s.%s：必须是有限数值" % [path, key])
		return false
	var number_value: float = float(candidate)
	if integral and number_value > MAX_EXACT_INTEGER:
		errors.append("%s.%s：超过可精确表示的整数范围" % [path, key])
		return false
	if (strict and number_value <= minimum) or (not strict and number_value < minimum) or (integral and number_value != floor(number_value)):
		errors.append("%s.%s：必须%s %s%s" % [path, key, "大于" if strict else "不小于", str(minimum), "，且为整数" if integral else ""])
		return false
	return true

func _unit_interval(parent: Dictionary, key: String, path: String, strict: bool = false) -> void:
	if _number_field(parent, key, path, 0.0, strict) and float(parent[key]) > 1.0:
		errors.append("%s.%s：不得大于 1" % [path, key])

func value(section: String, key: String) -> Variant:
	assert(rules.has(section) and rules[section].has(key), "配置缺失：%s.%s" % [section, key])
	return rules[section][key]

func number(section: String, key: String) -> float:
	return float(value(section, key))

func integer(section: String, key: String) -> int:
	return int(value(section, key))

func category(kind: String) -> String:
	return str(cards.get(kind, {}).get("category", ""))

func is_person(kind: String) -> bool:
	return category(kind) == "person"

func can_purchase(kind: String) -> bool:
	return cards.has(kind) and bool(cards[kind].get("purchasable", false)) and kind not in ["work", "money"] and not is_upgrade_role(kind)

func coffee_upgrade(kind: String) -> Dictionary:
	return rules.get("coffee", {}).get("upgrades", {}).get(kind, {})

func coffee_seconds(kind: String) -> float:
	return float(coffee_upgrade(kind).get("seconds", number("coffee", "seconds")))

func is_upgrade_role(kind: String) -> bool:
	return kind in ["grinder", "workaholic", "work_emperor"]

func can_work(kind: String) -> bool:
	return is_person(kind) and bool(roles.get(kind, {}).get("can_work", false))

func can_be_meeting_target(kind: String) -> bool:
	return is_person(kind) and bool(roles[kind].can_be_meeting_target)

## 同批按组内人员次序分配剩余工作，费用按实际完成份数计算。
func work_batch_size(kind: String, available: int) -> int:
	return mini(available, int(roles[kind].work_capacity))

func income_per_work(kind: String) -> int:
	return int(cards.work.income) * int(roles[kind].work_income_multiplier)

func work_rate(kind: String, overtime_count: int) -> float:
	if not can_work(kind):
		return 0.0
	return pow(number("overtime", "speed_multiplier"), maxi(0, overtime_count)) / float(roles[kind].work_seconds)

func slack_rate(tool_count: int) -> float:
	if tool_count < 1: return 0.0
	return pow(number("slack", "speed_multiplier"), tool_count - 1) / number("slack", "seconds")

func meeting_capacity(kind: String) -> int:
	return maxi(integer("meeting", "minimum_targets"), int(number("meeting", "base_targets") * float(roles[kind].meeting_multiplier)))
