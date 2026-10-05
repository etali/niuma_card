# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 思考计时器（`engine/think_clock.gd` + 顶部回合状态）的判据。
##
## 用户要的原话是「外显的实时计数器显示 BOT 每次搜索花掉的时间，
## 如果是局域网对战则显示对手花掉的时间」。所以要钉三件事：
##   1. 那个数随实际墙钟增长，并与最终实测耗时一致
##   2. 计时**真的裹在搜索外面** —— 这条最容易假绿：秒表自己 start/stop
##      一定对得上，而它到底有没有装在 BOT 那条路上是另一件事
##   3. 单机与联网都在顶部显示当前计时，面板不重复，结束后收起
##
## 第 2 条的判法是**真跑一个行动阶段**，然后看趟数涨了没有 ——
## 不 mock 秒表、不直接调 start/stop。


func _initialize() -> void:
	print("=== 思考计时器 ===")
	CardDB.ensure_loaded()
	await _t_measures_wall_clock()
	await _t_stats()
	await _t_reset()
	await _t_idempotent_stop()
	await _t_live_text()
	await _t_wired_into_bot_path()
	await _t_bot_single_search()
	finish()


## 一、量的是真墙钟。
##
## 判 ±60 毫秒而不是精确值：无头下帧长本身就有抖动，
## 短长两次测量都比较真实墙钟，固定读数无法同时满足。
func _t_measures_wall_clock() -> void:
	ThinkClock.reset()
	ThinkClock.start(ThinkClock.SRC_BOT)
	check(ThinkClock.running(), "start 之后 running() 是真")
	check(ThinkClock.source() == ThinkClock.SRC_BOT, "记下了是谁在想（bot）")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 150:
		await process_frame
	var live := ThinkClock.elapsed_ms()
	ThinkClock.stop()
	var real := Time.get_ticks_msec() - t0

	check(not ThinkClock.running(), "stop 之后 running() 是假")
	check(absi(live - real) <= 60,
		"跑着的时候 elapsed_ms 跟着真时间走（读到 %d，实际 %d）" % [live, real])
	check(absi(ThinkClock.last_ms() - real) <= 60,
		"停表之后 last_ms 是真花掉的时间（%d，实际 %d）" % [ThinkClock.last_ms(), real])
	var first_ms := ThinkClock.last_ms()
	ThinkClock.start(ThinkClock.SRC_BOT)
	var second_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - second_start < real + 120:
		await process_frame
	ThinkClock.stop()
	var second_real := Time.get_ticks_msec() - second_start
	check(ThinkClock.last_ms() >= first_ms + 60
		and absi(ThinkClock.last_ms() - second_real) <= 60,
		"等待更久后实测时长增长且仍贴合墙钟（%d → %d，实际 %d）" % [
			first_ms, ThinkClock.last_ms(), second_real])

## 二、趟数和平均。单次会抖，玩家看这一档的形状要看平均
func _t_stats() -> void:
	ThinkClock.reset()
	check(ThinkClock.count() == 0, "刚清过：趟数 0")
	check(ThinkClock.last_ms() == -1, "从没跑过时 last_ms 是 -1（不是 0）")
	check(ThinkClock.avg_ms() == -1, "从没跑过时 avg_ms 是 -1")

	for i in 3:
		ThinkClock.start(ThinkClock.SRC_BOT)
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 40:
			await process_frame
		ThinkClock.stop()
	check(ThinkClock.count() == 3, "跑了三趟，趟数是 3（%d）" % ThinkClock.count())
	# 三趟每趟约 40 毫秒，平均该在这个量级。判区间而不是判具体数
	var avg := ThinkClock.avg_ms()
	check(avg >= 20 and avg <= 200, "平均值在三趟的量级上（%d 毫秒）" % avg)


## 三、清空。换局要调 —— 上一局的平均挂在新局面板上是假话
func _t_reset() -> void:
	ThinkClock.start(ThinkClock.SRC_FOE)
	ThinkClock.stop()
	if not need(ThinkClock.count() > 0, "清之前有数"):
		return
	ThinkClock.reset()
	check(ThinkClock.count() == 0 and ThinkClock.last_ms() == -1
			and ThinkClock.last_source() == "" and not ThinkClock.running(),
		"reset 把趟数 / 上次读数 / 来源 / 在跑标记全清了")


## 四、stop 幂等。`main.gd` 那几处 stop 在 await 之后，
## 换局或掉线会让那行代码走不到，而别处可能已经调过一次
func _t_idempotent_stop() -> void:
	ThinkClock.reset()
	ThinkClock.start(ThinkClock.SRC_BOT)
	ThinkClock.stop()
	var n := ThinkClock.count()
	ThinkClock.stop()
	ThinkClock.stop()
	check(ThinkClock.count() == n, "空手 stop 不计入统计（还是 %d 趟）" % n)


