# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## `BOTThink` 的判据：**真的跑在别的线程上**，而且主线程在等的时候没停。
##
## 为什么单开一份文件：`BOTThink` 之前一条判据都没有。
## 场景侧那批测试（`test_bot_panel` 等）走的是 `main.gd` 的钩子，
## 而钩子那一路只验「意图落地了」——线程起没起来它看不出来：
## `run()` 在 `tree == null` 时**退回同步算**，返回值一模一样。
## 也就是说不盯线程 ID 的话，整条线程分支可以从头到尾没执行过，测试照样全绿。
##
## 这里的 tree 传 `self`：`-s` 跑的脚本自己就是 SceneTree，
## `await self.process_frame` 在无头下照常发（全表 40 多处都这么等）。


## 主线程的 ID。`OS.get_thread_caller_id()` 在主线程上等于
## `OS.get_main_thread_id()`，在工作线程上是另一个数 —— 这就是「真上了线程」的判据本身
var _main_id := 0


func _initialize() -> void:
	print("=== BOTThink 线程测试 ===")
	_main_id = OS.get_thread_caller_id()
	check(_main_id == OS.get_main_thread_id(), "测试自己跑在主线程上（后面拿它当基准）")

	await _t_runs_off_thread()
	await _t_main_keeps_ticking()
	await _t_no_tree_falls_back_sync()
	await _t_reentrant_gate()
	await _t_cancel_queued_job()
	await _t_flush_is_idempotent()
	finish()


## 一、job 真的在工作线程上执行，且返回值原样穿回来。
##
## 这是这份文件存在的理由：把 `tree` 传进去之后，`job` 里读到的
## thread caller id 必须**不等于**主线程那个。相等就说明走了同步退化那一路
func _t_runs_off_thread() -> void:
	var t := BOTThink.new()
	var main_id := _main_id
	var got: Variant = await t.run(func() -> Variant:
		return {"tid": OS.get_thread_caller_id(), "val": 6 * 7}
	, self)

	if not need(got is Dictionary, "线程任务的返回值穿回主线程（拿到 Dictionary）"):
		return
	var d: Dictionary = got
	check(int(d.get("tid", main_id)) != main_id,
		"job 跑在工作线程上（线程 %d ≠ 主线程 %d）" % [int(d.get("tid", -1)), main_id])
	check(int(d.get("val", 0)) == 42, "返回值原样穿回来（42）")
	# 收工之后不许留着 Thread：留着的话下一次 run 撞到重入闸门，
	# 而 Godot 析构时还会报 Thread must be disposed
	check(not t.busy(), "算完之后 busy() 是假")


## 二、主线程在等结果的时候**没有停**。
##
## 「双工」这个词的判据只能是这条：光「结果对」不排除同步算 ——
## 同步算结果也对，只是画面卡住。所以让 job 忙等到某个墙钟，
## 期间数主线程走了多少帧：同步的话一帧都走不了（主线程正堵在 job 里面）
func _t_main_keeps_ticking() -> void:
	var t := BOTThink.new()
	# 忙等 0.25 秒。不用 OS.delay_msec 是因为它可能被优化/让出，
	# 这里要的是「线程确实占着 CPU 一段时间」这个事实
	var busy_job := func() -> Variant:
		var t0 := Time.get_ticks_msec()
		var spins := 0
		while Time.get_ticks_msec() - t0 < 250:
			spins += 1
		return spins

	# 数帧用引擎自己的计数器，不另起一条协程数。
	# 起协程数帧那个写法是错的：lambda **按值捕获**，
	# 所以外面把停止旗改成 false，lambda 里那份还是 true，它永远停不下来 ——
	# 一条数不完的协程挂在树上，整份文件跑完收不了尾。
	# `Engine.get_process_frames()` 直接问主循环转了几圈，没这个坑
	#（顺带：`counter.call()` 这种不接返回值的协程调用本身**不报错**，
	# 报的是接住返回值那一种 —— 见 `_t_reentrant_gate` 的说明）
	var f0 := Engine.get_process_frames()
	var wall0 := Time.get_ticks_msec()
	var spun: Variant = await t.run(busy_job, self)
	var frames := Engine.get_process_frames() - f0
	var wall := Time.get_ticks_msec() - wall0

	check(int(spun) > 0, "忙等任务返回了自旋次数（%d 次）" % int(spun))
	# 这条是配着下面那条读的：光「帧数不为零」还留个口子 ——
	# job 要是一瞬间就返回，随便等一帧也能凑出帧数。
	# 钉住「真占了 250 毫秒」之后，帧数才等价于「这段时间里主线程没闲着」
	check(wall >= 240, "这一趟真花了 %d 毫秒（job 占满了 250）" % wall)
	# 0.25 秒里主线程该走十几帧（无头 60Hz，TEST_SPEED 加速只会更多）。
	# 钉 >= 3 而不是某个具体数：这条要盯的是「不为零」，
	# 具体帧数随机器和 TEST_SPEED 变，写死一个数只会让判据变脆
	check(frames >= 3,
		"主线程在 BOT 思考期间照常走帧（%d 帧，同步算会是 0）" % frames)


