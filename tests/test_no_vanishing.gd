# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## 「提示不许自己消失」+「录像存在 ~/.niumapai_record」。
##
## 现行要求：录像保存在当前用户的 `~/.niumapai_record`，不使用 Application Support；
## 游戏提示持续可见，并能从提示记录中回看。
## T6 校验录像目录由 HOME 推导，不依赖具体机器或用户名。
## `use_custom_user_dir` 仍将目录置于 Application Support，因此录像路径绕开 `user://`。
##
## 提示展示和记录分别覆盖两种需求：
##
##   - **看不清楚** → 提示条不淡出（T1/T2）。开局那句「第 1 回合 · 你先手」
##     几十帧之后还在，读多久是玩家的事
##   - **无法复现** → 光不淡出治不了这一半（T3/T4/T5）。两条提示前后脚来的话
##     第一条照旧是被顶掉，所以每一条都同时进右下角那份记录
##
## 四种一眼看不出来的坏法，各有判据钉着：
##
##   1. 补间去了但 alpha 留在 0 —— 字在那儿，看不见。T1 钉 modulate.a
##   2. 提示条常驻了但还在老位置（顶部中间 600 宽），于是永久盖着对手牌区。
##      T2 钉它的**父子关系**在资源面板里，不是钉坐标
##   3. 记录里少几行，而少的原因是卡名里带了个 `[` 被当 bbcode 吃掉。
##      T4 专门喂一条带方括号的
##   4. 展开/收起只钉了一头。T3 两头都钉（这条是 bot_panel 那个 bug 的原样）
##
## T6 校验实际录像路径位于 `$HOME/.niumapai_record`，不与硬编码的个人目录比较，
## 保证测试可以在不同机器和用户环境中运行。

func _initialize() -> void:
	print("=== 不消失的提示 / 录像存在 ~/.niumapai_record ===")
	CardDB.ensure_loaded()
	await _t1_message_does_not_fade()
	await _t2_message_lives_in_res_panel()
	await _t3_log_toggles_both_ways()
	await _t4_every_message_is_kept()
	await _t5_log_is_capped_but_counts_all()
	await _t6_replays_live_under_home_dir()
	await _t7_expiring_state_gets_replaced_not_blanked()
	finish()


## 开局那句话，几十帧之后还在。
##
## 这是用户报的那一条的**原样回归**：他看到的是「出现了一行字又消失了」。
## 所以判据不是「_show_message 之后 text 对不对」（那一刻当然对，
## 从前也对），而是**等**——等到从前那条补间早该淡完的时候再看
func _t1_message_does_not_fade() -> void:
	print("\n-- T1 提示条不会自己消失 --")
	var main: Node = await boot_main()
	# 开局第一句是 _begin_action_phase 发的。先确认它真发了 ——
	# 「一条都没发」和「发了又淡了」在空文本上长得一样
	if not need(main.lbl_msg.text != "", "开局有一句提示"):
		return
	var opening: String = main.lbl_msg.text
	check(opening.contains("回合"), "开局那句里有回合数（实际「%s」）" % opening)
	check(main.lbl_msg.modulate.a == 1.0,
		"这一刻是**实心**的（alpha=%.2f）" % main.lbl_msg.modulate.a)

	# 从前是 MSG_HOLD 2.0 + MSG_FADE 0.6 = 2.6 秒。按 60 帧算是 156 帧,
	# 这里跑 200 帧，比那条补间的全长还多出一截
	for _i in range(200):
		await process_frame
	check(main.lbl_msg.text == opening,
		"200 帧之后**还是那句**（实际「%s」）" % main.lbl_msg.text)
	# alpha 才是那条补间留下的指纹。text 没变而 alpha 掉到 0 的话,
	# 屏幕上是空的而判据全绿 —— 这正是「补间删了但 alpha 忘了推回来」那个坏法
	check(main.lbl_msg.modulate.a == 1.0,
		"而且**看得见**：alpha 还是 1（实际 %.2f）" % main.lbl_msg.modulate.a)
	check(main.lbl_msg.visible, "标签自己也是显示着的")

	# 树上不许有拿它当靶子的补间。这条钉的是机制而不是结果 ——
	# 有人把补间加回来、只是把终值从 0 改成 1 的话，上面几条照旧全绿
	var tweens: int = 0
	for t in main.get_tree().get_processed_tweens():
		if not is_instance_valid(t):
			continue
		# Tween 不给「你动的是谁」这个问法，所以退一步：跑完这一帧之后
		# alpha 有没有被人动过。上面已经确认它是 1，这里只要它别掉下来
		tweens += 1
	await process_frame
	check(main.lbl_msg.modulate.a == 1.0,
		"再跑一帧也没人把它的 alpha 拽下来（树上 %d 条补间）" % tweens)


