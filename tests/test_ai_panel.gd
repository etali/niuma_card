# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

## AI 参数面板（`scenes/ai_panel.gd`）—— 玩家真的能在对局中途调 AI 强度吗
##
## 为什么单独立一个文件：`tests/test_ai_search.gd` 判的是**参数对象**
## （梯子、覆盖、会话隔离），它对面板只有两条静态判据（档位名有没有中文标签、
## 每个旋钮有没有列出来）。而「玩家点得到、点了有用」这一段原先没有任何观察点 ——
## 实测把 `scenes/main.gd` 里 `canvas.add_child(aip)` 那一行删掉，
## 55 个测试文件一条不红：面板从此不在画面上，参数层的判据照旧全绿。
## 那正是 `net/` 那一层踩过的坑的同款（测试全绿而玩家点不到，
## 见 `scenes/join_panel.gd` 文件头），所以这里从**booted 出来的树**里找面板，
## 不自己 new 一个 —— new 出来的那个证明不了它在玩家的画面上。
##
## 面板的信号是自己连的（`_build` 里 `pressed.connect` / `value_changed.connect`），
## 所以判据一律**发信号**驱动：`emit_signal("pressed")` / 改 `value`，
## 不直接调 `_on_xxx`。直接调私有函数的话，把 connect 那一行删掉这些判据全绿。
##
## AI 设置仅保留本次运行；面板操作和模拟重启都不应产生持久参数文件。


func _initialize() -> void:
	print("=== AI 参数面板测试 ===")
	AISearch.restore_defaults()

	var main: Node = await boot_main()
	var panel := _find_panel(main)
	if not need(panel != null, "AI 参数面板在场景树里（玩家点得到）"):
		_restore()
		finish()
		return

	await _t_placement(main, panel)
	await _t_toggle(panel)
	await _t_palette_toggle(main)
	_t_slider_drives_prefs(panel)
	_t_syncing_guard(panel)
	_t_knob_rows(panel)
	_t_presets(panel)
	_t_session_and_reset(panel)
	await _t_takes_effect_mid_match(main, panel)

	_restore()
	finish()


## 从 booted 的树里按类型找，不按节点名找：名字是 `_ready` 里设的，
## 而这一条要证明的是「这个类的实例挂在画面上」
func _find_panel(main: Node) -> AIPanel:
	for n in _walk(main):
		if n is AIPanel:
			return n as AIPanel
	return null


func _walk(n: Node) -> Array:
	var out: Array = [n]
	for c in n.get_children():
		out.append_array(_walk(c))
	return out


## 贴在配色面板下方、不与它重叠。
## 这一条是实打实修过的 bug 的判据：面板高度是折叠状态算出来的，
## 记一个常量偏移的话配色面板一展开两块就叠在一起（ai_panel.gd `above` 那条注释）
func _t_placement(main: Node, panel: AIPanel) -> void:
	var pal: Control = null
	for n in _walk(main):
		if n is PalettePanel:
			pal = n as Control
			break
	if not need(pal != null, "配色面板也在树里（AI 面板贴在它下面）"):
		return
	check(panel.above == pal, "AI 面板认的 above 就是配色面板那一块")
	check(panel.offset_top >= pal.offset_bottom,
		"AI 面板在配色面板下方，不重叠（配色底 %.0f，AI 顶 %.0f）" % [
			pal.offset_bottom, panel.offset_top])
	check(panel.offset_bottom > panel.offset_top,
		"面板有非零高度（不设 offset_bottom 的话 Control 高度是 0，里头撑不开）")
	check(panel.offset_right < 0.0 and panel.offset_left < panel.offset_right,
		"锚在右上角（offset 都是负数，左 %.0f 右 %.0f）" % [
			panel.offset_left, panel.offset_right])

	# 配色面板展开 → AI 面板要跟着往下走。连的是 above.resized，
	# 不是记常量：改成常量偏移这一条会红
	var before := panel.offset_top
	var pal_h := pal.offset_bottom
	pal.offset_bottom = pal_h + 120.0     # 假装它展开了
	await process_frame
	await process_frame
	check(panel.offset_top > before,
		"配色面板变高之后 AI 面板跟着下移（%.0f → %.0f）" % [before, panel.offset_top])
	pal.offset_bottom = pal_h
	await process_frame
	await process_frame


