# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

class_name AIThink
extends RefCounted

## 把一次 AI 决策丢到工作线程上算，主线程继续画画面。
##
## 搜索在工作线程运行，主线程继续刷新画面和处理输入。
## 每次决策实际耗时由 ThinkClock 记录，不使用固定档位耗时表。
##
## ---
##
## **为什么可以搬到别的线程上：搜索只写独立副本。**
## AIEnvironment.copy 保存牌实例、组合、UID和随机状态，搜索不写真实牌桌。
## AIAgent 在主线程通过 IntentApply 逐条重放最终计划，表现事件只从这里发出。
##
## 搜索期间 `CardDB` 只读。场景在重开、切换配置或联网入口重载规则前必须
## `flush()` 收完正在运行的搜索；会话取消只阻止意图落地，不能代替线程同步。
##
## ---
##
## **为什么不是把 choose_plan 切成协程按帧续算。**
##
## 那要求 `choose_plan` 变成 coroutine，而它下面压着 `MatchSimulator.run_rounds`、
## `tools/` 的一串同步调用方和几十个单测 —— `engine/ai_agent.gd` 的类注释
## 把这个坑写在「为什么是步进器而不是 coroutine」那一段里，是同一个坑。
## 搬线程只动场景层这一侧：引擎层的同步接口一个字没变，无头路径压根不经过这里。
##
## ---
##
## 用法（`scenes/main.gd`）：
##     var t := AIThink.new()
##     var plan: Variant = await t.run(func() -> Variant: return 一个纯计算(), tree)
## 算完之前每帧让出去，主线程照常 _process / _input。


## 线程活着但迟迟不给结果时，等到这个数就放弃等待、回主线程自己算一遍。
##
## 30 秒不是「够不够算完」的估计（满档最慢实测 7.4 秒），是「卡死了没」的判据：
## 真算完了这个值多大都无所谓，只有线程挂了才会撞上它。
## 撞上之后**不杀线程** —— Thread 没有安全的中止，杀了可能停在半路的
## 内存分配上。让它自己跑完，结果扔掉
const TIMEOUT_SEC := 30.0

## 那个工作线程。**只有一格** —— 同一时刻只跑一份任务，
## 第二个调用方在 `run()` 开头的闸门那儿等着（不是覆盖它）。
##
## 这一格是**镜子**，不是所有权：真正 join 线程的是 `run()` 里那个
## local 句柄（见那儿的注释）。这一格只回答两个问题 ——
## 「现在忙不忙」（`busy()`）和「退出时还有没有人要收」（`flush()`）
var _thread: Thread = null

## 最近一次任务的信箱，只给 `flush()` 和调试看。
##
## **信箱是按次调用各造一个的**（`run()` 里那个 local），不是共用这一格：
## 共用的话第二个调用方进闸门时会把上一份的结果清掉，
## 于是第一个调用方永远等不到自己的结果，最后领走第二份的
## （实测：`tools/_defer_coro_probe.gd` 下第一份等了 300 帧拿到空手）。
## 两个 AI 座位同时开口时那就是「A 座拿到 B 座的计划」
var _box: Array = []


