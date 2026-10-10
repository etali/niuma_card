# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

func _initialize() -> void:
	CardDB.load_default()
	_test_all_operations()
	_test_purchase_snapshot()
	_test_growth_purchase_choices()
	_test_split()
	_test_recipe()
	_test_surplus_preparation()
	_test_material_first()
	_test_remove_protection()
	_test_misplaced_resources()
	_test_surplus_and_buffs()
	_test_fission_and_upgrades()
	_test_produced_cards()
	_test_results()
	_test_attacks()
	_test_pile_attacks()
	_test_attack_victory_finalization()
	_test_attack_types()
	_test_preparation_and_cleanup()
	_test_previous_business()
	finish()

func _test_all_operations() -> void:
	var steps := 0
	for course in TutorialCatalog.courses():
		var session := TutorialSession.new(str(course["id"]))
		for _index in course["steps"].size():
			var step := session.current_step()
			steps += 1
			for planned in step.get("demo", []):
				var operation: Dictionary = planned.duplicate(true)
				var repeats := 100 if planned["op"] == "attack_all" else 1
				if planned["op"] == "attack_all": operation["op"] = "attack"
				for _repeat in repeats:
					if planned["op"] == "attack_all" and session.step_complete: break
					var before := session.capture_operation()
					var result := session._example_action(operation)
					var action := str(operation["op"])
					if action in ["groups", "auto_product", "split"]: action = "layout"
					if action == "round": action = "finish_action"
					var after := session.capture_operation()
					var reviewed := session.review_operation(before, action)
					check(result.get("ok", false) and reviewed["expected"] and session.capture_operation() == after,
						"%s %s：真实操作被接受，审查本身不修改状态 %s" % [step["id"], action, reviewed])
					if not reviewed["expected"]: return
			check(session.step_complete, "%s：合规前置操作能达成真实目标" % step["id"])
			if not session.step_complete: return
			session.acknowledge()
		check(session.completed, "%s：逐手审查不锁死课程" % course["id"])
	check(steps == 42, "完整八课42步均逐操作通过审查")

func _test_purchase_snapshot() -> void:
	var session := TutorialSession.new("income")
	session.state.stats["checkpoint"] = 17
	var before := session.capture_operation()
	session.buy(session.state.market.find("baoyue"))
	check(session.state.resource_count(GameState.PLAYER, "cash") == 7 and not session.step_complete, "错买连续包月按规则扣5现金，但不通过指定云课堂目标")
	var after := session.capture_operation()
	check(not session.review_operation(before, "buy")["expected"] and session.capture_operation() == after, "审查只报告买错卡，不偷偷恢复")
	var epoch := session.generation
	session.restore_operation(before)
	check(session.capture_operation() == before and session.generation == epoch + 1, "这一手恢复钱、卡UID、RNG、市场、日志、统计、事件及步骤")
	session.buy(0)
	check(session.review_operation(before, "buy")["expected"] and session.state.resource_count(GameState.PLAYER, "cash") == 8, "错手撤回后正确买云课堂花4现金")
	var bought := session.capture_operation()
	session.pawn(_ids(session, "yunketang", 1))
	check(not session.review_operation(bought, "pawn")["expected"], "关键业务被典当要撤回")
	session.restore_operation(bought)
	check(session.capture_operation() == bought and session.step_complete, "误典当只退这一手，保留之前正确购买和目标完成")
	var demo_before := session.capture_operation()
	session.demo_action()
	session.end_demo()
	demo_before["seen_demo"] = true
	check(session.capture_operation() == demo_before, "演示共用同一快照，仅额外保留看过演示标记")
	var premature := TutorialSession.new("income")
	var start := premature.capture_operation()
	premature.finish_action()
	check(not premature.review_operation(start, "finish_action")["expected"], "买牌目标不能提前结束行动")
	premature.restore_operation(start)
	check(premature.capture_operation() == start, "提前结算后整手撤回，不重开整课")

func _at_split() -> TutorialSession:
	var session := TutorialSession.new("income")
	session.buy(0)
	session.acknowledge()
	return session

func _at_recipe() -> TutorialSession:
	var session := _at_split()
	var user := int(_ids(session, "user", 1)[0])
	_move(session, [user])
	session.notify_split(user)
	session.acknowledge()
	return session

func _test_split() -> void:
	var session := _at_split()
	var user := int(_ids(session, "user", 1)[0])
	var before := session.capture_operation()
	_move(session, [user], int(_ids(session, "yunketang", 1)[0]))
	session.notify_split(user)
	check(not session.step_complete and not session.review_operation(before, "layout", {"picked_uids": [user], "split_uid": user})["expected"], "拆用户时放上业务，不能误判完成")
	session.restore_operation(before)
	_move(session, [user], int(_ids(session, "cash", 1)[0]))
	session.notify_split(user)
	check(not session.review_operation(before, "layout", {"picked_uids": [user], "split_uid": user})["expected"], "用户混入现金摞也要退回")
	session.restore_operation(before)
	_move(session, [user])
	session.notify_split(user)
	check(session.step_complete and session.review_operation(before, "layout", {"picked_uids": [user], "split_uid": user})["expected"], "单张用户独立落到空处才通过拆牌")

func _test_recipe() -> void:
	var session := _at_recipe()
	var business := int(_ids(session, "yunketang", 1)[0])
	var users := _ids(session, "user", 5)
	var cash := int(_ids(session, "cash", 1)[0])
	var before := session.capture_operation()
	_move(session, [users[0]], business)
	check(session.review_operation(before, "layout", {"picked_uids": [users[0]]})["expected"] and not session.step_complete, "配方接受1/3真实中间进展")
	var one := session.capture_operation()
	_move(session, [cash], business)
	check(not session.review_operation(one, "layout", {"picked_uids": [cash]})["expected"] and not session.step_complete, "尚缺用户时放入现金不是补料进展，应撤回错料")
	session.restore_operation(one)
	var wrong := session.state.add_card(GameState.PLAYER, "baoyue")
	session._reconcile_groups()
	one = session.capture_operation()
	_move(session, [wrong["uid"]], business)
	check(not session.review_operation(one, "layout", {"picked_uids": [wrong["uid"]]})["expected"], "加入另一张核心使生产组失效，应撤回这一手")
	session.restore_operation(one)
	check(session.capture_operation() == one and _counts(session, business).get("user") == 1, "错误核心撤回不抹掉第一张正确用户")
	_move(session, [users[1]], business)
	check(session.review_operation(one, "layout", {"picked_uids": [users[1]]})["expected"] and not session.step_complete, "继续2/3被接受")
	var two := session.capture_operation()
	_move(session, [users[0]])
	check(not session.review_operation(two, "layout", {"picked_uids": [users[0]]})["expected"], "拿走已经放好的必要用户不算进展")
	session.restore_operation(two)
	_move(session, [users[2], users[3]], business)
	check(session.review_operation(two, "layout", {"picked_uids": [users[2], users[3]]})["expected"] and session.step_complete, "两张一起补成4用户满足3用户配方，合法富余不能撤回")
	var four := session.capture_operation()
	_move(session, [users[3]])
	check(session.review_operation(four, "layout", {"picked_uids": [users[3]]})["expected"] and session.step_complete, "拿走富余第4张仍满足配方，允许整理")
	_move(session, [users[3]], business)
	var full := session.capture_operation()
	_move(session, [cash], business)
	check(session.review_operation(full, "layout", {"picked_uids": [cash]})["expected"] and session.step_complete, "真实配方已成立时仍允许附加现金和富余用户")
	var ready := session.capture_operation()
	session.finish_action(session._groups)
	check(not session.review_operation(ready, "finish_action")["expected"], "还在组牌目标时不能越步骤提前结算")
	session.restore_operation(ready)
	check(session.capture_operation() == ready, "提前结算撤回保留已配好的全部材料")