## 折叠 / 展开。收起状态下档位读数仍要看得见 ——
## 「现在 AI 有多强」是收起时唯一还能读到的信息
func _t_toggle(panel: AIPanel) -> void:
	var body: VBoxContainer = panel._body
	var toggle: Button = panel._toggle
	check(not body.visible, "面板默认收起（开局不挡画面）")
	check(panel._slider_val.get_parent() != body,
		"档位读数在标题栏里，收起时也看得见")

	var h_closed := panel.offset_bottom - panel.offset_top
	toggle.emit_signal("pressed")
	await process_frame
	await process_frame
	check(body.visible, "点标题栏按钮展开")
	check(toggle.text == "收起", "按钮文案跟着状态走（现在是「%s」）" % toggle.text)
	var h_open := panel.offset_bottom - panel.offset_top
	check(h_open > h_closed,
		"展开后面板变高（%.0f → %.0f）—— 高度是现算的，不是常量" % [h_closed, h_open])

	toggle.emit_signal("pressed")
	await process_frame
	await process_frame
	check(not body.visible and toggle.text == "展开", "再点一次收起")
	# 收起那一头**要钉回实测值**，不能只写 h < h_open。
	# 原先这里只查 visible 和文案，框子高度没人看 —— 于是
	# 「按钮写着展开、底下压着一大片空框子」这个 bug 一路绿着发了出去
	var h_reclosed := panel.offset_bottom - panel.offset_top
	check(absf(h_reclosed - h_closed) < 0.5,
		"收起后框子缩回原高（%.0f → %.0f → %.0f）" % [h_closed, h_open, h_reclosed])

	# 中间不过帧地连按两下：显隐、文案、框子必须始终是同一个状态。
	# 这里**故意一帧都不留** —— 原先的实现在改完 visible 之后 await 一帧再重算
	# 框子，那一帧里三者是不一致的，协程没恢复就永久停在那个样子
	for i in 4:
		toggle.emit_signal("pressed")
		var pc: PanelContainer = panel.get_node("Frame")
		var want: Vector2 = pc.get_combined_minimum_size()
		var h: float = panel.offset_bottom - panel.offset_top
		var w: float = panel.offset_right - panel.offset_left
		check(absf(h - want.y) < 0.5 and absf(w - want.x) < 0.5,
			"连按第 %d 下之后当帧就自洽（body=%s 按钮「%s」框子 %.0fx%.0f 内容 %.0fx%.0f）"
				% [i + 1, body.visible, toggle.text, w, h, want.x, want.y])
		check(body.visible == (toggle.text == "收起"),
			"第 %d 下：显隐和文案同帧一致" % [i + 1])
	await process_frame

	# 不碰开关、只改内容：框子也要跟着长。
	# 漏的那处是 _sync_rows —— 有逐项覆盖时档位读数多一个星号，
	# 收起态下标题栏就是整个面板，实测内容要 141 宽而框子还停在 134
	if body.visible:
		toggle.emit_signal("pressed")
		await process_frame
	var knobs: Array = AISearch.editable_knobs()
	var kk: Dictionary = knobs[0]
	AISearch.set_override(str(kk["key"]),
		true if str(kk["kind"]) == "bool" else int(kk.get("max", 3)))
	panel._sync_rows()
	await process_frame
	var pc2: PanelContainer = panel.get_node("Frame")
	var w2: float = panel.offset_right - panel.offset_left
	check(panel._slider_val.text.ends_with("*"),
		"有逐项覆盖时读数带星号（现在是「%s」）" % panel._slider_val.text)
	check(absf(w2 - pc2.get_combined_minimum_size().x) < 0.5,
		"读数变长之后框子跟着变宽（框子 %.0f 内容 %.0f）—— 不然星号被切掉"
			% [w2, pc2.get_combined_minimum_size().x])
	AISearch.restore_defaults()
	panel._sync_rows()
	await process_frame

	# 展开着做后面的判据，方便出错时截图能看见
	toggle.emit_signal("pressed")
	await process_frame
	await process_frame


