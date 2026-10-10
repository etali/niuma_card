# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	CardDB.load_default()
	check(TutorialCatalog.ui("hub.invitation") == "第一次玩牛马牌？", "首次邀请使用配置中的精确文案")
	check(TutorialCatalog.courses().size() == 8, "完整八门课程")
	check(TutorialCatalog.topics().size() == 6, "默认速查只呈现六条核心规则")
	for course in TutorialCatalog.courses(): _test_course(course)
	_test_early_finish()
	_test_guided_purchase()
	_test_readiness()
	_test_demo_restore()
	_test_attack_restore()
	_test_lost_card()
	_test_wrong_attack()
	_test_manual_economy()
	_test_manual_attack()
	_test_old_events()
	_test_numeric_copy()
	_test_buff_evidence_same_round()
	_test_groups_same_round()
	_test_attack_batches_same_round()
	finish()

func _test_course(course: Dictionary) -> void:
	var session := TutorialSession.new(str(course["id"]))
	var steps: Array = course["steps"]
	for index in steps.size():
		var step := session.current_step()
		check(not str(step.get("goal", "")).is_empty() and not str(step.get("instruction", "")).is_empty(), "%s 目标与操作说明齐全" % step.get("id"))
		check(step.get("advance") in ["operation", "confirm"], "%s 配置明确的推进方式" % step.get("id"))
		var result := session.run_example()
		check(result.get("ok", false), "%s 示例操作全部走真实规则成功：%s" % [step.get("id"), result])
		check(session.step_complete, "%s 可通过真实牌局目标判定（%s）" % [step.get("id"), session.feedback])
		if not result.get("ok", false) or not session.step_complete: return
		var advanced := session.acknowledge()
		check(advanced.get("ok", false), "%s 可明确确认并进入下一步" % step.get("id"))
	check(session.completed, "%s 可以完整通关" % course["title"])

func _test_early_finish() -> void:
	var session := TutorialSession.new("income")
	var before := session.capture_operation()
	session.finish_action()
	check(session.phase == "review" and not session.step_complete, "提前结束真实结算，但不会通过购牌目标")
	check(not session.review_operation(before, "finish_action")["expected"], "购牌步骤的提前结束应撤回这一手")
	session.restore_operation(before)
	check(session.phase == "action" and session.state.round_num == 1, "撤回提前结束后仍停在原回合原步骤")
	check(session.buy(0).get("ok", false) and session.step_complete, "撤回后正确购买仍可推进目标")

func _test_guided_purchase() -> void:
	var session := TutorialSession.new("income")
	var before := session.capture_operation()
	check(session.buy(1).get("ok", false) and not session.step_complete, "买另一张现金业务是合法规则操作，但不是本步指定的云课堂")
	check(not session.review_operation(before, "buy")["expected"], "第一课买错卡应撤回")
	session.restore_operation(before)
	check(session.capture_operation() == before, "买错牌只撤这一手，钱、市场、随机数与步骤原样恢复")
	session.buy(0)
	session.acknowledge()
	session.run_example()
	session.acknowledge()
	session.preview_groups(session._groups_for_specs([{"yunketang": 1, "user": 3}]))
	check(session.step_complete, "指定业务与三张用户满足本步组牌目标")
	var independent := TutorialSession.new("independent")
	var choice := independent.capture_operation()
	independent.buy(independent.state.market.find("baoyue"))
	check(independent.review_operation(choice, "buy")["expected"] and independent.step_complete, "独立经营课允许配置声明的自主业务选择")

func _test_readiness() -> void:
	var session := TutorialSession.new("growth")
	session.run_example()
	session.acknowledge()
	session.run_example()
	check(session.step_complete, "两组配方齐全时就绪")
	session.preview_groups(session._groups_for_specs([]))
	check(not session.step_complete, "就绪后拆散组合会撤销就绪状态")
	var before := StateCodec.state_hash(session.state)
	session.preview_groups([[{"uid": -999, "def_id": "ditui"}]])
	check(StateCodec.state_hash(session.state) == before and not session.step_complete, "伪造卡与预览编组不会污染真实牌局")

func _test_demo_restore() -> void:
	var session := TutorialSession.new("income")
	var before := StateCodec.state_hash(session.state)
	var events_before := session.events.size()
	check(session.demo_action().get("ok", false), "购买演示实际执行真实规则")
	check(session.state.resource_count(GameState.PLAYER, "cash") == 8, "演示购买真实扣款")
	session.end_demo()
	check(StateCodec.state_hash(session.state) == before and session.events.size() == events_before, "结束演示恢复整个局面及事件")
	check(session.seen_demo and not session.step_complete and not session.completed, "看过演示与亲手完成明确分开")
	session.skip()
	check(session.skipped and not session.completed, "跳过不冒充通关")

