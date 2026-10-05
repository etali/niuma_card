# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 测试公用脚手架：计数 + check() + 收尾。
##
## 每个测试文件原来各带一份同样的 12 行（_pass/_fail/check/结果行/quit），
## 21 份里已经飘出四种写法：FAIL 有的走 print 有的走 printerr、
## 参数名有的叫 msg 有的叫 label、还有一份额外往 user:// 写进度日志。
## 判据的印法是 tools/run_tests.sh 和 tools/mutate_check.py 都要认的东西
## （前者数「N 通过 / M 失败」，后者 grep 「[FAIL]」），四种写法等于四份约定。
##
## 用法：
##     extends "res://tests/harness.gd"
##     func _initialize() -> void:
##         print("=== 某某测试 ===")
##         check(1 + 1 == 2, "一加一等于二")
##         finish()
##
## _initialize 留给各测试自己实现 —— 基类不定义它，否则子类那份会被当成覆写，
## SceneTree 只调一处，两份都想跑就得再约定调用顺序

var _pass := 0
var _fail := 0
var _test_data_dir := ""
var _finishing := false

## user:// 必须在任何测试读取偏好前切换。单独用 Godot -s 跑测试也隔离；
## runner 只负责异常终止后的兜底清理，不再靠备份/覆盖玩家的真实文件。
func _isolate_user_data() -> void:
	var token := OS.get_environment("CARD_TEST_USER_DIR_NAME")
	if not token.begins_with("card-combine-tests/") or ".." in token:
		token = "card-combine-tests/%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	else:
		# OS.execute 派生的测试继承环境，但不能清理父进程仍在使用的夹具文件。
		token += "/%d" % OS.get_process_id()
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", token)
	_test_data_dir = OS.get_user_data_dir()
	if DirAccess.make_dir_recursive_absolute(_test_data_dir) != OK:
		printerr("SCRIPT ERROR: 无法创建测试数据目录：" + _test_data_dir)
		quit(1)
		return
	# 产品录像默认走 HOME，必须显式覆盖，才能和偏好一起隔离、清理。
	Tape.directory_override = "user://replays"
	# runner 从日志读取实际平台路径；不推测 macOS/Linux 的用户目录布局。
	print("CARD_TEST_USER_DIR=" + _test_data_dir)