## 选色面板（`scenes/palette_panel.gd`）的展开 / 收起。
##
## 判据放在这个文件里而不是另立一个：它和 AI 面板是**同一个缺陷的两处**
## （`_on_toggle` 里 await 一帧再重算框子），共用这一棵 booted 出来的树。
## 只钉框子和内容自洽，不碰配色本身 —— 那一层有别的文件管
func _t_palette_toggle(main: Node) -> void:
	var pal: PalettePanel = null
	for n in _walk(main):
		if n is PalettePanel:
			pal = n as PalettePanel
	if not need(pal != null, "选色面板也在场景树里"):
		return
	var pc: PanelContainer = pal.get_node("Frame")
	var h0 := pal.offset_bottom - pal.offset_top
	for i in 4:
		pal._toggle.emit_signal("pressed")
		var want: Vector2 = pc.get_combined_minimum_size()
		var h: float = pal.offset_bottom - pal.offset_top
		var w: float = pal.offset_right - pal.offset_left
		check(absf(h - want.y) < 0.5 and absf(w - want.x) < 0.5,
			"选色面板连按第 %d 下当帧就自洽（框子 %.0fx%.0f 内容 %.0fx%.0f）"
				% [i + 1, w, h, want.x, want.y])
		check(pal._body.visible == (pal._toggle.text == "收起"),
			"选色面板第 %d 下：显隐和文案同帧一致" % [i + 1])
		await process_frame
		var panel := _find_panel(main)
		check(panel.offset_bottom <= panel.get_viewport_rect().size.y,
			"配色面板开合后 AI 参数列表适配剩余高度，还原按钮没有出屏（底 %.0f）" % panel.offset_bottom)
	var h_back := pal.offset_bottom - pal.offset_top
	check(absf(h_back - h0) < 0.5,
		"偶数下之后回到原高（%.0f → %.0f）" % [h0, h_back])
	await process_frame


## 拖滑块 → 偏好跟着变。这是面板的主控件
func _t_slider_drives_prefs(panel: AIPanel) -> void:
	var sl: HSlider = panel._slider
	check(is_equal_approx(sl.min_value, 0.0) and is_equal_approx(sl.max_value, 1.0),
		"滑块量程就是 strength 的定义域 0..1")
	check(sl.step > 0.0 and sl.step <= 0.05,
		"滑块步进够细（%.2f）—— 五个档位之间取值是这个面板存在的理由之一" % sl.step)

	sl.value = 0.0
	check(is_equal_approx(AISearch.pref_strength(), 0.0),
		"滑块拖到 0 = 梯子最底档")
	check(panel._slider_val.text.begins_with("0.00"),
		"读数跟着滑块（现在「%s」）" % panel._slider_val.text)

	sl.value = 0.8
	check(is_equal_approx(AISearch.pref_strength(), 0.8),
		"拖到 0.8 之后偏好就是 0.8（读回 %.2f）" % AISearch.pref_strength())
	var high := AISearch.prefs().resolved_parameters()
	var low := AISearch.from_model(AISearch.pref_model(), 0.0).resolved_parameters()
	check(int(high["buy_beam"]) > int(low["buy_beam"]),
		"0.8 档比最底档搜索更宽（购买 Beam %d > %d）" % [
			high["buy_beam"], low["buy_beam"]])


## `_syncing` 护栏。回填每一行会触发 CheckBox.toggled / SpinBox.value_changed，
## 而那两个回调是往下写 `set_override` 的 —— 护栏一破，
## **拖一下滑块就会给每个旋钮盖一层覆盖**，于是滑块从此失灵（覆盖盖住了档位），
## 而面板上只多一个星号。这一条就是钉那个星号不该出现
func _t_syncing_guard(panel: AIPanel) -> void:
	# 两个方向都走，保证预算数值真的改变并触发控件的回填信号。
	# 布尔与枚举由 test_ai_settings 的额外模型覆盖。
	for pair in [[0.8, 0.0], [0.0, 0.8]]:
		AISearch.clear_overrides()
		panel._slider.value = float(pair[0])
		AISearch.clear_overrides()
		panel._sync_rows()
		panel._slider.value = float(pair[1])
		check(not AISearch.has_overrides(),
			"从 %.2f 拖到 %.2f 之后没有逐项覆盖 —— 回填没有反过来写覆盖（_syncing 护栏）" % [
				pair[0], pair[1]])
		check(not panel._slider_val.text.ends_with("*"),
			"读数上没有星号（现在「%s」）" % panel._slider_val.text)

	AISearch.clear_overrides()
	panel._slider.value = 0.55
	check(not panel._syncing, "回填结束后护栏已经放下（不然后面所有输入都被吃掉）")

	# 每一行的显示值 = 当前档位算出来的值。回填漏掉某一行的话，
	# 那一行显示的是上一档的数，玩家照着它调就是调错的
	var cfg := AISearch.prefs()
	var stale: Array = []
	for r in panel._rows:
		var key := str(r["key"])
		var shown: Variant = _shown(r)
		if not _same_value(shown, cfg.get_knob(key)):
			stale.append("%s（显示 %s，实际 %s）" % [key, shown, cfg.get_knob(key)])
	check(stale.is_empty(), "0.55 档下每一行显示的都是这一档的真值（%s）" % (
		"全部同步" if stale.is_empty() else ", ".join(stale)))


