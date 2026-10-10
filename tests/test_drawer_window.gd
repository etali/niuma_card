# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends "res://tests/harness.gd"

const Drawer = preload("res://scenes/drawer_window.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("=== 抽屉窗口几何、点击与悬停测试 ===")
	var drawer := Drawer.new()
	root.add_child(drawer)
	var screen := Rect2i(Vector2i(-1920, 32), Vector2i(1920, 1048))
	var attention_events: Array[bool] = []
	var hover_events: Array[bool] = []
	drawer.attention_requested.connect(func(): attention_events.append(true))
	drawer.handle_hovered.connect(func(value: bool): hover_events.append(value))
	drawer.setup(false, screen)
	check(drawer.process_mode == Node.PROCESS_MODE_ALWAYS, "牌局暂停后抽屉仍处理入口交互")
	check(drawer.get_expanded_size() == Vector2i(1694, 1027), "默认98%保留1027高度，左右空白收至1.65宽高比")
	check(screen.encloses(drawer._geometry), "负坐标副屏：展开窗口完整留在可用区")
	check(drawer._geometry.end.x == screen.end.x, "展开窗口贴住当前屏幕右边缘")
	drawer._tick_at(60000)
	check(drawer.is_expanded(), "场景初始化期间不提前自动暂停尚未建成的牌桌")
	drawer.start_collapsed()
	await process_frame
	check(not drawer.is_expanded(), "主场景构造结束后启动只展示入口")
	check(is_equal_approx(drawer.get_icon_scale(), 0.75), "入口默认使用75%比例")
	check(drawer._geometry.size == Vector2i(126, 144), "默认75%入口完整容纳图标与问候，不拦截全屏右边缘")
	check(screen.encloses(drawer._geometry), "入口留在副屏可用区")
	check(attention_events.size() == 1, "入口准备好后只发送一次启动问候")
	check(drawer.is_attention_active(), "入口出现后启动问候处于激活期")

	var handle := drawer._geometry.get_center()
	drawer._update_hover(handle, 1000)
	drawer._tick_at(1120)
	check(not drawer.is_expanded(), "悬停120ms不展开")
	drawer._update_hover(handle, 61000)
	drawer._tick_at(61000)
	check(not drawer.is_expanded(), "持续悬停一分钟也不展开")
	check(hover_events == [true], "持续悬停只触发一次入口放大问候")
	drawer._on_mouse_exited()
	drawer._on_mouse_entered()
	drawer._tick_at(121000)
	check(not drawer.is_expanded(), "原生鼠标进入事件同样不会触发展开")
	check(hover_events == [true, false, true], "入口离开和重进正确通知动画恢复与问候")
	drawer.activate_handle()
	check(drawer.is_expanded(), "点击图标入口立即展开")
	check(hover_events.back() == false, "点击展开时停止入口悬停动画")

	var outside := screen.position - Vector2i(20, 20)
	drawer._update_hover(outside, 2000)
	drawer._tick_at(2159)
	check(drawer.is_expanded(), "离开159ms仍保持展开，给短暂越界留容错")
	drawer._update_hover(drawer._geometry.get_center(), 2159)
	drawer._tick_at(2400)
	check(drawer.is_expanded(), "离开后及时返回取消收起")
	drawer._update_hover(outside, 3000)
	drawer._tick_at(3159)
	check(drawer.is_expanded(), "第二次离开在159ms边界前仍保持展开")
	drawer._tick_at(3160)
	check(not drawer.is_expanded(), "离开160ms立即开始自动收起")
	await process_frame
	check(attention_events.size() == 1, "再次收起不重复启动招手")

	drawer.pin()
	check(drawer.is_expanded() and drawer.is_pinned(), "pin同时展开并真正锁定")
	drawer._update_hover(outside, 4000)
	drawer._tick_at(9000)
	check(drawer.is_expanded(), "钉住后离开多久都不自动收起")
	drawer.pin(false)
	drawer._update_hover(outside, Time.get_ticks_msec())
	drawer._tick_at(Time.get_ticks_msec() + 700)
	check(not drawer.is_expanded(), "取消钉住恢复自动收起")

	drawer.expand()
	drawer.can_collapse = func() -> bool: return false
	drawer._update_hover(outside, 10000)
	drawer._tick_at(10160)
	check(drawer.is_expanded(), "拖牌或菜单操作阻止自动收起")
	drawer.collapse_now()
	check(drawer.is_expanded(), "程序收起同样尊重未完成的拖牌")
	drawer.can_collapse = Callable()
	drawer._tick_at(10161)
	check(not drawer.is_expanded(), "操作结束后到期收起请求继续执行")

	drawer._screen_rect = Rect2i(Vector2i(20, 40), Vector2i(900, 640))
	drawer.set_expanded_size(Vector2i(1400, 1000))
	drawer.expand()
	check(drawer.get_expanded_size() == Vector2i(900, 640), "显式像素档位按小屏工作区限制")
	check(drawer._screen_rect.encloses(drawer._geometry), "修改宽高后仍无窗口超出屏幕")
	drawer.handle_vertical_ratio = 3.0
	drawer.collapse_now()
	check(drawer._screen_rect.encloses(drawer._geometry), "入口纵向位置越界也会被限制在屏幕内")
	drawer.set_size_preset("wide")
	check(drawer.get_expanded_size() == Vector2i(900, 640), "宽屏档位仍按小屏工作区限制")
	drawer.set_size_preset("full")
	check(drawer.get_expanded_size() == Vector2i(882, 627), "最大档位按工作区98%计算")
	check(drawer.get_handle_texture() != null, "收起态提供游戏图标纹理")

	# 最大档位保留比例配置：换到4K工作区后不能继续使用上块屏幕的像素尺寸。
	drawer._screen_rect = Rect2i(Vector2i(1920, 24), Vector2i(3840, 2136))
	drawer.expand()
	var large := drawer.get_expanded_size()
	check(large == Vector2i(3453, 2093), "4K最大档保留98%高度，宽度只去掉牌区外空白")
	check(large.x > 1920 and large.y > 1200, "高分辨率窗口不再被1920×1200上限卡住")
	check(drawer._screen_rect.encloses(drawer._geometry), "4K大窗口仍完整留在当前工作区")
	drawer.set_size_fraction(0.85)
	check(drawer.get_expanded_size() == Vector2i(2996, 1816), "85%档在4K屏保留1816高度并收紧横向空白")
	drawer.set_expanded_size(Vector2i(1600, 1000))
	check(drawer.get_expanded_size() == Vector2i(1600, 1000), "主动选固定尺寸会退出百分比模式")
	drawer.set_size_preset("full")
	drawer.collapse_now()
	paused = true
	drawer._update_hover(drawer._geometry.get_center(), 12000)
	drawer._tick_at(72000)
	check(not drawer.is_expanded(), "SceneTree暂停时悬停仍只问候不展开")
	drawer.activate_handle()
	check(drawer.is_expanded(), "SceneTree暂停时点击入口仍可展开")
	paused = false

	# 新入口交互：按住图标移动后拖拽，松手吸附到最近屏幕边；轻点仍然展开。
	drawer.collapse_now()
	await process_frame
	var collapsed_center := drawer._geometry.get_center()
	drawer.start_drag(collapsed_center)
	drawer.drag_to(collapsed_center + Vector2i(400, 40))
	check(drawer.is_dragging(), "入口按住移动超过阈值进入拖拽")
	drawer.end_drag(Vector2i(drawer._screen_rect.end.x - 2, drawer._screen_rect.get_center().y))
	check(not drawer.is_dragging(), "松手结束入口拖拽")
	check(drawer.get_anchor_edge() == "right", "拖到右侧吸附")
	check(drawer._screen_rect.encloses(drawer._geometry), "右侧吸附后入口仍在工作区")
	drawer.start_drag(drawer._geometry.get_center())
	drawer.end_drag(drawer._geometry.get_center())
	check(drawer.is_expanded(), "轻点入口松手直接展开")

	# 比例档位不会写入固定像素，换屏后仍按工作区重算。
	drawer.set_size_preset("small")
	check(drawer.get_expanded_size() == Vector2i(2643, 1602), "75%档仍使用当前4K工作区高度并限制横向空白")
	drawer.set_icon_scale(1.5)
	drawer.collapse_now()
	check(drawer._geometry.size == Vector2i(252, 288), "入口图标支持比例缩放")

	drawer.free()
	_check_drag_positions()
	_check_default_icon_dpi()
	finish()

## 四边的吸附仅锁定贴边轴；沿边轴保留玩家松手的具体位置。
func _check_drag_positions() -> void:
	var drawer := Drawer.new()
	root.add_child(drawer)
	var screen := Rect2i(Vector2i(-1920, 32), Vector2i(1920, 1048))
	drawer.setup(false, screen)
	drawer.start_collapsed()
	for option in [["left", 0.18], ["right", 0.72], ["top", 0.24], ["bottom", 0.77]]:
		var edge: String = str(option[0])
		var ratio: float = float(option[1])
		var size: Vector2i = drawer._geometry.size
		var vertical := edge in ["left", "right"]
		var desired := screen.position + Vector2i(
			roundi(float(screen.size.x - size.x) * ratio),
			roundi(float(screen.size.y - size.y) * ratio))
		var pointer := desired + size / 2
		match edge:
			"left": pointer.x = screen.position.x + 2
			"right": pointer.x = screen.end.x - 2
			"top": pointer.y = screen.position.y + 2
			"bottom": pointer.y = screen.end.y - 2
		drawer.start_drag(drawer._geometry.get_center())
		# 松手可能是跨出原窗口后收到的唯一新事件，要使用松手的最终全局位置。
		drawer.end_drag(pointer)
		check(not drawer.is_dragging() and not drawer.is_expanded(), "%s：拖拽松手只吸附、不误展开" % edge)
		check(drawer.get_anchor_edge() == edge, "%s：吸附到鼠标最近的边" % edge)
		check(screen.encloses(drawer._geometry), "%s：整个入口留在工作区" % edge)
		var actual := drawer._geometry
		var on_edge := actual.position.x == screen.position.x if edge == "left" else \
			actual.end.x == screen.end.x if edge == "right" else \
			actual.position.y == screen.position.y if edge == "top" else actual.end.y == screen.end.y
		check(on_edge, "%s：入口贴住选中的边缘" % edge)
		var along := actual.position.y if vertical else actual.position.x
		var expected := desired.y if vertical else desired.x
		check(absi(along - expected) <= 1, "%s：保留松手的具体沿边位置，不跳回中间" % edge)
		var stored := drawer.handle_vertical_ratio if vertical else drawer.handle_horizontal_ratio
		check(absf(stored - 0.5) > 0.10, "%s：记录的沿边位置不是固定50%%" % edge)
		drawer.activate_handle()
		check(drawer.is_expanded(), "%s：当前位置点击后仍可展开" % edge)
		drawer.collapse_now()
		check(drawer._geometry == actual, "%s：展开再收起恢复原入口位置" % edge)
	drawer.free()

func _check_default_icon_dpi() -> void:
	for dpi in [1.0, 2.0]:
		var drawer := Drawer.new()
		root.add_child(drawer)
		drawer.set_display_scale(float(dpi))
		drawer.setup(false, Rect2i(Vector2i.ZERO, Vector2i(3840, 2160)))
		drawer.start_collapsed()
		check(is_equal_approx(drawer.get_icon_scale(), 0.75), "%s倍DPI初始化仍默认75%%入口" % dpi)
		check(drawer._geometry.size == Vector2i(roundi(126 * dpi), roundi(144 * dpi)),
			"%s倍DPI首次收起直接应用75%%物理尺寸" % dpi)
		drawer.free()