func _remove_test_data(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name in directory.get_files():
		directory.remove(name)
	for name in directory.get_directories():
		_remove_test_data(path.path_join(name))
	DirAccess.remove_absolute(path)

func _finalize() -> void:
	if not _test_data_dir.is_empty():
		_remove_test_data(_test_data_dir)

## 时间加速。`tools/run_tests.sh` 默认导出 `TEST_SPEED=5`（那边有为什么是 5），
## 单跑一个文件时不加就是默认档 —— 两档都必须全绿。
##
## 两个旋钮一起动才保住物理保真度：
##   time_scale=N          补间和 create_timer 按 N 倍快
##   physics_ticks=60*N    每步推进的游戏时间仍是 1/60
## 实测 time_scale=5 + ticks=300 下刚体自由落体 0.3 秒游戏时间后
## y = 9.5389，与默认档**逐位相同**；单帧墙钟从 15.8ms 掉到 3.6ms，
## 全表 191 秒 → 88 秒。要盯的是「两档断言数一样」这个恒等式，
## 不是某个具体条数：加判据它就变，写死一个数只会让注释过期
## （原先钉着 3293，加着加着早就不是了）。当前条数看 run_tests.sh 最后那行
##
## 两档结果不同 = 有判据把「帧数」当「墙钟」用了，而那本来就是错的：
## 加速只是让它现形（net_until 的预算、_seated_scene 缺的阶段前提都是这么揪出来的）
func _init() -> void:
	_isolate_user_data()
	var n := float(OS.get_environment("TEST_SPEED"))
	if n <= 1.0:
		return
	Engine.time_scale = n
	Engine.physics_ticks_per_second = int(round(60.0 * n))

## FAIL 走 printerr：跑一屏测试时失败那几行要能一眼挑出来（终端标红），
## 也让 tools/run_tests.sh 把它单独收进摘要。stdout/stderr 两头
## mutate_check.py 都读，所以走哪条都不影响变异检查
##
## `check(true, "...")` **不是**永真判据，别当冗余删掉：那是「等到了」这一路的记账，
## 判据本身在失败那一路上（全表 30 处都是这个写法）：
##     if not await net_until([a, b], 装弹了):
##         check(false, "服务器给先手装弹了")
##         return
##     check(true, "服务器给先手（%s）装弹了" % first.my_seat)
## 两条路记的是同一句话，所以报表上「这条验过没有」不取决于它过没过。
## 只在成功那路记的话，超时就变成「这条判据整个消失」，而报表少一条
## 和报表多一条红长得完全不一样 —— 前者要数断言总数才看得出来
func check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  [OK] " + msg)
	else:
		_fail += 1
		printerr("  [FAIL] " + msg)

## 「这条不成立后面就没法判了」的那种前提。判据照记一笔（漏做要让测试红），
## 但不成立时调用方要能立刻收摊 —— 不收的话下面每一条判的都是别的事
##
## 原先 14 个文件各抄一份，一字不差（只有 test_host_takeover 那份带着上面这段
## 说明，其余 13 份光秃秃）。收在这里之后各文件直接用
func need(cond: bool, msg: String) -> bool:
	check(cond, msg)
	return cond

## 打结果行并按失败数退出。**这一行的格式 tools/run_tests.sh 要解析**
## （数「N 通过 / M 失败」），别改字样
func finish() -> void:
	if _finishing:
		return
	_finishing = true
	_drain_and_finish.call_deferred()

## 保持 finish() 的同步调用约定；释放场景后给音频服务一次真实时间的收尾。
## 直接 quit 会让已 stop 的 AudioStreamPlaybackWAV 来不及退出混音线程，
## 从而在引擎析构时仍持有 WAV 资源。这里不静音、不屏蔽日志，也不改断言。
func _drain_and_finish() -> void:
	for child in root.get_children():
		child.queue_free()
	_booted = null
	await process_frame
	await process_frame
	# 观察真正的下一次混音，而非等待游戏时间。Dummy 驱动的 4096 帧缓冲
	# 在 44.1kHz 下约 93ms，固定等 50ms 仍会把退出落在两次混音之间。
	# 无线程/不运行混音的驱动有墙钟上限；退出日志仍会如实暴露未释放资源。
	var deadline := Time.get_ticks_msec() + 1000
	var previous_mix := AudioServer.get_time_since_last_mix()
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var since_mix := AudioServer.get_time_since_last_mix()
		if since_mix < previous_mix:
			break
		previous_mix = since_mix
	# 音频线程移除播放实例后，AudioServer 在主线程 update 中完成释放。
	await process_frame
	await process_frame
	print("\n=== 结果：%d 通过 / %d 失败 ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

## 起一局真场景并等布局稳定，返回 main 节点。用法：
##     var main: Node = await boot_main()
##
## 等的是 main._ready 里那一串（建桌面、发牌、HUD、开局理牌的补间）落定。
## 原先 15 个场景测试各写一份这四行，其中一份等 40 帧、没写为什么，
## 从 V1.0 起就那样；后来统一成 30 帧，而实测开局那批补间**第 19 帧就跑完了**
## （连量三次：19 / 19 / 19），30 帧里 11 帧是白等 —— 全表四十多个调用点，
## 按 headless 下单帧 16.6ms 算就是 8 秒往上。所以默认改成问机制（见 _anim_busy）。
## 哪个测试要在开局补间**跑完之前**插进去做事，传 frames 定帧并在调用处写清为什么
func boot_main(frames := -1) -> Node:
	return await boot_main_seated("", "", frames)

## 起一局并指定座位。mine/foe 留空 = 单机默认（PLAYER / BOT）。
## frames < 0 = 等到补间跑完；frames >= 0 = 只等这么多帧（要卡在中途时用）。
##
## 座位必须在 _ready 之前设好（_sync_round 按座位决定往哪半边摆），
## 而 _ready 是 add_child 那一刻跑的 —— 所以 instantiate 与 add_child
## 之间是唯一的窗口，set_seats 只能插在这里
func boot_main_seated(mine: String, foe: String, frames := -1) -> Node:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	if mine != "":
		main.set_seats(mine, foe)
	root.add_child(main)
	_booted = main
	if frames >= 0:
		for i in frames:
			await physics_frame
	else:
		# 补间是在 _ready 里建的，头一两帧还没登记上 —— 先等它忙起来再等它闲下来，
		# 不然一进来就「不忙」直接返回。上限按开局最长那条（撕牌 0.46）折算兜底
		var step: float = 1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
		var cap: int = int(ceil(1.5 / step))
		var n := 0
		while n < 3 and not _anim_busy(main):
			await physics_frame
			n += 1
		while n < cap and _anim_busy(main):
			await physics_frame
			n += 1
		for i in 2:
			await physics_frame
	_assert_booted(main)
	return main

## 最近起的那个 main。settle() 拿它问「补间跑完了没有」——
## 107 个调用点全是 `await settle()` 不带参数，加参数要改 107 处，
## 而这里记一笔就够：场景测试全都经由 boot_main_seated 起局。
## 起不来（纯引擎测试）时它是 null，settle() 退回按墙钟等
var _booted: Node = null

## 场景真的起来了吗。**不是判据，是判据的前提** —— 不过这一条必须让测试红。
##
## 起因：scenes/settle_layout.gd 里一处 `var at := _rest_pos(c)` 被改成
## `var at := c.global_position` 之后编译不过（`c` 来自 Dictionary，是 Variant，
## `:=` 推不出类型）。整份脚本没加载，main.state / main.layout 全是 nil，
## 于是每个 await 后面的小节都在 nil 上调方法 —— Godot 把这些记成
## SCRIPT ERROR 就继续跑下一行，一条断言都没执行到。
## 结果是「=== 结果：8 通过 / 0 失败 ===」，退出码 0：
## tools/run_tests.sh 看到绿，tools/mutate_check.py 看到「退出码 0，失败 0 条」
## 报了一条查无实据的 MISS。
##
## 也就是说**改到某个场景脚本编译不过时，整套测试是绿的** —— 断言一条都没跑
## 反而比断言跑了而挂掉更安静（memory: callback-script-error-doesnt-fail-test
## 的同一个形状：脚本错误在测试里是隐形的，只有它让别处的判据红了才被发现）。
##
## 查的是「被测场景的骨架都在」而不是某条业务量：nil 的成员就是「脚本没加载」
## 这件事在测试里唯一看得见的痕迹
func _assert_booted(main: Node) -> void:
	var dead: Array = []
	for m in ["state", "board", "layout", "entities"]:
		if main.get(m) == null:
			dead.append(m)
	if dead.is_empty():
		return
	check(false, "场景起得来（main.%s 是 nil —— 多半是某个场景脚本编译不过，"
		% ", main.".join(dead)
		+ "往上翻 SCRIPT ERROR：Parse Error / Compile Error）")
	finish()

## 等归位补间跑完。用法：await settle()
##
## 时长照着被等的那几个补间的源常量算，不写死：谁把 TEAR_TIME 调长了，
## 这里跟着变，不用再去四个测试里找魔法数字。**这不是判据**（判据不许读被测
## 常量，读了变异测试会全绿），是同步 —— 等多久本来就该由补间自己说。
##
## 原先四个文件各有一份 _settle()，等的时长是 0.30 / 0.45 / 0.30 / 0.4，
## 都没写为什么。其中三个短于 TEAR_TIME(0.46)：撕牌那条路径上它们本来就等不够，
## 只是那几条判据没撞上撕牌才一直是绿的。统一之后一律等够最长的那条。
##
## 要在两击之间等的，用 settle_within_dbl()：这里等得比 DBL_WINDOW 长，会把双击拆散。
##
## main.gd 用 load() 现取而不在文件头 preload：纯引擎的那几个测试
## （test_engine / test_simulator 等）不该因为 main.gd 有语法错就一起挂
##
## **不按墙钟等满，问机制**（和 arrivals_landed / bot_moves_landed 同一个理由）：
## 原先一律 create_timer(0.52)，而 107 个调用点里绝大多数身上一条补间都没在跑 ——
## 等的是个空。实测全表 229.6 秒里 test_attack_dbl 一个人占 41.8 秒，
## 40 次 settle() 有 20.8 秒是纯睡。三个机制各有可问的量：
##   飞入     卡身上的 fly_tw meta（main._fly_from 登记）
##   对手摆放 main.layout.bot_moving()
##   归位     board._move_tw 里还在跑的那些（编组重排、抬升）
## 上限仍按源常量折算兜底：补间被掐掉时记录还在但 is_running 为假，
## 真卡住也不该把测试挂死在这里。
##
## **撕牌那一项故意不等**（main._tear_until_ms）：那是飞出去的动画，
## 而 `entities.erase()` / `board.drop_card()` 在 _animate_removed 里是**同步**做完的
## —— 判据读的两个集合里早就没有那些牌了，重排补间也在同一批同步登记进 _move_tw。
## 等它的代价是真金白银：撕牌起飞时刻排在一条**共用队**上（TEAR_STAGGER 逐张 0.08s），
## B5「一次点掉点数够得着的所有张」实测把队排到 4.7 秒，而原先那 0.52s
## 压根没等够（撞得更早），也就是说没有哪条判据依赖这批撕完。
## 谁将来要等撕完，用 main._tears_drained() —— 那是生产侧自己的门（结算重画前会等）。
##
## **墙钟底线只在有一击悬着时才付**：原先那 0.52s > DBL_WINDOW(0.45)，
## 于是「点一下 → settle() → 再点一下」靠它保证第二击不算双击。
## 问机制会让这个等待缩到几毫秒，那条保证就没了 —— 所以看 board._last_click_t：
## 真有一击在窗口内才补齐到 DBL_WINDOW 之外，没有就不付这个钱。
## （这不是判据，和原来一样是同步。判据不许读被测常量）
func settle() -> void:
	var main_script: Variant = load("res://scenes/main.gd")
	var longest: float = maxf(main_script.TEAR_TIME, main_script.SPAWN_FLY_TIME)
	var main: Node = _booted
	if main == null or not is_instance_valid(main):
		# 没起过场景：没有机制可问，退回原来的墙钟
		await create_timer(longest + 0.06).timeout
		for i in 2:
			await physics_frame
		return

	var step: float = 1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
	# 兜底上限：最长那条补间的三倍。**只有卡住才该撞到这里**，
	# 正常跑完是 _anim_busy 返回假退出的
	var frames_left: int = int(ceil(longest * 3.0 / step))
	while frames_left > 0 and _anim_busy(main):
		await physics_frame
		frames_left -= 1

	# 有一击悬在 DBL_WINDOW 内 → 补齐到窗口之外，别把「点—等—点」变成双击。
	#
	# 这个 timer 必须**不跟时间缩放**（第四个参数）：`board._now()` 读的是
	# Time.get_ticks_msec，真墙钟，双击判定在 time_scale 下照旧按墙钟走
	# （双击是人手的节奏，游戏暂停时也该判得出来，所以生产侧本来就该是墙钟）。
	# 跟着缩放的话 TEST_SPEED=5 时只等够五分之一，窗口没让开，「点—等—点」
	# 就被判成双击 —— 加速反而把判据搅了
	var board: Variant = main.board
	if board != null and is_instance_valid(board):
		var since: float = board._now() - board._last_click_t
		var need: float = Board.DBL_WINDOW - since + 0.06
		if since >= 0.0 and need > 0.0:
			await create_timer(need, true, false, true).timeout

	# 补间那一帧写回位置之后再给两帧，让 _process 里的东西（吸附高亮、提示）跟上。
	# 原先是 10 帧 —— 墙钟时代的余量，那时「等完了」可能落在补间跑完之前。
	# 现在退出条件是 is_running() 为假，实测那一刻位置已经**精确等于**终点
	# （距离 0.00000，之后 20 帧一动不动），10 帧里 8 帧是白等：
	# 三处辅助共 40+ 次调用，test_attack_dbl 一个文件就省下 5 秒。
	#
	# 不要拿 linear_velocity 当「稳了没有」的条件：牌是刚体，落在桌上互相挤着，
	# 实测停在 y≈0.1 的牌速度长期在 0.1~0.97 之间抖，永远等不到 0
	for i in 2:
		await physics_frame

## 场上还有补间在跑吗。settle() 的轮询条件，三个机制各问一遍
## （撕牌不在里面，理由见 settle() 头上）
func _anim_busy(main: Node) -> bool:
	for uid in main.entities:
		var e: Variant = main.entities[uid]
		if not is_instance_valid(e) or not e.has_meta("fly_tw"):
			continue
		var tw: Variant = e.get_meta("fly_tw")
		if tw is Tween and tw.is_valid() and tw.is_running():
			return true
	if main.layout != null and is_instance_valid(main.layout) \
			and main.layout.bot_moving():
		return true
	var board: Variant = main.board
	if board != null and is_instance_valid(board):
		for c in board._move_tw:
			var rec: Variant = board._move_tw[c]
			if rec == null:
				continue
			var tw2: Variant = rec.get("tw")
			if tw2 is Tween and tw2.is_valid() and tw2.is_running():
				return true
	return false

## 等一批飞入全部落地。用法：await arrivals_landed(main)
##
## 为什么不用「SPAWN_FLY_SPREAD + SPAWN_FLY_TIME + 0.1」那个算法：那 0.1 是
## 纯余量，机器一忙就不够。补间按 process delta 走，CPU 被抢的时候同样的
## 墙钟时间内推进得更少 —— 于是「等完了」的那一刻卡还在空中，读 global_position
## 读到的是出发点，一批同时出生的卡出发点又挨得近，就报出「落点重合」。
## 实测：单跑 8/8 全绿，和全表变异抢 CPU 时 test_arrivals 的
## 「BOT 那批也各有落点」直接红了一次 —— 而基线一红，mutate_check 整轮就废了。
##
## 改成问机制本身：飞入的补间记在卡的 `fly_tw` meta 上（main.gd `_fly_from`），
## 逐帧看还有没有在跑的。等多久由「补间跑完了没有」说，跟机器快慢无关。
## 上限仍按源常量折算兜底（补间被 _cancel_fly 掐掉时 meta 还在，但 is_running 为假；
## 真卡住也不该把测试挂死在这里）。
##
## 这不是判据，和 settle() 一样是同步 —— 判据不许读被测常量。
func arrivals_landed(main: Node) -> void:
	var main_script: Variant = load("res://scenes/main.gd")
	# 兜底上限：整批错开 + 一趟飞行，再给一倍余量
	var cap: float = (main_script.SPAWN_FLY_SPREAD + main_script.SPAWN_FLY_TIME) * 2.0
	# SceneTree 上没有 get_physics_process_delta_time()，按帧数折算：
	# 物理帧率是引擎配置，取它换算出「cap 秒对应多少帧」
	var step: float = 1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
	var frames_left: int = int(ceil(cap / step))
	while frames_left > 0:
		var flying := false
		for uid in main.entities:
			var e: Variant = main.entities[uid]
			if not is_instance_valid(e) or not e.has_meta("fly_tw"):
				continue
			var tw: Variant = e.get_meta("fly_tw")
			if tw is Tween and tw.is_valid() and tw.is_running():
				flying = true
				break
		if not flying:
			break
		await physics_frame
		frames_left -= 1
	# 补间结束那一帧位置才写回，再多等两帧让物理和 global_position 对齐
	for i in 2:
		await physics_frame

## 等对手侧的归位补间跑完。用法：await bot_moves_landed(main)
##
## 和 arrivals_landed 是同一个道理，等的是另一批补间：settle() 按墙钟等，
## CPU 被抢的时候（比如变异检查在跑）补间推进得更少，等完了牌还在半路，
## 读 global_position 读到的是出发点 —— 症状是「牌没落回桌面」这种假红，
## 而基线一红整轮变异就废了（memory: flaky-baseline-kills-mutation-run）。
##
## 改成问机制本身：摆放补间记在 settle_layout 的 _bot_tw 里，逐帧问 bot_moving()。
## 上限按 BOT_MOVE_TIME 折算兜底（补间被 kill_bot_move 掐掉时也要能退出来）。
## 这不是判据，和 settle() 一样是同步
func bot_moves_landed(main: Node) -> void:
	var step: float = 1.0 / float(maxi(Engine.physics_ticks_per_second, 1))
	# 按**一趟**的时长折算（SettleLayout.bot_pass_time），不写死秒数：
	# 一趟多久由摆放那头说 —— 现在一趟等于单条补间，但这是那边的实现细节，
	# 改成分批出发时这里不该跟着改
	var frames_left: int = int(ceil(main.layout.bot_pass_time() * 3.0 / step))
	while frames_left > 0 and main.layout.bot_moving():
		await physics_frame
		frames_left -= 1
	# 补间结束那一帧位置才写回，再多等两帧让物理和 global_position 对齐
	for i in 2:
		await physics_frame

## 双击的两击之间要等的那种「等一下」。用法：await settle_within_dbl()
##
## 和 settle() 是两件事，不能合成一个数：
##   settle()            要 ≥ TEAR_TIME(0.46)，等最长的补间落地
##   settle_within_dbl() 要 < DBL_WINDOW(0.45)，否则第二击不再算双击
## 一个数满足不了两头，所以按「要等什么」分成两个名字。原先 test_attack_dbl
## 靠一个写死的 0.30 同时占着这两个位置，为什么是 0.30 没人写 —— 就是这个 <0.45。
##
## 时长按 DBL_WINDOW 折算（不是写死 0.30）：卡住的是这一条，谁调 DBL_WINDOW
## 这里跟着走。留三成余量给 _unhandled_input 到 _is_double 之间的几帧开销。
## 够不够长那头由 Board 的归位补间（0.18）说，0.66×0.45≈0.30 比它宽出一截
func settle_within_dbl() -> void:
	await create_timer(Board.DBL_WINDOW * 0.66).timeout
	for i in 4:
		await physics_frame

## 把这些卡拆出组、掐掉在飞的补间、挪去桌角冻住，好让判据只看剩下的牌。
## _stop_move 必须在改 global_position 之前：在飞的归位补间会盖掉写进去的坐标
func park(board: Board, used: Array) -> void:
	for c in used:
		if is_instance_valid(c):
			board._detach_from_group(c)
	var i := 0
	for c in used:
		if not is_instance_valid(c):
			continue
		board._stop_move(c, false)
		c.freeze = true
		c.global_position = Vector3(-14.0 - (i % 4) * 1.5, 0.2, -9.0 - float(i / 4) * 2.0)
		i += 1

## 除了 keep 里这些，桌上其他可拖的散卡一律挪到对角冻住（公共区的不动）。
## 和 park 挪去的方向相反，两边各占一角，免得清出来的卡自己挤在一处
func isolate(board: Board, keep: Array) -> void:
	var loose: Array = []
	for c in board.cards:
		if not is_instance_valid(c) or c.is_market or not c.draggable or keep.has(c):
			continue
		loose.append(c)
	for c in loose:
		board._detach_from_group(c)
	var i := 0
	for c in loose:
		board._stop_move(c, false)   # 掐掉在飞的归位补间，否则它会盖掉下面这行
		c.freeze = true
		c.global_position = Vector3(14.0 + (i % 5) * 1.5, 0.2, 9.0 + float(i / 5) * 2.0)
		i += 1

## ==================== 联机测试的公用脚手架 ====================
##
## 12 个联机测试原先各抄一份 `_pump`/`_until`/`_client`/`_boot`/`_stop`，
## 已经飘出好几种：`_pump` 11 份 4 种（差别只在 `c != null` 和
## `is_instance_valid(c)` 两道判空谁有谁没有）、`_boot` 10 份 2 种（差别只是
## 局部变量叫 `r` 还是 `res`）、`_until` 12 份 4 种（默认预算 240/300/400 各一派，
## 而**没有一份写了为什么是这个数**）。
##
## 收进来还顺手改掉一处真错，见 net_until 头上的「帧数不是墙钟」。

## 服务器（联机测试用）。`net_boot` 设它，`net_stop` 收它。
## test_embedded_host 的宿主不走 NetServer，它自己拿 `_host` 管，
## 只借这里的 net_pump —— 所以 net_pump 问的是「有没有 poll 这个方法」而不是类型
var _srv: Variant = null
var _port := 0

## 起服务器，从 base 开始往上找没被占的口。
## 扫 12 个而不是死守一个：并跑时端口会撞，而各文件的 PORT_BASE 只错开 20~40
func net_boot(base: int, seed_value := 0) -> bool:
	net_stop()
	for i in 12:
		var s := NetServer.new(seed_value)
		var r: Dictionary = s.start(base + i)
		if r["ok"]:
			_srv = s
			_port = int(r["port"])
			return true
	check(false, "起不了服务器（%d..%d 都被占）" % [base, base + 11])
	return false

func net_stop() -> void:
	if _srv != null:
		_srv.stop()
		_srv = null

## 接一个客户端。ping/silent 留 0 = 用生产默认（3.0 / 10.0）；
## 判活那类测试要把它们压小，不然一条判据就得等十秒墙钟
func net_client(room := "TEST", token := "", ping_every := 0.0,
		silent := 0.0) -> NetTransport:
	var c := NetTransport.new("ws://127.0.0.1:%d" % _port, room)
	if token != "":
		c.resume_token = token
	if ping_every > 0.0:
		c.ping_every_sec = ping_every
	if silent > 0.0:
		c.silent_sec = silent
	c.connect_to_server()
	return c

## 起服务器 + 两条连接并等到双方入座。返回 [a, b]，任一步没成返回 []。
##
## 原先 11 份（10 个文件，test_net_resume_piles 里两份）各抄一遍这七行，
## 其中 test_net_piles 和 test_net_resume_piles 的 _seated_scene 逐字节相同。
## 各文件自己那个 _seated_pair / _seated_scene 壳子留着没动 —— 41 个调用点
## 的参数次序各是各的（`(room, seed)` 和 `(seed, room)` 两种都有），
## 统一次序要改 41 处，而那两个参数都带类型、传反了当场编译不过，
## 所以次序不齐是难看不是隐患，不值得为它动 41 处
##
## mk 留空 = 用 net_client(room)。判活那类要压 ping/silent 的、
## 或者要裸 NetTransport 的，自己传个工厂进来
func net_seated_pair(base: int, seed_value: int, room: String,
		mk := Callable()) -> Array:
	if not net_boot(base, seed_value):
		return []
	var a: NetTransport = mk.call(room) if mk.is_valid() else net_client(room)
	var b: NetTransport = mk.call(room) if mk.is_valid() else net_client(room)
	if not await net_until([a, b], func(): return a.my_seat != "" and b.my_seat != ""):
		check(false, "双方都入座了（a=%s b=%s）" % [a.my_seat, b.my_seat])
		return []
	return [a, b]

## 上面那个 + 一份真场景接在 a 上，返回 [main, a, b]。
## require_seat 非空 = 顺带钉住场景那一侧的座位（有些判据只在 A 座成立）。
##
## 三道前提缺一不可，第三道是**踩过的**：
## 桌子是 seated 摆的，阶段是另一条消息（Protocol.phase），服务器同一批发出去
## 但不保证客户端同一次 poll 读全。少这一道的后果不是「等得不够」而是
## **判据被换掉** —— 接管取的 keep_phase 就是这条连接的 _phase，它空的话
## adopt 进去的是空阶段，服务器随后补给对手的也就是 `phase("", "")`，
## 于是 test_host_takeover 的 T4/T6/T8 一起红、报的却是「服务器没补 phase」，
## 而服务器补了，补的是一份空的。60Hz 下两条几乎总是同一次 poll 到，
## 所以从写下那天起就没露头，是把物理频率抬到 300Hz 之后才现形的
func net_seated_scene(base: int, seed_value: int, room: String,
		require_seat := "") -> Array:
	var pair: Array = await net_seated_pair(base, seed_value, room)
	if pair.is_empty():
		return []
	var a: NetTransport = pair[0]
	var b: NetTransport = pair[1]
	if require_seat != "" and not need(a.my_seat == require_seat,
			"场景那一侧坐的是 %s 座（实为 %s）" % [require_seat, a.my_seat]):
		return []
	var main: Node = await boot_main()
	main.begin_net_game(a)
	if not await net_until([a, b], func(): return main.entities.size() > 0):
		check(false, "照服务器那份快照把桌子摆出来了（实为 %d 张）" % main.entities.size())
		return []
	if not await net_until([a, b], func(): return a.phase() != ""):
		check(false, "第一个行动阶段也到了（实为「%s」）" % a.phase())
		return []
	return [main, a, b]

## 泵 frames 帧：服务器和每个客户端各 poll 一次，然后过一帧。
## 判空两道都留着（`null` 和已释放）—— 原先 11 份里各有各的漏，
## 而漏掉的那一份在客户端被 free 之后 poll 会当场崩
func net_pump(clients: Array, frames := 1) -> void:
	for i in frames:
		if _srv != null and _srv.has_method("poll"):
			_srv.poll()
		for c in clients:
			if c != null and is_instance_valid(c):
				(c as NetTransport).poll()
		await physics_frame

## 泵到 cond 成立，最多等 ms 毫秒**墙钟**。返回它最后成不成立。
##
## **帧数不是墙钟**：原先 12 份都写成 `frames := 240/300/400`，等的却是
## 真 socket 的往返和 silent_sec 这类墙钟量 —— 两者之间没有固定换算
## （test_net_liveness 的 _pump_for 头上就写着这句，但 _until 自己没照办）。
## 平时 60Hz 下 240 帧≈4 秒够用，所以一直没暴露；把物理频率抬上去
## （TEST_SPEED=5 → 300Hz）之后 200 帧只剩 0.67 秒，
## test_host_takeover 的 T8 当场红两条：服务器补的那条 phase 还在路上。
## 现在按毫秒等，频率怎么调都是同一个墙钟预算
func net_until(clients: Array, cond: Callable, ms := 4000) -> bool:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		if cond.call():
			return true
		await net_pump(clients)
	return cond.call()

## 泵到 cond 成立，不设上限。给「一定会发生，只是不知道第几帧」的那些用；
## 真不发生就让测试挂在这里（比默默超时往下跑好定位）
##
## 这个**故意有不带 await 的调法**（8 处：test_net_attack_flow 4、test_resign 2、
## test_foe_offline 1、test_host_takeover 1），长得像漏写而不是：
##     _flag = false
##     net_pump_until([a, b], func(): return _flag)   # 不 await —— 后台泵着
##     var r: Dictionary = await t.submit(...)        # 这一句要有人泵才回得来
##     _flag = true                                   # 泵到这里自己停
## 不带 await 的协程会被 physics_frame 信号一路唤醒、在后台跑到条件成立
## （实测 30 帧里跑了 31 圈，置 flag 后停）。这里加 await 是**死锁**：
## 停止条件在它后面一行才置上。
## submit 自己那个等待循环只 poll 它自己那条连接，对手那条得靠这个后台泵
func net_pump_until(clients: Array, done: Callable) -> void:
	while not done.call():
		await net_pump(clients)

## 泵满 ms 毫秒墙钟。判活的判据只能这么等：silent_sec 是墙钟量
func net_pump_for(clients: Array, ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await net_pump(clients)

## 造一摞：核心卡 + n-1 张现金，清场后拆成散卡返回，交给判据自己摆
func make_stack(main: Node, board: Board, uid0: int, core_id: String, n: int,
		also_keep: Array = []) -> Array:
	var members: Array = []
	members.append(main._spawn_entity(
		{ "uid": uid0, "def_id": core_id }, Vector3(-6.0, 0.05, 4.0), true))
	for i in n - 1:
		members.append(main._spawn_entity(
			{ "uid": uid0 + 1 + i, "def_id": "cash" }, Vector3(-6.0, 0.05, 4.0), true))
	isolate(board, members + also_keep)
	for c in members:
		board._detach_from_group(c)
	return members


## ---- 同名升级阶梯：从卡表现算，判据别自己抄一份 ----
## 放在 harness 而不是某个判据里，是因为盯这套阶梯的判据不止一个
## （test_dup_upgrade 判规则、test_hover_desc 判说明文案），
## 各抄一份就等于同一个档位表在仓库里存了两遍

## 传说卡阶梯 {同名 T2 张数: 传说卡 id}，取自卡表 `upgrade_from == dup_t2` 那几张
func dup_ladder() -> Dictionary:
	var out: Dictionary = {}
	for def_id in CardDB.all_cards():
		var d: Dictionary = CardDB.get_def(def_id)
		if str(d.get("upgrade_from", "")) == CardDB.DUP_T2:
			out[int(d["upgrade_dup_n"])] = def_id
	return out


## 把张数数组拼成提示里那种 "2/3/4"
func dup_slashed(ns: Array) -> String:
	var parts: PackedStringArray = []
	for n in ns:
		parts.append(str(n))
	return "/".join(parts)


## 反查某张 T1 对应的 T2（T2 用 upgrade_from 指回 T1 的卡面 id）。
## 没有对应 T2 的 T1（春晚冠名）返回空串 —— 它只剩直达传说这一条路
func t2_of(t1_id: String) -> String:
	for def_id in CardDB.all_cards():
		if str(CardDB.get_def(def_id).get("upgrade_from", "")) == t1_id:
			return def_id
	return ""
