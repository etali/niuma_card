# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends RefCounted

## 由独立的延迟调用替换场景。必须在新抽屉更改原生窗口之前释放旧场景：
## remove_child 只让旧控件离树，不会断开它们接在根窗口上的 size_changed/焦点信号。
static func replace(previous: Node, session: RefCounted) -> void:
	if not is_instance_valid(previous) or not previous.is_inside_tree():
		return
	var tree: SceneTree = previous.get_tree()
	var parent: Node = previous.get_parent()
	var next: Node = load("res://scenes/main.tscn").instantiate()
	next.replay_session = session
	next.force_drawer_layout = previous.force_drawer_layout
	next.force_mobile_layout = previous.force_mobile_layout
	next.force_web_layout = previous.force_web_layout
	next.drawer_ui_scale = previous.drawer_ui_scale
	var muted: bool = previous.sfx.user_muted if is_instance_valid(previous.sfx) else false
	var was_current := tree.current_scene == previous
	var pinned: bool = previous.drawer_window.is_pinned() if previous.drawer_window else false
	previous.tape.stop()
	# 这里不在 previous 自己的方法栈中执行，可以先彻底 free，自动断开其所有信号。
	parent.remove_child(previous)
	previous.free()
	tree.paused = false
	parent.add_child(next)
	if was_current:
		tree.current_scene = next
	next.sfx.set_user_muted(muted)
	if next.drawer_window:
		next.drawer_window.activate_handle()
		next.drawer_window.set_pinned(pinned)