## 三、不给 tree 就退回同步算 —— 无头单测和引擎层走的是这条。
##
## 判据是反过来的：这一路 job 必须**就在主线程上**跑。
## 这条和第一条合起来才说明「两条路都还在」，缺一条都会让另一条的绿失去意义
func _t_no_tree_falls_back_sync() -> void:
	var t := BOTThink.new()
	var main_id := _main_id
	var got: Variant = await t.run(func() -> Variant:
		return OS.get_thread_caller_id()
	, null)
	check(int(got) == main_id, "tree 传 null 时就地同步算（线程 ID 等于主线程）")
	check(not t.busy(), "同步那一路压根没起线程（busy() 是假）")

	# 同一个忙等任务走同步这一路：帧数必须是 0。
	# 这是上一条「走了 N 帧」的反面对照 —— 没有它，那条绿只说明
	# 「等的时候帧在走」，不排除「不管怎么算帧都在走」
	var f0 := Engine.get_process_frames()
	var _spun: Variant = await t.run(func() -> Variant:
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 250:
			pass
		return 1
	, null)
	var frames := Engine.get_process_frames() - f0
	check(frames == 0,
		"同步算的 250 毫秒里主线程一帧没走（%d 帧 —— 这就是要治的卡死）" % frames)


## 四、重入闸门：上一份还在跑的时候第二次 run 不许覆盖 `_thread`。
##
## 覆盖了就没人 wait_to_finish 那个旧的，正是这个类要防的
## 「Thread must be disposed」。今天两处调用是前后脚的，撞不上；
## 这条判据钉的是**闸门本身还在**，将来加第二个 BOT 座位时它才是唯一的防线
##
## 造重入要有一条**不等结果**的调用先把线程占住。而 `run()` 是协程，
## 直接 `t.run(...)` 编译期就被拦（Parse Error: Function "run()" is a coroutine…）。
##
## 绕法的分界线**不是「有没有 await」，是「有没有接住返回值」**
## （实测 `tools/_lambda_call_probe.gd`，五种形状）：
##   - `var r = lam.call()` —— 接住了 → 运行期报
##     「Trying to call an async function without "await"」，而且**中断调用方**：
##     那之后的断言一条都不跑。汇总数照旧全绿（断言没红过），
##     抓住它的是 `run_tests.sh` 的运行时报错检查
##   - `lam.call()` —— 不接返回值 → **不报**，协程照常起跑、照常恢复。
##     `tests/test_think_clock.gd` 里那个 `arm.call()` 就是这一种
##   - `helper.call_deferred(...)` —— 也不报，走空闲期回调
##
## 下面用 `call_deferred` 那一种：协程要往外递结果，而 lambda 按值捕获，
## 所以信箱是个成员数组（`_first_box`）。
##
## 这条判据钉的是**闸门本身还在**：覆盖了就没人 wait_to_finish 那个旧的，
## 正是这个类要防的「Thread must be disposed」。
## 今天两处调用是前后脚的，撞不上；将来加第二个 BOT 座位时它才是唯一的防线
func _t_reentrant_gate() -> void:
	var t := BOTThink.new()
	# 两份任务都报自己的起止墙钟。下面靠这两段区间判「闸门有没有串行化」——
	# 只看返回值的话，闸门拆掉之后两个线程并排跑，返回值照旧各自正确
	var slow := func() -> Variant:
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 120:
			pass
		return {"tag": "first", "t0": t0, "t1": Time.get_ticks_msec()}

	_first_box.clear()
	# 排进空闲期。回来那一帧 `_stash_first` 才开始跑，所以下面要先等一帧
	_stash_first.call_deferred(t, slow)
	await process_frame
	if not need(t.busy(), "第一份任务正在跑（busy() 是真，闸门下面要撞的就是它）"):
		return

	# 第二次进来。它会在闸门那儿等第一份收工，而不是覆盖 `_thread`
	var second: Variant = await t.run(func() -> Variant:
		return {"tag": "second", "t0": Time.get_ticks_msec()}
	, self)
	if not need(second is Dictionary, "第二份任务拿到了返回值"):
		return
	check(str((second as Dictionary).get("tag", "")) == "second",
		"第二份任务算出了自己的结果")

	# 第一份的结果从信箱里取。**必须真等到**：等不到就说明闸门把
	# 上一份的信箱清掉了（修之前就是这个形状 —— 共用一格 `_box`，
	# 第二个调用方进门先清，第一份等 300 帧拿到空手）
	var spins := 0
	while _first_box.is_empty() and spins < 600:
		await process_frame
		spins += 1
	if not need(not _first_box.is_empty(), "第一份任务拿到了结果（等了 %d 帧）" % spins):
		return
	var first: Dictionary = _first_box[0]
	check(str(first.get("tag", "")) == "first",
		"而且拿到的是**它自己那份**（%s，串了的话会是 second）" % str(first.get("tag", "")))

	# 闸门的判据本体：两段不许重叠 —— 第二份必须在第一份收工**之后**才开始算。
	#
	# 为什么不是「有没有漏 Thread」：线程句柄现在是各自的 local（见
	# `BOTThink._release`），闸门拆了也各自 join 得掉，`busy()` 照旧是假。
	# 也就是说拿漏没漏当判据的话，把 `while _thread != null` 改成 `while false`
	# 是抓不住的 —— 那时候真坏的是**两条线程并排跑**：满档一次 1.7 秒、
	# 两份一起就是两个核在烧，而 `_thread`/`_box` 两格只认得最后进来那个,
	# 退出时 `flush()` 只收得掉一条
	var gap := int(second["t0"]) - int(first["t1"])
	check(gap >= 0,
		"闸门把两份串起来了（第二份比第一份收工晚 %d 毫秒，并排跑会是负的约 -120）" % gap)
	check(not t.busy(), "两份都收工之后没有线程剩着")
	t.flush()