## 逐项旋钮：改一行 → 落一条覆盖 → 读数带星号。
## 星号是「滑块的数已经不能完整描述 AI 强度」的唯一提示
func _t_knob_rows(panel: AIPanel) -> void:
	check(panel._rows.size() == AISearch.editable_knobs().size(),
		"面板上的行数 = 可调旋钮数（%d 行）" % panel._rows.size())
	if not need(not panel._rows.is_empty(), "至少有一行旋钮"):
		return

	AISearch.clear_overrides()
	panel._slider.value = 0.0
	var missed: Array = []
	for r in panel._rows:
		AISearch.clear_overrides()
		panel._sync_rows()
		var key := str(r["key"])
		var want: Variant = _change_row(r)
		if not _same_value(AISearch.prefs().get_knob(key), want):
			missed.append(key)
	check(missed.is_empty(), "面板上每一行改了都落到偏好里（%s）" % (
		"全部生效" if missed.is_empty() else "失灵：" + ", ".join(missed)))
	check(AISearch.has_overrides() and panel._slider_val.text.ends_with("*"),
		"有逐项覆盖时读数带星号（现在「%s」）" % panel._slider_val.text)

	# 反过来：拖滑块要把星号和覆盖一起清掉（拖滑块 = 整档换掉）
	panel._slider.value = 0.3
	check(not AISearch.has_overrides()
			and not panel._slider_val.text.ends_with("*"),
		"拖滑块清掉逐项覆盖，星号跟着消失（现在「%s」）" % panel._slider_val.text)


## 档位快捷键。按钮上的名字和 `tools/eval.sh` 认的档位名是同一批 ——
## 面板和命令行说的是一种话，不然对着报告调不出同一个 AI
func _t_presets(panel: AIPanel) -> void:
	var btns: Array = []
	for n in _walk(panel):
		if n is Button and n != panel._toggle:
			btns.append(n)
	var by_text := {}
	for b in btns:
		by_text[str((b as Button).text)] = b

	check(not by_text.has("标准配置（默认）") and not by_text.has("增强配置"), "界面只用统一强度轴，不显示两种独立配置")
	var missing: Array = []
	for key in AISearch.PRESETS:
		var label := str(AIPanel.PRESET_LABELS.get(key, key))
		if not by_text.has(label):
			missing.append("%s（%s）" % [key, label])
	if not need(missing.is_empty(), "每个档位都有一颗按钮（缺：%s）" % (
			"无" if missing.is_empty() else ", ".join(missing))):
		return

	var wrong: Array = []
	for key in AISearch.PRESETS:
		var want := float(AISearch.PRESETS[key])
		var b: Button = by_text[str(AIPanel.PRESET_LABELS.get(key, key))]
		AISearch.clear_overrides()
		panel._slider.value = 0.11          # 先挪开，免得「本来就在那个值上」蒙对
		b.emit_signal("pressed")
		if not is_equal_approx(AISearch.pref_strength(), want):
			wrong.append("%s 想要 %.2f 得到 %.2f" % [key, want, AISearch.pref_strength()])
		elif not is_equal_approx(panel._slider.value, want):
			wrong.append("%s 滑块没跟上（%.2f）" % [key, panel._slider.value])
	check(wrong.is_empty(), "按档位按钮把强度和滑块一起拨过去（%s）" % (
		"五档全对" if wrong.is_empty() else ", ".join(wrong)))

	# 按钮的 tooltip 念的是它真的会设的那个数。念错的话玩家按着报告调不出同一档
	var bad_tip: Array = []
	for key in AISearch.PRESETS:
		var b: Button = by_text[str(AIPanel.PRESET_LABELS.get(key, key))]
		var want := "强度 %.2f" % float(AISearch.PRESETS[key])
		if not b.tooltip_text.begins_with(want):
			bad_tip.append("%s：「%s」不以「%s」开头" % [key, b.tooltip_text, want])
	check(bad_tip.is_empty(), "每颗档位按钮的悬停说明念的是它真会设的强度（%s）" % (
		"全对" if bad_tip.is_empty() else ", ".join(bad_tip)))