func _test_attack_restore() -> void:
	var session := TutorialSession.new("attack")
	session.run_example()
	session.acknowledge()
	session.run_example()
	session.acknowledge()
	var before := StateCodec.state_hash(session.state)
	var pools := session.applier.pools_snapshot()
	session.demo_action()
	session.end_demo()
	check(StateCodec.state_hash(session.state) == before and session.applier.pools_snapshot() == pools and session.phase == "attack", "攻击演示完整恢复双方资源、攻击池、锁与阶段")
	session.run_example()
	check(session.step_complete, "恢复攻击演示后玩家仍能真实命中目标")
	session.retry()
	check(session.phase == "action" and session.step_index == 0 and session.applier.pools_snapshot().is_empty(), "重试恢复本课完整起点并清除攻击状态")

func _test_lost_card() -> void:
	var session := TutorialSession.new("upgrade")
	var before := StateCodec.state_hash(session.state)
	session.pawn([int(session._select_cards(GameState.PLAYER, {"yunketang": 1}, {})[0]["uid"])])
	check(session.state.resource_count(GameState.PLAYER, "cash") > 6, "误卖关键牌遵循真实典当")
	session.retry()
	check(StateCodec.state_hash(session.state) == before, "重试恢复资源、随机源、组牌和胜负的完整起点")

func _test_wrong_attack() -> void:
	var session := TutorialSession.new("attack")
	session.run_example()
	session.acknowledge()
	session.run_example()
	session.acknowledge()
	for _i in 3:
		for target in session.applier.affordable_targets(GameState.PLAYER):
			if target.get("kind") == "card":
				session.attack(target)
				break
	check(not session.step_complete, "攻击散牌而非目标业务不能误判打断配方")
	session.finish_attack()
	check(not session.step_complete, "打错后正常结算，目标保持未完成")
	session.retry()
	check(session.state.resource_count(GameState.BOT, "cash") == 15, "失败后可完整重试，无须凭空补攻击点")

# 独立断言使用具体牌与硬编码预期，不读取课程示例计划。
func _manual_group(session: TutorialSession, requested: Array) -> Array:
	var selected: Array = []
	for id in requested:
		for card in session.state.players[GameState.PLAYER]["cards"]:
			if card["def_id"] == id and not selected.has(card):
				selected.append(card)
				break
	return selected

func _test_manual_economy() -> void:
	var income := TutorialSession.new("income")
	income.buy(income.state.market.find("yunketang"))
	check(income.state.resource_count(GameState.PLAYER, "cash") == 8, "独立核对购云课堂：12现金减4，剩8")
	income.finish_action([_manual_group(income, ["yunketang", "user", "user", "user"])])
	check(income.state.resource_count(GameState.PLAYER, "cash") == 12 and income.state.resource_count(GameState.PLAYER, "user") == 8, "独立核对云课堂结算：现金8到12，用户仍8")
	var growth := TutorialSession.new("growth")
	growth.buy(growth.state.market.find("ditui"))
	growth.finish_action([_manual_group(growth, ["yunketang", "user", "user", "user"]), _manual_group(growth, ["ditui", "cash", "cash"])])
	check(growth.state.resource_count(GameState.PLAYER, "cash") == 11 and growth.state.resource_count(GameState.PLAYER, "user") == 10, "独立核对并行经营：12减3购牌减2费用加4收入=11，用户8加2=10")
	var cashout := TutorialSession.new("cashout")
	cashout.finish_action([_manual_group(cashout, ["yunketang", "baoyue", "ditui", "pinshaoshao"])])
	check(cashout.state.resource_count(GameState.PLAYER, "cash") == 70 and cashout.state.winner == "", "独立核对传说生成不增加70现金，也不直接获胜")
	var legend := _manual_group(cashout, ["dujiaoshou"])
	check(not cashout.pawn([int(legend[0]["uid"])]).get("ok", true), "结算查看阶段不能提前典当传说")
	cashout.finish_action()
	cashout.pawn([int(legend[0]["uid"])])
	check(cashout.state.resource_count(GameState.PLAYER, "cash") == 100 and cashout.state.winner == GameState.PLAYER, "下一行动阶段典当真实获得30现金，70到100立即胜利")

func _test_manual_attack() -> void:
	var session := TutorialSession.new("attack")
	var attack_cards := _manual_group(session, ["zuokong", "user", "user", "user", "user", "user", "user"])
	var used := {}
	for card in attack_cards: used[int(card["uid"])] = true
	var income_cards := _manual_group(session, ["yunketang"])
	for card in session.state.players[GameState.PLAYER]["cards"]:
		if card["def_id"] == "user" and not used.has(int(card["uid"])) and income_cards.size() < 4: income_cards.append(card)
	session.finish_action([attack_cards, income_cards])
	check(session.phase == "attack" and int(session.applier.pools(GameState.PLAYER)["cash"]) == 3, "独立核对6用户做空报告真实装出3现金攻击点")
	var target: Dictionary = {}
	for candidate in session.applier.affordable_targets(GameState.PLAYER):
		if candidate.get("leader") == "pinshaoshao": target = candidate; break
	session.attack(target)
	check(session.state.resource_count(GameState.BOT, "cash") == 14 and int(session.applier.pools(GameState.PLAYER)["cash"]) == 2, "命中一张配方现金：对手15到14、攻击点3到2")
	session.finish_attack()
	check(session.state.resource_count(GameState.BOT, "user") == 8 and session.state.resource_count(GameState.PLAYER, "cash") == 15 and session.state.resource_count(GameState.PLAYER, "user") == 10, "对手停产不增用户；我方云课堂加4现金；攻击用户仍全部保留")

