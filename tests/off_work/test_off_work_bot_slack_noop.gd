# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Actions = preload("res://engine/off_work_bot_actions.gd")

func _initialize() -> void:
	for elapsed in [0.0, 7.0, 14.0]:
		_running_line(elapsed)
	finish()

func _world() -> OffWorkState:
	var config := OffWorkConfig.new()
	config.rules.initial.groups = [{"employee":1,"slack":1},{"employee":1,"work":100},{"slack":1}]
	config.rules.initial.money = 0
	config.rules.conveyor.pool = {"employee":1}
	config.rules.conveyor.interval_seconds = 1000.0
	var world := OffWorkState.new(config)
	world.new_game(271)
	world.offers.clear()
	return world

func _state(world: OffWorkState) -> Dictionary:
	var fields := {}
	for key in OffWorkState.WORLD_FIELDS: fields[key] = world.get(key)
	# Reconciliation may reorder dictionary keys while preserving all values.
	return {"fields":fields.duplicate(true), "events":world._events.duplicate(true), "rng":world._rng.state}

func _running_line(elapsed: float) -> void:
	var world := _world()
	world.advance(elapsed)
	var tool: int = world._owner_type(0,"slack")[0]
	var group: int = world.cards[tool].group
	check(world.cards[tool].status == "active" and world.group_slack_participants(group).size() == 1,
		"真实规则已启动摸鱼生产，覆盖开头、半批及刚完成批次")
	var before := _state(world)
	check(Actions.apply_action(world,0,{"kind":"activate","tool":tool,"group":group}),
		"规则允许手动再次点击现有摸鱼组合")
	check(_state(world) == before, "重复激活不增加进度、人员、咖啡或事件，确实是无效果操作")
	var generated: Dictionary = Actions.generate(world,0,world.config.rules.bot,-1)
	check(generated.complete and not generated.actions.any(func(action):
		return action.kind == "activate" and int(action.get("tool",-1)) == tool),
		"BOT不再把已经运行的摸鱼重复激活列为候选")
	check(generated.actions.any(func(action): return action.kind == "wait"),
		"保留等待自然产出的独立选择")
	check(generated.actions.any(func(action): return action.get("intent","") == "slack_staff" and int(action.group) == group),
		"保留向已有产线补充人员的真实动作")
	check(generated.actions.any(func(action): return action.get("intent","") == "slack_tools" and int(action.group) == group),
		"保留向已有产线追加摸鱼工具的真实动作")
	check(generated.actions.any(func(action): return action.get("intent","") == "staff" and action.ids.has(world.group_people(group)[0])),
		"保留从摸鱼返岗工作的真实动作")
	if elapsed >= world.config.number("slack","seconds"):
		check(generated.actions.any(func(action): return action.get("intent","") == "coffee"),
			"产出真实咖啡后仍保留升级配方动作")
	check(_state(world) == before, "生成候选不改变原局面和随机流")