## 提示条住在左上角那块面板里，不在顶部中间。
##
## 为什么这条得单独钉：不淡出之后它就常驻了，而它原来的位置是
## 顶部中间 600 宽 28 号 —— 那儿底下是对手牌区和公共区标价。
## 从前「盖着」只有 2.6 秒，现在会盖一整局。
##
## 判据用**父子关系**，不用坐标：坐标那条会被窗口尺寸、面板内容长短带得乱动,
## 而「它在不在这块面板里」是这条改动真正要保住的东西
func _t2_message_lives_in_res_panel() -> void:
	print("\n-- T2 提示条住在底部状态栏 --")
	var main: Node = await boot_main()
	var found: Array = main.find_children("StatusPanel", "PanelContainer", true, false)
	if not need(found.size() == 1, "找到独立底部状态栏（%d）" % found.size()):
		return
	var pc: PanelContainer = found[0]
	check(pc.is_ancestor_of(main.lbl_msg), "提示条在底部状态栏里")
	check(main.lbl_msg.get_parent() is PanelContainer,
		"提示使用底栏容器布局（父节点 %s）" % main.lbl_msg.get_parent().get_class())
	check(main.lbl_msg.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"不吃鼠标事件（mouse_filter=%d）" % main.lbl_msg.mouse_filter)
	main._show_message("这是一条很长的提示，用来验证完整内容仍可从提示记录和悬停提示里读取", Palette.semantic("info"))
	check(main.lbl_msg.clip_text and main.lbl_msg.tooltip_text == main.lbl_msg.text,
		"底栏单行省略时保留完整悬停提示")
	await settle()
	check(pc.get_global_rect().position.y > root.size.y * 0.8,
		"常驻状态栏停在底部，避免遮挡对手牌区")
	main.queue_free()


## 记录那一块，展开和收起**两头都钉**。
##
## 只钉一头是这仓库栽过的跟头（用户原话「BOT强度tab无法正确展开和收齐」）：
## 「按一下变大」写了判据，「再按一下没缩回去」那一路没人看着
func _t3_log_toggles_both_ways() -> void:
	print("\n-- T3 记录面板展得开也收得齐 --")
	var main: Node = await boot_main()
	if not need(main.msg_log != null, "记录面板搭起来了"):
		return
	var log_panel = main.msg_log
	await settle()

	# 默认收起。理由是它在右下角、压着玩家自己的桌面区（见 scenes/msg_log.gd）
	check(not log_panel.expanded(), "开局是**收起**的")
	var frame: PanelContainer = log_panel.get_node_or_null("Frame")
	if not need(frame != null, "找到 Frame"):
		return
	check(frame.mouse_filter == Control.MOUSE_FILTER_STOP,
		"Frame 吃鼠标事件（要点展开钮、要选文本）")
	var h_collapsed: float = frame.size.y

	# 收起态得**说得出自己藏了什么**。光写「提示记录」的话，
	# 玩家没理由相信他刚错过的那行在里头
	var head_txt: String = log_panel._title.text
	check(head_txt.contains("条"), "标题栏报了条数（实际「%s」）" % head_txt)
	check(log_panel._toggle.text == "展开", "钮上写着「展开」")

	log_panel._toggle.emit_signal("pressed")
	await settle()
	check(log_panel.expanded(), "按一下 → 展开了")
	check(log_panel._toggle.text == "收起", "钮上改成「收起」")
	var h_open: float = frame.size.y
	check(h_open > h_collapsed + 100.0,
		"框子真的撑开了（%.0f → %.0f）" % [h_collapsed, h_open])

	log_panel._toggle.emit_signal("pressed")
	await settle()
	check(not log_panel.expanded(), "再按一下 → 收回去了")
	check(log_panel._toggle.text == "展开", "钮上又是「展开」")
	check(absf(frame.size.y - h_collapsed) < 2.0,
		"框子也缩回原来那么高（%.0f，原 %.0f）" % [frame.size.y, h_collapsed])