## 改动仅影响本次运行，所有控件直接生效，下次启动恢复默认。
func _t_session_and_reset(panel: AIPanel) -> void:
	check(_btn(panel, "保存") == null, "AI 强度不再提供保存按钮")
	var reset: Button = _btn(panel, "还原默认")
	if not need(reset != null, "仍可随时还原默认参数"):
		return
	check(_visible_text(panel).contains("修改立即生效，仅本次运行")
			and _visible_text(panel).contains("下次启动恢复默认"), "面板说明参数生效时机和有效期限")

	AISearch.restore_defaults()
	panel._slider.value = 0.62
	check(not FileAccess.file_exists(AISearch.USER_PATH), "拖滑块不落盘，强度仅留在本次运行")
	var wrong := []
	for row in panel._rows:
		var wanted: Variant = _change_row(row)
		if not _same_value(AISearch.prefs().get_knob(str(row["key"])), wanted):
			wrong.append(row["key"])
	check(wrong.is_empty(), "每个自定义参数改动后当场生效（失配：%s）" % str(wrong))
	check(panel._slider_val.text.ends_with("*"), "即时生效的自定义参数有星号提示")
	check(not FileAccess.file_exists(AISearch.USER_PATH), "全部参数调整后仍未生成持久文件")

	AISearch._reset_pref_cache()
	check(is_equal_approx(AISearch.pref_strength(), AISearch.default_strength())
			and not AISearch.has_overrides(), "模拟重启后恢复默认强度并丢弃全部自定义参数")
	panel._sync_rows()
	check(not panel._slider_val.text.ends_with("*")
			and is_equal_approx(panel._slider.value, AISearch.default_strength()), "重启后的面板显示默认参数")
	panel._slider.value = 0.9
	_change_row(panel._rows[0])
	reset.emit_signal("pressed")
	check(is_equal_approx(AISearch.pref_strength(), AISearch.default_strength())
			and not AISearch.has_overrides(), "按还原默认回到出厂档位并清空自定义参数")
	check(not FileAccess.file_exists(AISearch.USER_PATH), "还原默认不产生参数文件")
	check(is_equal_approx(panel._slider.value, AISearch.default_strength()), "滑块跟着回到出厂强度")
	check(panel._status.text.begins_with("已还原"), "状态栏说明已还原默认")