func _test_surplus_preparation() -> void:
	for picked_count in [1, 7]:
		var session := _at_recipe()
		var users := _ids(session, "user", 8)
		var picked: Array = users.slice(0, 1) if picked_count == 1 else users.slice(1)
		var destination: int = int(users[1] if picked_count == 1 else users[0])
		var before := session.capture_operation()
		_move(session, picked, destination)
		check(session.review_operation(before, "layout", {"picked_uids": picked})["expected"]
			and not session.step_complete and _counts(session, destination) == {"user": 8},
			"拖%d用户与剩余用户合回8张摞属于准备，不冒充完成云课堂配方" % picked_count)
		check(session.review_operation(before, "layout")["expected"],
			"合回8张用户摞在没有视觉picked信息时判定一致：拖%d张" % picked_count)
		before = session.capture_operation()
		_move(session, users, int(_ids(session, "yunketang", 1)[0]))
		check(session.review_operation(before, "layout", {"picked_uids": users})["expected"] and session.step_complete,
			"整理后实际8张用户放上云课堂满足至少3用户配方：拖%d张路线" % picked_count)
		session.acknowledge()
		check(session.current_step()["id"] == "income.settle", "富余用户配方正常进入结算目标")
		before = session.capture_operation()
		var result := session.finish_action(session._groups)
		check(result.get("ok", false) and session.review_operation(before, "finish_action")["expected"]
			and session.step_complete and session.state.resource_count(GameState.PLAYER, "cash") == 12
			and session.state.resource_count(GameState.PLAYER, "user") == 8,
			"8用户真实配方产出4现金，购买后8变12且全部8用户保留")
	for picked_count in [7, 8]:
		var session := _at_recipe()
		for _extra in 2: session.state.add_card(GameState.PLAYER, "user")
		session._reconcile_groups()
		var users := _ids(session, "user", 10)
		_move(session, users)
		var before := session.capture_operation()
		var picked := users.slice(0, picked_count)
		_move(session, picked)
		check(session.review_operation(before, "layout", {"picked_uids": picked})["expected"]
			and session.review_operation(before, "layout")["expected"] and not session.step_complete
			and _counts(session, int(picked[0])) == {"user": picked_count},
			"先从10张用户摞拿出%d张到空处允许备用，不限于示例3张且不提前达标" % picked_count)
	var ready := _at_recipe()
	for _extra in 3: ready.state.add_card(GameState.PLAYER, "user")
	ready._reconcile_groups()
	var all_users := _ids(ready, "user", 11)
	var cloud := int(_ids(ready, "yunketang", 1)[0])
	_move(ready, all_users.slice(0, 3), cloud)
	var ready_before := ready.capture_operation()
	_move(ready, [all_users[3]])
	check(ready.review_operation(ready_before, "layout", {"picked_uids": [all_users[3]]})["expected"]
		and ready.step_complete, "业务已具备3用户时仍可先整理另一摞富余用户")
	ready_before = ready.capture_operation()
	_move(ready, all_users.slice(4), int(all_users[3]))
	check(ready.review_operation(ready_before, "layout", {"picked_uids": all_users.slice(4)})["expected"]
		and ready.review_operation(ready_before, "layout")["expected"] and ready.step_complete
		and _counts(ready, cloud).get("user") == 3,
		"已达标后7+1合回8张纯余料也接受，不损坏原业务且不要求仍缺料")
	ready_before = ready.capture_operation()
	_move(ready, all_users.slice(3), cloud)
	check(ready.review_operation(ready_before, "layout", {"picked_uids": all_users.slice(3)})["expected"]
		and ready.step_complete and _counts(ready, cloud).get("user") == 11,
		"已就绪业务继续添加整理好的8张富余用户，共11张仍有效")
	var wrong := _at_recipe()
	var before := wrong.capture_operation()
	var cash := _ids(wrong, "cash", 7)
	_move(wrong, cash)
	check(not wrong.review_operation(before, "layout", {"picked_uids": cash})["expected"]
		and not wrong.review_operation(before, "layout")["expected"], "所需材料是用户，拆现金仍不是合法准备")
	wrong.restore_operation(before)
	var users := _ids(wrong, "user", 8)
	_move(wrong, users.slice(0, 2), int(cash[0]))
	check(not wrong.review_operation(before, "layout", {"picked_uids": users.slice(0, 2)})["expected"],
		"用户混入现金摞仍应回滚，准备放宽不接受混合资源")
	wrong.restore_operation(before)
	_move(wrong, users.slice(0, 3), int(_ids(wrong, "yunketang", 1)[0]))
	before = wrong.capture_operation()
	_move(wrong, [users[0]])
	check(not wrong.review_operation(before, "layout", {"picked_uids": [users[0]]})["expected"],
		"已经生效的云课堂拆走必要用户仍应回滚，不把破坏业务当准备")