## 说过的每一句都在记录里，包括被下一句顶掉的那些。
##
## 这条治的是用户那半句「无法复现」。提示条只留最后一句 ——
## 两条前后脚来的话（「买不起」紧跟着对手行动那句），第一条在屏幕上没了,
## 而它得在记录里找得回来
func _t4_every_message_is_kept() -> void:
	print("\n-- T4 被顶掉的那句在记录里找得回来 --")
	var main: Node = await boot_main()
	if not need(main.msg_log != null, "记录面板在"):
		return
	var log_panel = main.msg_log
	var before: int = log_panel.total()

	main._show_message("第一句：买不起", Color(1, 0.5, 0.5))
	main._show_message("第二句：对手买了卡", Color(1, 0.8, 0.5))
	await settle()

	# 屏幕上只剩最后一句 —— 这不是 bug，是提示条的定义
	check(main.lbl_msg.text == "第二句：对手买了卡",
		"提示条上是最后那句（实际「%s」）" % main.lbl_msg.text)
	var body: String = log_panel.plain_text()
	check(body.contains("第一句：买不起"), "**被顶掉的第一句还在记录里**")
	check(body.contains("第二句：对手买了卡"), "第二句也在")
	check(log_panel.total() == before + 2,
		"条数涨了 2（%d → %d）" % [before, log_panel.total()])

	# 记录里带回合数。翻回去的时候「这是第几回合的事」是唯一有用的定位
	check(body.contains("回合"), "每条都带回合数")

	# **真标签**。喂的是 `[b]` 这种 RichTextLabel 认得的东西 ——
	# 房间码是玩家自己敲进去的（join_panel → _show_waiting_as_host →
	# _show_message），敲成什么样都有可能，而这条路上没人洗过。
	#
	# 喂 `[百亿补贴]` 那种**测不出来**：tools/_bb_probe.gd 实测过，
	# 它不是个认得的标签，转不转义存下来都一模一样。要红就得挑真标签：
	# 不转义的话 `[b]` 本身被吃掉，我自己那个 `[/color]` 还会漏进正文
	main._show_message("房间 [b]，端口 8910", Color(0.6, 1, 0.6))
	await settle()
	var after: String = log_panel.plain_text()
	var tail: String = after.substr(maxi(0, after.length() - 40))
	check(after.contains("[b]"),
		"真标签原样留着、没被当格式吃掉（记录尾部「%s」)" % tail)
	check(not after.contains("[/color]"),
		"**我自己那个结束标签没漏进正文**（漏出来说明前面那个 `[` 把它拆了）")
	check(after.contains("端口 8910"), "方括号后面那半截也在（吃标签就是从这儿断的）")

	# 空串不记。有几处调用点会传空（清场那类），记进去是一行空白占位
	var n: int = log_panel.total()
	main._show_message("", Color.WHITE)
	await settle()
	check(log_panel.total() == n, "空话不记（还是 %d 条）" % log_panel.total())


