# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	var config := OffWorkConfig.new()
	config.rules.recruitment.seconds = 7.0
	config.rules.recruitment.cost_per_employee = 3
	OffWorkCardDB.configure(config)
	var boss := OffWorkCardDB.get_def("boss")
	check(not boss.description.contains("{") and boss.description.contains("7") and boss.description.contains("3 钱"), "老板说明引用本卡表招聘时长与费用")
	check(boss.description.contains("免疫罢工") and not boss.has("recipe_res"), "老板标明自身免罢工且不显示工作产出")
	for id in ["boss", "union"]:
		check(OffWorkCardDB.get_def(id).source_art_id == "off_work_" + id, "%s 接入独立主图" % id)
		check(OffWorkIconMotion.enabled(id), "%s 使用连续动作配置" % id)
		check(FileAccess.file_exists("res://assets/art/icon/off_work_%s.png" % id), "%s 正式位图在项目内" % id)
	var recruiting := [{"def_id":"boss"}, {"def_id":"money","amount":3}]
	check(OffWorkComboRules.evaluate(recruiting).valid, "老板与足额聚合现金可招工")
	recruiting[1].amount = 2
	check(not OffWorkComboRules.evaluate(recruiting).valid, "招聘预览拒绝不足额现金")
	check(OffWorkComboRules.evaluate(recruiting, {"off_work_money_amount":3}).valid, "牌桌金额投影用于共享预判")
	recruiting.append_array([{"def_id":"work"}, {"def_id":"employee"}])
	check(OffWorkComboRules.evaluate(recruiting).type == "production", "招聘不抢占现有工作预览")
	var protected := OffWorkComboRules.evaluate([{"def_id":"work_emperor"}, {"def_id":"union"}, {"def_id":"work"}])
	check(protected.output_n == config.income_per_work("employee"), "工会组合预览按员工收入计算")
	check(not OffWorkComboRules.evaluate([{"def_id":"boss"}, {"def_id":"union"}, {"def_id":"work"}]).valid, "工会不让老板获得工作资格")
	var promotion := [{"def_id":"employee"}, {"def_id":"workaholic"}]
	for i in 4: promotion.append({"def_id":"coffee"})
	check(OffWorkComboRules.evaluate(promotion).output_card == "work_emperor", "咖啡组合预览优先最高可升级人员")
	promotion.pop_back()
	check(OffWorkComboRules.evaluate(promotion).output_card == "grinder", "咖啡不足高级配方时预览可升级低阶人员")
	finish()