## 五、顶部持续走字，结束后清理；每帧更新不得触发资源重新计算。
func _t_live_text() -> void:
	var main: Node = await boot_main()
	ThinkClock.reset()
	main._update_thinking_hint(true)
	var idle: String = main.lbl_round.text
	check(not idle.contains("思考") and not idle.contains("秒"), "未思考时顶部不显示旧耗时")
	var panels := main.find_children("BOTPanel", "", true, false)
	var panel_has_clock := false
	for panel: Node in panels:
		for label: Node in panel.find_children("*", "Label", true, false):
			panel_has_clock = panel_has_clock or label.text.contains("⏱") or label.text.contains("思考")
	check(panels.size() == 1 and not panel_has_clock, "BOT 强度面板不再重复显示计时行")
	ThinkClock.start(ThinkClock.SRC_BOT)
	main._update_thinking_hint()
	check(main.lbl_round.text.ends_with("对手思考中… 0.0秒"), "顶部在思考开始立即显示零秒")
	main.lbl_player_res.text = "计时刷新不重算资源"
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < 250:
		await process_frame
	var elapsed := _displayed_seconds(main.lbl_round.text)
	check(elapsed >= 0.2 and absf(elapsed - ThinkClock.elapsed_ms() / 1000.0) <= 0.15,
		"顶部计时随真实墙钟增长，无需额外 HUD 刷新（%s）" % main.lbl_round.text)
	check(main.lbl_player_res.text == "计时刷新不重算资源", "实时计时只更新回合标签，不全量重绘资源 HUD")
	ThinkClock.stop()
	main._update_thinking_hint()
	check(main.lbl_round.text == idle, "思考完成立即收起计时并恢复回合文字")
	ThinkClock.start(ThinkClock.SRC_FOE)
	main._update_thinking_hint()
	var foe_run: String = main.lbl_round.text
	check(foe_run.contains("对手") and not foe_run.contains("BOT"),
		"联网局在想的时候念「对手」而**不**念 BOT（%s）" % foe_run)
	check(foe_run.ends_with("0.0秒"), "下一次思考从零开始，不显示上一次耗时")
	ThinkClock.stop()
	main._update_thinking_hint()
	check(main.lbl_round.text == idle, "联网等待结束也收起当前计时")
	ThinkClock.reset()
	main.free()

func _displayed_seconds(text: String) -> float:
	if not text.contains("对手思考中… "):
		return -1.0
	return text.get_slice("对手思考中… ", 1).trim_suffix("秒").to_float()


## 六、**最要紧的一条**：秒表真的装在 BOT 那条路上。
##
## 前五条全是自证 —— 自己 start、自己 stop，读数当然对。
## 这条不碰 ThinkClock 的任何写接口，只跑一个真的行动阶段，
## 然后看趟数涨了没有。装漏了（`_think_off_thread` 里少那两行）这条就红，
## 而上面五条照旧全绿
func _t_wired_into_bot_path() -> void:
	var main: Node = await boot_main()
	if not need(main != null, "开局成功"):
		return
	# 强度调到最低档：这条判据要的是「计过没有」，不是「花了多久」，
	# 满档一次 1.7 秒会让这条测试自己变慢
	BOTSearch.clear_overrides()
	BOTSearch.set_pref_strength(float(BOTSearch.PRESETS["min"]))

	# 连跑两个行动阶段，beat 数真实搜索次数，再与同一个屏幕思考钩子的计时记录对账。
	ThinkClock.reset()
	var asked := [0]
	# 两个行动阶段分别触发当前策略搜索，验证每次搜索独立计时。
	var agent := BOTAgent.new(main.pipe, main.foe_seat, BOTSearch.from_model("bot", BOTSearch.pref_strength()))
	agent.think = main._think_off_thread
	# 阶段墙钟：下面那条占比判据要拿它当分母。beat 返回 null，
	# 所以这段墙钟里没有演出节拍，几乎全是搜索本身
	var t0 := Time.get_ticks_msec()
	await agent.run_action_phase(func(step: String):
		if step == BOTAgent.STEP_THINK:
			asked[0] += 1
		return null)
	var second := BOTAgent.new(main.pipe, main.foe_seat, BOTSearch.from_model("bot", BOTSearch.pref_strength()))
	second.think = main._think_off_thread
	await second.run_action_phase(func(step: String):
		if step == BOTAgent.STEP_THINK:
			asked[0] += 1
		return null)
	var wall := Time.get_ticks_msec() - t0
	var n := ThinkClock.count()
	check(n > 0, "跑完两个行动阶段，计时器记下了 %d 次搜索（0 = 秒表没装上）" % n)
	check(ThinkClock.last_source() == ThinkClock.SRC_BOT,
		"记的来源是本地 BOT（%s）" % ThinkClock.last_source())
	check(asked[0] == 2 and n == asked[0],
		"两个行动阶段各搜索一次，计时器逐次记录（搜索 %d / 记录 %d）" % [asked[0], n])

	# 趟数对上了还不够：**每一趟得真的裹住那次搜索**。
	# 趟数对而时长是 0 的写法是存在的 —— stop 摞在 start 后面、
	# 搜索在它俩之后（实测那个变异：占比 0%，而趟数一分不差）。
	# 于是顶部秒数一直停在零，满档也如此。
	#
	# 判占比而不是判「大于 0」：最低档一次搜索约 12 毫秒，
	# 快机器上真有可能量到 0，那样这条判据会随机红。
	# 实测占比最低档 56%、满档 98%（`tools/_clock_ratio_probe.gd`），
	# 钉 20% 是最低档那个数的三分之一 —— 松到不误杀，紧到 0% 一定红
	var recorded := n * ThinkClock.avg_ms()
	var share := 100.0 * float(recorded) / float(maxi(wall, 1))
	check(share >= 20.0,
		"记下的时长真裹住了搜索（合计 %d 毫秒 / 阶段墙钟 %d，占 %.0f%%）" % [
			recorded, wall, share])

	# 换局要清。这一条判的是 `main.gd::_reset_session_flags` 里那句 reset ——
	# `_t_reset` 那条自己调 `ThinkClock.reset()`，证明的是函数本身好使，
	# 证不了「换局时有人调它」。两条缺一不可
	if need(ThinkClock.count() > 0, "清之前先有数（%d 趟）" % ThinkClock.count()):
		main._reset_session_flags()
		check(ThinkClock.count() == 0 and ThinkClock.last_ms() == -1,
			"「再战一局」把上一局的趟数和读数清了（%d 趟 / 上次 %d）" % [
				ThinkClock.count(), ThinkClock.last_ms()])
	# rematch 那条路（keep_net=true）也要清：联网局和单机局量的不是同一件事,
	# 混进一个平均值里那个数没有意义
	ThinkClock.start(ThinkClock.SRC_FOE)
	ThinkClock.stop()
	main._reset_session_flags(true)
	check(ThinkClock.count() == 0, "rematch 那条路也清（keep_net=true）")

	await _foe_side(main)
	main.free()