## 记录有上限，但**计数器不封顶**。
##
## 上限是为了别让 RichTextLabel 攒到几百行之后越按越卡。
## 而标题栏报的数得是「一共说过几句」——报「现在存着几条」的话
## 上限一到数字就不动了，而玩家读它是当计数器读的
func _t5_log_is_capped_but_counts_all() -> void:
	print("\n-- T5 记录封顶但计数器不封顶 --")
	var main: Node = await boot_main()
	if not need(main.msg_log != null, "记录面板在"):
		return
	var log_panel = main.msg_log
	var cap: int = log_panel.MAX_LINES
	var base: int = log_panel.total()
	for i in range(cap + 20):
		main._show_message("压力条 %d" % i, Color.WHITE)
	await settle()

	check(log_panel.total() == base + cap + 20,
		"计数器照数（%d 条）" % log_panel.total())
	var lines: int = log_panel._body.get_line_count()
	check(lines <= cap + 2, "存着的行数封在上限附近（%d 行，上限 %d）" % [lines, cap])
	var body: String = log_panel.plain_text()
	# 丢的得是**最旧**那头。丢错头的话「翻回去看刚才发生了什么」正好落空
	check(body.contains("压力条 %d" % (cap + 19)), "最新那条在")
	check(not body.contains("压力条 0"), "最旧那条被挤掉了（丢的是旧的那头）")

	# **框子还在屏幕里**。这一条挂在 T5 上是因为只有这儿条数真的涨到三位数:
	# 标题从「· 1 条」长到「· 221 条」，框子的最小宽度跟着变宽，
	# 而它的 offset 是按**当时**那个宽度算的负数（贴右下角）。
	# 没人重算 offset 的话它就按老宽度贴着，多出来的那点捅出右边界 ——
	# 实测差 17 像素（tools/_relayout_probe.gd）。
	#
	# 靠的是 _ready 里那条 minimum_size_changed 连接。别指望展开/收起那条路
	# 替它把这事兜住：那条路只在玩家去点的时候跑，而条数是自己涨的
	var frame: Control = log_panel._frame
	var vp_w: float = main.get_viewport().get_visible_rect().size.x
	var right: float = frame.global_position.x + frame.size.x
	check(right <= vp_w,
		"框子右边缘没捅出屏幕（右边缘 %.1f ≤ 屏宽 %.1f）" % [right, vp_w])
	check(is_equal_approx(frame.position.x, -frame.size.x - log_panel.MARGIN),
		"offset 跟着宽度重算过了（该在 %.1f，实际 %.1f）"
			% [-frame.size.x - log_panel.MARGIN, frame.position.x])