func _test_material_first() -> void:
	var cases := [
		{"step": "buff.protect_user", "core": "yunketang", "res": "user", "n": 3, "extra_n": 4, "buff": "tuisong"},
		{"step": "buff.protect_cash", "core": "ditui", "res": "cash", "n": 2, "extra_n": 4, "buff": "jiangjia"},
		{"step": "buff.output", "core": "yunketang", "res": "user", "n": 3, "extra_n": 8, "buff": "yinqing996"},
		{"step": "buff.attack", "core": "zuokong", "res": "user", "n": 6, "extra_n": 8, "buff": "resou"},
		{"step": "buff.fill", "core": "jiaolv", "res": "user", "n": 1, "extra_n": 2, "buff": "liebian"},
	]
	var orders := [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
	for entry in cases:
		for order in orders:
			var session := _at_buff_step(entry["step"])
			var chunks := [_ids(session, entry["core"], 1), _ids(session, entry["res"], entry["n"]), _ids(session, entry["buff"], 1)]
			var anchor := int(chunks[order[0]][0])
			_move(session, chunks[order[0]])
			for position in range(1, 3):
				var before := session.capture_operation()
				_move(session, chunks[order[position]], anchor)
				check(session.review_operation(before, "layout", {"picked_uids": chunks[order[position]]})["expected"]
					and session.review_operation(before, "layout")["expected"],
					"%s：核心/资源/Buff顺序%s的第%d手被接受，是否带视觉信息不影响判定" % [entry["step"], order, position])
				if position == 1 and order[0] != 0 and order[1] != 0:
					check(not session.step_complete and not ComboRules.evaluate(_material_group(session, anchor))["valid"],
						"%s：无业务核心的资源+Buff只是准备，不冒充实际有效组合" % entry["step"])
			check(ComboRules.evaluate(_material_group(session, anchor))["valid"]
				and _counts(session, anchor).get(entry["res"]) == entry["n"],
				"%s：顺序%s最终得到同一真实有效配方" % [entry["step"], order])
		var surplus := _at_buff_step(entry["step"])
		var users := _ids(surplus, entry["res"], entry["extra_n"])
		var buff := int(_ids(surplus, entry["buff"], 1)[0])
		var before := surplus.capture_operation()
		_move(surplus, users, buff)
		check(surplus.review_operation(before, "layout", {"picked_uids": users})["expected"] and not surplus.step_complete,
			"%s：先把%d张资源与Buff组成富余材料摞，保留真实未达标状态" % [entry["step"], entry["extra_n"]])
		before = surplus.capture_operation()
		var core := _ids(surplus, entry["core"], 1)
		_move(surplus, core, buff)
		check(surplus.review_operation(before, "layout", {"picked_uids": core})["expected"]
			and ComboRules.evaluate(_material_group(surplus, buff))["valid"],
			"%s：核心最后加入富余材料摞也按真实配方放行" % entry["step"])

	var protected := _at_buff_step("buff.protect_user")
	var push := int(_ids(protected, "tuisong", 1)[0])
	_move(protected, _ids(protected, "user", 4), push)
	_move(protected, _ids(protected, "yunketang", 1), push)
	var before := protected.capture_operation()
	protected.finish_action(protected._groups)
	check(protected.review_operation(before, "finish_action")["expected"] and protected.step_complete
		and protected.state.resource_count(GameState.PLAYER, "cash") == 16
		and protected.state.resource_count(GameState.PLAYER, "user") == 3,
		"资源+推送先组再加云课堂：对手只打掉富余1用户，3配方用户受保护且真实赚4现金")
	var mixed_buffs := _at_buff_step("buff.output")
	var extra_buff := mixed_buffs.state.add_card(GameState.PLAYER, "tuisong")
	mixed_buffs._reconcile_groups()
	var mixed_anchor := int(extra_buff["uid"])
	before = mixed_buffs.capture_operation()
	_move(mixed_buffs, _ids(mixed_buffs, "user", 5), mixed_anchor)
	check(mixed_buffs.review_operation(before, "layout")["expected"] and not mixed_buffs.step_complete,
		"额外合法Buff可先与5用户整理，缺少本步996引擎和核心时仍只是准备")
	before = mixed_buffs.capture_operation()
	_move(mixed_buffs, _ids(mixed_buffs, "yinqing996", 2), mixed_anchor)
	check(mixed_buffs.review_operation(before, "layout")["expected"] and not mixed_buffs.step_complete,
		"无核心材料摞可继续加入两张目标Buff，不被误当作不可调整的另一项业务")
	before = mixed_buffs.capture_operation()
	_move(mixed_buffs, _ids(mixed_buffs, "yunketang", 1), mixed_anchor)
	check(mixed_buffs.review_operation(before, "layout")["expected"]
		and ComboRules.evaluate(_material_group(mixed_buffs, mixed_anchor)).get("output_n") == 16,
		"多种Buff与富余资源先组后加入云课堂，真实效果为16现金")
	var rearranged := _at_buff_step("buff.protect_user")
	var material_buff := int(_ids(rearranged, "tuisong", 1)[0])
	var material_users := _ids(rearranged, "user", 3)
	_move(rearranged, material_users, material_buff)
	before = rearranged.capture_operation()
	_move(rearranged, [material_buff])
	check(rearranged.review_operation(before, "layout", {"picked_uids": [material_buff]})["expected"]
		and not rearranged.step_complete and _counts(rearranged, int(material_users[0])) == {"user": 3},
		"用户+推送尚未配上业务时可拆出Buff重新整理，不把准备摞当已经生效的业务")
	before = rearranged.capture_operation()
	_move(rearranged, [material_buff], int(material_users[0]))
	check(rearranged.review_operation(before, "layout")["expected"] and not rearranged.step_complete,
		"拆开的推送可反向叠回用户材料摞，仍只是合法准备")
	before = rearranged.capture_operation()
	_move(rearranged, _ids(rearranged, "yunketang", 1), int(material_users[0]))
	check(rearranged.review_operation(before, "layout")["expected"]
		and ComboRules.evaluate(_material_group(rearranged, int(material_users[0]))).get("protect_user"),
		"准备材料拆开重组后补核心，最终共享规则正常识别用户保护")

	var wrong := _at_buff_step("buff.protect_user")
	var target_buff := int(_ids(wrong, "tuisong", 1)[0])
	before = wrong.capture_operation()
	_move(wrong, _ids(wrong, "cash", 3), target_buff)
	check(not wrong.review_operation(before, "layout")["expected"], "用户保护目标仍拒绝先把现金和Buff组为错料摞")
	wrong.restore_operation(before)
	_move(wrong, _ids(wrong, "user", 3), target_buff)
	before = wrong.capture_operation()
	_move(wrong, _ids(wrong, "cash", 1), target_buff)
	check(not wrong.review_operation(before, "layout")["expected"], "尚无业务核心的用户+Buff准备摞混入错类型现金仍应撤回")
	wrong.restore_operation(before)
	var unrelated := wrong.state.add_card(GameState.PLAYER, "baoyue")
	wrong._reconcile_groups()
	before = wrong.capture_operation()
	_move(wrong, [unrelated["uid"]], target_buff)
	check(not wrong.review_operation(before, "layout")["expected"], "材料先组不允许用不相干业务核心替代目标云课堂")
	wrong.restore_operation(before)
	_move(wrong, _ids(wrong, "yunketang", 1), target_buff)
	before = wrong.capture_operation()
	_move(wrong, _ids(wrong, "yunketang", 1))
	check(not wrong.review_operation(before, "layout")["expected"], "有效组合移走业务核心仍是退步，不能冒充无核心材料准备")

func _at_buff_step(id: String) -> TutorialSession:
	var session := TutorialSession.new("buffs")
	for index in session.course_data["steps"].size():
		if session.course_data["steps"][index]["id"] != id: continue
		session.step_index = index
		session._enter_step()
		return session
	return session

func _material_group(session: TutorialSession, uid: int) -> Array:
	for group in session._groups:
		if group.any(func(card): return int(card["uid"]) == uid): return group
	return []

func _test_remove_protection() -> void:
	var session := _at_buff_step("buff.spare")
	var cloud := int(_ids(session, "yunketang", 1)[0])
	var users := _ids(session, "user", 4)
	var push := int(_ids(session, "tuisong", 1)[0])
	_move(session, users, cloud)
	_move(session, [push], cloud)
	check(session.step_complete and session.current_step()["id"] == "buff.spare",
		"保护范围真实编组达标后仍停在本步，等待玩家确认")
	session.acknowledge()
	check(session.current_step()["id"] == "buff.remove" and not session.step_complete
		and _counts(session, cloud) == {"yunketang": 1, "user": 4, "tuisong": 1},
		"确认保护范围后完整保留云课堂、4用户与推送组合，进入移除Buff目标")
	var before := session.capture_operation()
	_move(session, [push])
	var review := session.review_operation(before, "layout", {"picked_uids": [push], "split_uid": push})
	check(review["expected"] and session.review_operation(before, "layout")["expected"] and session.step_complete,
		"仅把推送单张拖到空处应通过移除保护目标，是否带视觉拆牌信息不影响")
	check(_counts(session, cloud) == {"yunketang": 1, "user": 4}
		and _material_group(session, push).size() == 1
		and _material_group(session, cloud).filter(func(card): return card["def_id"] == "user").all(
			func(card): return not session.preview_protected(int(card["uid"]), "user")),
		"单张移出后四用户完整留在有效业务里，仅保护标记消失")
	# 模型按成员而非数组顺序裁决；模拟正式摞中Buff在用户前方的排列。
	session.restore_operation(before)
	var arranged: Array = []
	for uid in [cloud, push] + users: arranged.append(session.state.find_card(GameState.PLAYER, int(uid)))
	var groups: Array = session._groups.filter(func(group): return not group.any(func(card): return int(card["uid"]) == cloud))
	groups.append(arranged)
	session.preview_groups(groups)
	before = session.capture_operation()
	_move(session, [push])
	check(session.review_operation(before, "layout", {"picked_uids": [push]})["expected"] and session.step_complete,
		"Buff排在用户前方时精确移出同一张也合法，模型不要求它必须位于摞末端")
	session.restore_operation(before)
	_move(session, [push] + users)
	check(session.review_operation(before, "layout", {"picked_uids": [push] + users})["expected"]
		and session.review_operation(before, "layout")["expected"] and not session.step_complete,
		"推送位于中间时允许按真实拖牌规则带走后方全部用户，作为拆保护准备而非完成")
	var trailing := session.capture_operation()
	_move(session, users, cloud)
	check(session.review_operation(trailing, "layout", {"picked_uids": users})["expected"] and session.step_complete
		and _counts(session, cloud) == {"yunketang": 1, "user": 4} and _material_group(session, push).size() == 1,
		"推送连带用户的临时摞可直接把原用户拖回云课堂，不必额外落地一次")
	session.restore_operation(trailing)
	_move(session, users)
	check(session.review_operation(trailing, "layout", {"picked_uids": users})["expected"] and not session.step_complete,
		"无业务核心的推送+用户摞可以继续拆开，不被当作无关旧业务锁住")
	var detached := session.capture_operation()
	_move(session, users, cloud)
	check(session.review_operation(detached, "layout", {"picked_uids": users})["expected"] and session.step_complete
		and _counts(session, cloud) == {"yunketang": 1, "user": 4} and _material_group(session, push).size() == 1
		and session.state.resource_count(GameState.PLAYER, "user") == 6,
		"将原4张用户补回云课堂才达成无保护有效配方，所有原用户和推送均保留")
	# 推送位于整个组头部时，点它只会整摞平移；先从第二张开始拆，再单拆末尾Buff。
	session.restore_operation(before)
	groups = session._groups.filter(func(group): return not group.any(func(card): return int(card["uid"]) == cloud))
	arranged = []
	for uid in [push, cloud] + users: arranged.append(session.state.find_card(GameState.PLAYER, int(uid)))
	groups.append(arranged)
	session.preview_groups(groups)
	var head := session.capture_operation()
	_move(session, [cloud] + users)
	check(session.review_operation(head, "layout", {"picked_uids": [cloud] + users})["expected"]
		and session.step_complete and _material_group(session, push).size() == 1,
		"推送在整组头部时可拖出后方业务与用户，留下单张推送同样完成拆保护")
	# 先取走用户再移出Buff：每次都只拆分原材料，尚未补回业务前不能完成。
	session.restore_operation(before)
	for index in users.size():
		var partial := session.capture_operation()
		_move(session, [users[index]])
		check(session.review_operation(partial, "layout", {"picked_uids": [users[index]]})["expected"]
			and not session.step_complete, "拆保护允许先逐张移出第%d用户，不提前完成" % (index + 1))
	var empty_core := session.capture_operation()
	_move(session, [push])
	check(session.review_operation(empty_core, "layout", {"picked_uids": [push]})["expected"] and not session.step_complete,
		"用户已暂时拆出后可把推送单独移走，空业务仍不能冒充有效配方")
	var to_refill := session.capture_operation()
	_move(session, users, cloud)
	var returned_uids := _material_group(session, cloud).map(func(card): return int(card["uid"]))
	check(session.review_operation(to_refill, "layout", {"picked_uids": users})["expected"] and session.step_complete
		and users.all(func(uid): return returned_uids.has(uid)),
		"拆散再补回后真实原4用户UID全部归回业务，完成状态来自当前配方")
	# 新拆牌准备只允许分离原组，不能借它整理现金或往目标业务混入错料。
	session.restore_operation(before)
	var cash := _ids(session, "cash", 4)
	_move(session, cash)
	check(not session.review_operation(before, "layout", {"picked_uids": cash})["expected"],
		"拆保护目标中无关现金整理不算拆分准备")
	session.restore_operation(before)
	_move(session, [cash[0]], cloud)
	check(not session.review_operation(before, "layout", {"picked_uids": [cash[0]]})["expected"] and not session.step_complete,
		"含推送的目标组额外混入现金仍回滚，不能用拆牌准备规则放行合并错料")
	session.restore_operation(before)
	_move(session, [push] + users, int(cash[0]))
	check(not session.review_operation(before, "layout", {"picked_uids": [push] + users})["expected"] and not session.step_complete,
		"推送连带用户只能拆到空处，混进现金摞仍拒绝")

func _test_misplaced_resources() -> void:
	var session := TutorialSession.new("attack")
	var attack := int(_ids(session, "zuokong", 1)[0])
	var business := int(_ids(session, "yunketang", 1)[0])
	var users := _ids(session, "user", 10)
	var cash := _ids(session, "cash", 10)
	var before := session.capture_operation()
	_move(session, users, attack)
	check(session.review_operation(before, "layout")["expected"] and not session.step_complete, "做空放10用户真实合法，不因示例只需6用户就拒绝")
	before = session.capture_operation()
	_move(session, cash, business)
	check(not session.review_operation(before, "layout")["expected"], "云课堂放整摞现金不能冒充增加用户的配方准备")
	# 保留旧版本能够进入的错配，验证玩家自己修正的每一手，直到最后一张。
	for uid in cash:
		before = session.capture_operation()
		_move(session, [uid])
		check(session.review_operation(before, "layout", {"picked_uids": [uid]})["expected"] and not session.step_complete,
			"从历史错配中拆出现金%s属于修正，不被进度不增加拦截" % uid)
	check(_counts(session, business) == {"yunketang": 1} and _counts(session, attack).get("user") == 10,
		"最后一张错误现金也能拆走，保留另一组全部正确用户")
	before = session.capture_operation()
	_move(session, users.slice(0, 4))
	check(session.review_operation(before, "layout", {"picked_uids": users.slice(0, 4)})["expected"]
		and _counts(session, attack).get("user") == 6, "允许拆出富余4用户，保留做空的6用户有效配方")
	before = session.capture_operation()
	_move(session, users.slice(0, 3), business)
	check(session.review_operation(before, "layout")["expected"] and session.step_complete,
		"修正后把富余用户配到云课堂，同时完成赚钱与攻击")

	# 两个目标不能共享同一组的进度，拿走第二组必要用户仍须撤回。
	var partial := TutorialSession.new("attack")
	partial._example_action({"op": "groups", "groups": [{"zuokong": 1, "user": 6}, {"yunketang": 1, "user": 2}]})
	var cloud := int(_ids(partial, "yunketang", 1)[0])
	var cloud_user := -1
	for group in partial._groups:
		if not group.any(func(card): return int(card["uid"]) == cloud): continue
		for card in group:
			if card["def_id"] == "user": cloud_user = int(card["uid"]); break
	before = partial.capture_operation()
	_move(partial, [cloud_user], int(_ids(partial, "zuokong", 1)[0]))
	check(not partial.review_operation(before, "layout")["expected"], "做空的富余用户不能冒充云课堂被拿走的必要用户")

	var growth := TutorialSession.new("growth")
	growth.buy(0)
	growth.acknowledge()
	var income := int(_ids(growth, "yunketang", 1)[0])
	var recruitment := int(_ids(growth, "ditui", 1)[0])
	_move(growth, _ids(growth, "cash", 9), income)
	_move(growth, _ids(growth, "user", 8), recruitment)
	var swapped := growth.capture_operation()
	for resource in ["cash", "user"]:
		growth.restore_operation(swapped)
		for uid in _ids(growth, resource, 20):
			before = growth.capture_operation()
			_move(growth, [uid])
			check(growth.review_operation(before, "layout", {"picked_uids": [uid]})["expected"],
				"两种配方并行时也能逐张清理%s，另一业务不能抵消错料减少" % resource)
	growth.restore_operation(swapped)
	before = growth.capture_operation()
	_move(growth, _ids(growth, "cash", 2), recruitment)
	check(growth.review_operation(before, "layout")["expected"] and not growth.step_complete,
		"双方错配时允许把现金直接移到需要现金的业务，保留其合法富余用户")
	before = growth.capture_operation()
	_move(growth, _ids(growth, "user", 3), income)
	check(growth.review_operation(before, "layout")["expected"] and growth.step_complete,
		"继续把用户移回云课堂即可完成目标，不要求额外移除已合法组合中的现金")

func _test_surplus_and_buffs() -> void:
	var session := TutorialSession.new("buffs")
	var core := int(_ids(session, "yunketang", 1)[0])
	var engine_buffs := _ids(session, "yinqing996", 2)
	var other_buff := session.state.add_card(GameState.PLAYER, "tuisong")
	session._reconcile_groups()
	var before := session.capture_operation()
	_move(session, _ids(session, "user", 5), core)
	check(session.review_operation(before, "layout")["expected"] and not session.step_complete, "强化目标允许先放5用户，但不能因普通生产合法就跳过指定Buff")
	before = session.capture_operation()
	_move(session, _ids(session, "cash", 1), core)
	check(session.review_operation(before, "layout")["expected"] and not session.step_complete,
		"真实用户配方已成立时附加现金合法，即使强化教学还要求补入Buff")
	var incomplete := session.capture_operation()
	session.finish_action(session._groups)
	check(not session.review_operation(incomplete, "finish_action")["expected"], "缺少指定996引擎时结算依旧撤回")
	session.restore_operation(incomplete)
	_move(session, [engine_buffs[0]], core)
	check(session.review_operation(incomplete, "layout")["expected"], "5用户加第一张996引擎可正常准备结算")
	before = session.capture_operation()
	_move(session, [engine_buffs[1]], core)
	check(session.review_operation(before, "layout")["expected"], "第一步提前加入第二张同类Buff合法")
	before = session.capture_operation()
	_move(session, [other_buff["uid"]], core)
	check(session.review_operation(before, "layout")["expected"], "不同效果保护Buff也能和两张产出Buff合法同组")
	before = session.capture_operation()
	session.finish_action(session._groups)
	check(session.review_operation(before, "finish_action")["expected"] and session.step_complete, "多资源多Buff的真实结算可通过强化教学")
	check(session.state.resource_count(GameState.PLAYER, "cash") == 28 and session.state.resource_count(GameState.PLAYER, "user") == 8, "两张引擎真实使云课堂产16现金，12变28且用户不消耗")
	check(session._resolution_match({"leader": "yunketang", "output_n": 8, "buff_count": {"yinqing996": 1}}), "实际16产出和2Buff满足至少8产出及1Buff的目标")
	var result_state := StateCodec.snapshot(session.state)
	session.acknowledge()
	check(session.current_step()["id"] == "buff.stack" and session.current_step()["kind"] == "read" and session.step_complete, "下一步要求两张Buff已真实完成，转成可点击观察")
	check(session.phase == "review" and StateCodec.snapshot(session.state) == result_state, "提前完成的叠乘观察保持真实16现金结果，不开新轮")
	before = session.capture_operation()
	session.demo_action()
	session.end_demo()
	before["seen_demo"] = true
	check(session.capture_operation() == before and session.current_step()["kind"] == "read", "演示往返完整恢复入步已完成阅读标记")
	session.acknowledge()
	check(session.current_step()["id"] == "buff.attack" and not session.step_complete, "已完成的第二张Buff观察可继续，旧产出不会完成攻击新场景")

	var ordinary := TutorialSession.new("buffs")
	ordinary.run_example()
	ordinary.acknowledge()
	check(ordinary.current_step()["id"] == "buff.stack" and not ordinary.step_complete and ordinary.phase == "action" and ordinary.state.round_num == 2, "上一轮只放1Buff时仍必须新一轮实际叠乘生产，不把旧结果当达标")
	ordinary._example_action({"op": "groups", "groups": [{"yunketang": 1, "user": 3, "yinqing996": 2}]})
	check(not ordinary.step_complete, "新一轮摆上2Buff尚未结算时仍不满足实际产出目标")
	before = ordinary.capture_operation()
	ordinary.finish_action(ordinary._groups)
	check(ordinary.review_operation(before, "finish_action")["expected"] and ordinary.step_complete and ordinary.state.resource_count(GameState.PLAYER, "cash") == 36, "第二轮真实产16完成叠乘：第一轮20现金再加16")

	var growth := TutorialSession.new("growth")
	growth.buy(0)
	growth.acknowledge()
	growth._example_action({"op": "groups", "groups": [{"yunketang": 1, "user": 4}, {"ditui": 1, "cash": 4}]})
	check(growth.step_complete, "两种业务都允许配方以上资源")
	growth.acknowledge()
	before = growth.capture_operation()
	growth.finish_action(growth._groups)
	check(growth.review_operation(before, "finish_action")["expected"] and growth.state.resource_count(GameState.PLAYER, "cash") == 11 and growth.state.resource_count(GameState.PLAYER, "user") == 10, "地推放4现金只真实支付2；购买后9加4减2得11现金，并产2用户")
	check(_counts(growth, int(_ids(growth, "ditui", 1)[0])).get("cash") == 2, "现金配方中的富余2张保留，不被教学抹掉")
	growth.acknowledge()
	check(growth.state.round_num == 2 and growth.step_complete and growth.current_step()["kind"] == "read", "足量现金留到下轮已经满足补料目标，允许观察继续")

func _test_fission_and_upgrades() -> void:
	var session := TutorialSession.new("buffs")
	session.step_index = 3
	session._enter_step()
	var before := session.capture_operation()
	session._example_action({"op": "groups", "groups": [{"jiaolv": 1, "user": 2, "liebian": 2}]})
	check(session.review_operation(before, "layout")["expected"] and session.step_complete, "裂变教学接受2用户与2裂变，仍实际触发未满4人的补满效果")
	before = session.capture_operation()
	var core := int(_ids(session, "jiaolv", 1)[0])
	_move(session, _ids(session, "user", 4), core)
	check(not session.step_complete and not session.review_operation(before, "layout")["expected"], "4用户自身已满配方，不再产生裂变补满，不能冒充裂变教学")
	session.restore_operation(before)
	session.acknowledge()
	check(not session.step_complete, "进入无用户失效目标时，两张用户尚未移走不能误判")
	_move(session, _ids(session, "user", 2))
	check(session.step_complete, "用户移空后即使双裂变也不能独立生产，零用户条件仍严格")

	var upgrade := TutorialSession.new("upgrade")
	upgrade.run_example()
	upgrade.acknowledge()
	var third := upgrade.state.add_card(GameState.PLAYER, "yunketang")
	var higher := upgrade.state.add_card(GameState.PLAYER, "jiaolv")
	var buff := upgrade.state.add_card(GameState.PLAYER, "yinqing996")
	upgrade._reconcile_groups()
	upgrade.run_example()
	var ready := upgrade.capture_operation()
	var leader := int(_ids(upgrade, "yunketang", 1)[0])
	for wrong in [third["uid"], higher["uid"], buff["uid"], _ids(upgrade, "cash", 1)[0]]:
		_move(upgrade, [wrong], leader)
		check(not upgrade.step_complete and not upgrade.review_operation(ready, "layout")["expected"], "升级仍拒绝第三张/混档/Buff/资源等真实非法材料 %s" % wrong)
		upgrade.restore_operation(ready)
	check(upgrade.capture_operation() == ready and upgrade.step_complete, "撤回升级错误材料保持原两张合法合成")

func _test_growth_purchase_choices() -> void:
	# 两条明确选择各走完一课；预期数值独立于示例卡名与适配代码。
	for choice in [["ditui", 3, 2, 2], ["pinshaoshao", 4, 3, 4]]:
		var id: String = choice[0]
		var session := TutorialSession.new("growth")
		var before := session.capture_operation()
		var bought := session.buy(session.state.market.find(id))
		check(bought.get("ok", false) and session.step_complete and session.review_operation(before, "buy")["expected"],
			"扩大生意允许购买能增加用户的业务：" + id)
		check(session.state.resource_count(GameState.PLAYER, "cash") == 12 - choice[1], id + "按真实价格扣款，不被撤回")
		session.acknowledge()
		var hint: String = session.current_step()["hint"]
		check(hint.contains(CardDB.card_name(id)) and hint.replace("\u2060", "").replace(" ", "").contains(str(choice[2]) + "张现金"), id + "后续配方提示跟随所选业务")
		before = session.capture_operation()
		session.preview_groups(session._groups_for_specs([{"yunketang": 1, "user": 3}, {id: 1, "cash": choice[2]}]))
		check(session.step_complete and session.review_operation(before, "layout")["expected"], id + "实际配方通过组牌步骤")
		session.acknowledge()
		before = session.capture_operation()
		check(session.finish_action(session._groups).get("ok", false) and session.step_complete
			and session.review_operation(before, "finish_action")["expected"], id + "所选业务真实结算被接受")
		check(session.state.resource_count(GameState.PLAYER, "cash") == 12 - choice[1] + 4 - choice[2]
			and session.state.resource_count(GameState.PLAYER, "user") == 8 + choice[3], id + "真实消耗现金并产出对应用户数量")
		session.acknowledge()
		check(session.current_step()["id"] == "growth.refill" and session.state.round_num == 2
			and session.current_step()["hint"].contains(CardDB.card_name(id)), id + "下一回合仍提示所选业务补料")
		before = session.capture_operation()
		session.preview_groups(session._groups_for_specs([{id: 1, "cash": choice[2]}], true))
		check(session.step_complete and session.review_operation(before, "layout")["expected"], id + "下一回合按实际现金配方补料被接受")
		session.acknowledge()
		check(session.completed, id + "能够完整完成扩大生意课程")
	var wrong := TutorialSession.new("growth")
	wrong.state.market = ["baoyue"]
	var before := wrong.capture_operation()
	check(wrong.buy(0).get("ok", false) and not wrong.step_complete
		and not wrong.review_operation(before, "buy")["expected"], "扩大生意仍拒绝不增加用户的业务")
	wrong.restore_operation(before)
	check(wrong.capture_operation() == before, "错误业务仍只撤销这一手")

func _test_produced_cards() -> void:
	var session := TutorialSession.new("growth")
	for _i in 2:
		session.run_example()
		session.acknowledge()
	session.finish_action(session._groups)
	var productions: Array = session.events.filter(func(event): return event.get("op") == Intent.OP_PRODUCE)
	check(productions.size() == 2 and productions[0]["produced_cards"].size() == 4 and productions[1]["produced_cards"].size() == 2, "每组事件只记录本次引擎新增实体：云课堂4现金、地推2用户")
	var seen := {}
	for index in productions.size():
		for added in productions[index]["produced_cards"]:
			var card: Dictionary = added["card"]
			check(added["seat"] == GameState.PLAYER and card["def_id"] == ("cash" if index == 0 else "user") and not seen.has(card["uid"]), "产出实体归属、类型、UID精确且不同组不重复")
			seen[card["uid"]] = true
	var record: Dictionary = productions[0]["produced_cards"][0]["card"]
	var real := session.state.find_card(GameState.PLAYER, int(record["uid"]))
	check(record.get("locked") == true and real.get("locked") == false, "事件实体为独立深拷贝，最终解锁不改变当时新增状态")
	session.state.remove_card(GameState.PLAYER, int(record["uid"]))
	check(record["def_id"] == "cash" and record.has("uid"), "后续消耗真实产出牌后，事件仍保留可演出的实体记录")

	var upgrade := TutorialSession.new("upgrade")
	for _i in 3:
		upgrade.run_example()
		if _i < 2: upgrade.acknowledge()
	productions = upgrade.events.filter(func(event): return event.get("op") == Intent.OP_PRODUCE)
	check(productions.size() == 1 and productions[0]["produced_cards"].size() == 1 and productions[0]["produced_cards"][0]["card"]["def_id"] == "jiaolv", "升级事件记录实际新焦虑贩卖机，不把消失材料当产出")

	var attack := TutorialSession.new("attack")
	for _i in 4:
		attack.run_example()
		if _i < 3: attack.acknowledge()
	productions = attack.events.filter(func(event): return event.get("op") == Intent.OP_PRODUCE and event.get("seat") == GameState.BOT)
	check(productions.size() == 1 and productions[0]["produced_cards"].is_empty(), "对手组合被拆散后无实际产出，事件不得按eval虚构资源")

func _test_results() -> void:
	var session := TutorialSession.new("income")
	while session.current_step().get("id") != "income.settle":
		session.run_example()
		session.acknowledge()
	var before := session.capture_operation()
	session.finish_action(session._groups)
	check(session.review_operation(before, "finish_action")["expected"] and session.state.resource_count(GameState.PLAYER, "cash") == 12, "结算步骤真实赚4现金，购买后的8变成12")
	var settled := StateCodec.snapshot(session.state)
	session.acknowledge()
	check(session.current_step()["kind"] == "confirm" and session.phase == "review" and session.state.round_num == 1 and StateCodec.snapshot(session.state) == settled, "收入对白保留刚结算局面，不提前开轮、发牌或刷新随机数")
	var read := session.capture_operation()
	session.finish_action()
	check(not session.review_operation(read, "finish_action")["expected"], "收入对白不能用行动按钮跳过阅读开新轮")
	session.restore_operation(read)
	session.acknowledge()
	check(session.completed and StateCodec.snapshot(session.state) == settled, "确认结果完成课程也保持结算状态")

func _test_attacks() -> void:
	var session := TutorialSession.new("attack")
	for _i in 2:
		session.run_example()
		session.acknowledge()
	var before := session.capture_operation()
	var wrong: Dictionary = {}
	var right: Dictionary = {}
	for target in session.applier.affordable_targets(GameState.PLAYER):
		if target.get("kind") == "card": wrong = target
		if target.get("leader") == "pinshaoshao": right = target
	session.attack(wrong)
	check(not session.review_operation(before, "attack")["expected"], "攻击散牌合法但未拆目标配方，应撤回")
	session.restore_operation(before)
	check(session.capture_operation() == before and int(session.applier.pools(GameState.PLAYER)["cash"]) == 3, "错误靶撤回恢复双方资源、攻击点、锁与事件")
	session.attack(right)
	check(session.review_operation(before, "attack")["expected"] and session.state.resource_count(GameState.BOT, "cash") == 14, "正确攻击只移除1张配方现金")
	var locked := session.capture_operation()
	session.finish_attack()
	check(not session.review_operation(locked, "finish_attack")["expected"], "未切到结束攻击目标时不能提前结束")
	session.restore_operation(locked)
	check(session.capture_operation() == locked and GameState.attack_lock(session.applier.pools(GameState.PLAYER)) != "", "错误结束恢复已成功命中后的攻击锁和剩余点数")
	session.acknowledge()
	var finish_before := session.capture_operation()
	session.finish_attack()
	check(session.review_operation(finish_before, "finish_attack")["expected"] and session.step_complete, "到结束攻击目标再结束可以验证对手停产")

func _test_attack_types() -> void:
	var session := TutorialSession.new("tactics")
	session.step_index = 2
	session._enter_step()
	session._example_action({"op": "groups", "groups": [{"zuokong": 1, "user": 6}, {"chaping": 1, "user": 6}]})
	session.finish_action(session._groups)
	var before := session.capture_operation()
	session._example_action({"op": "attack", "res": "cash"})
	check(session.review_operation(before, "attack")["expected"] and not session.step_complete, "两种攻击目标可先完成现金这一半")
	var half := session.capture_operation()
	session._example_action({"op": "attack", "res": "cash"})
	check(not session.review_operation(half, "attack")["expected"], "重复现金攻击不能冒充用户攻击")
	session.restore_operation(half)
	session._example_action({"op": "attack", "res": "user"})
	check(session.review_operation(half, "attack")["expected"] and session.step_complete, "保留一半进展后命中用户完成两种攻击")

func _test_pile_attacks() -> void:
	var session := TutorialSession.new("attack")
	for _i in 2:
		session.run_example()
		session.acknowledge()
	var before := session.capture_operation()
	var target: Dictionary = session.applier.affordable_targets(GameState.PLAYER).filter(
		func(candidate): return candidate.get("leader") == "pinshaoshao")[0]
	var detail := _apply_pile(session, target)
	var hits := session._events_of(session.events.slice(before["events"].size()), Intent.OP_ATTACK)
	check(hits.size() == 3 and session.state.resource_count(GameState.BOT, "cash") == 12
		and int(session.applier.pools(GameState.PLAYER)["cash"]) == 0,
		"一次点拼少少整摞真实消耗3攻击点、移除3现金")
	var after := session.capture_operation()
	check(session.review_operation(before, "attack", detail)["expected"] and session.step_complete
		and session.capture_operation() == after, "同次命中指定业务摞的多条真实意图被接受，审查不改变结果")
	check(not session.review_operation(before, "attack", {"target": target, "pile_uids": target["uids"]})["expected"],
		"不能把未选中摞里的后续命中混入同一手")
	check(not session.review_operation(before, "attack", {"target": hits[1]["target"], "pile_uids": detail["pile_uids"]})["expected"],
		"第一击必须匹配实际点击选中的目标")
	session.restore_operation(before)
	check(session.capture_operation() == before and session.state.resource_count(GameState.BOT, "cash") == 15,
		"整摞事务撤回仍恢复全部资源、攻击点、锁、目标与事件")
	var loose: Dictionary = session.applier.affordable_targets(GameState.PLAYER).filter(
		func(candidate): return candidate.get("kind") == "card")[0]
	var wrong_detail := _apply_pile(session, loose)
	check(not session.review_operation(before, "attack", wrong_detail)["expected"],
		"同摞多击仍逐击受指定业务目标限制，不能放行无关散现金")

	var surplus := TutorialSession.new("attack")
	# 真实引擎重新编好五现金目标（配方只需三张），再用两张攻击Buff装弹。
	surplus.applier.apply(Intent.finalize())
	surplus._scenario["bot_groups"] = [{"pinshaoshao": 1, "cash": 5}]
	surplus._commit_bot_groups()
	for _i in 2: surplus.state.add_card(GameState.PLAYER, "resou")
	surplus._example_action({"op": "groups", "groups": [
		{"zuokong": 1, "user": 6, "resou": 2}, {"yunketang": 1, "user": 3}]})
	surplus.acknowledge()
	surplus.finish_action(surplus._groups)
	surplus.acknowledge()
	var spare_before := surplus.capture_operation()
	var spare_target: Dictionary = surplus.applier.affordable_targets(GameState.PLAYER).filter(
		func(candidate): return candidate.get("leader") == "pinshaoshao")[0]
	var spare_detail := _apply_pile(surplus, spare_target)
	check(surplus._events_of(surplus.events.slice(spare_before["events"].size()), Intent.OP_ATTACK).size() == 5
		and int(surplus.applier.pools(GameState.PLAYER)["cash"]) == 7
		and surplus.state.resource_count(GameState.BOT, "cash") == 10,
		"两个Buff真实提供12攻击点，同手可打掉三张配方现金与两张富余现金，余7点")
	check(surplus.review_operation(spare_before, "attack", spare_detail)["expected"] and surplus.step_complete,
		"首击已拆配方仍允许同摞后续合法余量，不因示例只攻击一次而回滚整手")

	var locked := TutorialSession.new("tactics")
	locked.step_index = 3
	locked._enter_step()
	locked._example_action({"op": "groups", "groups": [{"zuokong": 1, "user": 6}]})
	locked.finish_action(locked._groups)
	var start := locked.capture_operation()
	var first: Dictionary = locked.applier.affordable_targets(GameState.PLAYER).filter(
		func(candidate): return GameState.batch_locks(candidate))[0]
	var first_detail := _apply_pile(locked, first)
	check(locked.review_operation(start, "attack", first_detail)["expected"] and not locked.step_complete,
		"锁定教学允许一手打完整个第一组合，保留第二组合目标")
	var half := locked.capture_operation()
	var second: Dictionary = locked.applier.affordable_targets(GameState.PLAYER).filter(
		func(candidate): return GameState.batch_locks(candidate))[0]
	var second_detail := _apply_pile(locked, second)
	check(locked.review_operation(half, "attack", second_detail)["expected"] and locked.step_complete,
		"第一摞清完后另一次点击第二摞合法，并完成两批目标")
	var combined := first_detail.duplicate(true)
	combined["pile_uids"].append_array(second_detail["pile_uids"])
	check(not locked.review_operation(start, "attack", combined)["expected"],
		"即使两摞都符合攻击计划，也不能伪装成同一次选摞的攻击")

func _apply_pile(session: TutorialSession, selected: Dictionary) -> Dictionary:
	var batch := GameState.target_batch(selected)
	var pile_uids: Array = []
	for target in session.state.attack_targets(GameState.BOT):
		if GameState.target_batch(target) == batch: pile_uids.append_array(target["uids"])
	var target: Dictionary = selected
	for _hit in 100:
		if target.is_empty(): break
		if not session.attack(target).get("ok", false) or session.phase != "attack": break
		var choices := session.applier.affordable_targets(GameState.PLAYER).filter(
			func(candidate): return GameState.target_batch(candidate) == batch)
		target = {} if choices.is_empty() else choices[0]
	return {"target": selected, "pile_uids": pile_uids}

func _test_attack_victory_finalization() -> void:
	var session := TutorialSession.new("attack")
	session.step_index = 4
	session._enter_step()
	session._example_action({"op": "groups", "groups": [{"zuokong": 1, "user": 6}]})
	session.finish_action(session._groups)
	var before := session.capture_operation()
	var target: Dictionary = session.applier.affordable_targets(GameState.PLAYER)[0]
	session.attack(target)
	check(session.state.winner == GameState.PLAYER and session.phase == "over"
		and session.events.slice(before["events"].size()).filter(func(event): return event.get("op") == Intent.OP_FINALIZE).size() == 1,
		"教程清零获胜与正式流程一致，决胜攻击后通过共享裁决完成且仅完成一次FINALIZE")
	check(session.state.combos.is_empty()
		and session.state.players[GameState.PLAYER]["cards"].all(func(card): return not card.get("locked", false))
		and session.state.players[GameState.BOT]["cards"].all(func(card): return not card.get("locked", false)),
		"攻击胜利收尾清空双方组合并解锁剩余实体")
	check(session.review_operation(before, "attack", {"target": target, "pile_uids": target["uids"]})["expected"]
		and session.step_complete, "共享收尾不会丢失实际攻击事件或使胜利学习目标无法通过")
	session.restore_operation(before)
	check(session.capture_operation() == before and not session.state.combos.is_empty(),
		"决胜攻击也能按同一事务完整还原，恢复胜负、组合、锁及事件")

func _test_preparation_and_cleanup() -> void:
	var session := TutorialSession.new("tactics")
	session.step_index = 5
	session._enter_step()
	var before := session.capture_operation()
	var extra := _ids(session, "jiaolv", 1)
	_move(session, extra)
	check(session.review_operation(before, "layout", {"picked_uids": extra})["expected"] and not session.step_complete, "污染升级组可以先移走错误业务，接受修复中间步骤")
	var partial := session.capture_operation()
	var user := _ids(session, "user", 1)
	_move(session, user)
	check(session.review_operation(partial, "layout", {"picked_uids": user})["expected"] and session.step_complete, "再移走用户留下真正的两张云课堂升级")
	var recipe := _at_recipe()
	var users := _ids(recipe, "user", 8)
	var split_before := recipe.capture_operation()
	_move(recipe, [users[1], users[2]])
	check(recipe.review_operation(split_before, "layout", {"picked_uids": [users[1], users[2]]})["expected"], "组牌时先拿出两张尚缺的正确用户属于合规准备")
	var prepared := recipe.capture_operation()
	var cash := _ids(recipe, "cash", 1)
	_move(recipe, cash)
	check(not recipe.review_operation(prepared, "layout", {"picked_uids": cash})["expected"], "当前不需要现金，拆现金不能冒充准备")
	var independent := TutorialSession.new("independent")
	for _i in 3:
		independent.run_example()
		independent.acknowledge()
	check(independent.step_complete and independent.current_step()["kind"] == "read" and independent.state.round_num == 2, "用户配方保留时最后一步转为可点击观察，不要求无意义操作")

func _test_previous_business() -> void:
	var session := TutorialSession.new("growth")
	for _i in 3:
		session.run_example()
		session.acknowledge()
	check(session.current_step()["id"] == "growth.refill" and session.state.round_num == 2, "补现金目标进入第二轮，云课堂仍留在桌面")
	var cloud := int(_ids(session, "yunketang", 1)[0])
	var user := -1
	for group in session._groups:
		if not group.any(func(card): return int(card["uid"]) == cloud): continue
		for card in group:
			if card["def_id"] == "user": user = int(card["uid"]); break
	var before := session.capture_operation()
	_move(session, [user])
	check(not session.review_operation(before, "layout", {"picked_uids": [user]})["expected"], "补地推现金时拆已完成云课堂，不能被当作降低材料错误的进展")
	session.restore_operation(before)
	var cash := _ids(session, "cash", 2)
	_move(session, cash, int(_ids(session, "ditui", 1)[0]))
	check(session.review_operation(before, "layout", {"picked_uids": cash})["expected"] and session.step_complete and _counts(session, cloud).get("user") == 3, "正确补地推现金，并完整保留云课堂及三用户")

func _ids(session: TutorialSession, id: String, count: int) -> Array:
	var out: Array = []
	for card in session.state.players[GameState.PLAYER]["cards"]:
		if card["def_id"] == id and out.size() < count: out.append(int(card["uid"]))
	return out

func _move(session: TutorialSession, uids: Array, target_uid := -1) -> void:
	var groups: Array = []
	var moved: Array = []
	for group in session._groups:
		var kept: Array = []
		for card in group:
			if uids.has(int(card["uid"])): moved.append(card)
			else: kept.append(card)
		if not kept.is_empty(): groups.append(kept)
	var destination := -1
	for index in groups.size():
		if groups[index].any(func(card): return int(card["uid"]) == target_uid): destination = index
	if destination >= 0: groups[destination].append_array(moved)
	elif not moved.is_empty(): groups.append(moved)
	session.preview_groups(groups)

func _counts(session: TutorialSession, uid: int) -> Dictionary:
	for group in session._groups:
		if group.any(func(card): return int(card["uid"]) == uid): return session._counts(group)
	return {}