## 联网那一路的秒表。**这一路压根不经过 `BOTThink`** ——
## 对手在他自己那台机器上想，这边只是在 `_await_foe_action` 里等一条 action_done。
## 也就是说本地 BOT 那些判据一条都覆盖不到它（这也是秒表不能挂在 BOTThink 上的理由）。
##
## 这里不起真连接：`_await_foe_action` 等的是 `_foe_action_done` 这个标志位，
## 而那个标志位由 `_on_intent_applied` 之外那条分支置起来。
## 直接置它 = 模拟「对方发来了 action_done」，等的那一段墙钟是真的
func _foe_side(main: Node) -> void:
	ThinkClock.reset()
	# 一段可辨认的等待：置标志位的活儿排在 120 毫秒之后
	var arm := func() -> void:
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 250:
			await process_frame
		check(_displayed_seconds(main.lbl_round.text) >= 0.2,
			"真实联网等待路径在顶部持续显示本次耗时")
		main._foe_action_done = true
	arm.call()
	var t0 := Time.get_ticks_msec()
	await main._await_foe_action()
	var wall := Time.get_ticks_msec() - t0

	check(ThinkClock.count() == 1, "等了一次对手行动，计时器记了 %d 趟" % ThinkClock.count())
	check(ThinkClock.last_source() == ThinkClock.SRC_FOE,
		"记的来源是**对手**而不是本地 BOT（%s）" % ThinkClock.last_source())
	# 量到的是真等的那一段。±60 同前：无头帧长本身有抖动
	check(absi(ThinkClock.last_ms() - wall) <= 60,
		"读数就是真等的那段墙钟（%d，实际 %d）" % [ThinkClock.last_ms(), wall])
	check(not main.lbl_round.text.contains("思考中"), "真实联网等待路径完成后收起顶部计时")
	ThinkClock.reset()


## BOT 一次搜索生成整段行动，计时不能误按典当/购买/编组的意图条数累计。
func _t_bot_single_search() -> void:
	var main: Node = await boot_main()
	if not need(main != null, "BOT计时测试启动场景"):
		return
	ThinkClock.reset()
	var asked := [0]
	var agent := BOTAgent.new(main.pipe, main.foe_seat, BOTSearch.from_model("bot",0))
	agent.think = main._think_off_thread
	await agent.run_action_phase(func(step: String):
		if step == BOTAgent.STEP_THINK:
			asked[0] += 1
		return null)
	check(asked[0] == 1 and ThinkClock.count() == 1,
		"BOT完整方案搜索一次，计时器恰好记一次，不因逐条重放而增加")
	check(ThinkClock.last_source() == ThinkClock.SRC_BOT and ThinkClock.last_ms() >= 0,
		"BOT复用实际屏幕思考钩子，报告本地BOT耗时")
	main.free()