## 录像存在 `~/.niumapai_record`，**不在** Application Support 底下。
##
## 这条路绕开了 `user://`：那个前缀落在哪儿是引擎定的，
## `use_custom_user_dir` 只换得掉最后一层目录名，换不掉上面那几层。
##
## 同时验证路径不含 Application Support，并位于 HOME 下的 `.niumapai_record`；
## 不硬编码个人目录，以兼容不同机器和用户名。
func _t6_replays_live_under_home_dir() -> void:
	print("\n-- T6 录像存在 ~/.niumapai_record --")
	var main: Node = await boot_main()
	var home: String = OS.get_environment("HOME")
	if not need(home != "", "拿到家目录（HOME）"):
		return

	# 默认产品路径只读验证；任何实际保存都必须恢复测试沙箱。
	var saved_override: String = Tape.directory_override
	Tape.directory_override = ""
	var default_dir: String = Tape.path_dir()
	Tape.directory_override = saved_override
	check(default_dir == home.path_join(".niumapai_record"),
		"录像目录就是 ~/.niumapai_record（实际 %s）" % default_dir)
	check(not default_dir.contains("Application Support"),
		"不在 Application Support 底下（用户点名要挪走的就是这儿）")
	check(not default_dir.contains("app_userdata"), "也没有 app_userdata 那一层")
	# `~` 得自己展开。不展开的话这里会是一个真叫 `~` 的相对目录 ——
	# 落在进程的工作目录底下，也就是**仓库根**，而路径照样报得出来
	check(not default_dir.contains("~"), "`~` 展开过了（没展开会存进仓库根）")
	check(default_dir.begins_with("/"), "是绝对路径（实际「%s」）" % default_dir)

	# 光看常量不算 —— 真存一次，看**面板上念出来的那条**。
	# 那条才是玩家会拿去 Finder 里找的东西
	var dir: String = Tape.path_dir()
	if not need(dir == ProjectSettings.globalize_path("user://replays"), "实际保存前确认录像目录在测试沙箱"):
		return
	main._save_replay()
	await settle()
	var notice: SaveNotice = main.save_notice
	if not need(notice != null and notice.visible, "存录像面板立起来了"):
		return
	var shown: String = notice._path_edit.text
	check(shown.begins_with(dir + "/"),
		"念出来的那条就在录像目录底下（实际「%s」）" % shown)
	check(shown.begins_with(_test_data_dir + "/"),
		"面板显示的实际录像文件在独立测试目录")
	# 存在不存在。路径漂亮但文件不在那儿，是这一条最难查的坏法
	check(FileAccess.file_exists(shown), "而且那个文件真在那儿")
	DirAccess.remove_absolute(shown)

	# **目录还不存在的时候也得存得下来**（第一次玩的人就是这个情形）。
	#
	# 切到沙箱内还未创建的目录，验证首次保存会建目录；不改 HOME。
	var sandbox: String = "user://first-recording-%d" % Time.get_ticks_usec()
	Tape.directory_override = sandbox
	var fresh_dir: String = Tape.path_dir()
	check(fresh_dir == ProjectSettings.globalize_path(sandbox),
		"首次保存目录位于指定沙箱（实际 %s）" % fresh_dir)
	check(not DirAccess.dir_exists_absolute(fresh_dir), "那底下这个目录还不存在")
	var t := Tape.new()
	var fresh_path: String = t.save("_first_run.json")
	Tape.directory_override = saved_override
	check(fresh_path != "", "目录不存在也存得下来（自己把目录建出来）")
	check(FileAccess.file_exists(fresh_path),
		"而且文件真落在那儿（实际「%s」）" % fresh_path)
	# 扫干净：只清理这次测试创建的目录。
	if fresh_path != "":
		DirAccess.remove_absolute(fresh_path)
	DirAccess.remove_absolute(fresh_dir)
	check(Tape.path_dir() == dir and OS.get_environment("HOME") == home,
		"录像沙箱恢复，HOME 始终未改（别把后面几节带跑偏）")


## 会过期的提示，到期时**换一句**，不是清空。
##
## 「再点一下就认输了」描述的是一个 4 秒后失效的状态。提示条现在常驻,
## 不管它的话按钮早复原了而屏幕上还挂着一句已经失效的话。
##
## 而换掉不能用「清空」来做 —— 清空就是凭空消失，正是用户要杜绝的那件事
func _t7_expiring_state_gets_replaced_not_blanked() -> void:
	print("\n-- T7 过期的提示换一句，不是清空 --")
	var main: Node = await boot_main()
	if not need(main.btn_resign != null, "认输按钮在"):
		return
	main._on_resign_pressed()
	await settle()
	check(main._resign_armed, "第一下 → 进了「再点一下」那个状态")
	var armed_msg: String = main.lbl_msg.text
	check(armed_msg.contains("认输"), "提示条说了这事（实际「%s」）" % armed_msg)

	# 等过 RESIGN_ARM_HOLD。用真定时器，因为 _on_resign_pressed 里那条 await
	# 就是 create_timer —— settle() 等的是补间，等不着它
	await create_timer(main.RESIGN_ARM_HOLD + 0.4).timeout
	await settle()
	check(not main._resign_armed, "到期了 → 状态退了")
	check(main.btn_resign.text == main.TXT_RESIGN, "按钮字也复原了")
	# 关键的两条：换了，而且**没被清空**
	check(main.lbl_msg.text != armed_msg,
		"提示条换了一句（不再是那句失效的话）")
	check(main.lbl_msg.text != "", "而且不是清空 —— 说的是「取消了」而非什么都不说")
	check(main.lbl_msg.modulate.a == 1.0, "新那句也是看得见的")
	# 两句都在记录里：说出去的话和收回的话都留着
	var body: String = main.msg_log.plain_text()
	check(body.contains(armed_msg), "armed 那句在记录里")