func _test_old_events() -> void:
	var session := TutorialSession.new("growth")
	session.buy(session.state.market.find("ditui"))
	session.acknowledge()
	session.finish_action([_manual_group(session, ["yunketang", "user", "user", "user"])])
	session.finish_action()
	var both: Array = [_manual_group(session, ["yunketang", "user", "user", "user"]), _manual_group(session, ["ditui", "cash", "cash"])]
	session.preview_groups(both)
	session.acknowledge()
	session.finish_action([_manual_group(session, ["ditui", "cash", "cash"])])
	check(not session.step_complete, "旧回合现金收入不能替代当前回合双业务同时结算目标")
	session.finish_action()
	session.finish_action([_manual_group(session, ["yunketang", "user", "user", "user"]), _manual_group(session, ["ditui", "cash", "cash"])])
	check(session.step_complete, "以后同一回合同时生产两种资源，可以正常恢复并通过")
	var ahead := TutorialSession.new("growth")
	ahead.buy(ahead.state.market.find("ditui"))
	ahead.acknowledge()
	ahead.finish_action([_manual_group(ahead, ["yunketang", "user", "user", "user"]), _manual_group(ahead, ["ditui", "cash", "cash"])])
	check(ahead.step_complete, "先结算再确认步骤时，已消耗现金不抹掉本轮真实编组证据")
	ahead.acknowledge()
	check(ahead.step_complete, "同一回合提前完成的真实结算能被下一步识别")

func _test_numeric_copy() -> void:
	check(not ".0" in TutorialCatalog.ui("hub.intro"), "整数字段不以100.0显示")
	var session := TutorialSession.new("income")
	check(session.course_data["steps"].size() == 5 and session.current_step()["kind"] == "buy", "第一课五步，直接从购买开始")
	session.buy(0)
	session.acknowledge()
	session.run_example()
	session.acknowledge()
	check("云课堂" in str(session.current_step()["goal"]) and "3" in str(session.current_step()["goal"]), "组牌短目标显示实际卡名与整数配方")

func _test_buff_evidence_same_round() -> void:
	var session := TutorialSession.new("buffs")
	session.step_index = 2
	session._enter_step()
	session.finish_action([_manual_group(session, ["zuokong", "user", "user", "user", "user", "user", "user", "resou"])])
	check(int(session.applier.pools(GameState.PLAYER)["cash"]) == 6, "热搜首次真实装出6点")
	session.finish_attack()
	session.finish_action()
	session.finish_action([_manual_group(session, ["zuokong", "user", "user", "user", "user", "user", "user"])])
	session.attack(session.applier.affordable_targets(GameState.PLAYER)[0])
	check(not session.step_complete, "上轮热搜装弹不能冒充本轮无强化攻击")
	session.finish_attack()
	session.finish_action()
	session.finish_action([_manual_group(session, ["zuokong", "user", "user", "user", "user", "user", "user", "resou"])])
	session.attack(session.applier.affordable_targets(GameState.PLAYER)[0])
	check(session.step_complete, "同轮强化装弹并命中对应资源才通过")

func _test_groups_same_round() -> void:
	var session := TutorialSession.new("growth")
	session.buy(session.state.market.find("ditui"))
	session.acknowledge()
	session.finish_action([_manual_group(session, ["yunketang", "user", "user", "user"])])
	session.finish_action()
	session.finish_action([_manual_group(session, ["ditui", "cash", "cash"])])
	check(not session.step_complete, "两轮各提交一项业务不能冒充同时编两组")
	session.finish_action()
	session.finish_action([_manual_group(session, ["yunketang", "user", "user", "user"]), _manual_group(session, ["ditui", "cash", "cash"])])
	check(session.step_complete, "同轮同时编组，现金消耗后仍保留正确证据")

func _test_attack_batches_same_round() -> void:
	var session := TutorialSession.new("tactics")
	session.step_index = 3
	session._enter_step()
	for round_index in 2:
		session.finish_action([_manual_group(session, ["zuokong", "user", "user", "user", "user", "user", "user"])])
		var batches: Array = []
		for target in session.applier.affordable_targets(GameState.PLAYER):
			if GameState.batch_locks(target) and not batches.has(GameState.target_batch(target)): batches.append(GameState.target_batch(target))
		for target in session.applier.affordable_targets(GameState.PLAYER):
			if GameState.target_batch(target) == batches[round_index]:
				session.attack(target)
				break
		check(not session.step_complete, "第%d轮只打一组，不能与其他轮的组合拼接通过" % (round_index + 1))
		session.finish_attack()
		session.finish_action()
	session.finish_action([_manual_group(session, ["zuokong", "user", "user", "user", "user", "user", "user"])])
	for _i in 3:
		for target in session.applier.affordable_targets(GameState.PLAYER):
			if GameState.batch_locks(target):
				session.attack(target)
				break
	check(session.step_complete, "同轮遵循攻击锁清完一组再攻击另一组可以通过")
