# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"
const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	for kind in ["meeting", "outsource", "slack"]:
		var config := OffWorkConfig.new()
		config.rules.initial.groups = [{"employee":2, "work":100}]
		if kind == "slack": config.rules.initial.groups[0].leader = 1
		config.rules.initial.money = 20 if kind == "outsource" else 0
		var game := OffWorkState.new(config)
		game.new_game(861)
		var original: int = game.cards[game._owner_type(0, "work")[0]].group
		var tool := game.add_card(kind, 0, original)
		var snapshot := var_to_bytes(game.cards)
		var generated := Actions.generate(game,0,config.rules.bot,Time.get_ticks_usec()+1000000)
		check(generated.complete,kind+"完整列举工具与生产候选")
		var action := {}
		for candidate in generated.actions:
			if candidate.get("intent") != kind or candidate.kind != "move" or candidate.group != -1 or tool not in candidate.ids: continue
			# Ranking belongs to shared evaluator/search tests. This contract
			# verifies the alternative that preserves ordinary production.
			var moved_workers: int = candidate.ids.filter(func(id): return game.config.can_work(str(game.cards[id].type))).size()
			if moved_workers <= 1:
				action = candidate
				break
		check(var_to_bytes(game.cards) == snapshot, kind + "候选评估不修改当前对局")
		check(not action.is_empty(),kind + "候选拆出独立功能组，不把工具塞给已开工组合")
		if action.is_empty(): continue
		check(Actions.apply_action(game,0,action), kind + "规划命令能由真实规则执行")
		var destination: int = game.cards[tool].group
		check(destination != original and game.groups[destination].job == kind and game.groups[original].job == "work", kind + "执行后两个组合各自保持一个功能")
		check(game.group_work_rate(original) > 0.0 and game.work_count(0) == 100, kind + "组合操作保留原工作组生产且不提前消耗工作")
	finish()
