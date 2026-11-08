# SPDX-License-Identifier: AGPL-3.0-only
extends "res://tests/harness.gd"

const Live = preload("res://engine/off_work_bot_live.gd")
const Preferences = preload("res://engine/off_work_bot_preferences.gd")

func _initialize() -> void: run.call_deferred()

func publish_ready(host: Node, label := "old", action: Dictionary = {"kind":"wait"}) -> RefCounted:
	var bot: OffWorkBot = host.bot
	bot._next_think = host.state.time
	var job := Live.Search.new()
	job.world = host.state.fork_for_bot(71, true)
	job.worker = OffWorkBot.new(job.world, bot.owner, bot._policy.duplicate(true))
	job.bot_id = bot.get_instance_id()
	job.due = bot.next_action_time()
	job.policy_hash = hash(bot._policy)
	job.deadline = Time.get_ticks_usec() + 1000000
	job.visible_offer_end = host.state._next_offer
	job.visible_card_end = host.state._next_card
	job.visible_group_end = host.state._next_group
	job.publish(action, {"kind":action.kind, "search_depth":4, "source_tag":label})
	host._live_bot._ready = job
	check(job.still_legal(host.state, job.latest().action), "完成的后台候选起初合法：" + label)
	return job

func run() -> void:
	var host: Node = load("res://scenes/off_work_main.tscn").instantiate()
	root.add_child(host)
	await process_frame
	host.set_process(false)
	Preferences.set_pref_strength(1.0)
	host.bot.start()
	for trigger in ["groups_changed", "human_action"]:
		publish_ready(host, trigger)
		if trigger == "groups_changed": host._on_groups_changed()
		else: host._start_opponent_after_action(0)
		check(host._live_bot._ready == null and not host._live_bot._retained_packet.is_empty(), "玩家动作重新规划但保留完整候选：" + trigger)
		host._live_bot.tick(host.bot, 0.0)
		var report: Dictionary = host.bot.last_decision
		check(report.get("live_retained", false) and report.get("search_depth", 0) == 4 and not report.get("live_fallback", false), "截止时使用仍合法的四层结果：" + trigger)

	publish_ready(host)
	host._on_groups_changed()
	publish_ready(host, "new")
	host._live_bot.tick(host.bot, 0.0)
	check(host.bot.last_decision.get("source_tag") == "new" and not host.bot.last_decision.get("live_retained", false), "新规划完成时优先采用新结果")

	publish_ready(host, "valid_backup")
	host._on_groups_changed()
	var first_offer: Dictionary = host.state.offers[0].duplicate()
	publish_ready(host, "new_sold_offer", {"kind":"buy", "offer":first_offer.id, "card_type":first_offer.type})
	host._on_buy(first_offer.id)
	host._live_bot.tick(host.bot, 0.0)
	check(host.bot.last_decision.get("source_tag") == "valid_backup", "新候选已失效时不覆盖仍合法的旧备用方案")

	var offer: Dictionary = host.state.offers[1].duplicate()
	publish_ready(host, "sold_offer", {"kind":"buy", "offer":offer.id, "card_type":offer.type})
	host._on_buy(offer.id)
	check(host.state.offers[1].is_empty(), "真人实际买走旧计划中的商品")
	host._live_bot.tick(host.bot, 0.0)
	check(host.bot.last_decision.get("live_fallback", false) and not host.bot.last_decision.get("live_retained", false), "旧候选已非法时绝不执行，使用现场应急决策")

	publish_ready(host)
	host._on_groups_changed()
	Preferences.set_override("evaluation_max_seconds", 900.0)
	host._live_bot.tick(host.bot, 0.0)
	check(host.bot.last_decision.get("source_tag") != "old" and host._live_bot._retained_packet.is_empty(), "策略变化使旧候选失效")
	Preferences.set_pref_strength(1.0)

	publish_ready(host)
	host._on_groups_changed()
	host.bot._next_think = host.state.time + 0.1
	host.state.advance(0.1)
	host._live_bot.tick(host.bot, 0.0)
	check(host.bot.last_decision.get("source_tag") != "old", "行动时点变化不能沿用旧候选")

	publish_ready(host)
	host._on_groups_changed()
	host.bot = OffWorkBot.new(host.state, 1)
	host.bot.start()
	host._live_bot.tick(host.bot, 0.0)
	check(host.bot.last_decision.get("source_tag") != "old", "新BOT实例不能沿用前一局候选")

	publish_ready(host)
	host._on_groups_changed()
	host._live_bot.cancel()
	check(host._live_bot._retained_packet.is_empty(), "暂停、退出等完整取消路径清空保留结果")
	host._live_bot.tick(host.bot, 0.0)
	check(host.bot.last_decision.get("live_fallback", false), "完整取消后不复用旧结果")

	var tool: int = host.state.add_card("meeting", 1)
	host.state._recover(tool)
	host.state.cards[tool].remaining = 0.1
	host.state.cards[tool].total = 0.1
	var future := publish_ready(host, "ready_at_due", {"kind":"move", "ids":[tool], "group":-1})
	host.bot._next_think = host.state.time + 0.1
	future.due = host.bot.next_action_time()
	future.world.advance(0.1)
	check(not future.still_legal(host.state, future.latest().action), "预测到期已恢复的工具此刻仍在冷却")
	host._on_groups_changed()
	check(not host._live_bot._retained_packet.is_empty(), "没有合法旧备用时保留预测到期可用的新候选")
	host.state.advance(0.1)
	host._live_bot.tick(host.bot, 0.0)
	check(host.bot.last_decision.get("source_tag") == "ready_at_due" and host.bot.last_decision.get("live_retained", false), "实际冷却结束后重新验证并执行到期候选")

	var gate := Semaphore.new()
	var running := publish_ready(host, "published_before_cancel")
	host._live_bot._ready = null
	host._live_bot._search = running
	host._live_bot._task = WorkerThreadPool.add_task(gate.wait)
	host._on_groups_changed()
	host._live_bot.tick(host.bot, 0.0)
	check(running.control.is_cancelled() and host.bot.last_decision.get("source_tag") == "published_before_cancel", "工作线程尚未退出时可用已发布结果且不等待线程")
	host._live_bot.close(self)
	gate.post()
	for frame in 3: await process_frame
	host.queue_free()
	await process_frame
	finish()
