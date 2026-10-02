# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 手工探针：msg_log 的框子尺寸，到底哪条路在维护它。
## 两条路各自管什么：
##   A. _toggle_body 里那句 _relayout()  —— 展开/收起
##   B. _ready 里 minimum_size_changed 连接 —— 内容自己长大（标题条数变宽）
## 拿它定 56j 那条变异该钉哪一行。结论写进 scenes/msg_log.gd
func _initialize() -> void:
	for cut_signal in [false, true]:
		var log_panel := MsgLog.new()
		get_root().add_child(log_panel)
		await process_frame
		if cut_signal:
			log_panel._frame.minimum_size_changed.disconnect(log_panel._relayout)
		var tag := "断信号" if cut_signal else "原样"

		log_panel.append("头一句", Color.WHITE, 1)
		await process_frame
		var w1: float = log_panel._frame.size.x
		var h1: float = log_panel._frame.size.y

		# 条数从 1 位涨到 3 位：标题「提示记录 · 1 条」→「· 221 条」，最小宽度会变
		for i in range(220):
			log_panel.append("第 %d 句" % i, Color.WHITE, 1)
		await process_frame
		await process_frame
		var w2: float = log_panel._frame.size.x
		var h2: float = log_panel._frame.size.y
		# **在任何 toggle 之前**读位置：翻一下就会重算，读晚了量的是那次重算
		var px: float = log_panel._frame.position.x

		log_panel._toggle_body()
		await process_frame
		var h3: float = log_panel._frame.size.y
		log_panel._toggle_body()
		await process_frame
		var h4: float = log_panel._frame.size.y

		print("%s：宽 1条=%.1f 221条=%.1f ｜ 高 收=%.1f 展=%.1f 再收=%.1f（初 %.1f）"
			% [tag, w1, w2, h2, h3, h4, h1])
		# 位置才是重点：offset 是按**当时**那个 sz 算的，
		# 框子自己长宽之后没人重算 offset 的话它会捅出右边界
		print("   位置 x：该在 %.1f，实际 %.1f（差 %.1f，>0 就是捅出右边界了）"
			% [-w2 - log_panel.MARGIN, px, px + w2 + log_panel.MARGIN])
		log_panel.free()
	quit()
