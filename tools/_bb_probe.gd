# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

extends SceneTree

## 手工探针：RichTextLabel 到底吃掉什么。
## 不进 tests/ —— 它问的是引擎行为，不是这个仓库的判据。
## 结论写进了 scenes/msg_log.gd 里 `safe` 那行的注释和 tests/test_no_vanishing.gd T4
func _initialize() -> void:
	for raw in ["购入[百亿补贴]，剩 3 现金", "房间 [b]，端口 8910", "对手 [/color] 走了"]:
		for esc in [false, true]:
			var rtl := RichTextLabel.new()
			rtl.bbcode_enabled = true
			var s: String = raw.replace("[", "[lb]") if esc else raw
			rtl.append_text("[color=#ffffff]%s[/color]\n" % s)
			print("esc=%s 原「%s」→ 存下来「%s」"
				% [esc, raw, rtl.get_parsed_text().strip_edges()])
			rtl.free()
	quit()
