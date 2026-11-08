# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Preferences = preload("res://engine/off_work_bot_preferences.gd")

func _initialize() -> void:
	var config := OffWorkConfig.new()
	if not need(config.errors.is_empty(), "当前下班BOT配置合法"):
		finish()
		return
	var previous := {}
	for index in 101:
		var strength := index / 100.0
		var profile := Preferences.strength_parameters(strength, config.rules.bot, config.bot_preferences)
		check(profile.keys().size() == 2 and profile.has_all(["think_seconds", "decision_budget_ratio"]), "整体强度只映射行动间隔与思考预算")
		if not previous.is_empty():
			check(profile.think_seconds <= previous.think_seconds and profile.decision_budget_ratio >= previous.decision_budget_ratio, "行动机会与预算比例随强度单调增加")
		if not previous.is_empty():
			check(OffWorkConfig.decision_budget_ms(profile) >= OffWorkConfig.decision_budget_ms(previous), "两个锚点之间的真实毫秒预算也单调，不仅比例或五个端点")
		var policy := OffWorkConfig.merge_bot_policy(config.rules.bot, profile)
		var valid := OffWorkConfig.new(config.balance_document(), {"bot":policy, "preferences":config.bot_preferences})
		check(valid.errors.is_empty(), "0–1每个百分位都产生合法可执行策略")
		check(policy.search_max_depth == config.rules.bot.search_max_depth and policy.search_root_width == config.rules.bot.search_root_width and policy.search_reply_width == config.rules.bot.search_reply_width, "完整既有搜索范围不因整体滑钮降级")
		previous = profile
	var middle := Preferences.strength_parameters(.5, config.rules.bot, config.bot_preferences)
	check(middle.think_seconds == config.rules.bot.think_seconds and middle.decision_budget_ratio == config.rules.bot.decision_budget_ratio, "标准档保持原默认策略")
	Preferences.bind(OffWorkState.new(config), config.bot_preferences)
	Preferences.set_override("evaluation_max_seconds", 900.0)
	Preferences.set_override("think_seconds", 20.0)
	Preferences.set_pref_strength(.75)
	check(Preferences.has_overrides() and config.rules.bot.evaluation_max_seconds == 900.0 and config.rules.bot.think_seconds == 3.0, "整体滑钮覆盖派生项并保留独立高级参数")
	Preferences.restore_defaults()
	var archived := {"bot":config.rules.bot.duplicate(true), "preferences":config.bot_preferences.duplicate(true)}
	archived.preferences.erase("strength_curves")
	archived.preferences.erase("model_version")
	var restored := OffWorkConfig.new(config.balance_document(), archived)
	check(restored.errors.is_empty() and restored.bot_preferences.has("strength_curves") and not archived.preferences.has("strength_curves"), "旧文档回填统一曲线且不改写输入")
	for malformed in [[], [[0,1],[0,2]], [[.1,1],[1,2]], [[0,2],[1,1]], [[0,0],[1,1]], [[0,1],[1,INF]]]:
		var invalid := config.bot_preferences.duplicate(true)
		invalid.strength_curves.decision_budget_ratio = malformed
		check(not OffWorkConfig.new(config.balance_document(), {"bot":config.rules.bot,"preferences":invalid}).errors.is_empty(), "非法曲线在载入时拒绝")
	var previous_mapping := config.bot_preferences.duplicate(true)
	previous_mapping.erase("model_version")
	previous_mapping.strength_curves["buy_chance"] = [[0,0.1],[1,0.9]]
	previous_mapping.strength_curves["desired_people"] = [[0,2],[1,10]]
	var legacy_policy: Dictionary = config.rules.bot.duplicate(true)
	legacy_policy["desired_people"] = 10
	legacy_policy["material_batch_limit"] = 16
	var migrated := OffWorkConfig.new(config.balance_document(), {"bot":legacy_policy,"preferences":previous_mapping})
	check(migrated.errors.is_empty() and migrated.bot_preferences.strength_curves == config.bot_preferences.strength_curves,
		"旧启发式模型迁移为统一竞速模型曲线")
	check(not migrated.rules.bot.has("desired_people") and not migrated.rules.bot.has("material_batch_limit"), "旧数量限制不进入新模型")
	check(previous_mapping.strength_curves.has("desired_people") and legacy_policy.desired_people == 10, "迁移不改写历史输入")
	var reversed_budget := config.bot_preferences.duplicate(true)
	reversed_budget.strength_curves.think_seconds = [[0,24],[.25,10],[.5,2.8],[.75,1.4],[1,.5]]
	check(not OffWorkConfig.new(config.balance_document(), {"bot":config.rules.bot,"preferences":reversed_budget}).errors.is_empty(), "仅比例递增但真实毫秒预算倒挂的曲线被拒绝")
	finish()