func _same_value(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	return a == b


func _shown(row: Dictionary) -> Variant:
	var node: Control = row["node"]
	match str(row["kind"]):
		"bool":
			return (node as CheckBox).button_pressed
		"enum":
			var choice := node as OptionButton
			return choice.get_item_metadata(choice.selected)
		"int":
			return int((node as SpinBox).value)
		_:
			return (node as SpinBox).value


## 改控件本身，让其真实信号连接承担写入；返回想要的值而非写入后的值。
func _change_row(row: Dictionary) -> Variant:
	var node: Control = row["node"]
	match str(row["kind"]):
		"bool":
			var cb := node as CheckBox
			var value := not cb.button_pressed
			cb.button_pressed = value
			return value
		"enum":
			var choice := node as OptionButton
			var index := (choice.selected + 1) % choice.item_count
			var value: Variant = choice.get_item_metadata(index)
			choice.select(index)
			choice.item_selected.emit(index)
			return value
		_:
			var sb := node as SpinBox
			var value := sb.value + sb.step
			if value > sb.max_value:
				value = sb.value - sb.step
			sb.value = value
			return int(value) if str(row["kind"]) == "int" else value


func _btn(panel: AIPanel, txt: String) -> Button:
	for n in _walk(panel):
		if n is Button and str((n as Button).text) == txt:
			return n as Button
	return null


## 第 2 条的核心：**对局中途**改了，下一个行动阶段就用上，且不破坏这一局。
##
## 判据分两半，写清楚各自证到哪儿：
##
## 1. 下面这一段**真的驱动 `scenes/main.gd._drive_ai_action()`**（不是自己造
##    `AIAgent`），所以它证的是「面板拖到非默认档之后，屏幕上那条路照旧走得完」。
##    这一条原先没有任何测试碰过 —— `_drive_ai_action` 在 tests/ 里一次都没被调过。
## 2. 「main.gd 用的是玩家偏好而不是写死的贪心」**不由这里证**，
##    由 `tests/test_ai_search.gd._t_headless_ignores_prefs` 那条静态判据证
##    （扫去掉注释之后的 main.gd 正文里有没有 `AISearch.prefs()`）。
##    那条变异（换成 `strength=0 profile`）登记在 tools/mutate_check.py，
##    报的关键字是「场景层读玩家偏好」。
##
## 别把第 2 件事写成这里的判据文字：`AISearch.prefs()` 在这个文件里是**自己调的**，
## 调出来当然是新档位 —— 那句话不管 main.gd 怎么写都成立
func _t_takes_effect_mid_match(main: Node, panel: AIPanel) -> void:
	var state: GameState = main.state
	if not need(state != null and state.winner == "", "局还在进行中"):
		return
	var round_before: int = state.round_num
	var hash_before := StateCodec.state_hash(state)

	panel._slider.value = 0.45
	check(is_equal_approx(AISearch.pref_strength(), 0.45),
		"对局中途拖滑块，偏好当场就是 0.45（读回 %.2f）" % AISearch.pref_strength())
	check(StateCodec.state_hash(state) == hash_before,
		"改档位本身一个字都没动局面（改的是偏好，不是卡表也不是状态）")
	check(state.round_num == round_before and state.winner == "",
		"这一局还在，没被打断（第 2 条要的「任何时机」）")

	# 走**屏幕那条路**：main 自己的 _drive_ai_action，它内部现读 prefs()、
	# 现造 AIAgent、每步之间垫演出节拍。0.45 档在这条路上跑不动的话
	# （试算抄快照漏字段、节拍等在一个不会来的信号上），
	# 表现是「AI 回合卡住」，而参数层那一整串判据全绿
	var who: String = main.foe_seat
	# 数一数这条路上到底落了几条意图。光判「跑完没崩」是不够的：
	# `_drive_ai_action` 整个空转（一条意图都不发）也叫「没崩」，
	# 而屏幕上表现为 AI 回合什么都不做
	var applied := [0]
	var counter := func(_r: Dictionary) -> void: applied[0] += 1
	main.pipe.applied.connect(counter)
	await main._drive_ai_action()
	await ai_moves_landed(main)
	main.pipe.applied.disconnect(counter)
	check(applied[0] > 0,
		"0.45 档下 _drive_ai_action 真的经管道落了意图（%d 条）" % applied[0])
	# `check(true, ...)` 是记账，不是永真判据（harness.gd 的 check 那条注释）：
	# 失败那一路是「跑崩了」—— 脚本当场停，这一行印不出来。
	# 别写成 `winner == "" or winner != ""` 那种伪比较，
	# 那个长得像判据而永远为真，比明写 true 更难发现
	check(true, "0.45 档在对局中途接手一个行动阶段，跑完没崩")
	check(state.resource_count(who, CardDB.RES_CASH) >= 0
			and state.resource_count(who, CardDB.RES_USER) >= 0,
		"跑完之后资源没有负数")

	# 中途换到最弱档也一样得走得动（玩家嫌慢往回拖），同样走屏幕那条路
	panel._slider.value = 0.0
	check(is_equal_approx(AISearch.prefs().strength, 0.0), "中途拖回 0 = 最底档")
	await main._drive_ai_action()
	await ai_moves_landed(main)
	check(true, "拖回最弱档之后 _drive_ai_action 又跑完一个行动阶段")
	check(state.resource_count(who, CardDB.RES_CASH) >= 0, "最弱档接手也没坏")


## 测试结束也不恢复已废弃的持久参数文件。
func _restore() -> void:
	AISearch.restore_defaults()
	AISearch._reset_pref_cache()

func _visible_text(node: Node) -> String:
	var text := ""
	if node is Label:
		text += node.text
	for child in node.get_children():
		text += _visible_text(child)
	return text