## 在工作线程上跑 `job`，返回它的返回值。**job 必须是纯计算** ——
## 不许碰场景树、不许改真状态、不许发信号（Godot 的信号不是线程安全的）。
##
## tree: 用来 await `process_frame`。没有它就退化成同步跑
## （无头单测走这条：那边没有 SceneTree 的帧循环可等）
func run(job: Callable, tree: SceneTree, cancelled: Callable = Callable()) -> Variant:
	if cancelled.is_valid() and cancelled.call():
		return {}
	if tree == null:
		return job.call()
	# 上一份还在跑就先等它。整个场景共用一个 AIThink，而 `_thread` 只有一格：
	# 不等就直接覆盖，旧的那个再没人 wait_to_finish（正是这个类要防的
	# 「Thread must be disposed」）。今天两处调用是前后脚的，撞不上；
	# 哪天两个 AI 座位或者快进同时开口，这里就是唯一的闸门
	while _thread != null:
		if cancelled.is_valid() and cancelled.call():
			return {}
		if _thread.is_alive():
			await tree.process_frame
		else:
			# 跑完了但还没人收 —— 替它收掉。`is_alive()` 假的那一刻线程体
			# 已经返回，也就是信箱那一句 append 已经执行完，
			# 原主人醒过来能读到自己的结果（它的 `_release` 会发现
			# 线程已被 join，空转一下就过去）
			_release(_thread)
	# flush 可能在上面的等待期间收完旧线程并重载规则；排队的旧会话不得再开工。
	if cancelled.is_valid() and cancelled.call():
		return {}
	# 信箱和线程句柄**都是这一次调用自己的 local**，`_box`/`_thread` 那两格
	# 只是给闸门和 `flush()` 看的镜子。
	#
	# 为什么句柄也要 local：两个协程同时在场时，上面那道闸门可能替别人
	# 收掉线程并把 `_thread` 置空，而原主人这时才醒过来 —— 它要是去读
	# `_thread.wait_to_finish()` 就是对着 null 调
	# （实测报「Cannot call method 'wait_to_finish' on a null value」）。
	# 各自只 join 自己起的那一条，谁也不碰别人的
	var box: Array = []
	var th := Thread.new()
	_box = box
	_thread = th
	# 线程体只做两件事：算，然后把结果塞进信箱。**信箱的写入必须是最后一步** ——
	# 主线程靠 `box.is_empty()` 判完成，先写信箱再算的话它会读到半成品
	var body := func() -> void:
		var r: Variant = job.call()
		box.append(r)
	var err := th.start(body)
	if err != OK:
		# 起不来线程（平台不支持 / 资源耗尽）就地同步算，别让回合卡住。
		# 单线程导出的 Web 版走的就是这条
		push_warning("AIThink：线程起不来（%d），退回同步" % err)
		_release(th)
		return job.call()

	var waited := 0.0
	while box.is_empty():
		# 让出一帧。这一行就是「双工」本身：主线程回到消息循环，
		# 光标、拖拽、面板照常响应，而搜索在另一个核上继续
		await tree.process_frame
		waited += tree.root.get_process_delta_time() if tree.root != null else 0.016
		if waited > TIMEOUT_SEC:
			push_error("AIThink：等了 %.0f 秒没结果，退回主线程算一遍" % waited)
			# 线程还在跑，wait_to_finish 会阻塞到它结束 —— 但这条路本身
			# 就是「已经不正常了」，宁可卡一下也不要泄漏一个 Thread
			_release(th)
			return job.call()

	_release(th)
	return box[0]


## 收掉自己起的那条线程，并且**只在 `_thread` 还指着它时**才清那一格。
##
## wait_to_finish 必须调：不调的话 Thread 对象析构时 Godot 会报
## 「Thread must be disposed」，而那条错误在导出版里只进日志，看不见。
##
## `is_started()` 那道判断是给「被别人先收掉了」这一路兜的：
## 重入闸门会替已经跑完的线程 join 并置空 `_thread`，
## 那之后原主人再走到这里，重复 join 同一条是未定义行为
func _release(th: Thread) -> void:
	if th != null and th.is_started():
		th.wait_to_finish()
	if _thread == th:
		_thread = null


## 有没有一个线程正在跑。给「换局 / 改档位要不要等一等」用
func busy() -> bool:
	return _thread != null and _thread.is_alive()


## 收干净。**只等，不杀** —— 理由同 TIMEOUT_SEC 那段。
## 退出前必须调，否则 Godot 报 Thread must be disposed。
##
## 幂等：`_release` 里那道 `is_started()` 判断兜住了「已经被收过」，
## 所以 `_exit_tree` 和 `run()` 谁先谁后都不会重复 join
func flush() -> void:
	if _thread != null:
		_release(_thread)
	_box = []