## `_t_reentrant_gate` 用的信箱。放成员变量而不是 local：
## `call_deferred` 那头是另一次调用，捕不到这边的栈
var _first_box: Array = []
var _queued_box: Array = []

func _stash_queued(t: BOTThink, job: Callable, cancelled: Callable) -> void:
	_queued_box.append(await t.run(job, self, cancelled))

func _t_cancel_queued_job() -> void:
	var t := BOTThink.new()
	_first_box.clear()
	_queued_box.clear()
	_stash_first.call_deferred(t, func() -> Variant:
		OS.delay_msec(100)
		return "first"
	)
	await process_frame
	check(t.busy(), "取消测试的首份任务已占用线程")
	var cancelled := [false]
	var ran := [false]
	_stash_queued.call_deferred(t, func() -> Variant:
		ran[0] = true
		return {"ran": true}
	, func() -> bool: return cancelled[0])
	await process_frame
	check(_queued_box.is_empty(), "第二份任务正在排队等待线程")
	cancelled[0] = true
	t.flush()
	for i in 30:
		if not _queued_box.is_empty() and not _first_box.is_empty():
			break
		await process_frame
	check(not ran[0] and _queued_box == [{}], "flush 后已取消的排队任务不会再启动")
	check(_first_box == ["first"] and not t.busy(), "取消排队任务不丢失第一份结果或遗留线程")


## 替 `_t_reentrant_gate` 去 await 第一份任务，结果丢进 `_first_box`。
##
## 单独一个方法是为了能被 `call_deferred` 点名 —— 见调用处的说明
func _stash_first(t: BOTThink, job: Callable) -> void:
	var r: Variant = await t.run(job, self)
	_first_box.append(r)


## 五、flush() 可以重复调，且空手调不炸。
##
## `main.gd` 的 `_exit_tree` 调它，而 `_exit_tree` 在换局/退出时可能走到不止一次
func _t_flush_is_idempotent() -> void:
	var t := BOTThink.new()
	t.flush()
	check(not t.busy(), "没起过线程也能 flush（不炸）")
	var _r: Variant = await t.run(func() -> Variant: return 1, self)
	t.flush()
	t.flush()
	check(not t.busy(), "连着 flush 两次之后 busy() 是假")
